// Web panels (BEWebPanel, BEEngineWebPanels): a page of the app's own UI (its
// chat) in a WebContents the layer makes and owns, in no window's tab strip,
// whose view the app puts where it wants. Made as Chrome makes its own pages
// outside the strip (views::WebView: WebContents::Create(), no tab helpers),
// which is what keeps it out of history (HistoryTabHelper), sessions and
// recently closed (the tab strip), discarding (Memory Saver discards tabs'
// pages only: DiscardEligibilityPolicy's kNotATab), autofill and passwords
// (their clients are tab helpers), Chrome's tab search and the address bar's
// open tabs. Its storage is an in-memory StoragePartition of the profile,
// shared by every panel; a navigation throttle of its own keeps it to the
// app's folder.
//
// A partition and not a profile of its own: an off-the-record profile would
// start a second set of Chrome's services for one page and still load the
// extensions allowed in incognito, and the system profile (the profile
// picker's) lacks most services, which Chrome's code for an ordinary page
// expects. The partition keeps cookies, storage and cache apart; what the page
// still shares with the profile is in README.md.

#import "browser_engine/be_engine.h"

#import <AppKit/AppKit.h>

#include <memory>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/raw_ref.h"
#include "base/memory/weak_ptr.h"
#include "base/process/kill.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/current_thread.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_devtools_session.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/ui/waap/waap_utils.h"
#include "chrome/grit/generated_resources.h"
#include "components/input/native_web_keyboard_event.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/site_instance.h"
#include "content/public/browser/storage_partition_config.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "net/base/apple/url_conversions.h"
// What content's ContextMenuParams::edit_flags holds; //browser_engine may not
// depend on blink's common headers itself.
#include "third_party/blink/public/common/context_menu_data/edit_flags.h"  // nogncheck
#include "ui/base/l10n/l10n_util_mac.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/views/cocoa/native_widget_mac_ns_window_host.h"
#include "url/gurl.h"
#include "url/url_constants.h"

// The BEWebPanel the app holds; its page is a WebPanelHost's.
@interface BEChromiumWebPanel : NSObject <BEWebPanel>
- (instancetype)
    initWithProfile:(Profile*)profile
          keepAlive:(std::unique_ptr<ScopedProfileKeepAlive>)keepAlive
             folder:(const GURL&)folder NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// From the page: each reaches the delegate on a later task.
- (void)pageDidFinishLoading;
- (void)pageWantsURL:(const GURL&)url;
- (void)pageDidCrash;
- (void)chromiumDidClose;
@end

// One item of a panel's right-click menu: runs its block.
@interface BEWebPanelMenuAction : NSObject
- (instancetype)initWithBlock:(void (^)(void))block NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)run:(id)sender;
@end

@implementation BEWebPanelMenuAction {
  void (^_block)(void);
}

- (instancetype)initWithBlock:(void (^)(void))block {
  if ((self = [super init])) {
    _block = [block copy];
  }
  return self;
}

- (void)run:(id)sender {
  _block();
}

@end

