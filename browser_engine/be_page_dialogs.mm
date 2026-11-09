#import "browser_engine/be_page_dialogs.h"

#import <AppKit/AppKit.h>

#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_tab.h"
#include "chrome/browser/external_protocol/external_protocol_handler.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/login/login_handler.h"
#include "chrome/common/pref_names.h"
#include "chrome/grit/generated_resources.h"
#include "components/javascript_dialogs/app_modal_dialog_controller.h"
#include "components/javascript_dialogs/app_modal_dialog_manager.h"
#include "components/javascript_dialogs/app_modal_dialog_view.h"
#include "components/javascript_dialogs/tab_modal_dialog_view.h"
#include "components/password_manager/core/browser/http_auth_manager.h"
#include "components/password_manager/core/browser/http_auth_observer.h"
#include "components/prefs/pref_service.h"
#include "components/strings/grit/components_strings.h"
#include "components/tabs/public/tab_interface.h"
#include "components/url_formatter/elide_url.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/page.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/javascript_dialog_type.h"
#include "net/base/auth.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/base/l10n/l10n_util_mac.h"
#include "ui/gfx/text_elider.h"
#include "ui/strings/grit/ui_strings.h"
#include "url/gurl.h"
#include "url/origin.h"

@implementation BEChromiumPageDialog {
  BOOL _open;
}

@synthesize kind = _kind;
@synthesize title = _title;
@synthesize message = _message;
@synthesize defaultText = _defaultText;
@synthesize defaultPassword = _defaultPassword;
@synthesize acceptTitle = _acceptTitle;
@synthesize cancelTitle = _cancelTitle;
@synthesize rememberTitle = _rememberTitle;
@synthesize didChange = _didChange;
@synthesize acceptHandler = _acceptHandler;
@synthesize cancelHandler = _cancelHandler;

- (instancetype)initWithKind:(BEPageDialogKind)kind
                       title:(NSString*)title
                     message:(NSString*)message
                 defaultText:(NSString*)defaultText
                 acceptTitle:(NSString*)acceptTitle
                 cancelTitle:(NSString*)cancelTitle
               rememberTitle:(NSString*)rememberTitle {
  if ((self = [super init])) {
    _kind = kind;
    _title = [title copy];
    _message = [message copy];
    _defaultText = [defaultText copy];
    _defaultPassword = @"";
    _acceptTitle = [acceptTitle copy];
    _cancelTitle = [cancelTitle copy];
    _rememberTitle = [rememberTitle copy];
    _open = YES;
  }
  return self;
}

- (BOOL)isOpen {
  return _open;
}

- (void)acceptWithText:(NSString*)text
              password:(NSString*)password
              remember:(BOOL)remember {
  if (!_open) {
    return;
  }
  _open = NO;
  NSString* answer = [text copy] ?: @"";
  NSString* secret = [password copy] ?: @"";
  __weak BEChromiumPageDialog* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        // Nil if Chrome closed the dialog meanwhile: its answer stands.
        auto handler = weakSelf.acceptHandler;
        [weakSelf dropHandlers];
        if (handler) {
          handler(answer, secret, remember);
        }
      }));
}

- (void)cancel {
  if (!_open) {
    return;
  }
  _open = NO;
  __weak BEChromiumPageDialog* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        auto handler = weakSelf.cancelHandler;
        [weakSelf dropHandlers];
        if (handler) {
          handler();
        }
      }));
}

- (void)dropHandlers {
  _acceptHandler = nil;
  _cancelHandler = nil;
}

- (void)setDefaultText:(NSString*)text password:(NSString*)password {
  _defaultText = [text copy];
  _defaultPassword = [password copy];
  if (_open && _didChange) {
    _didChange();
  }
}

- (void)closeForTab:(BEChromiumTab*)tab {
  [self dropHandlers];
  if (!_open) {
    return;
  }
  _open = NO;
  id<BETabDelegateNativeUI> delegate =
      static_cast<id<BETabDelegateNativeUI>>(tab.delegate);
  if ([delegate respondsToSelector:@selector(tab:closePageDialog:)]) {
    [delegate tab:tab closePageDialog:self];
  }
}

@end

