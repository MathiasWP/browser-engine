#import "browser_engine/be_infobars.h"

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

#include "base/feature_list.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#import "browser_engine/be_tab.h"
#include "chrome/browser/ui/tab_sharing/tab_sharing_infobar_delegate.h"
#include "chrome/browser/ui/ui_features.h"
#include "chrome/browser/ui/views/tab_sharing/tab_sharing_infobar.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/confirm_infobar_delegate.h"
#include "components/infobars/core/infobar.h"
#include "components/infobars/core/infobar_delegate.h"
#include "ui/base/window_open_disposition.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/controls/label.h"
#include "ui/views/view.h"
#include "ui/views/view_utils.h"

namespace {

// An infobar as the app is shown it. Read once, as Chrome's infobar views read
// their delegate once, when they're made.
struct InfobarContents {
  // What the app's buttons do: ConfirmInfoBar's OK and Cancel buttons, and
  // TabSharingInfoBar's.
  enum class Action {
    kAccept,
    kCancel,
    kStopSharing,
    kShareThisTabInstead,
    kShowCapturedSurfaceControl,
  };

  struct Button {
    Action action;
    std::u16string label;
    // Chrome shows a disabled button greyed out (MdTextButton::SetEnabled()),
    // and a press on it does nothing.
    bool enabled = true;
  };

