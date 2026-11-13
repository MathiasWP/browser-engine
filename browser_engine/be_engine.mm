#import "browser_engine/be_engine.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include <memory>
#include <string>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/check.h"
#include "base/feature_list.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/mac/mac_util.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#import "browser_engine/be_bookmarks.h"
#include "browser_engine/be_browser_window.h"
#import "browser_engine/be_closed.h"
#include "browser_engine/be_downloads.h"
#import "browser_engine/be_most_visited.h"
#import "browser_engine/be_page_dialogs.h"
#import "browser_engine/be_palette.h"
#import "browser_engine/public/BEEngineOptional.h"
#import "browser_engine/be_preferences.h"
#import "browser_engine/be_profiles.h"
#import "browser_engine/be_visited.h"
#include "browser_engine/browser_engine_hooks.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_window.h"
#include "chrome/browser/ui/login/login_handler.h"
#include "chrome/browser/sessions/tab_restore_service_factory.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "chrome/browser/ui/browser_window/public/profile_browser_collection.h"
#include "components/javascript_dialogs/tab_modal_dialog_view.h"
#include "content/public/browser/weak_document_ptr.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/profiles/profile_picker.h"
#include "chrome/common/chrome_constants.h"
#include "chrome/common/chrome_paths_internal.h"
#include "chrome/common/chrome_switches.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/version_info/version_info.h"
#include "content/public/browser/browser_accessibility_state.h"
#import "content/public/browser/native_event_processor_mac.h"
#include "content/public/browser/scoped_accessibility_mode.h"
#include "content/public/common/content_features.h"
#include "net/base/apple/url_conversions.h"
#include "ui/accessibility/ax_mode.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"

// The framework's own entry point, chrome/app/chrome_main.cc. No header
// declares it; chrome_exe_main_mac.cc finds it with dlsym().
extern "C" int ChromeMain(int argc, const char** argv);

@interface BEChromiumEngine ()
// From the hooks: the main loop runs and startup has made its windows.
- (void)browserDidStart;
// From our windows: one became active (OnWindowActivated()).
- (void)windowDidBecomeActive;
// From touch point 30: whether the app shows its own profile picker for
// `entryPoint` (ProfilePicker::EntryPoint).
- (BOOL)showProfilePicker:(int)entryPoint;
@end

// BrowserCrApplication's accessibility support, for the app's NSApp
// (chrome_browser_application_mac.mm at 156): Chrome's accessibility comes on
// when VoiceOver runs or other assistive technology asks for it. The methods
// AddMissingAppMethods() adds to NSApp's class call it.
@interface BEAppAccessibility : NSObject
// NSWorkspace's voiceOverEnabled, which BrowserAccessibilityStateImplMac
// observes for NSApp from its start, is (or became) `voiceOverEnabled`.
- (void)voiceOverStateChanged:(BOOL)voiceOverEnabled;
// Assistive technology set NSApp's AXEnhancedUserInterface.
- (void)enableScreenReaderCompleteModeAfterDelay:(BOOL)enable;
// Assistive technology read NSApp's accessibilityRole.
- (void)accessibilityRoleRequested;
@end

namespace browser_engine {

namespace {

BEChromiumEngine* Engine() {
  static BEChromiumEngine* engine = [[BEChromiumEngine alloc] init];
  return engine;
}

// What the touch points in Chromium call (browser_engine_hooks.h).
class EngineHooks : public Hooks {
 public:
  EngineHooks() = default;
  EngineHooks(const EngineHooks&) = delete;
  EngineHooks& operator=(const EngineHooks&) = delete;
  ~EngineHooks() override = default;

  BrowserWindow* CreateBrowserWindow(BrowserWindowInterface* browser) override {
    // Normal windows only, for milestone 1. Popups, app and DevTools windows
    // and picture-in-picture keep Chrome's own Views windows.
    if (browser->GetType() != BrowserWindowInterface::TYPE_NORMAL) {
      return nullptr;
    }
    return new BEBrowserWindow(browser);
  }

