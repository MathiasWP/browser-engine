// Split view for the app (BEWindowSplits): two tabs shown at once, kept as
// Chrome's own split tabs, so its sessions save them, session restore and ⇧⌘T
// bring them back, and its tab strip model keeps the pair together. The app
// draws the panes; Chrome's MultiContentsView isn't in our windows.

#import "browser_engine/be_window.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/strings/sys_string_conversions.h"
#import "browser_engine/be_tab.h"
#include "chrome/browser/ui/tabs/split_tab_metrics.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/split_tabs/split_tab_id.h"
#include "components/split_tabs/split_tab_visual_data.h"
#include "components/tabs/public/split_tab_data.h"
#include "components/tabs/public/tab_interface.h"

namespace {

// Each pane keeps at least a tenth, as Chrome's divider does
// (MultiContentsView's minimum).
constexpr double kMinimumRatio = 0.1;

}  // namespace

// What the app sees of a split: a copy of it when `tabSplits` was read.
@interface BEChromiumTabSplit : NSObject <BETabSplit>
- (instancetype)initWithSplit:(const split_tabs::SplitTabData&)split
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumTabSplit

@synthesize identifier = _identifier;
@synthesize tabs = _tabs;
@synthesize ratio = _ratio;
@synthesize isStacked = _isStacked;

- (instancetype)initWithSplit:(const split_tabs::SplitTabData&)split {
  if ((self = [super init])) {
    _identifier = base::SysUTF8ToNSString(split.id().ToString());
    // In strip order: the start pane's tab first.
    NSMutableArray<id<BETab>>* tabs = [NSMutableArray array];
    for (tabs::TabInterface* tab : split.ListTabs()) {
      [tabs addObject:[BEChromiumTab tabForTab:tab]];
    }
    _tabs = tabs;
    _ratio = split.visual_data()->split_ratio();
    _isStacked = split.visual_data()->split_layout() ==
                 split_tabs::SplitTabLayout::kStacked;
  }
  return self;
}

@end

@interface BEChromiumWindow (Splits) <BEWindowSplits>
@end

@implementation BEChromiumWindow (Splits)

// One of this window's splits, if `identifier` names one. Chrome CHECKs on a
// split it doesn't have, so every call looks first.
- (std::optional<split_tabs::SplitTabId>)splitWithIdentifier:
    (NSString*)identifier {
  TabStripModel* model = [self tabStripModel];
  if (!model || !identifier) {
    return std::nullopt;
  }
  const std::string wanted = base::SysNSStringToUTF8(identifier);
  for (const split_tabs::SplitTabId& split : model->ListSplits()) {
    if (split.ToString() == wanted) {
      return split;
    }
  }
  return std::nullopt;
}

- (NSArray<id<BETabSplit>>*)tabSplits {
  TabStripModel* model = [self tabStripModel];
  if (!model) {
    return @[];
  }
  // ListSplits() is ordered by id; the app wants them as the strip has them.
  std::vector<std::pair<uint32_t, split_tabs::SplitTabData*>> splits;
  for (const split_tabs::SplitTabId& id : model->ListSplits()) {
    if (split_tabs::SplitTabData* split = model->GetSplitData(id)) {
      splits.emplace_back(split->GetIndexRange().start(), split);
    }
  }
  std::ranges::sort(splits, {},
                    &std::pair<uint32_t, split_tabs::SplitTabData*>::first);
  NSMutableArray<id<BETabSplit>>* result = [NSMutableArray array];
  for (const auto& [start, split] : splits) {
    [result addObject:[[BEChromiumTabSplit alloc] initWithSplit:*split]];
  }
  return result;
}

- (NSString*)splitTabAtIndex:(NSInteger)index
              withTabAtIndex:(NSInteger)other
                     atStart:(BOOL)atStart {
  TabStripModel* model = [self tabStripModel];
  // Chrome CHECKs rather than refusing (a tab already split, an index that
  // isn't one), so this refuses first.
  if (!model || index == other || !model->ContainsIndex(index) ||
      !model->ContainsIndex(other) || model->GetSplitForTab(index) ||
      model->GetSplitForTab(other)) {
    return nil;
  }
  tabs::TabInterface* joining = model->GetTabAtIndex(other);
  // The tab at `index` is the pivot: the split takes its place, group and pin.
  const split_tabs::SplitTabId split = model->AddToNewSplit(
      {static_cast<int>(index), static_cast<int>(other)},
      split_tabs::SplitTabVisualData(split_tabs::SplitTabLayout::kSideBySide),
      split_tabs::SplitTabCreatedSource::kDragAndDropTab);
  // The joining tab on the side the app asked for.
  if (split_tabs::SplitTabData* data = model->GetSplitData(split)) {
    const std::vector<tabs::TabInterface*> tabs = data->ListTabs();
    if (!tabs.empty() &&
        (tabs.front() == joining) != static_cast<bool>(atStart)) {
      model->ReverseTabsInSplit(split);
    }
  }
  return base::SysUTF8ToNSString(split.ToString());
}

- (void)setTabSplit:(NSString*)identifier ratio:(double)ratio final:(BOOL)final {
  const std::optional<split_tabs::SplitTabId> split =
      [self splitWithIdentifier:identifier];
  if (!split) {
    return;
  }
  // While dragging, Chrome's session leaves the ratio unsaved
  // (SessionServiceBrowserHelper skips intermediate changes).
  [self tabStripModel]->UpdateSplitRatio(
      *split, std::clamp(ratio, kMinimumRatio, 1 - kMinimumRatio),
      /*is_intermediate=*/!final);
}

- (void)setTabSplit:(NSString*)identifier stacked:(BOOL)stacked {
  const std::optional<split_tabs::SplitTabId> split =
      [self splitWithIdentifier:identifier];
  if (!split) {
    return;
  }
  [self tabStripModel]->UpdateSplitLayout(
      *split, stacked ? split_tabs::SplitTabLayout::kStacked
                      : split_tabs::SplitTabLayout::kSideBySide);
}

- (void)reverseTabSplit:(NSString*)identifier {
  const std::optional<split_tabs::SplitTabId> split =
      [self splitWithIdentifier:identifier];
  if (split) {
    [self tabStripModel]->ReverseTabsInSplit(*split);
  }
}

- (void)unsplitTabSplit:(NSString*)identifier {
  const std::optional<split_tabs::SplitTabId> split =
      [self splitWithIdentifier:identifier];
  if (split) {
    [self tabStripModel]->RemoveSplit(*split);
  }
}

@end