  std::u16string message;
  // In BEInfobar's order, the default (Chrome's prominent one) first.
  std::vector<Button> buttons;
  std::u16string link_text;
  // Set when the link is one in the message rather than the delegate's own
  // (see GetInlineLink()).
  std::optional<size_t> link_substitution;
  bool closable = true;
};

// A message's inline link, as ConfirmInfoBarWithStyledLabel shows it: Chrome
// shows that variant for a delegate with a message template
// (ConfirmInfoBar::Create()), with links in it where its substitutions say.
// Only for a delegate without a link of its own: the app shows one link, after
// the message. At M156 that's AlternateNavInfoBarDelegate ("Did you mean to go
// to http://intranet/?"), whose link is its URL in the message, and the
// centralized framework's RegistryInfoBarDelegate (off by default).
std::optional<size_t> GetInlineLink(const ConfirmInfoBarDelegate& delegate) {
  if (!delegate.GetLinkText().empty() ||
      delegate.GetMessageTextTemplate().empty() ||
      !base::FeatureList::IsEnabled(features::kInfoBarInlineLinks)) {
    return std::nullopt;
  }
  const std::vector<MessageSubstitution>& substitutions =
      delegate.GetMessageSubstitutions();
  auto it = std::ranges::find_if(substitutions, &MessageSubstitution::is_link);
  if (it == substitutions.end()) {
    return std::nullopt;
  }
  return static_cast<size_t>(it - substitutions.begin());
}

// What ConfirmInfoBar shows.
InfobarContents ReadConfirmInfobar(const ConfirmInfoBarDelegate& delegate) {
  using Action = InfobarContents::Action;
  InfobarContents contents;
  // ConfirmInfoBarWithNormalLabel's text. ConfirmInfoBarWithStyledLabel fills
  // the delegate's template in instead (ReplaceStringPlaceholders()), which
  // comes to the same text for both delegates with a template at M156 (their
  // GetMessageText() fills it in).
  contents.message = delegate.GetMessageText();
  // ConfirmInfoBar's constructor: OK, then Cancel. OK is the default when
  // there is one (`type == buttons || type == BUTTON_OK`).
  const int buttons = delegate.GetButtons();
  const auto add_button = [&](ConfirmInfoBarDelegate::InfoBarButton button,
                              Action action) {
    if (buttons & button) {
      contents.buttons.push_back({action, delegate.GetButtonLabel(button),
                                  delegate.GetButtonEnabled(button)});
    }
  };
  add_button(ConfirmInfoBarDelegate::BUTTON_OK, Action::kAccept);
  add_button(ConfirmInfoBarDelegate::BUTTON_CANCEL, Action::kCancel);
  // InfoBarView::CreateLink(), which makes an empty link for none.
  contents.link_text = delegate.GetLinkText();
  if (const std::optional<size_t> index = GetInlineLink(delegate)) {
    contents.link_text = delegate.GetMessageSubstitutions()[*index].text;
    contents.link_substitution = index;
  }
  contents.closable = delegate.IsCloseable();
  return contents;
}

// As TabSharingInfoBar::GetDelegate().
TabSharingInfoBarDelegate* GetTabSharingDelegate(infobars::InfoBar& infobar) {
  return static_cast<TabSharingInfoBarDelegate*>(infobar.delegate());
}

// The tab-sharing infobar's message ("Sharing this tab to meet.google.com"),
// which its view makes from what TabSharingUIViews gives it (the two sites,
// which tab this is) and the delegate doesn't keep: a label for an extension's
// capture, otherwise a TabSharingStatusMessageView, which shows the sites as
// buttons that switch to their tab and whose accessible name is the whole
// message (SetupMessage()).
std::u16string GetTabSharingMessage(infobars::InfoBar* infobar) {
  // Every tab-sharing infobar is a TabSharingInfoBar: the delegate's
  // constructor is private, and Create() wraps it in one
  // (CreateTabSharingInfoBar()). GetStatusMessageViewForTesting() is the one
  // way to its message view.
  // UNVERIFIED: read, not run: the view is never in a widget here, and sets
  // its accessible name without one (ViewAccessibility::SetName() returns
  // early only once a widget has closed).
  const views::View* view = static_cast<TabSharingInfoBar*>(infobar)
                                ->GetStatusMessageViewForTesting();
  if (!view) {
    return std::u16string();
  }
  if (const views::Label* label = views::AsViewClass<views::Label>(view)) {
    return std::u16string(label->GetText());
  }
  return view->GetViewAccessibility().GetCachedName();
}

// What TabSharingInfoBar shows.
InfobarContents ReadTabSharingInfobar(infobars::InfoBar* infobar) {
  using Action = InfobarContents::Action;
  const TabSharingInfoBarDelegate* delegate = GetTabSharingDelegate(*infobar);
  InfobarContents contents;
  contents.message = GetTabSharingMessage(infobar);
  // TabSharingInfoBar's constructor makes them in this order, Stop the
  // default (`type == buttons || type == kStop`); the Mac lays them out
  // reversed, with the default last (PlatformStyle::kIsOkButtonLeading).
  const int buttons = delegate->GetButtons();
  const auto add_button =
      [&](TabSharingInfoBarDelegate::TabSharingInfoBarButton button,
          Action action) {
        if (buttons & button) {
          contents.buttons.push_back({action, delegate->GetButtonLabel(button),
                                      delegate->IsButtonEnabled(button)});
        }
      };
  add_button(TabSharingInfoBarDelegate::kStop, Action::kStopSharing);
  add_button(TabSharingInfoBarDelegate::kShareThisTabInstead,
             Action::kShareThisTabInstead);
  add_button(TabSharingInfoBarDelegate::kCapturedSurfaceControlIndicator,
             Action::kShowCapturedSurfaceControl);
  // The view's link is the delegate's (none, at M156); it has no close
  // button.
  contents.link_text = delegate->GetLinkText();
  contents.closable = delegate->IsCloseable();
  return contents;
}

// What the app is shown of `infobar`, or nothing for the kinds it isn't.
// Every infobar on the Mac at M156 has a ConfirmInfoBarDelegate, except the
// tab-sharing one and two that never reach our windows: SigninQRCodeInfoBar
// shows while signing in to Chrome, which ungoogled-chromium doesn't offer, and
// nothing makes an InterventionInfoBarDelegate.
std::optional<InfobarContents> ReadInfobar(infobars::InfoBar* infobar) {
  infobars::InfoBarDelegate* delegate = infobar->delegate();
  if (const ConfirmInfoBarDelegate* confirm_delegate =
          delegate->AsConfirmInfoBarDelegate()) {
    return ReadConfirmInfobar(*confirm_delegate);
  }
  if (delegate->GetIdentifier() ==
      infobars::InfoBarDelegate::TAB_SHARING_INFOBAR_DELEGATE) {
    return ReadTabSharingInfobar(infobar);
  }
  return std::nullopt;
}

}  // namespace

NS_ASSUME_NONNULL_BEGIN

// What the app holds for one infobar.
@interface BEChromiumInfobar : NSObject <BEInfobar>
- (instancetype)initWithInfobar:(infobars::InfoBar*)infobar
                       contents:(const InfobarContents&)contents
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The infobar was removed, or isn't the tab's any more: nothing more reaches
// Chrome.
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumInfobar {
  // Null once the infobar is removed or gone.
  base::WeakPtr<infobars::InfoBar> _infobar;
  // What `buttons` do, in their order.
  std::vector<InfobarContents::Button> _buttonActions;
  std::optional<size_t> _linkSubstitution;
}

