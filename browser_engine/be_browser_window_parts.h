// The objects Chrome asks our BrowserWindow for and expects never to be null:
// a location bar, an exclusive-access (fullscreen) context, a host for
// tab-modal dialogs and the owner of Chrome's find bar. Each is a copy of
// Webium's at M156 (chrome/browser/ui/webui_browser/), pointed at our window
// instead of the WebUI one. The autofill bubble handler and the status bubble
// are ours: Webium has neither.

#ifndef BROWSER_ENGINE_BE_BROWSER_WINDOW_PARTS_H_
#define BROWSER_ENGINE_BE_BROWSER_WINDOW_PARTS_H_

#include <memory>
#include <optional>
#include <string>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/task/cancelable_task_tracker.h"
#include "chrome/browser/ui/autofill/autofill_bubble_handler.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_context.h"
#include "chrome/browser/ui/location_bar/location_bar.h"
#include "chrome/browser/ui/status_bubble.h"
#include "chrome/browser/ui/views/exclusive_access/exclusive_access_bubble_views_context.h"
#include "chrome/browser/ui/views/find_bar_owner.h"
#include "components/signin/public/base/signin_buildflags.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "ui/base/unowned_user_data/scoped_unowned_user_data.h"

class BrowserWindowInterface;
class ExclusiveAccessBubbleViews;
class GURL;

namespace browser_engine {

class BEBrowserWindow;

// The app draws the address field; this tells it when Chrome wants focus
// there and answers Chrome's questions with "no omnibox here". Unlike
// Webium's stub it has no permission chip: IsDrawn() is false, so permission
// requests take the bubble path (chrome/browser/ui/views/permissions/
// permission_prompt_factory.cc), which null-checks GetChipController() and
// anchors to GetChipAnchor() (see there).
class BELocationBar : public LocationBar {
 public:
  explicit BELocationBar(BEBrowserWindow* window);
  BELocationBar(const BELocationBar&) = delete;
  BELocationBar& operator=(const BELocationBar&) = delete;
  ~BELocationBar() override;

  // LocationBar:
  void FocusLocation(bool is_user_initiated,
                     bool clear_focus_if_failed) override;
  void FocusSearch() override;
  void UpdateFocusBehavior(bool toolbar_visible) override;
  void UpdateContentSettingsIcons() override;
  void SaveStateToContents(content::WebContents* contents) override;
  void Revert() override;
  OmniboxView* GetOmniboxView() override;
  OmniboxPopupView* GetOmniboxPopupView() override;
  OmniboxController* GetOmniboxController() override;
  bool ShouldCloseOmniboxPopup(ui::MouseEvent* event) override;
  content::WebContents* GetWebContents() override;
  LocationBarModel* GetLocationBarModel() override;
  std::optional<bubble_anchor_util::AnchorConfiguration> GetChipAnchor()
      override;
  ChipController* GetChipController() override;
  void AnnounceAlert(const std::u16string& announcement) override;
  void OnChanged() override;
  void UpdateWithoutTabRestore() override;
  ui::TrackedElement* GetAnchorOrNull() override;
  BrowserWindowInterface* GetBrowser() override;
  Profile* GetProfile() override;
  bool IsInitialized() const override;
  bool IsVisible() const override;
  bool IsDrawn() const override;
  bool IsFullscreen() const override;
  bool IsEditingOrEmpty() const override;
  bool IsMouseHovered() const override;
  bool IsFocusWithin() const override;
  void InvalidateLayout() override;
  gfx::Rect Bounds() const override;
  gfx::Rect BoundsInScreen() const override;
  gfx::Size MinimumSize() const override;
  gfx::Size PreferredSize() const override;
  void Update(content::WebContents* contents) override;
  void ResetTabState(content::WebContents* contents) override;
  bool HasSecurityStateChanged() override;
  LocationBarTesting* GetLocationBarForTesting() override;

