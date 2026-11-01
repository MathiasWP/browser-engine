#import "browser_engine/be_closed.h"

#import <AppKit/AppKit.h>

#include <stdint.h>

#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/favicon/favicon_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/sessions/tab_restore_service_factory.h"
#include "chrome/browser/ui/browser_live_tab_context.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/profile_browser_collection.h"
#include "chrome/grit/generated_resources.h"
#include "components/favicon/core/favicon_service.h"
#include "components/favicon_base/favicon_types.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/sessions/core/live_tab_context.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "components/sessions/core/session_id.h"
#include "components/sessions/core/tab_restore_types.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"

NS_ASSUME_NONNULL_BEGIN

// One entry as the app reads it. BERecentlyClosed keeps the object while the
// entry is listed, and sets it again each time it lists the entries (a
// window's tab count changes when one of its tabs is reopened).
@interface BEChromiumClosedItem : NSObject <BEClosedItem>
- (instancetype)initWithIdentifier:(int32_t)identifier
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readwrite) BOOL isWindow;
@property(nonatomic, readwrite, copy) NSString* title;
@property(nonatomic, readwrite, copy, nullable) NSURL* url;
@property(nonatomic, readwrite, nullable) NSImage* favicon;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumClosedItem

@synthesize identifier = _identifier;
@synthesize isWindow = _isWindow;
@synthesize title = _title;
@synthesize url = _url;
@synthesize favicon = _favicon;

- (instancetype)initWithIdentifier:(int32_t)identifier {
  if ((self = [super init])) {
    _identifier = identifier;
    _title = @"";
  }
  return self;
}

@end

