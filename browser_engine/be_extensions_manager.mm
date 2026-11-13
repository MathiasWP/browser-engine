#import "browser_engine/be_extensions_manager.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <optional>
#include <set>
#include <utility>

#include "base/apple/foundation_util.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_window.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/extensions/api/developer_private/extension_info_generator.h"
#include "chrome/browser/extensions/api/developer_private/profile_info_generator.h"
#include "chrome/browser/extensions/commands/command_service.h"
#include "chrome/browser/extensions/devtools_util.h"
#include "chrome/browser/extensions/error_console/error_console.h"
#include "chrome/browser/extensions/extension_commands_global_registry.h"
#include "chrome/browser/extensions/extension_management.h"
#include "chrome/browser/extensions/extension_util.h"
#include "chrome/browser/extensions/updater/extension_updater.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/singleton_tabs.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "chrome/common/extensions/api/developer_private.h"
#include "chrome/common/pref_names.h"
#include "chrome/grit/generated_resources.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/prefs/pref_service.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/error_map.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_prefs_observer.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/extension_util.h"
#include "extensions/browser/load_error_reporter.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/permissions/permissions_updater.h"
#include "extensions/browser/permissions/scripting_permissions_modifier.h"
#include "extensions/browser/permissions_manager.h"
#include "extensions/browser/process_manager.h"
#include "extensions/browser/process_manager_observer.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/browser/updater/extension_downloader_types.h"
#include "extensions/browser/warning_service.h"
#include "extensions/common/api/extension_action/action_info.h"
#include "extensions/common/command.h"
#include "extensions/common/extension.h"
#include "extensions/common/extension_set.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/background_info.h"
#include "extensions/common/manifest_handlers/incognito_info.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "extensions/common/permissions/api_permission_set.h"
#include "extensions/common/permissions/manifest_permission_set.h"
#include "extensions/common/permissions/permission_set.h"
#include "extensions/common/url_pattern.h"
#include "extensions/common/url_pattern_set.h"
#include "net/base/apple/url_conversions.h"
#include "net/base/data_url.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/events/keycodes/keyboard_codes.h"
#include "url/gurl.h"

namespace developer = extensions::api::developer_private;

namespace {

NSArray<NSString*>* Strings(const std::vector<std::string>& strings) {
  NSMutableArray<NSString*>* array =
      [NSMutableArray arrayWithCapacity:strings.size()];
  for (const std::string& string : strings) {
    [array addObject:base::SysUTF8ToNSString(string)];
  }
  return array;
}

// An address the generator wrote, which may not be a valid one (Chrome's page
// copes with invalid view addresses too).
NSURL* URLFromString(const std::string& spec) {
  return net::NSURLWithGURL(GURL(spec));
}

// The generator's icon: a PNG data: URL, the extension's 48 px icon (or a
// larger one scaled to at most 128 px), or a lettered placeholder Chrome drew.
// Sized as 48 points, so a larger image draws sharp on a Retina screen.
NSImage* IconFromDataURL(const std::string& spec) {
  std::string mime_type;
  std::string charset;
  std::string data;
  if (!net::DataURL::Parse(GURL(spec), &mime_type, &charset, &data)) {
    return nil;
  }
  NSImage* image = [[NSImage alloc]
      initWithData:[NSData dataWithBytes:data.data() length:data.size()]];
  const NSSize pixels = image.size;
  if (pixels.width > 0 && pixels.height > 0) {
    constexpr CGFloat kPoints = 48;
    const CGFloat scale = std::max(pixels.width, pixels.height) / kPoints;
    image.size = NSMakeSize(pixels.width / scale, pixels.height / scale);
  }
  return image;
}

// Chrome's page's userCanChangeEnablement() (item_util.ts).
bool CanToggle(const developer::ExtensionInfo& info) {
  const developer::DisableReasons& reasons = info.disable_reasons;
  return info.user_may_modify && !reasons.corrupt_install &&
         !reasons.suspicious_install && !reasons.update_required &&
         !reasons.published_in_store_required && !reasons.blocked_by_policy &&
         !reasons.unsupported_developer_extension &&
         !reasons.unsupported_manifest_version &&
         // Turning off a shared module would break the extensions using it.
         info.dependent_extensions.empty() &&
         info.state != developer::ExtensionState::kBlocklisted;
}

// What Chrome's page writes about the extension, in its order: who installed
// it, where from, a blocklisting, why it's off, then the warnings. (The safety
// check's are left out: without the Web Store every extension is "not from
// the Chrome Web Store" there.)
NSArray<NSString*>* Notices(const developer::ExtensionInfo& info) {
  std::vector<std::string> lines;
  if (info.controlled_info) {
    lines.push_back(info.controlled_info->text);
  }
  if (info.location_text) {
    lines.push_back(*info.location_text);
  }
  if (info.blocklist_text) {
    lines.push_back(*info.blocklist_text);
  }
  const developer::DisableReasons& reasons = info.disable_reasons;
  if (reasons.corrupt_install) {
    lines.push_back(
        l10n_util::GetStringUTF8(IDS_EXTENSIONS_CORRUPTED_EXTENSION));
  }
  if (reasons.update_required) {
    lines.push_back(l10n_util::GetStringUTF8(
        IDS_EXTENSIONS_DISABLED_UPDATE_REQUIRED_BY_POLICY));
  }
  if (reasons.published_in_store_required) {
    lines.push_back(l10n_util::GetStringUTF8(
        IDS_EXTENSIONS_DISABLED_PUBLISHED_IN_STORE_REQUIRED_BY_POLICY));
  }
  if (reasons.unsupported_developer_extension) {
    lines.push_back(l10n_util::GetStringUTF8(
        IDS_EXTENSIONS_DISABLED_UNSUPPORTED_DEVELOPER_MODE));
  }
  if (reasons.unsupported_manifest_version) {
    lines.push_back(l10n_util::GetStringUTF8(
        IDS_EXTENSIONS_MV2_DEPRECATION_UNSUPPORTED_EXTENSION_OFF_TEXT));
  }
  if (reasons.disabled_by_another_extension) {
    lines.push_back(
        reasons.disabled_by_extension_name
            ? l10n_util::GetStringFUTF8(
                  IDS_EXTENSIONS_ITEM_DISABLED_BY_EXTENSION,
                  base::UTF8ToUTF16(*reasons.disabled_by_extension_name))
            : l10n_util::GetStringUTF8(
                  IDS_EXTENSIONS_ITEM_DISABLED_BY_EXTENSION_GENERIC));
  }
  lines.insert(lines.end(), info.install_warnings.begin(),
               info.install_warnings.end());
  lines.insert(lines.end(), info.runtime_warnings.begin(),
               info.runtime_warnings.end());
  return Strings(lines);
}

BEExtensionState State(developer::ExtensionState state) {
  switch (state) {
    case developer::ExtensionState::kEnabled:
      return BEExtensionStateEnabled;
    case developer::ExtensionState::kTerminated:
      return BEExtensionStateTerminated;
    case developer::ExtensionState::kBlocklisted:
      return BEExtensionStateBlocked;
    case developer::ExtensionState::kDisabled:
    case developer::ExtensionState::kNone:
      return BEExtensionStateDisabled;
  }
  return BEExtensionStateDisabled;
}

BEExtensionViewKind ViewKind(developer::ViewType type) {
  switch (type) {
    case developer::ViewType::kExtensionServiceWorkerBackground:
      return BEExtensionViewKindServiceWorker;
    case developer::ViewType::kExtensionBackgroundPage:
      return BEExtensionViewKindBackgroundPage;
    case developer::ViewType::kExtensionPopup:
      return BEExtensionViewKindPopup;
    case developer::ViewType::kTabContents:
      return BEExtensionViewKindTab;
    case developer::ViewType::kOffscreenDocument:
      return BEExtensionViewKindOffscreen;
    default:
      return BEExtensionViewKindOther;
  }
}

// ParseRuntimePermissionsPattern() in developer_private_functions.cc: a site
// as addHostPermission takes it, an http, https or file pattern of a whole
// site.
std::optional<URLPattern> ParseSite(const std::string& site) {
  constexpr int kValidSchemes = URLPattern::SCHEME_HTTP |
                                URLPattern::SCHEME_HTTPS |
                                URLPattern::SCHEME_FILE;
  URLPattern pattern(kValidSchemes);
  if (pattern.Parse(site) != URLPattern::ParseResult::kSuccess ||
      pattern.path() != "/*") {
    return std::nullopt;
  }
  return pattern;
}

}  // namespace

