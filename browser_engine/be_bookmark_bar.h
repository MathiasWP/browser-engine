// One window's bookmarks bar for the app, as Chrome's BookmarkBarView drives
// its own: Chrome's controller (BookmarkBarUIControllerImpl with the desktop
// adapters) opens bookmarks and folders and shows the context menu, and drops
// go through BookmarkUIOperationsHelperMergedSurfaces as the view's do. The
// app draws the bar and its folder menus.

#ifndef BROWSER_ENGINE_BE_BOOKMARK_BAR_H_
#define BROWSER_ENGINE_BE_BOOKMARK_BAR_H_

#include <stddef.h>
#include <stdint.h>

#include <memory>
#include <string>

#include "base/memory/raw_ptr.h"
#include "chrome/browser/ui/bookmarks/controllers/bookmark_bar_ui_client.h"

class BookmarkBarUIControllerImpl;
class BrowserWindowInterface;
class GURL;
enum class WindowOpenDisposition;

namespace gfx {
class Point;
}  // namespace gfx

namespace browser_engine {

// Made for the window's first click, menu or drop; destroyed before its
// browser.
class BEBookmarkBar : public BookmarkBarUIClient {
 public:
  explicit BEBookmarkBar(BrowserWindowInterface* browser);
  BEBookmarkBar(const BEBookmarkBar&) = delete;
  BEBookmarkBar& operator=(const BEBookmarkBar&) = delete;
  ~BEBookmarkBar() override;

  // Opens the bookmark or folder whose node is `node_id` as a click on its
  // button does: a bookmark where `disposition` says, a folder's bookmarks
  // all in tabs (a folder opened in the current tab is the app's menu).
  void Open(int64_t node_id, WindowOpenDisposition disposition);
  // Chrome's context menu for the node `node_id`, or the bar itself with 0,
  // at `screen_point`.
  void ShowMenu(int64_t node_id, const gfx::Point& screen_point);
  // Drops the node `node_id` into the folder `folder_id` at `index`, as
  // BookmarkBarView::PerformDrop() drops a bookmark dragged from the bar.
  void Move(int64_t node_id, int64_t folder_id, size_t index);
  // Drops a link into the folder `folder_id` at `index`, as a link dragged
  // from a page or another app.
  void Add(const GURL& url,
           const std::u16string& title,
           int64_t folder_id,
           size_t index);

 private:
  // BookmarkBarUIClient: what the bar shows besides bookmarks, and folder
  // menus, are the app's.
  void SetAppsPageShortcutVisibility(bool visible) override {}
  void SetSavedTabGroupsVisibility(bool visible) override {}
  void SetManagedBookmarksFolderVisibility(bool visible) override {}
  void ShowFolderMenu(const bookmarks::BookmarkNodeId& folder) override {}

  raw_ptr<BrowserWindowInterface> browser_;
  std::unique_ptr<BookmarkBarUIControllerImpl> controller_;
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_BOOKMARK_BAR_H_
