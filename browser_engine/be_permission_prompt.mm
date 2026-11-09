#import "browser_engine/be_permission_prompt.h"

#import <AppKit/AppKit.h>

#include <memory>
#include <optional>
#include <variant>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_tab.h"
#include "chrome/grit/generated_resources.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/permissions/permission_prompt.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_request_manager.h"
#include "components/permissions/permission_uma_constants.h"
#include "components/permissions/permission_util.h"
#include "components/permissions/request_type.h"
#include "components/strings/grit/components_strings.h"
#include "components/tabs/public/tab_interface.h"
#include "components/url_formatter/elide_url.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/l10n/l10n_util_mac.h"
#include "url/gurl.h"

using permissions::PermissionPrompt;
using permissions::RequestType;

NS_ASSUME_NONNULL_BEGIN

// The app's object for one prompt; answers do nothing once it's closed, and
// the first runs on a later task.
@interface BEChromiumPermissionPrompt : NSObject <BEPermissionPrompt>
- (instancetype)initWithOrigin:(NSString*)origin
                      requests:(NSArray<NSString*>*)requests
                         kinds:(NSArray<NSString*>*)kinds
                    allowTitle:(NSString*)allowTitle
                allowOnceTitle:(nullable NSString*)allowOnceTitle
                    blockTitle:(NSString*)blockTitle NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// 0 allow, 1 allow once, 2 block, 3 dismiss.
@property(nonatomic, copy, nullable) void (^answerHandler)(int answer);
// Chrome closed it (answered, or withdrawn): the app hears
// tab:closePermissionPrompt: from `tab` unless it answered.
- (void)closeForTab:(nullable BEChromiumTab*)tab;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumPermissionPrompt {
  BOOL _open;
}

@synthesize origin = _origin;
@synthesize requests = _requests;
@synthesize kinds = _kinds;
@synthesize allowTitle = _allowTitle;
@synthesize allowOnceTitle = _allowOnceTitle;
@synthesize blockTitle = _blockTitle;
@synthesize answerHandler = _answerHandler;

- (instancetype)initWithOrigin:(NSString*)origin
                      requests:(NSArray<NSString*>*)requests
                         kinds:(NSArray<NSString*>*)kinds
                    allowTitle:(NSString*)allowTitle
                allowOnceTitle:(NSString*)allowOnceTitle
                    blockTitle:(NSString*)blockTitle {
  if ((self = [super init])) {
    _origin = [origin copy];
    _requests = [requests copy];
    _kinds = [kinds copy];
    _allowTitle = [allowTitle copy];
    _allowOnceTitle = [allowOnceTitle copy];
    _blockTitle = [blockTitle copy];
    _open = YES;
  }
  return self;
}

- (BOOL)isOpen {
  return _open;
}

- (void)answer:(int)answer {
  if (!_open) {
    return;
  }
  _open = NO;
  __weak BEChromiumPermissionPrompt* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        // Nil if Chrome withdrew the prompt meanwhile.
        auto handler = weakSelf.answerHandler;
        weakSelf.answerHandler = nil;
        if (handler) {
          handler(answer);
        }
      }));
}

- (void)allow {
  [self answer:0];
}

- (void)allowOnce {
  if (_allowOnceTitle) {
    [self answer:1];
  }
}

- (void)block {
  [self answer:2];
}

- (void)dismiss {
  [self answer:3];
}

- (void)closeForTab:(BEChromiumTab*)tab {
  _answerHandler = nil;
  if (!_open) {
    return;
  }
  _open = NO;
  id<BETabDelegateNativeUI> delegate =
      static_cast<id<BETabDelegateNativeUI>>(tab.delegate);
  if ([delegate respondsToSelector:@selector(tab:closePermissionPrompt:)]) {
    [delegate tab:tab closePermissionPrompt:self];
  }
}

@end

