// The BEPreferences the app holds: Chrome's preferences (PrefService) of the
// everyday profile, and Local State's for names the profile doesn't have.

#ifndef BROWSER_ENGINE_BE_PREFERENCES_H_
#define BROWSER_ENGINE_BE_PREFERENCES_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngine.h"

NS_ASSUME_NONNULL_BEGIN

// Keeps no PrefService: every call finds the everyday profile again (the one
// -[BEEngine dataFolder] is), so it follows a switch of profile, and finds no
// preferences once Chromium has quit.
@interface BEChromiumPreferences : NSObject <BEPreferences>
@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_PREFERENCES_H_
