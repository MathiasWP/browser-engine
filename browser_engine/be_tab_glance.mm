// Tab hover cards for the app (BETabGlance): a picture of the page, the memory
// it uses and when it was last shown, from Chrome's own hover card machinery
// (ThumbnailTabHelper, TabResourceUsageTabHelper), so the app's card shows what
// Chrome's would.

#import "browser_engine/be_tab.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include <memory>
#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/ui/performance_controls/tab_resource_usage_collector.h"
#include "chrome/browser/ui/performance_controls/tab_resource_usage_tab_helper.h"
#include "chrome/browser/ui/thumbnails/thumbnail_image.h"
#include "chrome/browser/ui/thumbnails/thumbnail_tab_helper.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_util_mac.h"

namespace {

// Runs `done` once Chrome has measured the tabs' memory again, or after two
// seconds if it doesn't; then deletes itself.
class MemoryMeasure : public TabResourceUsageCollector::Observer {
 public:
  explicit MemoryMeasure(base::OnceClosure done) : done_(std::move(done)) {
    observation_.Observe(TabResourceUsageCollector::Get());
    base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&MemoryMeasure::Finish, weak_factory_.GetWeakPtr()),
        base::Seconds(2));
  }

  void OnTabResourceMetricsRefreshed() override { Finish(); }

 private:
  void Finish() {
    observation_.Reset();
    base::OnceClosure done = std::move(done_);
    delete this;
    std::move(done).Run();
  }

  base::OnceClosure done_;
  base::ScopedObservation<TabResourceUsageCollector,
                          TabResourceUsageCollector::Observer>
      observation_{this};
  base::WeakPtrFactory<MemoryMeasure> weak_factory_{this};
};

}  // namespace

// While the app watches a tab's pictures: Chrome's subscription to them, which
// keeps a hidden page drawn for its picture while it lasts.
@interface BEThumbnailObservation : NSObject
- (instancetype)initWithImage:(scoped_refptr<ThumbnailImage>)image
                    pixelSize:(NSSize)pixelSize
                      handler:(void (^)(NSImage*))handler;
@end

@implementation BEThumbnailObservation {
  scoped_refptr<ThumbnailImage> _image;
  std::unique_ptr<ThumbnailImage::Subscription> _subscription;
}

- (instancetype)initWithImage:(scoped_refptr<ThumbnailImage>)image
                    pixelSize:(NSSize)pixelSize
                      handler:(void (^)(NSImage*))handler {
  if ((self = [super init])) {
    _image = std::move(image);
    _subscription = _image->Subscribe();
    if (pixelSize.width > 0 && pixelSize.height > 0) {
      _subscription->SetSizeHint(
          gfx::Size(static_cast<int>(pixelSize.width),
                    static_cast<int>(pixelSize.height)));
    }
    void (^copied)(NSImage*) = [handler copy];
    // On the UI thread, once decoded off it.
    _subscription->SetUncompressedImageCallback(
        base::BindRepeating(^(gfx::ImageSkia picture) {
          if (picture.isNull()) {
            return;
          }
          if (NSImage* shown = gfx::NSImageFromImageSkia(picture)) {
            copied(shown);
          }
        }));
    // The kept picture at once, if there is one; a fresh one is on its way.
    _image->RequestThumbnailImage();
  }
  return self;
}

@end

@interface BEChromiumTab (Glance) <BETabGlance>
@end

@implementation BEChromiumTab (Glance)

static const void* const kThumbnailObservationKey = &kThumbnailObservationKey;

- (BOOL)observeThumbnailWithPixelSize:(NSSize)pixelSize
                              handler:(void (^)(NSImage*))handler {
  // A new handler replaces the last; nil just stops.
  objc_setAssociatedObject(self, kThumbnailObservationKey, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  tabs::TabInterface* tab = [self tab];
  ThumbnailTabHelper* helper = tab ? ThumbnailTabHelper::From(tab) : nullptr;
  if (!helper || !helper->thumbnail()) {
    return NO;
  }
  if (handler) {
    BEThumbnailObservation* observation =
        [[BEThumbnailObservation alloc] initWithImage:helper->thumbnail()
                                            pixelSize:pixelSize
                                              handler:handler];
    objc_setAssociatedObject(self, kThumbnailObservationKey, observation,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return YES;
}

- (uint64_t)memoryUsage {
  tabs::TabInterface* tab = [self tab];
  TabResourceUsageTabHelper* usage =
      tab ? TabResourceUsageTabHelper::From(tab) : nullptr;
  return usage ? usage->GetMemoryUsage().InBytes() : 0;
}

- (void)measureMemoryUsage:(void (^)(uint64_t))completion {
  content::WebContents* contents = [self contents];
  void (^copied)(uint64_t) = [completion copy];
  if (!contents || !TabResourceUsageCollector::Get()) {
    copied([self memoryUsage]);
    return;
  }
  __weak BEChromiumTab* weakSelf = self;
  new MemoryMeasure(base::BindOnce(^{
    copied([weakSelf memoryUsage]);
  }));
  TabResourceUsageCollector::Get()->ImmediatelyRefreshMetrics(contents);
}

- (NSDate*)lastActiveDate {
  content::WebContents* contents = [self contents];
  return contents ? contents->GetLastActiveTime().ToNSDate() : nil;
}

@end
