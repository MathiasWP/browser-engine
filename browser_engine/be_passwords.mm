#import "browser_engine/be_passwords.h"

#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_tab.h"
#include "chrome/browser/ui/actions/chrome_action_id.h"
#include "chrome/browser/ui/page_action/page_action_controller.h"
#include "chrome/browser/ui/page_action/page_action_model.h"
#include "chrome/browser/ui/passwords/bubble_controllers/password_bubble_controller_base.h"
#include "chrome/browser/ui/passwords/bubble_controllers/save_update_bubble_controller.h"
#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"
#include "chrome/browser/ui/tabs/public/tab_features.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/common/password_manager_ui.h"
#include "components/url_formatter/elide_url.h"
#include "content/public/browser/web_contents.h"

using Response = browser_engine::TabPasswordOffer::Response;

NS_ASSUME_NONNULL_BEGIN

// What the app holds while an offer stands.
@interface BEChromiumPasswordOffer : NSObject <BEPasswordOffer>
- (instancetype)initWithOwner:
                    (base::WeakPtr<browser_engine::TabPasswordOffer>)owner
                     isUpdate:(BOOL)isUpdate
                         site:(NSString*)site
                     username:(NSString*)username NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Answered or withdrawn: nothing more reaches Chrome.
- (void)invalidate;
- (void)respond:(Response)response;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumPasswordOffer {
  // Null once the offer is answered or withdrawn, or its tab's object is gone.
  base::WeakPtr<browser_engine::TabPasswordOffer> _owner;
}

@synthesize isUpdate = _isUpdate;
@synthesize site = _site;
@synthesize username = _username;

- (instancetype)initWithOwner:
                    (base::WeakPtr<browser_engine::TabPasswordOffer>)owner
                     isUpdate:(BOOL)isUpdate
                         site:(NSString*)site
                     username:(NSString*)username {
  if ((self = [super init])) {
    _owner = std::move(owner);
    _isUpdate = isUpdate;
    _site = [site copy];
    _username = [username copy];
  }
  return self;
}

- (void)invalidate {
  _owner.reset();
}

- (void)respond:(Response)response {
  // Respond() lets go of the offer; keep it until the call returns.
  BEChromiumPasswordOffer* offer = self;
  if (browser_engine::TabPasswordOffer* owner = _owner.get()) {
    owner->Respond(offer, response);
  }
}

// MARK: BEPasswordOffer

- (void)save {
  [self respond:Response::kSave];
}

- (void)neverForThisSite {
  [self respond:Response::kNeverForThisSite];
}

- (void)dismiss {
  [self respond:Response::kNotNow];
}

@end

