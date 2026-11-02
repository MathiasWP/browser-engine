// The everyday profile's most visited sites to the app, as the tiles of
// Chrome's new tab page list them (MostVisitedHandler, with top sites only,
// as ungoogled-chromium's third-party new tab page has them): for
// -[BEEngine mostVisited], with their icons from the local favicon database.

#ifndef BROWSER_ENGINE_BE_MOST_VISITED_H_
#define BROWSER_ENGINE_BE_MOST_VISITED_H_

#import <Foundation/Foundation.h>

#include <map>
#include <memory>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/cancelable_task_tracker.h"
#import "browser_engine/public/BEEngine.h"
#include "components/ntp_tiles/most_visited_sites.h"

@class BEChromiumVisitedPage;

class GURL;
class Profile;

namespace browser_engine {

// One for the process, in the engine, made when the app first reads the
// sites. Tiles and icons arrive on later tasks; each tells the engine
// delegate engineDidChangeMostVisited:.
class BEMostVisited : public ntp_tiles::MostVisitedSites::Observer {
 public:
  BEMostVisited();
  BEMostVisited(const BEMostVisited&) = delete;
  BEMostVisited& operator=(const BEMostVisited&) = delete;
  ~BEMostVisited() override;

  // Watches `profile`'s sites, in place of another profile's, unless it does
  // already.
  void ObserveProfile(Profile* profile);

  // The tiles as last listed, best first.
  NSArray<id<BEVisitedPage>>* items() const;

  // Blocklists `url` as removing a tile does, or lets it back.
  void SetRemoved(const GURL& url, bool removed);

 private:
  // ntp_tiles::MostVisitedSites::Observer:
  void OnURLsAvailable(
      bool is_user_triggered,
      const std::map<ntp_tiles::SectionType, ntp_tiles::NTPTilesVector>&
          sections) override;
  void OnIconMadeAvailable(const GURL& site_url) override;

  // Asks for `page`'s icon at tile size, from the local database only; it
  // arrives on a later task.
  void LoadIcon(BEChromiumVisitedPage* page);
  // Tells the engine delegate, once per task.
  void NotifyChange();
  void SendChange();

  raw_ptr<Profile> profile_ = nullptr;
  std::unique_ptr<ntp_tiles::MostVisitedSites> sites_;
  NSArray<BEChromiumVisitedPage*>* __strong items_ = nil;
  bool change_pending_ = false;
  base::CancelableTaskTracker icon_tracker_;
  base::WeakPtrFactory<BEMostVisited> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_MOST_VISITED_H_