  void BrowserWindowInitialized(BrowserWindowInterface* browser) override {
    if (BEBrowserWindow* window = BEBrowserWindow::FromBrowser(browser)) {
      // Downloads of every profile our windows show, from its first window
      // on: the everyday profile, and a private window's own.
      downloads_.ObserveProfile(browser->GetProfile());
      window->OnBrowserInitialized();
      // Chrome has installed its app-modal dialog factory by now
      // (ChromeBrowserMainExtraPartsViews).
      InstallAppModalDialogFactory();
    }
  }

  views::Widget* GetWidgetForBrowser(BrowserWindowInterface* browser) override {
    BEBrowserWindow* window = BEBrowserWindow::FromBrowser(browser);
    return window ? window->widget() : nullptr;
  }

  void ShowSessionCrashedBubble(BrowserWindowInterface* browser) override {
    // Our windows have no app menu to anchor the bubble to: the window offers
    // the restore to the app instead.
    if (BEBrowserWindow* window = BEBrowserWindow::FromBrowser(browser)) {
      window->OfferRestoreAfterCrash();
    }
  }

  void PreCreateThreads() override {
    // After Chrome's colour mixers (ToolkitInitialized), before any window.
    browser_engine::InstallPaletteMixer();

    // AppController's keep-alive: on the Mac the browser keeps running with
    // no windows open, until the user quits.
    keep_alive_ = std::make_unique<ScopedKeepAlive>(
        KeepAliveOrigin::APP_CONTROLLER, KeepAliveRestartOption::DISABLED);

    // chrome::HandleAppExitingForPlatform() posts this once the last browser
    // is gone (application_lifetime_mac.mm). AppController lets go of its
    // keep-alive then (-applicationWillTerminate:), so the main loop ends
    // and ChromeMain() returns. The app's delegate hears it too.
    will_terminate_observer_ = [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationWillTerminateNotification
                    object:NSApp
                     queue:nil
                usingBlock:^(NSNotification* notification) {
                  OnWillTerminate();
                }];

    // Runs once the main loop runs, which is after startup (session restore,
    // the first window) is done: like AppController's _startupComplete.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce([] { [Engine() browserDidStart]; }));
  }

  base::WeakPtr<javascript_dialogs::TabModalDialogView> CreateJavaScriptDialog(
      content::WebContents* parent_web_contents,
      const std::u16string& title,
      int dialog_type,
      const std::u16string& message_text,
      const std::u16string& default_prompt_text,
      base::OnceCallback<void(bool, const std::u16string&)>& dialog_callback,
      base::OnceClosure& dialog_force_closed_callback) override {
    return browser_engine::CreateJavaScriptDialog(
        parent_web_contents, title, dialog_type, message_text,
        default_prompt_text, dialog_callback, dialog_force_closed_callback);
  }

  std::unique_ptr<LoginHandler> CreateLoginHandler(
      const net::AuthChallengeInfo& auth_info,
      content::WebContents* web_contents,
      base::OnceCallback<void(const std::optional<net::AuthCredentials>&)>&
          auth_required_callback) override {
    return browser_engine::CreateLoginHandler(auth_info, web_contents,
                                              auth_required_callback);
  }

  bool ShowProfilePicker(int entry_point) override {
    return [Engine() showProfilePicker:entry_point];
  }

  bool RunExternalProtocolDialog(
      const GURL& url,
      content::WebContents* web_contents,
      const url::Origin* initiating_origin,
      const content::WeakDocumentPtr& initiator_document,
      const std::u16string& program_name) override {
    return browser_engine::RunExternalProtocolDialog(
        url, web_contents, initiating_origin, initiator_document,
        program_name);
  }

  void DidEndMainMessageLoop() override {
    // AppController's -didEndMainMessageLoop: with no browsers left, shut the
    // TabRestoreService down now so its NavigationControllers go before the
    // threads they use. UNVERIFIED: AppController uses the profile it last
    // saw active; the last used profile is our stand-in.
    Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
    if (!profile) {
      return;
    }
    ProfileBrowserCollection* collection =
        ProfileBrowserCollection::GetForProfile(profile);
    if (!collection || !collection->GetSize()) {
      TabRestoreServiceFactory::ResetForProfile(profile);
    }
  }