NS_ASSUME_NONNULL_BEGIN

// One of an extension's shortcuts: a copy, which doesn't change.
@interface BEChromiumExtensionCommand : NSObject <BEExtensionCommand>
- (instancetype)initWithCommand:(const developer::Command&)command
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// Something of an extension DevTools can inspect: a copy, which keeps what
// inspecting it takes (DeveloperPrivateOpenDevToolsFunction's properties).
@interface BEChromiumExtensionView : NSObject <BEExtensionView>
- (instancetype)initWithView:(const developer::ExtensionView&)view
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// -1 for one not running (an inactive service worker, a lazy background
// page).
@property(nonatomic, readonly) int renderProcessId;
// The frame's routing id (developerPrivate calls it render_view_id).
@property(nonatomic, readonly) int renderFrameId;
@property(nonatomic, readonly) developer::ViewType viewType;
@end

// An error from Chrome's error console: a copy.
@interface BEChromiumExtensionError : NSObject <BEExtensionError>
- (instancetype)initWithManifestError:(BOOL)isManifestError
                              warning:(BOOL)isWarning
                              message:(const std::string&)message
                               source:(const std::string&)source
                          occurrences:(NSInteger)occurrences
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// An extension as Chrome's page shows it: a copy, which doesn't change.
@interface BEChromiumExtension : NSObject <BEExtension>
- (instancetype)initWithInfo:(const developer::ExtensionInfo&)info
                        icon:(nullable NSImage*)icon
     needsPermissionApproval:(BOOL)needsPermissionApproval
          incognitoAvailable:(BOOL)incognitoAvailable NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumExtensionCommand

@synthesize name = _name;
@synthesize title = _title;
@synthesize shortcut = _shortcut;
@synthesize isGlobal = _isGlobal;

- (instancetype)initWithCommand:(const developer::Command&)command {
  if ((self = [super init])) {
    _name = base::SysUTF8ToNSString(command.name);
    // The generator words the action's own command ("Activate the
    // extension") itself.
    _title = base::SysUTF8ToNSString(command.description);
    // The generator writes the key with Accelerator::GetShortcutText(), which
    // on the Mac is the Mac's way already: ⌃⌥⇧⌘, then the key ("⇧⌘Y"). A
    // command without one has none (an inactive one may carry the key its
    // manifest suggested, which it didn't get).
    _shortcut =
        command.is_active ? base::SysUTF8ToNSString(command.keybinding) : @"";
    _isGlobal = command.scope == developer::CommandScope::kGlobal;
  }
  return self;
}

@end

@implementation BEChromiumExtensionView

@synthesize kind = _kind;
@synthesize url = _url;
@synthesize isIncognito = _isIncognito;
@synthesize isInactive = _isInactive;
@synthesize renderProcessId = _renderProcessId;
@synthesize renderFrameId = _renderFrameId;
@synthesize viewType = _viewType;

- (instancetype)initWithView:(const developer::ExtensionView&)view {
  if ((self = [super init])) {
    _kind = ViewKind(view.type);
    _url = URLFromString(view.url) ?: [NSURL URLWithString:@"about:blank"];
    _isIncognito = view.incognito;
    _isInactive = view.render_process_id == -1;
    _renderProcessId = view.render_process_id;
    _renderFrameId = view.render_view_id;
    _viewType = view.type;
  }
  return self;
}

@end

@implementation BEChromiumExtensionError

@synthesize isManifestError = _isManifestError;
@synthesize isWarning = _isWarning;
@synthesize message = _message;
@synthesize source = _source;
@synthesize occurrences = _occurrences;

- (instancetype)initWithManifestError:(BOOL)isManifestError
                              warning:(BOOL)isWarning
                              message:(const std::string&)message
                               source:(const std::string&)source
                          occurrences:(NSInteger)occurrences {
  if ((self = [super init])) {
    _isManifestError = isManifestError;
    _isWarning = isWarning;
    _message = base::SysUTF8ToNSString(message);
    _source = base::SysUTF8ToNSString(source);
    _occurrences = occurrences;
  }
  return self;
}

@end

@implementation BEChromiumExtension

@synthesize identifier = _identifier;
@synthesize name = _name;
@synthesize version = _version;
@synthesize summary = _summary;
@synthesize icon = _icon;
@synthesize state = _state;
@synthesize canToggle = _canToggle;
@synthesize canRemove = _canRemove;
@synthesize needsPermissionApproval = _needsPermissionApproval;
@synthesize notices = _notices;
@synthesize path = _path;
@synthesize updateURL = _updateURL;
@synthesize homepage = _homepage;
@synthesize permissions = _permissions;
@synthesize canChangeSiteAccess = _canChangeSiteAccess;
@synthesize siteAccess = _siteAccess;
@synthesize allowedSites = _allowedSites;
@synthesize requestedSites = _requestedSites;
@synthesize canAllowIncognito = _canAllowIncognito;
@synthesize allowsIncognito = _allowsIncognito;
@synthesize canAllowFileAccess = _canAllowFileAccess;
@synthesize allowsFileAccess = _allowsFileAccess;
@synthesize hasAction = _hasAction;
@synthesize isPinned = _isPinned;
@synthesize hasOptions = _hasOptions;
@synthesize commands = _commands;
@synthesize views = _views;
@synthesize collectsErrors = _collectsErrors;
@synthesize errors = _errors;

