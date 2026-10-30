#include "browser_engine/be_browser_window_parts.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/notimplemented.h"
#include "base/task/single_thread_task_runner.h"
#include "browser_engine/be_browser_window.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/find_bar/find_bar_controller.h"
#include "chrome/browser/ui/fullscreen/browser_window_fullscreen_controller.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "chrome/browser/ui/views/exclusive_access/exclusive_access_bubble_views.h"
#include "chrome/browser/ui/views/translate/translate_bubble_controller.h"
#include "chrome/browser/ui/window_metadata/window_metadata_controller.h"
#include "components/strings/grit/components_strings.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/display/types/display_constants.h"
#include "ui/gfx/native_ui_util.h"
#include "ui/views/bubble/bubble_anchor.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/client_view.h"

namespace browser_engine {

// BELocationBar ---------------------------------------------------------------

BELocationBar::BELocationBar(BEBrowserWindow* window)
    : LocationBar(chrome::BrowserCommandController::From(window->browser())),
      window_(window) {}

BELocationBar::~BELocationBar() = default;

void BELocationBar::FocusLocation(bool is_user_initiated,
                                  bool clear_focus_if_failed) {
  window_->RequestLocationFocus();
}

void BELocationBar::FocusSearch() {
  // Keyword mode is the app's business (milestone 2); focusing is the part
  // Chrome expects to see.
  window_->RequestLocationFocus();
}

void BELocationBar::UpdateFocusBehavior(bool toolbar_visible) {}  // No toolbar.

void BELocationBar::UpdateContentSettingsIcons() {}  // Milestone 2.

void BELocationBar::SaveStateToContents(content::WebContents* contents) {
}  // The app keeps per-tab edit state.

void BELocationBar::Revert() {}  // The app owns the text.

OmniboxView* BELocationBar::GetOmniboxView() {
  return nullptr;  // No Chrome omnibox; callers check.
}

OmniboxPopupView* BELocationBar::GetOmniboxPopupView() {
  return nullptr;
}

OmniboxController* BELocationBar::GetOmniboxController() {
  return nullptr;  // Milestone 2 drives Chrome's OmniboxController itself.
}

bool BELocationBar::ShouldCloseOmniboxPopup(ui::MouseEvent* event) {
  return false;
}

content::WebContents* BELocationBar::GetWebContents() {
  return window_->browser()->GetTabStripModel()->GetActiveWebContents();
}

LocationBarModel* BELocationBar::GetLocationBarModel() {
  return nullptr;  // Webium returns null too.
}

std::optional<bubble_anchor_util::AnchorConfiguration>
BELocationBar::GetChipAnchor() {
  // Never empty: GetPageInfoAnchorConfiguration() (bubble_anchor_util_views.cc)
  // takes this for location-bar-anchored bubbles (permission prompts, page
  // info, choosers) and otherwise dereferences the BrowserView we don't have.
  // A null anchor crashes too (GetPageInfoAnchorRect()), so the bubbles float
  // centered over the window until the app tells us where its field is.
  return bubble_anchor_util::AnchorConfiguration{
      views::BubbleAnchor(window_->widget()->client_view()), std::nullopt,
      views::BubbleBorder::FLOAT};
}

ChipController* BELocationBar::GetChipController() {
  return nullptr;  // Null-checked on the bubble path; see the class comment.
}

void BELocationBar::AnnounceAlert(const std::u16string& announcement) {
  NOTIMPLEMENTED_LOG_ONCE();  // Milestone 2: pass to the app's field.
}

void BELocationBar::OnChanged() {}

void BELocationBar::UpdateWithoutTabRestore() {}

ui::TrackedElement* BELocationBar::GetAnchorOrNull() {
  return nullptr;  // Bubbles fall back to the window.
}

BrowserWindowInterface* BELocationBar::GetBrowser() {
  return window_->browser();
}

Profile* BELocationBar::GetProfile() {
  return window_->browser()->GetProfile();
}

bool BELocationBar::IsInitialized() const {
  return true;
}

bool BELocationBar::IsVisible() const {
  return true;  // The app always shows an address field.
}

bool BELocationBar::IsDrawn() const {
  // Chrome draws nothing here; false keeps Chrome's permission chip and other
  // location-bar-anchored UI off (see the class comment).
  return false;
}

bool BELocationBar::IsFullscreen() const {
  return window_->IsFullscreen();
}

bool BELocationBar::IsEditingOrEmpty() const {
  return false;  // Milestone 2: ask the app.
}

bool BELocationBar::IsMouseHovered() const {
  return false;
}

bool BELocationBar::IsFocusWithin() const {
  return false;  // Milestone 2: ask the app.
}

void BELocationBar::InvalidateLayout() {}

gfx::Rect BELocationBar::Bounds() const {
  return gfx::Rect();
}

gfx::Rect BELocationBar::BoundsInScreen() const {
  return gfx::Rect();
}

gfx::Size BELocationBar::MinimumSize() const {
  return gfx::Size();
}

gfx::Size BELocationBar::PreferredSize() const {
  return gfx::Size();
}

void BELocationBar::Update(content::WebContents* contents) {}  // BETab tells.

void BELocationBar::ResetTabState(content::WebContents* contents) {}

bool BELocationBar::HasSecurityStateChanged() {
  return false;  // BETab reports security with every update.
}

LocationBarTesting* BELocationBar::GetLocationBarForTesting() {
  return nullptr;
}

// BEExclusiveAccessContext ----------------------------------------------------

BEExclusiveAccessContext::BEExclusiveAccessContext(BEBrowserWindow* window)
    : window_(window) {}

BEExclusiveAccessContext::~BEExclusiveAccessContext() = default;

Profile* BEExclusiveAccessContext::GetProfile() {
  return window_->browser()->GetProfile();
}

bool BEExclusiveAccessContext::IsFullscreen() const {
  return window_->widget()->IsFullscreen();
}

void BEExclusiveAccessContext::EnterFullscreen(
    const url::Origin& origin,
    ExclusiveAccessBubbleType bubble_type,
    FullscreenTabParams fullscreen_tab_params) {
  const int64_t display_id = fullscreen_tab_params.display_id;
  if (IsFullscreen() && display_id == display::kInvalidDisplayId) {
    return;
  }
  window_->ProcessFullscreen(true);
}

void BEExclusiveAccessContext::ExitFullscreen() {
  if (BrowserWindowFullscreenController::From(window_->browser())
          ->IsForceFullscreen()) {
    return;
  }
  if (!IsFullscreen()) {
    return;
  }
  window_->ProcessFullscreen(false);
}

void BEExclusiveAccessContext::UpdateExclusiveAccessBubble(
    const ExclusiveAccessBubbleParams& params,
    ExclusiveAccessBubbleHideCallback first_hide_callback) {
  // Copied from WebUIBrowserExclusiveAccessContext.
  bool should_close_bubble = false;
  if (!params.has_download) {
    // ...TYPE_NONE indicates deleting the bubble, except when used with
    // download.
    should_close_bubble = params.type == EXCLUSIVE_ACCESS_BUBBLE_TYPE_NONE;
  }

  if (should_close_bubble) {
    if (first_hide_callback) {
      std::move(first_hide_callback)
          .Run(ExclusiveAccessBubbleHideReason::kNotShown);
    }
    if (!exclusive_access_bubble_) {
      return;
    }
    if (exclusive_access_bubble_destruction_task_id_) {
      return;
    }
    exclusive_access_bubble_->HideImmediately();
    // Destroy asynchronously: the bubble may call back in here while it
    // updates (crbug.com/40063714).
    exclusive_access_bubble_destruction_task_id_ =
        exclusive_access_bubble_cancelable_task_tracker_.PostTask(
            base::SingleThreadTaskRunner::GetCurrentDefault().get(), FROM_HERE,
            base::BindOnce(
                &BEExclusiveAccessContext::DestroyAnyExclusiveAccessBubble,
                weak_ptr_factory_.GetWeakPtr()));
    return;
  }

  if (exclusive_access_bubble_) {
    if (exclusive_access_bubble_destruction_task_id_) {
      exclusive_access_bubble_cancelable_task_tracker_.TryCancel(
          exclusive_access_bubble_destruction_task_id_.value());
      exclusive_access_bubble_destruction_task_id_.reset();
    }
    exclusive_access_bubble_->Update(params, std::move(first_hide_callback));
    return;
  }

  exclusive_access_bubble_ = std::make_unique<ExclusiveAccessBubbleViews>(
      this, params, std::move(first_hide_callback));
}

bool BEExclusiveAccessContext::IsExclusiveAccessBubbleDisplayed() const {
  return exclusive_access_bubble_ && (exclusive_access_bubble_->IsShowing() ||
                                      exclusive_access_bubble_->IsVisible());
}

void BEExclusiveAccessContext::OnExclusiveAccessUserInput() {
  if (exclusive_access_bubble_) {
    exclusive_access_bubble_->OnUserInput();
  }
}

content::WebContents*
BEExclusiveAccessContext::GetWebContentsForExclusiveAccess() {
  return window_->browser()->GetTabStripModel()->GetActiveWebContents();
}

bool BEExclusiveAccessContext::CanUserEnterFullscreen() const {
  return true;
}

bool BEExclusiveAccessContext::CanUserExitFullscreen() const {
  return true;
}

ExclusiveAccessManager* BEExclusiveAccessContext::GetExclusiveAccessManager() {
  // Made in InitPostWindowConstruction, after this object.
  ExclusiveAccessManager* manager =
      ExclusiveAccessManager::From(window_->browser());
  DCHECK(manager);
  return manager;
}

ui::AcceleratorProvider* BEExclusiveAccessContext::GetAcceleratorProvider() {
  return window_.get();
}

gfx::NativeView BEExclusiveAccessContext::GetBubbleParentView() const {
  return window_->widget()->GetNativeView();
}

gfx::Rect BEExclusiveAccessContext::GetClientAreaBoundsInScreen() const {
  return window_->widget()->GetClientAreaBoundsInScreen();
}

bool BEExclusiveAccessContext::IsImmersiveModeEnabled() const {
  return false;  // Immersive fullscreen is BrowserView's.
}

gfx::Rect BEExclusiveAccessContext::GetTopContainerBoundsInScreen() {
  return gfx::Rect();  // The app's bar isn't a Views top container.
}

void BEExclusiveAccessContext::DestroyAnyExclusiveAccessBubble() {
  exclusive_access_bubble_.reset();
  exclusive_access_bubble_destruction_task_id_.reset();
}

// BEModalDialogHost -----------------------------------------------------------

BEModalDialogHost::BEModalDialogHost(BEBrowserWindow* window)
    : window_(window) {}

BEModalDialogHost::~BEModalDialogHost() {
  observers_.Notify(&web_modal::ModalDialogHostObserver::OnHostDestroying);
}

void BEModalDialogHost::NotifyPositionRequiresUpdate() {
  observers_.Notify(
      &web_modal::ModalDialogHostObserver::OnPositionRequiresUpdate);
}

gfx::NativeView BEModalDialogHost::GetHostView() const {
  return gfx::GetViewForWindow(window_->GetNativeWindow());
}

gfx::Point BEModalDialogHost::GetDialogPosition(const gfx::Size& size) {
  // Centered at the top of the page area, as Webium does.
  gfx::Rect contents_bounds = window_->GetContentsBoundsInScreen();
  const gfx::Rect window_bounds = window_->GetBounds();
  contents_bounds -= window_bounds.OffsetFromOrigin();
  return gfx::Point(
      contents_bounds.x() + (contents_bounds.width() - size.width()) / 2,
      contents_bounds.y() - 10);
}

bool BEModalDialogHost::ShouldActivateDialog() const {
  return GlobalBrowserCollection::GetInstance()->GetLastActiveBrowser() ==
         window_->browser();
}

gfx::Size BEModalDialogHost::GetMaximumDialogSize() {
  return window_->GetContentsBoundsInScreen().size();
}

void BEModalDialogHost::AddObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.AddObserver(observer);
}

