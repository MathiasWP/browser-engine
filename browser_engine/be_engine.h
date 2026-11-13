// BEEngine: how the app starts and drives Chromium (public/BEEngine.h), and
// the hooks Chromium's touch points call (browser_engine_hooks.h).

#ifndef BROWSER_ENGINE_BE_ENGINE_H_
#define BROWSER_ENGINE_BE_ENGINE_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngine.h"
#import "browser_engine/public/BEEngineOptional.h"

namespace browser_engine {
class BEProfiles;
}  // namespace browser_engine

NS_ASSUME_NONNULL_BEGIN

// The engine the app holds: be_engine.mm, with parts in other files.
@interface BEChromiumEngine : NSObject <BEEngine, BEEnginePalette>
// The app's delegate while Chromium runs.
@property(nonatomic, readonly, nullable) id<BEEngineDelegate> delegate;
// The profile list, once Chromium has started; null before.
- (nullable browser_engine::BEProfiles*)profilesModel;
@end

// be_task_manager.mm
@interface BEChromiumEngine (TaskManager) <BEEngineTaskManager>
@end

// be_engine_profiles.mm
@interface BEChromiumEngine (Profiles) <BEEngineProfiles>
@end

// be_devtools_session.mm
@interface BEChromiumEngine (DevTools) <BEEngineDevTools>
@end

NS_ASSUME_NONNULL_END

// The framework's one exported function (listed in chrome/app/framework.exports
// by patches/browser_engine/). Nil unless `apiVersion` is BE_API_VERSION.
extern "C" __attribute__((visibility("default"))) id<BEEngine> _Nullable
BEEngineCreate(NSInteger apiVersion);

namespace browser_engine {

// The delegate the app passed to -runWithArguments:delegate:, while Chromium
// runs; nil otherwise.
id<BEEngineDelegate> _Nullable GetEngineDelegate();
// The engine the app holds, for the delegate's calls.
id<BEEngine> _Nonnull GetEngine();

// One of our windows became the active one, and Chrome made its profile the
// last used: the menus' lists follow it, as Chrome's do.
void OnWindowActivated();

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_ENGINE_H_
