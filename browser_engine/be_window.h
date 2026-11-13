// The BEWindow the app holds: one Chrome Browser and our BrowserWindow for it.
// Commands go to Chrome's command ids; the tab strip's changes come back out
// through the window's delegate.

#ifndef BROWSER_ENGINE_BE_WINDOW_H_
#define BROWSER_ENGINE_BE_WINDOW_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngine.h"
#import "browser_engine/public/BEEngineOptional.h"

#include <optional>

class BrowserWindowInterface;
class TabStripModel;
class TabStripModelChange;
struct TabStripSelectionChange;

namespace tab_groups {
class TabGroupId;
}  // namespace tab_groups

namespace browser_engine {
class BEAutofillData;
class BEBookmarkBar;
class BEExtensionsManager;
class BEHistory;
class BEImport;
class BEPasswordsData;
class BESettingsData;
class BEBrowserWindow;
}  // namespace browser_engine

NS_ASSUME_NONNULL_BEGIN

@interface BEChromiumWindow
    : NSObject <BEWindow, BEWindowPreloading, BEWindowReadingList, BEWindowOpening>

- (instancetype)initWithBrowserWindow:(browser_engine::BEBrowserWindow*)window
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// Called by BEBrowserWindow.

// Hands the window to the engine delegate (engineDidCreateWindow:).
- (void)announce;
// The tab strip changed: tabs inserted, removed, moved or replaced, and maybe
// the active tab.
- (void)tabStripModelChanged:(const TabStripModelChange&)change
                   selection:(const TabStripSelectionChange&)selection;
// Chrome refreshed what it shows for the active tab (toolbar, title bar,
// security state).
- (void)activeTabDidChange;
// Chrome wants the address field focused.
- (void)wantsLocationFocus;
// Where the app's star is now, in the window's coordinates; empty without one.
- (NSRect)bookmarkButtonRect;
// Chrome's fullscreen state changed, a page's or the window's. On a later
// task, tells the delegate windowDidChangePageFullscreen: if isPageFullscreen
// is no longer what it last heard.
- (void)fullscreenStateDidChange;
// After a crash, Chrome would show its session-crashed bubble ("Restore
// pages?") on this window. Offers the restore until the app answers or the
// window closes, keeping the crash unacknowledged as the open bubble does, and
// tells the delegate windowDidChangeRestoreOffer: on a later task.
- (void)offerRestoreAfterCrash;
// Whether the bookmarks bar shows may have changed. On a later task, tells
// the delegate windowDidChangeBookmarkBar: if showsBookmarkBar is no longer
// what it last heard.
- (void)bookmarkBarStateDidChange;
// The status bubble's text changed (BEBrowserWindow::GetStatusText()). On a
// later task, tells the delegate windowDidChangeStatus: if statusText is no
// longer what it last heard.
- (void)statusTextDidChange;
// The window is going: tells the delegate, then forgets the C++ window. Every
// method is a no-op afterwards.
- (void)browserWindowWillClose;
// A tab group was made, closed, moved or changed how it looks. On a later
// task, at most once per task, tells the delegate windowDidChangeTabGroups:.
- (void)tabGroupsDidChange;
// Chrome wants `group`'s editor shown (OpenTabGroupEditor()). On a later task,
// after the groups' update, asks the delegate to show it.
- (void)wantsEditorForTabGroup:(const tab_groups::TabGroupId&)group;
// A split was made, changed or ended. On a later task, at most once per task,
// tells the delegate windowDidChangeTabSplits: (be_window_splits.mm).
- (void)tabSplitsDidChange;

// Called by browser_engine::BEAutocomplete.

// New suggestions for the text last given to
// suggestForText:allowsInlineCompletion:.
- (void)suggestionsDidUpdate:(NSArray<id<BESuggestion>>*)suggestions;

// Called by browser_engine::BEExtensions.

// What an extension's button shows may have changed, or which buttons there
// are, or the active tab. On a later task, at most once per task, tells the
// delegate windowDidUpdateExtensionActions:.
- (void)extensionActionsDidChange;

// For the window's categories (be_window_native_ui.mm).

// The browser and its tab strip while the window is open, or null.
- (nullable BrowserWindowInterface*)browser;
- (nullable TabStripModel*)tabStripModel;
// One of this window's groups, if `identifier` names one.
- (std::optional<tab_groups::TabGroupId>)groupWithIdentifier:
    (NSString*)identifier;
// The bookmarks bar's controller, made on first use; null once closed.
- (nullable browser_engine::BEBookmarkBar*)bookmarkBar;
// The history page's data, made on first use; null once closed.
- (nullable browser_engine::BEHistory*)history;
// Settings' own pages' data, made on first use; null once closed.
- (nullable browser_engine::BESettingsData*)settingsData;
// The app's extensions page, passwords, addresses and cards, and importing:
// each made on first use, for the window's profile; null once closed.
- (nullable browser_engine::BEExtensionsManager*)extensionsManager;
- (nullable browser_engine::BEPasswordsData*)passwordsData;
- (nullable browser_engine::BEAutofillData*)autofillData;
- (nullable browser_engine::BEImport*)importer;

@end

// The app's own UI in place of Chrome's (be_window_native_ui.mm).

// What Chrome asks of a bookmark editor, for the app's.
@interface BEChromiumBookmarkEditRequest : NSObject <BEBookmarkEditRequest>
- (instancetype)initWithKind:(BEBookmarkEditKind)kind
                    bookmark:(int64_t)bookmark
                      folder:(int64_t)folder
                       index:(NSInteger)index
                         url:(nullable NSURL*)url
                       title:(NSString*)title
                        urls:(NSArray<NSURL*>*)urls
                   urlTitles:(NSArray<NSString*>*)urlTitles
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// The app's own pages in place of Chrome's settings and extensions pages, each
// in its own file.

// be_extensions_manager.mm
@interface BEChromiumWindow (ExtensionsManager) <BEWindowExtensionsManager>
@end

// be_passwords_data.mm
@interface BEChromiumWindow (Passwords) <BEWindowPasswords>
@end

// be_autofill_data.mm
@interface BEChromiumWindow (Autofill) <BEWindowAddresses, BEWindowPaymentCards>
@end

// be_import.mm
@interface BEChromiumWindow (Import) <BEWindowImport>
@end

// be_agent_tabs.mm: agents' tabs, with storage of their own.
@interface BEChromiumWindow (AgentTabs) <BEWindowAgentTabs>
@end

@interface BEChromiumWindow (NativeUI) <BEWindowBookmarkEditing,
                                        BEWindowTabCommands,
                                        BEWindowFind,
                                        BEWindowHistory,
                                        BEWindowBrowsingData,
                                        BEWindowSearchEngines,
                                        BEWindowSiteZoom>
// Each asks the delegate in place of Chrome's UI; NO when the delegate shows
// none, and Chrome's should.
- (BOOL)showBookmarkEditor:(BEChromiumBookmarkEditRequest*)request;
- (BOOL)confirmClosingWithDownloads:(NSInteger)count
                           quitting:(BOOL)quitting
                         completion:(void (^)(BOOL closeAnyway))completion;
- (BOOL)showFullscreenNotice:(NSString*)text;
// Whether the delegate draws the find bar (then it hears every find).
- (BOOL)drawsFindBar;
- (void)showFindBarWithText:(NSString*)text;
- (void)hideFindBar;
- (void)didFindMatch:(NSInteger)current of:(NSInteger)total final:(BOOL)final;
@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_WINDOW_H_
