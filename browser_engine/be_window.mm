#import "browser_engine/be_window.h"

#import <AppKit/AppKit.h>

#include "base/check.h"
#include "base/memory/weak_ptr.h"
#include "browser_engine/be_browser_window.h"
#import "browser_engine/be_engine.h"
#import "browser_engine/be_tab.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/tab_list/tab_removed_reason.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/tabs/tab_strip_user_gesture_details.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"

namespace {

// BECommand to Chrome's command id (chrome/app/chrome_command_ids.h), or -1.
int CommandIdForCommand(BECommand command) {
  switch (command) {
    case BECommandNewTab:
      return IDC_NEW_TAB;
    case BECommandNewWindow:
      return IDC_NEW_WINDOW;
    case BECommandNewPrivateWindow:
      return IDC_NEW_INCOGNITO_WINDOW;
    case BECommandCloseTab:
      return IDC_CLOSE_TAB;
    case BECommandCloseWindow:
      return IDC_CLOSE_WINDOW;
    case BECommandReopenClosedTab:
      return IDC_RESTORE_TAB;
    case BECommandBack:
      return IDC_BACK;
    case BECommandForward:
      return IDC_FORWARD;
    case BECommandReload:
      return IDC_RELOAD;
    case BECommandStop:
      return IDC_STOP;
    case BECommandSelectNextTab:
      return IDC_SELECT_NEXT_TAB;
    case BECommandSelectPreviousTab:
      return IDC_SELECT_PREVIOUS_TAB;
    case BECommandFocusLocation:
      return IDC_FOCUS_LOCATION;
    case BECommandFind:
      return IDC_FIND;
    case BECommandFindNext:
      return IDC_FIND_NEXT;
    case BECommandFindPrevious:
      return IDC_FIND_PREVIOUS;
  }
  return -1;
}

}  // namespace

@implementation BEChromiumWindow {
  // Null once the window closed.
  browser_engine::BEBrowserWindow* _window;
  base::WeakPtr<BrowserWindowInterface> _browser;
}

@synthesize delegate = _delegate;

- (instancetype)initWithBrowserWindow:(browser_engine::BEBrowserWindow*)window {
  CHECK(window);
  if ((self = [super init])) {
    _window = window;
    _browser = window->browser()->GetWeakPtr();
  }
  return self;
}

// The browser while the window is open, or null.
- (BrowserWindowInterface*)browser {
  return _window ? _browser.get() : nullptr;
}

- (TabStripModel*)tabStripModel {
  BrowserWindowInterface* browser = [self browser];
  return browser ? browser->GetTabStripModel() : nullptr;
}

// MARK: Called by BEBrowserWindow

- (void)announce {
  id<BEEngineDelegate> engineDelegate = browser_engine::GetEngineDelegate();
  DCHECK(engineDelegate);
  [engineDelegate engineDidCreateWindow:self];
}

- (void)tabStripModelChanged:(const TabStripModelChange&)change
                   selection:(const TabStripSelectionChange&)selection {
  id<BEWindowDelegate> delegate = _delegate;
  switch (change.type()) {
    case TabStripModelChange::kInserted:
      // In the order Chrome made the changes, with the index at the time of
      // each (see TabStripModelChange::Insert).
      for (const auto& inserted : change.GetInsert()->contents) {
        [delegate window:self
            didInsertTab:[BEChromiumTab tabForTab:inserted.tab.get()]
                 atIndex:inserted.index];
      }
      break;
    case TabStripModelChange::kRemoved:
      for (const auto& removed : change.GetRemove()->contents) {
        // The same object reappears if the tab moved to another window.
        [delegate window:self
            didRemoveTab:[BEChromiumTab tabForTab:removed.tab.get()]
                 atIndex:removed.index];
        if (TabRemoveReasonUtils::WillDeleteTab(removed.remove_reason)) {
          [BEChromiumTab forgetTab:removed.tab.get()];
        }
      }
      break;
    case TabStripModelChange::kMoved: {
      const TabStripModelChange::Move* move = change.GetMove();
      [delegate window:self
            didMoveTab:[BEChromiumTab tabForTab:move->tab.get()]
             fromIndex:move->from_index
               toIndex:move->to_index];
      break;
    }
    case TabStripModelChange::kReplaced: {
      // Discarding, or a prerendered page swapping in: same tab, new page
      // (and so a new view). If it's the active tab, didActivateTab: below
      // tells the app to show the new view.
      BEChromiumTab* tab =
          [BEChromiumTab existingTabForTab:change.GetReplace()->tab.get()];
      [tab contentsDidChange];
      break;
    }
    case TabStripModelChange::kSelectionOnly:
      break;
  }

  // After the insertion that may have caused it, never before.
  if (selection.active_tab_changed() && selection.new_tab) {
    [delegate window:self
        didActivateTab:[BEChromiumTab tabForTab:selection.new_tab.get()]];
  }
}

