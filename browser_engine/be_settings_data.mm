#import "browser_engine/be_settings_data.h"

#include <cmath>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/browsing_data/browsing_data_important_sites_util.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/browsing_data/counters/browsing_data_counter_factory.h"
#include "chrome/browser/browsing_data/counters/browsing_data_counter_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "components/browsing_data/core/browsing_data_utils.h"
#include "components/browsing_data/core/counters/browsing_data_counter.h"
#include "components/browsing_data/core/pref_names.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_data.h"
#include "components/search_engines/template_url_service.h"
#include "components/search_engines/template_url_starter_pack_data.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/host_zoom_map.h"
#include "url/gurl.h"

@interface BEChromiumSearchEngine : NSObject <BESearchEngine>
- (instancetype)initWithIdentifier:(int64_t)identifier
                              name:(NSString*)name
                           keyword:(NSString*)keyword
                               url:(NSString*)url
                         isDefault:(BOOL)isDefault
                   isDefaultChoice:(BOOL)isDefaultChoice
                    canMakeDefault:(BOOL)canMakeDefault
                           canEdit:(BOOL)canEdit
                         canRemove:(BOOL)canRemove NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumSearchEngine

@synthesize identifier = _identifier;
@synthesize name = _name;
@synthesize keyword = _keyword;
@synthesize url = _url;
@synthesize isDefault = _isDefault;
@synthesize isDefaultChoice = _isDefaultChoice;
@synthesize canMakeDefault = _canMakeDefault;
@synthesize canEdit = _canEdit;
@synthesize canRemove = _canRemove;

- (instancetype)initWithIdentifier:(int64_t)identifier
                              name:(NSString*)name
                           keyword:(NSString*)keyword
                               url:(NSString*)url
                         isDefault:(BOOL)isDefault
                   isDefaultChoice:(BOOL)isDefaultChoice
                    canMakeDefault:(BOOL)canMakeDefault
                           canEdit:(BOOL)canEdit
                         canRemove:(BOOL)canRemove {
  if ((self = [super init])) {
    _identifier = identifier;
    _name = [name copy];
    _keyword = [keyword copy];
    _url = [url copy];
    _isDefault = isDefault;
    _isDefaultChoice = isDefaultChoice;
    _canMakeDefault = canMakeDefault;
    _canEdit = canEdit;
    _canRemove = canRemove;
  }
  return self;
}

@end

