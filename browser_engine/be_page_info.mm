#import "browser_engine/be_page_info.h"

#include <memory>
#include <optional>
#include <utility>
#include <variant>

#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/certificate_viewer.h"
#include "chrome/browser/ui/page_info/chrome_page_info_delegate.h"
#include "chrome/browser/ui/page_info/chrome_page_info_ui_delegate.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/page_info/page_info.h"
#include "components/page_info/page_info_ui.h"
#include "components/url_formatter/elide_url.h"
#include "content/public/browser/web_contents.h"
#include "net/cert/x509_certificate.h"
#include "url/gurl.h"

@interface BEChromiumSitePermission : NSObject <BESitePermission>
@property(nonatomic) NSInteger identifier;
@property(nonatomic, copy) NSString* title;
@property(nonatomic) BESitePermissionState state;
@property(nonatomic, copy) NSString* stateText;
@property(nonatomic) BESitePermissionState defaultState;
@property(nonatomic) BOOL offersAllow;
@property(nonatomic) BOOL offersAsk;
@property(nonatomic) BOOL isManaged;
@property(nonatomic) BOOL isInUse;
@end

@implementation BEChromiumSitePermission
@synthesize identifier = _identifier;
@synthesize title = _title;
@synthesize state = _state;
@synthesize stateText = _stateText;
@synthesize defaultState = _defaultState;
@synthesize offersAllow = _offersAllow;
@synthesize offersAsk = _offersAsk;
@synthesize isManaged = _isManaged;
@synthesize isInUse = _isInUse;
@end

namespace browser_engine {

namespace {

BESitePermissionState StateFor(const std::optional<PermissionSetting>& setting) {
  const ContentSetting* value =
      setting ? std::get_if<ContentSetting>(&*setting) : nullptr;
  if (!value) {
    return BESitePermissionStateDefault;
  }
  switch (*value) {
    case CONTENT_SETTING_ALLOW:
      return BESitePermissionStateAllow;
    case CONTENT_SETTING_BLOCK:
      return BESitePermissionStateBlock;
    case CONTENT_SETTING_ASK:
      return BESitePermissionStateAsk;
    default:
      return BESitePermissionStateDefault;
  }
}

ContentSetting SettingFor(BESitePermissionState state) {
  switch (state) {
    case BESitePermissionStateAllow:
      return CONTENT_SETTING_ALLOW;
    case BESitePermissionStateBlock:
      return CONTENT_SETTING_BLOCK;
    case BESitePermissionStateAsk:
      return CONTENT_SETTING_ASK;
    case BESitePermissionStateDefault:
    default:
      return CONTENT_SETTING_DEFAULT;
  }
}

}  // namespace

// What PageInfoBubbleView is to PageInfo: the UI it tells what to show. It
// keeps the last of each for the app's object, and tells it of every change.
class AppPageInfoUI : public PageInfoUI {
 public:
  AppPageInfoUI(content::WebContents* contents, BEChromiumSiteInfo* owner)
      : contents_(contents->GetWeakPtr()),
        owner_(owner),
        ui_delegate_(contents, contents->GetLastCommittedURL()) {}
  AppPageInfoUI(const AppPageInfoUI&) = delete;
  AppPageInfoUI& operator=(const AppPageInfoUI&) = delete;
  ~AppPageInfoUI() override = default;

  // Made after the UI, which it calls at once.
  void Start() {
    page_info_ = std::make_unique<PageInfo>(
        std::make_unique<ChromePageInfoDelegate>(contents_.get()),
        contents_.get(), contents_->GetLastCommittedURL());
    page_info_->InitializeUiState(this, base::DoNothing());
  }

  // PageInfoUI:
  void SetIdentityInfo(const IdentityInfo& identity_info) override {
    std::unique_ptr<SecurityDescription> description =
        GetSecurityDescription(identity_info);
    security_title_ = description ? base::SysUTF16ToNSString(description->summary) : @"";
    security_detail_ =
        description ? base::SysUTF16ToNSString(description->details) : @"";
    is_secure_ = description &&
                 description->summary_style == SecuritySummaryColor::GREEN;
    is_warning_ = description &&
                  description->summary_style == SecuritySummaryColor::RED;
    certificate_ = identity_info.certificate;
    Changed();
  }

  void SetPermissionInfo(const PermissionInfoList& permission_info_list,
                         ChosenObjectInfoList chosen_object_info_list) override {
    permission_list_ = permission_info_list;
    NSMutableArray<id<BESitePermission>>* permissions = [NSMutableArray array];
    for (const PageInfo::PermissionInfo& info : permission_info_list) {
      BEChromiumSitePermission* permission = [[BEChromiumSitePermission alloc] init];
      permission.identifier = static_cast<NSInteger>(info.type);
      permission.title =
          base::SysUTF16ToNSString(PermissionTypeToUIString(info.type));
      permission.state = StateFor(info.setting);
      permission.stateText = base::SysUTF16ToNSString(
          PermissionStateToUIString(&ui_delegate_, info));
      permission.defaultState = StateFor(info.default_setting);
      permission.offersAllow = ui_delegate_.ShouldShowAllow(info.type);
      permission.offersAsk = ui_delegate_.ShouldShowAsk(info.type);
      permission.isManaged =
          info.source == content_settings::SettingSource::kPolicy ||
          info.source == content_settings::SettingSource::kExtension ||
          info.source == content_settings::SettingSource::kSupervised;
      permission.isInUse = info.is_in_use;
      [permissions addObject:permission];
    }
    permissions_ = permissions;
    Changed();
  }