namespace browser_engine {

namespace {

// The icon's name for the app (BEPermissionPrompt.kinds).
NSString* KindName(RequestType type) {
  switch (type) {
    case RequestType::kCameraStream:
    case RequestType::kCameraPanTiltZoom:
      return @"camera";
    case RequestType::kMicStream:
      return @"microphone";
    case RequestType::kGeolocation:
      return @"location";
    case RequestType::kNotifications:
      return @"notifications";
    case RequestType::kClipboard:
      return @"clipboard";
    case RequestType::kMidiSysex:
      return @"midi";
    case RequestType::kMultipleDownloads:
      return @"downloads";
    case RequestType::kDiskQuota:
    case RequestType::kStorageAccess:
    case RequestType::kTopLevelStorageAccess:
    case RequestType::kFileSystemAccess:
      return @"storage";
    case RequestType::kWindowManagement:
      return @"windows";
    case RequestType::kLocalFonts:
      return @"fonts";
    case RequestType::kSensors:
      return @"sensors";
    case RequestType::kVrSession:
      return @"vr";
    case RequestType::kArSession:
      return @"ar";
    case RequestType::kHandTracking:
      return @"handTracking";
    case RequestType::kIdleDetection:
      return @"idle";
    case RequestType::kLocalNetwork:
    case RequestType::kLoopbackNetwork:
      return @"localNetwork";
    case RequestType::kRegisterProtocolHandler:
      return @"protocolHandler";
    default:
      return @"other";
  }
}

// PermissionPromptBubbleBaseView::IsOneTimePermission(): every request can be
// granted for this visit only.
bool OffersAllowOnce(PermissionPrompt::Delegate* delegate) {
  for (const auto& request : delegate->Requests()) {
    std::optional<ContentSettingsType> type =
        permissions::RequestTypeToContentSettingsType(request->request_type());
    if (!type || !permissions::PermissionUtil::DoesSupportTemporaryGrants(*type)) {
      return false;
    }
  }
  return true;
}

// Whether Chrome's anchored bubble is the prompt Chrome would show (see
// CreatePermissionPrompt() in permission_prompt_factory.cc); the others stay
// Chrome's.
bool IsBubblePrompt(content::WebContents* contents,
                    PermissionPrompt::Delegate* delegate) {
  if (delegate->Requests().empty() ||
      delegate->ShouldCurrentRequestUseQuietUI() ||
      permissions::PermissionUtil::
          ShouldCurrentRequestUsePermissionElementSecondaryUI(delegate,
                                                              contents)) {
    return false;
  }
  // Approximate location isn't on the desktop's bubble either.
  for (const auto& request : delegate->Requests()) {
    if (request->GetContentSettingsType() ==
        ContentSettingsType::GEOLOCATION_WITH_OPTIONS) {
      return false;
    }
  }
  return true;
}

// What PermissionPromptBubble is to the manager: shown while it exists, and
// answered once. The manager deletes it once answered (inside Accept() and
// the like), on a tab switch, and when the requests go.
class AppPermissionPrompt : public PermissionPrompt {
 public:
  AppPermissionPrompt(BEChromiumTab* tab_object,
                      BEChromiumPermissionPrompt* prompt,
                      PermissionPrompt::Delegate* delegate)
      : tab_object_(tab_object), prompt_(prompt), delegate_(delegate) {
    base::WeakPtr<AppPermissionPrompt> weak = weak_factory_.GetWeakPtr();
    prompt_.answerHandler = ^(int answer) {
      if (weak) {
        weak->Answer(answer);
      }
    };
  }
  AppPermissionPrompt(const AppPermissionPrompt&) = delete;
  AppPermissionPrompt& operator=(const AppPermissionPrompt&) = delete;
  ~AppPermissionPrompt() override { [prompt_ closeForTab:tab_object_]; }

  // PermissionPrompt:
  bool UpdateAnchor() override { return true; }
  TabSwitchingBehavior GetTabSwitchingBehavior() override {
    return TabSwitchingBehavior::kDestroyPromptButKeepRequestPending;
  }
  permissions::PermissionPromptDisposition GetPromptDisposition()
      const override {
    return permissions::PermissionPromptDisposition::ANCHORED_BUBBLE;
  }
  bool IsAskPrompt() const override { return true; }
  std::optional<gfx::Rect> GetViewBoundsInScreen() const override {
    return std::nullopt;
  }
  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants()
      const override {
    return {};
  }
  std::optional<permissions::feature_params::PermissionElementPromptPosition>
  GetPromptPosition() const override {
    return std::nullopt;
  }

 private:
  // PermissionPromptBubbleBaseView::RunButtonCallback() and
  // ClosingPermission(). Each deletes this prompt.
  void Answer(int answer) {
    const PromptOptions options = std::monostate();
    switch (answer) {
      case 0:
        delegate_->Accept(options);
        return;
      case 1:
        delegate_->AcceptThisTime(options);
        return;
      case 2:
        delegate_->Deny(options);
        return;
      default:
        delegate_->Dismiss(options);
        return;
    }
  }

