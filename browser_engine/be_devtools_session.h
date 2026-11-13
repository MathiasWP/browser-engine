// The DevTools protocol for the app (BEDevToolsSession): a client of a tab's
// or the browser's DevTools agent in the browser's own process, as Chrome's
// --remote-debugging-pipe is one (DevToolsPipeHandler), with no port, prompt,
// automation infobar or navigator.webdriver. The app sends the protocol's JSON
// and gets its replies and events back; it parses none of it here.

#ifndef BROWSER_ENGINE_BE_DEVTOOLS_SESSION_H_
#define BROWSER_ENGINE_BE_DEVTOOLS_SESSION_H_

#import <Foundation/Foundation.h>

#include "base/memory/scoped_refptr.h"
#import "browser_engine/public/BEEngineOptional.h"

namespace content {
class DevToolsAgentHost;
}  // namespace content

NS_ASSUME_NONNULL_BEGIN

// Attached from -init until -close, dealloc, or Chrome ending it (the target
// went, or it may no longer attach there), which the close handler hears once.
// On the UI thread.
@interface BEChromiumDevToolsSession : NSObject <BEDevToolsSession>
// Attaches to `host` with `access`. If Chrome refuses (policy, or a page the
// access doesn't cover), the session isn't attached and its close handler
// runs on a later task.
- (instancetype)initWithAgentHost:
                    (scoped_refptr<content::DevToolsAgentHost>)host
                           access:(BEDevToolsAccess)access
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_DEVTOOLS_SESSION_H_
