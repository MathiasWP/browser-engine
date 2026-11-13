#import "browser_engine/be_task_manager.h"

#import <AppKit/AppKit.h>

#include <map>
#include <memory>
#include <optional>
#include <utility>

#include "base/byte_size.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#import "browser_engine/be_engine.h"
#import "browser_engine/be_tab.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/task_manager/providers/task.h"
#include "chrome/browser/task_manager/task_manager_interface.h"
#include "chrome/browser/task_manager/task_manager_observer.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_util_mac.h"

NS_ASSUME_NONNULL_BEGIN

// One line of the Task Manager as measured: a copy, which doesn't change.
@interface BEChromiumTask : NSObject <BETask>
- (instancetype)initWithIdentifier:(int64_t)identifier
                             title:(NSString*)title
                              icon:(nullable NSImage*)icon
                              kind:(BETaskKind)kind
                  isTabOrExtension:(BOOL)isTabOrExtension
                       profileName:(NSString*)profileName
                 processIdentifier:(int32_t)processIdentifier
                          cpuUsage:(double)cpuUsage
                   memoryFootprint:(int64_t)memoryFootprint
                      networkUsage:(int64_t)networkUsage
                            canEnd:(BOOL)canEnd NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumTask

@synthesize identifier = _identifier;
@synthesize title = _title;
@synthesize icon = _icon;
@synthesize kind = _kind;
@synthesize isTabOrExtension = _isTabOrExtension;
@synthesize profileName = _profileName;
@synthesize processIdentifier = _processIdentifier;
@synthesize cpuUsage = _cpuUsage;
@synthesize memoryFootprint = _memoryFootprint;
@synthesize networkUsage = _networkUsage;
@synthesize canEnd = _canEnd;

- (instancetype)initWithIdentifier:(int64_t)identifier
                             title:(NSString*)title
                              icon:(NSImage*)icon
                              kind:(BETaskKind)kind
                  isTabOrExtension:(BOOL)isTabOrExtension
                       profileName:(NSString*)profileName
                 processIdentifier:(int32_t)processIdentifier
                          cpuUsage:(double)cpuUsage
                   memoryFootprint:(int64_t)memoryFootprint
                      networkUsage:(int64_t)networkUsage
                            canEnd:(BOOL)canEnd {
  if ((self = [super init])) {
    _identifier = identifier;
    _title = [title copy];
    _icon = icon;
    _kind = kind;
    _isTabOrExtension = isTabOrExtension;
    _profileName = [profileName copy];
    _processIdentifier = processIdentifier;
    _cpuUsage = cpuUsage;
    _memoryFootprint = memoryFootprint;
    _networkUsage = networkUsage;
    _canEnd = canEnd;
  }
  return self;
}

@end

namespace browser_engine {

namespace {

using task_manager::Task;
using task_manager::TaskId;
using task_manager::TaskManagerInterface;

// As Chrome's window: every two seconds, with its default columns' numbers
// (TaskManagerTableModel's kRefreshTime, and the CPU, memory footprint and
// network columns).
constexpr base::TimeDelta kRefreshTime = base::Seconds(2);
constexpr int64_t kRefreshTypes = task_manager::REFRESH_TYPE_CPU |
                                  task_manager::REFRESH_TYPE_MEMORY_FOOTPRINT |
                                  task_manager::REFRESH_TYPE_NETWORK_USAGE;

// ShouldKeepTaskForTabsAndExtensions() in task_manager_table_model.cc: the
// tasks of Chrome's "Tabs & extensions", the rest being "System".
bool IsTabOrExtension(Task::Type type, Task::SubType subtype) {
  switch (type) {
    case Task::RENDERER:
      // Spare and unknown renderers count as the browser's.
      return subtype == Task::SubType::kNoSubType;
    case Task::EXTENSION:
    case Task::GUEST:
      return true;
    default:
      return false;
  }
}

BETaskKind Kind(Task::Type type, Task::SubType subtype, bool has_parent) {
  switch (type) {
    case Task::BROWSER:
      return BETaskKindBrowser;
    case Task::GPU:
      return BETaskKindGPU;
    case Task::UTILITY:
    case Task::ZYGOTE:
    case Task::SANDBOX_HELPER:
      return BETaskKindUtility;
    case Task::RENDERER:
      if (subtype != Task::SubType::kNoSubType) {
        return BETaskKindOther;
      }
      // A page's frames from other sites run in their own processes, each a
      // task under the tab's (SubframeTask).
      return has_parent ? BETaskKindSubframe : BETaskKindTab;
    case Task::EXTENSION:
      return BETaskKindExtension;
    case Task::DEDICATED_WORKER:
    case Task::SHARED_WORKER:
    case Task::SERVICE_WORKER:
      return BETaskKindWorker;
    default:
      return BETaskKindOther;
  }
}

}  // namespace

// Chrome's Task Manager observed: a TaskManagerObserver, as Chrome's table
// model is one. Every change runs `changed`, from inside the task manager's
// notifications; the lines are read on a later task (Snapshot()).
class BETaskManagerObserver : public task_manager::TaskManagerObserver {
 public:
  explicit BETaskManagerObserver(base::RepeatingClosure changed)
      : TaskManagerObserver(kRefreshTime, kRefreshTypes),
        changed_(std::move(changed)) {}
  BETaskManagerObserver(const BETaskManagerObserver&) = delete;
  BETaskManagerObserver& operator=(const BETaskManagerObserver&) = delete;
  ~BETaskManagerObserver() override {
    // While this is whole (the base class would too, later). The last
    // observer gone, Chrome stops measuring and forgets its tasks.
    if (TaskManagerInterface* manager = observed_task_manager()) {
      manager->RemoveObserver(this);
    }
  }

