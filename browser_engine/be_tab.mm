#import "browser_engine/be_tab.h"

#import <AppKit/AppKit.h>

#include <memory>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/ssl/chrome_security_state_util.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tab_ui_helper.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/security_state/core/security_state.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

@interface BEChromiumTab ()
- (instancetype)initWithTab:(tabs::TabInterface*)tab NS_DESIGNATED_INITIALIZER;
- (void)sendUpdate;
- (void)contentsDestroyed;
@end

namespace browser_engine {

// Watches a tab's current WebContents and its favicon, and has the BETab tell
// its delegate, coalesced to one tabDidUpdate: per task however many events
// arrive (load progress fires often).
class TabObserver : public content::WebContentsObserver,
                    public favicon::FaviconDriverObserver {
 public:
  explicit TabObserver(BEChromiumTab* tab) : tab_(tab) {}
  TabObserver(const TabObserver&) = delete;
  TabObserver& operator=(const TabObserver&) = delete;
  ~TabObserver() override = default;

  void StartObserving(content::WebContents* contents) {
    favicon_observation_.Reset();
    Observe(contents);
    if (!contents) {
      return;
    }
    if (favicon::ContentFaviconDriver* driver =
            favicon::ContentFaviconDriver::FromWebContents(contents)) {
      favicon_observation_.Observe(driver);
    }
  }

  void ScheduleUpdate() {
    if (update_pending_) {
      return;
    }
    update_pending_ = true;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&TabObserver::SendUpdate,
                                  weak_factory_.GetWeakPtr()));
  }

 private:
  void SendUpdate() {
    update_pending_ = false;
    [tab_ sendUpdate];
  }

  // content::WebContentsObserver:
  void DidStartLoading() override { ScheduleUpdate(); }
  void DidStopLoading() override { ScheduleUpdate(); }
  void LoadProgressChanged(double progress) override { ScheduleUpdate(); }
  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override {
    ScheduleUpdate();
  }
  void NavigationEntryCommitted(
      const content::LoadCommittedDetails& load_details) override {
    ScheduleUpdate();
  }
  void NavigationListPruned(
      const content::PrunedDetails& pruned_details) override {
    ScheduleUpdate();
  }
  void NavigationEntriesDeleted() override { ScheduleUpdate(); }
  void TitleWasSet(content::NavigationEntry* entry) override {
    ScheduleUpdate();
  }
  void DidChangeVisibleSecurityState() override { ScheduleUpdate(); }
  void PrimaryMainFrameRenderProcessGone(
      base::TerminationStatus status) override {
    ScheduleUpdate();
  }
  void WebContentsDestroyed() override {
    // The favicon driver is WebContents user data; stop before it goes.
    favicon_observation_.Reset();
    [tab_ contentsDestroyed];
  }

  // favicon::FaviconDriverObserver:
  void OnFaviconUpdated(favicon::FaviconDriver* favicon_driver,
                        NotificationIconType notification_icon_type,
                        const GURL& icon_url,
                        bool icon_url_changed,
                        const gfx::Image& image) override {
    ScheduleUpdate();
  }

  __weak BEChromiumTab* tab_;
  bool update_pending_ = false;
  base::ScopedObservation<favicon::FaviconDriver,
                          favicon::FaviconDriverObserver>
      favicon_observation_{this};
  base::WeakPtrFactory<TabObserver> weak_factory_{this};
};

}  // namespace browser_engine

namespace {

// Every BETab the app has seen, by TabHandle. Main thread only.
NSMutableDictionary<NSNumber*, BEChromiumTab*>* Registry() {
  static NSMutableDictionary<NSNumber*, BEChromiumTab*>* registry =
      [[NSMutableDictionary alloc] init];
  return registry;
}

BESecurity SecurityFromLevel(security_state::SecurityLevel level) {
  switch (level) {
    case security_state::SECURE:
      return BESecuritySecure;
    case security_state::WARNING:
      return BESecurityWarning;
    case security_state::DANGEROUS:
      return BESecurityDangerous;
    case security_state::NONE:
    case security_state::SECURITY_LEVEL_COUNT:
      return BESecurityNone;
  }
  return BESecurityNone;
}

}  // namespace

@implementation BEChromiumTab {
  tabs::TabHandle _handle;
  std::unique_ptr<browser_engine::TabObserver> _observer;
}

@synthesize delegate = _delegate;

+ (BEChromiumTab*)tabForTab:(tabs::TabInterface*)tab {
  CHECK(tab);
  if (BEChromiumTab* existing = [self existingTabForTab:tab]) {
    return existing;
  }
  BEChromiumTab* created = [[BEChromiumTab alloc] initWithTab:tab];
  Registry()[@(tab->GetHandle().raw_value())] = created;
  return created;
}

+ (BEChromiumTab*)existingTabForTab:(tabs::TabInterface*)tab {
  return tab ? Registry()[@(tab->GetHandle().raw_value())] : nil;
}

