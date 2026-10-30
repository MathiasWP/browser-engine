// The BEWindow the app holds: one Chrome Browser and our BrowserWindow for it.
// Commands go to Chrome's command ids; the tab strip's changes come back out
// through the window's delegate.

#ifndef BROWSER_ENGINE_BE_WINDOW_H_
#define BROWSER_ENGINE_BE_WINDOW_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngine.h"

class TabStripModelChange;
struct TabStripSelectionChange;

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
// The window is going: tells the delegate, then forgets the C++ window. Every
// method is a no-op afterwards.
- (void)browserWindowWillClose;

@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_WINDOW_H_
