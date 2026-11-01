// Pages visited recently to the app, as Chrome's History menu lists them
// (HistoryMenuBridge's "Recently Visited" section): the everyday profile's
// latest history, as BEVisitedPage objects, for -[BEEngine recentlyVisited].

#ifndef BROWSER_ENGINE_BE_VISITED_H_
#define BROWSER_ENGINE_BE_VISITED_H_

#import <Foundation/Foundation.h>

#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/timer/timer.h"
#import "browser_engine/public/BEEngine.h"
#include "components/history/core/browser/history_service_observer.h"
#include "components/history/core/browser/history_types.h"

@class BEChromiumVisitedPage;

class GURL;
class Profile;

namespace history {
class HistoryService;
}  // namespace history

namespace browser_engine {

// One for the process, in the engine. Like the menu bridge, it watches the
// profile's history from Chromium's start and asks it for the latest pages
// once it has loaded and again whenever it changes, asking the
// FaviconService for each page's icon. The answer, and icons, arrive on later
// tasks; a read returns the last answer. A page listed again keeps its
// object, and with it its icon.
class BERecentlyVisited : public history::HistoryServiceObserver {
 public:
  BERecentlyVisited();
  BERecentlyVisited(const BERecentlyVisited&) = delete;
  BERecentlyVisited& operator=(const BERecentlyVisited&) = delete;
  ~BERecentlyVisited() override;

  // Watches `profile`'s history, in place of another profile's, unless it
  // does already. A private profile's is never listed.
  void ObserveProfile(Profile* profile);

  // What Chrome's menu lists, newest first; empty while nothing is watched,
  // and until history has first answered.
  NSArray<id<BEVisitedPage>>* items() const;

 private:
  // history::HistoryServiceObserver:
  void OnURLVisited(history::HistoryService* history_service,
                    const history::VisitedURLInfo& visited_url_info) override;
  void OnURLsModified(history::HistoryService* history_service,
                      const history::URLRows& changed_urls) override;
  void OnHistoryDeletions(history::HistoryService* history_service,
                          const history::DeletionInfo& deletion_info) override;
  void OnHistoryServiceLoaded(
      history::HistoryService* history_service) override;
  void HistoryServiceBeingDeleted(
      history::HistoryService* history_service) override;

  // Asks history again, shortly.
  void OnHistoryChanged();
  // Asks history for the latest pages, now.
  void Query();
  void OnQueryResults(history::QueryResults results);
  // Stops watching, and lists nothing.
  void Reset();
  // Asks history for the icon of `page`, showing `page_url`.
  void RequestFavicon(BEChromiumVisitedPage* page, const GURL& page_url);

  // The profile watched; null when none is.
  raw_ptr<Profile> profile_ = nullptr;
  NSArray<BEChromiumVisitedPage*>* __strong items_ = @[];
  // While history answers, a change only marks that it must be asked again.
  bool query_in_progress_ = false;
  bool needs_query_ = false;
  base::OneShotTimer query_timer_;
  // History's answers and icons.
  base::CancelableTaskTracker task_tracker_;
  base::ScopedObservation<history::HistoryService,
                          history::HistoryServiceObserver>
      history_observation_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_VISITED_H_