 private:
  void OnWillTerminate() {
    keep_alive_.reset();
    if (will_terminate_observer_) {
      [NSNotificationCenter.defaultCenter
          removeObserver:will_terminate_observer_];
      will_terminate_observer_ = nil;
    }
  }

  std::unique_ptr<ScopedKeepAlive> keep_alive_;
  id __strong will_terminate_observer_ = nil;
  BEDownloads downloads_;
};

EngineHooks& GetEngineHooks() {
  static base::NoDestructor<EngineHooks> hooks;
  return *hooks;
}

// What [super ...] runs for `selector` in NSApp's class, to override it with;
// null if the class implements `selector` itself.
IMP InheritedAppMethod(SEL selector) {
  Class app_class = [NSApp class];
  IMP inherited =
      class_getMethodImplementation(class_getSuperclass(app_class), selector);
  return class_getMethodImplementation(app_class, selector) == inherited
             ? inherited
             : nullptr;
}

// Adds `block` to NSApp's class as its own `selector`, which it inherits.
void OverrideAppMethod(SEL selector, id block) {
  Class app_class = [NSApp class];
  class_addMethod(app_class, selector, imp_implementationWithBlock(block),
                  method_getTypeEncoding(class_getInstanceMethod(
                      class_getSuperclass(app_class), selector)));
}

// Chromium sends NSApp a few messages beyond CrAppProtocol, which its own
// BrowserCrApplication answers. The engine answers them for the app's
// NSApplication, adding the methods at runtime, because only Chromium's side
// can act on them:
// - content's responsiveness watcher registers with NSApp as a
//   NativeEventProcessor at startup (native_event_observer_mac.mm). The
//   stand-in ignores the observer (Chrome's jank metrics only).
// - chrome_browser_application_mac::CancelTerminate() sends -cancelTerminate:
//   when the user stays on a page during quit; the stand-in does what
//   AppController's -stopTryingToTerminateApplication does.
// - Assistive technology, and content's VoiceOver KVO, reach NSApp through
//   three NSApplication methods, which BrowserCrApplication overrides to turn
//   Chrome's accessibility on (BEAppAccessibility). The overrides call
//   NSApplication's own, as [super ...] would.
// An app that implements them itself keeps its own.
void AddMissingAppMethods() {
  Class app_class = [NSApp class];
  if (![NSApp respondsToSelector:@selector(addNativeEventProcessorObserver:)]) {
    class_addMethod(app_class, @selector(addNativeEventProcessorObserver:),
                    imp_implementationWithBlock(^(id app, void* observer){}),
                    "v@:^v");
    class_addMethod(app_class, @selector(removeNativeEventProcessorObserver:),
                    imp_implementationWithBlock(^(id app, void* observer){}),
                    "v@:^v");
    class_addProtocol(app_class, @protocol(NativeEventProcessor));
  }
  if (![NSApp respondsToSelector:@selector(cancelTerminate:)]) {
    class_addMethod(app_class, @selector(cancelTerminate:),
                    imp_implementationWithBlock(^(id app, id sender) {
                      if (browser_shutdown::IsTryingToQuit()) {
                        browser_shutdown::SetTryingToQuit(false);
                      }
                    }),
                    "v@:@");
  }

  BEAppAccessibility* accessibility = [[BEAppAccessibility alloc] init];
  SEL set_value = @selector(accessibilitySetValue:forAttribute:);
  if (IMP inherited = InheritedAppMethod(set_value)) {
    auto* super_set_value =
        reinterpret_cast<void (*)(id, SEL, id, NSString*)>(inherited);
    OverrideAppMethod(set_value, ^(id app, id value, NSString* attribute) {
      // Undocumented, and set when VoiceOver goes on or off. VoiceOver is
      // followed through KVO (below), but other assistive technology may set
      // it to ask for accessibility.
      if ([attribute isEqualToString:@"AXEnhancedUserInterface"]) {
        [accessibility
            enableScreenReaderCompleteModeAfterDelay:[value boolValue]];
      }
      super_set_value(app, set_value, value, attribute);
    });
  }
  SEL role = @selector(accessibilityRole);
  if (IMP inherited = InheritedAppMethod(role)) {
    auto* super_role =
        reinterpret_cast<NSAccessibilityRole (*)(id, SEL)>(inherited);
    OverrideAppMethod(role, ^NSAccessibilityRole(id app) {
      [accessibility accessibilityRoleRequested];
      return super_role(app, role);
    });
  }
  SEL observe = @selector(observeValueForKeyPath:ofObject:change:context:);
  if (IMP inherited = InheritedAppMethod(observe)) {
    auto* super_observe = reinterpret_cast<void (*)(
        id, SEL, NSString*, id, NSDictionary*, void*)>(inherited);
    OverrideAppMethod(observe, ^(id app, NSString* key_path, id object,
                                 NSDictionary* change, void* context) {
      // The context is the BrowserAccessibilityState that set this up, as
      // opposed to observations of the app's own.
      if ([key_path isEqualToString:@"voiceOverEnabled"] &&
          context == content::BrowserAccessibilityState::GetInstance()) {
        NSNumber* enabled =
            base::apple::ObjCCast<NSNumber>(change[NSKeyValueChangeNewKey]);
        if (enabled) {
          [accessibility voiceOverStateChanged:enabled.boolValue];
        }
        return;
      }
      super_observe(app, observe, key_path, object, change, context);
    });
  }
}

// The --user-data-dir the app passed, if any.
base::FilePath UserDataDirFromArguments(NSArray<NSString*>* arguments) {
  NSString* prefix =
      [NSString stringWithFormat:@"--%s=", switches::kUserDataDir];
  for (NSString* argument in arguments) {
    if ([argument hasPrefix:prefix]) {
      return base::apple::NSStringToFilePath(
          [[argument substringFromIndex:prefix.length]
              stringByExpandingTildeInPath]);
    }
  }
  return base::FilePath();
}

// `watcher` watching `profile`, made on first use: the closed tabs, history
// or bookmarks the app's menus list. Null with no profile.
template <typename Watcher>
Watcher* Watch(std::unique_ptr<Watcher>& watcher, Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  if (!watcher) {
    watcher = std::make_unique<Watcher>();
  }
  watcher->ObserveProfile(profile);
  return watcher.get();
}

// The profile that addresses from other apps open in: the last active
// window's, regular rather than incognito (as AppController does).
Profile* ProfileForOpeningURLs() {
  BrowserWindowInterface* browser =
      GetLastActiveBrowserWindowInterfaceWithAnyProfile();
  Profile* profile = browser ? browser->GetProfile()
                             : ProfileManager::GetLastUsedProfileAllowedByPolicy();
  if (profile && profile->IsIncognitoProfile()) {
    profile = ProfileManager::MaybeForceOffTheRecordMode(
        profile->GetOriginalProfile());
  }
  return profile;
}

}  // namespace

id<BEEngineDelegate> GetEngineDelegate() {
  return Engine().delegate;
}

id<BEEngine> GetEngine() {
  return Engine();
}

void OnWindowActivated() {
  [Engine() windowDidBecomeActive];
}

}  // namespace browser_engine