namespace browser_engine {

namespace {

using javascript_dialogs::AppModalDialogController;
using javascript_dialogs::AppModalDialogManager;
using javascript_dialogs::AppModalDialogView;

NSString* String(int message_id) {
  return l10n_util::GetNSString(message_id);
}

// Hands `dialog` to the app for `tab`; whether it shows it.
bool ShowInApp(BEChromiumTab* tab, BEChromiumPageDialog* dialog) {
  id<BETabDelegateNativeUI> delegate =
      static_cast<id<BETabDelegateNativeUI>>(tab.delegate);
  return tab && [delegate respondsToSelector:@selector(tab:showPageDialog:)] &&
         [delegate tab:tab showPageDialog:dialog];
}

// MARK: alert, confirm, prompt

// What JavaScriptTabModalDialogViewViews is to TabModalDialogManager: the
// tab's dialog, which marks the tab as showing modal UI while it's open. It
// owns itself: an answer, or Chrome closing it, deletes it.
class AppTabModalDialog : public javascript_dialogs::TabModalDialogView {
 public:
  AppTabModalDialog(
      tabs::TabInterface* tab,
      BEChromiumTab* tab_object,
      BEChromiumPageDialog* dialog,
      const std::u16string& default_prompt_text,
      content::JavaScriptDialogManager::DialogClosedCallback dialog_callback,
      base::OnceClosure dialog_force_closed_callback)
      : tab_object_(tab_object),
        dialog_(dialog),
        default_prompt_text_(default_prompt_text),
        dialog_callback_(std::move(dialog_callback)),
        dialog_force_closed_callback_(std::move(dialog_force_closed_callback)) {
    if (tab->CanShowModalUI()) {
      modal_ui_ = tab->ShowModalUI();
    }
    base::WeakPtr<AppTabModalDialog> weak = weak_factory_.GetWeakPtr();
    dialog_.acceptHandler = ^(NSString* text, NSString*, BOOL) {
      if (weak) {
        weak->Answer(true, base::SysNSStringToUTF16(text));
      }
    };
    dialog_.cancelHandler = ^{
      if (weak) {
        weak->Answer(false, std::u16string());
      }
    };
  }
  AppTabModalDialog(const AppTabModalDialog&) = delete;
  AppTabModalDialog& operator=(const AppTabModalDialog&) = delete;
  ~AppTabModalDialog() override { [dialog_ closeForTab:tab_object_]; }

  base::WeakPtr<AppTabModalDialog> GetWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

  // javascript_dialogs::TabModalDialogView:
  void CloseDialogWithoutCallback() override {
    dialog_callback_.Reset();
    dialog_force_closed_callback_.Reset();
    delete this;
  }
  std::u16string GetUserInput() override { return default_prompt_text_; }

 private:
  // As the Views dialog's accept and cancel callbacks: the manager hears the
  // answer (TabModalDialogManager::CloseDialog), and the dialog goes.
  void Answer(bool accept, const std::u16string& text) {
    dialog_force_closed_callback_.Reset();
    // The tab can show the next modal UI (another dialog) from here on.
    modal_ui_.reset();
    base::WeakPtr<AppTabModalDialog> weak = weak_factory_.GetWeakPtr();
    if (dialog_callback_) {
      std::move(dialog_callback_).Run(accept, text);
    }
    if (weak) {
      delete this;
    }
  }

