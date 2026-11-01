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
#define BE_API_VERSION 9

@protocol BEWindow;
@protocol BETab;
@protocol BEPreferences;
@protocol BESuggestion;
@protocol BEDownload;
@protocol BEPasswordOffer;
@protocol BEExtensionAction;
@protocol BEClosedItem;
@protocol BESiteSetting;

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
    // Version 2.
    BECommandReloadBypassingCache,
    BECommandZoomIn,
    BECommandZoomOut,
    BECommandZoomReset,
    BECommandPrint,
    BECommandSavePage,
    BECommandOpenFile,
    BECommandViewSource,
    /// Opens or closes DevTools for the page, docked where it was last.
    BECommandDevTools,
    BECommandDevToolsConsole,
    BECommandDevToolsInspect,
    BECommandShowHistory,
    BECommandShowDownloads,
    BECommandBookmarkPage,
    BECommandShowBookmarks,
    BECommandClearBrowsingData,
    BECommandDuplicateTab,
    BECommandTaskManager,
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
/// A download started or changed: progress, a new name, finished, failed. For downloads in any
/// window, private ones included. (Version 3.)
- (void)engineDidUpdateDownload:(id<BEDownload>)download;
@end

NS_SWIFT_UI_ACTOR
@protocol BEEngine <NSObject>
@property (nonatomic, readonly) NSInteger apiVersion;
/// "Chromium 156.0.8078.47".
@property (nonatomic, readonly, copy) NSString *version;
/// Where the everyday profile keeps its data.
@property (nonatomic, readonly, copy) NSURL *dataFolder;
/// Tabs and windows closed recently, newest first, as Chrome's History menu lists them (the
/// everyday profile's). Read it when the menu opens. (Version 8.)
@property (nonatomic, readonly, copy) NSArray<id<BEClosedItem>> *recentlyClosed;
/// The everyday profile's preferences; nil until Chromium has started.
@property (nonatomic, readonly, nullable) id<BEPreferences> preferences;

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

// MARK: Preferences

/// Chrome's preferences (`PrefService`), by name ("intl.accept_languages"). A name the profile
/// doesn't have is looked up in Chrome's Local State, its browser-wide preferences
/// ("dns_over_https.mode"). Values are what `base::Value` holds: @YES and @NO, other NSNumbers
/// (whole or not), NSString, and NSArray and NSDictionary of these.
NS_SWIFT_UI_ACTOR
@protocol BEPreferences <NSObject>
/// The current value, or nil if no preference has that name.
- (nullable id)valueForPreference:(NSString *)name;
/// Whether the user changed it from its default.
- (BOOL)isPreferenceModified:(NSString *)name;
/// Whether it exists and the user may change it: not when policy or the command line fixes it.
- (BOOL)canSetPreference:(NSString *)name;
/// Sets the value; nil puts back the default. Refuses, saying why, for an unknown name, a
/// preference the user can't change, or a value of the wrong type.
- (BOOL)setValue:(nullable id)value forPreference:(NSString *)name error:(NSError **)error;
@end

// MARK: Address bar

/// What a suggestion is. (Chrome: `AutocompleteMatchType`, grouped)
typedef NS_ENUM(NSInteger, BESuggestionKind) {
    /// The address as typed.
    BESuggestionKindAddress,
    /// A page visited before.
    BESuggestionKindHistory,
    BESuggestionKindBookmark,
    /// A search with the default search engine.
    BESuggestionKindSearch,
    /// An open tab to switch to.
    BESuggestionKindOpenTab,
};

/// One address-bar suggestion. (Chrome: `AutocompleteMatch`)
NS_SWIFT_UI_ACTOR
@protocol BESuggestion <NSObject>
@property (nonatomic, readonly) BESuggestionKind kind;
/// What it reads as: the address, or the search terms.
@property (nonatomic, readonly, copy) NSString *text;
/// What goes beside it: the page's title, or which engine searches.
@property (nonatomic, readonly, copy) NSString *detail;
/// Where choosing it goes.
@property (nonatomic, readonly, copy) NSURL *url;
/// Completes what was typed, selected after the cursor; empty for none. Only the first
/// suggestion has one.
@property (nonatomic, readonly, copy) NSString *inlineCompletion;
@end