namespace browser_engine {

namespace {

// The panels' storage: one partition of the profile, in memory, for every
// panel, kept while the profile is loaded (content keeps a partition it has
// made). StoragePartitionConfig wants [a-z] for a domain; agents' begin with
// "beagent" (be_agent_tabs.mm).
constexpr char kPartitionDomain[] = "bewebpanel";

// Addresses that mean something only in the page that has them: nothing for
// the app to open.
bool IsPageOnly(const GURL& url) {
  return !url.is_valid() || url.SchemeIs(url::kAboutScheme) ||
         url.SchemeIs(url::kJavaScriptScheme) ||
         url.SchemeIs(url::kDataScheme) || url.SchemeIs(url::kBlobScheme) ||
         url.SchemeIs(url::kFileSystemScheme);
}

// The panel's WebContents, as its delegate and its observer: what its page may
// load, what it hands the app, its right-click menu and the keys it leaves.
// Lives as long as the BEChromiumWebPanel; the page goes earlier on Close().
class WebPanelHost : public content::WebContentsDelegate,
                     public content::WebContentsObserver,
                     public ProfileObserver,
                     public ProfileManagerObserver {
 public:
  WebPanelHost(BEChromiumWebPanel* panel,
               Profile* profile,
               std::unique_ptr<ScopedProfileKeepAlive> keep_alive,
               const GURL& folder);
  WebPanelHost(const WebPanelHost&) = delete;
  WebPanelHost& operator=(const WebPanelHost&) = delete;
  ~WebPanelHost() override;

  // The page's WebContents; null once closed.
  content::WebContents* contents() { return contents_.get(); }

  // Whether `url` is one of the panel's own pages: a file:// URL in its folder.
  bool IsPanelPage(const GURL& url) const;
  // `url` doesn't load here: the app may open it.
  void Refuse(const GURL& url);
  // The app's loadURL:.
  void Load(const GURL& url);
  // Destroys the page; nothing more is told.
  void Close();

 private:
  // Chromium closes the page: its profile goes.
  void CloseForChromium();

  // content::WebContentsDelegate:
  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>
          navigation_handle_callback) override;
  bool IsWebContentsCreationOverridden(
      content::RenderFrameHost* opener,
      content::SiteInstance* source_site_instance,
      content::mojom::WindowContainerType window_container_type,
      const GURL& opener_url,
      const std::string& frame_name,
      const GURL& target_url) override;
  content::WebContents* CreateCustomWebContents(
      content::RenderFrameHost* opener,
      content::SiteInstance* source_site_instance,
      bool is_new_browsing_instance,
      const GURL& opener_url,
      const std::string& frame_name,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      const content::StoragePartitionConfig& partition_config,
      content::SessionStorageNamespaceHandle* session_storage_namespace)
      override;
  bool HandleContextMenu(content::RenderFrameHost& render_frame_host,
                         const content::ContextMenuParams& params) override;
  bool HandleKeyboardEvent(content::WebContents* source,
                           const input::NativeWebKeyboardEvent& event) override;

  // content::WebContentsObserver:
  void DidStartNavigation(content::NavigationHandle* navigation) override;
  void DidFinishLoad(content::RenderFrameHost* render_frame_host,
                     const GURL& validated_url) override;
  void PrimaryMainFrameRenderProcessGone(
      base::TerminationStatus status) override;

  // ProfileObserver:
  void OnProfileWillBeDestroyed(Profile* profile) override;

  // ProfileManagerObserver:
  void OnProfileMarkedForPermanentDeletion(Profile* profile) override;
  void OnProfileManagerDestroying() override;

