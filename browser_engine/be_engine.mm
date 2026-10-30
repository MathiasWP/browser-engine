#import "browser_engine/be_engine.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include <memory>
#include <string>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/check.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/strings/strcat.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "browser_engine/be_browser_window.h"
#include "browser_engine/browser_engine_hooks.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/sessions/tab_restore_service_factory.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "chrome/browser/ui/browser_window/public/profile_browser_collection.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/common/chrome_constants.h"
#include "chrome/common/chrome_paths_internal.h"
#include "chrome/common/chrome_switches.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/version_info/version_info.h"
#import "content/public/browser/native_event_processor_mac.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"

// The framework's own entry point, chrome/app/chrome_main.cc. No header
// declares it; chrome_exe_main_mac.cc finds it with dlsym().
extern "C" int ChromeMain(int argc, const char** argv);

@interface BEChromiumEngine : NSObject <BEEngine>
// The app's delegate while Chromium runs.
@property(nonatomic, readonly, nullable) id<BEEngineDelegate> delegate;
// From the hooks: the main loop runs and startup has made its windows.
- (void)browserDidStart;
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
      window->OnBrowserInitialized();
    }
  }

  views::Widget* GetWidgetForBrowser(BrowserWindowInterface* browser) override {
    BEBrowserWindow* window = BEBrowserWindow::FromBrowser(browser);
    return window ? window->widget() : nullptr;
  }

  void PreCreateThreads() override {
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
};

EngineHooks& GetEngineHooks() {
  static base::NoDestructor<EngineHooks> hooks;
  return *hooks;
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

}  // namespace browser_engine

@implementation BEChromiumEngine {
  id<BEEngineDelegate> _delegate;  // Strong while Chromium runs.
  NSArray<NSString*>* _arguments;
  BOOL _ran;
  BOOL _started;
  NSMutableArray<NSURL*>* _pendingURLs;
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
  if (_pendingURLs.count) {
    NSArray<NSURL*>* urls = [_pendingURLs copy];
    [_pendingURLs removeAllObjects];
    [self openURLs:urls];
  }
}

@end

id<BEEngine> BEEngineCreate(NSInteger apiVersion) {
  if (apiVersion != BE_API_VERSION) {
    return nil;
  }
  return browser_engine::Engine();
}
