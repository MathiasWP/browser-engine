// Optional additions to the interface in BEEngine.h: what an engine may offer, which the app uses
// only where it does (`respondsToSelector:`). An engine built before one was added just lacks it,
// so adding here leaves BE_API_VERSION and BEEngine.h alone, and the engines already built for
// them (the optimised one takes a day or two) still match the app. Keep the copies in the app
// (Sources/BrowserEngineAPI/include) and the engine (browser_engine/public) the same.

#import "BEEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// Where a page the app offers is about to be opened from, for preloading it as Chrome preloads
/// from its own bookmarks bar and New Tab page. (4 Nov 2026.)
typedef NS_ENUM(NSInteger, BEPreloadSource) {
    BEPreloadSourceBookmarkBar = 0,
    BEPreloadSourceNewTabPage = 1,
};

NS_SWIFT_UI_ACTOR
@protocol BEWindowPreloading <NSObject>
@optional
/// The pointer rests on a link to `url`: its site is connected to ahead of a click, as Chrome's
/// bookmark buttons do after 100 ms. (4 Nov 2026.)
- (void)preconnectToURL:(NSURL *)url from:(BEPreloadSource)source;
/// Pressed: `url` starts loading in a hidden page for the active tab, which the click then shows
/// at once, as Chrome's bookmark buttons and New Tab page tiles do on mouse-down; nil drops the one
/// started from `source`, as the pointer leaves. A bookmark then opens with `openBookmark:event:`,
/// a New Tab page link with `-[BETabPreloading loadURL:from:]`. (4 Nov 2026.)
- (void)prerenderURL:(nullable NSURL *)url from:(BEPreloadSource)source;
@end

/// A page saved to read later: Chrome's reading list, the window's profile's. (5 Nov 2026.)
NS_SWIFT_UI_ACTOR
@protocol BEReadingListItem <NSObject>
@property (nonatomic, readonly, copy) NSURL *url;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) BOOL isRead;
@property (nonatomic, readonly, copy) NSDate *added;
@end

NS_SWIFT_UI_ACTOR
@protocol BEWindowReadingList <NSObject>
@optional
/// The window's profile's reading list, newest first; empty until Chrome has loaded it (it's
/// read as a menu opens, so nothing is sent as it changes). Chrome's tab menu adds to it too.
@property (nonatomic, readonly, copy) NSArray<id<BEReadingListItem>> *readingListItems;
/// Whether `url` can go on the list (Chrome's: web pages).
- (BOOL)canAddToReadingList:(NSURL *)url;
- (void)addToReadingList:(NSURL *)url title:(NSString *)title;
- (void)setReadingListItem:(NSURL *)url read:(BOOL)read;
- (void)removeFromReadingList:(NSURL *)url;
@end

NS_SWIFT_UI_ACTOR
@protocol BEWindowOpening <NSObject>
@optional
/// Opens the suggestion at `index` of the last update in a new window, as ⇧Return does in
/// Chrome's omnibox. (5 Nov 2026.)
- (void)openSuggestionInNewWindowAtIndex:(NSInteger)index;
@end

NS_SWIFT_UI_ACTOR
@protocol BESuggestionKeyword <NSObject>
/// The site search Tab starts from this suggestion, as in Chrome's omnibox (its
/// `associated_keyword`): typing the keyword and a space searches the site. Empty for none.
/// (5 Nov 2026.)
@property (nonatomic, readonly, copy) NSString *keyword;
/// The site search's name ("Wikipedia").
@property (nonatomic, readonly, copy) NSString *keywordName;
@end

NS_SWIFT_UI_ACTOR
@protocol BEDownloadProfile <NSObject>
/// The profile that downloads it, as `BEWindow.profileIdentifier` names it (a private window's
/// downloads name the profile it's private from), so each profile's windows list their own.
/// (5 Nov 2026.)
@property (nonatomic, readonly, copy) NSString *profileIdentifier;
@end

NS_SWIFT_UI_ACTOR
@protocol BEDownloadControl <NSObject>
/// Paused by the user, until `resume`. (5 Nov 2026.)
@property (nonatomic, readonly) BOOL isPaused;
/// What Chrome's download bubble offers now: Pause while it runs, Resume while paused or
/// interrupted where Chrome can go on, Retry where it can't and fetches the file again.
@property (nonatomic, readonly) BOOL canPause;
@property (nonatomic, readonly) BOOL canResume;
@property (nonatomic, readonly) BOOL canRetry;
- (void)pause;
- (void)resume;
- (void)retry;
@end

