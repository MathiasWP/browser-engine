// Our BrowserWindow: Chrome's third production window implementation, after
// BrowserView and Webium's WebUIBrowserWindow (whose shape this follows at
// M156). Chrome makes a views::Widget, and so an NSWindow, for the window as it
// does for Webium; the app's root NSView fills it, and the app puts each tab's
// page view where it wants it. Everything Chrome asks of its window lands here,
// and what the app must hear goes out through BEChromiumWindow.

#ifndef BROWSER_ENGINE_BE_BROWSER_WINDOW_H_
#define BROWSER_ENGINE_BE_BROWSER_WINDOW_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/callback_list.h"
#include "base/memory/raw_ptr.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/accelerators/accelerator_manager.h"
#include "ui/views/controls/webview/unhandled_keyboard_event_handler.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"

@class BEChromiumWindow;
@class NSView;

namespace views {
class NativeViewHost;
class NativeWidget;
}  // namespace views

namespace browser_engine {

class BEExclusiveAccessContext;
class BEFindBarOwner;
class BELocationBar;
class BEModalDialogHost;

class BEBrowserWindow : public BrowserWindow,
                        public TabStripModelObserver,
                        public ui::AcceleratorProvider,
                        public ui::AcceleratorTarget,
                        public views::WidgetObserver {
 public:
  explicit BEBrowserWindow(BrowserWindowInterface* browser);
  BEBrowserWindow(const BEBrowserWindow&) = delete;
  BEBrowserWindow& operator=(const BEBrowserWindow&) = delete;
  ~BEBrowserWindow() override;

  // Our window for `browser`, or null if `browser` has another kind (found
  // through a property on the widget's NSWindow, as Webium does).
  static BEBrowserWindow* FromBrowser(const BrowserWindowInterface* browser);

  BrowserWindowInterface* browser() const { return browser_; }
  views::Widget* widget() const { return widget_.get(); }

  // From the embedder hook, once `browser` is fully constructed: makes the
  // Objective-C window and hands it to the app, before any tab or Show().
  void OnBrowserInitialized();

  // The app's root view; it fills the window. Call once, before pages show:
  // views::NativeViewHost refuses to attach a view with child widgets in it.
  void SetContentView(NSView* view);

  // Where the active page is on screen (the app decides), or the window's
  // client area while no page is in the window.
  gfx::Rect GetContentsBoundsInScreen() const;

  // Enters or leaves fullscreen for Chrome's ExclusiveAccessManager.
  void ProcessFullscreen(bool fullscreen);

  // The location bar or Chrome asked for the address field to take focus.
  void RequestLocationFocus();

  // BrowserWindow:
  gfx::NativeWindow GetNativeWindow() const override;
  bool IsOnCurrentWorkspace() const override;
  bool IsVisibleOnScreen() const override;
  void SetTopControlsShownRatio(content::WebContents* web_contents,
                                float ratio) override;
  bool DoBrowserControlsShrinkRendererSize(
      const content::WebContents* contents) const override;
  ui::NativeTheme* GetNativeTheme() override;
  const ui::ThemeProvider* GetThemeProvider() const override;
  const ui::ColorProvider* GetColorProvider() const override;
  int GetTopControlsHeight() const override;
  void SetTopControlsGestureScrollInProgress(bool in_progress) override;
  std::vector<StatusBubble*> GetStatusBubbles() override;
  void UpdateTitleBar() override;
  void UpdateLoadingAnimations(bool is_visible) override;
  void OnActiveTabChanged(content::WebContents* old_contents,
                          content::WebContents* new_contents,
                          int index,
                          int reason) override;
  void OnTabDetached(content::WebContents* contents, bool was_active) override;
  gfx::Size GetContentsSize() const override;
  void SetContentsSize(const gfx::Size& size) override;
  autofill::AutofillBubbleHandler* GetAutofillBubbleHandler() override;
  LocationBar* GetLocationBar() const override;
  ui::AcceleratorProvider* GetAcceleratorProvider() override;
  PinnedToolbarActions* GetPinnedToolbarActions() override;
  void SetFocusToLocationBar(bool is_user_initiated) override;
  void UpdateReloadStopState(bool is_loading, bool force) override;
  void UpdateToolbar(content::WebContents* contents) override;
  bool UpdateToolbarSecurityState() override;
  void UpdateCustomTabBarVisibility(bool visible, bool animate) override;
  void ResetToolbarTabState(content::WebContents* contents) override;
  void FocusToolbar() override;
  void ToolbarSizeChanged(bool is_animating) override;
  void TabDraggingStatusChanged(bool is_dragging) override;
  void LinkOpeningFromGesture(WindowOpenDisposition disposition) override;
  void FocusAppMenu() override;
  bool IsTabStripEditable() const override;
  void DisableTabStripEditingForTesting() override;
  bool IsToolbarVisible() const override;
  bool IsToolbarShowing() const override;
  bool IsLocationBarVisible() const override;
  void ShowUpdateChromeDialog() override;
  void ShowIntentPickerBubble(
      std::vector<apps::IntentPickerAppInfo> app_info,
      bool show_stay_in_chrome,
      bool show_remember_selection,
      apps::IntentPickerBubbleType bubble_type,
      const std::optional<url::Origin>& initiating_origin,
      IntentPickerResponse callback) override;
  void ShowBookmarkBubble(const GURL& url, bool already_bookmarked) override;
  ShowTranslateBubbleResult ShowTranslateBubble(
      content::WebContents* contents,
      translate::TranslateStep step,
      const std::string& source_language,
      const std::string& target_language,
      translate::TranslateErrors error_type,
      bool is_user_gesture) override;
  DownloadBubbleUIController* GetDownloadBubbleUIController() override;
  void ConfirmBrowserCloseWithPendingDownloads(
      int download_count,
      DownloadCloseType dialog_type,
      base::OnceCallback<void(bool)> callback) override;
  void ShowAppMenu() override;
  void PreHandleDragUpdate(const content::DropData& drop_data,
                           const gfx::PointF& point) override;
  void PreHandleDragExit() override;
  void HandleDragEnded() override;
  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      const input::NativeWebKeyboardEvent& event) override;
  bool HandleKeyboardEvent(const input::NativeWebKeyboardEvent& event) override;
  std::unique_ptr<FindBar> CreateFindBar() override;
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost()
      override;
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHostFor(
      content::WebContents* web_contents) override;
  void ShowAvatarBubbleFromAvatarButton(bool is_source_accelerator) override;
  void MaybeShowProfileSwitchIPH() override;
  void MaybeShowSupervisedUserProfileSignInIPH() override;
  void ShowHatsDialog(
      const std::string& site_id,
      const std::optional<std::string>& hats_histogram_name,
      const std::optional<uint64_t> hats_survey_ukm_id,
      base::OnceClosure success_callback,
      base::OnceClosure failure_callback,
      const SurveyBitsData& product_specific_bits_data,
      const SurveyStringData& product_specific_string_data) override;
  ExclusiveAccessContext* GetExclusiveAccessContext() override;
  std::string GetWorkspace() const override;
  bool IsVisibleOnAllWorkspaces() const override;
  void ShowEmojiPanel() override;
  std::unique_ptr<content::EyeDropper> OpenEyeDropper(
      content::RenderFrameHost* frame,
      content::EyeDropperListener* listener) override;
  void ShowCaretBrowsingDialog() override;
  void CreateTabSearchBubble() override;
  void CloseTabSearchBubble() override;
  void ShowIncognitoClearBrowsingDataDialog() override;
  void ShowIncognitoHistoryDisclaimerDialog() override;
  bool IsUnframedModeEnabled() const override;
  bool GetCanResize() override;
  ui::mojom::WindowShowState GetWindowShowState() const override;
  void ShowChromeLabs() override;
  BrowserView* AsBrowserView() override;