  __weak BEChromiumWebPanel* panel_;
  const GURL folder_;
  // The folder's path in its URL, ending in "/".
  std::string folder_path_;
  raw_ptr<Profile> profile_;
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive_;
  std::unique_ptr<content::WebContents> contents_;
  base::ScopedObservation<Profile, ProfileObserver> profile_observation_{this};
  base::ScopedObservation<ProfileManager, ProfileManagerObserver>
      profile_manager_observation_{this};
  base::WeakPtrFactory<WebPanelHost> weak_factory_{this};
};

// Keeps a panel's navigations, its page's and its frames', redirects included,
// to its folder. The page's going anywhere else is cancelled (the page stays
// as it was) and its address offered to the app, as is a frame's the user
// clicked for; the frame shows Chrome's error. Added to each navigation from
// DidStartNavigation()
// with RegisterThrottleForTesting(), the way content's own
// TestNavigationThrottleInserter adds one, so no touch point is needed: at 156
// that isn't test-only (NavigationRequest only CHECKs that the navigation
// isn't a page activation), and content keeps throttles added before its own
// and runs them last (NavigationThrottleRegistryImpl::
// RegisterNavigationThrottles()). The registry a throttle is made with is
// only its way to its navigation, and for one that defers, to resuming it,
// which this one never does; so this throttle is its own registry.
class WebPanelThrottle final : public content::NavigationThrottleRegistry,
                               public content::NavigationThrottle {
 public:
  WebPanelThrottle(content::NavigationHandle& navigation,
                   base::WeakPtr<WebPanelHost> host)
      : content::NavigationThrottle(
            static_cast<content::NavigationThrottleRegistry&>(*this)),
        navigation_(navigation),
        host_(std::move(host)) {}
  WebPanelThrottle(const WebPanelThrottle&) = delete;
  WebPanelThrottle& operator=(const WebPanelThrottle&) = delete;
  ~WebPanelThrottle() override = default;

  // content::NavigationThrottleRegistry:
  content::NavigationHandle& GetNavigationHandle() override {
    return *navigation_;
  }
  void AddThrottle(
      std::unique_ptr<content::NavigationThrottle> throttle) override {
    navigation_->RegisterThrottleForTesting(std::move(throttle));
  }
  bool HasThrottle(const std::string& name) override { return false; }
  bool EraseThrottleForTesting(const std::string& name) override {
    return false;
  }

  // content::NavigationThrottle:
  ThrottleCheckResult WillStartRequest() override { return Check(); }
  ThrottleCheckResult WillRedirectRequest() override { return Check(); }
  const char* GetNameForLogging() override { return "BEWebPanelThrottle"; }

 private:
  ThrottleCheckResult Check() {
    const GURL& url = navigation_->GetURL();
    if (host_ && host_->IsPanelPage(url)) {
      return PROCEED;
    }
    const bool is_page = navigation_->IsInPrimaryMainFrame();
    if (host_ && (is_page || navigation_->HasUserGesture())) {
      host_->Refuse(url);
    }
    return is_page ? CANCEL_AND_IGNORE : BLOCK_REQUEST;
  }

  const raw_ref<content::NavigationHandle> navigation_;
  const base::WeakPtr<WebPanelHost> host_;
};

using MenuBlock = void (^)(void);

// `command` (Cut, Paste…) on the page's focused frame, while the panel is open.
MenuBlock EditCommand(base::WeakPtr<WebPanelHost> host,
                      void (content::WebContents::*command)()) {
  return [^{
    if (content::WebContents* contents = host ? host->contents() : nullptr) {
      (contents->*command)();
    }
  } copy];
}

// Chrome's "Copy link address" (RenderViewContextMenu::WriteURLToClipboard()):
// a mail link's address alone.
void CopyLink(const GURL& url) {
  NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:base::SysUTF8ToNSString(url.SchemeIs(url::kMailToScheme)
                                                    ? std::string(url.path())
                                                    : url.spec())
                forType:NSPasteboardTypeString];
}

