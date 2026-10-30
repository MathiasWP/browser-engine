// BEEngine: how the app starts and drives Chromium (public/BEEngine.h), and
// the hooks Chromium's touch points call (browser_engine_hooks.h).

#ifndef BROWSER_ENGINE_BE_ENGINE_H_
#define BROWSER_ENGINE_BE_ENGINE_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngine.h"

// The framework's one exported function (listed in chrome/app/framework.exports
// by patches/browser_engine/). Nil unless `apiVersion` is BE_API_VERSION.
extern "C" __attribute__((visibility("default"))) id<BEEngine> _Nullable
BEEngineCreate(NSInteger apiVersion);

namespace browser_engine {

// The delegate the app passed to -runWithArguments:delegate:, while Chromium
// runs; nil otherwise.
id<BEEngineDelegate> _Nullable GetEngineDelegate();

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_ENGINE_H_
