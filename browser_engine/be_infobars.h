// Chrome's infobars for a page, as BETab.infobars: "Reload this page to apply
// your updated settings" after a Page Info change, "Sharing this tab to
// meet.google.com" with Stop sharing, the warnings Chrome shows at startup
// (bad flags, an unsupported macOS), "Did you mean to go to http://intranet/?"
// and the rest at M156. Chrome makes them for our windows' tabs as for its own
// (one infobars::ContentInfoBarManager per tab, TabHelpers::
// AttachTabHelpers()), but only BrowserView shows them (InfoBarContainerView),
// and our windows have none: the app shows them, and its answers reach Chrome
// the way the infobar's buttons, link and close button send them
// (ConfirmInfoBar, InfoBarView, TabSharingInfoBar).

#ifndef BROWSER_ENGINE_BE_INFOBARS_H_
#define BROWSER_ENGINE_BE_INFOBARS_H_

#import <Foundation/Foundation.h>

#include <map>

#include "base/scoped_observation.h"
#import "browser_engine/public/BEEngine.h"
#include "components/infobars/core/infobar_manager.h"

@class BEChromiumInfobar;
@class BEChromiumTab;

namespace content {
class WebContents;
}  // namespace content

namespace infobars {
class InfoBar;
}  // namespace infobars

namespace browser_engine {

// One tab's infobars, owned by its BETab.
//
// The app sees one object per infobar for the infobar's whole life: from the
// moment the tab's manager adds it (or, for one there already, from when the
// tab's object is made) until the manager removes it, as an answer, the close
// button, a navigation (InfoBarDelegate::ShouldExpire()) or a crash do, or
// replaces it with another, or the WebContents goes (closing or discarding the
// tab). From then on the object does nothing. Chrome's infobar deletes itself
// as it's removed: with no InfoBarContainer to animate it closed, at once
// (InfoBar::MaybeDelete()), as in Chrome when animations are off.
class TabInfobars : public infobars::InfoBarManager::Observer {
 public:
  // Calls `[owner scheduleUpdate]` when an infobar comes or goes.
  explicit TabInfobars(BEChromiumTab* owner);
  TabInfobars(const TabInfobars&) = delete;
  TabInfobars& operator=(const TabInfobars&) = delete;
  ~TabInfobars() override;

  // Watches the infobars of `contents`, the tab's WebContents now (null for
  // none). Those of a WebContents watched before go.
  void StartObserving(content::WebContents* contents);

  // The infobars the app is shown, oldest first, as the manager keeps them.
  NSArray<id<BEInfobar>>* GetInfobars() const;

 private:
  // Makes the app's object for `infobar`, unless it's one the app isn't shown
  // (see be_infobars.mm); true if it did.
  bool Add(infobars::InfoBar* infobar);
  // The object for `infobar`, if there is one, does nothing more and goes;
  // true if there was one.
  bool Remove(infobars::InfoBar* infobar);
  void RemoveAll();

  // infobars::InfoBarManager::Observer:
  void OnInfoBarAdded(infobars::InfoBar* infobar) override;
  void OnInfoBarRemoved(infobars::InfoBar* infobar, bool animate) override;
  void OnInfoBarReplaced(infobars::InfoBar* old_infobar,
                         infobars::InfoBar* new_infobar) override;
  void OnManagerWillBeDestroyed(infobars::InfoBarManager* manager) override;

  __weak BEChromiumTab* owner_;

  // What the app holds (strong, ARC), by Chrome's infobar, while it's the
  // manager's.
  std::map<const infobars::InfoBar*, BEChromiumInfobar* __strong> objects_;

  base::ScopedObservation<infobars::InfoBarManager,
                          infobars::InfoBarManager::Observer>
      manager_observation_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_INFOBARS_H_