- (instancetype)initWithInfo:(const developer::ExtensionInfo&)info
                        icon:(NSImage*)icon
     needsPermissionApproval:(BOOL)needsPermissionApproval
          incognitoAvailable:(BOOL)incognitoAvailable {
  if ((self = [super init])) {
    _identifier = base::SysUTF8ToNSString(info.id);
    _name = base::SysUTF8ToNSString(info.name);
    _version = base::SysUTF8ToNSString(info.version);
    _summary = base::SysUTF8ToNSString(info.description);
    _icon = icon;
    _state = State(info.state);
    _canToggle = CanToggle(info);
    // What ExtensionUninstallDialog::Uninstall() checks again before it
    // removes one.
    _canRemove = info.user_may_modify && !info.must_remain_installed;
    _needsPermissionApproval = needsPermissionApproval;
    _notices = Notices(info);
    _path = info.path ? base::SysUTF8ToNSString(*info.path) : nil;
    _updateURL = base::SysUTF8ToNSString(info.update_url);
    // The manifest's own homepage_url: home_page.url falls back to the Web
    // Store's page, whose address domain substitution spoils.
    _homepage = info.manifest_home_page_url.empty()
                    ? nil
                    : URLFromString(info.manifest_home_page_url);

    NSMutableArray<NSString*>* permissions = [NSMutableArray array];
    for (const developer::Permission& permission :
         info.permissions.simple_permissions) {
      [permissions addObject:base::SysUTF8ToNSString(permission.message)];
    }
    _permissions = permissions;

    // Sites are separate (and the user's to choose) only when Chrome lets the
    // user withhold them (PermissionsManager::CanAffectExtension()); otherwise
    // they are among `permissions`, and it runs wherever it asks.
    _siteAccess = BEExtensionSiteAccessOnAllSites;
    NSMutableArray<NSString*>* allowedSites = [NSMutableArray array];
    NSMutableArray<NSString*>* requestedSites = [NSMutableArray array];
    if (const std::optional<developer::RuntimeHostPermissions>& hosts =
            info.permissions.runtime_host_permissions) {
      _canChangeSiteAccess = YES;
      switch (hosts->host_access) {
        case developer::HostAccess::kOnClick:
          _siteAccess = BEExtensionSiteAccessOnClick;
          break;
        case developer::HostAccess::kOnSpecificSites:
          _siteAccess = BEExtensionSiteAccessOnSpecificSites;
          break;
        case developer::HostAccess::kOnAllSites:
        case developer::HostAccess::kNone:
          _siteAccess = BEExtensionSiteAccessOnAllSites;
          break;
      }
      for (const developer::SiteControl& site : hosts->hosts) {
        NSMutableArray<NSString*>* sites =
            site.granted ? allowedSites : requestedSites;
        [sites addObject:base::SysUTF8ToNSString(site.host)];
      }
    }
    _allowedSites = allowedSites;
    _requestedSites = requestedSites;

    // Chrome's page hides the switch when private windows are off by policy.
    _canAllowIncognito = info.incognito_access.is_enabled && incognitoAvailable;
    _allowsIncognito = info.incognito_access.is_active;
    _canAllowFileAccess = info.file_access.is_enabled;
    _allowsFileAccess = info.file_access.is_active;
    // Only enabled extensions have actions (the generator's TODO).
    _hasAction = info.pinned_to_toolbar.has_value();
    _isPinned = info.pinned_to_toolbar.value_or(false);
    // An options page opens only while the extension runs (showOptions looks
    // among the enabled ones).
    _hasOptions = info.options_page.has_value() &&
                  info.state == developer::ExtensionState::kEnabled;

    NSMutableArray<id<BEExtensionCommand>>* commands = [NSMutableArray array];
    for (const developer::Command& command : info.commands) {
      [commands addObject:[[BEChromiumExtensionCommand alloc]
                              initWithCommand:command]];
    }
    _commands = commands;

    NSMutableArray<id<BEExtensionView>>* views = [NSMutableArray array];
    for (const developer::ExtensionView& view : info.views) {
      [views addObject:[[BEChromiumExtensionView alloc] initWithView:view]];
    }
    _views = views;

    // Errors are collected, and listed, only in developer mode (the error
    // console's IsEnabledForChromeExtensionsPage()).
    _collectsErrors = info.error_collection.is_active;
    NSMutableArray<id<BEExtensionError>>* errors = [NSMutableArray array];
    for (const developer::ManifestError& error : info.manifest_errors) {
      // The manifest's are logged as warnings (ManifestError).
      [errors addObject:[[BEChromiumExtensionError alloc]
                            initWithManifestError:YES
                                          warning:YES
                                          message:error.message
                                           source:error.source
                                      occurrences:1]];
    }
    for (const developer::RuntimeError& error : info.runtime_errors) {
      [errors addObject:[[BEChromiumExtensionError alloc]
                            initWithManifestError:NO
                                          warning:error.severity !=
                                                  developer::ErrorLevel::kError
                                          message:error.message
                                           source:error.source
                                      occurrences:error.occurrences]];
    }
    _errors = errors;
  }
  return self;
}

@end