// MARK: Downloads

/// Where a download is. (Chrome: `download::DownloadItem::DownloadState`)
typedef NS_ENUM(NSInteger, BEDownloadState) {
    BEDownloadStateInProgress,
    BEDownloadStateComplete,
    BEDownloadStateCancelled,
    /// Failed (network, disk); Chrome may resume it.
    BEDownloadStateInterrupted,
};

/// A file Chrome is saving or has saved. (Chrome: `download::DownloadItem`)
NS_SWIFT_UI_ACTOR
@protocol BEDownload <NSObject>
/// Stable for the download's life.
@property (nonatomic, readonly) uint32_t identifier;
/// Whether a private window's profile downloads it.
@property (nonatomic, readonly) BOOL isPrivate;
@property (nonatomic, readonly, copy, nullable) NSURL *sourceURL;
/// Where the file goes. Nil until Chrome has picked the name; final once complete.
@property (nonatomic, readonly, copy, nullable) NSURL *fileURL;
@property (nonatomic, readonly) int64_t receivedBytes;
/// -1 while the size isn't known.
@property (nonatomic, readonly) int64_t totalBytes;
@property (nonatomic, readonly) BEDownloadState state;
/// Chrome holds the file back until the user keeps it: dangerous, or fetched insecurely. Chrome's
/// reason, in its words, is in `warning`.
@property (nonatomic, readonly) BOOL needsApproval;
@property (nonatomic, readonly, copy) NSString *warning;
/// Keeps a held-back file. (Chrome: `ValidateDangerousDownload` / `ValidateInsecureDownload`)
- (void)approve;
/// Stops it, or discards a held-back file.
- (void)cancel;
@end

// MARK: Passwords

/// Chrome offers to save a password the page just signed in with, or to update a saved one.
/// (Chrome: `ManagePasswordsUIController`, its save and update bubbles)
NS_SWIFT_UI_ACTOR
@protocol BEPasswordOffer <NSObject>
/// Updating a saved password rather than saving a new one.
@property (nonatomic, readonly) BOOL isUpdate;
/// The site, as Chrome shows it ("example.com").
@property (nonatomic, readonly, copy) NSString *site;
/// Empty when the form had none.
@property (nonatomic, readonly, copy) NSString *username;
- (void)save;
/// Never offers again for this site. (Not offered for updates.)
- (void)neverForThisSite;
/// Not now.
- (void)dismiss;
@end

// MARK: Extensions

/// An extension's button, as Chrome's toolbar shows it for the window's active tab. (Chrome:
/// `ToolbarActionViewModel`. Version 8.)
NS_SWIFT_UI_ACTOR
@protocol BEExtensionAction <NSObject>
/// The extension's id; stable.
@property (nonatomic, readonly, copy) NSString *identifier;
/// What the button says on hover: the extension's name, or its title for this tab.
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, nullable) NSImage *icon;
/// A few characters over the icon (a count); empty for none.
@property (nonatomic, readonly, copy) NSString *badgeText;
@property (nonatomic, readonly, nullable) NSColor *badgeColor;
/// Whether it does anything on this tab.
@property (nonatomic, readonly) BOOL isEnabled;
@end

// MARK: Recently closed

/// A tab, window or tab group closed earlier, as Chrome keeps them for ⇧⌘T. (Chrome:
/// `sessions::TabRestoreService::Entry`. Version 8.)
NS_SWIFT_UI_ACTOR
@protocol BEClosedItem <NSObject>
/// Stable while the item is in the list.
@property (nonatomic, readonly) int32_t identifier;
@property (nonatomic, readonly) BOOL isWindow;
/// The tab's title, or what Chrome's menu calls a window or group ("3 Tabs").
@property (nonatomic, readonly, copy) NSString *title;
/// A tab's address; nil for a window or group.
@property (nonatomic, readonly, copy, nullable) NSURL *url;
@property (nonatomic, readonly, nullable) NSImage *favicon;
@end

