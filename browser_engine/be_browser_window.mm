#include "browser_engine/be_browser_window.h"

#import <AppKit/AppKit.h>

#include <utility>

#include "base/check.h"
#include "base/check_op.h"
#include "base/functional/bind.h"
#include "base/notimplemented.h"
#include "browser_engine/be_browser_window_parts.h"
#import "browser_engine/be_tab.h"
#import "browser_engine/be_window.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/app_mode/app_mode_utils.h"
#include "chrome/browser/global_keyboard_shortcuts_mac.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/themes/theme_service.h"
#include "chrome/browser/ui/accelerator_table.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_init_state.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window_state.h"
#import "chrome/browser/ui/cocoa/browser_window_command_handler.h"
#import "chrome/browser/ui/cocoa/chrome_command_dispatcher_delegate.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/interaction/browser_elements.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/download/download_in_progress_dialog_view.h"
#include "chrome/browser/ui/views/find_bar_host.h"
#include "chrome/browser/ui/views/find_bar_owner.h"
#include "chrome/browser/ui/views/interaction/browser_elements_views_impl.h"
#include "chrome/browser/ui/window_metadata/window_metadata_controller.h"
#include "components/input/native_web_keyboard_event.h"
#import "components/remote_cocoa/app_shim/native_widget_ns_window_bridge.h"
#include "content/public/browser/eye_dropper.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/accelerators/global_accelerator_listener/global_accelerator_listener.h"
#include "ui/base/emoji/emoji_panel_helper.h"
#include "ui/content_accelerators/accelerator_util.h"
#include "ui/native_theme/native_theme.h"
#include "ui/views/cocoa/native_widget_mac_ns_window_host.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/widget/native_widget_mac.h"
#include "ui/views/widget/widget_delegate.h"

namespace browser_engine {

namespace {

// The NSWindow property that leads from a window back to us (as Webium's
// "__WEBUI_BROWSER_WINDOW__").
const char kBEBrowserWindowKey[] = "__BROWSER_ENGINE_WINDOW__";

// Where the traffic lights sit: the height of the title bar region they're
// centered in. Webium uses 40; the app's single-row bar decides the final
// number (open question in README.md).
constexpr float kTitlebarHeight = 40;

// Copied from webui_browser_window_mac.mm.
bool ShouldHandleKeyboardEvent(const input::NativeWebKeyboardEvent& event) {
  // |event.skip_if_unhandled| is true when it shouldn't be handled by the
  // browser if it was ignored by the renderer. See http://crbug.com/41018016.
  if (event.skip_if_unhandled) {
    return false;
  }
  // Ignore synthesized keyboard events. See http://crbug.com/41007517.
  if (event.GetType() == input::NativeWebKeyboardEvent::Type::kChar) {
    return false;
  }
  // Do not fire shortcuts on key up, and only forward shortcuts if we have an
  // underlying os event.
  return event.os_event && event.os_event.Get().type == NSEventTypeKeyDown;
}

// The NSWindow Chrome makes for us: full-size content view, transparent title
// bar, Chrome's command dispatch. Webium's WebUIBrowserNativeWidgetMac (itself
// derived from BrowserNativeWidgetMac), minus the app-shim path: our windows
// always live in this process.
class BENativeWidgetMac : public views::NativeWidgetMac {
 public:
  BENativeWidgetMac(BrowserWindowInterface* browser, views::Widget* widget)
      : NativeWidgetMac(widget), browser_(browser) {}

 private:
  // views::NativeWidgetMac:
  void OnWidgetDestroyed(views::Widget* widget) override {
    browser_ = nullptr;
    NativeWidgetMac::OnWidgetDestroyed(widget);
  }

  void ValidateUserInterfaceItem(
      int32_t command,
      remote_cocoa::mojom::ValidateUserInterfaceItemResult* result) override {
    CHECK(browser_);
    // Lets menu items with Chrome command tags (and their key equivalents)
    // enable as Chrome would.
    result->enable = chrome::IsCommandEnabled(browser_, command);
  }

  // For ValidateUserInterfaceItem() and ExecuteCommand() to be called, the
  // window needs Chrome's command dispatcher.
  void OnWindowInitialized() override {
    if (auto* bridge = GetInProcessNSWindowBridge()) {
      bridge->SetCommandDispatcher(
          [[ChromeCommandDispatcherDelegate alloc] init],
          [[BrowserWindowCommandHandler alloc] init]);
    }
  }

