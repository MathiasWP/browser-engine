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

// MARK: Our own UI in place of Chrome's, second batch (9 Nov 2026)

/// A page in history as Chrome's history page lists it: one entry per address and day, at the
/// page's latest visit that day.
NS_SWIFT_UI_ACTOR
@protocol BEHistoryEntry <NSObject>
@property (nonatomic, readonly, copy) NSURL *url;
/// Its title; the address when the page had none.
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSDate *visitTime;
@end

/// The history page's data, from the window's profile's history (a private window's: its everyday
/// profile's). Completions run once, on a later task, and not at all if the window closes first.
NS_SWIFT_UI_ACTOR
@protocol BEWindowHistory <NSObject>
@optional
/// Newest first, as Chrome's history page asks: pages whose title or address match `text` (all
/// for empty text), on `host` or its subdomains if given, visited before `before` (nil: now), at
/// most `count`. `complete`: nothing older is left.
- (void)queryHistory:(NSString *)text
                host:(nullable NSString *)host
              before:(nullable NSDate *)before
               count:(NSInteger)count
          completion:(void (^)(NSArray<id<BEHistoryEntry>> *entries, BOOL complete))completion;
/// Removes each entry's page's visits on that entry's day (the page's Remove from history).
- (void)removeHistoryEntries:(NSArray<id<BEHistoryEntry>> *)entries completion:(void (^)(void))completion;
/// The icon history keeps for the page at `url`; nil if it has none.
- (void)requestHistoryFaviconForURL:(NSURL *)url completion:(void (^)(NSImage *_Nullable favicon))completion;
@end

/// What a page asks the user, in a dialog over the page. (Chrome: JavaScript dialogs, the
/// beforeunload dialog, the HTTP sign-in dialog, the external protocol dialog.)
typedef NS_ENUM(NSInteger, BEPageDialogKind) {
    BEPageDialogKindAlert = 0,
    BEPageDialogKindConfirm = 1,
    /// Asks for text: `defaultText` to start with.
    BEPageDialogKindPrompt = 2,
    /// "Leave site?": the page would lose what was entered (beforeunload).
    BEPageDialogKindLeave = 3,
    /// "Reload site?", the same when reloading.
    BEPageDialogKindReload = 4,
    /// A site or proxy asks for a user name and password (HTTP authentication).
    BEPageDialogKindSignIn = 5,
    /// A link would open another app ("Open Zoom?").
    BEPageDialogKindOpenApp = 6,
};

NS_SWIFT_UI_ACTOR
@protocol BEPageDialog <NSObject>
@property (nonatomic, readonly) BEPageDialogKind kind;
/// As Chrome titles it: "example.com says", "Leave site?", "Sign in", "Open Zoom?".
@property (nonatomic, readonly, copy) NSString *title;
/// The page's message; a sign-in's who and why ("https://example.com requires a username and
/// password", and "Your connection to this site is not private" over http); an app's, who asks.
@property (nonatomic, readonly, copy) NSString *message;
/// A prompt's text, or a sign-in's saved user name, to start with.
@property (nonatomic, readonly, copy) NSString *defaultText;
/// A sign-in's saved password, to start with.
@property (nonatomic, readonly, copy) NSString *defaultPassword;
/// What accepting says: "OK", "Leave", "Reload", "Sign in", "Open Zoom".
@property (nonatomic, readonly, copy) NSString *acceptTitle;
/// What cancelling says: "Cancel"; empty for an alert, which only has OK.
@property (nonatomic, readonly, copy) NSString *cancelTitle;
/// An app's "Always allow example.com to open links of this type in the associated app"; nil
/// when Chrome wouldn't offer it.
@property (nonatomic, readonly, copy, nullable) NSString *rememberTitle;
/// NO once answered or closed by Chrome; an answer then does nothing.
@property (nonatomic, readonly) BOOL isOpen;
/// Runs when `defaultText` or `defaultPassword` change (saved sign-in details arriving).
@property (nonatomic, copy, nullable) void (^didChange)(void);
/// OK, Leave, Sign in, Open: `text` is a prompt's answer or a sign-in's user name, `password` a
/// sign-in's, `remember` the app's checkbox.
- (void)acceptWithText:(NSString *)text password:(NSString *)password remember:(BOOL)remember;
/// Cancel, Stay, Escape (an alert's too). Answers arrive on a later task, so the app may answer
/// from inside `tab:showPageDialog:`.
- (void)cancel;
@end

/// A site asks for permissions (camera, location, notifications…), as Chrome's permission bubble
/// asks; one prompt can ask for several (camera and microphone).
NS_SWIFT_UI_ACTOR
@protocol BEPermissionPrompt <NSObject>
/// Who asks, as Chrome shows it ("example.com"; "This file").
@property (nonatomic, readonly, copy) NSString *origin;
/// What for, one line each, as under Chrome's "example.com wants to" ("Use your camera").
@property (nonatomic, readonly, copy) NSArray<NSString *> *requests;
/// Each request's kind, for its icon: camera, microphone, location, notifications, clipboard,
/// midi, downloads, storage, windows, fonts, sensors, vr, ar, handTracking, idle, localNetwork,
/// protocolHandler, other.
@property (nonatomic, readonly, copy) NSArray<NSString *> *kinds;
/// "Allow while visiting the site", or a request's own.
@property (nonatomic, readonly, copy) NSString *allowTitle;
/// "Allow this time"; nil when a request can't be allowed just once (notifications).
@property (nonatomic, readonly, copy, nullable) NSString *allowOnceTitle;
/// "Never allow", or a request's own.
@property (nonatomic, readonly, copy) NSString *blockTitle;
/// NO once answered or withdrawn; an answer then does nothing.
@property (nonatomic, readonly) BOOL isOpen;
- (void)allow;
- (void)allowOnce;
- (void)block;
/// Closed without an answer (the prompt's close button, Escape).
- (void)dismiss;
@end

/// What a tab asks the app to show over its page in place of Chrome's own UI.
NS_SWIFT_UI_ACTOR
@protocol BETabDelegateNativeUI <NSObject>
@optional
/// The app shows `dialog` over the tab's page while the tab is selected, until it's answered or
/// `tab:closePageDialog:` comes. Returns whether it does; NO gets Chrome's dialog. A tab has one
/// at a time.
- (BOOL)tab:(id<BETab>)tab showPageDialog:(id<BEPageDialog>)dialog;
/// Chrome closed it unanswered (the page navigated or went, another dialog replaced it).
- (void)tab:(id<BETab>)tab closePageDialog:(id<BEPageDialog>)dialog;
/// The same for a permission prompt, which Chrome shows only while its tab is selected (it
/// closes the prompt when another tab is selected and asks again on return).
- (BOOL)tab:(id<BETab>)tab showPermissionPrompt:(id<BEPermissionPrompt>)prompt;
- (void)tab:(id<BETab>)tab closePermissionPrompt:(id<BEPermissionPrompt>)prompt;
@end

// MARK: Settings' own pages (9 Nov 2026)

