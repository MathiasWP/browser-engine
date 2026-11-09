// The app's own UI in place of Chrome's (docs/native-ui.md in the app): what
// the window offers the app's bookmark popover, editor and menus, its tab menu
// and group editor and its find bar, and the asks that go to the app in place
// of Chrome's bubbles and dialogs.

#import "browser_engine/be_window.h"

#import <AppKit/AppKit.h>

#include <optional>
#include <string>
#include <vector>

#include "base/location.h"
#include "base/strings/sys_string_conversions.h"
#include "browser_engine/be_bookmark_bar.h"
#include "browser_engine/be_history.h"
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/find_bar/find_bar_controller.h"
#include "chrome/browser/ui/tabs/tab_group_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_delegate.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_node.h"
#include "components/bookmarks/browser/bookmark_utils.h"
#include "components/bookmarks/common/bookmark_metrics.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_id.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_group.h"
#include "content/public/browser/web_contents.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"

NS_ASSUME_NONNULL_BEGIN

// A folder for the app's folder lists: its folders, not its bookmarks.
@interface BEChromiumBookmarkFolder : NSObject <BEBookmark>
- (instancetype)initWithNode:(const bookmarks::BookmarkNode*)node
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumBookmarkFolder

@synthesize identifier = _identifier;
@synthesize title = _title;
@synthesize children = _children;

- (instancetype)initWithNode:(const bookmarks::BookmarkNode*)node {
  if ((self = [super init])) {
    _identifier = node->id();
    _title = base::SysUTF16ToNSString(node->GetTitle());
    NSMutableArray<id<BEBookmark>>* children = [NSMutableArray array];
    for (const auto& child : node->children()) {
      if (child->is_folder()) {
        [children addObject:[[BEChromiumBookmarkFolder alloc]
                                initWithNode:child.get()]];
      }
    }
    _children = children;
  }
  return self;
}

- (NSURL*)url {
  return nil;
}

- (NSImage*)favicon {
  return nil;
}

@end

@implementation BEChromiumBookmarkEditRequest

@synthesize kind = _kind;
@synthesize bookmarkIdentifier = _bookmarkIdentifier;
@synthesize folderIdentifier = _folderIdentifier;
@synthesize index = _index;
@synthesize url = _url;
@synthesize title = _title;
@synthesize urls = _urls;
@synthesize urlTitles = _urlTitles;

- (instancetype)initWithKind:(BEBookmarkEditKind)kind
                    bookmark:(int64_t)bookmark
                      folder:(int64_t)folder
                       index:(NSInteger)index
                         url:(NSURL*)url
                       title:(NSString*)title
                        urls:(NSArray<NSURL*>*)urls
                   urlTitles:(NSArray<NSString*>*)urlTitles {
  if ((self = [super init])) {
    _kind = kind;
    _bookmarkIdentifier = bookmark;
    _folderIdentifier = folder;
    _index = index;
    _url = [url copy];
    _title = [title copy];
    _urls = [urls copy];
    _urlTitles = [urlTitles copy];
  }
  return self;
}

@end

namespace {

WindowOpenDisposition DispositionFor(BEOpenDisposition disposition) {
  switch (disposition) {
    case BEOpenDispositionCurrentTab:
      return WindowOpenDisposition::CURRENT_TAB;
    case BEOpenDispositionNewForegroundTab:
      return WindowOpenDisposition::NEW_FOREGROUND_TAB;
    case BEOpenDispositionNewBackgroundTab:
      return WindowOpenDisposition::NEW_BACKGROUND_TAB;
    case BEOpenDispositionNewWindow:
      return WindowOpenDisposition::NEW_WINDOW;
    case BEOpenDispositionPrivateWindow:
      return WindowOpenDisposition::OFF_THE_RECORD;
  }
  return WindowOpenDisposition::CURRENT_TAB;
}

std::optional<TabStripModel::ContextMenuCommand> TabCommand(
    BETabCommand command) {
  switch (command) {
    case BETabCommandNewTabToRight:
      return TabStripModel::CommandNewTabToRight;
    case BETabCommandReload:
      return TabStripModel::CommandReload;
    case BETabCommandDuplicate:
      return TabStripModel::CommandDuplicate;
    case BETabCommandTogglePinned:
      return TabStripModel::CommandTogglePinned;
    case BETabCommandToggleSiteMuted:
      return TabStripModel::CommandToggleSiteMuted;
    case BETabCommandAddToNewGroup:
      return TabStripModel::CommandAddToNewGroup;
    case BETabCommandRemoveFromGroup:
      return TabStripModel::CommandRemoveFromGroup;
    case BETabCommandClose:
      return TabStripModel::CommandCloseTab;
    case BETabCommandCloseOthers:
      return TabStripModel::CommandCloseOtherTabs;
    case BETabCommandCloseToRight:
      return TabStripModel::CommandCloseTabsToRight;
    case BETabCommandMoveToNewWindow:
      return TabStripModel::CommandMoveTabsToNewWindow;
    case BETabCommandAddToReadingList:
      return TabStripModel::CommandAddToReadLater;
  }
  return std::nullopt;
}

// The delegate, if it answers `selector`.
id<BEWindowDelegateNativeUI> NativeUIDelegate(id<BEWindowDelegate> delegate,
                                              SEL selector) {
  return [delegate respondsToSelector:selector]
             ? static_cast<id<BEWindowDelegateNativeUI>>(delegate)
             : nil;
}

}  // namespace