  bool WillExecuteCommand(int32_t command,
                          WindowOpenDisposition window_open_disposition,
                          bool is_before_first_responder) override {
    CHECK(browser_);
    if (is_before_first_responder) {
      // Don't run Chrome commands before the first responder had a go, unless
      // the command is reserved (see webui_browser_window_mac.mm).
      if (ui::GlobalAcceleratorListener::GetInstance() &&
          ui::GlobalAcceleratorListener::GetInstance()
              ->IsShortcutHandlingSuspended()) {
        return false;
      }
      input::NativeWebKeyboardEvent dummy_event(
          blink::WebInputEvent::Type::kKeyDown, 0, base::TimeTicks());
      if (!chrome::BrowserCommandController::From(browser_)
               ->IsReservedCommandOrKey(command, dummy_event)) {
        return false;
      }
    }
    return true;
  }

  bool ExecuteCommand(int32_t command,
                      WindowOpenDisposition window_open_disposition,
                      bool is_before_first_responder) override {
    if (!WillExecuteCommand(command, window_open_disposition,
                            is_before_first_responder)) {
      return false;
    }
    chrome::ExecuteCommandWithDisposition(browser_, command,
                                          window_open_disposition);
    return true;
  }

  // views::NativeWidget:
  views::internal::NativeWidgetPrivate* AsNativeWidgetPrivate() override {
    return this;
  }

  void PopulateCreateWindowParams(
      const views::Widget::InitParams& widget_params,
      remote_cocoa::mojom::CreateWindowParams* params) override {
    // As Webium: the content view fills the whole window, under a
    // transparent title bar with the traffic lights.
    params->style_mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                         NSWindowStyleMaskMiniaturizable |
                         NSWindowStyleMaskResizable |
                         NSWindowStyleMaskFullSizeContentView;
    params->window_class = remote_cocoa::mojom::WindowClass::kBrowser;
    params->titlebar_appears_transparent = true;
    params->window_title_hidden = true;
    params->animation_enabled = true;
  }

  void GetWindowFrameTitlebarHeight(bool* override_titlebar_height,
                                    float* titlebar_height) override {
    *override_titlebar_height = true;
    *titlebar_height = kTitlebarHeight;
  }

  raw_ptr<BrowserWindowInterface> browser_;
};

}  // namespace

// The widget's delegate: window placement, title, resizability. Copied from
// WebUIBrowserWindow::WidgetDelegate; the client view is the default one.
class BEBrowserWindow::WidgetDelegate : public views::WidgetDelegate {
 public:
  explicit WidgetDelegate(BEBrowserWindow* window) : window_(window) {
    const auto& create_params =
        BrowserInitState::From(window_->browser())->create_params();
    SetCanResize(create_params.can_resize);
    SetCanMaximize(create_params.can_maximize);
    SetCanFullscreen(create_params.can_fullscreen);
    SetCanMinimize(true);
  }

  // views::WidgetDelegate:
  bool ShouldSaveWindowPlacement() const override {
    // While entering fullscreen, the going-into-fullscreen bounds are not the
    // ones to save.
    return !window_->IsFullscreen() &&
           chrome::ShouldSaveWindowPlacement(window_->browser());
  }

  void SaveWindowPlacement(const gfx::Rect& bounds,
                           ui::mojom::WindowShowState show_state) override {
    CHECK(ShouldSaveWindowPlacement());
    views::WidgetDelegate::SaveWindowPlacement(bounds, show_state);
    chrome::SaveWindowPlacement(window_->browser(), bounds, show_state);
  }

  bool GetSavedWindowPlacement(
      const views::Widget* widget,
      gfx::Rect* bounds,
      ui::mojom::WindowShowState* show_state) const override {
    chrome::GetSavedWindowBoundsAndShowState(window_->browser(), bounds,
                                             show_state);
    return true;
  }

  std::u16string GetWindowTitle() const override {
    // The Window menu, Mission Control and VoiceOver read this; the title
    // bar itself is hidden.
    return WindowMetadataController::From(window_->browser())
        ->GetWindowTitleForCurrentTab(/*include_app_name=*/true);
  }