  void SetCookieInfo(const CookiesInfo& cookie_info) override {
    cookie_sites_ = cookie_info.allowed_sites_count;
    Changed();
  }

  // For the app's object.
  NSString* security_title() const { return security_title_; }
  NSString* security_detail() const { return security_detail_; }
  bool is_secure() const { return is_secure_; }
  bool is_warning() const { return is_warning_; }
  bool has_certificate() const { return !!certificate_; }
  NSInteger cookie_sites() const { return cookie_sites_; }
  NSArray<id<BESitePermission>>* permissions() const { return permissions_; }

  // PageInfoBubbleView's permission rows: the setting for the permission's
  // requesting origin, as a lasting choice.
  void SetPermission(NSInteger identifier, BESitePermissionState state) {
    for (const PageInfo::PermissionInfo& info : permission_list_) {
      if (static_cast<NSInteger>(info.type) == identifier) {
        page_info_->OnSitePermissionChanged(
            info.type, PermissionSetting(SettingFor(state)),
            info.requesting_origin, /*is_one_time=*/false);
        return;
      }
    }
  }

  void ShowCertificate() {
    if (contents_ && certificate_) {
      ShowCertificateViewer(contents_.get(),
                            contents_->GetTopLevelNativeWindow(),
                            certificate_.get());
    }
  }

  // PageInfoBubbleView::OnWidgetDestroying(): a change that needs a reload
  // gets Chrome's infobar.
  void Close() {
    if (page_info_) {
      bool reload_prompt = false;
      page_info_->OnUIClosing(&reload_prompt);
      page_info_.reset();
    }
  }

 private:
  void Changed();

  base::WeakPtr<content::WebContents> contents_;
  __weak BEChromiumSiteInfo* owner_;
  ChromePageInfoUiDelegate ui_delegate_;
  NSString* __strong security_title_ = @"";
  NSString* __strong security_detail_ = @"";
  bool is_secure_ = false;
  bool is_warning_ = false;
  scoped_refptr<net::X509Certificate> certificate_;
  NSInteger cookie_sites_ = -1;
  NSArray<id<BESitePermission>>* __strong permissions_ = @[];
  PermissionInfoList permission_list_;
  // Last: destroyed first, before what it calls.
  std::unique_ptr<PageInfo> page_info_;
};

}  // namespace browser_engine

@implementation BEChromiumSiteInfo {
  std::unique_ptr<browser_engine::AppPageInfoUI> _ui;
  NSString* _site;
}

@synthesize didChange = _didChange;

- (instancetype)initWithContents:(content::WebContents*)contents {
  const GURL url = contents ? contents->GetLastCommittedURL() : GURL();
  if (!url.is_valid() || url.IsAboutBlank()) {
    return nil;
  }
  if ((self = [super init])) {
    _site = base::SysUTF16ToNSString(url_formatter::FormatUrlForSecurityDisplay(
        url, url_formatter::SchemeDisplay::OMIT_HTTP_AND_HTTPS));
    _ui = std::make_unique<browser_engine::AppPageInfoUI>(contents, self);
    _ui->Start();
  }
  return self;
}

- (void)dealloc {
  if (_ui) {
    _ui->Close();
  }
}

- (void)changed {
  if (_didChange) {
    _didChange();
  }
}

- (NSString*)site {
  return _site;
}

- (NSString*)securityTitle {
  return _ui ? _ui->security_title() : @"";
}

- (NSString*)securityDetail {
  return _ui ? _ui->security_detail() : @"";
}

- (BOOL)isSecure {
  return _ui && _ui->is_secure();
}

- (BOOL)isWarning {
  return _ui && _ui->is_warning();
}

- (BOOL)hasCertificate {
  return _ui && _ui->has_certificate();
}

- (NSInteger)cookieSites {
  return _ui ? _ui->cookie_sites() : -1;
}

- (NSArray<id<BESitePermission>>*)permissions {
  return _ui ? _ui->permissions() : @[];
}

- (void)setPermission:(NSInteger)identifier state:(BESitePermissionState)state {
  if (_ui) {
    _ui->SetPermission(identifier, state);
  }
}

- (void)showCertificate {
  if (_ui) {
    _ui->ShowCertificate();
  }
}

- (void)close {
  if (_ui) {
    _ui->Close();
    _ui.reset();
  }
}

@end

namespace browser_engine {

void AppPageInfoUI::Changed() {
  [owner_ changed];
}

}  // namespace browser_engine
