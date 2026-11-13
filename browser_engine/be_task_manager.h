// Chrome's Task Manager for the app's own window (BETaskManager): the
// process-wide task_manager::TaskManagerInterface, observed while the app
// shows it, as Chrome's Task Manager window observes it (TaskManagerTableModel)
// but with numbers rather than Chrome's strings, for the app to format.

#ifndef BROWSER_ENGINE_BE_TASK_MANAGER_H_
#define BROWSER_ENGINE_BE_TASK_MANAGER_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngineOptional.h"

NS_ASSUME_NONNULL_BEGIN

// Measures every two seconds from -init until -close or dealloc. While any is
// open Chrome samples every process and the network service counts each
// one's traffic, so the app keeps one only while its window shows. On the UI
// thread, once Chromium runs (-[BEChromiumEngine openTaskManager]).
@interface BEChromiumTaskManager : NSObject <BETaskManager>
- (instancetype)init NS_DESIGNATED_INITIALIZER;
@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_TASK_MANAGER_H_