/// What Delete browsing data deletes. (Chrome: its dialog's checkboxes)
typedef NS_OPTIONS(NSUInteger, BEBrowsingDataTypes) {
    BEBrowsingDataTypeHistory = 1 << 0,
    BEBrowsingDataTypeDownloads = 1 << 1,
    /// Cookies and other site data: signs out of most sites.
    BEBrowsingDataTypeCookies = 1 << 2,
    BEBrowsingDataTypeCache = 1 << 3,
    /// Autofill form data: addresses and what was typed into forms.
    BEBrowsingDataTypeFormData = 1 << 4,
    BEBrowsingDataTypeSiteSettings = 1 << 5,
    BEBrowsingDataTypePasswords = 1 << 6,
};

/// From when. (Chrome: `browsing_data::TimePeriod`)
typedef NS_ENUM(NSInteger, BEBrowsingDataPeriod) {
    BEBrowsingDataPeriodLastHour = 0,
    BEBrowsingDataPeriodLastDay = 1,
    BEBrowsingDataPeriodLastWeek = 2,
    BEBrowsingDataPeriodFourWeeks = 3,
    BEBrowsingDataPeriodAllTime = 4,
    BEBrowsingDataPeriodLast15Minutes = 6,
};

/// Delete browsing data, for the window's profile (a private window's: its everyday profile's).
NS_SWIFT_UI_ACTOR
@protocol BEWindowBrowsingData <NSObject>
@optional
/// Counts what each of `types` holds from `period`, as Chrome's dialog words it ("1,203 items",
/// "From 32 sites", "Less than 4 MB"): `update` gets one type's text at a time, again as counting
/// goes on, until counting is asked for again or stopped.
- (void)countBrowsingData:(BEBrowsingDataTypes)types
                   period:(BEBrowsingDataPeriod)period
                   update:(void (^)(BEBrowsingDataTypes type, NSString *text))update;
- (void)stopCountingBrowsingData;
/// Deletes `types` from `period`, as the dialog's Delete does; `completion` once done.
- (void)removeBrowsingData:(BEBrowsingDataTypes)types
                    period:(BEBrowsingDataPeriod)period
                completion:(void (^)(void))completion;
@end

/// A search engine, or a site's search ("wikipedia.org"). (Chrome: `TemplateURL`)
NS_SWIFT_UI_ACTOR
@protocol BESearchEngine <NSObject>
@property (nonatomic, readonly) int64_t identifier;
@property (nonatomic, readonly, copy) NSString *name;
/// What's typed before the search in the address field.
@property (nonatomic, readonly, copy) NSString *keyword;
/// The search's address, with %s for what's searched for.
@property (nonatomic, readonly, copy) NSString *url;
@property (nonatomic, readonly) BOOL isDefault;
/// One of the engines Chrome offers as the default; otherwise a site search.
@property (nonatomic, readonly) BOOL isDefaultChoice;
@property (nonatomic, readonly) BOOL canMakeDefault;
@property (nonatomic, readonly) BOOL canEdit;
@property (nonatomic, readonly) BOOL canRemove;
@end

/// Search engines and site search (Chrome's settings page), for the window's profile. Changes,
/// whoever made them, come as `windowDidChangeSearchEngines:` (BEWindowDelegateSettings).
NS_SWIFT_UI_ACTOR
@protocol BEWindowSearchEngines <NSObject>
@optional
/// The default choices first, then site search, each as Chrome orders them; empty until loaded.
@property (nonatomic, readonly, copy) NSArray<id<BESearchEngine>> *searchEngines;
- (void)makeDefaultSearchEngine:(int64_t)identifier;
/// A new site search; its id, or 0 when it can't be added: a name or keyword missing or the
/// keyword taken, or an address without %s.
- (int64_t)addSearchEngine:(NSString *)name keyword:(NSString *)keyword url:(NSString *)url;
/// NO under the same rules as adding.
- (BOOL)editSearchEngine:(int64_t)identifier name:(NSString *)name keyword:(NSString *)keyword url:(NSString *)url;
- (void)removeSearchEngine:(int64_t)identifier;
@end

/// Sites with a zoom of their own (Chrome: `HostZoomMap`), for the window's profile.
NS_SWIFT_UI_ACTOR
@protocol BEWindowSiteZoom <NSObject>
@optional
/// Host to percent.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSNumber *> *siteZoomLevels;
/// The site goes back to the default zoom.
- (void)resetZoomForSite:(NSString *)host;
@end

NS_SWIFT_UI_ACTOR
@protocol BEWindowDelegateSettings <NSObject>
@optional
- (void)windowDidChangeSearchEngines:(id<BEWindow>)window;
/// A site's zoom changed, or went back to the default.
- (void)windowDidChangeSiteZoomLevels:(id<BEWindow>)window;
@end

// MARK: Page info (9 Nov 2026)

/// A site permission's setting. (Chrome: `ContentSetting`)
typedef NS_ENUM(NSInteger, BESitePermissionState) {
    /// As every site: the default (Chrome: CONTENT_SETTING_DEFAULT, or none set).
    BESitePermissionStateDefault = 0,
    BESitePermissionStateAllow = 1,
    BESitePermissionStateBlock = 2,
    BESitePermissionStateAsk = 3,
};

/// One of a site's permissions, as Chrome's page info lists it.
NS_SWIFT_UI_ACTOR
@protocol BESitePermission <NSObject>
/// Chrome's content setting type, to set it by.
@property (nonatomic, readonly) NSInteger identifier;
/// "Location", "Camera".
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) BESitePermissionState state;
/// Chrome's words for it: "Allowed", "Blocked", "Allowed this time", "Blocked by your organisation".
@property (nonatomic, readonly, copy) NSString *stateText;
/// What the default is now: Allow, Block or Ask.
@property (nonatomic, readonly) BESitePermissionState defaultState;
/// Which states Chrome offers for it besides the default.
@property (nonatomic, readonly) BOOL offersAllow;
@property (nonatomic, readonly) BOOL offersAsk;
/// Set by policy or an extension: it can't be changed here.
@property (nonatomic, readonly) BOOL isManaged;
/// The site uses it now (the camera on).
@property (nonatomic, readonly) BOOL isInUse;
@end

/// What Chrome's page info shows about the page's site, live while it's open: its connection
/// and identity, its permissions, its cookies. (Chrome: `PageInfo` and a `PageInfoUI`)
NS_SWIFT_UI_ACTOR
@protocol BESiteInfo <NSObject>
/// "example.com".
@property (nonatomic, readonly, copy) NSString *site;
/// Chrome's summary of the connection ("Connection is secure", "Not secure") and its details.
@property (nonatomic, readonly, copy) NSString *securityTitle;
@property (nonatomic, readonly, copy) NSString *securityDetail;
/// Green in Chrome (secure), red (a warning), or neither.
@property (nonatomic, readonly) BOOL isSecure;
@property (nonatomic, readonly) BOOL isWarning;
/// The site's certificate can be shown (`showCertificate`).
@property (nonatomic, readonly) BOOL hasCertificate;
/// Sites allowed to use cookies on the page; -1 while unknown.
@property (nonatomic, readonly) NSInteger cookieSites;
/// The permissions Chrome lists for the site: those set, in use, or asked for.
@property (nonatomic, readonly, copy) NSArray<id<BESitePermission>> *permissions;
/// Runs whenever any of the above changes.
@property (nonatomic, copy, nullable) void (^didChange)(void);
- (void)setPermission:(NSInteger)identifier state:(BESitePermissionState)state;
/// Chrome's certificate viewer.
- (void)showCertificate;
/// The page info is closed: a change that needs a reload gets Chrome's "Reload" infobar.
- (void)close;
@end