@implementation BEChromiumWindow (NativeUI)

// MARK: BEWindowBookmarkEditing

// The window's profile's bookmarks, once loaded.
- (bookmarks::BookmarkModel*)loadedBookmarkModel {
  BrowserWindowInterface* browser = [self browser];
  bookmarks::BookmarkModel* model =
      browser
          ? BookmarkModelFactory::GetForBrowserContext(browser->GetProfile())
          : nullptr;
  return model && model->loaded() ? model : nullptr;
}

- (const bookmarks::BookmarkNode*)bookmarkNode:(int64_t)identifier {
  bookmarks::BookmarkModel* model = [self loadedBookmarkModel];
  return model && identifier ? bookmarks::GetBookmarkNodeByID(model, identifier)
                             : nullptr;
}

- (NSArray<id<BEBookmark>>*)bookmarkFolders {
  bookmarks::BookmarkModel* model = [self loadedBookmarkModel];
  if (!model) {
    return @[];
  }
  NSMutableArray<id<BEBookmark>>* folders = [NSMutableArray array];
  for (const bookmarks::BookmarkNode* node :
       {model->bookmark_bar_node(), model->other_node(),
        model->mobile_node()}) {
    // Mobile Bookmarks only when it has any, as Chrome's editor lists it.
    if (node && (node != model->mobile_node() || !node->children().empty())) {
      [folders addObject:[[BEChromiumBookmarkFolder alloc] initWithNode:node]];
    }
  }
  return folders;
}

- (NSArray<NSNumber*>*)recentBookmarkFolders {
  bookmarks::BookmarkModel* model = [self loadedBookmarkModel];
  if (!model) {
    return @[];
  }
  NSMutableArray<NSNumber*>* folders = [NSMutableArray array];
  for (const bookmarks::BookmarkNode* node :
       bookmarks::GetMostRecentlyModifiedUserFolders(model)) {
    [folders addObject:@(node->id())];
  }
  return folders;
}

- (int64_t)bookmarkIdentifierForURL:(NSURL*)url {
  bookmarks::BookmarkModel* model = [self loadedBookmarkModel];
  const bookmarks::BookmarkNode* node =
      model ? model->GetMostRecentlyAddedUserNodeForURL(net::GURLWithNSURL(url))
            : nullptr;
  return node ? node->id() : 0;
}

- (int64_t)folderOfBookmark:(int64_t)identifier {
  const bookmarks::BookmarkNode* node = [self bookmarkNode:identifier];
  return node && node->parent() ? node->parent()->id() : 0;
}

- (void)editBookmark:(int64_t)identifier
               title:(NSString*)title
                 url:(NSURL*)url
              folder:(int64_t)folder {
  bookmarks::BookmarkModel* model = [self loadedBookmarkModel];
  const bookmarks::BookmarkNode* node = [self bookmarkNode:identifier];
  if (!node || model->is_permanent_node(node)) {
    return;
  }
  // BookmarkEditor::ApplyEdits(): the title, the address, then the folder.
  model->SetTitle(node, base::SysNSStringToUTF16(title),
                  bookmarks::metrics::BookmarkEditSource::kUser);
  const GURL gurl = url ? net::GURLWithNSURL(url) : GURL();
  if (node->is_url() && gurl.is_valid()) {
    model->SetURL(node, gurl, bookmarks::metrics::BookmarkEditSource::kUser);
  }
  const bookmarks::BookmarkNode* parent = [self bookmarkNode:folder];
  // Not into itself, nor into a folder inside it.
  if (parent && parent->is_folder() && parent != node->parent() &&
      !parent->HasAncestor(node)) {
    model->Move(node, parent, parent->children().size());
  }
}