 private:
  const raw_ptr<BEBrowserWindow> window_;
};

BEBrowserWindow::BEBrowserWindow(BrowserWindowInterface* browser)
    : browser_(browser) {
  // Before the widget: views may ask for the location bar while it inits.
  location_bar_ = std::make_unique<BELocationBar>(this);

  widget_delegate_ = std::make_unique<WidgetDelegate>(this);
  widget_ = std::make_unique<views::Widget>();
  widget_->AddObserver(this);
  views::Widget::InitParams params(
      views::Widget::InitParams::CLIENT_OWNS_WIDGET);
  params.name = "BEBrowserWindow";
  chrome::GetSavedWindowBoundsAndShowState(browser_, &params.bounds,
                                           &params.show_state);
  params.delegate = widget_delegate_.get();
  params.native_widget = CreateNativeWidget();
  widget_->Init(std::move(params));
  widget_->SetNativeWindowProperty(kBEBrowserWindowKey, this);
  widget_->MakeCloseSynchronous(base::BindOnce(
      &BEBrowserWindow::OnWindowCloseRequested, base::Unretained(this)));

  // The app's root NSView goes into a NativeViewHost rather than straight
  // into the widget's content NSView: the host keeps the view sized to the
  // client area, in the widget's focus and accessibility trees (VoiceOver
  // reaches the page through it), and is how views::WebView hosts pages too.
  host_ = widget_->SetClientContentsView(
      std::make_unique<views::NativeViewHost>());

  // BrowserWindowFeatures made BrowserElementsViewsImpl for us (Webium is
  // off); give it our widget, as BrowserView::AddedToWidget() does, so
  // features that ask BrowserElementsViews for the window's widget get ours.
  if (BrowserElements* elements = BrowserElements::From(browser_)) {
    if (auto* views_elements = elements->AsA<BrowserElementsViewsImpl>()) {
      views_elements->Init(host_.get());
    }
  }

  modal_dialog_host_ = std::make_unique<BEModalDialogHost>(this);
  exclusive_access_context_ = std::make_unique<BEExclusiveAccessContext>(this);
  find_bar_owner_ = std::make_unique<BEFindBarOwner>(
      this, browser_->GetUnownedUserDataHost());

  paint_as_active_subscription_ =
      widget_->RegisterPaintAsActiveChangedCallback(base::BindRepeating(
          &BEBrowserWindow::PaintAsActiveChanged, base::Unretained(this)));

  browser_->GetTabStripModel()->AddObserver(this);

  LoadAccelerators();
}

BEBrowserWindow::~BEBrowserWindow() {
  // The app lets go of the window and its views first, while everything it
  // might still read is alive.
  [objc_window_ browserWindowWillClose];
  objc_window_ = nil;

  browser_->GetTabStripModel()->RemoveObserver(this);

  // As BrowserWidget and WebUIBrowserWindow do: window-dependent features go
  // while the widget still exists. This also destroys the ExclusiveAccessManager
  // and FindBarController that hold pointers to our parts.
  browser_->GetFeatures().TearDownPreBrowserWindowDestruction();

  find_bar_owner_.reset();
  exclusive_access_context_.reset();
  modal_dialog_host_.reset();

  if (host_ && host_->native_view()) {
    host_->Detach();
  }
  host_ = nullptr;
  content_view_ = nil;

  // Nothing may call back into us while the widget goes.
  paint_as_active_subscription_ = {};
  widget_->MakeCloseSynchronous(
      base::BindOnce([](views::Widget::ClosedReason) {}));
  widget_->RemoveObserver(this);
  widget_.reset();
}

// static
BEBrowserWindow* BEBrowserWindow::FromBrowser(
    const BrowserWindowInterface* browser) {
  if (!browser || !browser->GetWindow() ||
      !browser->GetWindow()->GetNativeWindow()) {
    return nullptr;
  }
  views::Widget* widget = views::Widget::GetWidgetForNativeWindow(
      browser->GetWindow()->GetNativeWindow());
  return widget ? static_cast<BEBrowserWindow*>(
                      widget->GetNativeWindowProperty(kBEBrowserWindowKey))
                : nullptr;
}

void BEBrowserWindow::OnBrowserInitialized() {
  if (objc_window_) {
    return;
  }
  objc_window_ = [[BEChromiumWindow alloc] initWithBrowserWindow:this];
  // Synchronously, so the app can install its views before the window shows
  // and set the window's delegate before the first tab arrives.
  [objc_window_ announce];
}

void BEBrowserWindow::SetContentView(NSView* view) {
  if (content_view_ == view) {
    return;
  }
  if (host_->native_view()) {
    host_->Detach();
  }
  content_view_ = view;
  if (view) {
    host_->Attach(gfx::NativeView(view));
  }
}

gfx::Rect BEBrowserWindow::GetContentsBoundsInScreen() const {
  content::WebContents* contents =
      browser_->GetTabStripModel()->GetActiveWebContents();
  if (contents) {
    NSView* page = contents->GetNativeView().GetNativeNSView();
    if (page.window &&
        page.window == GetNativeWindow().GetNativeNSWindow()) {
      return contents->GetContainerBounds();
    }
  }
  return widget_->GetClientAreaBoundsInScreen();
}

void BEBrowserWindow::ProcessFullscreen(bool fullscreen) {
  widget_->SetFullscreen(fullscreen);
  fullscreen_ = fullscreen;
  if (ExclusiveAccessManager* manager = ExclusiveAccessManager::From(browser_)) {
    manager->fullscreen_controller()->WindowFullscreenStateChanged();
  }
}

void BEBrowserWindow::RequestLocationFocus() {
  [objc_window_ wantsLocationFocus];
}

void BEBrowserWindow::DeleteBrowserWindow() {
  delete this;
}

// BrowserWindow ---------------------------------------------------------------

gfx::NativeWindow BEBrowserWindow::GetNativeWindow() const {
  return widget_->GetNativeWindow();
}

bool BEBrowserWindow::IsOnCurrentWorkspace() const {
  return GetNativeWindow().GetNativeNSWindow().onActiveSpace;
}

bool BEBrowserWindow::IsVisibleOnScreen() const {
  return widget_->IsVisible() && !widget_->IsMinimized();
}

void BEBrowserWindow::SetTopControlsShownRatio(
    content::WebContents* web_contents,
    float ratio) {}  // No sliding top controls on Mac.

bool BEBrowserWindow::DoBrowserControlsShrinkRendererSize(
    const content::WebContents* contents) const {
  return false;
}

ui::NativeTheme* BEBrowserWindow::GetNativeTheme() {
  return ui::NativeTheme::GetInstanceForNativeUi();
}

const ui::ThemeProvider* BEBrowserWindow::GetThemeProvider() const {
  // Normal windows only (see CreateBrowserWindow in be_engine.mm), so no web
  // app theme to prefer, unlike Webium.
  return &ThemeService::GetThemeProviderForProfile(browser_->GetProfile());
}

const ui::ColorProvider* BEBrowserWindow::GetColorProvider() const {
  return widget_->GetColorProvider();
}

int BEBrowserWindow::GetTopControlsHeight() const {
  return 0;  // No sliding top controls.
}

void BEBrowserWindow::SetTopControlsGestureScrollInProgress(bool in_progress) {
}  // No sliding top controls.

std::vector<StatusBubble*> BEBrowserWindow::GetStatusBubbles() {
  return {};  // Milestone 2: the hover-URL status goes to the app.
}

void BEBrowserWindow::UpdateTitleBar() {
  widget_->UpdateWindowTitle();
  [objc_window_ activeTabDidChange];
}

void BEBrowserWindow::UpdateLoadingAnimations(bool is_visible) {
}  // The app animates from BETab.isLoading.

void BEBrowserWindow::OnActiveTabChanged(content::WebContents* old_contents,
                                         content::WebContents* new_contents,
                                         int index,
                                         int reason) {
  // The app hears about the switch from OnTabStripModelChanged() instead:
  // Browser observes the tab strip before us and calls this first, so telling
  // the app here would announce a new tab's activation before its insertion.
  //
  // Pages use the window's colors (form controls, scrollbars, dark mode) as
  // views::WebView would give them.
  if (new_contents) {
    new_contents->SetColorProviderSource(widget_.get());
  }
  // Visibility follows the page's NSView entering and leaving the window,
  // which the app does on didActivateTab: (as in content_shell), so unlike
  // Webium there is no UpdateWebContentsVisibility() here.
}

void BEBrowserWindow::OnTabDetached(content::WebContents* contents,
                                    bool was_active) {
  // The app removes the page's view on didRemoveTab:, which
  // OnTabStripModelChanged() sends after Browser is done with the tab.
}

gfx::Size BEBrowserWindow::GetContentsSize() const {
  return GetContentsBoundsInScreen().size();
}

void BEBrowserWindow::SetContentsSize(const gfx::Size& size) {
  // Grow or shrink the window by the difference (window.resizeTo for the
  // page area), as Webium does.
  const gfx::Size current = GetContentsSize();
  if (size == current) {
    return;
  }
  gfx::Rect bounds = GetBounds();
  bounds.set_size(bounds.size() + size - current);
  SetBounds(bounds);
}

autofill::AutofillBubbleHandler* BEBrowserWindow::GetAutofillBubbleHandler() {
  NOTIMPLEMENTED_LOG_ONCE();  // Milestone 2 (password and address bubbles).
  return nullptr;
}

LocationBar* BEBrowserWindow::GetLocationBar() const {
  return location_bar_.get();
}

ui::AcceleratorProvider* BEBrowserWindow::GetAcceleratorProvider() {
  return this;
}

PinnedToolbarActions* BEBrowserWindow::GetPinnedToolbarActions() {
  return nullptr;  // No Chrome toolbar.
}

void BEBrowserWindow::SetFocusToLocationBar(bool is_user_initiated) {
  RequestLocationFocus();
}

void BEBrowserWindow::UpdateReloadStopState(bool is_loading, bool force) {
  [objc_window_ activeTabDidChange];
}

void BEBrowserWindow::UpdateToolbar(content::WebContents* contents) {
  [objc_window_ activeTabDidChange];
}

bool BEBrowserWindow::UpdateToolbarSecurityState() {
  [objc_window_ activeTabDidChange];
  return true;
}

void BEBrowserWindow::UpdateCustomTabBarVisibility(bool visible,
                                                   bool animate) {
}  // Web app windows only.

void BEBrowserWindow::ResetToolbarTabState(content::WebContents* contents) {
  [objc_window_ activeTabDidChange];
}

void BEBrowserWindow::FocusToolbar() {}  // The app's bar takes keyboard focus.

void BEBrowserWindow::ToolbarSizeChanged(bool is_animating) {}  // No toolbar.

void BEBrowserWindow::TabDraggingStatusChanged(bool is_dragging) {
}  // The app's tab strip drags.

void BEBrowserWindow::LinkOpeningFromGesture(
    WindowOpenDisposition disposition) {}  // Nothing to animate.

void BEBrowserWindow::FocusAppMenu() {}  // Not used on the Mac.

bool BEBrowserWindow::IsTabStripEditable() const {
  return true;
}

void BEBrowserWindow::DisableTabStripEditingForTesting() {}  // Tests only.

bool BEBrowserWindow::IsToolbarVisible() const {
  return true;  // The app always shows its bar in normal windows.
}

bool BEBrowserWindow::IsToolbarShowing() const {
  return !IsFullscreen();
}

bool BEBrowserWindow::IsLocationBarVisible() const {
  return true;
}

void BEBrowserWindow::ShowUpdateChromeDialog() {}  // Updates are ours.

void BEBrowserWindow::ShowIntentPickerBubble(
    std::vector<apps::IntentPickerAppInfo> app_info,
    bool show_stay_in_chrome,
    bool show_remember_selection,
    apps::IntentPickerBubbleType bubble_type,
    const std::optional<url::Origin>& initiating_origin,
    IntentPickerResponse callback) {
  NOTIMPLEMENTED_LOG_ONCE();  // "Open in app" picker; not for milestone 1.
}

void BEBrowserWindow::ShowBookmarkBubble(const GURL& url,
                                         bool already_bookmarked) {
  NOTIMPLEMENTED_LOG_ONCE();  // Bookmarks are milestone 2.
}

ShowTranslateBubbleResult BEBrowserWindow::ShowTranslateBubble(
    content::WebContents* contents,
    translate::TranslateStep step,
    const std::string& source_language,
    const std::string& target_language,
    translate::TranslateErrors error_type,
    bool is_user_gesture) {
  return ShowTranslateBubbleResult::kBrowserWindowNotValid;  // As Webium.
}

DownloadBubbleUIController* BEBrowserWindow::GetDownloadBubbleUIController() {
  return nullptr;  // "Null if the download toolbar button does not exist."
}

void BEBrowserWindow::ConfirmBrowserCloseWithPendingDownloads(
    int download_count,
    DownloadCloseType dialog_type,
    base::OnceCallback<void(bool)> callback) {
  // Chrome's own Views dialog, parented to our NSWindow, as BrowserView does.
  // It runs `callback` (true: cancel the downloads and close).
  DownloadInProgressDialogView::Show(GetNativeWindow(), download_count,
                                     dialog_type, std::move(callback));
}

void BEBrowserWindow::ShowAppMenu() {}  // The app's main menu.

void BEBrowserWindow::PreHandleDragUpdate(const content::DropData& drop_data,
                                          const gfx::PointF& point) {
}  // No drop targets of Chrome's over the page.

void BEBrowserWindow::PreHandleDragExit() {}

void BEBrowserWindow::HandleDragEnded() {}

content::KeyboardEventProcessingResult BEBrowserWindow::PreHandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  // Copied from WebUIBrowserWindow::PreHandleKeyboardEvent().
  if ((event.GetType() != blink::WebInputEvent::Type::kRawKeyDown) &&
      (event.GetType() != blink::WebInputEvent::Type::kKeyUp)) {
    return content::KeyboardEventProcessingResult::NOT_HANDLED;
  }