@implementation BEChromiumEngine {
  id<BEEngineDelegate> _delegate;  // Strong while Chromium runs.
  NSArray<NSString*>* _arguments;
  BOOL _ran;
  BOOL _started;
  NSMutableArray<NSURL*>* _pendingURLs;
  BEChromiumPreferences* _preferences;
  std::unique_ptr<browser_engine::BERecentlyClosed> _recentlyClosed;
  std::unique_ptr<browser_engine::BERecentlyVisited> _recentlyVisited;
  std::unique_ptr<browser_engine::BEBookmarks> _bookmarks;
  std::unique_ptr<browser_engine::BEMostVisited> _mostVisited;
  std::unique_ptr<browser_engine::BEProfiles> _profiles;
}

- (instancetype)init {
  if ((self = [super init])) {
    _pendingURLs = [NSMutableArray array];
  }
  return self;
}

- (id<BEEngineDelegate>)delegate {
  return _delegate;
}

// The everyday profile (the one dataFolder is), whose closed tabs, history
// and bookmarks the app's menus list, once Chromium runs; null before, or
// with no profile.
- (Profile*)everydayProfile {
  return _started && g_browser_process
             ? ProfileManager::GetLastUsedProfileIfLoaded()
             : nullptr;
}

// MARK: BEEngine

