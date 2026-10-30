// The interface between the browser app (Swift) and our Chromium build (the `//browser_engine`
// layer in MathiasWP/browser-engine). Both sides build against this file; nothing else crosses.
//
// Chromium keeps Chrome's browser layer: it decides when windows and tabs exist (startup and
// session restore, ⌘N, a page's window.open, chrome.windows.create) and runs them. The app draws
// them. Commands go in as method calls; what happened comes out through the delegates. Only plain
// values and the page's NSView cross, so the same interface could later sit in front of Chromium
// running in another process.
//
// Everything is called on the main thread (NS_SWIFT_UI_ACTOR: Swift sees it as main-actor code). The app loads the framework at runtime and gets the
// engine from `BEEngineCreate`, so it builds and runs its tests without the framework present.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Raised when either side changes this file in a way the other must follow.
#define BE_API_VERSION 1

@protocol BEWindow;
@protocol BETab;

/// Browser commands, run the way Chrome runs them (so ⌘-click and keyboard modifiers, tab
/// restore and extensions all see them). The engine maps them to Chrome's command ids.
typedef NS_ENUM(NSInteger, BECommand) {
    BECommandNewTab,
    BECommandNewWindow,
    BECommandNewPrivateWindow,
    BECommandCloseTab,
    BECommandCloseWindow,
    BECommandReopenClosedTab,
    BECommandBack,
    BECommandForward,
    BECommandReload,
    BECommandStop,
    BECommandSelectNextTab,
    BECommandSelectPreviousTab,
    BECommandFocusLocation,
    BECommandFind,
    BECommandFindNext,
    BECommandFindPrevious,
};

/// How a page's connection reads in the address bar. (Chrome: `security_state::SecurityLevel`)
typedef NS_ENUM(NSInteger, BESecurity) {
    BESecurityNone,
    BESecuritySecure,
    BESecurityWarning,
    BESecurityDangerous,
};

// MARK: Engine

/// What the engine tells the app.
NS_SWIFT_UI_ACTOR
@protocol BEEngineDelegate <NSObject>
/// Chromium made a browser window: at startup, for ⌘N, for a page or an extension. The app fills
/// the window with its own views and keeps it until `windowWillClose:`.
- (void)engineDidCreateWindow:(id<BEWindow>)window;
@end

NS_SWIFT_UI_ACTOR
@protocol BEEngine <NSObject>
@property (nonatomic, readonly) NSInteger apiVersion;
/// "Chromium 156.0.8078.47".
@property (nonatomic, readonly, copy) NSString *version;
/// Where the everyday profile keeps its data.
@property (nonatomic, readonly, copy) NSURL *dataFolder;

/// Starts Chromium and runs the app until it quits; returns the exit code. NSApp must already be
/// an `NSApplication` that adopts Chromium's `CrAppProtocol` and `CrAppControlProtocol`
/// (`isHandlingSendEvent`, `setHandlingSendEvent:`). `arguments` are Chromium switches, such as
/// `--user-data-dir=…` for a separate development copy.
- (int)runWithArguments:(NSArray<NSString *> *)arguments delegate:(id<BEEngineDelegate>)delegate;

/// Opens a new window with one tab, as ⌘N or ⇧⌘N do.
- (void)openWindowPrivate:(BOOL)isPrivate;
/// Addresses from other apps (Launch Services), opened as Chrome opens them: in the last active
/// window, or a new one.
- (void)openURLs:(NSArray<NSURL *> *)urls;
/// Quits as ⌘Q does in Chrome: pages may ask to stay, then every window closes, the session and
/// profile are saved, and `runWithArguments:delegate:` returns.
- (void)quit;
@end

// MARK: Windows

/// What a window tells the app. Indexes are positions in the window's tab strip.
NS_SWIFT_UI_ACTOR
@protocol BEWindowDelegate <NSObject>
- (void)window:(id<BEWindow>)window didInsertTab:(id<BETab>)tab atIndex:(NSInteger)index;
- (void)window:(id<BEWindow>)window didRemoveTab:(id<BETab>)tab atIndex:(NSInteger)index;
- (void)window:(id<BEWindow>)window didMoveTab:(id<BETab>)tab fromIndex:(NSInteger)from toIndex:(NSInteger)to;
/// The selected tab changed. The app shows its view in the page area.
- (void)window:(id<BEWindow>)window didActivateTab:(id<BETab>)tab;
/// Chrome asks for the address field to take focus (⌘L, a new tab), selecting all of it.
- (void)windowWantsLocationFocus:(id<BEWindow>)window;
/// The window is closing; the app lets go of it and its views.
- (void)windowWillClose:(id<BEWindow>)window;
@end

NS_SWIFT_UI_ACTOR
@protocol BEWindow <NSObject>
@property (nonatomic, weak, nullable) id<BEWindowDelegate> delegate;
/// The window Chromium made. The app puts its views in it with `setContentView:` and may style
/// it (title bar, button positions), but Chromium owns it.
@property (nonatomic, readonly) NSWindow *nativeWindow;
/// The app's root view, filling the window. Pages go inside it, wherever the app puts them.
- (void)setContentView:(NSView *)view;
@property (nonatomic, readonly) BOOL isPrivate;
@property (nonatomic, readonly, copy) NSArray<id<BETab>> *tabs;
/// -1 while the window has no tabs.
@property (nonatomic, readonly) NSInteger activeIndex;

- (void)runCommand:(BECommand)command;
- (BOOL)canRunCommand:(BECommand)command;
- (void)activateTabAtIndex:(NSInteger)index;
- (void)moveTabAtIndex:(NSInteger)from toIndex:(NSInteger)to;
- (void)closeTabAtIndex:(NSInteger)index;
/// Opens `url` in a new tab after the active one.
- (void)openURL:(NSURL *)url inBackground:(BOOL)inBackground;
@end

// MARK: Tabs

NS_SWIFT_UI_ACTOR
@protocol BETabDelegate <NSObject>
/// Anything in the tab's state changed: address, title, loading, progress, history, security,
/// crash, favicon. The app reads what it shows.
- (void)tabDidUpdate:(id<BETab>)tab;
@end

NS_SWIFT_UI_ACTOR
@protocol BETab <NSObject>
@property (nonatomic, weak, nullable) id<BETabDelegate> delegate;
/// Stable for the tab's life. (Chrome: `tabs::TabHandle`)
@property (nonatomic, readonly) int32_t identifier;
/// The page. The app adds it to its page area while the tab is selected, and removes it when
/// another tab is.
@property (nonatomic, readonly) NSView *view;

@property (nonatomic, readonly, copy, nullable) NSURL *url;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) BOOL isLoading;
/// 0 to 1.
@property (nonatomic, readonly) double progress;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BESecurity security;
/// The page's process died while showing it.
@property (nonatomic, readonly) BOOL isCrashed;
/// Asleep to save memory; it reloads when selected. (Chrome: discarded)
@property (nonatomic, readonly) BOOL isDiscarded;
@property (nonatomic, readonly, nullable) NSImage *favicon;

/// What the user typed or picked in the address field.
- (void)loadURL:(NSURL *)url;
/// Gives the page keyboard focus.
- (void)focusPage;
@end

/// The framework's one exported function. Returns nil if it was built for another API version.
typedef id<BEEngine> _Nullable (*BEEngineCreateFunction)(NSInteger apiVersion);
#define BE_ENGINE_CREATE_SYMBOL "BEEngineCreate"

NS_ASSUME_NONNULL_END