NS_SWIFT_UI_ACTOR
@protocol BETabSiteInfo <NSObject>
@optional
/// Page info for the tab's page now, in place of Chrome's bubble; nil for none (a new tab).
- (nullable id<BESiteInfo>)siteInfo;
@end

// MARK: Site setting popovers (9 Nov 2026)

/// What a site setting's icon in the address bar opens, as Chrome's content setting bubble shows
/// it: "Pop-ups blocked", what was blocked, and a choice for the site.
NS_SWIFT_UI_ACTOR
@protocol BESiteSettingPopover <NSObject>
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *message;
/// What it lists (a blocked pop-up's address), each opened with `openItem:`; it grows as more
/// are blocked.
@property (nonatomic, readonly, copy) NSArray<NSString *> *items;
/// The choices for the site ("Always allow pop-ups and redirects from example.com", "Continue
/// blocking"), and the one chosen.
@property (nonatomic, readonly, copy) NSArray<NSString *> *choices;
@property (nonatomic, readonly) NSInteger chosen;
/// NO when policy decides it.
@property (nonatomic, readonly) BOOL canChoose;
/// "Manage", which opens Chrome's settings for it; empty for none.
@property (nonatomic, readonly, copy) NSString *manageTitle;
/// "Done".
@property (nonatomic, readonly, copy) NSString *doneTitle;
/// Runs when `items` change.
@property (nonatomic, copy, nullable) void (^didChange)(void);
- (void)openItem:(NSInteger)index;
- (void)choose:(NSInteger)index;
- (void)manage;
/// Done, or the popover closed: the choice takes effect, as when Chrome's bubble closes.
- (void)close;
@end

NS_SWIFT_UI_ACTOR
@protocol BETabSiteSettingPopovers <NSObject>
@optional
/// The popover for one of `siteSettings` (its identifier), for the app to draw; nil where it
/// stays Chrome's (camera and microphone, with their device menus).
- (nullable id<BESiteSettingPopover>)siteSettingPopover:(NSString *)identifier;
@end

// MARK: Split view (10 Nov 2026)

/// Two tabs shown at once, side by side or one above the other, as Chrome's split view keeps
/// them: next to each other in the strip, both on screen and live, saved with the session and
/// brought back with it and with ⇧⌘T. The app places both tabs' `view`s in its own layout.
/// The active tab is the focused pane, which the bar follows; a click in the other pane makes
/// its tab the active one (`window:didActivateTab:`). (Chrome: `split_tabs::SplitTabData`)
NS_SWIFT_UI_ACTOR
@protocol BETabSplit <NSObject>
/// Stable while the split lasts.
@property (nonatomic, readonly, copy) NSString *identifier;
/// The start pane's tab first (left, or the top one when stacked), as in the strip.
@property (nonatomic, readonly, copy) NSArray<id<BETab>> *tabs;
/// The start pane's share of the width (or the height when stacked), 0–1.
@property (nonatomic, readonly) double ratio;
/// One above the other rather than side by side.
@property (nonatomic, readonly) BOOL isStacked;
@end

NS_SWIFT_UI_ACTOR
@protocol BEWindowSplits <NSObject>
@optional
/// The window's splits, in strip order; `windowDidChangeTabSplits:` says when they change.
@property (nonatomic, readonly, copy) NSArray<id<BETabSplit>> *tabSplits;
/// Makes a split of the tab at `index`, which stays where it is, and the tab at `other`, which
/// joins it in the start pane (left, or top) if `atStart`, else the end pane. Nil if either
/// isn't a tab or is already in a split.
- (nullable NSString *)splitTabAtIndex:(NSInteger)index
                        withTabAtIndex:(NSInteger)other
                               atStart:(BOOL)atStart;
/// The start pane's share, kept within what leaves each pane room; `final` NO while the
/// divider is still being dragged (saved only once it's let go).
- (void)setTabSplit:(NSString *)split ratio:(double)ratio final:(BOOL)final;
- (void)setTabSplit:(NSString *)split stacked:(BOOL)stacked;
/// The two panes change places.
- (void)reverseTabSplit:(NSString *)split;
/// Each tab its own again, where it is in the strip.
- (void)unsplitTabSplit:(NSString *)split;
@end

NS_SWIFT_UI_ACTOR
@protocol BEWindowDelegateSplits <NSObject>
@optional
/// Splits were made, changed (ratio, sides, layout, a tab replaced) or ended, by the app or by
/// Chrome (its menus, session restore, a split tab closed or moved out). Once per batch.
- (void)windowDidChangeTabSplits:(id<BEWindow>)window;
@end

// MARK: Tab hover cards (13 Nov 2026)

/// What a tab's hover card shows besides its title, from Chrome's own hover cards: a picture of
/// the page, the memory it uses, and when it was last shown. (Chrome: `TabHoverCardBubbleView`)
NS_SWIFT_UI_ACTOR
@protocol BETabGlance <NSObject>
@optional
/// Pictures of the page while `handler` is set, about `pixelSize` big: at once the one Chrome
/// kept from when the tab was last shown, then a fresh one if a hidden page has to be drawn for
/// it (`ThumbnailTabHelper`, which needs Chrome's TabHoverCardImages feature). nil stops. NO if
/// the engine keeps no pictures of this tab.
- (BOOL)observeThumbnailWithPixelSize:(NSSize)pixelSize handler:(nullable void (^)(NSImage *image))handler;
/// The memory the tab's page uses, in bytes, as last measured; 0 before the first measure.
@property (nonatomic, readonly) uint64_t memoryUsage;
/// Measures the tab's memory again (`TabResourceUsageCollector`), then `completion` with it;
/// within about two seconds whatever happens.
- (void)measureMemoryUsage:(void (^)(uint64_t bytes))completion;
/// When the tab was last the window's active tab (or made, if never).
@property (nonatomic, readonly, nullable) NSDate *lastActiveDate;
@end

// MARK: Extensions manager (13 Nov 2026)

/// Whether an extension runs. (Chrome: developerPrivate's `ExtensionState`)
typedef NS_ENUM(NSInteger, BEExtensionState) {
    BEExtensionStateEnabled = 0,
    BEExtensionStateDisabled = 1,
    /// Its background stopped (it crashed); reloading starts it again.
    BEExtensionStateTerminated = 2,
    /// On Chrome's blocklist: it can't be turned on.
    BEExtensionStateBlocked = 3,
};