  ui::Accelerator accelerator =
      ui::GetAcceleratorFromNativeWebKeyboardEvent(event);

  int command_id;
  if (!FindCommandIdForAccelerator(accelerator, &command_id)) {
    return content::KeyboardEventProcessingResult::NOT_HANDLED;
  }

  // As BrowserView: a reserved shortcut runs now, before the page sees it.
  // On the Mac the reserved ones (⌘W, ⌘T...) are the app's menu items, so the
  // table's own (F12, F7, Esc) go to the page first and come back to
  // HandleKeyboardEvent() if it doesn't take them.
  if (chrome::BrowserCommandController::From(browser_)->IsReservedCommandOrKey(
          command_id, event)) {
    return accelerator_manager_.Process(accelerator)
               ? content::KeyboardEventProcessingResult::HANDLED
               : content::KeyboardEventProcessingResult::NOT_HANDLED;
  }
  return content::KeyboardEventProcessingResult::NOT_HANDLED_IS_SHORTCUT;
}

bool BEBrowserWindow::HandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  if (ShouldHandleKeyboardEvent(event)) {
    // On the Mac, shortcuts belong to the main menu, which is the app's: send
    // the key the page didn't take back through AppKit so the app's menu
    // items catch their key equivalents (as Webium and BrowserView do).
    if (views::NativeWidgetMacNSWindowHost::GetFromNativeWindow(
            GetNativeWindow())
            ->RedispatchKeyEvent(event.os_event.Get())) {
      return true;
    }
    // Then Chrome's own shortcuts the page left (see
    // PreHandleKeyboardEvent()).
    if (accelerator_manager_.Process(
            ui::GetAcceleratorFromNativeWebKeyboardEvent(event))) {
      return true;
    }
  }
  // Then accelerators registered with the widget's FocusManager (extension
  // commands), as BrowserView::HandleKeyboardEvent() does.
  return unhandled_keyboard_event_handler_.HandleKeyboardEvent(
      event, widget_->GetFocusManager());
}

