// The BEWindow the app holds: one Chrome Browser and our BrowserWindow for it.
// Commands go to Chrome's command ids; the tab strip's changes come back out
// through the window's delegate.

#ifndef BROWSER_ENGINE_BE_WINDOW_H_
#define BROWSER_ENGINE_BE_WINDOW_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngine.h"

class TabStripModelChange;
struct TabStripSelectionChange;

namespace tab_groups {
class TabGroupId;
}  // namespace tab_groups

namespace browser_engine {
class BEBrowserWindow;
}  // namespace browser_engine

NS_ASSUME_NONNULL_BEGIN

@interface BEChromiumWindow : NSObject <BEWindow>

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

// Called by browser_engine::BEAutocomplete.

// New suggestions for the text last given to
// suggestForText:allowsInlineCompletion:.
- (void)suggestionsDidUpdate:(NSArray<id<BESuggestion>>*)suggestions;

// Called by browser_engine::BEExtensions.

// What an extension's button shows may have changed, or which buttons there
// are, or the active tab. On a later task, at most once per task, tells the
// delegate windowDidUpdateExtensionActions:.
- (void)extensionActionsDidChange;

@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_WINDOW_H_