namespace browser_engine {

namespace {

// As many as Chrome's menu lists (history_menu_bridge.mm).
constexpr NSUInteger kRecentlyClosedCount = 10;

NSString* PluralString(int message_id, size_t count) {
  return base::SysUTF16ToNSString(
      l10n_util::GetPluralStringFUTF16(message_id, static_cast<int>(count)));
}

}  // namespace

BERecentlyClosed::BERecentlyClosed() = default;

BERecentlyClosed::~BERecentlyClosed() = default;

void BERecentlyClosed::ObserveProfile(Profile* profile) {
  if (profile == profile_) {
    return;
  }
  Reset();
  sessions::TabRestoreService* service =
      TabRestoreServiceFactory::GetForProfile(profile);
  if (!service) {
    return;  // A private profile.
  }
  profile_ = profile;
  service_observation_.Observe(service);
  // As the menu bridge: the last session's entries join the list once loaded
  // (TabRestoreServiceLoaded()); what was closed since is there already.
  if (!service->IsLoaded()) {
    service->LoadTabsFromLastSession();
  }
  Update();
}

NSArray<id<BEClosedItem>>* BERecentlyClosed::items() const {
  return items_;
}

void BERecentlyClosed::TabRestoreServiceChanged(
    sessions::TabRestoreService* service) {
  Update();
}

void BERecentlyClosed::TabRestoreServiceDestroyed(
    sessions::TabRestoreService* service) {
  Reset();
}

void BERecentlyClosed::TabRestoreServiceLoaded(
    sessions::TabRestoreService* service) {
  // Changed() isn't called when the service was empty when it loaded.
  Update();
}

void BERecentlyClosed::Update() {
  NSMutableDictionary<NSNumber*, BEChromiumClosedItem*>* listed =
      [NSMutableDictionary dictionary];
  for (BEChromiumClosedItem* item in items_) {
    listed[@(item.identifier)] = item;
  }

  // HistoryMenuBridge::TabRestoreServiceChanged(): the first ten entries it
  // doesn't skip. A window, group or split with no tabs is skipped. Groups and
  // splits are titled as in the menu, and have no address or icon here (the
  // menu draws a group's color).
  NSMutableArray<BEChromiumClosedItem*>* items = [NSMutableArray array];
  for (const std::unique_ptr<sessions::tab_restore::Entry>& entry :
       service_observation_.GetSource()->entries()) {
    if (items.count >= kRecentlyClosedCount) {
      break;
    }
    NSString* title = nil;
    GURL page_url;
    BOOL is_window = NO;
    switch (entry->type) {
      case sessions::tab_restore::Type::TAB: {
        const auto& tab =
            static_cast<const sessions::tab_restore::Tab&>(*entry);
        if (tab.navigations.empty()) {
          continue;
        }
        const sessions::SerializedNavigationEntry& navigation =
            tab.navigations.at(tab.normalized_navigation_index());
        page_url = navigation.virtual_url();
        // An untitled page shows its address, as in the menu.
        title = navigation.title().empty()
                    ? base::SysUTF8ToNSString(page_url.possibly_invalid_spec())
                    : base::SysUTF16ToNSString(navigation.title());
        break;
      }
      case sessions::tab_restore::Type::WINDOW: {
        const auto& window =
            static_cast<const sessions::tab_restore::Window&>(*entry);
        if (window.tabs.empty()) {
          continue;
        }
        is_window = YES;
        title = PluralString(IDS_RECENTLY_CLOSED_WINDOW, window.tabs.size());
        break;
      }
      case sessions::tab_restore::Type::GROUP: {
        const auto& group =
            static_cast<const sessions::tab_restore::Group&>(*entry);
        if (group.tabs.empty()) {
          continue;
        }
        const std::u16string& name = group.visual_data.title();
        if (name.empty()) {
          title = PluralString(IDS_RECENTLY_CLOSED_GROUP_UNNAMED,
                               group.tabs.size());
        } else {
          std::u16string group_title = l10n_util::GetPluralStringFUTF16(
              IDS_RECENTLY_CLOSED_GROUP, static_cast<int>(group.tabs.size()));
          group_title =
              base::ReplaceStringPlaceholders(group_title, name, nullptr);
          title = base::SysUTF16ToNSString(group_title);
        }
        break;
      }
      case sessions::tab_restore::Type::SPLIT: {
        const auto& split =
            static_cast<const sessions::tab_restore::Split&>(*entry);
        if (split.tabs.empty()) {
          continue;
        }
        title = base::SysUTF16ToNSString(
            l10n_util::GetStringUTF16(IDS_RECENTLY_CLOSED_SPLIT));
        break;
      }
    }
    if (!title) {
      continue;
    }

    const int32_t identifier = entry->id.id();
    BEChromiumClosedItem* item = listed[@(identifier)];
    if (!item) {
      item = [[BEChromiumClosedItem alloc] initWithIdentifier:identifier];
    }
    item.isWindow = is_window;
    item.title = title;
    NSURL* url = page_url.is_valid() ? net::NSURLWithGURL(page_url) : nil;
    if (!(url == item.url || [url isEqual:item.url])) {
      item.url = url;
      item.favicon = nil;
    }
    // Asked for again with each change until there is one, as the menu
    // bridge asks each time it lists.
    if (url && !item.favicon) {
      RequestFavicon(item, page_url);
    }
    [items addObject:item];
  }
  items_ = [items copy];
}

void BERecentlyClosed::Reset() {
  service_observation_.Reset();
  profile_ = nullptr;
  favicon_tracker_.TryCancelAll();
  items_ = @[];
}

void BERecentlyClosed::RequestFavicon(BEChromiumClosedItem* item,
                                      const GURL& page_url) {
  __weak BEChromiumClosedItem* weak_item = item;
  NSURL* requested_url = item.url;
  RequestPageFavicon(
      profile_, page_url, &favicon_tracker_, ^(NSImage* favicon) {
        BEChromiumClosedItem* strong_item = weak_item;
        // Unless the item shows another page by now.
        if (strong_item && [strong_item.url isEqual:requested_url]) {
          strong_item.favicon = favicon;
        }
      });
}

void RestoreClosedItem(BrowserWindowInterface* browser, int32_t identifier) {
  const SessionID id = SessionID::FromSerializedValue(identifier);
  if (!id.is_valid() || !g_browser_process) {
    return;
  }
  // The entries -[BEEngine recentlyClosed] lists.
  Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
  sessions::TabRestoreService* service =
      profile ? TabRestoreServiceFactory::GetForProfile(profile) : nullptr;
  if (!service) {
    return;
  }
  // Into `browser` if it's one of the profile's windows. Else, as Chrome's
  // menu does, into the profile's last active window, or a new one if there
  // is none: never into a private window.
  if (!browser || browser->GetProfile() != profile) {
    ProfileBrowserCollection* collection =
        ProfileBrowserCollection::GetForProfile(profile);
    browser = collection ? collection->FindTabbedBrowser() : nullptr;
  }
  sessions::LiveTabContext* context =
      browser ? BrowserLiveTabContext::From(browser) : nullptr;
  // As app_controller_mac::TabRestorer::DoRestoreTab(), with no disposition
  // (TabRestoreServiceHelper::RestoreTab()): a tab closed in this session goes
  // back to its window if that's still open, else to a new one; one from the
  // last session goes into `context`. A window opens as it was. An id that
  // isn't listed does nothing.
  service->RestoreEntryById(context, id, WindowOpenDisposition::UNKNOWN);
}

void RequestPageFavicon(Profile* profile,
                        const GURL& page_url,
                        base::CancelableTaskTracker* tracker,
                        void (^done)(NSImage* favicon)) {
  // What the menu bridge asks for: the page's favicon from history, 16 points.
  favicon::FaviconService* service = FaviconServiceFactory::GetForProfile(
      profile, ServiceAccessType::EXPLICIT_ACCESS);
  if (!service) {
    return;
  }
  service->GetFaviconImageForPageURL(
      page_url,
      base::BindOnce(^(const favicon_base::FaviconImageResult& result) {
        // Nil for a page history has no icon for.
        if (NSImage* image = result.image.AsNSImage()) {
          done(image);
        }
      }),
      tracker);
}

}  // namespace browser_engine