std::unique_ptr<FindBar> BEBrowserWindow::CreateFindBar() {
  // Chrome's Views find bar over the page, owned by `find_bar_owner_`.
  return std::make_unique<FindBarHost>(FindBarOwner::From(browser_));
}

web_modal::WebContentsModalDialogHost*
BEBrowserWindow::GetWebContentsModalDialogHost() {
  return modal_dialog_host_.get();
}

web_modal::WebContentsModalDialogHost*
BEBrowserWindow::GetWebContentsModalDialogHostFor(
    content::WebContents* web_contents) {
  return modal_dialog_host_.get();
}

void BEBrowserWindow::ShowAvatarBubbleFromAvatarButton(
    bool is_source_accelerator) {}  // No avatar button.

void BEBrowserWindow::MaybeShowProfileSwitchIPH() {}  // No in-product help.

void BEBrowserWindow::MaybeShowSupervisedUserProfileSignInIPH() {
}  // No in-product help.

void BEBrowserWindow::ShowHatsDialog(
    const std::string& site_id,
    const std::optional<std::string>& hats_histogram_name,
    const std::optional<uint64_t> hats_survey_ukm_id,
    base::OnceClosure success_callback,
    base::OnceClosure failure_callback,
    const SurveyBitsData& product_specific_bits_data,
    const SurveyStringData& product_specific_string_data) {
  // No Google surveys. Say so, so the caller doesn't wait.
  if (failure_callback) {
    std::move(failure_callback).Run();
  }
}

