#import "browser_engine/be_devtools_session.h"

#import <objc/runtime.h>

#include <memory>
#include <optional>
#include <string>
#include <tuple>

#include "base/apple/foundation_util.h"
#include "base/callback_list.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/scoped_refptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/single_thread_task_runner.h"
#import "browser_engine/be_agent_tabs.h"
#import "browser_engine/be_engine.h"
#import "browser_engine/be_tab.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/url_constants.h"
#include "ui/gfx/geometry/size.h"
#include "url/gurl.h"

@interface BEChromiumDevToolsSession ()
// From the client.
- (void)deliverMessage:(NSData*)json;
- (void)agentHostClosed;
@end

namespace browser_engine {

namespace {

// Chrome's own pages, which only a session with BEDevToolsAccessChromePages
// may attach to or stay on: its WebUI (chrome://, chrome-untrusted://) and
// DevTools' own front end.
bool IsChromePage(const GURL& url, bool is_webui) {
  return is_webui || url.SchemeIs(content::kChromeUIScheme) ||
         url.SchemeIs(content::kChromeUIUntrustedScheme) ||
         url.SchemeIs(content::kChromeDevToolsScheme);
}

// What a session may do, as Chrome asks its clients. Everything else (unsafe
// operations, a navigation initiator, the binary protocol) is Chrome's
// default: off.
class DevToolsClient : public content::DevToolsAgentHostClient {
 public:
  DevToolsClient(BEChromiumDevToolsSession* session, BEDevToolsAccess access)
      : session_(session), access_(access) {}
  DevToolsClient(const DevToolsClient&) = delete;
  DevToolsClient& operator=(const DevToolsClient&) = delete;
  ~DevToolsClient() override = default;

  // content::DevToolsAgentHostClient:
  void DispatchProtocolMessage(content::DevToolsAgentHost* agent_host,
                               base::span<const uint8_t> message) override {
    // Replies to browser-side commands come from inside
    // DispatchProtocolMessage(), so inside the app's sendMessage:; each
    // reaches the app on a task of its own, in order.
    NSData* json = [NSData dataWithBytes:message.data() length:message.size()];
    __weak BEChromiumDevToolsSession* session = session_;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{
          [session deliverMessage:json];
        }));
  }
  void AgentHostClosed(content::DevToolsAgentHost* agent_host) override {
    // Chrome has detached the session already.
    [session_ agentHostClosed];
  }
  bool MayAttachToURL(const GURL& url, bool is_webui) override {
    // Asked on attaching and before each navigation commits: a session that
    // may not stay on the page is detached (AgentHostClosed()).
    return (access_ & BEDevToolsAccessChromePages) ||
           !IsChromePage(url, is_webui);
  }
  bool IsTrusted() override { return access_ & BEDevToolsAccessTrusted; }
  bool MayReadLocalFiles() override {
    return access_ & BEDevToolsAccessReadsFiles;
  }
  bool MayWriteLocalFiles() override {
    return access_ & BEDevToolsAccessWritesFiles;
  }

 private:
  __weak BEChromiumDevToolsSession* session_;
  const BEDevToolsAccess access_;
};

// Focuses or blurs the page as if its window had the keyboard, or as its
// view really is (`focused` empty): Chrome's actor's SetFocusState()
// (actor_task.cc).
void SetPageFocus(content::WebContents* contents, std::optional<bool> focused) {
  content::RenderWidgetHostView* view = contents->GetRenderWidgetHostView();
  content::RenderWidgetHost* host =
      view ? view->GetRenderWidgetHost() : nullptr;
  if (!host) {
    return;
  }
  if (focused.value_or(view->HasFocus())) {
    host->Focus();
  } else {
    host->Blur();
  }
}

// While an agent acts in a tab: what Chrome's own agent framework holds on a
// tab it acts on (ActorTask::DidContentsEnterActorControl()). The page
// renders and runs its timers at full rate as if in front, though hidden (a
// capture that doesn't stay hidden, keeping the Mac awake, and counting as
// use); takes focus; draws <select> menus inside the page rather than as a
// native menu on screen; and isn't discarded. A page that replaces it (a new
// document, or a discard's new WebContents) gets the same.
class AgentActivity : public content::WebContentsObserver {
 public:
  explicit AgentActivity(tabs::TabInterface* tab) {
    discard_subscription_ =
        tab->RegisterWillDiscardContents(base::BindRepeating(
            &AgentActivity::WillDiscardContents, base::Unretained(this)));
    Hold(tab->GetContents());
  }
  AgentActivity(const AgentActivity&) = delete;
  AgentActivity& operator=(const AgentActivity&) = delete;
  ~AgentActivity() override { Release(); }

