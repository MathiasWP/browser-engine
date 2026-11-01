#import "browser_engine/be_extensions.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <utility>
#include <vector>

#include "base/check.h"
#include "base/functional/callback.h"
#include "base/i18n/case_conversion.h"
#include "base/strings/sys_string_conversions.h"
#include "browser_engine/be_browser_window.h"
#import "browser_engine/be_window.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/extensions/extension_action_view_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/views/extensions/extension_action_delegate_desktop.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_icon_factory.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/common/extension.h"
#include "skia/ext/skia_utils_mac.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_util_mac.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_anchor.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/view.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"

NS_ASSUME_NONNULL_BEGIN

// One extension's button as the app reads it: a copy, which doesn't change.
@interface BEChromiumExtensionAction : NSObject <BEExtensionAction>
- (instancetype)initWithIdentifier:(NSString*)identifier
                             title:(NSString*)title
                              icon:(nullable NSImage*)icon
                         badgeText:(NSString*)badgeText
                        badgeColor:(nullable NSColor*)badgeColor
                         isEnabled:(BOOL)isEnabled NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumExtensionAction

@synthesize identifier = _identifier;
@synthesize title = _title;
@synthesize icon = _icon;
@synthesize badgeText = _badgeText;
@synthesize badgeColor = _badgeColor;
@synthesize isEnabled = _isEnabled;

- (instancetype)initWithIdentifier:(NSString*)identifier
                             title:(NSString*)title
                              icon:(NSImage*)icon
                         badgeText:(NSString*)badgeText
                        badgeColor:(NSColor*)badgeColor
                         isEnabled:(BOOL)isEnabled {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _title = [title copy];
    _icon = icon;
    _badgeText = [badgeText copy];
    _badgeColor = badgeColor;
    _isEnabled = isEnabled;
  }
  return self;
}

@end