@synthesize message = _message;
@synthesize buttons = _buttons;
@synthesize linkText = _linkText;
@synthesize isClosable = _isClosable;

- (instancetype)initWithInfobar:(infobars::InfoBar*)infobar
                       contents:(const InfobarContents&)contents {
  if ((self = [super init])) {
    _infobar = infobar->AsWeakPtr();
    _message = base::SysUTF16ToNSString(contents.message);
    NSMutableArray<NSString*>* buttons =
        [NSMutableArray arrayWithCapacity:contents.buttons.size()];
    for (const InfobarContents::Button& button : contents.buttons) {
      [buttons addObject:base::SysUTF16ToNSString(button.label)];
    }
    _buttons = [buttons copy];
    _buttonActions = contents.buttons;
    _linkText = base::SysUTF16ToNSString(contents.link_text);
    _linkSubstitution = contents.link_substitution;
    _isClosable = contents.closable;
  }
  return self;
}

- (void)invalidate {
  _infobar.reset();
}

// MARK: BEInfobar

// Each answer reads what it needs from this object first: what it sets off may
// remove the infobar, and the tab lets go of the object then. Chrome's views
// ignore presses on an infobar that's closing (no owner()); so does each
// answer. Removing an infobar deletes it at once (see be_infobars.h), so the
// infobar is looked at again after each call into its delegate.

- (void)pressButtonAtIndex:(NSInteger)index {
  if (index < 0 || static_cast<size_t>(index) >= _buttonActions.size()) {
    return;
  }
  using Action = InfobarContents::Action;
  const InfobarContents::Button& button =
      _buttonActions[static_cast<size_t>(index)];
  const Action action = button.action;
  base::WeakPtr<infobars::InfoBar> infobar = _infobar;
  if (!button.enabled || !infobar || !infobar->owner()) {
    return;
  }
  switch (action) {
    case Action::kAccept:
    case Action::kCancel: {
      // ConfirmInfoBar::OkButtonPressed() and CancelButtonPressed(). An answer
      // may remove the infobar itself and return false (the theme infobar's
      // Undo: the theme it puts back closes it).
      ConfirmInfoBarDelegate* delegate =
          infobar->delegate()->AsConfirmInfoBarDelegate();
      const bool remove =
          action == Action::kAccept ? delegate->Accept() : delegate->Cancel();
      if (remove && infobar) {
        infobar->RemoveSelf();
      }
      return;
    }
    // TabSharingInfoBar's buttons, without the screen-sharing histograms its
    // logger keeps. TabSharingUIViews removes or replaces the infobars of
    // every tab as the capture stops or moves to this tab.
    case Action::kStopSharing:
      GetTabSharingDelegate(*infobar)->Stop();
      return;
    case Action::kShareThisTabInstead:
      GetTabSharingDelegate(*infobar)->ShareThisTabInstead();
      return;
    case Action::kShowCapturedSurfaceControl:
      // Page Info, at the site's captured-surface-control permission
      // (CscIndicatorButton::Click()), floated over the window as BETab's
      // showSiteInfo is.
      GetTabSharingDelegate(*infobar)
          ->OnCapturedSurfaceControlActivityIndicatorPressed();
      return;
  }
}

- (void)openLink {
  const std::optional<size_t> substitution = _linkSubstitution;
  base::WeakPtr<infobars::InfoBar> infobar = _infobar;
  if (_linkText.length == 0 || !infobar || !infobar->owner()) {
    return;
  }
  // A plain click (ui::DispositionFromEventFlags() of no flags). A delegate's
  // own link opens in a new foreground tab (InfoBarDelegate::LinkClicked() →
  // ContentInfoBarManager::OpenURL()); the alternate-address one loads in
  // this tab, as in Chrome.
  const WindowOpenDisposition disposition = WindowOpenDisposition::CURRENT_TAB;
  // InfoBarView::LinkClicked(), or ConfirmInfoBarWithStyledLabel's link.
  const bool remove =
      substitution ? infobar->delegate()
                         ->AsConfirmInfoBarDelegate()
                         ->InlineSubstitutionLinkClicked(*substitution,
                                                         disposition)
                   : infobar->delegate()->LinkClicked(disposition);
  if (remove && infobar) {
    infobar->RemoveSelf();
  }
}