namespace browser_engine {

TabPasswordOffer::TabPasswordOffer(tabs::TabInterface* tab,
                                   BEChromiumTab* owner)
    : handle_(tab->GetHandle()), owner_(owner) {
  // The tab's page action for passwords lives as long as the tab's
  // TabFeatures, across windows and WebContents replacements. Every tab of a
  // window with BrowserActions, as all of ours, has one
  // (page_actions::GetActivePageActionIds(), TabFeatures::Init()), and
  // ManagePasswordsUIController counts on it too
  // (UpdatePasswordIconAndBubbleState()). Without it, no offer.
  if (tabs::TabFeatures* features = tab->GetTabFeatures()) {
    page_actions::PageActionController* controller =
        features->page_action_controller();
    if (controller &&
        controller->ActionExists(kActionShowPasswordsBubbleOrPage)) {
      controller->AddObserver(kActionShowPasswordsBubbleOrPage,
                              model_observation_);
    }
  }
  Update();
}

TabPasswordOffer::~TabPasswordOffer() {
  [offer_ invalidate];
}

id<BEPasswordOffer> TabPasswordOffer::offer() const {
  return offer_;
}

bool TabPasswordOffer::Update() {
  ManagePasswordsUIController* controller = GetController();
  const std::optional<PendingCredential> pending =
      controller ? GetPendingCredential(*controller) : std::nullopt;
  if (!pending) {
    requested_.reset();
    answered_.reset();
  } else if (pending != requested_ && pending != answered_ &&
             PageActionAwaitsBubble()) {
    // Chrome asked for its bubble while the page action already looked as a
    // request leaves it (after an earlier request nothing reset), so the
    // model didn't change and OnPageActionModelChanged() didn't hear of it.
    requested_ = pending;
  }

  if (pending && pending == requested_) {
    if (offer_ && offered_ == pending) {
      return false;
    }
    SetOffer(pending);
    return true;
  }
  if (!offer_) {
    return false;
  }
  SetOffer(std::nullopt);
  return true;
}

void TabPasswordOffer::Respond(BEChromiumPasswordOffer* offer,
                               Response response) {
  if (!offer_ || offer != offer_) {
    return;  // Answered or withdrawn already.
  }
  ManagePasswordsUIController* controller = GetController();
  const std::optional<PendingCredential> pending =
      controller ? GetPendingCredential(*controller) : std::nullopt;
  if (!pending || pending != offered_) {
    // Chrome moved on since the app was told: the app hears what stands now.
    if (Update()) {
      [owner_ scheduleUpdate];
    }
    return;
  }
  if (response == Response::kNeverForThisSite && pending->is_update) {
    return;  // The update bubble has no "Never" (PasswordSaveUpdateView).
  }

  // Spent before Chrome hears the answer, so nothing the answer sets off can
  // use it again.
  answered_ = pending;
  requested_.reset();
  SetOffer(std::nullopt);
  [owner_ scheduleUpdate];

  // Chrome's bubble makes this controller when it shows (its constructor
  // calls OnBubbleShown()), its buttons call it, and closing the bubble
  // destroys it, which reports the interaction (ReportInteractions(): "Not
  // now" counts toward Chrome no longer popping up for the site) and calls
  // OnBubbleHidden(). Here the three happen at once. kAutomatic: Chrome popped
  // the bubble up itself.
  SaveUpdateBubbleController bubble(
      controller->GetModelDelegateProxy(),
      PasswordBubbleControllerBase::DisplayReason::kAutomatic);
  switch (response) {
    case Response::kSave:
      // The pending username and password, unchanged: SavePassword(), after
      // clearing the site's "Not now" count.
      bubble.OnSaveClicked();
      break;
    case Response::kNeverForThisSite:
      // NeverSavePassword(): Chrome blocklists the site.
      bubble.OnNeverForThisSiteClicked();
      break;
    case Response::kNotNow:
      // The save bubble's "Not now" (OnNotNowClicked() → OnNoInteraction()),
      // or the update bubble's cancel button (OnNopeUpdateClicked()). Chrome
      // keeps the credential pending either way, as its key icon would.
      if (pending->is_update) {
        bubble.OnNoThanksClicked();
      } else {
        bubble.OnNotNowClicked();
      }
      break;
  }
}

// static
std::optional<TabPasswordOffer::PendingCredential>
TabPasswordOffer::GetPendingCredential(
    const ManagePasswordsUIController& controller) {
  const password_manager::ui::State state = controller.GetState();
  if (state != password_manager::ui::PENDING_PASSWORD_STATE &&
      state != password_manager::ui::PENDING_PASSWORD_UPDATE_STATE) {
    return std::nullopt;
  }
  // While the user types a password, Chrome keeps it pending too, for its
  // key icon only (OnShowManualFallbackForSaving()).
  if (controller.BubbleIsManualFallbackForSaving()) {
    return std::nullopt;
  }
  return PendingCredential{
      .is_update = state == password_manager::ui::PENDING_PASSWORD_UPDATE_STATE,
      .origin = controller.GetOrigin(),
      .username = controller.GetPendingPassword().username_value,
  };
}

ManagePasswordsUIController* TabPasswordOffer::GetController() const {
  // Without its page action the tab is going (TabFeatures are destroyed
  // before the WebContents).
  if (!model_observation_.IsObserving()) {
    return nullptr;
  }
  tabs::TabInterface* tab = handle_.Get();
  content::WebContents* contents = tab ? tab->GetContents() : nullptr;
  return contents ? ManagePasswordsUIController::FromWebContents(contents)
                  : nullptr;
}

bool TabPasswordOffer::PageActionAwaitsBubble() const {
  // ManagePasswordsPageActionController::UpdateVisibility() gives the page
  // action no tooltip while the bubble is or will be showing; otherwise it
  // has one ("Save password", "Manage passwords").
  const page_actions::PageActionModelInterface* model =
      model_observation_.GetSource();
  return model && model->GetTooltipText().empty();
}

void TabPasswordOffer::SetOffer(
    const std::optional<PendingCredential>& credential) {
  [offer_ invalidate];
  offer_ = nil;
  offered_ = credential;
  if (!credential) {
    return;
  }
  // The site as the bubble names it (GetSavePasswordDialogTitleText(),
  // SaveUpdateBubbleController::GetDomainForSubhead()).
  const std::u16string site = url_formatter::FormatOriginForSecurityDisplay(
      credential->origin, url_formatter::SchemeDisplay::OMIT_HTTP_AND_HTTPS);
  offer_ = [[BEChromiumPasswordOffer alloc]
      initWithOwner:weak_factory_.GetWeakPtr()
           isUpdate:credential->is_update
               site:base::SysUTF16ToNSString(site)
           username:base::SysUTF16ToNSString(credential->username)];
}

void TabPasswordOffer::ScheduleUpdate() {
  if (update_pending_) {
    return;
  }
  update_pending_ = true;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&TabPasswordOffer::UpdateAndNotify,
                                weak_factory_.GetWeakPtr()));
}

void TabPasswordOffer::UpdateAndNotify() {
  update_pending_ = false;
  if (Update()) {
    [owner_ scheduleUpdate];
  }
}

void TabPasswordOffer::OnPageActionModelChanged(
    const page_actions::PageActionModelInterface& model) {
  // Synchronously, inside Chrome's update: IsAutomaticallyOpeningBubble()
  // stays true only until the bubble is asked for (ClearPopUpFlagForBubble()).
  // The rest waits for the end of the task, when Chrome is done.
  ManagePasswordsUIController* controller = GetController();
  if (controller && controller->IsAutomaticallyOpeningBubble()) {
    if (std::optional<PendingCredential> pending =
            GetPendingCredential(*controller)) {
      // A new request, even for a credential the app answered before.
      requested_ = std::move(pending);
      answered_.reset();
    }
  }
  ScheduleUpdate();
}

void TabPasswordOffer::OnPageActionModelWillBeDeleted(
    const page_actions::PageActionModelInterface& model) {
  // The tab is closing; the offer goes now, before the controller does.
  model_observation_.Reset();
  requested_.reset();
  answered_.reset();
  if (offer_) {
    SetOffer(std::nullopt);
    [owner_ scheduleUpdate];
  }
}

}  // namespace browser_engine