  BEChromiumTab* __strong tab_object_;
  BEChromiumPageDialog* __strong dialog_;
  const std::u16string default_prompt_text_;
  content::JavaScriptDialogManager::DialogClosedCallback dialog_callback_;
  base::OnceClosure dialog_force_closed_callback_;
  std::unique_ptr<tabs::ScopedTabModalUI> modal_ui_;
  base::WeakPtrFactory<AppTabModalDialog> weak_factory_{this};
};

// MARK: Leave site? (and other app-modal dialogs)

// What AppModalDialogViewViews is to AppModalDialogController: it owns the
// controller, answers it once, and goes on a later task, which deletes the
// controller and so shows the queue's next dialog.
class AppModalDialog : public AppModalDialogView {
 public:
  // Ours for `controller`'s tab, taking the controller; null (keeping it)
  // when the app doesn't draw the tab's dialogs.
  static AppModalDialogView* Create(
      std::unique_ptr<AppModalDialogController>& controller) {
    BEChromiumTab* tab_object = PageDialogTab(controller->web_contents());
    if (!tab_object) {
      return nullptr;
    }
    BEPageDialogKind kind = BEPageDialogKindAlert;
    NSString* accept = String(IDS_APP_OK);
    NSString* cancel = String(IDS_APP_CANCEL);
    if (controller->is_before_unload_dialog()) {
      kind = controller->is_reload() ? BEPageDialogKindReload
                                     : BEPageDialogKindLeave;
      accept = String(controller->is_reload()
                          ? IDS_BEFORERELOAD_MESSAGEBOX_OK_BUTTON_LABEL
                          : IDS_BEFOREUNLOAD_MESSAGEBOX_OK_BUTTON_LABEL);
    } else if (controller->javascript_dialog_type() ==
               content::JAVASCRIPT_DIALOG_TYPE_CONFIRM) {
      kind = BEPageDialogKindConfirm;
    } else if (controller->javascript_dialog_type() ==
               content::JAVASCRIPT_DIALOG_TYPE_PROMPT) {
      kind = BEPageDialogKindPrompt;
    } else {
      cancel = @"";
    }
    BEChromiumPageDialog* dialog = [[BEChromiumPageDialog alloc]
         initWithKind:kind
                title:base::SysUTF16ToNSString(controller->title())
              message:base::SysUTF16ToNSString(controller->message_text())
          defaultText:base::SysUTF16ToNSString(
                          controller->default_prompt_text())
          acceptTitle:accept
          cancelTitle:cancel
        rememberTitle:nil];
    if (!ShowInApp(tab_object, dialog)) {
      return nullptr;
    }
    return new AppModalDialog(std::move(controller), tab_object, dialog);
  }

  AppModalDialog(const AppModalDialog&) = delete;
  AppModalDialog& operator=(const AppModalDialog&) = delete;
  ~AppModalDialog() override { [dialog_ closeForTab:tab_object_]; }

  // javascript_dialogs::AppModalDialogView:
  // The app shows it with its tab, which Chrome brings forward first.
  void ShowAppModalDialog() override {}
  void ActivateAppModalDialog() override {}
  // Chrome closed it (the page went); its callback has run.
  void CloseAppModalDialog() override { Finish(); }
  // A test or DevTools answered (Page.handleJavaScriptDialog).
  void AcceptAppModalDialog() override {
    Answer(true, controller_->default_prompt_text());
  }
  void CancelAppModalDialog() override { Answer(false, std::u16string()); }
  bool IsShowing() const override { return !finished_; }

 private:
  AppModalDialog(std::unique_ptr<AppModalDialogController> controller,
                 BEChromiumTab* tab_object,
                 BEChromiumPageDialog* dialog)
      : controller_(std::move(controller)),
        tab_object_(tab_object),
        dialog_(dialog) {
    base::WeakPtr<AppModalDialog> weak = weak_factory_.GetWeakPtr();
    dialog_.acceptHandler = ^(NSString* text, NSString*, BOOL) {
      if (weak) {
        weak->Answer(true, base::SysNSStringToUTF16(text));
      }
    };
    dialog_.cancelHandler = ^{
      if (weak) {
        weak->Answer(false, std::u16string());
      }
    };
  }

  void Answer(bool accept, const std::u16string& text) {
    if (finished_) {
      return;
    }
    // Before telling the controller, which may show the next dialog.
    [dialog_ closeForTab:tab_object_];
    base::WeakPtr<AppModalDialog> weak = weak_factory_.GetWeakPtr();
    if (accept) {
      controller_->OnAccept(text, /*suppress_js_messages=*/false);
    } else {
      controller_->OnCancel(/*suppress_js_messages=*/false);
    }
    if (weak) {
      Finish();
    }
  }

  void Finish() {
    if (finished_) {
      return;
    }
    finished_ = true;
    [dialog_ closeForTab:tab_object_];
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                               this);
  }

