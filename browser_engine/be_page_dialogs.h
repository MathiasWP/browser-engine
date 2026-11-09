// What a page asks the user, drawn by the app (BEPageDialog) when the tab's
// delegate draws page dialogs: JavaScript's alert, confirm and prompt (touch
// point 27), "Leave site?" (Chrome's app-modal dialog factory), HTTP sign-in
// (touch point 28) and "Open app?" (touch point 29). Chrome's own shows
// otherwise.
//
// Each Chrome object here answers Chrome exactly as its Views dialog would,
// once, and tells the app when Chrome closes it first. The app's answers
// arrive on a later task (BEChromiumPageDialog), so none runs inside the call
// that showed the dialog, and none outlives what it answers.

#ifndef BROWSER_ENGINE_BE_PAGE_DIALOGS_H_
#define BROWSER_ENGINE_BE_PAGE_DIALOGS_H_

#import <Foundation/Foundation.h>

#include <memory>
#include <optional>
#include <string>

#include "base/functional/callback_forward.h"
#include "base/memory/weak_ptr.h"
#import "browser_engine/public/BEEngine.h"
#import "browser_engine/public/BEEngineOptional.h"

@class BEChromiumTab;
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

NS_ASSUME_NONNULL_BEGIN

// The app's object for one dialog. Answers do nothing once it's closed; the
// first runs its handler on a later task.
@interface BEChromiumPageDialog : NSObject <BEPageDialog>
- (instancetype)initWithKind:(BEPageDialogKind)kind
                       title:(NSString*)title
                     message:(NSString*)message
                 defaultText:(NSString*)defaultText
                 acceptTitle:(NSString*)acceptTitle
                 cancelTitle:(NSString*)cancelTitle
               rememberTitle:(nullable NSString*)rememberTitle
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, copy, nullable) void (^acceptHandler)
    (NSString* text, NSString* password, BOOL remember);
@property(nonatomic, copy, nullable) void (^cancelHandler)(void);

// Saved sign-in details arrived: tells the app (didChange).
- (void)setDefaultText:(NSString*)text password:(NSString*)password;
// Chrome closed it: no answer runs from now on, and the app hears
// tab:closePageDialog: from `tab` unless it answered already.
- (void)closeForTab:(nullable BEChromiumTab*)tab;
@end

namespace browser_engine {

// The tab `contents` shows in our windows, if its delegate draws page dialogs.
BEChromiumTab* _Nullable PageDialogTab(
    content::WebContents* _Nullable contents);

// Touch point 27 (javascript_tab_modal_dialog_view_views.cc): the app's
// alert, confirm or prompt for the tab of `parent_contents`; null for
// Chrome's. Takes the callbacks only when it returns a dialog.
base::WeakPtr<javascript_dialogs::TabModalDialogView> CreateJavaScriptDialog(
    content::WebContents* parent_contents,
    const std::u16string& title,
    int dialog_type,
    const std::u16string& message_text,
    const std::u16string& default_prompt_text,
    base::OnceCallback<void(bool, const std::u16string&)>& dialog_callback,
    base::OnceClosure& dialog_force_closed_callback);

// Puts our factory for Chrome's app-modal dialogs (beforeunload's "Leave
// site?", and JavaScript dialogs a tab can't show itself) in front of
// Chrome's, which still makes those for tabs the app doesn't draw them for.
// Once, after Chrome installed its own (it does before the first window).
void InstallAppModalDialogFactory();

// Touch point 28 (login_handler_views.cc): the app's sign-in for the tab of
// `contents`; null for Chrome's. Takes the callback only when it returns one.
std::unique_ptr<LoginHandler> CreateLoginHandler(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* contents,
    base::OnceCallback<void(const std::optional<net::AuthCredentials>&)>&
        auth_required_callback);

// Touch point 29 (external_protocol_dialog.cc): asks in the app whether to
// open `url` in `program_name`; false for Chrome's dialog.
bool RunExternalProtocolDialog(const GURL& url,
                               content::WebContents* contents,
                               const url::Origin* _Nullable initiating_origin,
                               const content::WeakDocumentPtr& initiator_document,
                               const std::u16string& program_name);

}  // namespace browser_engine

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_PAGE_DIALOGS_H_
