// Chrome's offer to save or update the password a page just signed in with,
// as BETab.passwordOffer. Chrome decides when to offer exactly as it does for
// its own save and update bubble (ManagePasswordsUIController); that bubble
// never shows in our windows (PasswordBubbleViewBase::ShowBubble() wants
// Chrome's toolbar), so the app shows its own prompt, and its answers reach
// Chrome the way the bubble's buttons send them (SaveUpdateBubbleController).

#ifndef BROWSER_ENGINE_BE_PASSWORDS_H_
#define BROWSER_ENGINE_BE_PASSWORDS_H_

#import <Foundation/Foundation.h>

#include <optional>
#include <string>

#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#import "browser_engine/public/BEEngine.h"
#include "chrome/browser/ui/page_action/page_action_model_observer.h"
#include "components/tabs/public/tab_interface.h"
#include "url/origin.h"

@class BEChromiumPasswordOffer;
@class BEChromiumTab;

class ManagePasswordsUIController;

namespace page_actions {
class PageActionModelInterface;
}  // namespace page_actions

namespace browser_engine {

// One tab's offer, owned by its BETab.
//
// Chrome keeps one pending credential per tab (ManagePasswordsUIController's
// PENDING_PASSWORD_STATE or PENDING_PASSWORD_UPDATE_STATE), and also has one
// pending while the user types a password (the manual fallback), after the
// user told it never to save for a site, and after the user ignored its
// bubble on a site too often. It pops its bubble up only for a sign-in it
// wants to offer, so an offer stands from that moment until Chrome's
// credential is no longer pending, is another one, or the app answers.
//
// Chrome tells nothing outside itself when it pops the bubble up. What it does
// first is update the tab's page action for passwords
// (ManagePasswordsUIController::UpdatePasswordIconAndBubbleState() →
// ManagePasswordsPageActionController::UpdateVisibility()), while
// IsAutomaticallyOpeningBubble() is true; watching that page action's model
// catches the moment. Each update of that model blanks its tooltip while the
// bubble is or will be showing, which is also how a request is recognized
// when the model didn't change and so said nothing.
class TabPasswordOffer : public page_actions::PageActionModelObserver {
 public:
  // The app's answers, as the bubble's buttons.
  enum class Response { kSave, kNeverForThisSite, kNotNow };

  // Calls `[owner scheduleUpdate]` when the offer comes or goes.
  TabPasswordOffer(tabs::TabInterface* tab, BEChromiumTab* owner);
  TabPasswordOffer(const TabPasswordOffer&) = delete;
  TabPasswordOffer& operator=(const TabPasswordOffer&) = delete;
  ~TabPasswordOffer() override;

  // The offer standing, or nil. Once answered, or once Chrome withdraws it (a
  // navigation, a new sign-in, the tab closing), an offer does nothing.
  id<BEPasswordOffer> offer() const;

  // Looks at Chrome's state again; true if the offer came, went or changed.
  // The tab calls this before each tabDidUpdate:.
  bool Update();

  // From `offer`, if it's still the one standing: answers Chrome as the
  // bubble would, and the offer goes.
  void Respond(BEChromiumPasswordOffer* offer, Response response);

 private:
  // The credential an offer is about, as the app sees it. A new sign-in
  // replaces Chrome's pending credential.
  struct PendingCredential {
    bool is_update = false;
    url::Origin origin;
    std::u16string username;

    friend bool operator==(const PendingCredential&,
                           const PendingCredential&) = default;
  };

  // Chrome's pending credential for the bubble, if any.
  static std::optional<PendingCredential> GetPendingCredential(
      const ManagePasswordsUIController& controller);

  // The tab's controller, or null once the tab (or its page action) is going.
  ManagePasswordsUIController* GetController() const;

  // Whether the page action looks as an update leaves it while Chrome's
  // bubble is or will be showing (see the class comment).
  bool PageActionAwaitsBubble() const;

  // Replaces the offer the app sees (nil for none).
  void SetOffer(const std::optional<PendingCredential>& credential);

  // Update(), then tell the tab if anything changed; at most once per task.
  void ScheduleUpdate();
  void UpdateAndNotify();

  // page_actions::PageActionModelObserver:
  void OnPageActionModelChanged(
      const page_actions::PageActionModelInterface& model) override;
  void OnPageActionModelWillBeDeleted(
      const page_actions::PageActionModelInterface& model) override;

  const tabs::TabHandle handle_;
  __weak BEChromiumTab* owner_;

  // The credential Chrome last popped its bubble up for, until it's no longer
  // pending or the app answers.
  std::optional<PendingCredential> requested_;
  // The credential the app last answered, while it's still pending (Chrome
  // keeps it after "Not now"), so the blank tooltip doesn't offer it again.
  std::optional<PendingCredential> answered_;

  // What the app sees (strong, ARC), and what it's about.
  BEChromiumPasswordOffer* __strong offer_ = nil;
  std::optional<PendingCredential> offered_;

  bool update_pending_ = false;
  base::ScopedObservation<page_actions::PageActionModelInterface,
                          page_actions::PageActionModelObserver>
      model_observation_{this};
  base::WeakPtrFactory<TabPasswordOffer> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_PASSWORDS_H_
