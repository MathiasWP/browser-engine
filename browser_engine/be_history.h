// The history page's data for the app (BEWindowHistory): Chrome's history
// service, asked as its history page asks it (BrowsingHistoryService), for one
// window's profile.

#ifndef BROWSER_ENGINE_BE_HISTORY_H_
#define BROWSER_ENGINE_BE_HISTORY_H_

#import <AppKit/AppKit.h>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/cancelable_task_tracker.h"
#import "browser_engine/public/BEEngineOptional.h"

class Profile;

namespace history {
class HistoryService;
class QueryResults;
}  // namespace history

namespace browser_engine {

// One per window, made when the app first asks, destroyed with the window
// (before its profile). Requests outstanding then are cancelled, and their
// completions never run.
class BEHistory {
 public:
  // `profile` is the window's; a private one's original profile is asked.
  explicit BEHistory(Profile* profile);
  BEHistory(const BEHistory&) = delete;
  BEHistory& operator=(const BEHistory&) = delete;
  ~BEHistory();

  void Query(NSString* text,
             NSString* host,
             NSDate* before,
             NSInteger count,
             void (^completion)(NSArray<id<BEHistoryEntry>>*, BOOL));
  void Remove(NSArray<id<BEHistoryEntry>>* entries, void (^completion)(void));
  void RequestFavicon(NSURL* url, void (^completion)(NSImage*));

 private:
  // Null while the profile has no history (it's being torn down).
  history::HistoryService* service() const;
  void OnQueryResults(void (^completion)(NSArray<id<BEHistoryEntry>>*, BOOL),
                      history::QueryResults results);

  const raw_ptr<Profile> profile_;
  base::CancelableTaskTracker tracker_;
  base::WeakPtrFactory<BEHistory> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_HISTORY_H_