- (int64_t)addBookmarkFolder:(NSString*)title
                    toFolder:(int64_t)folder
                     atIndex:(NSInteger)index {
  bookmarks::BookmarkModel* model = [self loadedBookmarkModel];
  const bookmarks::BookmarkNode* parent = [self bookmarkNode:folder];
  if (!parent || !parent->is_folder()) {
    return 0;
  }
  const size_t count = parent->children().size();
  const size_t at = index < 0 || static_cast<size_t>(index) > count
                        ? count
                        : static_cast<size_t>(index);
  const bookmarks::BookmarkNode* added =
      model->AddFolder(parent, at, base::SysNSStringToUTF16(title));
  return added ? added->id() : 0;
}

- (void)removeBookmark:(int64_t)identifier {
  bookmarks::BookmarkModel* model = [self loadedBookmarkModel];
  const bookmarks::BookmarkNode* node = [self bookmarkNode:identifier];
  if (node && !model->is_permanent_node(node)) {
    model->Remove(node, bookmarks::metrics::BookmarkEditSource::kUser,
                  FROM_HERE);
  }
}

- (void)openBookmark:(int64_t)identifier
         disposition:(BEOpenDisposition)disposition {
  // Last: opening can replace this window's page; the app calls it from a
  // menu, never from inside a Chrome notification.
  if (browser_engine::BEBookmarkBar* bar = [self bookmarkBar]) {
    bar->Open(identifier, DispositionFor(disposition));
  }
}

// MARK: BEWindowTabCommands

- (BOOL)canRunTabCommand:(BETabCommand)command atIndex:(NSInteger)index {
  TabStripModel* model = [self tabStripModel];
  const std::optional<TabStripModel::ContextMenuCommand> chrome =
      TabCommand(command);
  return model && chrome && model->ContainsIndex(static_cast<int>(index)) &&
         model->IsContextMenuCommandEnabled(static_cast<int>(index), *chrome);
}

- (void)runTabCommand:(BETabCommand)command atIndex:(NSInteger)index {
  if (![self canRunTabCommand:command atIndex:index]) {
    return;
  }
  // As Chrome's tab menu: on the tab, or on every selected tab if it's one.
  // Last: it can close this window.
  [self tabStripModel]->ExecuteContextMenuCommand(static_cast<int>(index),
                                                  *TabCommand(command));
}

- (void)addTabAtIndex:(NSInteger)index toTabGroup:(NSString*)identifier {
  TabStripModel* model = [self tabStripModel];
  const std::optional<tab_groups::TabGroupId> group =
      [self groupWithIdentifier:identifier];
  if (group && model->ContainsIndex(static_cast<int>(index))) {
    model->ExecuteAddToExistingGroupCommand(static_cast<int>(index), *group);
  }
}

- (void)setTabGroup:(NSString*)identifier
              title:(NSString*)title
              color:(BETabGroupColor)color {
  TabStripModel* model = [self tabStripModel];
  const std::optional<tab_groups::TabGroupId> group =
      [self groupWithIdentifier:identifier];
  if (!group) {
    return;
  }
  const tab_groups::TabGroupVisualData* visuals =
      model->group_model()->GetTabGroup(*group)->visual_data();
  // BETabGroupColor follows TabGroupColorId's order.
  model->ChangeTabGroupVisuals(
      *group,
      tab_groups::TabGroupVisualData(
          base::SysNSStringToUTF16(title),
          static_cast<tab_groups::TabGroupColorId>(color),
          visuals->is_collapsed()),
      /*is_customized=*/true);
}

// The indices of `group`'s tabs.
- (std::vector<int>)indicesOfTabGroup:(const tab_groups::TabGroupId&)group {
  TabStripModel* model = [self tabStripModel];
  const gfx::Range range = model->group_model()->GetTabGroup(group)->ListTabs();
  std::vector<int> indices;
  for (uint32_t i = range.start(); i < range.end(); ++i) {
    indices.push_back(static_cast<int>(i));
  }
  return indices;
}

- (void)ungroupTabGroup:(NSString*)identifier {
  if (const std::optional<tab_groups::TabGroupId> group =
          [self groupWithIdentifier:identifier]) {
    [self tabStripModel]->RemoveFromGroup([self indicesOfTabGroup:*group]);
  }
}

- (void)closeTabGroup:(NSString*)identifier {
  // Last: closing every tab can close the window.
  if (const std::optional<tab_groups::TabGroupId> group =
          [self groupWithIdentifier:identifier]) {
    [self tabStripModel]->CloseAllTabsInGroup(*group);
  }
}

- (void)addTabToTabGroup:(NSString*)identifier {
  TabStripModel* model = [self tabStripModel];
  const std::optional<tab_groups::TabGroupId> group =
      [self groupWithIdentifier:identifier];
  if (!group) {
    return;
  }
  // TabGroupEditorBubbleView's "New tab in group".
  const gfx::Range range =
      model->group_model()->GetTabGroup(*group)->ListTabs();
  model->delegate()->AddTabAt(GURL(), static_cast<int>(range.end()),
                              /*foreground=*/true, *group);
}

