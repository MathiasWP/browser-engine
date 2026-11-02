#import "browser_engine/be_bookmarks.h"

#import <AppKit/AppKit.h>

#include <stdint.h>

#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_engine.h"
#include "chrome/browser/bookmarks/bookmark_merged_surface_service.h"
#include "chrome/browser/bookmarks/bookmark_merged_surface_service_factory.h"
#include "chrome/browser/bookmarks/bookmark_parent_folder.h"
#include "chrome/browser/bookmarks/bookmark_parent_folder_children.h"
#include "chrome/grit/generated_resources.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_node.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/l10n/l10n_util_mac.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

NS_ASSUME_NONNULL_BEGIN

// A folder or a bookmark as the app reads it, as it was when listed:
// BEBookmarks makes new ones each time it lists the bookmarks again. A
// bookmark's icon is the model's, asked for when the app reads it.
@interface BEChromiumBookmark : NSObject <BEBookmark>
- (instancetype)initFolderWithTitle:(NSString*)title
                           children:(NSArray<BEChromiumBookmark*>*)children
                             nodeID:(int64_t)nodeID NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithTitle:(NSString*)title
                          url:(NSURL*)url
                       nodeID:(int64_t)nodeID
                        owner:(base::WeakPtr<browser_engine::BEBookmarks>)owner
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumBookmark {
  // The node, which `_owner` has the icon of for a bookmark. For a permanent
  // folder, its first node (the account's, if there is one).
  int64_t _nodeID;
  // Null for a folder, and once the bookmarks of another profile, or none,
  // are watched.
  base::WeakPtr<browser_engine::BEBookmarks> _owner;
}

@synthesize title = _title;
@synthesize url = _url;
@synthesize children = _children;

- (instancetype)initFolderWithTitle:(NSString*)title
                           children:(NSArray<BEChromiumBookmark*>*)children
                             nodeID:(int64_t)nodeID {
  if ((self = [super init])) {
    _title = [title copy];
    _children = [children copy];
    _nodeID = nodeID;
  }
  return self;
}

- (int64_t)identifier {
  return _nodeID;
}

- (instancetype)initWithTitle:(NSString*)title
                          url:(NSURL*)url
                       nodeID:(int64_t)nodeID
                        owner:
                            (base::WeakPtr<browser_engine::BEBookmarks>)owner {
  if ((self = [super init])) {
    _title = [title copy];
    _url = [url copy];
    _children = @[];
    _nodeID = nodeID;
    _owner = std::move(owner);
  }
  return self;
}

- (NSImage*)favicon {
  browser_engine::BEBookmarks* owner = _owner.get();
  return owner ? owner->GetFavicon(_nodeID) : nil;
}

@end