// MARK: Site settings

/// Something the page was allowed, or kept from doing, as an icon in Chrome's address bar shows
/// it: pop-ups blocked, the camera or microphone in use, location used or blocked, and so on.
/// (Chrome: `ContentSettingImageModel`. Version 9.)
NS_SWIFT_UI_ACTOR
@protocol BESiteSetting <NSObject>
/// Which kind, stable: "popups", "redirects", "camera", "microphone", "camera-microphone",
/// "location", "downloads", "cookies", "javascript", "images", "sound", "clipboard", "sensors",
/// "midi", "protocol-handlers", "storage-access", "ads", "mixed-content", "notifications", or
/// another of Chrome's, named the same way.
@property (nonatomic, readonly, copy) NSString *identifier;
/// What Chrome says on hover ("Pop-ups blocked").
@property (nonatomic, readonly, copy) NSString *title;
/// Blocked (Chrome strikes its icon through), rather than allowed or in use.
@property (nonatomic, readonly) BOOL isBlocked;
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
/// Suggestions for the text last given to `suggestForText:allowsInlineCompletion:`, best first.
/// The first is what Return opens. Arrives several times as Chrome's sources answer.
- (void)window:(id<BEWindow>)window didUpdateSuggestions:(NSArray<id<BESuggestion>> *)suggestions;
/// The window is closing; the app lets go of it and its views.
- (void)windowWillClose:(id<BEWindow>)window;
/// A page took the whole window or gave it back: `isPageFullscreen` changed. (Version 5.)
- (void)windowDidChangePageFullscreen:(id<BEWindow>)window;
/// `offersRestoreAfterCrash` changed. (Version 6.)
- (void)windowDidChangeRestoreOffer:(id<BEWindow>)window;
/// Extensions were added, removed, pinned, or changed their buttons. (Version 8.)
- (void)windowDidUpdateExtensionActions:(id<BEWindow>)window;
/// `statusText` changed. (Version 8.)
- (void)windowDidChangeStatus:(id<BEWindow>)window;
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
/// A page has the whole window (a video's full screen, `Element.requestFullscreen()`), so the app
/// hides everything but the page. Escape or the page gives it back. (Chrome: tab fullscreen)
@property (nonatomic, readonly) BOOL isPageFullscreen;
/// The browser didn't quit properly last time, and Chrome offers to bring back what was open.
/// Until the user answers, Chrome keeps that session and saves no new one. (Chrome: the
/// session-crashed bubble. Version 6.)
@property (nonatomic, readonly) BOOL offersRestoreAfterCrash;
/// Brings back the windows and tabs that were open, as the bubble's Restore does.
- (void)restoreAfterCrash;
/// Lets the old session go, as closing the bubble does.
- (void)declineRestoreAfterCrash;

- (void)runCommand:(BECommand)command;
- (BOOL)canRunCommand:(BECommand)command;
- (void)activateTabAtIndex:(NSInteger)index;
- (void)moveTabAtIndex:(NSInteger)from toIndex:(NSInteger)to;
- (void)closeTabAtIndex:(NSInteger)index;
/// Opens `url` in a new tab after the active one.
- (void)openURL:(NSURL *)url inBackground:(BOOL)inBackground;

/// The extensions' buttons for the active tab, in Chrome's toolbar order: pinned ones first.
/// `windowDidUpdateExtensionActions:` says when they change. (Version 8.)
@property (nonatomic, readonly, copy) NSArray<id<BEExtensionAction>> *extensionActions;
/// Runs an extension's button as a click on Chrome's toolbar does: shows its popup, anchored
/// below `rect` (in the window's coordinates, from its bottom left), or runs its action.
- (void)runExtensionAction:(NSString *)identifier fromRect:(NSRect)rect;

/// Reopens a recently closed tab or window, in place of ⇧⌘T's choice. (Version 8.)
- (void)restoreClosedItem:(int32_t)identifier;