 private:
  const raw_ptr<BEBrowserWindow> window_;
};

// Fullscreen (the page's requestFullscreen, ⌃⌘F) and its "Press Esc" bubble.
// Webium's WebUIBrowserExclusiveAccessContext, owned by our window instead of
// BrowserWindowFeatures.
class BEExclusiveAccessContext : public ExclusiveAccessContext,
                                 public ExclusiveAccessBubbleViewsContext {
 public:
  explicit BEExclusiveAccessContext(BEBrowserWindow* window);
  BEExclusiveAccessContext(const BEExclusiveAccessContext&) = delete;
  BEExclusiveAccessContext& operator=(const BEExclusiveAccessContext&) =
      delete;
  ~BEExclusiveAccessContext() override;

  // ExclusiveAccessContext:
  Profile* GetProfile() override;
  bool IsFullscreen() const override;
  void EnterFullscreen(const url::Origin& origin,
                       ExclusiveAccessBubbleType bubble_type,
                       FullscreenTabParams fullscreen_tab_params) override;
  void ExitFullscreen() override;
  void UpdateExclusiveAccessBubble(
      const ExclusiveAccessBubbleParams& params,
      ExclusiveAccessBubbleHideCallback first_hide_callback) override;
  bool IsExclusiveAccessBubbleDisplayed() const override;
  void OnExclusiveAccessUserInput() override;
  content::WebContents* GetWebContentsForExclusiveAccess() override;
  bool CanUserEnterFullscreen() const override;
  bool CanUserExitFullscreen() const override;

  // ExclusiveAccessBubbleViewsContext:
  ExclusiveAccessManager* GetExclusiveAccessManager() override;
  ui::AcceleratorProvider* GetAcceleratorProvider() override;
  gfx::NativeView GetBubbleParentView() const override;
  gfx::Rect GetClientAreaBoundsInScreen() const override;
  bool IsImmersiveModeEnabled() const override;
  gfx::Rect GetTopContainerBoundsInScreen() override;
  void DestroyAnyExclusiveAccessBubble() override;

 private:
  const raw_ptr<BEBrowserWindow> window_;
  std::unique_ptr<ExclusiveAccessBubbleViews> exclusive_access_bubble_;
  base::CancelableTaskTracker exclusive_access_bubble_cancelable_task_tracker_;
  std::optional<base::CancelableTaskTracker::TaskId>
      exclusive_access_bubble_destruction_task_id_;
  base::WeakPtrFactory<BEExclusiveAccessContext> weak_ptr_factory_{this};
};

// Positions Chrome's tab-modal dialogs (HTTP auth, print, JavaScript dialogs)
// over the page area the app laid out. Webium's WebUIBrowserModalDialogHost.
class BEModalDialogHost : public web_modal::WebContentsModalDialogHost {
 public:
  explicit BEModalDialogHost(BEBrowserWindow* window);
  BEModalDialogHost(const BEModalDialogHost&) = delete;
  BEModalDialogHost& operator=(const BEModalDialogHost&) = delete;
  ~BEModalDialogHost() override;

  // web_modal::WebContentsModalDialogHost:
  void NotifyPositionRequiresUpdate() override;
  gfx::NativeView GetHostView() const override;
  gfx::Point GetDialogPosition(const gfx::Size& size) override;
  bool ShouldActivateDialog() const override;
  gfx::Size GetMaximumDialogSize() override;
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override;
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override;

 private:
  const raw_ptr<BEBrowserWindow> window_;
  base::ObserverList<web_modal::ModalDialogHostObserver> observers_;
};

// Owns Chrome's Views find bar for our window until milestone 2 brings our
// own: it registers itself on the browser's UnownedUserDataHost, where
// FindBarOwner::From() looks, so BrowserWindowFeatures needs no arm for it.
// Webium's FindBarOwnerWebUIBrowser, with the page area as the bounding box.
class BEFindBarOwner : public FindBarOwner {
 public:
  BEFindBarOwner(BEBrowserWindow* window, ui::UnownedUserDataHost& host);
  BEFindBarOwner(const BEFindBarOwner&) = delete;
  BEFindBarOwner& operator=(const BEFindBarOwner&) = delete;
  ~BEFindBarOwner() override;

  // FindBarOwner:
  views::Widget* GetOwnerWidget() override;
  gfx::Rect GetFindBarBoundingBox() override;
  gfx::Rect GetFindBarClippingBox() override;
  bool IsOffTheRecord() const override;
  views::Widget* GetWidgetForAnchoring() override;
  std::u16string GetFindBarAccessibleWindowTitle() override;
  void OnFindBarVisibilityChanged(gfx::Rect visible_bounds) override;
  void CloseOverlappingBubbles() override;

 private:
  const raw_ptr<BEBrowserWindow> window_;
};

// Chrome's status bubble, whose text the app shows over the bottom of its page
// (BEWindow.statusText): the address of the link under the pointer, or what a
// loading page waits for ("Waiting for example.com..."). One for the window
// and its active page, where BrowserView has a StatusBubbleViews over each
// visible page's ContentsWebView (two in a split view), which is what
// BrowserWebContentsDelegate looks for to route a link's address: patch 21
// routes the active page's here instead. As in StatusBubbleViews, a link wins
// over the status, and leaving the link shows the status again.
class BEStatusBubble : public StatusBubble {
 public:
  explicit BEStatusBubble(BEBrowserWindow* window);
  BEStatusBubble(const BEStatusBubble&) = delete;
  BEStatusBubble& operator=(const BEStatusBubble&) = delete;
  ~BEStatusBubble() override;

  // The link's address if there is one, else the status; empty for nothing.
  const std::u16string& GetText() const;

  // StatusBubble:
  void SetStatus(const std::u16string& status) override;
  void SetURL(const GURL& url) override;
  void Hide() override;
  void MouseMoved(bool left_content) override;

 private:
  // Tells the window if GetText() changed.
  void SetTexts(std::u16string status_text, std::u16string url_text);

