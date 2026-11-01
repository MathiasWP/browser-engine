// The extensions' toolbar buttons for one window, behind BEWindow's
// extensionActions and runExtensionAction:fromRect:. Chrome's own per-window
// model of them at M156 (ExtensionsToolbarViewModel, with an
// ExtensionActionViewModel per extension), with this object where Chrome's
// Views toolbar (ExtensionsToolbarDesktop) would be: the app draws the
// buttons, and popups anchor to the rect the app runs an action from.

#ifndef BROWSER_ENGINE_BE_EXTENSIONS_H_
#define BROWSER_ENGINE_BE_EXTENSIONS_H_

#import <Foundation/Foundation.h>

#include <map>
#include <memory>
#include <optional>
#include <string>

#include "base/functional/callback_forward.h"
#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/time/time.h"
#import "browser_engine/public/BEEngine.h"
#include "chrome/browser/ui/extensions/extensions_container.h"
#include "chrome/browser/ui/extensions/extensions_toolbar_view_model.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "chrome/browser/ui/views/extensions/extensions_container_views.h"
#include "extensions/common/extension_id.h"
#include "ui/base/unowned_user_data/scoped_unowned_user_data.h"
#include "ui/gfx/geometry/rect.h"

@class BEChromiumWindow;

class ExtensionActionViewModel;
class ToolbarActionViewModel;

namespace content {
class WebContents;
}  // namespace content

namespace views {
class FocusManager;
class View;
class Widget;
}  // namespace views

namespace browser_engine {

class BEBrowserWindow;

// One per window (not for guest profiles, as Chrome's toolbar), made by
// BEBrowserWindow before the app hears of the window and destroyed before its
// widget. While it lives it is the window's ExtensionsContainer, so
// chrome.action.openPopup(), extension shortcuts (_execute_action) and
// DevTools' Extensions.triggerAction find the buttons, as in Chrome.
//
// Changes go to the window ([BEChromiumWindow extensionActionsDidChange]),
// which tells the app on a later task.
class BEExtensions : public ExtensionsToolbarViewModel::Delegate,
                     public ExtensionsToolbarViewModel::Observer,
                     public ExtensionsContainerViews {
 public:
  BEExtensions(BEBrowserWindow* window, BEChromiumWindow* objc_window);
  BEExtensions(const BEExtensions&) = delete;
  BEExtensions& operator=(const BEExtensions&) = delete;
  ~BEExtensions() override;

  // The buttons for the active tab: the pinned ones in the toolbar's order,
  // then the others by name, as the extensions menu lists them. Empty while
  // the window has no tab.
  NSArray<id<BEExtensionAction>>* GetActions();

  // A click on the action's toolbar button, which is at `rect` in the app (in
  // the window's coordinates, from its bottom left): Chrome runs the action,
  // and its popup, if it has one, opens below `rect`. A click on the button
  // whose popup is open closes it. Does nothing for an id Chrome doesn't
  // have.
  void Run(const std::string& action_id, NSRect rect);

 private:
  class Action;

  // A popup that closed while a mouse button was down: a press outside the
  // popup closed it (see OnPopupClosed()).
  struct PopupClosedByPress {
    extensions::ExtensionId action_id;
    // Where the press was, in screen coordinates (AppKit's).
    NSPoint location;
    base::TimeTicks time;
  };

  // Tells the window that what the app shows may have changed.
  void ActionsChanged();

  // Where `action_id`'s popup anchors, in the widget's root view: where the
  // app last ran it from, or the window's top right corner.
  gfx::Rect GetAnchorRect(const extensions::ExtensionId& action_id) const;

  // ExtensionsToolbarViewModel::Delegate:
  std::unique_ptr<ExtensionActionViewModel> CreateActionViewModel(
      const ToolbarActionsModel::ActionId& action_id,
      ExtensionsContainer* extensions_container) override;
  void HideActivePopup() override;
  void CloseExtensionsMenuIfOpen() override;
  bool CanShowToolbarActionPopupForAPICall(
      const ToolbarActionsModel::ActionId& action_id) override;
  void ToggleExtensionsMenu() override;

  // ExtensionsToolbarViewModel::Observer:
  void OnActionsInitialized() override;
  void OnActionAdded(const ToolbarActionsModel::ActionId& action_id) override;
  void OnActionRemoved(
      const ToolbarActionsModel::ActionId& action_id) override;
  void OnActionUpdated(
      const ToolbarActionsModel::ActionId& action_id) override;
  void OnPinnedActionsChanged() override;
  void OnActiveWebContentsChanged(bool is_same_document,
                                  content::WebContents* web_contents) override;
  void OnRequestAccessButtonParamsChanged(
      content::WebContents* web_contents) override;
  void OnToolbarControlStateUpdated() override;

  // ExtensionsContainerViews:
  bool IsVisible() const override;
  std::optional<extensions::ExtensionId> GetPoppedOutActionId() const override;
  bool IsActionVisibleOnToolbar(const std::string& action_id) const override;
  void UndoPopOut() override;
  void SetPopupOwner(ToolbarActionViewModel* popup_owner) override;
  void PopOutAction(const extensions::ExtensionId& action_id,
                    base::OnceClosure closure) override;
  void ShowWidgetForExtension(views::Widget* widget,
                              const std::string& extension_id) override;
  void CollapseConfirmation() override;
  void ShowContextMenuAsFallback(
      const extensions::ExtensionId& action_id) override;
  void OnPopupShown(const extensions::ExtensionId& action_id,
                    bool by_user) override;
  void OnPopupClosed(const extensions::ExtensionId& action_id) override;
  views::FocusManager* GetFocusManagerForAccelerator() override;
  views::BubbleAnchor GetReferenceButtonForPopup(
      const extensions::ExtensionId& action_id) override;
  views::BubbleAnchor GetExtensionsButtonAnchor() override;
  views::BubbleBorder::Arrow GetPopupArrow() const override;

  const raw_ptr<BEBrowserWindow> window_;
  __weak BEChromiumWindow* objc_window_;

  // What popups anchor to, as to a toolbar button: an empty view in the
  // widget's root view (which owns it), out of layout, events and
  // accessibility, moved over the action's rect before each popup.
  raw_ptr<views::View> anchor_view_ = nullptr;
  // Where the app last ran each action from, in the root view's coordinates.
  std::map<extensions::ExtensionId, gfx::Rect> anchor_rects_;

  // Ours for each of `toolbar_view_model_`'s actions, from
  // CreateActionViewModel() until OnActionRemoved().
  std::map<ToolbarActionsModel::ActionId, std::unique_ptr<Action>> actions_;

  // The action whose popup is open or opening, as the toolbar tracks it.
  raw_ptr<ToolbarActionViewModel> popup_owner_ = nullptr;
  std::optional<extensions::ExtensionId> popped_out_action_;

  // Until the next Run().
  std::optional<PopupClosedByPress> popup_closed_by_press_;

  // Declared after everything CreateActionViewModel() fills in, since the
  // view model's constructor calls it.
  std::unique_ptr<ExtensionsToolbarViewModel> toolbar_view_model_;
  // The view model is the window's ExtensionsContainer, as in Chrome's
  // toolbar.
  ui::ScopedUnownedUserData<ExtensionsContainer> scoped_container_;
  base::ScopedObservation<ExtensionsToolbarViewModel,
                          ExtensionsToolbarViewModel::Observer>
      toolbar_view_model_observation_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_EXTENSIONS_H_
