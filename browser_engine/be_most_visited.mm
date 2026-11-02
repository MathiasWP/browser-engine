#import "browser_engine/be_most_visited.h"

#import <AppKit/AppKit.h>

#include <utility>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_engine.h"
#import "browser_engine/be_visited_page.h"
#include "chrome/browser/favicon/large_icon_service_factory.h"
#include "chrome/browser/ntp_tiles/chrome_most_visited_sites_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "components/favicon/core/large_icon_service.h"
#include "components/favicon_base/favicon_types.h"
#include "components/ntp_tiles/constants.h"
#include "components/ntp_tiles/section_type.h"
#include "net/base/apple/url_conversions.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

namespace browser_engine {

namespace {

// Icons at tile size for a Retina screen; smaller ones would look blurred, so
// the app shows its own placeholder for a site without one (as the new tab
// page's monogram does).
constexpr int kMinIconSize = 32;
constexpr int kIconSize = 64;

}  // namespace

BEMostVisited::BEMostVisited() = default;

BEMostVisited::~BEMostVisited() {
  if (sites_) {
    sites_->RemoveMostVisitedURLsObserver(this);
  }
}

void BEMostVisited::ObserveProfile(Profile* profile) {
  if (profile == profile_) {
    return;
  }
  if (sites_) {
    sites_->RemoveMostVisitedURLsObserver(this);
    sites_.reset();
  }
  icon_tracker_.TryCancelAll();
  items_ = nil;
  profile_ = profile;
  // As the third-party new tab page sets it up (new_tab_page_third_party_
  // ui.cc, MostVisitedHandler): top sites only, as many as Chrome shows. Null
  // for an off-the-record profile.
  sites_ = ChromeMostVisitedSitesFactory::NewForProfile(profile);
  if (!sites_) {
    return;
  }
  sites_->EnableTileTypes(
      ntp_tiles::MostVisitedSites::EnableTileTypesOptions().with_top_sites(
          true));
  sites_->AddMostVisitedURLsObserver(this, ntp_tiles::kMaxNumMostVisited);
}

NSArray<id<BEVisitedPage>>* BEMostVisited::items() const {
  return items_ ? items_ : @[];
}

void BEMostVisited::SetRemoved(const GURL& url, bool removed) {
  if (sites_) {
    // MostVisitedHandler::DeleteMostVisitedTile() and RestoreMostVisitedDefaults().
    sites_->AddOrRemoveBlockedUrl(url, removed);
  }
}

void BEMostVisited::OnURLsAvailable(
    bool is_user_triggered,
    const std::map<ntp_tiles::SectionType, ntp_tiles::NTPTilesVector>&
        sections) {
  auto it = sections.find(ntp_tiles::SectionType::PERSONALIZED);
  if (it == sections.end()) {
    return;
  }
  // A site listed again keeps its object, and with it its icon.
  NSMutableDictionary<NSURL*, BEChromiumVisitedPage*>* listed =
      [NSMutableDictionary dictionary];
  for (BEChromiumVisitedPage* page in items_) {
    listed[page.url] = page;
  }
  NSMutableArray<BEChromiumVisitedPage*>* items = [NSMutableArray array];
  for (const ntp_tiles::NTPTile& tile : it->second) {
    NSURL* url = net::NSURLWithGURL(tile.url);
    if (!url) {
      continue;
    }
    BEChromiumVisitedPage* page = listed[url];
    if (!page) {
      page = [[BEChromiumVisitedPage alloc] initWithURL:url];
      LoadIcon(page);
    }
    NSString* title = base::SysUTF16ToNSString(tile.title);
    page.title = title.length ? title : url.host ? url.host : url.absoluteString;
    [items addObject:page];
  }
  items_ = [items copy];
  NotifyChange();
}

void BEMostVisited::OnIconMadeAvailable(const GURL& site_url) {
  NSURL* url = net::NSURLWithGURL(site_url);
  for (BEChromiumVisitedPage* page in items_) {
    if ([page.url isEqual:url]) {
      LoadIcon(page);
    }
  }
}

void BEMostVisited::LoadIcon(BEChromiumVisitedPage* page) {
  favicon::LargeIconService* service =
      profile_ ? LargeIconServiceFactory::GetForBrowserContext(profile_)
               : nullptr;
  if (!service) {
    return;
  }
  // The local database only: never the Google server variants.
  __weak BEChromiumVisitedPage* weak_page = page;
  base::WeakPtr<BEMostVisited> weak_self = weak_factory_.GetWeakPtr();
  service->GetLargeIconImageOrFallbackStyleForPageUrl(
      net::GURLWithNSURL(page.url), kMinIconSize, kIconSize,
      base::BindOnce(^(const favicon_base::LargeIconImageResult& result) {
        BEChromiumVisitedPage* strong_page = weak_page;
        if (weak_self && strong_page && !result.image.IsEmpty()) {
          strong_page.favicon = result.image.ToNSImage();
          weak_self->NotifyChange();
        }
      }),
      &icon_tracker_);
}

void BEMostVisited::NotifyChange() {
  if (change_pending_) {
    return;
  }
  change_pending_ = true;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BEMostVisited::SendChange,
                                weak_factory_.GetWeakPtr()));
}

void BEMostVisited::SendChange() {
  change_pending_ = false;
  [GetEngineDelegate() engineDidChangeMostVisited:GetEngine()];
}

}  // namespace browser_engine
