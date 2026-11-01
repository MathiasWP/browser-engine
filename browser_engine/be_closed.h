// Recently closed tabs and windows to the app, as Chrome's History menu lists
// them (HistoryMenuBridge's "Recently Closed" section): the everyday profile's
// sessions::TabRestoreService entries as BEClosedItem objects, for
// -[BEEngine recentlyClosed], and reopening one, for
// -[BEWindow restoreClosedItem:].

#ifndef BROWSER_ENGINE_BE_CLOSED_H_
#define BROWSER_ENGINE_BE_CLOSED_H_

#import <Foundation/Foundation.h>

#include <stdint.h>

#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/task/cancelable_task_tracker.h"
#import "browser_engine/public/BEEngine.h"
#include "components/sessions/core/tab_restore_service.h"
#include "components/sessions/core/tab_restore_service_observer.h"

@class BEChromiumClosedItem;
@class NSImage;

class BrowserWindowInterface;
class GURL;
class Profile;

namespace browser_engine {

// One for the process, in the engine. Like the menu bridge, it watches the
// profile's TabRestoreService from Chromium's start, which loads the last
// session's entries, and lists the entries again whenever they change, asking
// the FaviconService for each tab's icon. Icons arrive on later tasks, into
// the objects already listed, so the list read when the menu opens has the
// icons of what was closed before.
class BERecentlyClosed : public sessions::TabRestoreServiceObserver {
 public:
  BERecentlyClosed();
  BERecentlyClosed(const BERecentlyClosed&) = delete;
  BERecentlyClosed& operator=(const BERecentlyClosed&) = delete;
  ~BERecentlyClosed() override;

  // Watches `profile`'s closed tabs and windows, in place of another
  // profile's, unless it does already. A private profile keeps none.
  void ObserveProfile(Profile* profile);

  // What Chrome's menu lists, newest first; empty while nothing is watched.
  NSArray<id<BEClosedItem>>* items() const;

 private:
  // sessions::TabRestoreServiceObserver:
  void TabRestoreServiceChanged(sessions::TabRestoreService* service) override;
  void TabRestoreServiceDestroyed(
      sessions::TabRestoreService* service) override;
  void TabRestoreServiceLoaded(sessions::TabRestoreService* service) override;

  // Lists the service's entries again. An entry still listed keeps its
  // object, and with it its icon.
  void Update();
  // Stops watching, and lists nothing.
  void Reset();
  // Asks history for the icon of `item`, a tab showing `page_url`.
  void RequestFavicon(BEChromiumClosedItem* item, const GURL& page_url);

  // The profile watched; null when none is.
  raw_ptr<Profile> profile_ = nullptr;
  NSArray<BEChromiumClosedItem*>* __strong items_ = @[];
  base::CancelableTaskTracker favicon_tracker_;
  base::ScopedObservation<sessions::TabRestoreService,
                          sessions::TabRestoreServiceObserver>
      service_observation_{this};
};

// -[BEWindow restoreClosedItem:] for `browser`: reopens the entry whose
// SessionID is `identifier` (BEClosedItem.identifier) as Chrome's History
// menu does, from the everyday profile's entries. Does nothing for an id
// that's no longer listed.
void RestoreClosedItem(BrowserWindowInterface* browser, int32_t identifier);

// Asks `profile`'s history for the icon of the page at `page_url`, as Chrome's
// History menu does for the items of both its sections. `done` gets it on a
// later task, unless history has none or `tracker` cancels the request.
void RequestPageFavicon(Profile* profile,
                        const GURL& page_url,
                        base::CancelableTaskTracker* tracker,
                        void (^done)(NSImage* favicon));

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_CLOSED_H_