/// Where an extension may read and change pages. (Chrome: developerPrivate's `HostAccess`)
typedef NS_ENUM(NSInteger, BEExtensionSiteAccess) {
    /// Only when its button is clicked.
    BEExtensionSiteAccessOnClick = 0,
    /// On the sites in `allowedSites`.
    BEExtensionSiteAccessOnSpecificSites = 1,
    /// On every site it asks for.
    BEExtensionSiteAccessOnAllSites = 2,
};

/// What of an extension DevTools can inspect.
typedef NS_ENUM(NSInteger, BEExtensionViewKind) {
    BEExtensionViewKindServiceWorker = 0,
    BEExtensionViewKindBackgroundPage = 1,
    BEExtensionViewKindPopup = 2,
    BEExtensionViewKindTab = 3,
    BEExtensionViewKindOffscreen = 4,
    BEExtensionViewKindOther = 5,
};

/// One of an extension's keyboard shortcuts. (Chrome: `extensions::Command`)
NS_SWIFT_UI_ACTOR
@protocol BEExtensionCommand <NSObject>
/// Chrome's name for it ("_execute_action"), to set it by.
@property (nonatomic, readonly, copy) NSString *name;
/// What it does: "Activate the extension", or the extension's own words.
@property (nonatomic, readonly, copy) NSString *title;
/// As the Mac writes it ("⇧⌘Y"); empty for none.
@property (nonatomic, readonly, copy) NSString *shortcut;
/// Works while another app is in front.
@property (nonatomic, readonly) BOOL isGlobal;
@end

/// Something of an extension's DevTools can inspect: its service worker, background page, a popup.
NS_SWIFT_UI_ACTOR
@protocol BEExtensionView <NSObject>
@property (nonatomic, readonly) BEExtensionViewKind kind;
@property (nonatomic, readonly, copy) NSURL *url;
@property (nonatomic, readonly) BOOL isIncognito;
/// Not running now; inspecting starts it.
@property (nonatomic, readonly) BOOL isInactive;
@end

/// An error an extension made, collected while developer mode is on. (Chrome: `ExtensionError`)
NS_SWIFT_UI_ACTOR
@protocol BEExtensionError <NSObject>
/// In its manifest, rather than while it ran.
@property (nonatomic, readonly) BOOL isManifestError;
@property (nonatomic, readonly) BOOL isWarning;
@property (nonatomic, readonly, copy) NSString *message;
/// The file it came from.
@property (nonatomic, readonly, copy) NSString *source;
@property (nonatomic, readonly) NSInteger occurrences;
@end

/// An extension as Chrome's extensions page shows it: a copy, read again after a change.
/// (Chrome: developerPrivate's `ExtensionInfo`)
NS_SWIFT_UI_ACTOR
@protocol BEExtension <NSObject>
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly, copy) NSString *summary;
@property (nonatomic, readonly, nullable) NSImage *icon;
@property (nonatomic, readonly) BEExtensionState state;
/// NO when policy decides.
@property (nonatomic, readonly) BOOL canToggle;
@property (nonatomic, readonly) BOOL canRemove;
/// Turned off because it now asks for more: turning it on grants `permissions`, so ask first.
@property (nonatomic, readonly) BOOL needsPermissionApproval;
/// Chrome's words about it, a line each: who installed it, why it's off, warnings.
@property (nonatomic, readonly, copy) NSArray<NSString *> *notices;
/// The folder an unpacked extension was loaded from; nil for others.
@property (nonatomic, readonly, copy, nullable) NSString *path;
/// Where it updates from: the Chrome Web Store's address for the store's extensions.
@property (nonatomic, readonly, copy) NSString *updateURL;
@property (nonatomic, readonly, copy, nullable) NSURL *homepage;
/// What it can do, as Chrome words it ("Read your browsing history"), sites aside.
@property (nonatomic, readonly, copy) NSArray<NSString *> *permissions;
/// Whether the user can choose `siteAccess` (it asks for sites).
@property (nonatomic, readonly) BOOL canChangeSiteAccess;
@property (nonatomic, readonly) BEExtensionSiteAccess siteAccess;
/// Sites as "https://example.com/*": those the user allowed it, and those it asks for but wasn't
/// given.
@property (nonatomic, readonly, copy) NSArray<NSString *> *allowedSites;
@property (nonatomic, readonly, copy) NSArray<NSString *> *requestedSites;
@property (nonatomic, readonly) BOOL canAllowIncognito;
@property (nonatomic, readonly) BOOL allowsIncognito;
@property (nonatomic, readonly) BOOL canAllowFileAccess;
@property (nonatomic, readonly) BOOL allowsFileAccess;
/// It has a toolbar button, which is pinned.
@property (nonatomic, readonly) BOOL hasAction;
@property (nonatomic, readonly) BOOL isPinned;
@property (nonatomic, readonly) BOOL hasOptions;
@property (nonatomic, readonly, copy) NSArray<id<BEExtensionCommand>> *commands;
/// Developer mode: what DevTools can inspect, and its errors.
@property (nonatomic, readonly, copy) NSArray<id<BEExtensionView>> *views;
@property (nonatomic, readonly) BOOL collectsErrors;
@property (nonatomic, readonly, copy) NSArray<id<BEExtensionError>> *errors;
@end

/// Chrome's extensions page for the window's profile (a private window's: its everyday profile's).
/// Changes, whoever made them, come as `windowDidChangeExtensions:`. Completions run once, on a
/// later task, and not at all if the window closes first.
NS_SWIFT_UI_ACTOR
@protocol BEWindowExtensionsManager <NSObject>
@optional
/// Every extension Chrome's page lists (on, off, blocked, crashed), by name; empty until the first
/// list is made, which the first read starts.
@property (nonatomic, readonly, copy) NSArray<id<BEExtension>> *installedExtensions;
@property (nonatomic, readonly) BOOL extensionsDeveloperMode;
/// NO under policy.
@property (nonatomic, readonly) BOOL canChangeExtensionsDeveloperMode;
- (void)setExtensionsDeveloperModeEnabled:(BOOL)on;
- (void)setExtension:(NSString *)identifier enabled:(BOOL)enabled;
/// After the app's own "Remove …?"; NO if Chrome refused (policy).
- (BOOL)removeExtension:(NSString *)identifier;
- (void)setExtension:(NSString *)identifier allowsIncognito:(BOOL)allow;
- (void)setExtension:(NSString *)identifier allowsFileAccess:(BOOL)allow;
- (void)setExtension:(NSString *)identifier siteAccess:(BEExtensionSiteAccess)access;
/// `site` as "https://example.com/*"; NO if it isn't one.
- (BOOL)setExtension:(NSString *)identifier site:(NSString *)site allowed:(BOOL)allowed;
- (void)setExtension:(NSString *)identifier pinned:(BOOL)pinned;
/// Its options page, in a tab of this window.
- (void)openOptionsOfExtension:(NSString *)identifier;
/// `keys` in Chrome's form: "Command+Shift+Y" (Command, Ctrl for the Control key, Alt, Shift,
/// then the key); empty clears it. NO if Chrome can't read it. Takes the shortcut from any other
/// extension that had it.
- (BOOL)setShortcut:(NSString *)keys forCommand:(NSString *)command ofExtension:(NSString *)identifier;
- (void)setCommand:(NSString *)command ofExtension:(NSString *)identifier global:(BOOL)global;
/// While the app records a shortcut, so that extensions' global shortcuts don't fire.
- (void)setExtensionShortcutsSuspended:(BOOL)suspended;
/// Developer mode: a folder with a manifest.json; the new extension's identifier, or why not.
- (void)loadUnpackedExtensionAtPath:(NSString *)path
                         completion:(void (^)(NSString *_Nullable identifier, NSString *_Nullable error))completion;