namespace browser_engine {

// What Chrome's page listens to (DeveloperPrivateEventRouter's observers,
// less sync's and Safe Browsing's, which ungoogled-chromium leaves empty),
// each telling the manager the list may have changed; plus reload results.
class BEExtensionsManager::Observers
    : public extensions::ExtensionRegistryObserver,
      public extensions::ExtensionPrefsObserver,
      public extensions::PermissionsManager::Observer,
      public extensions::ErrorConsole::Observer,
      public extensions::ProcessManagerObserver,
      public extensions::CommandService::Observer,
      public extensions::WarningService::Observer,
      public extensions::ExtensionManagement::Observer,
      public extensions::LoadErrorReporter::Observer,
      public ToolbarActionsModel::Observer {
 public:
  Observers(BEExtensionsManager* owner, Profile* profile) : owner_(owner) {
    // Each where the profile has it (a guest profile lacks some).
    if (auto* registry = extensions::ExtensionRegistry::Get(profile)) {
      registry_.Observe(registry);
    }
    if (auto* prefs = extensions::ExtensionPrefs::Get(profile)) {
      prefs_.Observe(prefs);
    }
    if (auto* permissions = extensions::PermissionsManager::Get(profile)) {
      permissions_.Observe(permissions);
    }
    if (auto* error_console = extensions::ErrorConsole::Get(profile)) {
      error_console_.Observe(error_console);
    }
    if (auto* process_manager = extensions::ProcessManager::Get(profile)) {
      process_manager_.Observe(process_manager);
    }
    if (auto* commands = extensions::CommandService::Get(profile)) {
      commands_.Observe(commands);
    }
    if (auto* warnings = extensions::WarningService::Get(profile)) {
      warnings_.Observe(warnings);
    }
    if (auto* management =
            extensions::ExtensionManagementFactory::GetForBrowserContext(
                profile)) {
      management_.Observe(management);
    }
    if (auto* toolbar = ToolbarActionsModel::Get(profile)) {
      toolbar_.Observe(toolbar);
    }
    if (auto* load_errors = extensions::LoadErrorReporter::GetInstance()) {
      load_errors_.Observe(load_errors);
    }
    // Developer mode changes what's listed: views, errors, install warnings.
    pref_change_registrar_.Init(profile->GetPrefs());
    pref_change_registrar_.Add(
        prefs::kExtensionsUIDeveloperMode,
        base::BindRepeating(&BEExtensionsManager::ListChanged,
                            base::Unretained(owner)));
  }
  Observers(const Observers&) = delete;
  Observers& operator=(const Observers&) = delete;
  ~Observers() override = default;

 private:
  // extensions::ExtensionRegistryObserver:
  void OnExtensionLoaded(content::BrowserContext* browser_context,
                         const extensions::Extension* extension) override {
    owner_->FinishReloads(extension->path(), std::u16string());
    owner_->ListChanged();
  }
  void OnExtensionUnloaded(
      content::BrowserContext* browser_context,
      const extensions::Extension* extension,
      extensions::UnloadedExtensionReason reason) override {
    owner_->ListChanged();
  }
  void OnExtensionInstalled(content::BrowserContext* browser_context,
                            const extensions::Extension* extension,
                            bool is_update) override {
    // A disabled unpacked extension reloads without loading.
    owner_->FinishReloads(extension->path(), std::u16string());
    owner_->ListChanged();
  }
  void OnExtensionUninstalled(content::BrowserContext* browser_context,
                              const extensions::Extension* extension,
                              extensions::UninstallReason reason) override {
    owner_->ListChanged();
  }
  void OnShutdown(extensions::ExtensionRegistry* registry) override {
    registry_.Reset();
  }

  // extensions::ExtensionPrefsObserver:
  void OnExtensionDisableReasonsChanged(
      const extensions::ExtensionId& extension_id,
      extensions::DisableReasonSet disable_reasons) override {
    owner_->ListChanged();
  }
  void OnExtensionRuntimePermissionsChanged(
      const extensions::ExtensionId& extension_id) override {
    owner_->ListChanged();
  }
  void OnExtensionPrefsWillBeDestroyed(
      extensions::ExtensionPrefs* prefs) override {
    prefs_.Reset();
  }

  // extensions::PermissionsManager::Observer:
  void OnUserPermissionsSettingsChanged(
      const extensions::PermissionsManager::UserPermissionsSettings& settings)
      override {
    owner_->ListChanged();
  }
  void OnExtensionPermissionsUpdated(
      const extensions::Extension& extension,
      const extensions::PermissionSet& permissions,
      extensions::PermissionsManager::UpdateReason reason) override {
    owner_->ListChanged();
  }
  void OnPermissionsManagerShutdown() override { permissions_.Reset(); }

  // extensions::ErrorConsole::Observer:
  void OnErrorAdded(const extensions::ExtensionError* error) override {
    owner_->ListChanged();
  }
  void OnErrorsRemoved(const std::set<std::string>& extension_ids) override {
    owner_->ListChanged();
  }
  void OnErrorConsoleDestroyed() override { error_console_.Reset(); }

  // extensions::ProcessManagerObserver: what DevTools can inspect.
  void OnExtensionFrameRegistered(
      const extensions::ExtensionId& extension_id,
      content::RenderFrameHost* render_frame_host) override {
    owner_->ListChanged();
  }
  void OnExtensionFrameUnregistered(
      const extensions::ExtensionId& extension_id,
      content::RenderFrameHost* render_frame_host) override {
    owner_->ListChanged();
  }
  void OnStartedTrackingServiceWorkerInstance(
      const extensions::WorkerId& worker_id) override {
    owner_->ListChanged();
  }
  void OnStoppedTrackingServiceWorkerInstance(
      content::BrowserContext& browser_context,
      const extensions::WorkerId& worker_id) override {
    owner_->ListChanged();
  }
  void OnProcessManagerShutdown(extensions::ProcessManager* manager) override {
    process_manager_.Reset();
  }

  // extensions::CommandService::Observer:
  void OnExtensionCommandAdded(const extensions::ExtensionId& extension_id,
                               const std::string& command_name) override {
    owner_->ListChanged();
  }
  void OnExtensionCommandRemoved(const extensions::ExtensionId& extension_id,
                                 const std::string& command_name) override {
    owner_->ListChanged();
  }
  void OnCommandServiceDestroying() override { commands_.Reset(); }

  // extensions::WarningService::Observer:
  void ExtensionWarningsChanged(
      const extensions::ExtensionIdSet& affected_extensions) override {
    owner_->ListChanged();
  }

  // extensions::ExtensionManagement::Observer: policy.
  void OnExtensionManagementSettingsChanged() override {
    owner_->ListChanged();
  }

  // extensions::LoadErrorReporter::Observer: for every profile. Chrome's
  // reload function goes by the folder alone; so do we, less another
  // profile's.
  void OnLoadFailure(content::BrowserContext* browser_context,
                     const base::FilePath& extension_path,
                     const std::u16string& error) override {
    if (browser_context &&
        Profile::FromBrowserContext(browser_context)->GetOriginalProfile() !=
            owner_->profile_) {
      return;
    }
    owner_->FinishReloads(extension_path, error);
    owner_->ListChanged();
  }

  // ToolbarActionsModel::Observer: whether an action is pinned, or there.
  void OnToolbarActionAdded(const ToolbarActionsModel::ActionId& id) override {
    owner_->ListChanged();
  }
  void OnToolbarActionRemoved(
      const ToolbarActionsModel::ActionId& id) override {
    owner_->ListChanged();
  }
  // Titles and badges, which the list doesn't show.
  void OnToolbarActionUpdated(
      const ToolbarActionsModel::ActionId& id) override {}
  void OnToolbarModelInitialized() override { owner_->ListChanged(); }
  void OnToolbarPinnedActionsChanged() override { owner_->ListChanged(); }
  void OnToolbarActionsModelShutdown() override { toolbar_.Reset(); }

  const raw_ptr<BEExtensionsManager> owner_;
  base::ScopedObservation<extensions::ExtensionRegistry,
                          extensions::ExtensionRegistryObserver>
      registry_{this};
  base::ScopedObservation<extensions::ExtensionPrefs,
                          extensions::ExtensionPrefsObserver>
      prefs_{this};
  base::ScopedObservation<extensions::PermissionsManager,
                          extensions::PermissionsManager::Observer>
      permissions_{this};
  base::ScopedObservation<extensions::ErrorConsole,
                          extensions::ErrorConsole::Observer>
      error_console_{this};
  base::ScopedObservation<extensions::ProcessManager,
                          extensions::ProcessManagerObserver>
      process_manager_{this};
  base::ScopedObservation<extensions::CommandService,
                          extensions::CommandService::Observer>
      commands_{this};
  base::ScopedObservation<extensions::WarningService,
                          extensions::WarningService::Observer>
      warnings_{this};
  base::ScopedObservation<extensions::ExtensionManagement,
                          extensions::ExtensionManagement::Observer>
      management_{this};
  base::ScopedObservation<extensions::LoadErrorReporter,
                          extensions::LoadErrorReporter::Observer>
      load_errors_{this};
  base::ScopedObservation<ToolbarActionsModel, ToolbarActionsModel::Observer>
      toolbar_{this};
  PrefChangeRegistrar pref_change_registrar_;
};

BEExtensionsManager::BEExtensionsManager(Profile* profile,
                                         base::RepeatingClosure changed)
    : profile_(profile->GetOriginalProfile()),
      changed_(std::move(changed)),
      observers_(std::make_unique<Observers>(this, profile_)) {}

BEExtensionsManager::~BEExtensionsManager() {
  // The suspension is the profile's (its global registry's), not this
  // window's: a recorder whose window closes mustn't leave it on.
  if (shortcuts_suspended_) {
    if (auto* registry =
            extensions::ExtensionCommandsGlobalRegistry::Get(profile_)) {
      registry->SetShortcutHandlingSuspended(false);
    }
  }
}

// MARK: The list

NSArray<id<BEExtension>>* BEExtensionsManager::Extensions() {
  read_since_told_ = true;
  if (stale_ && !generator_) {
    Generate();
  }
  return list_ ?: @[];
}

void BEExtensionsManager::ListChanged() {
  // Chrome tells of one change several times (an install loads, installs and
  // registers frames), from inside its own notifications: look once, later.
  stale_ = true;
  if (update_pending_) {
    return;
  }
  update_pending_ = true;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(&BEExtensionsManager::Update, weak_factory_.GetWeakPtr()));
}