- (NSInteger)apiVersion {
  return BE_API_VERSION;
}

- (NSString*)version {
  // "Chromium 156.0.8078.47".
  return base::SysUTF8ToNSString(base::StrCat(
      {version_info::GetProductName(), " ", version_info::GetVersionNumber()}));
}

- (NSURL*)dataFolder {
  base::FilePath profile_dir;
  if (_started && g_browser_process && g_browser_process->profile_manager()) {
    // The profile Chrome opens windows in (Local State's last used profile).
    profile_dir = g_browser_process->profile_manager()->GetLastUsedProfileDir();
  } else {
    // Before Chromium runs: the same folder, worked out the way Chrome will
    // (the app's Info.plist CrProductDirName, else "Chromium").
    base::FilePath user_data_dir = browser_engine::UserDataDirFromArguments(
        _arguments ?: NSProcessInfo.processInfo.arguments);
    if (user_data_dir.empty()) {
      chrome::GetDefaultUserDataDirectory(&user_data_dir);
    }
    profile_dir = user_data_dir.Append(chrome::kInitialProfile);
  }
  return base::apple::FilePathToNSURL(profile_dir);
}

- (NSArray<id<BEClosedItem>>*)recentlyClosed {
  browser_engine::BERecentlyClosed* recentlyClosed =
      browser_engine::Watch(_recentlyClosed, [self everydayProfile]);
  return recentlyClosed ? recentlyClosed->items() : @[];
}

- (NSArray<id<BEBookmark>>*)bookmarks {
  browser_engine::BEBookmarks* bookmarks =
      browser_engine::Watch(_bookmarks, [self everydayProfile]);
  return bookmarks ? bookmarks->items() : @[];
}

- (id<BEBookmark>)bookmarkBar {
  browser_engine::BEBookmarks* bookmarks =
      browser_engine::Watch(_bookmarks, [self everydayProfile]);
  return bookmarks ? bookmarks->bar() : nil;
}

- (id<BEBookmark>)otherBookmarks {
  browser_engine::BEBookmarks* bookmarks =
      browser_engine::Watch(_bookmarks, [self everydayProfile]);
  return bookmarks ? bookmarks->other() : nil;
}

- (NSArray<id<BEVisitedPage>>*)recentlyVisited {
  browser_engine::BERecentlyVisited* recentlyVisited =
      browser_engine::Watch(_recentlyVisited, [self everydayProfile]);
  return recentlyVisited ? recentlyVisited->items() : @[];
}

- (NSArray<id<BEVisitedPage>>*)mostVisited {
  browser_engine::BEMostVisited* mostVisited =
      browser_engine::Watch(_mostVisited, [self everydayProfile]);
  return mostVisited ? mostVisited->items() : @[];
}

- (NSArray<id<BEProfile>>*)profiles {
  return _profiles ? _profiles->items() : @[];
}

- (void)openWindowForProfile:(NSString*)identifier {
  const base::FilePath path =
      _profiles ? _profiles->PathForIdentifier(identifier) : base::FilePath();
  if (!path.empty()) {
    // As choosing a profile in Chrome's Profiles menu: a new window for it.
    profiles::SwitchToProfile(path, /*always_create=*/true);
  }
}

- (browser_engine::BEProfiles*)profilesModel {
  return _profiles.get();
}