  std::unique_ptr<AppModalDialogController> controller_;
  BEChromiumTab* __strong tab_object_;
  BEChromiumPageDialog* __strong dialog_;
  bool finished_ = false;
  base::WeakPtrFactory<AppModalDialog> weak_factory_{this};
};

// MARK: Sign in

// What LoginHandlerViews and its LoginView are: the dialog, filled with what
// the password manager saved for the site once it answers.
class AppLoginHandler : public LoginHandler,
                        public password_manager::HttpAuthObserver {
 public:
  AppLoginHandler(
      const net::AuthChallengeInfo& auth_info,
      content::WebContents* contents,
      content::LoginDelegate::LoginAuthRequiredCallback callback)
      : LoginHandler(auth_info, contents, std::move(callback)) {}
  AppLoginHandler(const AppLoginHandler&) = delete;
  AppLoginHandler& operator=(const AppLoginHandler&) = delete;
  // LoginHandler can't call CloseDialog() from its destructor.
  ~AppLoginHandler() override { CloseDialog(); }

 protected:
  // LoginHandler:
  bool BuildViewImpl(const std::u16string& authority,
                     const std::u16string& explanation,
                     LoginModelData* login_model_data) override {
    tab_object_ = PageDialogTab(web_contents());
    if (!tab_object_) {
      return false;
    }
    std::u16string message = authority;
    if (!explanation.empty()) {
      message += u"\n" + explanation;
    }
    dialog_ = [[BEChromiumPageDialog alloc]
         initWithKind:BEPageDialogKindSignIn
                title:String(IDS_LOGIN_DIALOG_TITLE)
              message:base::SysUTF16ToNSString(message)
          defaultText:@""
          acceptTitle:String(IDS_LOGIN_DIALOG_OK_BUTTON_LABEL)
          cancelTitle:String(IDS_APP_CANCEL)
        rememberTitle:nil];
    // SetAuth() and CancelAuth() can delete this handler: nothing after them.
    base::WeakPtr<LoginHandler> weak = GetWeakPtr();
    dialog_.acceptHandler = ^(NSString* user, NSString* password, BOOL) {
      if (weak) {
        weak->SetAuth(base::SysNSStringToUTF16(user),
                      base::SysNSStringToUTF16(password));
      }
    };
    dialog_.cancelHandler = ^{
      if (weak) {
        weak->CancelAuth(/*notify_others=*/true);
      }
    };
    if (!ShowInApp(tab_object_, dialog_)) {
      dialog_ = nil;
      return false;
    }
    if (login_model_data) {
      auth_manager_ = login_model_data->model;
      auth_manager_->SetObserverAndDeliverCredentials(this,
                                                      *login_model_data->form);
    }
    return true;
  }

  void CloseDialog() override {
    if (auth_manager_) {
      auth_manager_->DetachObserver(this);
      auth_manager_ = nullptr;
    }
    [dialog_ closeForTab:tab_object_];
    dialog_ = nil;
  }

  // password_manager::HttpAuthObserver:
  void OnAutofillDataAvailable(std::u16string_view username,
                               std::u16string_view password) override {
    [dialog_ setDefaultText:base::SysUTF16ToNSString(std::u16string(username))
                   password:base::SysUTF16ToNSString(std::u16string(password))];
  }
  void OnLoginModelDestroying() override { auth_manager_ = nullptr; }

 private:
  BEChromiumTab* __strong tab_object_ = nil;
  BEChromiumPageDialog* __strong dialog_ = nil;
  raw_ptr<password_manager::HttpAuthManager> auth_manager_ = nullptr;
};

// MARK: Open app?

// What ExternalProtocolDialog does on its buttons. It owns itself, and goes
// with an answer, with its tab's page, or with the tab; like Chrome's
// web-modal dialogs it stays through a navigation within the same site.
class AppExternalProtocolDialog : public content::WebContentsObserver {
 public:
  AppExternalProtocolDialog(content::WebContents* contents,
                            BEChromiumTab* tab_object,
                            BEChromiumPageDialog* dialog,
                            const GURL& url,
                            const url::Origin* initiating_origin,
                            const content::WeakDocumentPtr& initiator_document)
      : content::WebContentsObserver(contents),
        tab_object_(tab_object),
        dialog_(dialog),
        url_(url),
        page_url_(contents->GetLastCommittedURL()),
        initiator_document_(initiator_document) {
    if (initiating_origin) {
      initiating_origin_ = *initiating_origin;
    }
    base::WeakPtr<AppExternalProtocolDialog> weak =
        weak_factory_.GetWeakPtr();
    dialog_.acceptHandler = ^(NSString*, NSString*, BOOL remember) {
      if (weak) {
        weak->Accept(remember);
      }
    };
    dialog_.cancelHandler = ^{
      if (weak) {
        ExternalProtocolHandler::RecordHandleStateMetrics(
            /*checkbox_selected=*/false, ExternalProtocolHandler::BLOCK);
        delete weak.get();
      }
    };
  }
  AppExternalProtocolDialog(const AppExternalProtocolDialog&) = delete;
  AppExternalProtocolDialog& operator=(const AppExternalProtocolDialog&) =
      delete;
  ~AppExternalProtocolDialog() override { [dialog_ closeForTab:tab_object_]; }