void BEExtensionsManager::Update() {
  update_pending_ = false;
  // The list being made comes with a telling; reading it then makes the
  // next.
  if (generator_) {
    return;
  }
  // While the app shows the list, the new one comes before the telling, so
  // it reads it once. Otherwise the telling is all: the next read makes it
  // (and a service worker stopping in a hidden window costs nothing).
  if (read_since_told_) {
    Generate();
  } else {
    Tell();
  }
}

void BEExtensionsManager::Generate() {
  stale_ = false;
  // A new generator each time: each makes one list
  // (DeveloperPrivateGetExtensionsInfoFunction does the same). On, off,
  // blocked and crashed, as Chrome's page asks. The list always comes on a
  // later task, after the icons load.
  generator_ = std::make_unique<extensions::ExtensionInfoGenerator>(profile_);
  generator_->CreateExtensionsInfo(
      /*include_disabled=*/true, /*include_terminated=*/true,
      base::BindOnce(&BEExtensionsManager::OnGenerated,
                     weak_factory_.GetWeakPtr()));
}

void BEExtensionsManager::OnGenerated(
    std::vector<developer::ExtensionInfo> infos) {
  // It may be the generator running this (OnImageLoaded() allows its
  // deletion afterwards, but there's no need to cut it so fine).
  base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
      FROM_HERE, std::move(generator_));

  const bool incognito_available =
      extensions::CreateProfileInfo(profile_).is_incognito_available;
  extensions::ExtensionPrefs* prefs = extensions::ExtensionPrefs::Get(profile_);
  NSMutableArray<BEChromiumExtension*>* list =
      [NSMutableArray arrayWithCapacity:infos.size()];
  for (const developer::ExtensionInfo& info : infos) {
    // Turned off by an update asking for more (DISABLE_PERMISSIONS_INCREASE),
    // which Chrome's page leaves to its re-enable prompt.
    const bool escalated = info.state == developer::ExtensionState::kDisabled &&
                           prefs &&
                           prefs->DidExtensionEscalatePermissions(info.id);
    [list addObject:[[BEChromiumExtension alloc]
                                   initWithInfo:info
                                           icon:IconFromDataURL(info.icon_url)
                        needsPermissionApproval:escalated
                             incognitoAvailable:incognito_available]];
  }
  // By name, as Chrome's page lists them.
  [list sortUsingComparator:^NSComparisonResult(BEChromiumExtension* a,
                                                BEChromiumExtension* b) {
    const NSComparisonResult result = [a.name localizedStandardCompare:b.name];
    return result != NSOrderedSame ? result
                                   : [a.identifier compare:b.identifier];
  }];
  list_ = [list copy];
  Tell();
}

void BEExtensionsManager::Tell() {
  read_since_told_ = false;
  changed_.Run();
}

// MARK: Developer mode

bool BEExtensionsManager::DeveloperMode() const {
  return extensions::CreateProfileInfo(profile_).in_developer_mode;
}

bool BEExtensionsManager::CanChangeDeveloperMode() const {
  // Chrome's page greys the switch out under policy, and child accounts may
  // not change it (updateProfileConfiguration).
  const developer::ProfileInfo info = extensions::CreateProfileInfo(profile_);
  return !info.is_developer_mode_controlled_by_policy && !info.is_child_account;
}

void BEExtensionsManager::SetDeveloperMode(bool on) {
  if (!CanChangeDeveloperMode()) {
    return;
  }
  // Not the pref directly: this also tells the error console and the
  // extensions that care. The pref's change comes back as ListChanged().
  extensions::util::SetDeveloperModeForProfile(profile_, on);
}

// MARK: Actions

const extensions::Extension* BEExtensionsManager::Find(
    const std::string& id) const {
  return extensions::ExtensionRegistry::Get(profile_)->GetExtensionById(
      id, extensions::ExtensionRegistry::EVERYTHING);
}

void BEExtensionsManager::SetEnabled(const std::string& id, bool enabled) {
  // ManagementSetEnabledFunction::Run(), as Chrome's page (no source
  // extension) calls it, without the supervised user's approval flow and the
  // rare requirements recheck. A permission increase is approved by the app
  // before it asks (needsPermissionApproval).
  const extensions::Extension* extension = Find(id);
  if (!extension) {
    return;
  }
  extensions::ManagementPolicy* policy =
      extensions::ExtensionSystem::Get(profile_)->management_policy();
  if (!policy->ExtensionMayModifySettings(/*source_extension=*/nullptr,
                                          extension, /*error=*/nullptr)) {
    return;
  }
  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(profile_);
  const bool currently_enabled = registry->enabled_extensions().Contains(id) ||
                                 registry->terminated_extensions().Contains(id);
  if (enabled == currently_enabled) {
    return;
  }
  extensions::ExtensionRegistrar* registrar =
      extensions::ExtensionRegistrar::Get(profile_);
  if (!enabled) {
    // ChromeManagementAPIDelegate::DisableExtension().
    registrar->DisableExtensionWithSource(
        /*source_extension=*/nullptr, id,
        extensions::disable_reason::DISABLE_USER_ACTION);
  } else {
    if (registry->blocklisted_extensions().Contains(id) ||
        policy->MustRemainDisabled(extension, /*reason=*/nullptr)) {
      return;
    }
    // ChromeManagementAPIDelegate::EnableExtension().
    registrar->GrantPermissionsAndEnableExtension(*extension);
  }
  ListChanged();
}