- (void)close {
  const bool closable = _isClosable;
  base::WeakPtr<infobars::InfoBar> infobar = _infobar;
  if (!closable || !infobar || !infobar->owner()) {
    return;  // No close button, or it's going.
  }
  // InfoBarView::CloseButtonPressed().
  infobar->delegate()->InfoBarDismissed();
  if (infobar) {
    infobar->RemoveSelf();
  }
}

@end

namespace browser_engine {

TabInfobars::TabInfobars(BEChromiumTab* owner) : owner_(owner) {}

TabInfobars::~TabInfobars() {
  RemoveAll();
}

void TabInfobars::StartObserving(content::WebContents* contents) {
  // Every tab has a manager (TabHelpers::AttachTabHelpers()); it lives as
  // long as its WebContents.
  infobars::ContentInfoBarManager* manager =
      contents ? infobars::ContentInfoBarManager::FromWebContents(contents)
               : nullptr;
  if (manager && manager_observation_.GetSource() == manager) {
    return;  // The same WebContents: its infobars keep their objects.
  }
  RemoveAll();
  manager_observation_.Reset();
  if (!manager) {
    return;
  }
  manager_observation_.Observe(manager);
  // Those Chrome added before the tab's object was made, such as the startup
  // warnings on the first window's active tab (infobars::
  // AddInfoBarsIfNecessary()).
  for (infobars::InfoBar* infobar : manager->infobars()) {
    Add(infobar);
  }
}

NSArray<id<BEInfobar>>* TabInfobars::GetInfobars() const {
  const infobars::InfoBarManager* manager = manager_observation_.GetSource();
  if (!manager) {
    return @[];
  }
  // In the manager's order: as added, a replacement in the place of the one
  // it replaced (InfoBarManager::ReplaceInfoBar()). Chrome's own container,
  // which shows the active tab's, also holds back all but one closable
  // infobar of default priority, and all but two of critical priority, until
  // the one before closes (InfoBarContainerWithPriority); the app sees them
  // all.
  NSMutableArray<id<BEInfobar>>* result =
      [NSMutableArray arrayWithCapacity:objects_.size()];
  for (infobars::InfoBar* infobar : manager->infobars()) {
    auto it = objects_.find(infobar);
    if (it != objects_.end()) {
      [result addObject:it->second];
    }
  }
  return result;
}

bool TabInfobars::Add(infobars::InfoBar* infobar) {
  std::optional<InfobarContents> contents = ReadInfobar(infobar);
  if (!contents) {
    return false;
  }
  objects_[infobar] = [[BEChromiumInfobar alloc] initWithInfobar:infobar
                                                         contents:*contents];
  return true;
}

bool TabInfobars::Remove(infobars::InfoBar* infobar) {
  auto it = objects_.find(infobar);
  if (it == objects_.end()) {
    return false;
  }
  [it->second invalidate];
  objects_.erase(it);
  return true;
}

void TabInfobars::RemoveAll() {
  for (const auto& entry : objects_) {
    [entry.second invalidate];
  }
  objects_.clear();
}

// Each of these only notes the change: Chrome is in the middle of adding or
// removing, and the app hears of it from the tab's update, a task later.

void TabInfobars::OnInfoBarAdded(infobars::InfoBar* infobar) {
  if (Add(infobar)) {
    [owner_ scheduleUpdate];
  }
}

void TabInfobars::OnInfoBarRemoved(infobars::InfoBar* infobar, bool animate) {
  // Before Chrome deletes it (InfoBarManager::RemoveInfoBarInternal()).
  if (Remove(infobar)) {
    [owner_ scheduleUpdate];
  }
}

void TabInfobars::OnInfoBarReplaced(infobars::InfoBar* old_infobar,
                                    infobars::InfoBar* new_infobar) {
  // A new infobar, with a new object (the tab-sharing ones are replaced when
  // the capture moves to another tab).
  const bool removed = Remove(old_infobar);
  const bool added = Add(new_infobar);
  if (removed || added) {
    [owner_ scheduleUpdate];
  }
}

void TabInfobars::OnManagerWillBeDestroyed(infobars::InfoBarManager* manager) {
  // The WebContents is going. The manager removed its infobars first
  // (~InfoBarManager()), and checks that no observer is left.
  manager_observation_.Reset();
  if (!objects_.empty()) {
    RemoveAll();
    [owner_ scheduleUpdate];
  }
}

}  // namespace browser_engine