/// Loads it again (an unpacked one from its folder); nil, or why it failed.
- (void)reloadExtension:(NSString *)identifier completion:(void (^)(NSString *_Nullable error))completion;
/// Checks every extension for an update now.
- (void)updateExtensionsWithCompletion:(void (^)(void))completion;
- (void)inspectExtensionView:(id<BEExtensionView>)view ofExtension:(NSString *)identifier;
- (void)setExtension:(NSString *)identifier collectsErrors:(BOOL)collects;
- (void)clearErrorsOfExtension:(NSString *)identifier;
@end

NS_SWIFT_UI_ACTOR
@protocol BEWindowDelegateExtensions <NSObject>
@optional
/// `installedExtensions` changed: installed, removed, turned on or off, a setting, its views,
/// errors or shortcuts, or developer mode. At most once per task.
- (void)windowDidChangeExtensions:(id<BEWindow>)window NS_SWIFT_NAME(windowDidChangeExtensions(_:));
@end

// MARK: Task Manager (13 Nov 2026)

/// What a task is. (Chrome: `task_manager::Task::Type`)
typedef NS_ENUM(NSInteger, BETaskKind) {
    BETaskKindBrowser = 0,
    BETaskKindGPU = 1,
    BETaskKindUtility = 2,
    BETaskKindTab = 3,
    BETaskKindExtension = 4,
    BETaskKindWorker = 5,
    BETaskKindSubframe = 6,
    BETaskKindOther = 7,
};

/// A line of Chrome's Task Manager as last measured: a copy. Tasks of one process are next to
/// each other and share its numbers.
NS_SWIFT_UI_ACTOR
@protocol BETask <NSObject>
/// Stable while the task lives.
@property (nonatomic, readonly) int64_t identifier;
/// Chrome's words: "Tab: Example", "Extension: Dark Reader", "GPU Process".
@property (nonatomic, readonly, copy) NSString *title;
/// A template image when Chrome would tint it.
@property (nonatomic, readonly, nullable) NSImage *icon;
@property (nonatomic, readonly) BETaskKind kind;
/// In Chrome's "Tabs & extensions" rather than "System".
@property (nonatomic, readonly) BOOL isTabOrExtension;
@property (nonatomic, readonly, copy) NSString *profileName;
@property (nonatomic, readonly) int32_t processIdentifier;
/// Percent of one core; NaN until measured.
@property (nonatomic, readonly) double cpuUsage;
/// Bytes; -1 until measured.
@property (nonatomic, readonly) int64_t memoryFootprint;
/// Bytes a second; -1 when not measured.
@property (nonatomic, readonly) int64_t networkUsage;
/// Its process can be ended: never the browser's, nor under policy.
@property (nonatomic, readonly) BOOL canEnd;
@end

/// Chrome's Task Manager, measuring every two seconds while open, as Chrome's window does.
NS_SWIFT_UI_ACTOR
@protocol BETaskManager <NSObject>
/// The browser first, then by process.
@property (nonatomic, readonly, copy) NSArray<id<BETask>> *tasks;
/// `tasks` changed: measured again, or a task came or went. At most once per task.
@property (nonatomic, copy, nullable) void (^didChange)(void);
/// Shows its tab, in its window.
- (void)activateTask:(int64_t)identifier;
/// Ends its process, and every task in it. NO if it didn't end.
- (BOOL)endTask:(int64_t)identifier;
/// The task of a tab, to select when opened from its window; -1 for none.
- (int64_t)taskForTab:(id<BETab>)tab;
/// Stops measuring: `tasks` stays as it was, and the methods do nothing.
- (void)close;
@end

NS_SWIFT_UI_ACTOR
@protocol BEEngineTaskManager <NSObject>
@optional
/// Starts measuring; nil before Chromium has started.
- (nullable id<BETaskManager>)openTaskManager NS_SWIFT_NAME(openTaskManager());
@end

// MARK: Import (13 Nov 2026)

/// What can be brought over from another browser. (Chrome: `user_data_importer::ImportItem`)
typedef NS_OPTIONS(NSUInteger, BEImportItems) {
    BEImportItemHistory = 1 << 0,
    BEImportItemBookmarks = 1 << 1,
    BEImportItemPasswords = 1 << 3,
    BEImportItemSearchEngines = 1 << 4,
    BEImportItemFormData = 1 << 6,
};

typedef NS_ENUM(NSInteger, BEImportResult) {
    BEImportResultSucceeded = 0,
    /// Nothing came over: unreadable, or the importer stopped.
    BEImportResultFailed = 1,
    /// Firefox holds its profile: quit it and try again.
    BEImportResultBrowserOpen = 2,
    BEImportResultCancelled = 3,
};

/// A browser profile to import from. (Chrome: `user_data_importer::SourceProfile`)
NS_SWIFT_UI_ACTOR
@protocol BEImportSource <NSObject>
/// Good until sources are found again.
@property (nonatomic, readonly, copy) NSString *identifier;
/// "Safari", "Mozilla Firefox".
@property (nonatomic, readonly, copy) NSString *name;
/// Firefox's profile's name; empty for others.
@property (nonatomic, readonly, copy) NSString *profileName;
/// What it can give.
@property (nonatomic, readonly) BEImportItems items;
/// Its data is there, but macOS keeps it from the app until the app has Full Disk Access.
@property (nonatomic, readonly) BOOL needsFullDiskAccess;
@end

/// Imports into the window's profile (a private window's: its everyday profile). Completions run
/// once, on a later task; an import goes on to its end if the window closes.
NS_SWIFT_UI_ACTOR
@protocol BEWindowImport <NSObject>
@optional
- (void)findImportSources:(void (^)(NSArray<id<BEImportSource>> *sources))completion;
/// `progress` as each item starts and ends; `completion` with what came over.
- (void)importFrom:(NSString *)source
             items:(BEImportItems)items
          progress:(nullable void (^)(BEImportItems item, BOOL done))progress
        completion:(void (^)(BEImportResult result, BEImportItems imported))completion;
/// A bookmarks file (HTML, as browsers export them): into "Imported", with keywords and icons.
- (void)importBookmarksFile:(NSURL *)file
                 completion:(void (^)(BEImportResult result, BEImportItems imported))completion;
- (void)cancelImport;
@end

// MARK: Profiles by the app (13 Nov 2026)

/// More of a profile, for the app's own picker and editor; the engine's `BEProfile`s adopt it.
NS_SWIFT_UI_ACTOR
@protocol BEProfileDetails <NSObject>
/// One of `profileAvatarChoices`' indexes.
@property (nonatomic, readonly) NSInteger avatarIndex;
/// Its colour; nil for the default.
@property (nonatomic, readonly, nullable) NSColor *color;
/// Loaded now: it has windows, or is about to.
@property (nonatomic, readonly) BOOL isOpen;
@end