+ (void)forgetTab:(tabs::TabInterface*)tab {
  [Registry() removeObjectForKey:@(tab->GetHandle().raw_value())];
}

- (instancetype)initWithTab:(tabs::TabInterface*)tab {
  if ((self = [super init])) {
    _handle = tab->GetHandle();
    _observer = std::make_unique<browser_engine::TabObserver>(self);
    _observer->StartObserving(tab->GetContents());
  }
  return self;
}

// The tab, or null once Chrome deleted it.
- (tabs::TabInterface*)tab {
  return _handle.Get();
}

- (content::WebContents*)contents {
  tabs::TabInterface* tab = [self tab];
  return tab ? tab->GetContents() : nullptr;
}

- (void)contentsDidChange {
  _observer->StartObserving([self contents]);
  [self scheduleUpdate];
}

- (void)scheduleUpdate {
  _observer->ScheduleUpdate();
}

- (void)sendUpdate {
  [_delegate tabDidUpdate:self];
}

- (void)contentsDestroyed {
  // Either the tab is going (closed, or dropped while detached from every
  // window), or its WebContents is being replaced and contentsDidChange
  // follows. Look once the current task is done.
  __weak BEChromiumTab* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        BEChromiumTab* strongSelf = weakSelf;
        if (strongSelf && ![strongSelf tab]) {
          [Registry() removeObjectForKey:@(strongSelf.identifier)];
        }
      }));
}

// MARK: BETab

- (int32_t)identifier {
  return _handle.raw_value();
}

- (NSView*)view {
  content::WebContents* contents = [self contents];
  return contents ? contents->GetNativeView().GetNativeNSView() : nil;
}

- (NSURL*)url {
  content::WebContents* contents = [self contents];
  if (!contents) {
    return nil;
  }
  const GURL& url = contents->GetVisibleURL();
  return url.is_valid() ? net::NSURLWithGURL(url) : nil;
}

- (NSString*)title {
  tabs::TabInterface* tab = [self tab];
  if (!tab) {
    return @"";
  }
  // Chrome's tab title: "Untitled" and loading titles as the tab strip shows
  // them.
  if (TabUIHelper* helper = TabUIHelper::From(tab)) {
    return base::SysUTF16ToNSString(helper->GetTitle());
  }
  return base::SysUTF16ToNSString(tab->GetContents()->GetTitle());
}

- (BOOL)isLoading {
  content::WebContents* contents = [self contents];
  return contents && contents->IsLoading();
}

- (double)progress {
  content::WebContents* contents = [self contents];
  return contents ? contents->GetLoadProgress() : 0;
}

- (BOOL)canGoBack {
  content::WebContents* contents = [self contents];
  return contents && contents->GetController().CanGoBack();
}

- (BOOL)canGoForward {
  content::WebContents* contents = [self contents];
  return contents && contents->GetController().CanGoForward();
}

- (BESecurity)security {
  content::WebContents* contents = [self contents];
  if (!contents) {
    return BESecurityNone;
  }
  // What Chrome's location bar shows (ChromeLocationBarModelDelegate).
  return SecurityFromLevel(chrome_security_state::GetSecurityLevel(contents));
}

- (BOOL)isCrashed {
  content::WebContents* contents = [self contents];
  return contents && contents->IsCrashed();
}

- (BOOL)isDiscarded {
  content::WebContents* contents = [self contents];
  return contents && contents->WasDiscarded();
}

- (NSImage*)favicon {
  content::WebContents* contents = [self contents];
  if (!contents) {
    return nil;
  }
  // Through the FaviconDriver interface, where these are public.
  favicon::FaviconDriver* driver =
      favicon::ContentFaviconDriver::FromWebContents(contents);
  if (!driver || !driver->FaviconIsValid()) {
    return nil;  // The app shows its default icon.
  }
  return driver->GetFavicon().AsNSImage();
}

- (void)loadURL:(NSURL*)url {
  tabs::TabInterface* tab = [self tab];
  const GURL gurl = net::GURLWithNSURL(url);
  if (!tab || !gurl.is_valid()) {
    return;
  }
  content::WebContents* contents = tab->GetContents();
  const ui::PageTransition transition = ui::PageTransitionFromInt(
      ui::PAGE_TRANSITION_TYPED | ui::PAGE_TRANSITION_FROM_ADDRESS_BAR);
  if (BrowserWindowInterface* browser = tab->GetBrowserWindowInterface()) {
    // Through Chrome's navigator, as the omnibox does.
    NavigateParams params(browser, gurl, transition);
    params.source_contents = contents;
    params.disposition = WindowOpenDisposition::CURRENT_TAB;
    Navigate(&params);
    return;
  }
  content::NavigationController::LoadURLParams params(gurl);
  params.transition_type = transition;
  contents->GetController().LoadURLWithParams(params);
}

- (void)focusPage {
  if (content::WebContents* contents = [self contents]) {
    contents->Focus();
  }
}

@end