 private:
  // ExternalProtocolDialog::OnDialogAccepted().
  void Accept(bool remember) {
    remember = remember && initiating_origin_ && dialog_.rememberTitle;
    ExternalProtocolHandler::RecordHandleStateMetrics(
        remember, ExternalProtocolHandler::DONT_BLOCK);
    if (remember) {
      ExternalProtocolHandler::SetBlockState(
          url_.GetScheme(), *initiating_origin_,
          ExternalProtocolHandler::DONT_BLOCK,
          Profile::FromBrowserContext(web_contents()->GetBrowserContext()));
    }
    ExternalProtocolHandler::LaunchUrlWithoutSecurityCheck(
        url_, web_contents(), initiator_document_);
    delete this;
  }

  // content::WebContentsObserver:
  void PrimaryPageChanged(content::Page& page) override {
    // WebContentsModalDialogManager::DidFinishNavigation(): web-modal
    // dialogs close when the tab goes to another site.
    if (!net::registry_controlled_domains::SameDomainOrHost(
            page_url_, web_contents()->GetLastCommittedURL(),
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)) {
      delete this;
    }
  }
  void WebContentsDestroyed() override { delete this; }

  BEChromiumTab* __strong tab_object_;
  BEChromiumPageDialog* __strong dialog_;
  const GURL url_;
  const GURL page_url_;
  std::optional<url::Origin> initiating_origin_;
  const content::WeakDocumentPtr initiator_document_;
  base::WeakPtrFactory<AppExternalProtocolDialog> weak_factory_{this};
};

}  // namespace

BEChromiumTab* PageDialogTab(content::WebContents* contents) {
  tabs::TabInterface* tab =
      contents ? tabs::TabInterface::MaybeGetFromContents(contents) : nullptr;
  BEChromiumTab* object = [BEChromiumTab existingTabForTab:tab];
  return [object.delegate respondsToSelector:@selector(tab:showPageDialog:)]
             ? object
             : nil;
}

base::WeakPtr<javascript_dialogs::TabModalDialogView> CreateJavaScriptDialog(
    content::WebContents* parent_contents,
    const std::u16string& title,
    int dialog_type,
    const std::u16string& message_text,
    const std::u16string& default_prompt_text,
    base::OnceCallback<void(bool, const std::u16string&)>& dialog_callback,
    base::OnceClosure& dialog_force_closed_callback) {
  tabs::TabInterface* tab =
      tabs::TabInterface::MaybeGetFromContents(parent_contents);
  BEChromiumTab* tab_object = PageDialogTab(parent_contents);
  if (!tab || !tab_object) {
    return nullptr;
  }
  BEPageDialogKind kind = BEPageDialogKindAlert;
  if (dialog_type == content::JAVASCRIPT_DIALOG_TYPE_CONFIRM) {
    kind = BEPageDialogKindConfirm;
  } else if (dialog_type == content::JAVASCRIPT_DIALOG_TYPE_PROMPT) {
    kind = BEPageDialogKindPrompt;
  }
  // Alerts only have OK, as in Chrome's: there's no choice to make.
  BEChromiumPageDialog* dialog = [[BEChromiumPageDialog alloc]
       initWithKind:kind
              title:base::SysUTF16ToNSString(title)
            message:base::SysUTF16ToNSString(message_text)
        defaultText:base::SysUTF16ToNSString(default_prompt_text)
        acceptTitle:String(IDS_APP_OK)
        cancelTitle:kind == BEPageDialogKindAlert ? @"" : String(IDS_APP_CANCEL)
      rememberTitle:nil];
  if (!ShowInApp(tab_object, dialog)) {
    return nullptr;
  }
  auto* view = new AppTabModalDialog(tab, tab_object, dialog,
                                     default_prompt_text,
                                     std::move(dialog_callback),
                                     std::move(dialog_force_closed_callback));
  return view->GetWeakPtr();
}