// The panel's right-click menu, at the click, returning once it closes: a
// misspelling's suggestions, the link's address, and editing. Nothing of
// Chrome's own menu (RenderViewContextMenu), whose items open Chrome's pages,
// windows and tabs.
void ShowContextMenu(base::WeakPtr<WebPanelHost> host,
                     const content::ContextMenuParams& params) {
  content::WebContents* contents = host ? host->contents() : nullptr;
  content::RenderWidgetHostView* page =
      contents ? contents->GetRenderWidgetHostView() : nullptr;
  NSView* view = page ? page->GetNativeView().GetNativeNSView() : nil;
  if (!view.window) {
    return;
  }
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
  menu.autoenablesItems = NO;
  auto add = [menu](NSString* title, bool enabled, MenuBlock block) {
    BEWebPanelMenuAction* action =
        [[BEWebPanelMenuAction alloc] initWithBlock:block];
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(run:)
                                           keyEquivalent:@""];
    // An item's target is weak; its represented object keeps the action.
    item.target = action;
    item.representedObject = action;
    item.enabled = enabled;
    [menu addItem:item];
  };
  auto add_command = [&](int title, int flag,
                         void (content::WebContents::*command)()) {
    add(l10n_util::GetNSStringWithFixup(title), params.edit_flags & flag,
        EditCommand(host, command));
  };
  auto separate = [menu] {
    if (menu.numberOfItems && !menu.itemArray.lastObject.separatorItem) {
      [menu addItem:[NSMenuItem separatorItem]];
    }
  };

  if (params.is_editable && !params.misspelled_word.empty()) {
    for (const std::u16string& suggestion : params.dictionary_suggestions) {
      // Its own copy, for the block.
      const std::u16string word = suggestion;
      add(base::SysUTF16ToNSString(word), true, [^{
            if (content::WebContents* page_contents =
                    host ? host->contents() : nullptr) {
              page_contents->ReplaceMisspelling(word);
            }
          } copy]);
    }
    separate();
  }
  if (!IsPageOnly(params.link_url)) {
    const GURL link = params.link_url;
    add(l10n_util::GetNSStringWithFixup(IDS_CONTENT_CONTEXT_COPYLINKLOCATION),
        true, [^{
          CopyLink(link);
        } copy]);
    separate();
  }
  if (params.is_editable) {
    add_command(IDS_CONTENT_CONTEXT_UNDO,
                blink::ContextMenuDataEditFlags::kCanUndo,
                &content::WebContents::Undo);
    add_command(IDS_CONTENT_CONTEXT_REDO,
                blink::ContextMenuDataEditFlags::kCanRedo,
                &content::WebContents::Redo);
    separate();
    add_command(IDS_CONTENT_CONTEXT_CUT,
                blink::ContextMenuDataEditFlags::kCanCut,
                &content::WebContents::Cut);
    add_command(IDS_CONTENT_CONTEXT_COPY,
                blink::ContextMenuDataEditFlags::kCanCopy,
                &content::WebContents::Copy);
    add_command(IDS_CONTENT_CONTEXT_PASTE,
                blink::ContextMenuDataEditFlags::kCanPaste,
                &content::WebContents::Paste);
    separate();
    add_command(IDS_CONTENT_CONTEXT_SELECTALL,
                blink::ContextMenuDataEditFlags::kCanSelectAll,
                &content::WebContents::SelectAll);
  } else if (!params.selection_text.empty()) {
    add_command(IDS_CONTENT_CONTEXT_COPY,
                blink::ContextMenuDataEditFlags::kCanCopy,
                &content::WebContents::Copy);
  }
  if (menu.itemArray.lastObject.separatorItem) {
    [menu removeItemAtIndex:menu.numberOfItems - 1];
  }
  if (!menu.numberOfItems) {
    return;
  }

  // The click, in the page's view (Chromium's coordinates are from its top
  // left).
  const NSPoint point = NSMakePoint(
      params.x, view.isFlipped ? params.y : NSHeight(view.bounds) - params.y);
  // Chromium's tasks run while the menu is open, as for Chrome's own
  // (RenderViewContextMenuMacCocoa::Show()). The panel may close meanwhile:
  // nothing here uses it after.
  base::CurrentThread::ScopedAllowApplicationTasksInNativeNestedLoop allow;
  [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

WebPanelHost::WebPanelHost(BEChromiumWebPanel* panel,
                           Profile* profile,
                           std::unique_ptr<ScopedProfileKeepAlive> keep_alive,
                           const GURL& folder)
    : panel_(panel),
      folder_(folder),
      folder_path_(folder.path()),
      profile_(profile),
      keep_alive_(std::move(keep_alive)) {
  if (!folder_path_.ends_with('/')) {
    folder_path_ += '/';
  }
  // As an agent's tab is made (be_agent_tabs.mm), in the panels' partition,
  // which its navigations keep to.
  const content::StoragePartitionConfig config =
      content::StoragePartitionConfig::Create(profile, kPartitionDomain,
                                              std::string(),
                                              /*in_memory=*/true);
  content::WebContents::CreateParams params(
      profile, content::SiteInstance::CreateForFixedStoragePartition(
                   profile, folder_, config));
  // Shown once the app puts its view in a window: content's view
  // (WebContentsViewCocoa) makes the page visible, hidden or occluded as the
  // view is in a window, hidden, or covered.
  params.initially_hidden = true;
  contents_ = content::WebContents::Create(params);
  contents_->SetDelegate(this);
  Observe(contents_.get());
  profile_observation_.Observe(profile);
  if (ProfileManager* manager = g_browser_process->profile_manager()) {
    profile_manager_observation_.Observe(manager);
  }
}

WebPanelHost::~WebPanelHost() {
  Close();
}

bool WebPanelHost::IsPanelPage(const GURL& url) const {
  // GURL has resolved "." and ".." in the path, escaped ones too. An escaped
  // "/" or NUL names no file outside the folder: the file loader
  // (net::FileURLToFilePath()) refuses both. A host ("file://localhost/…")
  // only matches the folder's own.
  return url.SchemeIsFile() && url.host() == folder_.host() &&
         url.path().starts_with(folder_path_);
}

void WebPanelHost::Refuse(const GURL& url) {
  if (!IsPanelPage(url) && !IsPageOnly(url)) {
    [panel_ pageWantsURL:url];
  }
}

void WebPanelHost::Load(const GURL& url) {
  if (!contents_ || browser_shutdown::HasShutdownStarted()) {
    return;
  }
  if (!IsPanelPage(url)) {
    Refuse(url);
    return;
  }
  content::NavigationController::LoadURLParams params(url);
  params.transition_type = ui::PAGE_TRANSITION_AUTO_TOPLEVEL;
  contents_->GetController().LoadURLWithParams(params);
}

void WebPanelHost::Close() {
  profile_observation_.Reset();
  profile_manager_observation_.Reset();
  Observe(nullptr);
  // Null while it's destroyed, for whatever it calls.
  if (std::unique_ptr<content::WebContents> contents = std::move(contents_)) {
    contents->SetDelegate(nullptr);
  }
  // After the page: its profile outlives it.
  keep_alive_.reset();
  profile_ = nullptr;
}

void WebPanelHost::CloseForChromium() {
  if (contents_) {
    Close();
    [panel_ chromiumDidClose];
  }
}

content::WebContents* WebPanelHost::OpenURLFromTab(
    content::WebContents* source,
    const content::OpenURLParams& params,
    base::OnceCallback<void(content::NavigationHandle&)>
        navigation_handle_callback) {
  // What the renderer hands over: a ⌘- or middle click, a link to a scheme of
  // another app's (mailto:), a frame's link aimed at another frame.
  if (!IsPanelPage(params.url)) {
    const bool for_frame =
        params.disposition == WindowOpenDisposition::CURRENT_TAB &&
        params.frame_tree_node_id &&
        params.frame_tree_node_id !=
            source->GetPrimaryMainFrame()->GetFrameTreeNodeId();
    if (!for_frame || params.user_gesture) {
      Refuse(params.url);
    }
    return nullptr;
  }
  // The panel's own pages open only in it: in place, or not at all.
  if (params.disposition != WindowOpenDisposition::CURRENT_TAB) {
    return nullptr;
  }
  base::WeakPtr<content::NavigationHandle> navigation =
      source->GetController().LoadURLWithParams(
          content::NavigationController::LoadURLParams(params));
  if (navigation && navigation_handle_callback) {
    std::move(navigation_handle_callback).Run(*navigation);
  }
  return source;
}

bool WebPanelHost::IsWebContentsCreationOverridden(
    content::RenderFrameHost* opener,
    content::SiteInstance* source_site_instance,
    content::mojom::WindowContainerType window_container_type,
    const GURL& opener_url,
    const std::string& frame_name,
    const GURL& target_url) {
  // No window comes from the panel (window.open, target=_blank):
  // CreateCustomWebContents() refuses each.
  return true;
}

content::WebContents* WebPanelHost::CreateCustomWebContents(
    content::RenderFrameHost* opener,
    content::SiteInstance* source_site_instance,
    bool is_new_browsing_instance,
    const GURL& opener_url,
    const std::string& frame_name,
    const GURL& target_url,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& window_features,
    const content::StoragePartitionConfig& partition_config,
    content::SessionStorageNamespaceHandle* session_storage_namespace) {
  // window.open() returns null to the page. A blank window (about:blank, to be
  // written into) is nothing to open.
  Refuse(target_url);
  return nullptr;
}

bool WebPanelHost::HandleContextMenu(
    content::RenderFrameHost& render_frame_host,
    const content::ContextMenuParams& params) {
  // On a task of its own: the menu runs a nested run loop, which shouldn't be
  // inside the renderer's message.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(&ShowContextMenu, weak_factory_.GetWeakPtr(), params));
  return true;
}

bool WebPanelHost::HandleKeyboardEvent(
    content::WebContents* source,
    const input::NativeWebKeyboardEvent& event) {
  // As for a tab (be_browser_window.mm): a key down the page didn't take,
  // never a synthesized one, nor one the page asked not to pass on.
  if (event.skip_if_unhandled ||
      event.GetType() == input::NativeWebKeyboardEvent::Type::kChar ||
      !event.os_event || event.os_event.Get().type != NSEventTypeKeyDown) {
    return false;
  }
  NSEvent* key = event.os_event.Get();
  NSWindow* window = source->GetNativeView().GetNativeNSView().window;
  // In one of Chrome's windows (the app's browser windows), through its
  // command dispatcher, as a tab's keys go; in the app's own windows, to its
  // main menu, as content_shell does (the page's view would take the key again
  // from the window's performKeyEquivalent:).
  if (views::NativeWidgetMacNSWindowHost* window_host =
          window ? views::NativeWidgetMacNSWindowHost::GetFromNativeWindow(
                       gfx::NativeWindow(window))
                 : nullptr) {
    return window_host->RedispatchKeyEvent(key);
  }
  return [NSApp.mainMenu performKeyEquivalent:key];
}

void WebPanelHost::DidStartNavigation(content::NavigationHandle* navigation) {
  // Content runs no throttles for a change within the page (a fragment,
  // history.pushState()) nor again for a page back from the back-forward cache
  // (let in when it first loaded), and refuses them for Chrome's initial WebUI
  // (its WebUI toolbar), which no page can open.
  if (navigation->IsSameDocument() || navigation->IsPageActivation() ||
      waap::IsForInitialWebUI(navigation->GetURL())) {
    return;
  }
  navigation->RegisterThrottleForTesting(std::make_unique<WebPanelThrottle>(
      *navigation, weak_factory_.GetWeakPtr()));
}

void WebPanelHost::DidFinishLoad(content::RenderFrameHost* render_frame_host,
                                 const GURL& validated_url) {
  // The panel's page, not an error page in its place (a file that isn't
  // there).
  if (render_frame_host->IsInPrimaryMainFrame() &&
      !render_frame_host->IsErrorDocument()) {
    [panel_ pageDidFinishLoading];
  }
}

void WebPanelHost::PrimaryMainFrameRenderProcessGone(
    base::TerminationStatus status) {
  // Not as Chromium quits, when every renderer goes.
  if (status != base::TERMINATION_STATUS_STILL_RUNNING &&
      !browser_shutdown::HasShutdownStarted()) {
    [panel_ pageDidCrash];
  }
}

void WebPanelHost::OnProfileWillBeDestroyed(Profile* profile) {
  // Chromium quitting: the page must go before its profile.
  CloseForChromium();
}

void WebPanelHost::OnProfileMarkedForPermanentDeletion(Profile* profile) {
  // Its keep-alive would hold the deletion up.
  if (profile == profile_) {
    CloseForChromium();
  }
}

void WebPanelHost::OnProfileManagerDestroying() {
  profile_manager_observation_.Reset();
}

}  // namespace

}  // namespace browser_engine

