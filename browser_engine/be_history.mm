#import "browser_engine/be_history.h"

#include <algorithm>
#include <set>
#include <string>
#include <vector>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "chrome/browser/favicon/favicon_service_factory.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/favicon/core/favicon_service.h"
#include "components/favicon_base/favicon_types.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_types.h"
#include "components/keyed_service/core/service_access_type.h"
#include "net/base/apple/url_conversions.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

@interface BEChromiumHistoryEntry : NSObject <BEHistoryEntry>
- (instancetype)initWithURL:(NSURL*)url
                      title:(NSString*)title
                  visitTime:(NSDate*)visitTime NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumHistoryEntry

@synthesize url = _url;
@synthesize title = _title;
@synthesize visitTime = _visitTime;

- (instancetype)initWithURL:(NSURL*)url
                      title:(NSString*)title
                  visitTime:(NSDate*)visitTime {
  if ((self = [super init])) {
    _url = [url copy];
    _title = [title copy];
    _visitTime = [visitTime copy];
  }
  return self;
}

@end

namespace browser_engine {

BEHistory::BEHistory(Profile* profile)
    : profile_(profile->GetOriginalProfile()) {}

BEHistory::~BEHistory() = default;

history::HistoryService* BEHistory::service() const {
  return HistoryServiceFactory::GetForProfile(
      profile_, ServiceAccessType::EXPLICIT_ACCESS);
}

void BEHistory::Query(NSString* text,
                      NSString* host,
                      NSDate* before,
                      NSInteger count,
                      void (^completion)(NSArray<id<BEHistoryEntry>>*, BOOL)) {
  history::HistoryService* history = service();
  if (!history) {
    return;
  }
  // BrowsingHistoryHandler::HandleQueryHistory() and
  // BrowsingHistoryService::QueryHistory(): each page once a day, newest
  // first, older pages by asking again before the last one listed. Like
  // Chrome's History menu, visits that found no page aren't listed.
  history::QueryOptions options;
  options.max_count = static_cast<int>(std::max<NSInteger>(count, 1));
  options.duplicate_policy = history::QueryOptions::REMOVE_DUPLICATES_PER_DAY;
  options.policy_for_404_visits = history::VisitQuery404sPolicy::kExclude404s;
  if (before) {
    options.end_time = base::Time::FromNSDate(before);
  }
  if (host.length) {
    options.hostname_suffix = base::SysNSStringToUTF8(host);
  }
  history->QueryHistory(
      base::SysNSStringToUTF16(text ?: @""), options,
      base::BindOnce(&BEHistory::OnQueryResults, weak_factory_.GetWeakPtr(),
                     completion),
      &tracker_);
}

void BEHistory::OnQueryResults(
    void (^completion)(NSArray<id<BEHistoryEntry>>*, BOOL),
    history::QueryResults results) {
  NSMutableArray<id<BEHistoryEntry>>* entries = [NSMutableArray array];
  for (const history::URLResult& result : results) {
    // An address NSURL can't hold isn't listed: the app couldn't open it.
    NSURL* url = net::NSURLWithGURL(result.url());
    if (!url) {
      continue;
    }
    // An untitled page shows its address, as on Chrome's page.
    NSString* title =
        result.title().empty()
            ? base::SysUTF8ToNSString(result.url().possibly_invalid_spec())
            : base::SysUTF16ToNSString(result.title());
    [entries addObject:[[BEChromiumHistoryEntry alloc]
                           initWithURL:url
                                 title:title
                             visitTime:result.visit_time().ToNSDate()]];
  }
  completion(entries, results.reached_beginning());
}

void BEHistory::Remove(NSArray<id<BEHistoryEntry>>* entries,
                       void (^completion)(void)) {
  history::HistoryService* history = service();
  if (!history) {
    return;
  }
  // BrowsingHistoryService::RemoveVisits(): each page's visits on the day of
  // its entry, in one expiry.
  std::vector<history::ExpireHistoryArgs> expire_list;
  for (id<BEHistoryEntry> entry in entries) {
    GURL url = net::GURLWithNSURL(entry.url);
    if (!url.is_valid()) {
      continue;
    }
    history::ExpireHistoryArgs& args = expire_list.emplace_back();
    args.SetTimeRangeForOneDay(base::Time::FromNSDate(entry.visitTime));
    args.urls.insert(url);
  }
  if (expire_list.empty()) {
    completion();
    return;
  }
  history->ExpireHistory(expire_list, base::BindOnce(^{
                           completion();
                         }),
                         &tracker_);
}

void BEHistory::RequestFavicon(NSURL* url, void (^completion)(NSImage*)) {
  GURL page_url = net::GURLWithNSURL(url);
  // As RequestPageFavicon() (be_closed.mm) asks, but answering nil too.
  favicon::FaviconService* favicons = FaviconServiceFactory::GetForProfile(
      profile_, ServiceAccessType::EXPLICIT_ACCESS);
  if (!page_url.is_valid() || !favicons) {
    completion(nil);
    return;
  }
  favicons->GetFaviconImageForPageURL(
      page_url,
      base::BindOnce(^(const favicon_base::FaviconImageResult& result) {
        completion(result.image.AsNSImage());
      }),
      &tracker_);
}

}  // namespace browser_engine