 private:
  void Hold(content::WebContents* contents) {
    Observe(contents);
    if (!contents) {
      return;
    }
    SetPageFocus(contents, true);
    capture_ = contents->IncrementCapturerCount(gfx::Size(),
                                                /*stay_hidden=*/false,
                                                /*stay_awake=*/true,
                                                /*is_activity=*/true);
#if BUILDFLAG(USE_EXTERNAL_POPUP_MENU)
    internal_popups_ = contents->ForbidExternalPopupMenus();
#endif
    was_auto_discardable_ = IsAutoDiscardable(contents);
    SetAutoDiscardable(contents, false);
  }

  // As ActorTask::DidContentsExitActorControl().
  void Release() {
    content::WebContents* contents = web_contents();
    if (!contents) {
      return;
    }
    Observe(nullptr);
    SetAutoDiscardable(contents, was_auto_discardable_);
    capture_.RunAndReset();
#if BUILDFLAG(USE_EXTERNAL_POPUP_MENU)
    internal_popups_.RunAndReset();
#endif
    SetPageFocus(contents, std::nullopt);
  }

  void WillDiscardContents(tabs::TabInterface* tab,
                           content::WebContents* old_contents,
                           content::WebContents* new_contents) {
    Release();
    Hold(new_contents);
  }

  // content::WebContentsObserver:
  void PrimaryPageChanged(content::Page& page) override {
    // A new document has a widget of its own to focus.
    SetPageFocus(web_contents(), true);
  }
  void WebContentsDestroyed() override {
    // The tab closed: what it held goes with the WebContents, which can't be
    // told anything now.
    Observe(nullptr);
    std::ignore = capture_.Release();
#if BUILDFLAG(USE_EXTERNAL_POPUP_MENU)
    std::ignore = internal_popups_.Release();
#endif
  }

  base::CallbackListSubscription discard_subscription_;
  base::ScopedClosureRunner capture_;
#if BUILDFLAG(USE_EXTERNAL_POPUP_MENU)
  base::ScopedClosureRunner internal_popups_;
#endif
  bool was_auto_discardable_ = true;
};

}  // namespace

}  // namespace browser_engine

// MARK: BEDevToolsSession

@implementation BEChromiumDevToolsSession {
  scoped_refptr<content::DevToolsAgentHost> _host;
  std::unique_ptr<browser_engine::DevToolsClient> _client;
  NSString* _targetIdentifier;
  BOOL _attached;
  // -close was called: the app hears nothing more.
  BOOL _closed;
  // The close handler has run or is on its way.
  BOOL _closeScheduled;
}

@synthesize messageHandler = _messageHandler;
@synthesize closeHandler = _closeHandler;

- (instancetype)initWithAgentHost:
                    (scoped_refptr<content::DevToolsAgentHost>)host
                           access:(BEDevToolsAccess)access {
  if ((self = [super init])) {
    _host = std::move(host);
    _targetIdentifier = base::SysUTF8ToNSString(_host->GetId());
    _client = std::make_unique<browser_engine::DevToolsClient>(self, access);
    // Chrome's DevTools policy, then the target: a browser target refuses an
    // untrusted client, a page or tab target a page the client may not
    // attach to. Chrome adds its own domains to every session it accepts
    // (ChromeDevToolsManagerDelegate::ClientAttached()).
    _attached = _host->AttachClient(_client.get());
    if (!_attached) {
      [self scheduleClose];
    }
  }
  return self;
}

- (void)dealloc {
  if (_attached) {
    _host->DetachClient(_client.get());
  }
}

- (void)deliverMessage:(NSData*)json {
  if (!_closed && _messageHandler) {
    _messageHandler(json);
  }
}

- (void)agentHostClosed {
  _attached = NO;
  [self scheduleClose];
}

// After the messages already on their way.
- (void)scheduleClose {
  if (_closeScheduled || _closed) {
    return;
  }
  _closeScheduled = YES;
  __weak BEChromiumDevToolsSession* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        [weakSelf runCloseHandler];
      }));
}

- (void)runCloseHandler {
  if (_closed) {
    return;
  }
  // Once; and the handlers, which may hold the app's side, go.
  void (^handler)(void) = _closeHandler;
  _closeHandler = nil;
  _messageHandler = nil;
  if (handler) {
    handler();
  }
}

// MARK: BEDevToolsSession

- (NSString*)targetIdentifier {
  return _targetIdentifier;
}

- (BOOL)isAttached {
  return _attached && !_closed;
}