  const raw_ptr<BEBrowserWindow> window_;
  std::u16string status_text_;
  std::u16string url_text_;
};

// Chrome's autofill and payments bubbles (save or update an address, save a
// card or IBAN, virtual cards, Autofill AI...) don't show in our windows yet;
// the app will show its own. Like BrowserView's AutofillBubbleHandlerImpl this
// is both GetAutofillBubbleHandler() and the browser's UnownedUserData, so
// every caller finds a handler. Each Show*() returns a bubble that isn't
// there: most callers dereference the result (SetBubbleView(*...), then
// CHECK(bubble_view())), and they only ever call Hide() and IsMouseHovered()
// on it (autofill_bubble_controller_base.cc).
class BEAutofillBubbleHandler : public autofill::AutofillBubbleHandler {
 public:
  explicit BEAutofillBubbleHandler(BrowserWindowInterface* browser);
  BEAutofillBubbleHandler(const BEAutofillBubbleHandler&) = delete;
  BEAutofillBubbleHandler& operator=(const BEAutofillBubbleHandler&) = delete;
  ~BEAutofillBubbleHandler() override;

  // autofill::AutofillBubbleHandler:
  autofill::AutofillBubbleBase* ShowSaveCreditCardBubble(
      content::WebContents* web_contents,
      autofill::SaveCardBubbleController* controller,
      bool is_user_gesture) override;
  autofill::AutofillBubbleBase* ShowIbanBubble(
      content::WebContents* web_contents,
      autofill::IbanBubbleController* controller,
      bool is_user_gesture,
      autofill::IbanBubbleType bubble_type) override;
  autofill::AutofillBubbleBase* ShowOfferNotificationBubble(
      content::WebContents* web_contents,
      autofill::OfferNotificationBubbleController* controller,
      bool is_user_gesture) override;
  autofill::AutofillBubbleBase* ShowSaveAutofillAiDataBubble(
      content::WebContents* web_contents,
      autofill::AutofillAiImportDataController* controller) override;
  autofill::AutofillBubbleBase* ShowAutofillAiLocalSaveNotification(
      content::WebContents* web_contents,
      autofill::AutofillAiImportDataController* controller) override;
  autofill::AutofillBubbleBase* ShowSaveAddressProfileBubble(
      content::WebContents* web_contents,
      std::unique_ptr<autofill::SaveAddressBubbleController> controller,
      bool is_user_gesture) override;
#if BUILDFLAG(ENABLE_DICE_SUPPORT)
  autofill::AutofillBubbleBase* ShowAddressSignInPromo(
      content::WebContents* web_contents,
      const autofill::AutofillProfile& autofill_profile) override;
#endif  // BUILDFLAG(ENABLE_DICE_SUPPORT)
  autofill::AutofillBubbleBase* ShowUpdateAddressProfileBubble(
      content::WebContents* web_contents,
      std::unique_ptr<autofill::UpdateAddressBubbleController> controller,
      bool is_user_gesture) override;
  autofill::AutofillBubbleBase* ShowFilledCardInformationBubble(
      content::WebContents* web_contents,
      autofill::FilledCardInformationBubbleController* controller,
      bool is_user_gesture) override;
  autofill::AutofillBubbleBase* ShowVirtualCardEnrollBubble(
      content::WebContents* web_contents,
      autofill::VirtualCardEnrollBubbleController* controller,
      bool is_user_gesture) override;
  autofill::AutofillBubbleBase* ShowVirtualCardEnrollConfirmationBubble(
      content::WebContents* web_contents,
      autofill::VirtualCardEnrollBubbleController* controller) override;
  autofill::AutofillBubbleBase* ShowMandatoryReauthBubble(
      content::WebContents* web_contents,
      autofill::MandatoryReauthBubbleController* controller,
      bool is_user_gesture,
      autofill::MandatoryReauthBubbleType bubble_type) override;
  autofill::AutofillBubbleBase* ShowSaveCardConfirmationBubble(
      content::WebContents* web_contents,
      autofill::SaveCardBubbleController* controller) override;
  autofill::AutofillBubbleBase* ShowSaveIbanConfirmationBubble(
      content::WebContents* web_contents,
      autofill::IbanBubbleController* controller) override;
  autofill::AutofillBubbleBase* ShowOmniboxAutofillBubble(
      content::WebContents* web_contents,
      autofill::OmniboxAutofillBubbleController* controller) override;
  autofill::AutofillBubbleBase* ShowPaymentsChurnedUsersBubble(
      content::WebContents* web_contents,
      autofill::PaymentsChurnedUsersBubbleController* controller,
      bool is_user_gesture) override;
  autofill::AutofillBubbleBase* ShowPaymentsChurnedUsersConfirmationBubble(
      content::WebContents* web_contents,
      autofill::PaymentsChurnedUsersBubbleController* controller) override;
  autofill::AutofillBubbleBase* ShowWalletReminderNoticeBubble(
      content::WebContents* web_contents,
      autofill::WalletReminderNoticeBubbleController* controller,
      bool is_user_gesture) override;

 private:
  ui::ScopedUnownedUserData<autofill::AutofillBubbleHandler> scoped_user_data_;
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_BROWSER_WINDOW_PARTS_H_
