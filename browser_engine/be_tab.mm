#import "browser_engine/be_tab.h"

#import <AppKit/AppKit.h>

#include <memory>
#include <string>

#include "base/callback_list.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_passwords.h"
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "chrome/browser/devtools/devtools_contents_resizing_strategy.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/favicon/favicon_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ssl/chrome_security_state_util.h"
#include "chrome/browser/ui/bookmarks/bookmark_tab_helper.h"
#include "chrome/browser/ui/bookmarks/bookmark_tab_helper_observer.h"
#include "chrome/browser/ui/bookmarks/bookmark_utils.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/bubble_anchor_util.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/page_info/page_info_dialog.h"
#include "chrome/browser/ui/recently_audible_helper.h"
#include "chrome/browser/ui/tab_ui_helper.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_muted_utils.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_utils.h"
#include "components/bookmarks/common/bookmark_pref_names.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/prefs/pref_service.h"
#include "components/security_state/core/security_state.h"
#include "components/tabs/public/tab_interface.h"
#include "components/zoom/zoom_controller.h"
#include "components/zoom/zoom_observer.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

@interface BEChromiumTab ()
- (instancetype)initWithTab:(tabs::TabInterface*)tab NS_DESIGNATED_INITIALIZER;
- (void)sendUpdate;
- (void)contentsDestroyed;
@end