// MARK: BEWebPanel

@implementation BEChromiumWebPanel {
  std::unique_ptr<browser_engine::WebPanelHost> _host;
  // The page's view, kept for the panel's life (empty once it's closed).
  NSView* _view;
}

@synthesize delegate = _delegate;

- (instancetype)
    initWithProfile:(Profile*)profile
          keepAlive:(std::unique_ptr<ScopedProfileKeepAlive>)keepAlive
             folder:(const GURL&)folder {
  if ((self = [super init])) {
    _host = std::make_unique<browser_engine::WebPanelHost>(
        self, profile, std::move(keepAlive), folder);
    _view = _host->contents()->GetNativeView().GetNativeNSView();
  }
  return self;
}

- (void)dealloc {
  _host.reset();
}

// On a later task, unless the app has closed the panel by then.
- (void)tellDelegate:(void (^)(BEChromiumWebPanel* panel,
                               id<BEWebPanelDelegate> delegate))message {
  __weak BEChromiumWebPanel* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        BEChromiumWebPanel* panel = weakSelf;
        id<BEWebPanelDelegate> delegate = panel.delegate;
        if (delegate) {
          message(panel, delegate);
        }
      }));
}

- (void)pageDidFinishLoading {
  [self tellDelegate:^(BEChromiumWebPanel* panel,
                       id<BEWebPanelDelegate> delegate) {
    if ([delegate respondsToSelector:@selector(webPanelDidFinishLoading:)]) {
      [delegate webPanelDidFinishLoading:panel];
    }
  }];
}

