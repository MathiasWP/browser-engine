// The BETab the app holds: one Chrome tab (tabs::TabInterface), found again
// through its TabHandle, so it stays the same object for the tab's whole life,
// across windows and across discarding (which swaps the tab's WebContents).

#ifndef BROWSER_ENGINE_BE_TAB_H_
#define BROWSER_ENGINE_BE_TAB_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngine.h"

namespace tabs {
class TabInterface;
}  // namespace tabs

NS_ASSUME_NONNULL_BEGIN

@interface BEChromiumTab : NSObject <BETab>

// The object for `tab`, made the first time it's asked for.
+ (BEChromiumTab*)tabForTab:(tabs::TabInterface*)tab;
// The object for `tab` if there is one already (nil for a null `tab`).
+ (nullable BEChromiumTab*)existingTabForTab:(nullable tabs::TabInterface*)tab;
// Drops the object for a tab Chrome is deleting.
+ (void)forgetTab:(tabs::TabInterface*)tab;

- (instancetype)init NS_UNAVAILABLE;

// The tab's WebContents was replaced (discard, prerender): watch the new one.
- (void)contentsDidChange;
// Tells the delegate tabDidUpdate: soon, at most once per task.
- (void)scheduleUpdate;

@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_TAB_H_