/// An avatar a profile can have. (Chrome: the default avatars)
NS_SWIFT_UI_ACTOR
@protocol BEProfileAvatarChoice <NSObject>
@property (nonatomic, readonly) NSInteger index;
/// "Cat".
@property (nonatomic, readonly, copy) NSString *label;
@property (nonatomic, readonly) NSImage *image;
@end

/// A colour a profile can have. (Chrome: `kDynamicCustomizeChromeColors`)
NS_SWIFT_UI_ACTOR
@protocol BEProfileColorChoice <NSObject>
@property (nonatomic, readonly, copy) NSString *label;
@property (nonatomic, readonly) NSColor *color;
@end

/// Why Chrome would show its profile picker.
typedef NS_ENUM(NSInteger, BEProfilePickerReason) {
    /// At startup, with "ask on startup", or with no usable profile.
    BEProfilePickerReasonStartup = 0,
    BEProfilePickerReasonManage = 1,
    BEProfilePickerReasonAdd = 2,
    /// A profile was just deleted while the picker was open.
    BEProfilePickerReasonAfterDeletion = 3,
    BEProfilePickerReasonOther = 4,
};

NS_SWIFT_UI_ACTOR
@protocol BEEngineProfiles <NSObject>
@optional
@property (nonatomic, readonly, copy) NSArray<id<BEProfileAvatarChoice>> *profileAvatarChoices;
@property (nonatomic, readonly, copy) NSArray<id<BEProfileColorChoice>> *profileColorChoices;
/// The avatar drawn from the profile's colour (its initial-less placeholder).
@property (nonatomic, readonly) NSInteger genericAvatarIndex;
/// A profile's avatar, `points` big (drawn at twice that).
- (nullable NSImage *)avatarForProfile:(NSString *)identifier size:(CGFloat)points;
/// A profile without an account, and a window for it if `openWindow`; `name` nil for Chrome's next
/// "Person N". `completion` with its identifier, nil if it couldn't be made.
- (void)createProfileNamed:(nullable NSString *)name
               avatarIndex:(NSInteger)avatarIndex
                     color:(nullable NSColor *)color
                openWindow:(BOOL)openWindow
                completion:(void (^)(NSString *_Nullable identifier))completion;
/// NO if `name` is empty or there's no such profile.
- (BOOL)renameProfile:(NSString *)identifier to:(NSString *)name;
- (void)setAvatarIndex:(NSInteger)index forProfile:(NSString *)identifier;
/// nil for the default.
- (void)setColor:(nullable NSColor *)color forProfile:(NSString *)identifier;
/// What deleting it would lose, as Chrome's delete dialog counts it: "BrowsingHistory",
/// "Passwords", "Bookmarks", "Autofill"; `update` again as each count arrives, until stopped.
- (void)countDataOfProfile:(NSString *)identifier
                    update:(void (^)(NSDictionary<NSString *, NSNumber *> *counts))update;
- (void)stopCountingProfileData;
/// Closes its windows (a page may refuse to leave, which keeps it) and deletes it: watch
/// `engineDidChangeProfiles:`. Deleting the last profile makes a new one.
- (void)deleteProfile:(NSString *)identifier;
/// Chosen in the app's picker: its window, or a new one; at startup with the pages the app was
/// opened with.
- (void)pickProfile:(NSString *)identifier;
- (void)moveProfileAtIndex:(NSInteger)from toIndex:(NSInteger)to;
@property (nonatomic, readonly) BOOL canCreateProfiles;
@property (nonatomic, readonly) BOOL guestModeEnabled;
- (void)openGuestWindow;
/// Chrome's "Ask on startup", with two profiles or more.
@property (nonatomic) BOOL showsProfilePickerOnStartup;
@end

NS_SWIFT_UI_ACTOR
@protocol BEEngineDelegateProfiles <NSObject>
@optional
/// Chrome would show its profile picker now: YES when the app shows its own instead.
- (BOOL)engine:(id<BEEngine>)engine showProfilePicker:(BEProfilePickerReason)reason;
@end

// MARK: Passwords, addresses and payment cards (13 Nov 2026)

/// A saved sign-in: a username and password on one or more sites, as Chrome's password manager
/// lists it. Its password and note aren't here: ask for them. (Chrome: `CredentialUIEntry`)
NS_SWIFT_UI_ACTOR
@protocol BESavedPassword <NSObject>
/// For this window; a new one once its username or password changes.
@property (nonatomic, readonly) int64_t identifier;
@property (nonatomic, readonly, copy) NSString *username;
/// "accounts.example.com", as Chrome shows them.
@property (nonatomic, readonly, copy) NSArray<NSString *> *sites;
@property (nonatomic, readonly, copy) NSArray<NSURL *> *siteURLs;
/// Signs in with another site's account ("accounts.google.com"); it has no password then.
@property (nonatomic, readonly, copy, nullable) NSString *federatedWith;
@property (nonatomic, readonly) BOOL hasNote;
@property (nonatomic, readonly, copy, nullable) NSDate *lastUsed;
@end

/// Passwords for one site, as Chrome groups them (without Google's affiliations: by the site's
/// registrable domain, "example.com").
NS_SWIFT_UI_ACTOR
@protocol BEPasswordGroup <NSObject>
@property (nonatomic, readonly, copy) NSString *name;
/// For its icon (`requestHistoryFaviconForURL:`).
@property (nonatomic, readonly, copy) NSURL *url;
@property (nonatomic, readonly, copy) NSArray<id<BESavedPassword>> *passwords;
@end

/// A site Chrome was told never to offer to save a password for.
NS_SWIFT_UI_ACTOR
@protocol BENeverSavedSite <NSObject>
@property (nonatomic, readonly) int64_t identifier;
@property (nonatomic, readonly, copy) NSString *site;
@property (nonatomic, readonly, copy) NSURL *url;
@end

typedef NS_ENUM(NSInteger, BEPasswordEditResult) {
    BEPasswordEditResultSaved = 0,
    BEPasswordEditResultNotFound = 1,
    /// The site has a password for that username already.
    BEPasswordEditResultUsernameTaken = 2,
    BEPasswordEditResultEmptyPassword = 3,
};

typedef NS_ENUM(NSInteger, BEPasswordImportStatus) {
    BEPasswordImportStatusImported = 0,
    /// Some rows are for sign-ins saved already: `replacePasswords:` takes the file's.
    BEPasswordImportStatusConflicts = 1,
    BEPasswordImportStatusUnreadable = 2,
    BEPasswordImportStatusTooLarge = 3,
    /// Another import is running.
    BEPasswordImportStatusBusy = 4,
    BEPasswordImportStatusFailed = 5,
};