  // ui::BaseWindow:
  bool IsActive() const override;
  bool IsMaximized() const override;
  bool IsMinimized() const override;
  bool IsFullscreen() const override;
  gfx::Rect GetRestoredBounds() const override;
  ui::mojom::WindowShowState GetRestoredState() const override;
  gfx::Rect GetBounds() const override;
  void Show() override;
  void Hide() override;
  bool IsVisible() const override;
  void ShowInactive() override;
  void Close() override;
  void Activate() override;
  void Deactivate() override;
  void Maximize() override;
  void Minimize() override;
  void Restore() override;
  void SetBounds(const gfx::Rect& bounds) override;
  void FlashFrame(bool flash) override;
  ui::ZOrderLevel GetZOrderLevel() const override;
  void SetZOrderLevel(ui::ZOrderLevel order) override;

  // TabStripModelObserver:
  void OnTabStripModelChanged(
      TabStripModel* tab_strip_model,
      const TabStripModelChange& change,
      const TabStripSelectionChange& selection) override;
  void OnTabChangedAt(tabs::TabInterface* tab,
                      TabChangeType change_type) override;

  // ui::AcceleratorProvider:
  bool GetAcceleratorForCommandId(int command_id,
                                  ui::Accelerator* accelerator) const override;

  // views::WidgetObserver:
  void OnWidgetBoundsChanged(views::Widget* widget,
                             const gfx::Rect& new_bounds) override;
  void OnWidgetShowStateChanged(views::Widget* widget) override;