namespace browser_engine {

namespace {

// How long after a press closed a popup the click it began can come: the app
// hears of a click on its button on mouse up (see Run()).
constexpr base::TimeDelta kPressToClick = base::Seconds(1);

// Where popups anchor when the app hasn't run the action yet (from an
// extension's chrome.action.openPopup() or keyboard shortcut): the window's
// top right corner, below a bar as tall as the title bar the traffic lights
// sit in (kTitlebarHeight in be_browser_window.mm), as near as we can get to
// where Chrome's toolbar would put the button.
constexpr int kFallbackAnchorInset = 12;
constexpr int kFallbackAnchorHeight = 40;

}  // namespace

// What we keep for one action next to Chrome's view model of it: the action's
// own icon for each tab, without the badge (the view model's GetIcon() paints
// the badge in, and the app draws its own from badgeText and badgeColor).
class BEExtensions::Action
    : public extensions::ExtensionActionIconFactory::Observer {
 public:
  // `model` is `toolbar_view_model_`'s and outlives this.
  Action(BEExtensions* owner,
         ExtensionActionViewModel* model,
         const extensions::Extension* extension,
         extensions::ExtensionAction* extension_action)
      : owner_(owner),
        model_(model),
        extension_action_(extension_action),
        icon_factory_(extension, extension_action, this) {}
  Action(const Action&) = delete;
  Action& operator=(const Action&) = delete;
  ~Action() override = default;

  ExtensionActionViewModel* model() const { return model_; }

  // What the app shows for `contents`, the active tab; nil while the
  // extension unloads, before its action goes (OnActionRemoved()).
  BEChromiumExtensionAction* Snapshot(content::WebContents* contents) {
    // Null once the extension isn't enabled any more, which it stops being
    // before anyone hears it unload (ExtensionActionViewModel's
    // ExtensionIsValid()). Until then `extension_action_` is alive.
    if (!model_->GetExtension()) {
      return nil;
    }
    const int tab_id = sessions::SessionTabHelper::IdForTab(contents).id();
    std::u16string title = model_->GetActionTitle(contents);
    if (title.empty()) {
      title = model_->GetActionName();
    }
    // A new NSImage each time, from the image's own representations: the
    // factory hands out one cached gfx::Image, whose NSImage would keep the
    // icon as it was before it finished loading.
    const gfx::Image icon = icon_factory_.GetIcon(tab_id);
    // No color set is transparent, for which Chrome paints its default
    // (IconWithBadgeImageSource): nil, the app's.
    const SkColor badge_color =
        extension_action_->GetBadgeBackgroundColor(tab_id);
    return [[BEChromiumExtensionAction alloc]
        initWithIdentifier:base::SysUTF8ToNSString(model_->GetId())
                     title:base::SysUTF16ToNSString(title)
                      icon:gfx::NSImageFromImageSkia(icon.AsImageSkia())
                 badgeText:base::SysUTF8ToNSString(
                               extension_action_->GetDisplayBadgeText(tab_id))
                badgeColor:SkColorGetA(badge_color) == SK_AlphaTRANSPARENT
                               ? nil
                               : skia::SkColorToSRGBNSColor(badge_color)
                 isEnabled:model_->IsEnabled(contents)];
  }

 private:
  // extensions::ExtensionActionIconFactory::Observer:
  void OnIconUpdated() override {
    // The default icon finished loading (it loads asynchronously).
    owner_->ActionsChanged();
  }

  const raw_ptr<BEExtensions> owner_;
  const raw_ptr<ExtensionActionViewModel> model_;
  // ExtensionActionManager's; it goes when the extension unloads, as the
  // view model's does.
  const raw_ptr<extensions::ExtensionAction, DanglingUntriaged>
      extension_action_;
  extensions::ExtensionActionIconFactory icon_factory_;
};

BEExtensions::BEExtensions(BEBrowserWindow* window,
                           BEChromiumWindow* objc_window)
    : window_(window),
      objc_window_(objc_window),
      toolbar_view_model_(std::make_unique<ExtensionsToolbarViewModel>(
          this,
          window->browser(),
          ToolbarActionsModel::Get(window->browser()->GetProfile()))),
      scoped_container_(window->browser()->GetUnownedUserDataHost(),
                        *toolbar_view_model_) {
  // The anchor goes into the root view, next to the NonClientView, rather
  // than into the NativeViewHost with the app's view: a NativeViewHost takes
  // any child added to or removed from it for its own (re)attachment
  // (NativeViewHost::ViewHierarchyChanged()).
  auto anchor_view = std::make_unique<views::View>();
  anchor_view->SetProperty(views::kViewIgnoredByLayoutKey, true);
  anchor_view->SetCanProcessEventsWithinSubtree(false);
  anchor_view->GetViewAccessibility().SetIsIgnored(true);
  anchor_view_ =
      window_->widget()->GetRootView()->AddChildView(std::move(anchor_view));

  toolbar_view_model_observation_.Observe(toolbar_view_model_.get());
}

BEExtensions::~BEExtensions() {
  // As when Chrome's toolbar buttons leave their widget, while it and its
  // FocusManager are still there: no popup (the view model mustn't go with one
  // open), no shortcuts.
  HideActivePopup();
  for (const auto& [action_id, action] : actions_) {
    action->model()->UnregisterCommand();
  }
  // Before the view models they point to.
  actions_.clear();
}

NSArray<id<BEExtensionAction>>* BEExtensions::GetActions() {
  content::WebContents* contents =
      window_->browser()->GetTabStripModel()->GetActiveWebContents();
  // Nothing before the first tab, nor while the window closes (where
  // Webium's container stops updating too).
  if (!contents) {
    return @[];
  }

  // Pinned first, in the toolbar's order (ToolbarActionsModel keeps only
  // pinned ids it has).
  const std::vector<ToolbarActionsModel::ActionId>& pinned_ids =
      toolbar_view_model_->GetPinnedActionIds();
  std::vector<Action*> ordered;
  ordered.reserve(actions_.size());
  for (const ToolbarActionsModel::ActionId& action_id : pinned_ids) {
    if (auto it = actions_.find(action_id); it != actions_.end()) {
      ordered.push_back(it->second.get());
    }
  }
  // Then the others by name, case-insensitively, as the extensions menu sorts
  // them (SortActionsByName() in extensions_menu_view_model.cc).
  std::vector<std::pair<std::u16string, Action*>> unpinned;
  for (const auto& [action_id, action] : actions_) {
    if (std::ranges::find(pinned_ids, action_id) == pinned_ids.end()) {
      unpinned.emplace_back(
          base::i18n::ToLower(action->model()->GetActionName()),
          action.get());
    }
  }
  std::ranges::stable_sort(unpinned, {},
                           &std::pair<std::u16string, Action*>::first);
  for (const auto& [name, action] : unpinned) {
    ordered.push_back(action);
  }

  NSMutableArray<id<BEExtensionAction>>* actions =
      [NSMutableArray arrayWithCapacity:ordered.size()];
  for (Action* action : ordered) {
    if (BEChromiumExtensionAction* snapshot = action->Snapshot(contents)) {
      [actions addObject:snapshot];
    }
  }
  return actions;
}

void BEExtensions::Run(const std::string& action_id, NSRect rect) {
  auto it = actions_.find(action_id);
  NSWindow* ns_window = window_->GetNativeWindow().GetNativeNSWindow();
  if (it == actions_.end() || !ns_window ||
      !window_->browser()->GetTabStripModel()->GetActiveWebContents()) {
    return;
  }
  ExtensionActionViewModel* model = it->second->model();
  const NSRect screen_rect = [ns_window convertRectToScreen:rect];

  // A click on the button of the open popup closes it, as in Chrome's
  // toolbar. Usually the popup has closed already: the press activated the
  // window under it, which closes the popup (ExtensionPopup::
  // OnWidgetTreeActivated()), and the app hears of the click only on mouse
  // up. Chrome's button ignores the press that closed its popup; so do we.
  const std::optional<PopupClosedByPress> closed_by_press =
      std::exchange(popup_closed_by_press_, std::nullopt);
  if (model->IsShowingPopup()) {
    model->HidePopup();
    return;
  }
  if (closed_by_press && closed_by_press->action_id == action_id &&
      NSPointInRect(closed_by_press->location, screen_rect) &&
      base::TimeTicks::Now() - closed_by_press->time < kPressToClick) {
    return;
  }

  // Popups anchor below the rect (GetReferenceButtonForPopup()). Views wants
  // it in the root view's coordinates, from the top left; through the screen,
  // so Views' own conversion places it.
  const gfx::Rect bounds_in_screen = gfx::ScreenRectFromNSRect(screen_rect);
  gfx::Point origin = bounds_in_screen.origin();
  views::View::ConvertPointFromScreen(anchor_view_->parent(), &origin);
  anchor_rects_[action_id] = gfx::Rect(origin, bounds_in_screen.size());

  // Chrome's toolbar button (ToolbarActionView::ButtonPressed()): the popup,
  // or the click event to the extension, granting it the tab (activeTab and
  // withheld site access, which may run its blocked scripts or ask to
  // reload). A disabled action asks for its context menu instead
  // (ShowContextMenuAsFallback()). Every change it causes comes back as a
  // model update.
  model->ExecuteUserAction(
      ToolbarActionViewModel::InvocationSource::kToolbarButton);
}

void BEExtensions::ActionsChanged() {
  [objc_window_ extensionActionsDidChange];
}

gfx::Rect BEExtensions::GetAnchorRect(
    const extensions::ExtensionId& action_id) const {
  auto it = anchor_rects_.find(action_id);
  if (it != anchor_rects_.end()) {
    return it->second;
  }
  return gfx::Rect(anchor_view_->parent()->width() - kFallbackAnchorInset, 0,
                   0, kFallbackAnchorHeight);
}

// ExtensionsToolbarViewModel::Delegate ----------------------------------------

std::unique_ptr<ExtensionActionViewModel> BEExtensions::CreateActionViewModel(
    const ToolbarActionsModel::ActionId& action_id,
    ExtensionsContainer* extensions_container) {
  // As ExtensionsToolbarDesktop makes them: the desktop delegate shows the
  // popup (ExtensionPopup), anchored where we say.
  std::unique_ptr<ExtensionActionViewModel> model =
      ExtensionActionViewModel::Create(
          action_id, window_->browser(),
          std::make_unique<ExtensionActionDelegateDesktop>(
              window_->browser(), extensions_container, this));
  // The extension's shortcut for its button (_execute_action), on our
  // widget's FocusManager, as a toolbar button registers it when it's added
  // to the widget. ExtensionKeybindingRegistryViews leaves those to the
  // toolbar.
  model->RegisterCommand();

  // Create() found both, or it would have crashed.
  const extensions::Extension* extension = model->GetExtension();
  CHECK(extension);
  extensions::ExtensionAction* extension_action =
      extensions::ExtensionActionManager::Get(window_->browser()->GetProfile())
          ->GetExtensionAction(*extension);
  CHECK(extension_action);
  actions_.insert_or_assign(
      action_id, std::make_unique<Action>(this, model.get(), extension,
                                          extension_action));
  return model;
}

void BEExtensions::HideActivePopup() {
  // Closing it calls SetPopupOwner(nullptr).
  if (popup_owner_) {
    popup_owner_->HidePopup();
  }
}

void BEExtensions::CloseExtensionsMenuIfOpen() {}  // No extensions menu.

bool BEExtensions::CanShowToolbarActionPopupForAPICall(
    const ToolbarActionsModel::ActionId& action_id) {
  // ExtensionsToolbarDesktop's rule: not over another popup, and only in the
  // active window.
  return !popped_out_action_ && window_->IsActive();
}

void BEExtensions::ToggleExtensionsMenu() {}  // The app's, if it has one.

// ExtensionsToolbarViewModel::Observer ----------------------------------------

void BEExtensions::OnActionsInitialized() {
  ActionsChanged();
}

void BEExtensions::OnActionAdded(
    const ToolbarActionsModel::ActionId& action_id) {
  ActionsChanged();
}

void BEExtensions::OnActionRemoved(
    const ToolbarActionsModel::ActionId& action_id) {
  // The view model is no longer the toolbar model's, but alive until this
  // returns (ExtensionsToolbarViewModel::OnToolbarActionRemoved()).
  if (auto it = actions_.find(action_id); it != actions_.end()) {
    ExtensionActionViewModel* model = it->second->model();
    if (model->IsShowingPopup()) {
      model->HidePopup();
    }
    model->UnregisterCommand();
    actions_.erase(it);
  }
  if (popped_out_action_ == action_id) {
    popped_out_action_.reset();
  }
  anchor_rects_.erase(action_id);
  ActionsChanged();
}

void BEExtensions::OnActionUpdated(
    const ToolbarActionsModel::ActionId& action_id) {
  // Title, icon, badge, visibility (ExtensionActionDispatcher), or site
  // access.
  ActionsChanged();
}

void BEExtensions::OnPinnedActionsChanged() {
  ActionsChanged();
}

void BEExtensions::OnActiveWebContentsChanged(
    bool is_same_document,
    content::WebContents* web_contents) {
  // Another tab, or a navigation: each tab has its own state.
  ActionsChanged();
}

void BEExtensions::OnRequestAccessButtonParamsChanged(
    content::WebContents* web_contents) {
  // A site access request came or went, which can enable an action.
  ActionsChanged();
}

void BEExtensions::OnToolbarControlStateUpdated() {
  ActionsChanged();
}

// ExtensionsContainerViews ----------------------------------------------------

bool BEExtensions::IsVisible() const {
  return window_->widget()->IsVisible();
}

std::optional<extensions::ExtensionId> BEExtensions::GetPoppedOutActionId()
    const {
  return popped_out_action_;
}

bool BEExtensions::IsActionVisibleOnToolbar(
    const std::string& action_id) const {
  const std::vector<ToolbarActionsModel::ActionId>& pinned_ids =
      toolbar_view_model_->GetPinnedActionIds();
  return popped_out_action_ == action_id ||
         std::ranges::find(pinned_ids, action_id) != pinned_ids.end();
}

void BEExtensions::UndoPopOut() {
  popped_out_action_.reset();
}

void BEExtensions::SetPopupOwner(ToolbarActionViewModel* popup_owner) {
  popup_owner_ = popup_owner;
}

void BEExtensions::PopOutAction(const extensions::ExtensionId& action_id,
                                base::OnceClosure closure) {
  // The toolbar slides an unpinned button out first; the app's buttons are
  // where they are, so the popup opens now.
  popped_out_action_ = action_id;
  std::move(closure).Run();
}

void BEExtensions::ShowWidgetForExtension(views::Widget* widget,
                                          const std::string& extension_id) {
  // Bubbles about one extension (extension_dialog_utils_views.cc), anchored
  // as its popup would be. Unused today: ShowDialog() looks for the
  // container through BrowserView and shows those as modal dialogs instead.
  if (views::BubbleDialogDelegate* bubble =
          widget->widget_delegate()->AsBubbleDialogDelegate()) {
    bubble->SetAnchor(GetReferenceButtonForPopup(extension_id));
  }
  widget->Show();
}

void BEExtensions::CollapseConfirmation() {}  // No request access button.

void BEExtensions::ShowContextMenuAsFallback(
    const extensions::ExtensionId& action_id) {
  // A click on a disabled button opens Chrome's context menu for it. The app
  // gets isEnabled and leaves those buttons alone ("does nothing on this
  // tab"), so nothing shows.
}

void BEExtensions::OnPopupShown(const extensions::ExtensionId& action_id,
                                bool by_user) {}

void BEExtensions::OnPopupClosed(const extensions::ExtensionId& action_id) {
  // A press outside the popup closes it on mouse down; Run() needs to know if
  // that press began a click on the action's own button.
  // UNVERIFIED: that the popup is gone (its ExtensionHost destroyed, which is
  // what calls this) before the button comes up. Read from
  // ExtensionPopup::CloseDeferredIfNecessary() and
  // NativeWidgetNSWindowBridge::CloseWindow() (closed on the next tasks), not
  // run. If not, Run() finds the popup still open and closes it, which looks
  // the same.
  if ([NSEvent pressedMouseButtons] != 0) {
    popup_closed_by_press_ = PopupClosedByPress{
        action_id, [NSEvent mouseLocation], base::TimeTicks::Now()};
  }
}

views::FocusManager* BEExtensions::GetFocusManagerForAccelerator() {
  return window_->widget()->GetFocusManager();
}

views::BubbleAnchor BEExtensions::GetReferenceButtonForPopup(
    const extensions::ExtensionId& action_id) {
  // One popup at a time (ExtensionActionDelegateDesktop closes the open one
  // first), so one anchor will do.
  anchor_view_->SetBoundsRect(GetAnchorRect(action_id));
  return views::BubbleAnchor(anchor_view_.get());
}

views::BubbleAnchor BEExtensions::GetExtensionsButtonAnchor() {
  // There's no puzzle piece: the corner.
  anchor_view_->SetBoundsRect(GetAnchorRect(extensions::ExtensionId()));
  return views::BubbleAnchor(anchor_view_.get());
}

views::BubbleBorder::Arrow BEExtensions::GetPopupArrow() const {
  // As the toolbar: the popup drops down from the button, its right edge on
  // the button's, mirrored if that would put it off the screen
  // (PlatformStyle::kAdjustBubbleIfOffscreen).
  return views::BubbleBorder::TOP_RIGHT;
}

}  // namespace browser_engine