NS_SWIFT_UI_ACTOR
@protocol BETabPreloading <NSObject>
@optional
/// Opens `url` as a link chosen from `source`: a bookmark navigation, as Chrome's New Tab page
/// tiles open, which a prerender made for it on mouse-down matches. (4 Nov 2026.)
- (void)loadURL:(NSURL *)url from:(BEPreloadSource)source;
/// While warm, the tab's page, hidden, keeps rendering, so choosing the tab shows a fresh frame at
/// once (Firefox's tab warming, for the pointer resting on a tab); the page still reads as hidden.
/// (5 Nov 2026.)
- (void)setWarm:(BOOL)warm;
@end

// MARK: Our own UI in place of Chrome's (8 Nov 2026, docs/native-ui.md in the app)

/// The colours the app draws with, for what Chrome still draws itself: its bubbles, dialogs and
/// chrome:// pages, in light and dark. Keys: accent, onAccent, accentContainer, onAccentContainer,
/// surface, raised, text, secondaryText, separator, outline, focusRing, selection; dynamic colours
/// are resolved in both appearances. May be called before the engine runs. (8 Nov 2026.)
NS_SWIFT_UI_ACTOR
@protocol BEEnginePalette <NSObject>
@optional
- (void)setPalette:(NSDictionary<NSString *, NSColor *> *)palette;
@end

/// Where a bookmark, a link or a page opens. (Chrome: `WindowOpenDisposition`.)
typedef NS_ENUM(NSInteger, BEOpenDisposition) {
    BEOpenDispositionCurrentTab = 0,
    BEOpenDispositionNewForegroundTab = 1,
    BEOpenDispositionNewBackgroundTab = 2,
    BEOpenDispositionNewWindow = 3,
    BEOpenDispositionPrivateWindow = 4,
};

/// What Chrome asks of a bookmark editor. (Chrome: `BookmarkEditor::EditDetails` and its bubble.)
typedef NS_ENUM(NSInteger, BEBookmarkEditKind) {
    /// The star or ⌘D: the page has just been bookmarked, or already was (name, folder, Remove).
    BEBookmarkEditKindBookmarked = 0,
    /// A bookmark's name, address and folder.
    BEBookmarkEditKindEdit = 1,
    /// A new bookmark in a folder ("Add Page…").
    BEBookmarkEditKindAddPage = 2,
    /// A new folder ("Add Folder…"; Bookmark All Tabs gives it `urls`).
    BEBookmarkEditKindAddFolder = 3,
    /// A folder's name.
    BEBookmarkEditKindEditFolder = 4,
};

NS_SWIFT_UI_ACTOR
@protocol BEBookmarkEditRequest <NSObject>
@property (nonatomic, readonly) BEBookmarkEditKind kind;
/// The bookmark or folder edited; 0 for a new one.
@property (nonatomic, readonly) int64_t bookmarkIdentifier;
/// The folder it's in, or the new one goes in.
@property (nonatomic, readonly) int64_t folderIdentifier;
/// Where in the folder a new one goes; -1 for the end.
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy, nullable) NSURL *url;
@property (nonatomic, readonly, copy) NSString *title;
/// The pages a new folder is made with (Bookmark All Tabs), with their titles; empty otherwise.
@property (nonatomic, readonly, copy) NSArray<NSURL *> *urls;
@property (nonatomic, readonly, copy) NSArray<NSString *> *urlTitles;
@end

/// Bookmarks as the app's own star popover, editor and menus change them, in the window's profile.
NS_SWIFT_UI_ACTOR
@protocol BEWindowBookmarkEditing <NSObject>
@optional
/// The folders bookmarks can go in: the bar's, Other Bookmarks', and Mobile Bookmarks' when it
/// has any, each with its folders inside (bookmarks aren't listed).
@property (nonatomic, readonly, copy) NSArray<id<BEBookmark>> *bookmarkFolders;
/// The folders bookmarks were put in lately, newest first (Chrome's star bubble offers them).
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *recentBookmarkFolders;
/// The bookmark for `url` added last; 0 if there's none.
- (int64_t)bookmarkIdentifierForURL:(NSURL *)url;
/// The folder a bookmark or folder is in; 0 if there's no such bookmark.
- (int64_t)folderOfBookmark:(int64_t)identifier;
/// Renames a bookmark or folder, gives a bookmark a new address (nil keeps it), and moves it to
/// the end of `folder` unless it's there already (0 keeps it where it is).
- (void)editBookmark:(int64_t)identifier title:(NSString *)title url:(nullable NSURL *)url folder:(int64_t)folder;
/// A new folder in `folder` at `index` (-1: the end); its id, 0 if it couldn't be made.
- (int64_t)addBookmarkFolder:(NSString *)title toFolder:(int64_t)folder atIndex:(NSInteger)index;
- (void)removeBookmark:(int64_t)identifier;
/// Opens a bookmark, or every bookmark in a folder, there.
- (void)openBookmark:(int64_t)identifier disposition:(BEOpenDisposition)disposition;
@end

