// What Settings' own pages show and change, for one window's profile (its
// everyday profile for a private window): Delete browsing data (Chrome's
// counters and BrowsingDataRemover, as its dialog uses them), search engines
// and site search (TemplateURLService) and sites with their own zoom
// (HostZoomMap).

#ifndef BROWSER_ENGINE_BE_SETTINGS_DATA_H_
#define BROWSER_ENGINE_BE_SETTINGS_DATA_H_

#import <Foundation/Foundation.h>

#include <memory>
#include <string>
#include <vector>

#include "base/callback_list.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#import "browser_engine/public/BEEngineOptional.h"
#include "components/search_engines/template_url_service_observer.h"

class Profile;
class TemplateURLService;

namespace browsing_data {
class BrowsingDataCounter;
}  // namespace browsing_data

namespace browser_engine {

class BESettingsData : public TemplateURLServiceObserver {
 public:
  // `search_engines_changed` and `zoom_changed` run when those change, from
  // whoever.
  BESettingsData(Profile* profile,
                 base::RepeatingClosure search_engines_changed,
                 base::RepeatingClosure zoom_changed);
  BESettingsData(const BESettingsData&) = delete;
  BESettingsData& operator=(const BESettingsData&) = delete;
  ~BESettingsData() override;

  // Delete browsing data.
  void CountBrowsingData(BEBrowsingDataTypes types,
                         BEBrowsingDataPeriod period,
                         void (^update)(BEBrowsingDataTypes, NSString*));
  void StopCounting();
  void RemoveBrowsingData(BEBrowsingDataTypes types,
                          BEBrowsingDataPeriod period,
                          void (^completion)(void));

  // Search engines.
  NSArray<id<BESearchEngine>>* SearchEngines();
  void MakeDefault(int64_t identifier);
  int64_t Add(NSString* name, NSString* keyword, NSString* url);
  bool Edit(int64_t identifier,
            NSString* name,
            NSString* keyword,
            NSString* url);
  void Remove(int64_t identifier);

  // Sites with their own zoom.
  NSDictionary<NSString*, NSNumber*>* SiteZoomLevels();
  void ResetZoom(NSString* host);

 private:
  // TemplateURLServiceObserver:
  void OnTemplateURLServiceChanged() override;
  void OnTemplateURLServiceShuttingDown() override;

  // The service, loaded; null while it isn't (it's asked to load).
  TemplateURLService* LoadedService();
  // Whether `keyword` and `url` make a valid engine, `keyword` not taken by
  // another than `identifier`'s.
  bool IsValid(const std::u16string& name,
               const std::u16string& keyword,
               const std::string& url,
               int64_t identifier);

  const raw_ptr<Profile> profile_;
  base::RepeatingClosure search_engines_changed_;
  base::RepeatingClosure zoom_changed_;
  std::vector<std::unique_ptr<browsing_data::BrowsingDataCounter>> counters_;
  base::ScopedObservation<TemplateURLService, TemplateURLServiceObserver>
      template_url_observation_{this};
  base::CallbackListSubscription zoom_subscription_;
  base::WeakPtrFactory<BESettingsData> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_SETTINGS_DATA_H_
