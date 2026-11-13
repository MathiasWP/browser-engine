#include "browser_engine/be_menus.h"

#include "base/memory/raw_ptr.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_menu_model.h"
#include "chrome/browser/ui/tabs/tab_menu_model_delegate.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/toolbar/back_forward_menu_model.h"
#include "components/tabs/public/tab_interface.h"
#include "ui/base/mojom/menu_source_type.mojom-shared.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "ui/views/widget/widget.h"

namespace browser_engine {

namespace {

// The tab menu's commands, run on the tab strip as BrowserTabStripController
// runs them (through TabContextMenuController), less what our windows don't
// have: group focus, vertical tabs, the reading list and Chrome's assistant
// draw in Chrome's own tab strip and side panel, and Send to Your Devices
// needs sync. Split view's are the app's to show (BEWindowSplits).
class TabMenuDelegate : public ui::SimpleMenuModel::Delegate {
 public:
  TabMenuDelegate(TabStripModel* model, tabs::TabHandle tab)
      : model_(model), tab_(tab) {}
  TabMenuDelegate(const TabMenuDelegate&) = delete;
  TabMenuDelegate& operator=(const TabMenuDelegate&) = delete;
  ~TabMenuDelegate() override = default;

  // ui::SimpleMenuModel::Delegate:
  bool IsCommandIdChecked(int command_id) const override { return false; }

  bool IsCommandIdEnabled(int command_id) const override {
    const int index = Index();
    return index != TabStripModel::kNoTab &&
           model_->IsContextMenuCommandEnabled(
               index, static_cast<TabStripModel::ContextMenuCommand>(command_id));
  }

  bool IsCommandIdVisible(int command_id) const override {
    switch (static_cast<TabStripModel::ContextMenuCommand>(command_id)) {
      case TabStripModel::CommandToggleGrouped:
      case TabStripModel::CommandToggleFocusGroup:
      case TabStripModel::CommandToggleVertical:
      case TabStripModel::CommandAddToReadLater:
      case TabStripModel::CommandSendTabToSelf:
      case TabStripModel::CommandGlicShare:
      case TabStripModel::CommandGlicCreateNewChat:
      case TabStripModel::CommandGlicSwitchToRecentConversation:
      case TabStripModel::CommandGlicUnshare:
        return false;
      default:
        return true;
    }
  }

  void ExecuteCommand(int command_id, int event_flags) override {
    const int index = Index();
    if (index != TabStripModel::kNoTab) {
      model_->ExecuteContextMenuCommand(
          index, static_cast<TabStripModel::ContextMenuCommand>(command_id));
    }
  }

 private:
  // Where the tab is now, or kNoTab once it's gone.
  int Index() const {
    tabs::TabInterface* tab = tab_.Get();
    return tab ? model_->GetIndexOfTab(tab) : TabStripModel::kNoTab;
  }

  raw_ptr<TabStripModel> model_;
  tabs::TabHandle tab_;
};

// Runs `model` as a native menu at `screen_point` over `widget`, as Chrome's
// context menus run on the Mac; returns once it closes.
void RunMenu(ui::MenuModel* model,
             views::Widget* widget,
             const gfx::Point& screen_point) {
  views::MenuRunner runner(model, views::MenuRunner::HAS_MNEMONICS |
                                      views::MenuRunner::CONTEXT_MENU);
  runner.RunMenuAt(widget, /*button_controller=*/nullptr,
                   gfx::Rect(screen_point, gfx::Size()),
                   views::MenuAnchorPosition::kTopLeft,
                   ui::mojom::MenuSourceType::kMouse);
}

}  // namespace

void ShowTabMenu(BrowserWindowInterface* browser,
                 views::Widget* widget,
                 int index,
                 const gfx::Point& screen_point) {
  TabStripModel* model = browser->GetTabStripModel();
  if (!model->ContainsIndex(index)) {
    return;
  }
  TabMenuDelegate delegate(model, model->GetTabAtIndex(index)->GetHandle());
  TabMenuModel menu(&delegate, TabMenuModelDelegate::From(browser), model,
                    index);
  RunMenu(&menu, widget, screen_point);
}

void ShowHistoryMenu(BrowserWindowInterface* browser,
                     views::Widget* widget,
                     bool forward,
                     const gfx::Point& screen_point) {
  BackForwardMenuModel menu(
      browser, forward ? BackForwardMenuModel::ModelType::kForward
                       : BackForwardMenuModel::ModelType::kBackward);
  RunMenu(&menu, widget, screen_point);
}

}  // namespace browser_engine