bool BEExtensionsManager::Remove(const std::string& id) {
  // What ExtensionUninstallDialog checks before it removes, with the reason
  // Chrome's page gives (management.uninstall).
  const extensions::Extension* extension = Find(id);
  if (!extension) {
    return false;
  }
  extensions::ManagementPolicy* policy =
      extensions::ExtensionSystem::Get(profile_)->management_policy();
  if (!policy->UserMayModifySettings(extension, /*error=*/nullptr) ||
      policy->MustRemainInstalled(extension, /*error=*/nullptr)) {
    return false;
  }
  // A copy: the extension goes during the call.
  const std::string extension_id = id;
  std::u16string error;
  const bool removed =
      extensions::ExtensionRegistrar::Get(profile_)->UninstallExtension(
          extension_id, extensions::UNINSTALL_REASON_MANAGEMENT_API, &error);
  ListChanged();
  return removed;
}

void BEExtensionsManager::SetIncognitoAllowed(const std::string& id,
                                              bool allowed) {
  const extensions::Extension* extension = Find(id);
  if (!extension || !extensions::util::CanBeIncognitoEnabled(extension)) {
    return;
  }
  // May reload the extension at once (`extension` is stale afterwards).
  extensions::util::SetIsIncognitoEnabled(id, profile_, allowed);
  ListChanged();
}

void BEExtensionsManager::SetFileAccessAllowed(const std::string& id,
                                               bool allowed) {
  const extensions::Extension* extension = Find(id);
  // The generator's file_access.is_enabled.
  if (!extension || !(extension->wants_file_access() ||
                      extensions::Manifest::ShouldAlwaysAllowFileAccess(
                          extension->location()))) {
    return;
  }
  // May reload the extension at once (`extension` is stale afterwards).
  extensions::util::SetAllowFileAccess(id, profile_, allowed);
  ListChanged();
}

void BEExtensionsManager::SetSiteAccess(const std::string& id,
                                        BEExtensionSiteAccess access) {
  // updateExtensionConfiguration's host_access.
  const extensions::Extension* extension = Find(id);
  extensions::PermissionsManager* manager =
      extensions::PermissionsManager::Get(profile_);
  if (!extension || !manager->CanAffectExtension(*extension)) {
    return;
  }
  extensions::ScriptingPermissionsModifier modifier(profile_, extension);
  switch (access) {
    case BEExtensionSiteAccessOnClick:
      modifier.SetWithholdHostPermissions(true);
      modifier.RemoveAllGrantedHostPermissions();
      break;
    case BEExtensionSiteAccessOnSpecificSites:
      if (manager->HasBroadGrantedHostPermissions(*extension)) {
        modifier.RemoveBroadGrantedHostPermissions();
      }
      modifier.SetWithholdHostPermissions(true);
      break;
    case BEExtensionSiteAccessOnAllSites:
      modifier.SetWithholdHostPermissions(false);
      break;
  }
  ListChanged();
}

bool BEExtensionsManager::SetSiteAllowed(const std::string& id,
                                         const std::string& site,
                                         bool allowed) {
  // addHostPermission and removeHostPermission.
  const std::optional<URLPattern> pattern = ParseSite(site);
  const extensions::Extension* extension = Find(id);
  extensions::PermissionsManager* manager =
      extensions::PermissionsManager::Get(profile_);
  if (!pattern || !extension || !manager->CanAffectExtension(*extension)) {
    return false;
  }
  extensions::URLPatternSet hosts({*pattern});
  extensions::PermissionSet permissions(extensions::APIPermissionSet(),
                                        extensions::ManifestPermissionSet(),
                                        hosts.Clone(), hosts.Clone());
  // Both finish later, and their changes come back through the permissions
  // manager.
  if (allowed) {
    extensions::PermissionsUpdater(profile_).GrantRuntimePermissions(
        *extension, permissions, base::DoNothing());
  } else {
    // Only what was granted can go; a site that wasn't is not allowed
    // already.
    std::unique_ptr<const extensions::PermissionSet> granted =
        extensions::PermissionSet::CreateIntersection(
            permissions, *manager->GetRevokablePermissions(*extension),
            extensions::URLPatternSet::IntersectionBehavior::kDetailed);
    if (!granted->IsEmpty()) {
      extensions::PermissionsUpdater(profile_).RevokeRuntimePermissions(
          *extension, *granted, base::DoNothing());
    }
  }
  return true;
}

void BEExtensionsManager::SetPinned(const std::string& id, bool pinned) {
  ToolbarActionsModel* model = ToolbarActionsModel::Get(profile_);
  if (!model || !model->HasAction(id) || model->IsActionPinned(id) == pinned) {
    return;
  }
  model->SetActionVisibility(id, pinned);
}

void BEExtensionsManager::OpenOptions(const std::string& id,
                                      BrowserWindowInterface* browser) {
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(profile_)
          ->enabled_extensions()
          .GetByID(id);
  if (!extension || !extensions::OptionsPageInfo::HasOptionsPage(extension)) {
    return;
  }
  // The options page itself, also for one meant to be embedded
  // (ExtensionTabUtil::OpenOptionsPage() would open Chrome's extensions page
  // around it, chrome://extensions/?options=<id>). As
  // BrowserExtensionWindowController::OpenOptionsPage(): one tab for it, the
  // new tab page reused, and in a private window only for a split-mode
  // extension: a spanning one can't save its settings there, so it opens in
  // a window of the everyday profile.
  const GURL& url = extensions::OptionsPageInfo::GetOptionsPage(extension);
  if (!browser || (browser->GetProfile()->IsOffTheRecord() &&
                   !extensions::IncognitoInfo::IsSplitMode(extension))) {
    ShowSingletonTabOverwritingNTP(profile_.get(), url,
                                   NavigateParams::RESPECT);
  } else {
    ShowSingletonTabOverwritingNTP(browser, url, NavigateParams::RESPECT);
  }
}

bool BEExtensionsManager::SetShortcut(const std::string& id,
                                      const std::string& command,
                                      const std::string& keys) {
  extensions::CommandService* commands =
      extensions::CommandService::Get(profile_);
  if (!commands || !Find(id)) {
    return false;
  }
  // One of the extension's commands: its action's, or a named one.
  bool known = false;
  ui::CommandMap named;
  if (commands->GetNamedCommands(id, extensions::CommandService::ALL,
                                 extensions::CommandService::ANY_SCOPE,
                                 &named)) {
    known = named.contains(command);
  }
  for (auto type : {extensions::ActionInfo::Type::kBrowser,
                    extensions::ActionInfo::Type::kPage,
                    extensions::ActionInfo::Type::kAction}) {
    extensions::Command action_command;
    if (!known &&
        commands->GetExtensionActionCommand(
            id, type, extensions::CommandService::ALL, &action_command,
            /*active=*/nullptr)) {
      known = action_command.command_name() == command;
    }
  }
  if (!known) {
    return false;
  }
  // UpdateKeybindingPrefs() parses as this does, and takes a key it can't
  // read as "none": refuse those rather than clear the shortcut.
  if (!keys.empty() &&
      extensions::Command::StringToAccelerator(keys, command).key_code() ==
          ui::VKEY_UNKNOWN) {
    return false;
  }
  // updateExtensionCommand: takes the key from any other extension that had
  // it. The change comes back through the command service.
  commands->UpdateKeybindingPrefs(id, command, keys);
  ListChanged();
  return true;
}

