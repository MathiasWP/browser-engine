// The everyday profile's bookmarks to the app, as Chrome's Bookmarks menu
// lists them (BookmarkMenuBridge) and its bookmarks bar shows them
// (BookmarkBarView): BookmarkMergedSurfaceService's folders and bookmarks as
// BEBookmark objects, for -[BEEngine bookmarks], -bookmarkBar and
// -otherBookmarks. The engine delegate hears engineDidChangeBookmarks: when
// they change.

#ifndef BROWSER_ENGINE_BE_BOOKMARKS_H_
#define BROWSER_ENGINE_BE_BOOKMARKS_H_

#import <Foundation/Foundation.h>

#include <stddef.h>
#include <stdint.h>

#include <map>

#include "base/containers/flat_set.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#import "browser_engine/public/BEEngine.h"
#include "chrome/browser/bookmarks/bookmark_merged_surface_service_observer.h"

@class BEChromiumBookmark;
@class NSImage;

class BookmarkMergedSurfaceService;
class Profile;
struct BookmarkParentFolder;

namespace bookmarks {
class BookmarkNode;
}  // namespace bookmarks

namespace browser_engine {

// One for the process, in the engine. Like the menu bridge, it lists the
// bookmarks on the first read after they change, and leaves their icons to the
// BookmarkModel: a bookmark's icon starts loading the first time the app reads
// it (BookmarkModel::GetFavicon(), which the bridge calls as it adds an item),
// and is there on a later read.
class BEBookmarks : public BookmarkMergedSurfaceServiceObserver {
 public:
  BEBookmarks();
  BEBookmarks(const BEBookmarks&) = delete;
  BEBookmarks& operator=(const BEBookmarks&) = delete;
  ~BEBookmarks() override;

  // Watches `profile`'s bookmarks, in place of another profile's, unless it
  // does already.
  void ObserveProfile(Profile* profile);

  // What Chrome's menu lists, all the way down; empty while nothing is
  // watched, and until the bookmarks have loaded.
  NSArray<id<BEBookmark>>* items();
  // The bookmarks bar's folder, all the way down; nil while nothing is
  // watched, and until the bookmarks have loaded.
  id<BEBookmark> bar();
  // The bar's All Bookmarks: the Other Bookmarks folder, while it has any.
  id<BEBookmark> other();

  // The icon of the bookmark whose node is `node_id`, once the model has
  // loaded it; asking starts loading it. Nil for a bookmark that's no longer
  // listed.
  NSImage* GetFavicon(int64_t node_id);

 private:
  // BookmarkMergedSurfaceServiceObserver:
  void BookmarkMergedSurfaceServiceLoaded() override;
  void BookmarkMergedSurfaceServiceBeingDeleted() override;
  void BookmarkNodeAdded(const BookmarkParentFolder& parent,
                         size_t index) override;
  void BookmarkNodesRemoved(
      const BookmarkParentFolder& parent,
      const base::flat_set<const bookmarks::BookmarkNode*>& nodes) override;
  void BookmarkNodeMoved(const BookmarkParentFolder& old_parent,
                         size_t old_index,
                         const BookmarkParentFolder& new_parent,
                         size_t new_index) override;
  void BookmarkNodeChanged(const bookmarks::BookmarkNode* node) override;
  void BookmarkNodeFaviconChanged(const bookmarks::BookmarkNode* node) override;
  void BookmarkParentFolderChildrenReordered(
      const BookmarkParentFolder& folder) override;
  void BookmarkAllUserNodesRemoved() override;

  // Lists the bookmarks again on the next read, and tells the app.
  void Invalidate();
  // Tells the engine delegate engineDidChangeBookmarks: soon, once for every
  // change in a task.
  void NotifyChange();
  void SendChange();
  // Stops watching, and lists nothing.
  void Reset();
  // `folder`, with its bookmarks and folders, titled `title` if given.
  BEChromiumBookmark* FolderItem(const BookmarkParentFolder& folder,
                                 NSString* title = nil);
  // `node`, a bookmark or a folder; nil for a bookmark the app can't open.
  BEChromiumBookmark* NodeItem(const bookmarks::BookmarkNode* node);

  // The profile watched; null when none is.
  raw_ptr<Profile> profile_ = nullptr;
  // What items(), bar() and other() return; nil until next read.
  NSArray<BEChromiumBookmark*>* __strong items_ = nil;
  BEChromiumBookmark* __strong bar_ = nil;
  BEChromiumBookmark* __strong other_ = nil;
  // engineDidChangeBookmarks: is on its way.
  bool change_pending_ = false;
  // The nodes of the bookmarks `items_` lists, by id, for their icons.
  // Cleared with `items_`, before a removed node goes.
  std::map<int64_t, raw_ptr<const bookmarks::BookmarkNode>> listed_nodes_;
  base::ScopedObservation<BookmarkMergedSurfaceService,
                          BookmarkMergedSurfaceServiceObserver>
      service_observation_{this};
  // The listed bookmarks' way back to their icons.
  base::WeakPtrFactory<BEBookmarks> weak_factory_{this};
  // For the change notice; kept across profiles.
  base::WeakPtrFactory<BEBookmarks> notify_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_BOOKMARKS_H_