- (void)activeTabDidChange {
  TabStripModel* model = [self tabStripModel];
  if (!model) {
    return;
  }
  [[BEChromiumTab existingTabForTab:model->GetActiveTab()] scheduleUpdate];
}

- (void)wantsLocationFocus {
  [_delegate windowWantsLocationFocus:self];
}

- (void)browserWindowWillClose {
  if (!_window) {
    return;
  }
  [_delegate windowWillClose:self];
  _window = nullptr;
  _browser.reset();
}

// MARK: BEWindow

- (NSWindow*)nativeWindow {
  // Nil after windowWillClose:.
  return _window ? _window->GetNativeWindow().GetNativeNSWindow() : nil;
}

- (void)setContentView:(NSView*)view {
  if (_window) {
    _window->SetContentView(view);
  }
}

- (BOOL)isPrivate {
  BrowserWindowInterface* browser = [self browser];
  return browser && browser->GetProfile()->IsOffTheRecord();
}

- (NSArray<id<BETab>>*)tabs {
  TabStripModel* model = [self tabStripModel];
  if (!model) {
    return @[];
  }
  NSMutableArray<id<BETab>>* tabs =
      [NSMutableArray arrayWithCapacity:model->count()];
  for (int i = 0; i < model->count(); ++i) {
    [tabs addObject:[BEChromiumTab tabForTab:model->GetTabAtIndex(i)]];
  }
  return tabs;
}

- (NSInteger)activeIndex {
  TabStripModel* model = [self tabStripModel];
  if (!model || model->empty()) {
    return -1;
  }
  return model->active_index();
}

- (void)runCommand:(BECommand)command {
  BrowserWindowInterface* browser = [self browser];
  const int command_id = CommandIdForCommand(command);
  if (!browser || command_id < 0) {
    return;
  }
  // As a key equivalent or menu item would: Chrome checks whether the command
  // is enabled and records it.
  chrome::ExecuteCommand(browser, command_id);
}

- (BOOL)canRunCommand:(BECommand)command {
  BrowserWindowInterface* browser = [self browser];
  const int command_id = CommandIdForCommand(command);
  return browser && command_id >= 0 &&
         chrome::IsCommandEnabled(browser, command_id);
}

- (void)activateTabAtIndex:(NSInteger)index {
  TabStripModel* model = [self tabStripModel];
  if (!model || !model->ContainsIndex(static_cast<int>(index))) {
    return;
  }
  model->ActivateTabAt(static_cast<int>(index),
                       TabStripUserGestureDetails(
                           TabStripUserGestureDetails::GestureType::kOther));
}

- (void)moveTabAtIndex:(NSInteger)from toIndex:(NSInteger)to {
  TabStripModel* model = [self tabStripModel];
  if (!model || !model->ContainsIndex(static_cast<int>(from)) ||
      !model->ContainsIndex(static_cast<int>(to))) {
    return;
  }
  // Chrome may adjust `to` (pinned tabs, groups); the app follows didMoveTab:.
  model->MoveWebContentsAt(static_cast<int>(from), static_cast<int>(to),
                           /*select_after_move=*/false);
}

- (void)closeTabAtIndex:(NSInteger)index {
  TabStripModel* model = [self tabStripModel];
  if (!model || !model->ContainsIndex(static_cast<int>(index))) {
    return;
  }
  // Like a click on the tab's close button: beforeunload may keep it, and it
  // goes into "reopen closed tab".
  model->CloseWebContentsAt(
      static_cast<int>(index),
      TabCloseTypes::CLOSE_USER_GESTURE |
          TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
}

- (void)openURL:(NSURL*)url inBackground:(BOOL)inBackground {
  BrowserWindowInterface* browser = [self browser];
  const GURL gurl = net::GURLWithNSURL(url);
  if (!browser || !gurl.is_valid()) {
    return;
  }
  NavigateParams params(browser, gurl, ui::PAGE_TRANSITION_LINK);
  params.disposition = inBackground ? WindowOpenDisposition::NEW_BACKGROUND_TAB
                                    : WindowOpenDisposition::NEW_FOREGROUND_TAB;
  const int active_index = browser->GetTabStripModel()->active_index();
  if (active_index != TabStripModel::kNoTab) {
    params.tabstrip_index = active_index + 1;
    params.tabstrip_add_types |= AddTabTypes::ADD_FORCE_INDEX;
  }
  Navigate(&params);
}

@end