/// A row of a passwords file that didn't come in.
NS_SWIFT_UI_ACTOR
@protocol BEPasswordImportRow <NSObject>
@property (nonatomic, readonly) NSInteger identifier;
@property (nonatomic, readonly, copy) NSString *site;
@property (nonatomic, readonly, copy) NSString *username;
/// Why it didn't; empty for a sign-in saved already (a conflict).
@property (nonatomic, readonly, copy) NSString *problem;
@end

NS_SWIFT_UI_ACTOR
@protocol BEPasswordImport <NSObject>
@property (nonatomic, readonly) BEPasswordImportStatus status;
@property (nonatomic, readonly) NSInteger importedCount;
@property (nonatomic, readonly, copy) NSArray<id<BEPasswordImportRow>> *rows;
/// Everything came in: the file (passwords in the clear) can go.
@property (nonatomic, readonly) BOOL canDeleteFile;
@end

/// Chrome's password manager for the window's profile (a private window's: its everyday
/// profile's). Changes, whoever made them, come as `windowDidChangePasswords:`; writes take
/// effect a moment later, so read again then. Completions run once, on a later task, and not at
/// all if the window closes first.
NS_SWIFT_UI_ACTOR
@protocol BEWindowPasswords <NSObject>
@optional
/// By site name; empty until loaded, which the first read starts.
@property (nonatomic, readonly, copy) NSArray<id<BEPasswordGroup>> *passwordGroups;
@property (nonatomic, readonly, copy) NSArray<id<BENeverSavedSite>> *neverSavedSites;
/// After macOS asks who it is (Touch ID or the account's password; not again for five minutes);
/// nil if refused.
- (void)revealPassword:(int64_t)identifier
            completion:(void (^)(NSString *_Nullable password, NSString *_Nullable note))completion;
/// After the same; copied concealed from clipboard history, and cleared after two minutes unless
/// replaced.
- (void)copyPassword:(int64_t)identifier completion:(void (^)(BOOL copied))completion;
/// NO: not a web address, an empty password, or the username is saved for the site already.
- (BOOL)addPasswordForSite:(NSString *)site
                  username:(NSString *)username
                  password:(NSString *)password
                      note:(NSString *)note;
- (BEPasswordEditResult)editPassword:(int64_t)identifier
                            username:(NSString *)username
                            password:(NSString *)password
                                note:(NSString *)note;
/// A saved password or a never-saved site.
- (void)removePassword:(int64_t)identifier;
- (void)undoPasswordRemoval;
/// A CSV file, after macOS asks who it is (every time).
- (void)exportPasswordsToFile:(NSURL *)file completion:(void (^)(BOOL exported))completion;
- (void)importPasswordsFromFile:(NSURL *)file completion:(void (^)(id<BEPasswordImport> result))completion;
/// The conflicting rows given (by `BEPasswordImportRow.identifier`) replace what's saved.
- (void)replacePasswords:(NSArray<NSNumber *> *)rows completion:(void (^)(id<BEPasswordImport> result))completion;
/// Ends an import; deletes the file if asked and it can.
- (void)finishPasswordImportDeletingFile:(BOOL)deleteFile;
/// Weak passwords, and groups of passwords used on more than one site, by identifier. (Chrome's
/// password check without Google: no leaked passwords.)
- (void)checkPasswordsWithCompletion:(void (^)(NSArray<NSNumber *> *weak,
                                               NSArray<NSArray<NSNumber *> *> *reused))completion;
@end

/// A part of an address. (Chrome: the `FieldType`s its address editor offers)
typedef NS_ENUM(NSInteger, BEAddressField) {
    BEAddressFieldName = 0,
    BEAddressFieldOrganization = 1,
    BEAddressFieldStreet = 2,
    BEAddressFieldCity = 3,
    BEAddressFieldState = 4,
    BEAddressFieldPostalCode = 5,
    /// Its ISO code ("NO").
    BEAddressFieldCountry = 6,
    BEAddressFieldPhone = 7,
    BEAddressFieldEmail = 8,
    BEAddressFieldDependentLocality = 9,
    BEAddressFieldSortingCode = 10,
};

/// An address Chrome fills forms with. (Chrome: `AutofillProfile`, local)
NS_SWIFT_UI_ACTOR
@protocol BEAddress <NSObject>
/// Stable.
@property (nonatomic, readonly, copy) NSString *identifier;
/// "Jane Doe".
@property (nonatomic, readonly, copy) NSString *label;
/// "1 Main St, Springfield".
@property (nonatomic, readonly, copy) NSString *sublabel;
/// By `BEAddressField`.
@property (nonatomic, readonly, copy) NSDictionary<NSNumber *, NSString *> *fields;
@end

/// A field of a country's address form, as Chrome's editor lays it out.
NS_SWIFT_UI_ACTOR
@protocol BEAddressFormatField <NSObject>
@property (nonatomic, readonly) BEAddressField field;
/// The country's word for it: "ZIP code", "Postcode".
@property (nonatomic, readonly, copy) NSString *label;
/// Takes a line of its own.
@property (nonatomic, readonly) BOOL isLong;
@property (nonatomic, readonly) BOOL isRequired;
@end

/// The addresses Chrome fills forms with, for the window's profile. Changes come as
/// `windowDidChangeAddresses:`.
NS_SWIFT_UI_ACTOR
@protocol BEWindowAddresses <NSObject>
@optional
/// Empty until loaded.
@property (nonatomic, readonly, copy) NSArray<id<BEAddress>> *addresses;
/// Pairs of ISO code and name, by name.
@property (nonatomic, readonly, copy) NSArray<NSArray<NSString *> *> *addressCountries;
@property (nonatomic, readonly, copy) NSString *defaultAddressCountry;
/// The country's form, a line of fields at a time.
- (NSArray<NSArray<id<BEAddressFormatField>> *> *)addressFormatForCountry:(NSString *)code;
/// A new address (nil) or a change; its identifier, or nil before the addresses have loaded.
- (nullable NSString *)saveAddress:(nullable NSString *)identifier
                            fields:(NSDictionary<NSNumber *, NSString *> *)fields;
- (void)removeAddress:(NSString *)identifier;
@end

/// A payment card Chrome fills forms with, kept on this Mac. (Chrome: `CreditCard`, local)
NS_SWIFT_UI_ACTOR
@protocol BEPaymentCard <NSObject>
/// Stable.
@property (nonatomic, readonly, copy) NSString *identifier;
/// "Visa".
@property (nonatomic, readonly, copy) NSString *network;
/// Chrome's name for the network ("visaCC").
@property (nonatomic, readonly, copy) NSString *networkIdentifier;
@property (nonatomic, readonly, copy) NSString *lastFourDigits;
@property (nonatomic, readonly, copy) NSString *nameOnCard;
@property (nonatomic, readonly, copy) NSString *nickname;
@property (nonatomic, readonly) NSInteger expirationMonth;
@property (nonatomic, readonly) NSInteger expirationYear;
@property (nonatomic, readonly) BOOL isExpired;
@property (nonatomic, readonly) BOOL hasSecurityCode;
@end