- (BOOL)showProfilePicker:(int)entryPoint {
  id delegate = self.delegate;
  if (![delegate respondsToSelector:@selector(engine:showProfilePicker:)]) {
    return NO;
  }
  // Chrome keeps its own for what the app's doesn't do: first run, a locked
  // profile, and Google's own flows.
  using EntryPoint = ProfilePicker::EntryPoint;
  BEProfilePickerReason reason;
  switch (static_cast<EntryPoint>(entryPoint)) {
    case EntryPoint::kOnStartup:
    case EntryPoint::kOnStartupNoProfile:
    case EntryPoint::kNewSessionOnExistingProcess:
    case EntryPoint::kNewSessionOnExistingProcessNoProfile:
      reason = BEProfilePickerReasonStartup;
      break;
    case EntryPoint::kProfileMenuManageProfiles:
    case EntryPoint::kAppMenuProfileSubMenuManageProfiles:
      reason = BEProfilePickerReasonManage;
      break;
    case EntryPoint::kProfileMenuAddNewProfile:
    case EntryPoint::kAppMenuProfileSubMenuAddNewProfile:
      reason = BEProfilePickerReasonAdd;
      break;
    case EntryPoint::kOpenNewWindowAfterProfileDeletion:
      reason = BEProfilePickerReasonAfterDeletion;
      break;
    case EntryPoint::kUnableToCreateBrowser:
    case EntryPoint::kBackgroundModeManager:
    case EntryPoint::kProfileIdle:
      reason = BEProfilePickerReasonOther;
      break;
    default:
      return NO;
  }
  return [delegate engine:self showProfilePicker:reason];
}

- (void)showProfilePickerToAdd:(BOOL)add {
  if (!_started) {
    return;
  }
  ProfilePicker::Show(ProfilePicker::Params::FromEntryPoint(
      add ? ProfilePicker::EntryPoint::kProfileMenuAddNewProfile
          : ProfilePicker::EntryPoint::kProfileMenuManageProfiles));
}

- (void)setMostVisitedURL:(NSURL*)url removed:(BOOL)removed {
  if (browser_engine::BEMostVisited* mostVisited =
          browser_engine::Watch(_mostVisited, [self everydayProfile])) {
    mostVisited->SetRemoved(net::GURLWithNSURL(url), removed);
  }
}

// BEEnginePalette.
- (void)setPalette:(NSDictionary<NSString*, NSColor*>*)palette {
  browser_engine::SetPalette(palette);
}

- (id<BEPreferences>)preferences {
  if (!_started) {
    return nil;
  }
  if (!_preferences) {
    _preferences = [[BEChromiumPreferences alloc] init];
  }
  return _preferences;
}

- (int)runWithArguments:(NSArray<NSString*>*)arguments
               delegate:(id<BEEngineDelegate>)delegate {
  CHECK(NSThread.isMainThread);
  CHECK(!_ran) << "Chromium runs once per process";
  // Chromium's message pump checks these too (base::message_pump_apple::
  // UsingCrApp()); say what's wrong before it does.
  CHECK(NSApp && [NSApp respondsToSelector:@selector(isHandlingSendEvent)] &&
        [NSApp respondsToSelector:@selector(setHandlingSendEvent:)])
      << "NSApp must exist and adopt CrAppProtocol and CrAppControlProtocol "
         "before Chromium runs";
  browser_engine::AddMissingAppMethods();

  _ran = YES;
  _delegate = delegate;
  _arguments = [arguments copy];
  browser_engine::SetHooks(&browser_engine::GetEngineHooks());

  // argv[0] is the app's executable. Chrome finds its framework, helpers and
  // resources from the executable's bundle (chrome::GetFrameworkBundlePath()),
  // so the framework must sit in the app's Contents/Frameworks.
  NSString* executable = NSBundle.mainBundle.executablePath
                             ?: NSProcessInfo.processInfo.arguments.firstObject;
  std::vector<std::string> args;
  args.push_back(base::SysNSStringToUTF8(executable));
  for (NSString* argument in arguments) {
    args.push_back(base::SysNSStringToUTF8(argument));
  }
  std::vector<const char*> argv;
  for (const std::string& arg : args) {
    argv.push_back(arg.c_str());
  }
  argv.push_back(nullptr);

  const int result = ChromeMain(static_cast<int>(args.size()), argv.data());

  _started = NO;
  _delegate = nil;
  return result;
}