 protected:
  // BrowserWindow:
  void DeleteBrowserWindow() final;

 private:
  class WidgetDelegate;

  // ui::AcceleratorTarget:
  bool AcceleratorPressed(const ui::Accelerator& accelerator) override;
  bool CanHandleAccelerators() const override;

  // Webium's accelerator table: Chrome's reserved shortcuts (such as ⌘W) run
  // even when the page would take them.
  bool FindCommandIdForAccelerator(const ui::Accelerator& accelerator,
                                   int* command_id) const;
  void LoadAccelerators();

  // Creates the NativeWidgetMac subclass (be_browser_window.mm). The widget is
  // CLIENT_OWNS_WIDGET; the native widget frees itself.
  views::NativeWidget* CreateNativeWidget();

  // Called when the widget's ShouldPaintAsActive() changes, which (unlike
  // activation) stays true while a child widget such as a dialog has focus.
  void PaintAsActiveChanged();

  // The close button and Close() end up here (MakeCloseSynchronous): pages
  // may still ask to stay.
  void OnWindowCloseRequested(views::Widget::ClosedReason close_reason);

  const raw_ptr<BrowserWindowInterface> browser_;

  // Declared before `widget_`, which must be destroyed first.
  std::unique_ptr<WidgetDelegate> widget_delegate_;
  std::unique_ptr<views::Widget> widget_;

  // The widget's client contents view; hosts the app's root NSView.
  raw_ptr<views::NativeViewHost> host_ = nullptr;

  // The app's root view (strong, ARC).
  NSView* __strong content_view_ = nil;

  // What the app holds (strong, ARC). Made in OnBrowserInitialized().
  BEChromiumWindow* __strong objc_window_ = nil;

  std::unique_ptr<BELocationBar> location_bar_;
  std::unique_ptr<BEModalDialogHost> modal_dialog_host_;
  std::unique_ptr<BEExclusiveAccessContext> exclusive_access_context_;
  std::unique_ptr<BEFindBarOwner> find_bar_owner_;

  // Command ids for accelerators, from chrome/browser/ui/accelerator_table.h.
  std::map<ui::Accelerator, int> accelerator_table_;
  ui::AcceleratorManager accelerator_manager_;

  // Runs accelerators registered with the widget's FocusManager (extension
  // commands, find bar keys) for keys the page and the menu didn't take, as
  // BrowserView does.
  views::UnhandledKeyboardEventHandler unhandled_keyboard_event_handler_;

  base::CallbackListSubscription paint_as_active_subscription_;

  // The last fullscreen state Chrome heard about, so the window's own
  // fullscreen button and Chrome's requests tell Chrome exactly once.
  bool fullscreen_ = false;
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_BROWSER_WINDOW_H_