/// The payment cards Chrome fills forms with, for the window's profile. Changes come as
/// `windowDidChangePaymentCards:`.
NS_SWIFT_UI_ACTOR
@protocol BEWindowPaymentCards <NSObject>
@optional
/// Empty until loaded.
@property (nonatomic, readonly, copy) NSArray<id<BEPaymentCard>> *paymentCards;
/// Chrome's "Verify it's you": macOS asks before a card's number shows or fills.
@property (nonatomic, readonly) BOOL paymentCardsNeedAuthentication;
/// The whole number and security code, after macOS asks who it is if they need it; nil if
/// refused.
- (void)revealPaymentCard:(NSString *)identifier
               completion:(void (^)(NSString *_Nullable number, NSString *_Nullable securityCode))completion;
/// A new card (nil) or a change; its identifier, or nil if the number, month, year or nickname
/// isn't valid.
- (nullable NSString *)savePaymentCard:(nullable NSString *)identifier
                                number:(NSString *)number
                            nameOnCard:(NSString *)name
                       expirationMonth:(NSInteger)month
                        expirationYear:(NSInteger)year
                              nickname:(NSString *)nickname
                          securityCode:(NSString *)securityCode;
- (void)removePaymentCard:(NSString *)identifier;
- (void)removeAllSecurityCodes;
/// After macOS asks who it is; `changed` NO if refused.
- (void)setPaymentCardsNeedAuthentication:(BOOL)needed completion:(void (^)(BOOL changed))completion;
@end

NS_SWIFT_UI_ACTOR
@protocol BEWindowDelegateAutofill <NSObject>
@optional
/// Passwords or never-saved sites were added, changed or removed, here or elsewhere.
- (void)windowDidChangePasswords:(id<BEWindow>)window NS_SWIFT_NAME(windowDidChangePasswords(_:));
- (void)windowDidChangeAddresses:(id<BEWindow>)window NS_SWIFT_NAME(windowDidChangeAddresses(_:));
- (void)windowDidChangePaymentCards:(id<BEWindow>)window NS_SWIFT_NAME(windowDidChangePaymentCards(_:));
@end

// MARK: The DevTools protocol for the app, and agents' tabs (13 Nov 2026)

/// What a DevTools session may do beyond reading and driving its page.
typedef NS_OPTIONS(NSUInteger, BEDevToolsAccess) {
    /// Chrome's "trusted" client: may list and make targets (a browser session needs it), and its
    /// key events reach the browser's own shortcuts. Never for an agent's tab session: an agent
    /// typing ⌘W would close the tab.
    BEDevToolsAccessTrusted = 1 << 0,
    /// May attach to Chrome's own pages (chrome://, the app's own pages' documents).
    BEDevToolsAccessChromePages = 1 << 1,
    BEDevToolsAccessReadsFiles = 1 << 2,
    BEDevToolsAccessWritesFiles = 1 << 3,
};

/// A connection to a page's (or the browser's) DevTools agent, in the browser's own process: what
/// Chrome's DevTools front end and `--remote-debugging-pipe` speak, without a port, an approval
/// prompt, Chrome's automation infobar or `navigator.webdriver`. The app sends the protocol's JSON
/// messages and gets its replies and events back. (Chrome: `DevToolsAgentHost::AttachClient`)
NS_SWIFT_UI_ACTOR
@protocol BEDevToolsSession <NSObject>
/// The target it's attached to (Chrome's target id).
@property (nonatomic, readonly, copy) NSString *targetIdentifier;
/// Replies and events, each one JSON message, on a later task.
@property (nonatomic, copy, nullable) void (^messageHandler)(NSData *json);
/// The target went away (its tab closed or was discarded), refused the session, or its page went
/// where the session's access doesn't reach (chrome:// without `ChromePages`); once, on a later
/// task.
@property (nonatomic, copy, nullable) void (^closeHandler)(void);
@property (nonatomic, readonly) BOOL isAttached;
/// One protocol message: `{"id": 1, "method": "Page.navigate", "params": {…}}`, with `sessionId`
/// for a child session.
- (void)sendMessage:(NSData *)json;
/// Detaches; the handlers aren't called again.
- (void)close;
@end

NS_SWIFT_UI_ACTOR
@protocol BETabDevTools <NSObject>
@optional
/// The tab's target, stable while its page lives (prerendering and replaced documents included);
/// a discarded tab's page comes back with a new one.
@property (nonatomic, readonly, copy, nullable) NSString *devToolsTargetIdentifier;
/// A session on the tab's target, which has only the Target, IO and Tracing domains: the page is
/// reached with `Target.setAutoAttach` `{"autoAttach": true, "waitForDebuggerOnStart": false,
/// "flatten": true}` and the `sessionId` of each `Target.attachedToTarget` (again for a page
/// swapped in). Nil if the tab has no page now. Several can be open at once (Chrome's own DevTools
/// beside it).
- (nullable id<BEDevToolsSession>)openDevToolsSessionWithAccess:(BEDevToolsAccess)access
    NS_SWIFT_NAME(openDevToolsSession(access:));
/// While an agent works in the tab: it renders, runs its timers and takes input as if in front,
/// though hidden; isn't discarded; and its pop-up menus don't open on screen. (Chrome: what its
/// own agent framework does to a tab it acts on.)
- (void)setAgentActive:(BOOL)active;
/// The storage an agent's tab keeps to (`BEWindowAgentTabs`); nil for the profile's own.
@property (nonatomic, readonly, copy, nullable) NSString *storagePartition;
@end

NS_SWIFT_UI_ACTOR
@protocol BEEngineDevTools <NSObject>
@optional
/// A session on the browser itself (every target, made and closed through the protocol's Target
/// domain): what an external tool such as Playwright needs. Nil before Chromium has started.
- (nullable id<BEDevToolsSession>)openBrowserDevToolsSessionWithAccess:(BEDevToolsAccess)access
    NS_SWIFT_NAME(openBrowserDevToolsSession(access:));
/// The tab of a target, if it's a tab's.
- (nullable id<BETab>)tabForDevToolsTarget:(NSString *)targetIdentifier;
@end

/// Tabs for agents, in the user's window but with storage of their own: their cookies, local
/// storage and cache are kept apart from the profile's and from other agents', and stay signed in
/// across launches unless kept in memory. Every tab one opens (a link in a new tab,
/// `window.open`) keeps to its storage. Agents' tabs aren't saved with the session, aren't
/// discarded, and don't add to the profile's history.
NS_SWIFT_UI_ACTOR
@protocol BEWindowAgentTabs <NSObject>
@optional
/// A new tab at the end of the window showing `url` in `partition`'s storage (a name the app
/// makes, the same for every tab of one agent); selected only if `select`. Nil if it couldn't be
/// made, and for Chrome's own pages (chrome://, extensions'), which keep to the profile's storage.
- (nullable id<BETab>)openTabWithURL:(NSURL *)url
                    storagePartition:(NSString *)partition
                            inMemory:(BOOL)inMemory
                              select:(BOOL)select;
/// Deletes what `partition` stored in the window's profile (an agent deleted; its tabs closed
/// first); `completion` on a later task.
- (void)deleteStoragePartition:(NSString *)partition completion:(void (^)(void))completion;
@end

NS_ASSUME_NONNULL_END