/// A tab's commands, as Chrome's tab menu runs them. (Chrome: `TabStripModel::ContextMenuCommand`.)
typedef NS_ENUM(NSInteger, BETabCommand) {
    BETabCommandNewTabToRight = 0,
    BETabCommandReload = 1,
    BETabCommandDuplicate = 2,
    BETabCommandTogglePinned = 3,
    BETabCommandToggleSiteMuted = 4,
    BETabCommandAddToNewGroup = 5,
    BETabCommandRemoveFromGroup = 6,
    BETabCommandClose = 7,
    BETabCommandCloseOthers = 8,
    BETabCommandCloseToRight = 9,
    BETabCommandMoveToNewWindow = 10,
    BETabCommandAddToReadingList = 11,
};

/// The tab menu and the tab group editor, drawn by the app.
NS_SWIFT_UI_ACTOR
@protocol BEWindowTabCommands <NSObject>
@optional
- (BOOL)canRunTabCommand:(BETabCommand)command atIndex:(NSInteger)index;
/// For the tab at `index`; pinning, muting and grouping act on it alone.
- (void)runTabCommand:(BETabCommand)command atIndex:(NSInteger)index;
/// Adds the tab at `index` to one of this window's groups.
- (void)addTabAtIndex:(NSInteger)index toTabGroup:(NSString *)group;
- (void)setTabGroup:(NSString *)group title:(NSString *)title color:(BETabGroupColor)color;
/// Its tabs stay, out of the group.
- (void)ungroupTabGroup:(NSString *)group;
- (void)closeTabGroup:(NSString *)group;
/// A new tab at the group's end, selected.
- (void)addTabToTabGroup:(NSString *)group;
/// Only when the group isn't every tab in the window.
- (BOOL)canMoveTabGroupToNewWindow:(NSString *)group;
- (void)moveTabGroupToNewWindow:(NSString *)group;
@end

/// A page before or after the tab's current one, for the back and forward menus.
NS_SWIFT_UI_ACTOR
@protocol BENavigationItem <NSObject>
/// From the current page: -1 is the page Back goes to, 1 Forward's.
@property (nonatomic, readonly) NSInteger offset;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSURL *url;
/// Nil until the page's icon is known.
@property (nonatomic, readonly, nullable) NSImage *favicon;
@end

NS_SWIFT_UI_ACTOR
@protocol BETabNavigationHistory <NSObject>
@optional
/// The pages Back (or Forward) goes through, nearest first, at most `limit`.
- (NSArray<id<BENavigationItem>> *)navigationItemsForward:(BOOL)forward limit:(NSInteger)limit;
/// Goes `offset` pages back (negative) or forward, or opens that page elsewhere.
- (void)goToNavigationOffset:(NSInteger)offset disposition:(BEOpenDisposition)disposition;
@end

/// Find in page with the app's own find bar.
NS_SWIFT_UI_ACTOR
@protocol BEWindowFind <NSObject>
@optional
/// Finds `text` in the selected tab: the next match, or the one before with `forward` NO. Empty
/// text clears the matches.
- (void)findText:(NSString *)text forward:(BOOL)forward;
/// Ends finding: the matches go, the last one stays selected.
- (void)endFind;
@end

/// What a window asks the app to show in place of Chrome's own UI. Each returns whether the app
/// shows it; an app that doesn't implement one, or returns NO, gets Chrome's.
NS_SWIFT_UI_ACTOR
@protocol BEWindowDelegateNativeUI <NSObject>
@optional
/// Chrome's bookmark bubble or editor would show: the app's star popover or editor instead, for
/// the selected tab's page.
- (BOOL)window:(id<BEWindow>)window showBookmarkEditor:(id<BEBookmarkEditRequest>)request;
/// Find in page started (⌘F, or ⌘E then ⌘G): the find bar, with Chrome's last text. An app
/// that implements these draws every find bar; Chrome's never shows.
- (void)window:(id<BEWindow>)window showFindBarWithText:(NSString *)text;
- (void)windowHideFindBar:(id<BEWindow>)window;
/// The selected tab's matches: `current` of `total` (0 of 0: none); `final` once the count is done.
- (void)window:(id<BEWindow>)window didFindMatch:(NSInteger)current of:(NSInteger)total final:(BOOL)final;
/// Closing the window (or quitting, `quitting`) would cancel `count` downloads: the app asks, and
/// calls `completion` once, with YES to close anyway.
- (BOOL)window:(id<BEWindow>)window confirmClosingWithDownloads:(NSInteger)count quitting:(BOOL)quitting
    completion:(void (^)(BOOL closeAnyway))completion;
/// A page took the screen (full screen, pointer lock): the notice Chrome shows at the top for a
/// few seconds ("Press Esc to exit full screen"); empty text hides it.
- (BOOL)window:(id<BEWindow>)window showFullscreenNotice:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