  // Starts observing. The first observer starts the task manager, which
  // measures at once and may call back from inside AddObserver(): so it comes
  // last, after everything the callbacks touch.
  void Start() { TaskManagerInterface::GetTaskManager()->AddObserver(this); }

  // The task manager while observed (null if it dropped this).
  TaskManagerInterface* manager() const { return observed_task_manager(); }

  // Every task as measured last, the browser first, then by process (the
  // task manager's order, which keeps a process's tasks together).
  NSArray<id<BETask>>* Snapshot() {
    TaskManagerInterface* manager = observed_task_manager();
    if (!manager) {
      return @[];
    }
    const bool end_enabled = TaskManagerInterface::IsEndProcessEnabled();
    // A copy: the task manager sorts its list again when it changes.
    const task_manager::TaskIdList ids = manager->GetTaskIdsList();
    NSMutableArray<id<BETask>>* tasks =
        [NSMutableArray arrayWithCapacity:ids.size()];
    for (const TaskId id : ids) {
      const Task::Type type = manager->GetType(id);
      const Task::SubType subtype = manager->GetSubType(id);
      // Chrome's categories go by the task at the root (a subframe's tab);
      // a task whose root went is in neither (crbug.com/396002122).
      const TaskId root = manager->GetRootTaskId(id);
      const bool tab_or_extension =
          manager->IsTaskValid(root) &&
          IsTabOrExtension(manager->GetType(root), manager->GetSubType(root));
      // Unknown until the first background pass.
      const std::optional<base::ByteSize> memory =
          manager->GetMemoryFootprintUsage(id);
      // The whole process's, as Chrome's network column shows it.
      const std::optional<base::ByteSize> network =
          manager->GetProcessTotalNetworkUsage(id);
      BEChromiumTask* task = [[BEChromiumTask alloc]
          initWithIdentifier:id
                       title:base::SysUTF16ToNSString(manager->GetTitle(id))
                        icon:Icon(manager, id)
                        kind:Kind(type, subtype, root != id)
            isTabOrExtension:tab_or_extension
                 profileName:base::SysUTF16ToNSString(
                                 manager->GetProfileName(id))
           processIdentifier:static_cast<int32_t>(manager->GetProcessId(id))
                    cpuUsage:manager->GetPlatformIndependentCPUUsage(id)
             memoryFootprint:memory ? static_cast<int64_t>(memory->InBytes())
                                    : -1
                networkUsage:network ? static_cast<int64_t>(network->InBytes())
                                     : -1
                      canEnd:end_enabled && manager->IsTaskKillable(id)];
      [tasks addObject:task];
    }
    return tasks;
  }

 private:
  // The task's icon (a tab's favicon, an extension's icon), made into an
  // NSImage once for each image the task has: the lines are made every
  // refresh, the icons rarely change.
  NSImage* Icon(TaskManagerInterface* manager, TaskId id) {
    const gfx::ImageSkia& icon = manager->GetIcon(id);
    if (icon.isNull()) {
      icons_.erase(id);
      return nil;
    }
    auto it = icons_.find(id);
    if (it == icons_.end() || !it->second.skia.BackedBySameObjectAs(icon)) {
      NSImage* image = gfx::NSImageFromImageSkia(icon);
      // Chrome tints these with the theme (TaskManagerTableModel::GetIcon()),
      // as AppKit tints a template image.
      [image setTemplate:manager->ShouldThemifyIcon(id)];
      it = icons_.insert_or_assign(id, CachedIcon{icon, image}).first;
    }
    return it->second.image;
  }