ExclusiveAccessContext* BEBrowserWindow::GetExclusiveAccessContext() {
  return exclusive_access_context_.get();
}

std::string BEBrowserWindow::GetWorkspace() const {
  return widget_->GetWorkspace();
}

bool BEBrowserWindow::IsVisibleOnAllWorkspaces() const {
  return widget_->IsVisibleOnAllWorkspaces();
}

void BEBrowserWindow::ShowEmojiPanel() {
  ui::ShowEmojiPanel();
}

std::unique_ptr<content::EyeDropper> BEBrowserWindow::OpenEyeDropper(
    content::RenderFrameHost* frame,
    content::EyeDropperListener* listener) {
  NOTIMPLEMENTED_LOG_ONCE();  // Milestone 2 (Views' ShowEyeDropper()).
  return nullptr;
}

void BEBrowserWindow::ShowCaretBrowsingDialog() {
  NOTIMPLEMENTED_LOG_ONCE();  // Milestone 2.
}

void BEBrowserWindow::CreateTabSearchBubble() {}  // The app's own tab search.

void BEBrowserWindow::CloseTabSearchBubble() {}

void BEBrowserWindow::ShowIncognitoClearBrowsingDataDialog() {
  NOTIMPLEMENTED_LOG_ONCE();  // Milestone 2.
}

void BEBrowserWindow::ShowIncognitoHistoryDisclaimerDialog() {
  NOTIMPLEMENTED_LOG_ONCE();  // Milestone 2.
}

bool BEBrowserWindow::IsUnframedModeEnabled() const {
  return false;  // Isolated web apps only.
}

bool BEBrowserWindow::GetCanResize() {
  return widget_delegate_->CanResize();
}

ui::mojom::WindowShowState BEBrowserWindow::GetWindowShowState() const {
  if (IsMaximized()) {
    return ui::mojom::WindowShowState::kMaximized;
  }
  if (IsMinimized()) {
    return ui::mojom::WindowShowState::kMinimized;
  }
  if (IsFullscreen()) {
    return ui::mojom::WindowShowState::kFullscreen;
  }
  return ui::mojom::WindowShowState::kDefault;
}