- (void)openWindowPrivate:(BOOL)isPrivate {
  if (!_started) {
    return;  // Startup opens the first window itself.
  }
  BrowserWindowInterface* browser =
      GetLastActiveBrowserWindowInterfaceWithAnyProfile();
  if (browser &&
      browser->GetType() == BrowserWindowInterface::Type::TYPE_NORMAL) {
    // Chrome's own ⌘N / ⇧⌘N.
    chrome::ExecuteCommand(
        browser, isPrivate ? IDC_NEW_INCOGNITO_WINDOW : IDC_NEW_WINDOW);
    return;
  }
  Profile* profile = browser
                         ? browser->GetProfile()->GetOriginalProfile()
                         : ProfileManager::GetLastUsedProfileAllowedByPolicy();
  if (!profile) {
    return;
  }
  if (isPrivate) {
    chrome::NewIncognitoWindow(profile);
  } else {
    chrome::NewEmptyWindow(profile, /*should_trigger_session_restore=*/false);
  }
}

- (void)openURLs:(NSArray<NSURL*>*)urls {
  if (!_started) {
    // Launch Services delivers a launching URL while NSApp finishes
    // launching, which may be before startup is done (AppController keeps
    // them in _startupTabs the same way).
    [_pendingURLs addObjectsFromArray:urls];
    return;
  }
  Profile* profile = browser_engine::ProfileForOpeningURLs();
  if (!profile) {
    return;
  }
  // The last active normal window of the profile, or a new one. Chrome's
  // navigator makes the window when `browser` is null.
  ProfileBrowserCollection* collection =
      ProfileBrowserCollection::GetForProfile(profile);
  BrowserWindowInterface* browser =
      collection ? collection->FindTabbedBrowser() : nullptr;
  bool first = true;
  for (NSURL* url in urls) {
    const GURL gurl = net::GURLWithNSURL(url);
    if (!gurl.is_valid()) {
      continue;
    }
    NavigateParams params(profile, gurl, ui::PAGE_TRANSITION_AUTO_TOPLEVEL);
    params.browser = browser;
    params.disposition = first ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                               : WindowOpenDisposition::NEW_BACKGROUND_TAB;
    params.window_action = NavigateParams::WindowAction::kShowWindow;
    Navigate(&params);
    // The rest go to the window the first one went to.
    browser = params.browser;
    first = false;
  }
}

- (void)quit {
  if (!_started) {
    return;
  }
  // AppController's -tryToTerminateApplication, without its confirm-to-quit
  // panel, in-progress-downloads alert and "quit with apps" check (milestone
  // 2). BrowserCloseManager runs beforeunload in every window first; if a
  // page keeps the user, quitting stops. Never [NSApp terminate:]: the app
  // routes that here.
  if (browser_shutdown::IsTryingToQuit()) {
    return;
  }
  chrome::OnClosingAllBrowsers(true);
  chrome::CloseAllBrowsersAndQuit();
}

// MARK: From the hooks

- (void)browserDidStart {
  _started = YES;
  // Chrome's History and Bookmarks menus watch from startup
  // (HistoryMenuBridge, BookmarkMenuBridge), which loads the last session's
  // closed tabs and windows, asks history for the pages visited last and
  // loads the bookmarks: the lists, and the history menu's icons, are ready
  // when the app's menus first open.
  Profile* profile = [self everydayProfile];
  browser_engine::Watch(_recentlyClosed, profile);
  browser_engine::Watch(_recentlyVisited, profile);
  browser_engine::Watch(_bookmarks, profile);
  // As the new tab page's tiles, ready when the app first shows one.
  browser_engine::Watch(_mostVisited, profile);
  _profiles = std::make_unique<browser_engine::BEProfiles>();
  _profiles->Start();
  if (_pendingURLs.count) {
    NSArray<NSURL*>* urls = [_pendingURLs copy];
    [_pendingURLs removeAllObjects];
    [self openURLs:urls];
  }
}