void BEExtensionsManager::SetCommandGlobal(const std::string& id,
                                           const std::string& command,
                                           bool global) {
  extensions::CommandService* commands =
      extensions::CommandService::Get(profile_);
  if (!commands || !Find(id)) {
    return;
  }
  commands->SetScope(id, command, global);
  ListChanged();
}

void BEExtensionsManager::SetShortcutsSuspended(bool suspended) {
  // setShortcutHandlingSuspended: while the app records a shortcut, the
  // profile's global ones don't fire.
  extensions::ExtensionCommandsGlobalRegistry* registry =
      extensions::ExtensionCommandsGlobalRegistry::Get(profile_);
  if (!registry || suspended == shortcuts_suspended_) {
    return;
  }
  shortcuts_suspended_ = suspended;
  registry->SetShortcutHandlingSuspended(suspended);
}

// MARK: Developer mode's actions

void BEExtensionsManager::RunLater(void (^block)(void)) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<BEExtensionsManager> self, void (^block)(void)) {
            if (self) {
              block();
            }
          },
          weak_factory_.GetWeakPtr(), block));
}

void BEExtensionsManager::LoadUnpacked(const base::FilePath& path,
                                       void (^completion)(NSString* identifier,
                                                          NSString* error)) {
  // DeveloperPrivateLoadUnpackedFunction's checks, its folder from the app's
  // own panel in place of Chrome's file dialog. (Chrome's own messages:
  // developerPrivate doesn't localise them either.)
  NSString* refusal = nil;
  const developer::ProfileInfo info = extensions::CreateProfileInfo(profile_);
  extensions::ExtensionManagement* management =
      extensions::ExtensionManagementFactory::GetForBrowserContext(profile_);
  if (info.is_child_account) {
    refusal = @"Child account users cannot load unpacked extensions.";
  } else if (!info.in_developer_mode) {
    refusal = @"Must be in developer mode to load unpacked extensions.";
  } else if (!management || management->BlocklistedByDefault()) {
    refusal = @"Extension installation is blocked by policy.";
  }
  if (refusal) {
    RunLater(^{
      completion(nil, refusal);
    });
    return;
  }
  // Quietly: a failure is the completion's, not Chrome's message box
  // (LoadErrorReporter's noisy errors). The installer keeps itself alive
  // until it's done.
  scoped_refptr<extensions::UnpackedInstaller> installer =
      extensions::UnpackedInstaller::Create(profile_);
  installer->set_be_noisy_on_failure(false);
  installer->set_completion_callback(
      base::BindOnce(&BEExtensionsManager::OnUnpackedLoaded,
                     weak_factory_.GetWeakPtr(), completion));
  installer->Load(path);
}

void BEExtensionsManager::OnUnpackedLoaded(
    void (^completion)(NSString*, NSString*),
    const extensions::Extension* extension,
    const base::FilePath& path,
    const std::u16string& error) {
  NSString* identifier =
      extension ? base::SysUTF8ToNSString(extension->id()) : nil;
  NSString* message =
      extension ? nil
                : (error.empty() ? @"The extension could not be loaded."
                                 : base::SysUTF16ToNSString(error));
  RunLater(^{
    completion(identifier, message);
  });
}

void BEExtensionsManager::Reload(const std::string& id,
                                 void (^completion)(NSString* error)) {
  const extensions::Extension* extension = Find(id);
  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(profile_);
  if (!extension) {
    RunLater(^{
      completion(@"The extension is not installed.");
    });
    return;
  }
  // ExtensionRegistrar ignores these (DoReloadExtension()).
  if (registry->blocklisted_extensions().Contains(id) ||
      registry->blocked_extensions().Contains(id)) {
    RunLater(^{
      completion(@"The extension is blocked.");
    });
    return;
  }
  // DeveloperPrivateReloadFunction: an unpacked one is read from its folder
  // again, which can fail; wait for it to load (or install, when it is off)
  // or fail, by its folder. Others reload from what was installed.
  const bool unpacked =
      extensions::Manifest::IsUnpackedLocation(extension->location());
  if (unpacked) {
    pending_reloads_.push_back({extension->path(), completion});
  }
  // Quietly, as above. A copy of the id: the extension unloads during the
  // call.
  const std::string extension_id = id;
  extensions::ExtensionRegistrar::Get(profile_)
      ->ReloadExtensionWithQuietFailure(extension_id);
  if (!unpacked) {
    RunLater(^{
      completion(nil);
    });
  }
  ListChanged();
}

void BEExtensionsManager::FinishReloads(const base::FilePath& path,
                                        const std::u16string& error) {
  NSString* message = error.empty() ? nil : base::SysUTF16ToNSString(error);
  std::erase_if(pending_reloads_, [&](const PendingReload& reload) {
    if (reload.path != path) {
      return false;
    }
    void (^completion)(NSString*) = reload.completion;
    RunLater(^{
      completion(message);
    });
    return true;
  });
}

void BEExtensionsManager::UpdateAll(void (^completion)(void)) {
  // DeveloperPrivateAutoUpdateFunction, which never answers when updates are
  // off; this does, at once.
  extensions::ExtensionUpdater* updater =
      extensions::ExtensionUpdater::Get(profile_);
  if (!updater || !updater->enabled()) {
    RunLater(completion);
    return;
  }
  extensions::ExtensionUpdater::CheckParams params;
  params.fetch_priority = extensions::DownloadFetchPriority::kForeground;
  params.install_immediately = true;
  params.callback = base::BindOnce(&BEExtensionsManager::RunLater,
                                   weak_factory_.GetWeakPtr(), completion);
  updater->CheckNow(std::move(params));
}