- (void)pageWantsURL:(const GURL&)url {
  NSURL* address = net::NSURLWithGURL(url);
  if (!address) {
    return;
  }
  [self tellDelegate:^(BEChromiumWebPanel* panel,
                       id<BEWebPanelDelegate> delegate) {
    if ([delegate respondsToSelector:@selector(webPanel:openURL:)]) {
      [delegate webPanel:panel openURL:address];
    }
  }];
}

- (void)pageDidCrash {
  [self tellDelegate:^(BEChromiumWebPanel* panel,
                       id<BEWebPanelDelegate> delegate) {
    if ([delegate respondsToSelector:@selector(webPanelDidCrash:)]) {
      [delegate webPanelDidCrash:panel];
    }
  }];
}

- (void)chromiumDidClose {
  [self tellDelegate:^(BEChromiumWebPanel* panel,
                       id<BEWebPanelDelegate> delegate) {
    if ([delegate respondsToSelector:@selector(webPanelDidClose:)]) {
      [delegate webPanelDidClose:panel];
    }
  }];
}

// MARK: BEWebPanel

- (NSView*)view {
  return _view;
}

- (void)loadURL:(NSURL*)url {
  if (_host) {
    _host->Load(net::GURLWithNSURL(url));
  }
}

- (id<BEDevToolsSession>)openDevToolsSessionWithAccess:
    (BEDevToolsAccess)access {
  content::WebContents* contents = _host ? _host->contents() : nullptr;
  if (!contents) {
    return nil;
  }
  // On the page's own target, which follows it through its documents and
  // their processes for the panel's life: a binding the app adds stays through
  // reloads, and a crash doesn't end the session. Chrome's DevTools policy can
  // still refuse it (the close handler).
  return [[BEChromiumDevToolsSession alloc]
      initWithAgentHost:content::DevToolsAgentHost::GetOrCreateFor(contents)
                 access:access];
}