  BEChromiumTab* __strong tab_object_;
  BEChromiumPermissionPrompt* __strong prompt_;
  const raw_ptr<PermissionPrompt::Delegate> delegate_;
  base::WeakPtrFactory<AppPermissionPrompt> weak_factory_{this};
};

// The tab's prompts: ours when the app draws this one, else Chrome's.
std::unique_ptr<PermissionPrompt> CreatePrompt(
    content::WebContents* contents,
    PermissionPrompt::Delegate* delegate) {
  tabs::TabInterface* tab = tabs::TabInterface::MaybeGetFromContents(contents);
  BEChromiumTab* tab_object = [BEChromiumTab existingTabForTab:tab];
  id<BETabDelegateNativeUI> app =
      static_cast<id<BETabDelegateNativeUI>>(tab_object.delegate);
  if (![app respondsToSelector:@selector(tab:showPermissionPrompt:)] ||
      !IsBubblePrompt(contents, delegate)) {
    return PermissionPrompt::Create(contents, delegate);
  }
  // PermissionPromptBaseView::GetUrlIdentity(): the requesting origin, a
  // file as "This file".
  const GURL origin_url = delegate->GetRequestingOrigin();
  NSString* origin =
      origin_url.SchemeIsFile()
          ? l10n_util::GetNSString(IDS_PERMISSIONS_BUBBLE_PROMPT_THIS_FILE)
          : base::SysUTF16ToNSString(url_formatter::FormatUrlForSecurityDisplay(
                origin_url, url_formatter::SchemeDisplay::OMIT_CRYPTOGRAPHIC));
  NSMutableArray<NSString*>* requests = [NSMutableArray array];
  NSMutableArray<NSString*>* kinds = [NSMutableArray array];
  for (const auto& request : delegate->Requests()) {
    [requests
        addObject:base::SysUTF16ToNSString(request->GetMessageTextFragment())];
    [kinds addObject:KindName(request->request_type())];
  }
  // PermissionPromptBubbleBaseView::CreatePermissionButtons(): a request's
  // own texts when it's alone, else Chrome's.
  permissions::PermissionRequest* first = delegate->Requests()[0].get();
  const bool alone = delegate->Requests().size() == 1;
  NSString* allow = nil;
  NSString* allow_once = nil;
  NSString* block = nil;
  if (OffersAllowOnce(delegate)) {
    std::optional<std::u16string> own_allow = first->GetAllowAlwaysText();
    std::optional<std::u16string> own_block = first->GetBlockText();
    allow = alone && own_allow ? base::SysUTF16ToNSString(*own_allow)
                               : l10n_util::GetNSString(
                                     IDS_PERMISSION_ALLOW_WHILE_VISITING);
    allow_once = l10n_util::GetNSString(IDS_PERMISSION_ALLOW_THIS_TIME);
    block = alone && own_block
                ? base::SysUTF16ToNSString(*own_block)
                : l10n_util::GetNSString(IDS_PERMISSION_NEVER_ALLOW);
  } else {
    allow = l10n_util::GetNSString(IDS_PERMISSION_ALLOW);
    block = l10n_util::GetNSString(IDS_PERMISSION_DENY);
  }
  BEChromiumPermissionPrompt* prompt =
      [[BEChromiumPermissionPrompt alloc] initWithOrigin:origin
                                                requests:requests
                                                   kinds:kinds
                                              allowTitle:allow
                                          allowOnceTitle:allow_once
                                              blockTitle:block];
  if (![app tab:tab_object showPermissionPrompt:prompt]) {
    return PermissionPrompt::Create(contents, delegate);
  }
  return std::make_unique<AppPermissionPrompt>(tab_object, prompt, delegate);
}

}  // namespace

void UseAppPermissionPrompts(content::WebContents* contents) {
  if (!contents) {
    return;
  }
  if (auto* manager =
          permissions::PermissionRequestManager::FromWebContents(contents)) {
    // Public despite its name: the manager's only way to have its prompts
    // made by someone else.
    manager->set_view_factory_for_testing(base::BindRepeating(&CreatePrompt));
  }
}

}  // namespace browser_engine