void BEExtensionsManager::Inspect(id<BEExtensionView> view,
                                  const std::string& id) {
  // DeveloperPrivateOpenDevToolsFunction. DevTools open in Chrome's own
  // windows, or docked into a tab's window.
  if (![(NSObject*)view isKindOfClass:[BEChromiumExtensionView class]]) {
    return;
  }
  BEChromiumExtensionView* target = (BEChromiumExtensionView*)view;
  Profile* profile =
      target.isIncognito
          ? profile_->GetPrimaryOTRProfile(/*create_if_needed=*/true)
          : profile_.get();
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(profile_)
          ->enabled_extensions()
          .GetByID(id);

  if (target.viewType ==
      developer::ViewType::kExtensionServiceWorkerBackground) {
    if (!extension ||
        !extensions::BackgroundInfo::IsServiceWorkerBased(extension)) {
      return;
    }
    // A stopped worker starts first.
    if (target.renderProcessId == -1) {
      extensions::devtools_util::InspectInactiveServiceWorkerBackground(
          extension, profile, DevToolsOpenedByAction::kInspectLink);
    } else {
      extensions::devtools_util::InspectServiceWorkerBackground(
          extension, profile, DevToolsOpenedByAction::kInspectLink);
    }
    return;
  }

  if (target.renderProcessId == -1) {
    // A lazy background page, woken up.
    if (!extension ||
        !extensions::BackgroundInfo::HasLazyBackgroundPage(extension)) {
      return;
    }
    extensions::devtools_util::InspectBackgroundPage(
        extension, profile, DevToolsOpenedByAction::kInspectLink);
    return;
  }

  // The frame may have gone since the list was made.
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(
      target.renderProcessId, target.renderFrameId);
  content::WebContents* contents =
      frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  if (!contents) {
    return;
  }
  DevToolsWindow::OpenDevToolsWindow(contents,
                                     DevToolsOpenedByAction::kInspectLink);
  // A tab's DevTools dock into its window: show the tab, as Chrome's page
  // does. Popups and background pages have their own windows.
  tabs::TabInterface* tab = tabs::TabInterface::MaybeGetFromContents(contents);
  BrowserWindowInterface* browser =
      tab ? tab->GetBrowserWindowInterface() : nullptr;
  if (browser &&
      browser->GetType() == BrowserWindowInterface::Type::TYPE_NORMAL) {
    TabStripModel* tab_strip = browser->GetTabStripModel();
    const int index = tab_strip->GetIndexOfWebContents(contents);
    if (index != TabStripModel::kNoTab) {
      tab_strip->ActivateTabAt(index);
    }
  }
}

void BEExtensionsManager::SetCollectsErrors(const std::string& id,
                                            bool collects) {
  extensions::ErrorConsole* error_console =
      extensions::ErrorConsole::Get(profile_);
  if (!error_console || !Find(id)) {
    return;
  }
  error_console->SetReportingAllForExtension(id, collects);
  // Nothing announces it.
  ListChanged();
}

void BEExtensionsManager::ClearErrors(const std::string& id) {
  // deleteExtensionErrors for every error of the extension. Comes back as
  // OnErrorsRemoved().
  if (extensions::ErrorConsole* error_console =
          extensions::ErrorConsole::Get(profile_)) {
    error_console->RemoveErrors(
        extensions::ErrorMap::Filter::ErrorsForExtension(id));
  }
}

}  // namespace browser_engine

// MARK: BEWindowExtensionsManager

// Each forwards to the window's manager, which is null once the window
// closed: then nothing happens, and completions don't run.
@implementation BEChromiumWindow (ExtensionsManager)

- (NSArray<id<BEExtension>>*)installedExtensions {
  browser_engine::BEExtensionsManager* manager = [self extensionsManager];
  return manager ? manager->Extensions() : @[];
}

- (BOOL)extensionsDeveloperMode {
  browser_engine::BEExtensionsManager* manager = [self extensionsManager];
  return manager && manager->DeveloperMode();
}

- (BOOL)canChangeExtensionsDeveloperMode {
  browser_engine::BEExtensionsManager* manager = [self extensionsManager];
  return manager && manager->CanChangeDeveloperMode();
}

- (void)setExtensionsDeveloperModeEnabled:(BOOL)on {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetDeveloperMode(on);
  }
}

- (void)setExtension:(NSString*)identifier enabled:(BOOL)enabled {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetEnabled(base::SysNSStringToUTF8(identifier), enabled);
  }
}

- (BOOL)removeExtension:(NSString*)identifier {
  browser_engine::BEExtensionsManager* manager = [self extensionsManager];
  return manager && manager->Remove(base::SysNSStringToUTF8(identifier));
}

- (void)setExtension:(NSString*)identifier allowsIncognito:(BOOL)allow {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetIncognitoAllowed(base::SysNSStringToUTF8(identifier), allow);
  }
}

- (void)setExtension:(NSString*)identifier allowsFileAccess:(BOOL)allow {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetFileAccessAllowed(base::SysNSStringToUTF8(identifier), allow);
  }
}

- (void)setExtension:(NSString*)identifier
          siteAccess:(BEExtensionSiteAccess)access {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetSiteAccess(base::SysNSStringToUTF8(identifier), access);
  }
}

- (BOOL)setExtension:(NSString*)identifier
                site:(NSString*)site
             allowed:(BOOL)allowed {
  browser_engine::BEExtensionsManager* manager = [self extensionsManager];
  return manager &&
         manager->SetSiteAllowed(base::SysNSStringToUTF8(identifier),
                                 base::SysNSStringToUTF8(site), allowed);
}

- (void)setExtension:(NSString*)identifier pinned:(BOOL)pinned {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetPinned(base::SysNSStringToUTF8(identifier), pinned);
  }
}

- (void)openOptionsOfExtension:(NSString*)identifier {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->OpenOptions(base::SysNSStringToUTF8(identifier), [self browser]);
  }
}

- (BOOL)setShortcut:(NSString*)keys
         forCommand:(NSString*)command
        ofExtension:(NSString*)identifier {
  browser_engine::BEExtensionsManager* manager = [self extensionsManager];
  return manager && manager->SetShortcut(base::SysNSStringToUTF8(identifier),
                                         base::SysNSStringToUTF8(command),
                                         base::SysNSStringToUTF8(keys));
}

- (void)setCommand:(NSString*)command
       ofExtension:(NSString*)identifier
            global:(BOOL)global {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetCommandGlobal(base::SysNSStringToUTF8(identifier),
                              base::SysNSStringToUTF8(command), global);
  }
}

- (void)setExtensionShortcutsSuspended:(BOOL)suspended {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetShortcutsSuspended(suspended);
  }
}

- (void)loadUnpackedExtensionAtPath:(NSString*)path
                         completion:
                             (void (^)(NSString* _Nullable identifier,
                                       NSString* _Nullable error))completion {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->LoadUnpacked(base::apple::NSStringToFilePath(path), completion);
  }
}

- (void)reloadExtension:(NSString*)identifier
             completion:(void (^)(NSString* _Nullable error))completion {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->Reload(base::SysNSStringToUTF8(identifier), completion);
  }
}

- (void)updateExtensionsWithCompletion:(void (^)(void))completion {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->UpdateAll(completion);
  }
}

- (void)inspectExtensionView:(id<BEExtensionView>)view
                 ofExtension:(NSString*)identifier {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->Inspect(view, base::SysNSStringToUTF8(identifier));
  }
}

- (void)setExtension:(NSString*)identifier collectsErrors:(BOOL)collects {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->SetCollectsErrors(base::SysNSStringToUTF8(identifier), collects);
  }
}

- (void)clearErrorsOfExtension:(NSString*)identifier {
  if (browser_engine::BEExtensionsManager* manager = [self extensionsManager]) {
    manager->ClearErrors(base::SysNSStringToUTF8(identifier));
  }
}

@end