namespace browser_engine {

// Watches a tab's current WebContents, its favicon, its star, its zoom and its
// sound, and has the BETab tell its delegate, coalesced to one tabDidUpdate:
// per task however many events arrive (load progress fires often).
class TabObserver : public content::WebContentsObserver,
                    public favicon::FaviconDriverObserver,
                    public BookmarkTabHelperObserver,
                    public zoom::ZoomObserver {
 public:
  explicit TabObserver(BEChromiumTab* tab) : tab_(tab) {}
  TabObserver(const TabObserver&) = delete;
  TabObserver& operator=(const TabObserver&) = delete;
  ~TabObserver() override = default;

  void StartObserving(content::WebContents* contents) {
    favicon_observation_.Reset();
    bookmark_observation_.Reset();
    zoom_observation_.Reset();
    audible_subscription_ = {};
    Observe(contents);
    if (!contents) {
      return;
    }
    if (favicon::ContentFaviconDriver* driver =
            favicon::ContentFaviconDriver::FromWebContents(contents)) {
      favicon_observation_.Observe(driver);
    }
    // What Chrome's star watches (BookmarkPageActionController): the page's
    // address against the profile's bookmarks, whoever changed them. Every
    // tab has one (TabHelpers::AttachTabHelpers()).
    if (BookmarkTabHelper* helper =
            BookmarkTabHelper::FromWebContents(contents)) {
      bookmark_observation_.Observe(helper);
    }
    // What Chrome's zoom icon and bubble show (ZoomBubbleView): the page's
    // ZoomController, which every tab has (TabHelpers::AttachTabHelpers()).
    if (zoom::ZoomController* zoom_controller =
            zoom::ZoomController::FromWebContents(contents)) {
      zoom_observation_.Observe(zoom_controller);
    }
    // What the tab strip's speaker follows (TabAlertController): sound now,
    // or until two seconds after it stopped. Every tab has one
    // (TabHelpers::AttachTabHelpers()).
    if (RecentlyAudibleHelper* audible_helper =
            RecentlyAudibleHelper::FromWebContents(contents)) {
      audible_subscription_ =
          audible_helper->RegisterRecentlyAudibleChangedCallback(
              base::BindRepeating(&TabObserver::OnRecentlyAudibleChanged,
                                  base::Unretained(this)));
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

  void OnRecentlyAudibleChanged(bool was_recently_audible) {
    ScheduleUpdate();
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
  void DidUpdateAudioMutingState(bool muted) override { ScheduleUpdate(); }
  void WebContentsDestroyed() override {
    // The favicon driver, the bookmark helper, the zoom controller and the
    // audible helper are WebContents user data; stop before they go.
    favicon_observation_.Reset();
    bookmark_observation_.Reset();
    zoom_observation_.Reset();
    audible_subscription_ = {};
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

  // BookmarkTabHelperObserver:
  void URLStarredChanged(content::WebContents* web_contents,
                         bool starred) override {
    ScheduleUpdate();
  }

  // zoom::ZoomObserver:
  void OnZoomChanged(
      const zoom::ZoomController::ZoomChangedEventData& data) override {
    ScheduleUpdate();
  }
  void OnZoomControllerDestroyed(
      zoom::ZoomController* zoom_controller) override {
    // The controller tells its observers as its WebContents goes, which may
    // be before WebContentsDestroyed() reaches us, and as it's deleted.
    zoom_observation_.Reset();
  }

  __weak BEChromiumTab* tab_;
  bool update_pending_ = false;
  base::ScopedObservation<favicon::FaviconDriver,
                          favicon::FaviconDriverObserver>
      favicon_observation_{this};
  base::ScopedObservation<BookmarkTabHelper, BookmarkTabHelperObserver>
      bookmark_observation_{this};
  base::ScopedObservation<zoom::ZoomController, zoom::ZoomObserver>
      zoom_observation_{this};
  base::CallbackListSubscription audible_subscription_;
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
  std::unique_ptr<browser_engine::TabPasswordOffer> _passwordOffer;
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
    _passwordOffer =
        std::make_unique<browser_engine::TabPasswordOffer>(tab, self);
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
  // Chrome's password state can change with nothing the tab watches (a page
  // that signs in without navigating); look again before every update.
  _passwordOffer->Update();
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

- (NSView*)devToolsView {
  // What BrowserView shows behind the page (DevtoolsUIController): docked
  // DevTools, or undocked DevTools' device-mode toolbox.
  content::WebContents* devtools =
      DevToolsWindow::GetInTabWebContents([self contents], nullptr);
  return devtools ? devtools->GetNativeView().GetNativeNSView() : nil;
}

- (NSRect)pageFrameWithDevToolsInBounds:(NSRect)bounds {
  DevToolsContentsResizingStrategy strategy;
  if (!DevToolsWindow::GetInTabWebContents([self contents], &strategy)) {
    return bounds;
  }
  // As ContentsContainerView lays out, from the top-left corner of the area;
  // `bounds` is AppKit's, from the bottom left.
  const gfx::Rect container(gfx::Size(bounds.size));
  gfx::Rect devtools_bounds;
  gfx::Rect page_bounds;
  ApplyDevToolsContentsResizingStrategy(strategy, container, &devtools_bounds,
                                        &page_bounds);
  if (page_bounds == container) {
    return bounds;  // Not rounded down to whole points.
  }
  return NSMakeRect(NSMinX(bounds) + page_bounds.x(),
                    NSMaxY(bounds) - page_bounds.bottom(), page_bounds.width(),
                    page_bounds.height());
}

- (id<BEPasswordOffer>)passwordOffer {
  return _passwordOffer->offer();
}

- (BOOL)isBookmarked {
  content::WebContents* contents = [self contents];
  if (!contents) {
    return NO;
  }
  // Chrome's star: NO until the bookmarks are loaded, then looked at again
  // (BookmarkTabHelper::BookmarkModelLoaded()).
  BookmarkTabHelper* helper = BookmarkTabHelper::FromWebContents(contents);
  return helper && helper->is_starred();
}

- (NSInteger)zoomPercent {
  content::WebContents* contents = [self contents];
  zoom::ZoomController* zoom_controller =
      contents ? zoom::ZoomController::FromWebContents(contents) : nullptr;
  // What Chrome's zoom bubble shows (ZoomBubbleView::UpdateZoomPercent()), and
  // 100 at the default zoom, where Chrome shows no zoom icon.
  if (!zoom_controller || zoom_controller->IsAtDefaultZoom()) {
    return 100;
  }
  return zoom_controller->GetZoomPercent();
}

- (BOOL)isAudible {
  content::WebContents* contents = [self contents];
  RecentlyAudibleHelper* helper =
      contents ? RecentlyAudibleHelper::FromWebContents(contents) : nullptr;
  // The tab strip's speaker (TabAlertController::
  // OnRecentlyAudibleStateChanged()), shown crossed out while muted.
  return helper && helper->WasRecentlyAudible();
}

- (BOOL)isMuted {
  content::WebContents* contents = [self contents];
  return contents && contents->IsAudioMuted();
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

- (void)showSiteInfo {
  // As the lock in Chrome's omnibox does. Anchored to the location bar, which
  // floats it over our window (BELocationBar::GetChipAnchor()).
  ShowPageInfoDialog([self contents], base::DoNothing(),
                     bubble_anchor_util::Anchor::kLocationBar);
}

- (void)setBookmarked:(BOOL)bookmarked {
  content::WebContents* contents = [self contents];
  if (!contents) {
    return;
  }
  // A private window's tabs use their original profile's bookmarks, as
  // Chrome's star does there (BookmarkModelFactory redirects to it).
  Profile* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  bookmarks::BookmarkModel* model =
      BookmarkModelFactory::GetForBrowserContext(profile);
  // As chrome::CanBookmarkCurrentTab(), which enables ⌘D: nothing until the
  // bookmarks are loaded, or while policy turns editing them off (which also
  // hides the star).
  if (!model || !model->loaded() ||
      !profile->GetPrefs()->GetBoolean(
          bookmarks::prefs::kEditBookmarksEnabled)) {
    return;
  }
  // The address the star is for (the new tab page's is chrome://newtab).
  GURL url;
  std::u16string title;
  if (!chrome::GetURLAndTitleToBookmark(contents, &url, &title)) {
    return;  // No page.
  }
  if (!bookmarked) {
    // Every bookmark of it the user can edit. Managed ones (policy) stay, and
    // keep the star lit, as in Chrome.
    bookmarks::RemoveAllBookmarks(model, url, FROM_HERE);
    return;
  }
  // chrome::BookmarkCurrentTab() for this tab, not the window's active one,
  // and without its bubble.
  if (!model->IsBookmarked(url) && profile->IsOffTheRecord()) {
    // Private windows keep no favicons; save this one for the bookmark.
    favicon::SaveFaviconEvenIfInIncognito(contents);
  }
  // Into the folder Chrome last used (bookmarks::GetParentForNewNodes()),
  // unless the user has bookmarked the address already.
  bookmarks::AddIfNotBookmarked(model, url, title);
}

- (void)setMuted:(BOOL)muted {
  content::WebContents* contents = [self contents];
  if (!contents || contents->IsAudioMuted() == static_cast<bool>(muted)) {
    return;  // Keeps the reason Chrome recorded (an extension's, say).
  }
  // As the tab strip's audio button (BrowserTabStripController::
  // ToggleTabAudioMute()), which records why (extensions read it in
  // chrome.tabs' mutedInfo).
  SetTabAudioMuted(contents, muted, TabMutedReason::kAudioIndicator,
                   std::string());
}

@end