- (void)focus {
  if (content::WebContents* contents = _host ? _host->contents() : nullptr) {
    contents->Focus();
  }
}

- (void)setVisible:(BOOL)visible {
  // Through the view, which content's view follows (WebContentsViewCocoa's
  // -viewDidHide and -viewDidUnhide): setting the page's visibility itself
  // would be undone at the window's next occlusion change.
  _view.hidden = !visible;
}

- (void)close {
  _delegate = nil;
  _host.reset();
}

@end

// MARK: BEEngineWebPanels

@implementation BEChromiumEngine (WebPanels)

- (id<BEWebPanel>)makeWebPanelWithFolder:(NSURL*)folder {
  // Chromium runs: startup is done (the profiles model is made then) and it
  // isn't quitting.
  if (!g_browser_process || ![self profilesModel] ||
      browser_shutdown::HasShutdownStarted()) {
    return nil;
  }
  const GURL folder_url = net::GURLWithNSURL(folder);
  Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
  if (![folder isFileURL] || !folder_url.SchemeIsFile() || !profile) {
    return nil;
  }
  // The everyday profile (the menus' one) stays loaded while the panel is
  // open, with none of its windows left too. Chrome has no keep-alive for an
  // embedder's own UI; an app's window is nearest.
  profile = profile->GetOriginalProfile();
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive =
      ScopedProfileKeepAlive::TryAcquire(profile,
                                         ProfileKeepAliveOrigin::kAppWindow);
  if (!keep_alive) {
    return nil;  // It's being deleted.
  }
  return [[BEChromiumWebPanel alloc] initWithProfile:profile
                                           keepAlive:std::move(keep_alive)
                                              folder:folder_url];
}

@end