/// What Chrome's status bubble shows over the bottom of the page: the address of the link under
/// the pointer, or what a loading page waits for ("Waiting for example.com…"); empty for
/// nothing. `windowDidChangeStatus:` says when it changes. (Chrome: `StatusBubble`. Version 8.)
@property (nonatomic, readonly, copy) NSString *statusText;

/// Suggests for what's typed in the address field, as Chrome's omnibox does. No inline
/// completion right after the user deleted text.
- (void)suggestForText:(NSString *)text allowsInlineCompletion:(BOOL)allowsInlineCompletion;
/// The address field is done: stops suggesting and forgets the suggestions.
- (void)stopSuggesting;
/// Opens the suggestion at `index` of the last update as Chrome's omnibox does: in the active
/// tab, or a new foreground tab; an open-tab suggestion switches to that tab.
- (void)openSuggestionAtIndex:(NSInteger)index inNewTab:(BOOL)inNewTab;
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
/// DevTools docked to this tab, or nil. The app shows it filling the page area, with the page
/// on top of it at `pageFrameWithDevToolsInBounds:`. `tabDidUpdate:` says when it comes, goes or
/// asks for another layout.
@property (nonatomic, readonly, nullable) NSView *devToolsView;
/// Where the page goes when docked DevTools fills `bounds`, in the same coordinates.
/// (Chrome: `ApplyDevToolsContentsResizingStrategy`)
- (NSRect)pageFrameWithDevToolsInBounds:(NSRect)bounds;
/// Chrome's offer to save or update the password just used here, while it stands; nil otherwise.
/// `tabDidUpdate:` says when it comes and goes. (Version 4.)
@property (nonatomic, readonly, nullable) id<BEPasswordOffer> passwordOffer;

/// What the user typed or picked in the address field.
- (void)loadURL:(NSURL *)url;
/// Gives the page keyboard focus.
- (void)focusPage;
/// Shows Chrome's details for the page's site (connection, certificate, permissions, cookies),
/// as clicking the lock does. (Chrome: Page Info. Version 4.)
- (void)showSiteInfo;
/// Whether the page's address is bookmarked; `tabDidUpdate:` says when that changes, wherever
/// it changed (the star, ⌘D, the bookmark manager). (Version 7.)
@property (nonatomic, readonly) BOOL isBookmarked;
/// Bookmarks the page, as Chrome's star does (into the folder Chrome last used), or removes every
/// bookmark of its address. (Version 7.)
- (void)setBookmarked:(BOOL)bookmarked;
/// The page's zoom in percent, as Chrome's zoom bubble shows it; 100 at the default zoom, where
/// Chrome shows no zoom icon. `tabDidUpdate:` says when it changes. (Version 8.)
@property (nonatomic, readonly) NSInteger zoomPercent;
/// The page's site-setting icons, in Chrome's order; `tabDidUpdate:` says when they change.
/// (Version 9.)
@property (nonatomic, readonly, copy) NSArray<id<BESiteSetting>> *siteSettings;
/// Opens Chrome's bubble for one of them (allow this site's pop-ups, stop using the camera…),
/// anchored below `rect` (in the window's coordinates, from its bottom left), as a click on
/// Chrome's icon does. Does nothing for one the page doesn't show.
- (void)showSiteSetting:(NSString *)identifier fromRect:(NSRect)rect;
/// The page is playing sound, or did a moment ago, as Chrome's tab strip shows it; `tabDidUpdate:`
/// says when that changes. (Chrome: `RecentlyAudibleHelper`. Version 8.)
@property (nonatomic, readonly) BOOL isAudible;
/// Whether the tab's sound is off; `tabDidUpdate:` says when that changes.
@property (nonatomic, readonly) BOOL isMuted;
/// Turns the tab's sound off or on, as the tab strip's audio button does.
- (void)setMuted:(BOOL)muted;
@end

/// The framework's one exported function. Returns nil if it was built for another API version.
typedef id<BEEngine> _Nullable (*BEEngineCreateFunction)(NSInteger apiVersion);
#define BE_ENGINE_CREATE_SYMBOL "BEEngineCreate"

NS_ASSUME_NONNULL_END
