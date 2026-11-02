// Chrome's menus for the app's own buttons: the tab menu (TabMenuModel, as
// BrowserTabStripController shows it on a tab) and the back and forward menus
// (BackForwardMenuModel, as the toolbar's back and forward buttons show them),
// each run as a native menu over our widget.

#ifndef BROWSER_ENGINE_BE_MENUS_H_
#define BROWSER_ENGINE_BE_MENUS_H_

class BrowserWindowInterface;

namespace gfx {
class Point;
}  // namespace gfx

namespace views {
class Widget;
}  // namespace views

namespace browser_engine {

// Runs Chrome's menu for the tab at `index` at `screen_point` (Chromium's
// screen coordinates), returning once it closes; what's chosen runs on the
// tab, or on all selected tabs if the tab is one of them, as in Chrome.
void ShowTabMenu(BrowserWindowInterface* browser,
                 views::Widget* widget,
                 int index,
                 const gfx::Point& screen_point);

// Runs Chrome's back (or forward) menu at `screen_point`, returning once it
// closes.
void ShowHistoryMenu(BrowserWindowInterface* browser,
                     views::Widget* widget,
                     bool forward,
                     const gfx::Point& screen_point);

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_MENUS_H_