void BEModalDialogHost::RemoveObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.RemoveObserver(observer);
}

// BEFindBarOwner --------------------------------------------------------------

BEFindBarOwner::BEFindBarOwner(BEBrowserWindow* window,
                               ui::UnownedUserDataHost& host)
    : FindBarOwner(host), window_(window) {}

BEFindBarOwner::~BEFindBarOwner() = default;

views::Widget* BEFindBarOwner::GetOwnerWidget() {
  return window_->widget();
}

gfx::Rect BEFindBarOwner::GetFindBarBoundingBox() {
  // The page area, in the widget's coordinates; FindBarHost puts the bar at
  // its top right.
  return window_->GetContentsBoundsInScreen() -
         window_->widget()->GetWindowBoundsInScreen().OffsetFromOrigin();
}

gfx::Rect BEFindBarOwner::GetFindBarClippingBox() {
  return window_->widget()->client_view()->bounds();
}

bool BEFindBarOwner::IsOffTheRecord() const {
  return window_->browser()->GetProfile()->IsOffTheRecord();
}

views::Widget* BEFindBarOwner::GetWidgetForAnchoring() {
  return window_->widget();
}

std::u16string BEFindBarOwner::GetFindBarAccessibleWindowTitle() {
  return l10n_util::GetStringFUTF16(
      IDS_FIND_IN_PAGE_ACCESSIBLE_TITLE,
      WindowMetadataController::From(window_->browser())
          ->GetWindowTitleForCurrentTab(false));
}

void BEFindBarOwner::OnFindBarVisibilityChanged(gfx::Rect visible_bounds) {
  FindBarController::From(window_->browser())->OnFindBarVisibilityChanged();
}

void BEFindBarOwner::CloseOverlappingBubbles() {
  if (TranslateBubbleController* controller =
          TranslateBubbleController::From(window_->browser())) {
    controller->CloseBubble();
  }
}

}  // namespace browser_engine
