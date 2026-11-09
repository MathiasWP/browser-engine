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

NS_ASSUME_NONNULL_END
