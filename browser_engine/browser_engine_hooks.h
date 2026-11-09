// The one way Chromium's own code calls into //browser_engine.
//
// The touch-point patches in patches/browser_engine/ include only this header.
// It declares nothing but forward-declared types (and base's callback and weak
// pointer templates), so it never pulls the layer's headers into Chromium
// files, and changing the layer recompiles none of them.

#ifndef BROWSER_ENGINE_BROWSER_ENGINE_HOOKS_H_
#define BROWSER_ENGINE_BROWSER_ENGINE_HOOKS_H_

#include <memory>
#include <optional>
#include <string>

#include "base/functional/callback_forward.h"
#include "base/memory/weak_ptr.h"

class BrowserWindow;
class BrowserWindowInterface;
class GURL;
class LoginHandler;

namespace content {
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
