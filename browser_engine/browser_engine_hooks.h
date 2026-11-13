// The one way Chromium's own code calls into //browser_engine.
//
// The touch-point patches in patches/browser_engine/ include only this header.
// It declares nothing but forward-declared types (and base's callback, weak
// pointer and scoped_refptr templates), so it never pulls the layer's headers
// into Chromium files, and changing the layer recompiles none of them.

#ifndef BROWSER_ENGINE_BROWSER_ENGINE_HOOKS_H_
#define BROWSER_ENGINE_BROWSER_ENGINE_HOOKS_H_

#include <memory>
#include <optional>
#include <string>

#include "base/functional/callback_forward.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"

class BrowserWindow;
class BrowserWindowInterface;
class GURL;
class LoginHandler;
struct NavigateParams;

namespace base {
class FilePath;
}  // namespace base

namespace content {
class SiteInstance;
class WeakDocumentPtr;
class WebContents;
}  // namespace content

namespace javascript_dialogs {
class TabModalDialogView;
}  // namespace javascript_dialogs

namespace net {
class AuthChallengeInfo;
class AuthCredentials;
}  // namespace net

namespace url {
class Origin;
}  // namespace url

namespace views {
class Widget;
}  // namespace views

namespace browser_engine {

// Implemented by the layer (be_engine.mm). Every call is on the UI thread.
class Hooks {
 public:
  virtual ~Hooks() = default;

  // browser_window_factory.cc: our window for `browser`, or null to let Chrome
  // make its own (Views) window. The caller takes ownership.
  virtual BrowserWindow* CreateBrowserWindow(
      BrowserWindowInterface* browser) = 0;

  // embedder_browser_window_features.cc: `browser` and its window are fully
  // constructed and have no tabs yet. Called for every browser type.
  virtual void BrowserWindowInitialized(BrowserWindowInterface* browser) = 0;

  // browser_window_features.cc: the views::Widget of our window for
  // `browser`, or null if `browser` doesn't have one of our windows.
  virtual views::Widget* GetWidgetForBrowser(
      BrowserWindowInterface* browser) = 0;

  // session_crashed_bubble_view.cc: after a crash, Chrome would show its
  // session-crashed bubble ("Restore pages?") on `browser` now, but `browser`
  // has no BrowserView to anchor it to. Every check the bubble makes first
  // (not off the record, the browser still open, an active tab) has passed.
  virtual void ShowSessionCrashedBubble(BrowserWindowInterface* browser) = 0;

  // chrome_browser_main_mac.mm: what AppController does at these two points,
  // since the app (not AppController) is NSApp's delegate when embedded.
  virtual void PreCreateThreads() = 0;
  virtual void DidEndMainMessageLoop() = 0;

  // javascript_tab_modal_dialog_view_views.cc: an alert, confirm or prompt
  // (`dialog_type`, a content::JavaScriptDialogType) for the tab showing
  // `parent_web_contents`: the app's dialog, or null for Chrome's. Takes the
  // callbacks only when it returns a dialog.
  virtual base::WeakPtr<javascript_dialogs::TabModalDialogView>
  CreateJavaScriptDialog(
      content::WebContents* parent_web_contents,
      const std::u16string& title,
      int dialog_type,
      const std::u16string& message_text,
      const std::u16string& default_prompt_text,
      base::OnceCallback<void(bool, const std::u16string&)>& dialog_callback,
      base::OnceClosure& dialog_force_closed_callback) = 0;

  // login_handler_views.cc: the sign-in prompt for an HTTP authentication
  // challenge in `web_contents`: the app's, or null for Chrome's. Takes the
  // callback only when it returns one.
  virtual std::unique_ptr<LoginHandler> CreateLoginHandler(
      const net::AuthChallengeInfo& auth_info,
      content::WebContents* web_contents,
      base::OnceCallback<void(const std::optional<net::AuthCredentials>&)>&
          auth_required_callback) = 0;

  // external_protocol_dialog.cc: asks whether to open `url` in
  // `program_name` (not empty), as Chrome's dialog would; false to show
  // Chrome's dialog instead. `initiating_origin` may be null.
  virtual bool RunExternalProtocolDialog(
      const GURL& url,
      content::WebContents* web_contents,
      const url::Origin* initiating_origin,
      const content::WeakDocumentPtr& initiator_document,
      const std::u16string& program_name) = 0;

  // ProfilePicker::Show() (touch point 30): true when the app shows its own
  // picker instead of Chrome's. `entry_point` is ProfilePicker::EntryPoint.
  virtual bool ShowProfilePicker(int entry_point) = 0;

  // Agents' tabs (be_agent_tabs.mm, touch point 32): whether `contents`
  // keeps to an agent's own storage. Such a tab adds nothing to the profile's
  // history (history_tab_helper.cc), isn't saved with the session or in
  // recently closed (session_tab_helper_factory.cc, session_service_base.cc,
  // content_live_tab.cc) and isn't discarded (tab_lifecycle_unit.cc). False
  // for a WebContents being destroyed.
  virtual bool IsAgentTab(content::WebContents* contents) = 0;

  // browser_navigator.cc (touch point 31): the SiteInstance a new tab or
  // window that `params` opens at `url` starts in, when the page it's opened
  // from keeps to an agent's storage (a link opened in a new tab with ⌘, a
  // middle click or the page's menu), so that it keeps to it too; null for
  // Chrome's choice.
  virtual scoped_refptr<content::SiteInstance> GetSiteInstanceForNewTab(
      const NavigateParams& params,
      const GURL& url) = 0;

  // profile_network_context_service.cc (touch point 33): whether the
  // StoragePartition at `relative_partition_path` (from the profile's
  // directory) is an agent's on disk, whose session cookies are kept across
  // launches as the profile's own are when it restores its session.
  virtual bool IsAgentStoragePath(
      const base::FilePath& relative_partition_path) = 0;
};

// Set once by BEEngine before it calls ChromeMain; never unset. Null when the
// framework runs as the plain Chromium.app, and in every child process.
void SetHooks(Hooks* hooks);
Hooks* GetHooks();

// True when Chromium runs inside our app.
inline bool IsEmbedded() {
  return GetHooks() != nullptr;
}

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BROWSER_ENGINE_HOOKS_H_