void BEBrowserWindow::ShowChromeLabs() {}  // No Chrome Labs button.

BrowserView* BEBrowserWindow::AsBrowserView() {
  return nullptr;  // The point of this class.
}

// ui::BaseWindow --------------------------------------------------------------

bool BEBrowserWindow::IsActive() const {
  return widget_->IsActive();
}

bool BEBrowserWindow::IsMaximized() const {
  return widget_->IsMaximized();
}

bool BEBrowserWindow::IsMinimized() const {
  return widget_->IsMinimized();
}

bool BEBrowserWindow::IsFullscreen() const {
  return widget_->IsFullscreen();
}

gfx::Rect BEBrowserWindow::GetRestoredBounds() const {
  return widget_->GetRestoredBounds();
}

ui::mojom::WindowShowState BEBrowserWindow::GetRestoredState() const {
  // What session restore brings the window back as; Mac windows come back
  // zoomed or not (Webium returns kDefault).
  return IsMaximized() ? ui::mojom::WindowShowState::kMaximized
                       : ui::mojom::WindowShowState::kDefault;
}

gfx::Rect BEBrowserWindow::GetBounds() const {
  return widget_->GetWindowBoundsInScreen();
}

void BEBrowserWindow::Show() {
  // Copied from WebUIBrowserWindow::Show() (itself from BrowserView): the
  // browser must count as the active one when Show() returns, not only when
  // AppKit activates the window on the next run loop turn, or
  // GetLastActive() would be wrong for whoever asks next.
  BrowserActiveStateManager::From(browser_)->DidBecomeActive();

  if (widget_->IsVisible()) {
    widget_->Activate();
    return;
  }
  widget_->Show();
}

void BEBrowserWindow::Hide() {
  widget_->Hide();
}

bool BEBrowserWindow::IsVisible() const {
  return widget_->IsVisible();
}

void BEBrowserWindow::ShowInactive() {
  if (!widget_->IsVisible()) {
    widget_->ShowInactive();
  }
}

void BEBrowserWindow::Close() {
  // Not immediate: the close request comes back to OnWindowCloseRequested(),
  // where unload handlers can stop it. When the tabs are gone Chrome calls
  // Close() again, the Browser is deleted, and the widget goes with us.
  widget_->Close();
}

void BEBrowserWindow::Activate() {
  widget_->Activate();
}

void BEBrowserWindow::Deactivate() {
  widget_->Deactivate();
}

void BEBrowserWindow::Maximize() {
  widget_->Maximize();
}

void BEBrowserWindow::Minimize() {
  widget_->Minimize();
}

void BEBrowserWindow::Restore() {
  widget_->Restore();
}

void BEBrowserWindow::SetBounds(const gfx::Rect& bounds) {
  widget_->SetBounds(bounds);
}

void BEBrowserWindow::FlashFrame(bool flash) {
  widget_->FlashFrame(flash);
}

ui::ZOrderLevel BEBrowserWindow::GetZOrderLevel() const {
  return widget_->GetZOrderLevel();
}

void BEBrowserWindow::SetZOrderLevel(ui::ZOrderLevel order) {
  widget_->SetZOrderLevel(order);
}

// TabStripModelObserver -------------------------------------------------------

void BEBrowserWindow::OnTabStripModelChanged(
    TabStripModel* tab_strip_model,
    const TabStripModelChange& change,
    const TabStripSelectionChange& selection) {
  [objc_window_ tabStripModelChanged:change selection:selection];
}

void BEBrowserWindow::OnTabChangedAt(tabs::TabInterface* tab,
                                     TabChangeType change_type) {
  // Chrome's own coalesced "this tab's title/loading/URL changed".
  [[BEChromiumTab existingTabForTab:tab] scheduleUpdate];
}

// ui::AcceleratorProvider -----------------------------------------------------

bool BEBrowserWindow::GetAcceleratorForCommandId(
    int command_id,
    ui::Accelerator* accelerator) const {
  // Copied from WebUIBrowserWindow.
  if (GetDefaultMacAcceleratorForCommandId(command_id, accelerator)) {
    return true;
  }
  for (const auto& entry : accelerator_table_) {
    if (entry.second == command_id) {
      *accelerator = entry.first;
      return true;
    }
  }
  return false;
}

// ui::AcceleratorTarget -------------------------------------------------------

bool BEBrowserWindow::AcceleratorPressed(const ui::Accelerator& accelerator) {
  int command_id;
  if (!FindCommandIdForAccelerator(accelerator, &command_id)) {
    return false;
  }
  return chrome::ExecuteCommand(browser_, command_id,
                                accelerator.time_stamp());
}