void InstallAppModalDialogFactory() {
  static bool installed = false;
  if (installed) {
    return;
  }
  installed = true;
  AppModalDialogManager* manager = AppModalDialogManager::GetInstance();
  AppModalDialogManager::AppModalViewFactory chrome_factory =
      *manager->view_factory();
  manager->SetNativeDialogFactory(base::BindRepeating(
      [](const AppModalDialogManager::AppModalViewFactory& chrome_factory,
         std::unique_ptr<AppModalDialogController> controller)
          -> AppModalDialogView* {
        if (AppModalDialogView* view = AppModalDialog::Create(controller)) {
          return view;
        }
        return chrome_factory.Run(std::move(controller));
      },
      std::move(chrome_factory)));
}

std::unique_ptr<LoginHandler> CreateLoginHandler(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* contents,
    base::OnceCallback<void(const std::optional<net::AuthCredentials>&)>&
        auth_required_callback) {
  if (!PageDialogTab(contents)) {
    return nullptr;
  }
  return std::make_unique<AppLoginHandler>(auth_info, contents,
                                           std::move(auth_required_callback));
}

bool RunExternalProtocolDialog(const GURL& url,
                               content::WebContents* contents,
                               const url::Origin* initiating_origin,
                               const content::WeakDocumentPtr& initiator_document,
                               const std::u16string& program_name) {
  BEChromiumTab* tab_object = PageDialogTab(contents);
  if (!tab_object) {
    return false;
  }
  // ExternalProtocolDialog's texts.
  constexpr int kMaxCommandCharsToDisplay = 32;
  std::u16string elided;
  gfx::ElideString(program_name, kMaxCommandCharsToDisplay, &elided);
  const bool has_origin = initiating_origin && !initiating_origin->opaque();
  std::u16string message =
      has_origin
          ? l10n_util::GetStringFUTF16(
                IDS_EXTERNAL_PROTOCOL_MESSAGE_WITH_INITIATING_ORIGIN,
                url_formatter::FormatOriginForSecurityDisplay(
                    *initiating_origin))
          : l10n_util::GetStringUTF16(IDS_EXTERNAL_PROTOCOL_MESSAGE);
  // Offered as Chrome offers it: unless policy says not to, for an origin
  // whose decisions can be remembered.
  Profile* profile =
      Profile::FromBrowserContext(contents->GetBrowserContext());
  NSString* remember = nil;
  if (profile->GetPrefs()->GetBoolean(
          prefs::kExternalProtocolDialogShowAlwaysOpenCheckbox) &&
      ExternalProtocolHandler::MayRememberAllowDecisionsForThisOrigin(
          initiating_origin)) {
    remember = l10n_util::GetNSStringF(
        IDS_EXTERNAL_PROTOCOL_CHECKBOX_PER_ORIGIN_TEXT,
        url_formatter::FormatOriginForSecurityDisplay(
            *initiating_origin,
            url_formatter::SchemeDisplay::OMIT_CRYPTOGRAPHIC));
  }
  BEChromiumPageDialog* dialog = [[BEChromiumPageDialog alloc]
       initWithKind:BEPageDialogKindOpenApp
              title:l10n_util::GetNSStringF(IDS_EXTERNAL_PROTOCOL_TITLE, elided)
            message:base::SysUTF16ToNSString(message)
        defaultText:@""
        acceptTitle:l10n_util::GetNSStringF(
                        IDS_EXTERNAL_PROTOCOL_OK_BUTTON_TEXT, program_name)
        cancelTitle:String(IDS_EXTERNAL_PROTOCOL_CANCEL_BUTTON_TEXT)
      rememberTitle:remember];
  if (!ShowInApp(tab_object, dialog)) {
    return false;
  }
  new AppExternalProtocolDialog(contents, tab_object, dialog, url,
                                initiating_origin, initiator_document);
  return true;
}

}  // namespace browser_engine