- (BOOL)canMoveTabGroupToNewWindow:(NSString*)identifier {
  TabStripModel* model = [self tabStripModel];
  const std::optional<tab_groups::TabGroupId> group =
      [self groupWithIdentifier:identifier];
  return group && model->group_model()->GetTabGroup(*group)->tab_count() <
                      model->count();
}

- (void)moveTabGroupToNewWindow:(NSString*)identifier {
  if (![self canMoveTabGroupToNewWindow:identifier]) {
    return;
  }
  [self tabStripModel]->delegate() -> MoveGroupToNewWindow(
                                       *[self groupWithIdentifier:identifier]);
}

// MARK: BEWindowFind

- (void)findText:(NSString*)text forward:(BOOL)forward {
  BrowserWindowInterface* browser = [self browser];
  FindBarController* controller =
      browser ? FindBarController::From(browser) : nullptr;
  content::WebContents* contents =
      controller ? controller->web_contents() : nullptr;
  if (!contents) {
    return;
  }
  find_in_page::FindTabHelper* helper =
      find_in_page::FindTabHelper::FromWebContents(contents);
  const std::u16string query = base::SysNSStringToUTF16(text);
  // FindBarView's typing and its next and previous buttons.
  controller->OnUserChangedFindText(query);
  if (query.empty()) {
    helper->StopFinding(find_in_page::SelectionAction::kClear);
    return;
  }
  helper->StartFinding(query, forward, /*case_sensitive=*/false,
                       /*find_match=*/true);
}

- (void)endFind {
  BrowserWindowInterface* browser = [self browser];
  if (FindBarController* controller =
          browser ? FindBarController::From(browser) : nullptr) {
    controller->EndFindSession(find_in_page::SelectionAction::kKeep,
                               find_in_page::ResultAction::kKeep);
  }
}

// MARK: Asking the delegate

- (BOOL)showBookmarkEditor:(BEChromiumBookmarkEditRequest*)request {
  id<BEWindowDelegateNativeUI> delegate =
      NativeUIDelegate(self.delegate, @selector(window:showBookmarkEditor:));
  return delegate && [delegate window:self showBookmarkEditor:request];
}

- (BOOL)confirmClosingWithDownloads:(NSInteger)count
                           quitting:(BOOL)quitting
                         completion:(void (^)(BOOL))completion {
  id<BEWindowDelegateNativeUI> delegate = NativeUIDelegate(
      self.delegate, @selector(window:
                         confirmClosingWithDownloads:quitting:completion:));
  return delegate && [delegate window:self
                         confirmClosingWithDownloads:count
                                            quitting:quitting
                                          completion:completion];
}

- (BOOL)showFullscreenNotice:(NSString*)text {
  id<BEWindowDelegateNativeUI> delegate =
      NativeUIDelegate(self.delegate, @selector(window:showFullscreenNotice:));
  return delegate && [delegate window:self showFullscreenNotice:text];
}

- (BOOL)drawsFindBar {
  return NativeUIDelegate(self.delegate, @selector(window:
                                             showFindBarWithText:)) != nil;
}

- (void)showFindBarWithText:(NSString*)text {
  [NativeUIDelegate(self.delegate, @selector(window:
                                       showFindBarWithText:)) window:self
                                                 showFindBarWithText:text];
}

- (void)hideFindBar {
  [NativeUIDelegate(self.delegate, @selector(windowHideFindBar:))
      windowHideFindBar:self];
}

- (void)didFindMatch:(NSInteger)current of:(NSInteger)total final:(BOOL)final {
  [NativeUIDelegate(self.delegate, @selector(window:
                                       didFindMatch:of:final:)) window:self
                                                          didFindMatch:current
                                                                    of:total
                                                                 final:final];
}

// MARK: BEWindowHistory

- (void)queryHistory:(NSString*)text
                host:(NSString*)host
              before:(NSDate*)before
               count:(NSInteger)count
          completion:(void (^)(NSArray<id<BEHistoryEntry>>* entries,
                               BOOL complete))completion {
  if (browser_engine::BEHistory* history = [self history]) {
    history->Query(text, host, before, count, completion);
  }
}

- (void)removeHistoryEntries:(NSArray<id<BEHistoryEntry>>*)entries
                  completion:(void (^)(void))completion {
  if (browser_engine::BEHistory* history = [self history]) {
    history->Remove(entries, completion);
  }
}

- (void)requestHistoryFaviconForURL:(NSURL*)url
                         completion:(void (^)(NSImage* favicon))completion {
  if (browser_engine::BEHistory* history = [self history]) {
    history->RequestFavicon(url, completion);
  }
}

@end