- (void)sendMessage:(NSData*)json {
  if (!_attached || _closed) {
    return;
  }
  // May reply, or end the session (AgentHostClosed()), from inside.
  _host->DispatchProtocolMessage(_client.get(),
                                 base::apple::NSDataToSpan(json));
}

- (void)close {
  if (_closed) {
    return;
  }
  _closed = YES;
  _messageHandler = nil;
  _closeHandler = nil;
  if (_attached) {
    _attached = NO;
    _host->DetachClient(_client.get());
  }
}

@end

// MARK: BETabDevTools

// While an agent acts in the tab (setAgentActive:): its AgentActivity.
@interface BEAgentActivityHolder : NSObject
- (instancetype)initWithTab:(tabs::TabInterface*)tab;
@end

@implementation BEAgentActivityHolder {
  std::unique_ptr<browser_engine::AgentActivity> _activity;
}

- (instancetype)initWithTab:(tabs::TabInterface*)tab {
  if ((self = [super init])) {
    _activity = std::make_unique<browser_engine::AgentActivity>(tab);
  }
  return self;
}

@end

@implementation BEChromiumTab (DevTools)

static const void* const kAgentActivityKey = &kAgentActivityKey;

- (NSString*)devToolsTargetIdentifier {
  content::WebContents* contents = [self contents];
  // The tab target, which lasts through the page's documents and prerendered
  // pages swapped in; a discard's new WebContents has a new one.
  return contents ? base::SysUTF8ToNSString(
                        content::DevToolsAgentHost::GetOrCreateForTab(contents)
                            ->GetId())
                  : nil;
}

- (id<BEDevToolsSession>)openDevToolsSessionWithAccess:
    (BEDevToolsAccess)access {
  content::WebContents* contents = [self contents];
  if (!contents) {
    return nil;
  }
  // On the tab target, which has only the Target, IO and Tracing domains:
  // the page is reached through Target.setAutoAttach {autoAttach: true,
  // waitForDebuggerOnStart: false, flatten: true}, whose
  // Target.attachedToTarget gives the page's sessionId for its commands
  // (and again for each page swapped in). Attaching loads a tab that was
  // never loaded or was discarded.
  return [[BEChromiumDevToolsSession alloc]
      initWithAgentHost:content::DevToolsAgentHost::GetOrCreateForTab(contents)
                 access:access];
}

- (void)setAgentActive:(BOOL)active {
  tabs::TabInterface* tab = [self tab];
  BEAgentActivityHolder* holder =
      objc_getAssociatedObject(self, kAgentActivityKey);
  if (!active || !tab) {
    // Lets go at once; nothing if not active.
    objc_setAssociatedObject(self, kAgentActivityKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return;
  }
  if (!holder) {
    objc_setAssociatedObject(self, kAgentActivityKey,
                             [[BEAgentActivityHolder alloc] initWithTab:tab],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

- (NSString*)storagePartition {
  const std::string name = browser_engine::GetAgentStorageName([self contents]);
  return name.empty() ? nil : base::SysUTF8ToNSString(name);
}

@end

// MARK: BEEngineDevTools

@implementation BEChromiumEngine (DevTools)

- (id<BEDevToolsSession>)openBrowserDevToolsSessionWithAccess:
    (BEDevToolsAccess)access {
  // Chromium runs: startup is done (the profiles model is made then) and it
  // isn't shutting down.
  if (!g_browser_process || ![self profilesModel] ||
      browser_shutdown::HasShutdownStarted()) {
    return nil;
  }
  // A new browser target for each, as DevToolsPipeHandler makes one: every
  // target of every profile, through the Target domain. It takes a trusted
  // client only. No tethering (Tethering.bind).
  return [[BEChromiumDevToolsSession alloc]
      initWithAgentHost:
          content::DevToolsAgentHost::CreateForBrowser(
              nullptr, content::DevToolsAgentHost::CreateServerSocketCallback())
                 access:access];
}

- (id<BETab>)tabForDevToolsTarget:(NSString*)targetIdentifier {
  scoped_refptr<content::DevToolsAgentHost> host =
      content::DevToolsAgentHost::GetForId(
          base::SysNSStringToUTF8(targetIdentifier));
  // A tab target or one of its pages' (frames', prerendered pages').
  content::WebContents* contents = host ? host->GetWebContents() : nullptr;
  // The app's tabs only: not DevTools' own windows, nor Chrome's popups.
  return contents
             ? [BEChromiumTab
                   existingTabForTab:tabs::TabInterface::MaybeGetFromContents(
                                         contents)]
             : nil;
}

@end