  // task_manager::TaskManagerObserver:
  void OnTaskAdded(TaskId id) override { changed_.Run(); }
  void OnTaskToBeRemoved(TaskId id) override {
    // Gone after this returns: not read again.
    icons_.erase(id);
    changed_.Run();
  }
  void OnTasksRefreshed(const task_manager::TaskIdList& task_ids) override {
    changed_.Run();
  }
  void OnTasksRefreshedWithBackgroundCalculations(
      const task_manager::TaskIdList& task_ids) override {
    // The memory footprint and CPU land here.
    changed_.Run();
  }

  struct CachedIcon {
    gfx::ImageSkia skia;
    NSImage* __strong image;
  };

  base::RepeatingClosure changed_;
  std::map<TaskId, CachedIcon> icons_;
};

}  // namespace browser_engine

@implementation BEChromiumTaskManager {
  // Null once closed.
  std::unique_ptr<browser_engine::BETaskManagerObserver> _observer;
  NSArray<id<BETask>>* _tasks;
  // A task to read the lines again is on its way.
  BOOL _updatePending;
}

@synthesize didChange = _didChange;

- (instancetype)init {
  if ((self = [super init])) {
    _tasks = @[];
    __weak BEChromiumTaskManager* weakSelf = self;
    _observer = std::make_unique<browser_engine::BETaskManagerObserver>(
        base::BindRepeating(^{
          [weakSelf tasksDidChange];
        }));
    _observer->Start();
    // The first measure starts with the task manager, so there are lines at
    // once (CPU and memory unknown until its background pass).
    _tasks = _observer->Snapshot();
  }
  return self;
}

- (void)dealloc {
  // Before the ivars go: the observer leaves the task manager.
  _observer.reset();
}

// From inside the task manager's notifications (several a refresh, and one
// a task added or removed): read once, on a task of our own.
- (void)tasksDidChange {
  if (_updatePending || !_observer) {
    return;
  }
  _updatePending = YES;
  __weak BEChromiumTaskManager* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        [weakSelf sendUpdate];
      }));
}

- (void)sendUpdate {
  _updatePending = NO;
  if (!_observer) {
    return;
  }
  _tasks = _observer->Snapshot();
  if (_didChange) {
    _didChange();
  }
}

// The task manager, if `identifier` is one of its tasks; null once closed. Any
// call with an id it doesn't have crashes (GetTaskGroupByTaskId()).
- (task_manager::TaskManagerInterface*)managerForTask:(int64_t)identifier {
  task_manager::TaskManagerInterface* manager =
      _observer ? _observer->manager() : nullptr;
  return manager && manager->IsTaskValid(identifier) ? manager : nullptr;
}

// MARK: BETaskManager

- (NSArray<id<BETask>>*)tasks {
  return _tasks;
}

- (void)activateTask:(int64_t)identifier {
  // A tab's task shows the tab, and its window (the tab's delegate's
  // ActivateContents()); others have nothing to show.
  if (task_manager::TaskManagerInterface* manager =
          [self managerForTask:identifier]) {
    manager->ActivateTask(identifier);
  }
}

- (BOOL)endTask:(int64_t)identifier {
  // Chrome's End process button: enabled for a killable task, unless policy
  // turned it off. It ends the whole process.
  task_manager::TaskManagerInterface* manager =
      [self managerForTask:identifier];
  if (!manager || !manager->IsTaskKillable(identifier) ||
      !task_manager::TaskManagerInterface::IsEndProcessEnabled()) {
    return NO;
  }
  return manager->KillTask(identifier);
}

- (int64_t)taskForTab:(id<BETab>)tab {
  task_manager::TaskManagerInterface* manager =
      _observer ? _observer->manager() : nullptr;
  if (!manager || ![(NSObject*)tab isKindOfClass:[BEChromiumTab class]]) {
    return -1;
  }
  content::WebContents* contents = [(BEChromiumTab*)tab contents];
  return contents ? manager->GetTaskIdForWebContents(contents) : -1;
}

- (void)close {
  _observer.reset();
}

@end

// MARK: BEEngineTaskManager

@implementation BEChromiumEngine (TaskManager)

- (id<BETaskManager>)openTaskManager {
  // Chromium runs: the browser process exists, startup finished (the
  // profiles model is made then, in -browserDidStart) and it isn't shutting
  // down. The task manager is the UI thread's, which the app calls on.
  if (!g_browser_process || ![self profilesModel] ||
      browser_shutdown::HasShutdownStarted()) {
    return nil;
  }
  return [[BEChromiumTaskManager alloc] init];
}

@end