bool BEBrowserWindow::CanHandleAccelerators() const {
  return true;
}

// views::WidgetObserver -------------------------------------------------------

void BEBrowserWindow::OnWidgetBoundsChanged(views::Widget* widget,
                                            const gfx::Rect& new_bounds) {
  DCHECK_EQ(widget, widget_.get());
  if (modal_dialog_host_) {
    modal_dialog_host_->NotifyPositionRequiresUpdate();
  }
}

void BEBrowserWindow::OnWidgetShowStateChanged(views::Widget* widget) {
  // The window's own fullscreen button (or ⌃⌘F from the app's menu through
  // AppKit) changes the state without Chrome asking; tell Chrome as
  // BrowserView does, once. NativeWidgetMac reports the end of every
  // fullscreen transition here (native_widget_mac_ns_window_host.mm,
  // OnWindowFullscreenTransitionComplete()).
  const bool fullscreen = widget_->IsFullscreen();
  if (fullscreen == fullscreen_) {
    return;
  }
  fullscreen_ = fullscreen;
  if (ExclusiveAccessManager* manager = ExclusiveAccessManager::From(browser_)) {
    manager->fullscreen_controller()->WindowFullscreenStateChanged();
  }
}

// Private ---------------------------------------------------------------------

bool BEBrowserWindow::FindCommandIdForAccelerator(
    const ui::Accelerator& accelerator,
    int* command_id) const {
  auto iter = accelerator_table_.find(accelerator);
  if (iter == accelerator_table_.end()) {
    return false;
  }
  *command_id = iter->second;
  if (accelerator.IsRepeat() && !IsCommandRepeatable(*command_id)) {
    return false;
  }
  return true;
}

void BEBrowserWindow::LoadAccelerators() {
  // Copied from WebUIBrowserWindow::LoadAccelerators(), without ChromeOS.
  const bool is_app_mode = IsRunningInForcedAppMode();
  for (const auto& entry : GetAcceleratorList()) {
    if (is_app_mode &&
        !IsCommandAllowedInAppMode(
            entry.command_id,
            browser_->GetType() == BrowserWindowInterface::Type::TYPE_POPUP)) {
      continue;
    }
    ui::Accelerator accelerator(entry.keycode, entry.modifiers);
    accelerator_table_[accelerator] = entry.command_id;
    accelerator_manager_.Register(
        {accelerator}, ui::AcceleratorManager::kNormalPriority, this);
  }
}

views::NativeWidget* BEBrowserWindow::CreateNativeWidget() {
  return new BENativeWidgetMac(browser_.get(), widget_.get());
}

void BEBrowserWindow::PaintAsActiveChanged() {
  // Copied from WebUIBrowserWindow::PaintAsActiveChanged() (from
  // BrowserView): this is what makes the browser the "last active" one that
  // commands, extensions and new tabs go to.
  if (widget_->ShouldPaintAsActive()) {
    BrowserActiveStateManager::From(browser_)->DidBecomeActive();
  } else {
    BrowserActiveStateManager::From(browser_)->DidBecomeInactive();
  }
}

void BEBrowserWindow::OnWindowCloseRequested(
    views::Widget::ClosedReason close_reason) {
  // From WebUIBrowserWindow::OnWindowCloseRequested(), with one change: the
  // synchronous close callback is used up by each Close(), and we take it
  // again every time, not only when the close is refused. Chrome calls Close()
  // a second time once the tabs are gone (Browser::TabStripEmpty()); routing
  // that one here too is what reaches UnloadController's
  // OnWindowCloseComplete(), which schedules the Browser's deletion, which
  // deletes us and, with us, the widget (CLIENT_OWNS_WIDGET). The NSWindow
  // never closes behind Chrome's back.
  // UNVERIFIED: Webium re-arms only when refused, and its second Close()
  // reaches the native window; that the second Close() must come back here
  // for OnWindowCloseComplete() is read from unload_controller.cc, not run.
  widget_->MakeCloseSynchronous(base::BindOnce(
      &BEBrowserWindow::OnWindowCloseRequested, base::Unretained(this)));

  // Give beforeunload handlers, the user, or policy the chance to cancel the
  // close before we hide the window below.
  if (!UnloadController::From(browser_)->HandleBeforeClose()) {
    return;
  }

  UnloadController::From(browser_)->OnWindowClosing();
  if (!browser_->GetTabStripModel()->empty()) {
    // Hide the window so it looks closed at once while the tabs close and
    // their renderers shut down; when the strip is empty we're called again.
    widget_->Hide();
  }
}

}  // namespace browser_engine
