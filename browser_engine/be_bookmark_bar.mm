#include "browser_engine/be_bookmark_bar.h"

#include <algorithm>
#include <optional>

#include "base/functional/callback_helpers.h"
#include "chrome/browser/bookmarks/bookmark_merged_surface_service.h"
#include "chrome/browser/bookmarks/bookmark_merged_surface_service_factory.h"
#include "chrome/browser/bookmarks/bookmark_node_types.h"
#include "chrome/browser/bookmarks/bookmark_parent_folder.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/bookmarks/bookmark_drag_drop.h"
#include "chrome/browser/ui/bookmarks/bookmark_ui_operations_helper.h"
#include "chrome/browser/ui/bookmarks/bookmark_utils.h"
#include "chrome/browser/ui/bookmarks/controllers/bookmark_bar_ui_controller_impl.h"
#include "chrome/browser/ui/bookmarks/controllers/desktop_bookmark_bar_ui_controller_injector.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_node.h"
#include "components/bookmarks/browser/bookmark_node_data.h"
#include "components/bookmarks/browser/bookmark_utils.h"
#include "ui/base/mojom/menu_source_type.mojom-shared.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/geometry/point.h"
#include "url/gurl.h"

namespace browser_engine {

namespace {

// The profile's bookmarks, loaded; null before they are, and for profiles
// with none.
BookmarkMergedSurfaceService* LoadedService(BrowserWindowInterface* browser) {
  BookmarkMergedSurfaceService* service =
      BookmarkMergedSurfaceServiceFactory::GetForProfile(browser->GetProfile());
  return service && service->loaded() ? service : nullptr;
}

// The node `node_id`, or null for one that's gone.
const bookmarks::BookmarkNode* Node(BookmarkMergedSurfaceService* service,
                                    int64_t node_id) {
  return bookmarks::GetBookmarkNodeByID(service->bookmark_model(), node_id);
}

// The folder `folder_id` as the bar's views name it (a permanent folder as
// one, across local and account storage); nullopt for a node that's gone or
// isn't a folder.
std::optional<BookmarkParentFolder> Folder(
    BookmarkMergedSurfaceService* service,
    int64_t folder_id) {
  const bookmarks::BookmarkNode* node = Node(service, folder_id);
  if (!node || !node->is_folder() || node->is_root()) {
    return std::nullopt;
  }
  return BookmarkParentFolder::FromFolderNode(node);
}

// Drops `data` into `folder` at `index` as BookmarkBarView::PerformDrop()
// does, where its drop checks would let it
// (chrome/browser/ui/bookmarks/bookmark_utils.cc IsValidBookmarkDropLocation):
// never into a managed folder, nor a folder into itself or its own folders.
void Drop(BrowserWindowInterface* browser,
          BookmarkMergedSurfaceService* service,
          const BookmarkParentFolder& folder,
          size_t index,
          const bookmarks::BookmarkNodeData& data,
          const bookmarks::BookmarkNode* dragged) {
  if (service->IsParentFolderManaged(folder)) {
    return;
  }
  if (dragged && dragged->is_folder()) {
    for (const bookmarks::BookmarkNode* node :
         service->GetUnderlyingNodes(folder)) {
      if (node && node->HasAncestor(dragged)) {
        return;
      }
    }
  }
  index = std::min(index, service->GetChildrenCount(folder));
  // A managed bookmark is copied, as the bar copies one it can't move.
  const bool copy = dragged && service->IsNodeManaged(dragged);
  BookmarkUIOperationsHelperMergedSurfaces(service, &folder)
      .DropBookmarks(browser->GetProfile(), data, index, copy,
                     chrome::BookmarkReorderDropTarget::kBookmarkBarView,
                     browser);
}

}  // namespace

BEBookmarkBar::BEBookmarkBar(BrowserWindowInterface* browser)
    : browser_(browser),
      controller_(std::make_unique<BookmarkBarUIControllerImpl>(
          std::make_unique<DesktopBookmarkBarUIControllerInjector>(browser))) {
  controller_->Bind(this);
}

BEBookmarkBar::~BEBookmarkBar() = default;

void BEBookmarkBar::Open(int64_t node_id, WindowOpenDisposition disposition) {
  BookmarkMergedSurfaceService* service = LoadedService(browser_);
  const bookmarks::BookmarkNode* node =
      service ? Node(service, node_id) : nullptr;
  if (!node) {
    return;
  }
  if (node->is_url()) {
    controller_->OpenBookmark(node_id, disposition);
  } else if (!node->is_root()) {
    controller_->OpenFolder(
        chrome::ToNodeId(BookmarkParentFolder::FromFolderNode(node)),
        disposition);
  }
}

void BEBookmarkBar::ShowMenu(int64_t node_id, const gfx::Point& screen_point) {
  BookmarkMergedSurfaceService* service = LoadedService(browser_);
  if (!service) {
    return;  // As BookmarkBarView: nothing before the bookmarks load.
  }
  // BookmarkBarView::ShowContextMenuForViewImpl(): a button's node, the
  // permanent folder of All Bookmarks, or the bar's own folder for the bar.
  bookmarks::BookmarkNodeId target =
      bookmarks::PermanentFolderType::kBookmarkBarNode;
  if (node_id) {
    const bookmarks::BookmarkNode* node = Node(service, node_id);
    if (!node || node->is_root()) {
      return;
    }
    target = node->is_folder()
                 ? chrome::ToNodeId(BookmarkParentFolder::FromFolderNode(node))
                 : bookmarks::BookmarkNodeId(node->id());
  }
  controller_->ShowContextMenu(target, screen_point,
                               ui::mojom::MenuSourceType::kMouse,
                               base::DoNothing());
}

void BEBookmarkBar::Move(int64_t node_id, int64_t folder_id, size_t index) {
  BookmarkMergedSurfaceService* service = LoadedService(browser_);
  const bookmarks::BookmarkNode* node =
      service ? Node(service, node_id) : nullptr;
  std::optional<BookmarkParentFolder> folder =
      service ? Folder(service, folder_id) : std::nullopt;
  if (!node || node->is_permanent_node() || !folder) {
    return;
  }
  // What BookmarkBarView's drag writes: the node, from this profile, so the
  // drop moves it.
  bookmarks::BookmarkNodeData data(node);
  data.SetOriginatingProfilePath(browser_->GetProfile()->GetPath());
  Drop(browser_, service, *folder, index, data, node);
}

void BEBookmarkBar::Add(const GURL& url,
                        const std::u16string& title,
                        int64_t folder_id,
                        size_t index) {
  BookmarkMergedSurfaceService* service = LoadedService(browser_);
  std::optional<BookmarkParentFolder> folder =
      service ? Folder(service, folder_id) : std::nullopt;
  if (!folder || !url.is_valid()) {
    return;
  }
  // A link dropped from a page or another app: no profile, so it's copied in.
  bookmarks::BookmarkNodeData data;
  if (!data.ReadFromTuple(url, title)) {
    return;
  }
  Drop(browser_, service, *folder, index, data, nullptr);
}

}  // namespace browser_engine