namespace browser_engine {

namespace {

// Each type with the preference Chrome's dialog keeps its checkbox in, which
// names its counter (BrowsingDataCounterFactory).
struct DataType {
  BEBrowsingDataTypes type;
  const char* pref;
};

constexpr DataType kDataTypes[] = {
    {BEBrowsingDataTypeHistory, browsing_data::prefs::kDeleteBrowsingHistory},
    {BEBrowsingDataTypeDownloads, browsing_data::prefs::kDeleteDownloadHistory},
    {BEBrowsingDataTypeCookies, browsing_data::prefs::kDeleteCookies},
    {BEBrowsingDataTypeCache, browsing_data::prefs::kDeleteCache},
    {BEBrowsingDataTypeFormData, browsing_data::prefs::kDeleteFormData},
    {BEBrowsingDataTypeSiteSettings, browsing_data::prefs::kDeleteSiteSettings},
    {BEBrowsingDataTypePasswords, browsing_data::prefs::kDeletePasswords},
};

browsing_data::TimePeriod Period(BEBrowsingDataPeriod period) {
  switch (period) {
    case BEBrowsingDataPeriodLastHour:
      return browsing_data::TimePeriod::LAST_HOUR;
    case BEBrowsingDataPeriodLastDay:
      return browsing_data::TimePeriod::LAST_DAY;
    case BEBrowsingDataPeriodLastWeek:
      return browsing_data::TimePeriod::LAST_WEEK;
    case BEBrowsingDataPeriodFourWeeks:
      return browsing_data::TimePeriod::FOUR_WEEKS;
    case BEBrowsingDataPeriodLast15Minutes:
      return browsing_data::TimePeriod::LAST_15_MINUTES;
    case BEBrowsingDataPeriodAllTime:
    default:
      return browsing_data::TimePeriod::ALL_TIME;
  }
}

}  // namespace

BESettingsData::BESettingsData(Profile* profile,
                               base::RepeatingClosure search_engines_changed,
                               base::RepeatingClosure zoom_changed)
    : profile_(profile->GetOriginalProfile()),
      search_engines_changed_(std::move(search_engines_changed)),
      zoom_changed_(std::move(zoom_changed)) {
  if (TemplateURLService* service =
          TemplateURLServiceFactory::GetForProfile(profile_)) {
    template_url_observation_.Observe(service);
  }
  zoom_subscription_ =
      content::HostZoomMap::GetDefaultForBrowserContext(profile_)
          ->AddZoomLevelChangedCallback(base::BindRepeating(
              [](base::WeakPtr<BESettingsData> self,
                 const content::HostZoomMap::ZoomLevelChange& change) {
                if (self &&
                    change.mode ==
                        content::HostZoomMap::ZOOM_CHANGED_FOR_HOST) {
                  self->zoom_changed_.Run();
                }
              },
              weak_factory_.GetWeakPtr()));
}

BESettingsData::~BESettingsData() = default;

// MARK: Delete browsing data

void BESettingsData::CountBrowsingData(
    BEBrowsingDataTypes types,
    BEBrowsingDataPeriod period,
    void (^update)(BEBrowsingDataTypes, NSString*)) {
  // SettingsClearBrowsingDataHandler: a counter per type, for the period's
  // start, its result in the dialog's words.
  counters_.clear();
  const base::Time begin =
      browsing_data::CalculateBeginDeleteTime(Period(period));
  for (const DataType& data_type : kDataTypes) {
    if (!(types & data_type.type)) {
      continue;
    }
    std::unique_ptr<browsing_data::BrowsingDataCounter> counter =
        BrowsingDataCounterFactory::GetForProfileAndPref(profile_,
                                                         data_type.pref);
    if (!counter) {
      continue;
    }
    const BEBrowsingDataTypes type = data_type.type;
    Profile* profile = profile_;
    counter->InitWithoutPref(
        begin, base::BindRepeating(
                   ^(std::unique_ptr<browsing_data::BrowsingDataCounter::Result>
                         result) {
                     update(type, base::SysUTF16ToNSString(
                                      browsing_data_counter_utils::
                                          GetChromeCounterTextFromResult(
                                              result.get(), profile)));
                   }));
    counter->Restart();
    counters_.push_back(std::move(counter));
  }
}

void BESettingsData::StopCounting() {
  counters_.clear();
}

void BESettingsData::RemoveBrowsingData(BEBrowsingDataTypes types,
                                        BEBrowsingDataPeriod period,
                                        void (^completion)(void)) {
  // SettingsClearBrowsingDataHandler::HandleClearBrowsingData(): the same
  // masks, and important sites' data kept as Chrome keeps it.
  uint64_t remove_mask = 0;
  uint64_t origin_mask = 0;
  if (types & BEBrowsingDataTypeHistory) {
    remove_mask |= chrome_browsing_data_remover::DATA_TYPE_HISTORY;
  }
  if (types & BEBrowsingDataTypeDownloads) {
    remove_mask |= content::BrowsingDataRemover::DATA_TYPE_DOWNLOADS;
  }
  if (types & BEBrowsingDataTypeCache) {
    remove_mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
  }
  if (types & BEBrowsingDataTypeCookies) {
    remove_mask |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
    origin_mask |= content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB;
  }
  if (types & BEBrowsingDataTypeFormData) {
    remove_mask |= chrome_browsing_data_remover::DATA_TYPE_FORM_DATA;
  }
  if (types & BEBrowsingDataTypeSiteSettings) {
    remove_mask |= chrome_browsing_data_remover::DATA_TYPE_CONTENT_SETTINGS;
  }
  if (types & BEBrowsingDataTypePasswords) {
    remove_mask |= chrome_browsing_data_remover::DATA_TYPE_PASSWORDS;
  }
  if (!remove_mask) {
    completion();
    return;
  }
  browsing_data_important_sites_util::Remove(
      remove_mask, origin_mask, Period(period),
      content::BrowsingDataFilterBuilder::Create(
          content::BrowsingDataFilterBuilder::Mode::kPreserve),
      profile_->GetBrowsingDataRemover(),
      base::BindOnce(^(uint64_t failed_data_types) {
        completion();
      }));
}

// MARK: Search engines

TemplateURLService* BESettingsData::LoadedService() {
  TemplateURLService* service = template_url_observation_.GetSource();
  if (service && !service->loaded()) {
    service->Load();  // OnTemplateURLServiceChanged() once loaded.
    return nullptr;
  }
  return service;
}

NSArray<id<BESearchEngine>>* BESettingsData::SearchEngines() {
  TemplateURLService* service = LoadedService();
  if (!service) {
    return @[];
  }
  // KeywordEditorController's table: the default choices, then the rest,
  // each in the service's order; extension and hidden engines left out.
  const TemplateURL* default_engine = service->GetDefaultSearchProvider();
  NSMutableArray<id<BESearchEngine>>* choices = [NSMutableArray array];
  NSMutableArray<id<BESearchEngine>>* others = [NSMutableArray array];
  for (TemplateURL* engine : service->GetTemplateURLs()) {
    if (engine->type() != TemplateURL::NORMAL ||
        service->HiddenFromLists(engine)) {
      continue;
    }
    const bool is_default = engine == default_engine;
    const bool is_choice = service->ShowInDefaultList(engine);
    const bool fixed =
        engine->CreatedByPolicy() ||
        engine->starter_pack_id() !=
            template_url_starter_pack_data::StarterPackId::kNone;
    BEChromiumSearchEngine* object = [[BEChromiumSearchEngine alloc]
        initWithIdentifier:engine->id()
                      name:base::SysUTF16ToNSString(engine->short_name())
                   keyword:base::SysUTF16ToNSString(engine->keyword())
                       url:base::SysUTF8ToNSString(engine->url())
                 isDefault:is_default
           isDefaultChoice:is_choice
            canMakeDefault:!is_default && service->CanMakeDefault(engine)
                   canEdit:!fixed
                 canRemove:!is_default && !fixed];
    [(is_choice ? choices : others) addObject:object];
  }
  return [choices arrayByAddingObjectsFromArray:others];
}

void BESettingsData::MakeDefault(int64_t identifier) {
  TemplateURLService* service = LoadedService();
  TemplateURL* engine =
      service ? service->GetTemplateURLForId(identifier) : nullptr;
  if (engine && service->CanMakeDefault(engine)) {
    service->SetUserSelectedDefaultSearchProvider(engine);
  }
}

bool BESettingsData::IsValid(const std::u16string& name,
                             const std::u16string& keyword,
                             const std::string& url,
                             int64_t identifier) {
  TemplateURLService* service = LoadedService();
  if (!service || base::TrimWhitespace(name, base::TRIM_ALL).empty() ||
      base::TrimWhitespace(keyword, base::TRIM_ALL).empty() ||
      keyword.find(u' ') != std::u16string::npos) {
    return false;
  }
  // EditSearchEngineController::IsKeywordValid(): not another's keyword.
  const TemplateURL* taken = service->GetTemplateURLForKeyword(keyword);
  if (taken && taken->id() != identifier) {
    return false;
  }
  // EditSearchEngineController::IsURLValid(), simply: a search term to
  // replace, and an address once it's replaced.
  if (url.find("%s") == std::string::npos) {
    return false;
  }
  std::string replaced = url;
  base::ReplaceSubstringsAfterOffset(&replaced, 0, "%s", "x");
  GURL address(replaced);
  return address.is_valid() && address.SchemeIsHTTPOrHTTPS();
}

int64_t BESettingsData::Add(NSString* name, NSString* keyword, NSString* url) {
  const std::u16string title = base::SysNSStringToUTF16(name);
  const std::u16string word = base::SysNSStringToUTF16(keyword);
  const std::string address = base::SysNSStringToUTF8(url);
  if (!IsValid(title, word, address, 0)) {
    return 0;
  }
  // EditSearchEngineController::AcceptAddOrEdit() for a new one.
  TemplateURLData data;
  data.SetShortName(title);
  data.SetKeyword(word);
  data.SetURL(address);
  data.safe_for_autoreplace = false;
  data.is_active = TemplateURLData::ActiveStatus::kTrue;
  TemplateURL* added =
      LoadedService()->Add(std::make_unique<TemplateURL>(data));
  return added ? added->id() : 0;
}

bool BESettingsData::Edit(int64_t identifier,
                          NSString* name,
                          NSString* keyword,
                          NSString* url) {
  const std::u16string title = base::SysNSStringToUTF16(name);
  const std::u16string word = base::SysNSStringToUTF16(keyword);
  const std::string address = base::SysNSStringToUTF8(url);
  TemplateURLService* service = LoadedService();
  TemplateURL* engine =
      service ? service->GetTemplateURLForId(identifier) : nullptr;
  if (!engine || !IsValid(title, word, address, identifier)) {
    return false;
  }
  service->ResetTemplateURL(engine, title, word, address,
                            engine->suggestions_url());
  return true;
}

void BESettingsData::Remove(int64_t identifier) {
  TemplateURLService* service = LoadedService();
  TemplateURL* engine =
      service ? service->GetTemplateURLForId(identifier) : nullptr;
  if (engine && engine != service->GetDefaultSearchProvider() &&
      !engine->CreatedByPolicy() &&
      engine->starter_pack_id() ==
          template_url_starter_pack_data::StarterPackId::kNone) {
    service->Remove(engine);
  }
}

void BESettingsData::OnTemplateURLServiceChanged() {
  search_engines_changed_.Run();
}

void BESettingsData::OnTemplateURLServiceShuttingDown() {
  template_url_observation_.Reset();
}

// MARK: Sites with their own zoom

NSDictionary<NSString*, NSNumber*>* BESettingsData::SiteZoomLevels() {
  // SiteSettingsHandler::HandleFetchZoomLevels(): the levels set for a host,
  // as percentages.
  NSMutableDictionary<NSString*, NSNumber*>* levels =
      [NSMutableDictionary dictionary];
  for (const content::HostZoomMap::ZoomLevelChange& level :
       content::HostZoomMap::GetDefaultForBrowserContext(profile_)
           ->GetAllZoomLevels()) {
    if (level.mode != content::HostZoomMap::ZOOM_CHANGED_FOR_HOST ||
        level.host.empty()) {
      continue;
    }
    // blink::ZoomLevelToZoomFactor(): each level is 20% more (the layer may
    // not depend on Blink's headers).
    const double percent = std::round(std::pow(1.2, level.zoom_level) * 100);
    levels[base::SysUTF8ToNSString(level.host)] = @(percent);
  }
  return levels;
}

void BESettingsData::ResetZoom(NSString* host) {
  // SiteSettingsHandler::HandleRemoveZoomLevel(): back to the default.
  content::HostZoomMap* zoom_map =
      content::HostZoomMap::GetDefaultForBrowserContext(profile_);
  zoom_map->SetZoomLevelForHost(base::SysNSStringToUTF8(host),
                                zoom_map->GetDefaultZoomLevel());
}

}  // namespace browser_engine