namespace browser_engine {

namespace {

NSString* Title(const bookmarks::BookmarkNode* node) {
  return base::SysUTF16ToNSString(node->GetTitle());
}

}  // namespace

BEBookmarks::BEBookmarks() = default;

BEBookmarks::~BEBookmarks() = default;

void BEBookmarks::ObserveProfile(Profile* profile) {
  if (profile == profile_) {
    return;
  }
  Reset();
  // What Chrome's bookmark menu and bar show: the profile's bookmarks with
  // its account's, if it has one, in one order. Loading starts when the
  // service is made.
  BookmarkMergedSurfaceService* service =
      BookmarkMergedSurfaceServiceFactory::GetForProfile(profile);
  if (!service) {
    return;  // A profile with no bookmarks (the system profile).
  }
  profile_ = profile;
  service_observation_.Observe(service);
  if (service->loaded()) {
    NotifyChange();
  }
}

NSArray<id<BEBookmark>>* BEBookmarks::items() {
  BookmarkMergedSurfaceService* service = service_observation_.GetSource();
  if (!service || !service->loaded()) {
    return @[];
  }
  if (items_) {
    return items_;
  }

  // BookmarkMenuBridge::BuildRootMenu(): the managed bookmarks as a folder,
  // then the bookmarks bar's, then Other Bookmarks and Mobile Bookmarks as
  // folders; each permanent folder only if it isn't empty. (Chrome's menu
  // has a separator before the managed folder or the bar's bookmarks, and one
  // before Other Bookmarks or Mobile Bookmarks.)
  NSMutableArray<BEChromiumBookmark*>* items = [NSMutableArray array];
  const BookmarkParentFolder managed_folder =
      BookmarkParentFolder::ManagedFolder();
  if (service->GetChildrenCount(managed_folder)) {
    [items addObject:FolderItem(managed_folder)];
  }
  for (const bookmarks::BookmarkNode* node :
       service->GetChildren(BookmarkParentFolder::BookmarkBarFolder())) {
    if (BEChromiumBookmark* item = NodeItem(node)) {
      [items addObject:item];
    }
  }
  const BookmarkParentFolder other_folder = BookmarkParentFolder::OtherFolder();
  if (service->GetChildrenCount(other_folder)) {
    [items addObject:FolderItem(other_folder)];
  }
  const BookmarkParentFolder mobile_folder =
      BookmarkParentFolder::MobileFolder();
  if (service->GetChildrenCount(mobile_folder)) {
    [items addObject:FolderItem(mobile_folder)];
  }
  items_ = [items copy];
  return items_;
}

id<BEBookmark> BEBookmarks::bar() {
  BookmarkMergedSurfaceService* service = service_observation_.GetSource();
  if (!service || !service->loaded()) {
    return nil;
  }
  if (!bar_) {
    bar_ = FolderItem(BookmarkParentFolder::BookmarkBarFolder());
  }
  return bar_;
}

id<BEBookmark> BEBookmarks::other() {
  BookmarkMergedSurfaceService* service = service_observation_.GetSource();
  // BookmarkBarView::UpdateOtherAndManagedButtonsVisibility().
  const BookmarkParentFolder other_folder = BookmarkParentFolder::OtherFolder();
  if (!service || !service->loaded() ||
      !service->GetChildrenCount(other_folder)) {
    return nil;
  }
  if (!other_) {
    other_ = FolderItem(
        other_folder,
        l10n_util::GetNSString(IDS_BOOKMARKS_ALL_BOOKMARKS));
  }
  return other_;
}

NSImage* BEBookmarks::GetFavicon(int64_t node_id) {
  BookmarkMergedSurfaceService* service = service_observation_.GetSource();
  auto it = listed_nodes_.find(node_id);
  if (!service || it == listed_nodes_.end()) {
    return nil;
  }
  // BookmarkMenuBridge::ConfigureMenuItem(): the model's icon for the node,
  // which the model loads from history the first time it's asked, and is
  // empty until then (Chrome's menu shows the default icon meanwhile).
  return service->bookmark_model()->GetFavicon(it->second.get()).AsNSImage();
}

void BEBookmarks::BookmarkMergedSurfaceServiceLoaded() {
  Invalidate();
}

void BEBookmarks::BookmarkMergedSurfaceServiceBeingDeleted() {
  Reset();
}

void BEBookmarks::BookmarkNodeAdded(const BookmarkParentFolder& parent,
                                    size_t index) {
  Invalidate();
}

void BEBookmarks::BookmarkNodesRemoved(
    const BookmarkParentFolder& parent,
    const base::flat_set<const bookmarks::BookmarkNode*>& nodes) {
  // Before the nodes go: `listed_nodes_` may have them.
  Invalidate();
}

void BEBookmarks::BookmarkNodeMoved(const BookmarkParentFolder& old_parent,
                                    size_t old_index,
                                    const BookmarkParentFolder& new_parent,
                                    size_t new_index) {
  Invalidate();
}

void BEBookmarks::BookmarkNodeChanged(const bookmarks::BookmarkNode* node) {
  // A title or an address. Chrome's menu changes the item; listed again, the
  // app's has it.
  Invalidate();
}

void BEBookmarks::BookmarkNodeFaviconChanged(
    const bookmarks::BookmarkNode* node) {
  // The lists stand: each read of a bookmark's icon asks the model. The bar
  // shows the icons, so it looks again.
  NotifyChange();
}

void BEBookmarks::BookmarkParentFolderChildrenReordered(
    const BookmarkParentFolder& folder) {
  Invalidate();
}

void BEBookmarks::BookmarkAllUserNodesRemoved() {
  Invalidate();
}

void BEBookmarks::Invalidate() {
  items_ = nil;
  bar_ = nil;
  other_ = nil;
  listed_nodes_.clear();
  NotifyChange();
}

void BEBookmarks::NotifyChange() {
  if (change_pending_) {
    return;
  }
  change_pending_ = true;
  // From inside the model's notifications, where the app mustn't read it back.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BEBookmarks::SendChange,
                                notify_factory_.GetWeakPtr()));
}

void BEBookmarks::SendChange() {
  change_pending_ = false;
  [GetEngineDelegate() engineDidChangeBookmarks:GetEngine()];
}

void BEBookmarks::Reset() {
  service_observation_.Reset();
  profile_ = nullptr;
  Invalidate();
  // Ids are the model's, so a bookmark listed before mustn't find another
  // profile's node.
  weak_factory_.InvalidateWeakPtrs();
}

BEChromiumBookmark* BEBookmarks::FolderItem(const BookmarkParentFolder& folder,
                                            NSString* title) {
  BookmarkMergedSurfaceService* service = service_observation_.GetSource();
  // BookmarkMenuBridge::AddSubmenu(): a folder is titled as its first node
  // is. For a permanent folder that's the account's, if there is one, else
  // the profile's: "Other bookmarks", "Mobile bookmarks", or the managed
  // folder's name. (Called for the managed folder only when it has
  // bookmarks: without them, it may have no node, which this CHECKs.)
  const std::vector<const bookmarks::BookmarkNode*> nodes =
      service->GetUnderlyingNodes(folder);
  const bookmarks::BookmarkNode* first = nodes.empty() ? nullptr : nodes.front();
  if (!title) {
    title = first ? Title(first) : @"";
  }
  // An empty folder has no children; Chrome's menu shows "(empty)" in it.
  NSMutableArray<BEChromiumBookmark*>* children = [NSMutableArray array];
  for (const bookmarks::BookmarkNode* node : service->GetChildren(folder)) {
    if (BEChromiumBookmark* child = NodeItem(node)) {
      [children addObject:child];
    }
  }
  return [[BEChromiumBookmark alloc] initFolderWithTitle:title
                                                children:children
                                                  nodeID:first ? first->id() : 0];
}

BEChromiumBookmark* BEBookmarks::NodeItem(const bookmarks::BookmarkNode* node) {
  if (node->is_folder()) {
    return FolderItem(BookmarkParentFolder::FromFolderNode(node));
  }
  // Chrome's menu would list an address NSURL can't hold too, but the app
  // couldn't open it (net::NSURLWithGURL() is nil for some valid GURLs).
  NSURL* url = net::NSURLWithGURL(node->url());
  if (!url) {
    return nil;
  }
  listed_nodes_[node->id()] = node;
  return [[BEChromiumBookmark alloc] initWithTitle:Title(node)
                                               url:url
                                            nodeID:node->id()
                                             owner:weak_factory_.GetWeakPtr()];
}

}  // namespace browser_engine