- (void)windowDidBecomeActive {
  if (!_started) {
    return;
  }
  // On a later task, after Chrome made the window's profile the last used
  // (ProfileManager's BrowserCollectionObserver): the lists of another
  // profile's window are its own, and each tells the app if it changed.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce([] {
        BEChromiumEngine* engine = browser_engine::Engine();
        Profile* profile = [engine everydayProfile];
        browser_engine::Watch(engine->_recentlyClosed, profile);
        browser_engine::Watch(engine->_recentlyVisited, profile);
        browser_engine::Watch(engine->_bookmarks, profile);
        browser_engine::Watch(engine->_mostVisited, profile);
      }));
}

@end

@implementation BEAppAccessibility {
  // A counter for enhanced user interface enable (+1) and disable (-1)
  // requests.
  int _AXEnhancedUserInterfaceRequests;
  BOOL _voiceOverEnabled;
  std::unique_ptr<content::ScopedAccessibilityMode> _scopedModeVoiceOver;
  std::unique_ptr<content::ScopedAccessibilityMode> _scopedModeGeneral;
}

- (void)enableScreenReaderCompleteMode:(BOOL)enable {
  if (enable) {
    if (!_scopedModeVoiceOver) {
      _scopedModeVoiceOver =
          content::BrowserAccessibilityState::GetInstance()
              ->CreateScopedModeForProcess(ui::kAXModeComplete |
                                           ui::AXMode::kFromPlatform |
                                           ui::AXMode::kScreenReader);
    }
  } else {
    _scopedModeVoiceOver.reset();
  }
}

// For -performSelector:withObject:afterDelay:, which can't pass a BOOL.
- (void)enableScreenReaderCompleteMode {
  _AXEnhancedUserInterfaceRequests = 0;
  [self enableScreenReaderCompleteMode:YES];
}

- (void)voiceOverStateChanged:(BOOL)voiceOverEnabled {
  _voiceOverEnabled = voiceOverEnabled;
  [self enableScreenReaderCompleteMode:voiceOverEnabled];
}

- (void)enableScreenReaderCompleteModeAfterDelay:(BOOL)enable {
  // VoiceOver, once on, overrides other assistive technology.
  if (_voiceOverEnabled) {
    return;
  }
  // Disabling with no enable request seen: disable now.
  if (!enable && _AXEnhancedUserInterfaceRequests == 0) {
    [self enableScreenReaderCompleteMode:NO];
    return;
  }
  if (enable) {
    _AXEnhancedUserInterfaceRequests++;
  } else {
    _AXEnhancedUserInterfaceRequests--;
  }
  DCHECK(_AXEnhancedUserInterfaceRequests >= 0);
  // Since macOS Sonoma, AXEnhancedUserInterface sometimes flips on and off
  // quickly: enable only once requests have stopped for two seconds.
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector
                                           (enableScreenReaderCompleteMode)
                                             object:nil];
  if (_AXEnhancedUserInterfaceRequests > 0) {
    const float kTwoSecondDelay = 2.0;
    [self performSelector:@selector(enableScreenReaderCompleteMode)
               withObject:nil
               afterDelay:kTwoSecondDelay];
  }
}

- (void)accessibilityRoleRequested {
  // Apple's advice for assistive technology other than VoiceOver (Voice
  // Control): turn accessibility on when it reads the app's role. That's
  // often, so only while accessibility is off.
  if (_scopedModeGeneral || _scopedModeVoiceOver) {
    return;
  }
  // Chrome reads this in -finishLaunching; it can't change, and the feature
  // list is ready long before assistive technology can ask.
  const bool sonoma_refinements =
      base::mac::MacOSVersion() >= 14'00'00 &&
      base::FeatureList::IsEnabled(
          features::kSonomaAccessibilityActivationRefinements);
  const ui::AXMode target_mode =
      sonoma_refinements ? ui::AXMode::kNativeAPIs : ui::kAXModeBasic;
  _scopedModeGeneral =
      content::BrowserAccessibilityState::GetInstance()
          ->CreateScopedModeForProcess(target_mode | ui::AXMode::kFromPlatform);
}

@end

id<BEEngine> BEEngineCreate(NSInteger apiVersion) {
  if (apiVersion != BE_API_VERSION) {
    return nil;
  }
  return browser_engine::Engine();
}
