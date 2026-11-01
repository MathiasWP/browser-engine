#import "browser_engine/be_visited.h"

#import <AppKit/AppKit.h>

#include <string>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#import "browser_engine/be_closed.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/history/core/browser/history_service.h"
#include "components/keyed_service/core/service_access_type.h"
#include "net/base/apple/url_conversions.h"
#include "url/gurl.h"

NS_ASSUME_NONNULL_BEGIN

// One page as the app reads it. BERecentlyVisited keeps the object while the
// page is listed, and sets its title again each time it lists the pages (a
// page's title often comes after its visit).
@interface BEChromiumVisitedPage : NSObject <BEVisitedPage>
- (instancetype)initWithURL:(NSURL*)url NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readwrite, copy) NSString* title;
@property(nonatomic, readwrite, nullable) NSImage* favicon;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumVisitedPage

@synthesize title = _title;
@synthesize url = _url;
@synthesize favicon = _favicon;

- (instancetype)initWithURL:(NSURL*)url {
  if ((self = [super init])) {
    _url = [url copy];
    _title = @"";
  }
  return self;
}

@end

namespace browser_engine {

namespace {

// What Chrome's menu asks history for (history_menu_bridge.mm): the 15 pages
// visited last, in the last 90 days.
constexpr int kVisitedCount = 15;
constexpr int kVisitedScope = 90;

// How long the menu bridge waits after a change before it asks, so that a
// burst of changes (a page loading, a benchmark) makes one query.
constexpr base::TimeDelta kQueryDelay = base::Milliseconds(750);

}  // namespace

BERecentlyVisited::BERecentlyVisited() = default;

BERecentlyVisited::~BERecentlyVisited() = default;

void BERecentlyVisited::ObserveProfile(Profile* profile) {
  if (profile == profile_) {
    return;
  }
  Reset();
  // As the menu bridge: nothing for a private profile, whose history service
  // would be its original profile's.
  if (profile->IsOffTheRecord()) {
    return;
  }
  history::HistoryService* service = HistoryServiceFactory::GetForProfile(
      profile, ServiceAccessType::EXPLICIT_ACCESS);
  if (!service) {
    return;
  }
  profile_ = profile;
  history_observation_.Observe(service);
  // The first query once history has loaded (OnHistoryServiceLoaded()).
  if (service->BackendLoaded()) {
    OnHistoryChanged();
  }
}

NSArray<id<BEVisitedPage>>* BERecentlyVisited::items() const {
  return items_;
}

void BERecentlyVisited::OnURLVisited(
    history::HistoryService* history_service,
    const history::VisitedURLInfo& visited_url_info) {
  // A page that wasn't found isn't listed, so it changes nothing.
  if (visited_url_info.response_code_category ==
      history::VisitResponseCodeCategory::k404) {
    return;
  }
  OnHistoryChanged();
}

void BERecentlyVisited::OnURLsModified(history::HistoryService* history_service,
                                       const history::URLRows& changed_urls) {
  OnHistoryChanged();
}

void BERecentlyVisited::OnHistoryDeletions(
    history::HistoryService* history_service,
    const history::DeletionInfo& deletion_info) {
  OnHistoryChanged();
}

void BERecentlyVisited::OnHistoryServiceLoaded(
    history::HistoryService* history_service) {
  OnHistoryChanged();
}

void BERecentlyVisited::HistoryServiceBeingDeleted(
    history::HistoryService* history_service) {
  Reset();
}

void BERecentlyVisited::OnHistoryChanged() {
  // HistoryMenuBridge::CreateMenu(): one query at a time, 750 ms after the
  // last change. A change while history answers asks again after.
  needs_query_ = true;
  if (!query_in_progress_) {
    query_timer_.Start(FROM_HERE, kQueryDelay, this, &BERecentlyVisited::Query);
  }
}

void BERecentlyVisited::Query() {
  history::HistoryService* service = history_observation_.GetSource();
  if (!service || !service->BackendLoaded()) {
    return;  // Asked once it has loaded.
  }
  needs_query_ = false;
  query_in_progress_ = true;
  // HistoryMenuBridge::FinishCreateMenu(): each page once, at its latest
  // visit, newest first, leaving out visits that found no page.
  history::QueryOptions options;
  options.max_count = kVisitedCount;
  options.SetRecentDayRange(kVisitedScope);
  options.policy_for_404_visits = history::VisitQuery404sPolicy::kExclude404s;
  service->QueryHistory(std::u16string(), options,
                        base::BindOnce(&BERecentlyVisited::OnQueryResults,
                                       base::Unretained(this)),
                        &task_tracker_);
}

void BERecentlyVisited::OnQueryResults(history::QueryResults results) {
  query_in_progress_ = false;
  NSMutableDictionary<NSURL*, BEChromiumVisitedPage*>* listed =
      [NSMutableDictionary dictionary];
  for (BEChromiumVisitedPage* page in items_) {
    listed[page.url] = page;
  }

  NSMutableArray<BEChromiumVisitedPage*>* items = [NSMutableArray array];
  for (const history::URLResult& result : results) {
    // An address NSURL can't hold isn't listed: the app couldn't open it.
    NSURL* url = net::NSURLWithGURL(result.url());
    if (!url) {
      continue;
    }
    BEChromiumVisitedPage* page = listed[url];
    if (page) {
      [listed removeObjectForKey:url];
    } else {
      page = [[BEChromiumVisitedPage alloc] initWithURL:url];
    }
    // An untitled page shows its address, as in the menu.
    page.title =
        result.title().empty()
            ? base::SysUTF8ToNSString(result.url().possibly_invalid_spec())
            : base::SysUTF16ToNSString(result.title());
    // Asked for again with each answer until there is one, as the menu
    // bridge asks each time it lists.
    if (!page.favicon) {
      RequestFavicon(page, result.url());
    }
    [items addObject:page];
  }
  items_ = [items copy];

  if (needs_query_) {
    OnHistoryChanged();
  }
}

void BERecentlyVisited::Reset() {
  history_observation_.Reset();
  profile_ = nullptr;
  query_timer_.Stop();
  task_tracker_.TryCancelAll();
  query_in_progress_ = false;
  needs_query_ = false;
  items_ = @[];
}

void BERecentlyVisited::RequestFavicon(BEChromiumVisitedPage* page,
                                       const GURL& page_url) {
  __weak BEChromiumVisitedPage* weak_page = page;
  RequestPageFavicon(profile_, page_url, &task_tracker_, ^(NSImage* favicon) {
    BEChromiumVisitedPage* strong_page = weak_page;
    strong_page.favicon = favicon;
  });
}

}  // namespace browser_engine
