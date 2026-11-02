#import "browser_engine/be_window.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <memory>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "browser_engine/be_autocomplete.h"
#include "browser_engine/be_bookmark_bar.h"
#include "browser_engine/be_browser_window.h"
#import "browser_engine/be_closed.h"
#import "browser_engine/be_engine.h"
#import "browser_engine/be_extensions.h"
#include "browser_engine/be_menus.h"
#import "browser_engine/be_tab.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/sessions/exit_type_service.h"
#include "chrome/browser/sessions/session_restore.h"
#include "chrome/browser/tab_list/tab_removed_reason.h"
#include "chrome/browser/ui/bookmarks/bookmark_bar.h"
#include "chrome/browser/ui/bookmarks/bookmark_bar_controller.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/tabs/tab_strip_user_gesture_details.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "ui/base/window_open_disposition_utils.h"
#include "ui/events/cocoa/cocoa_event_utils.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/mac/coordinate_conversion.h"
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
    // Version 2: the ids of Chrome's own Mac main menu items
    // (main_menu_builder.mm).
    case BECommandReloadBypassingCache:
      return IDC_RELOAD_BYPASSING_CACHE;
    case BECommandZoomIn:
      return IDC_ZOOM_PLUS;
    case BECommandZoomOut:
      return IDC_ZOOM_MINUS;
    case BECommandZoomReset:
      return IDC_ZOOM_NORMAL;
    case BECommandPrint:
      return IDC_PRINT;
    case BECommandSavePage:
      return IDC_SAVE_PAGE;
    case BECommandOpenFile:
      return IDC_OPEN_FILE;
    case BECommandViewSource:
      return IDC_VIEW_SOURCE;
    case BECommandDevTools:
      // ⌥⌘I. Like F12's IDC_DEV_TOOLS_TOGGLE, it closes DevTools docked to
      // the page and opens or activates it otherwise
      // (DevToolsWindow::ToggleDevToolsWindow).
      return IDC_DEV_TOOLS;
    case BECommandDevToolsConsole:
      return IDC_DEV_TOOLS_CONSOLE;
    case BECommandDevToolsInspect:
      return IDC_DEV_TOOLS_INSPECT;
    case BECommandShowHistory:
      return IDC_SHOW_HISTORY;
    case BECommandShowDownloads:
      return IDC_SHOW_DOWNLOADS;
    case BECommandBookmarkPage:
      return IDC_BOOKMARK_THIS_TAB;
    case BECommandShowBookmarks:
      return IDC_SHOW_BOOKMARK_MANAGER;
    case BECommandClearBrowsingData:
      return IDC_CLEAR_BROWSING_DATA;
    case BECommandDuplicateTab:
      return IDC_DUPLICATE_TAB;
    case BECommandTaskManager:
      return IDC_TASK_MANAGER_MAIN_MENU;
    case BECommandToggleBookmarkBar:
      return IDC_SHOW_BOOKMARK_BAR;
  }
  return -1;
}

}  // namespace

@implementation BEChromiumWindow {
  // Null once the window closed.
  browser_engine::BEBrowserWindow* _window;
  base::WeakPtr<BrowserWindowInterface> _browser;
  // The address bar's suggestions: made for the first one, destroyed with the
  // window.
  std::unique_ptr<browser_engine::BEAutocomplete> _autocomplete;
  // The bookmarks bar's clicks, menus and drops: made for the first, destroyed
  // with the window.
  std::unique_ptr<browser_engine::BEBookmarkBar> _bookmarkBar;
  // showsBookmarkBar as the delegate last heard it.
  BOOL _showsBookmarkBar;
  BOOL _bookmarkBarUpdatePending;
  // isPageFullscreen as the delegate last heard it.
  BOOL _pageFullscreen;
  // From Chrome's offer to restore after a crash until the app answers or the
  // window closes.
  BOOL _offersRestoreAfterCrash;
  // offersRestoreAfterCrash as the delegate last heard it.
  BOOL _restoreOffer;
  // While the offer stands: ExitTypeService keeps the crashed session, and
  // saves no new one, until it goes. The bubble's delegate holds the same.
  // Null if ExitTypeService had stopped waiting already.
  std::unique_ptr<ExitTypeService::CrashedLock> _crashedLock;
  // statusText as the delegate last heard it.
  NSString* _status;
  // A task to tell the delegate is on its way.
  BOOL _statusUpdatePending;
  BOOL _extensionActionsUpdatePending;
}

@synthesize delegate = _delegate;

- (instancetype)initWithBrowserWindow:(browser_engine::BEBrowserWindow*)window {
  CHECK(window);
  if ((self = [super init])) {
    _window = window;
    _browser = window->browser()->GetWeakPtr();
    _status = @"";
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

// Tells the delegate if isPageFullscreen changed since it last heard.
- (void)sendPageFullscreenIfChanged {
  // Nothing after windowWillClose:.
  if (!_window) {
    return;
  }
  const BOOL pageFullscreen = [self isPageFullscreen];
  if (pageFullscreen == _pageFullscreen) {
    return;
  }
  _pageFullscreen = pageFullscreen;
  [_delegate windowDidChangePageFullscreen:self];
}

// Tells the delegate if offersRestoreAfterCrash changed since it last heard.
- (void)sendRestoreOfferIfChanged {
  // Nothing after windowWillClose:.
  if (!_window) {
    return;
  }
  if (_offersRestoreAfterCrash == _restoreOffer) {
    return;
  }
  _restoreOffer = _offersRestoreAfterCrash;
  [_delegate windowDidChangeRestoreOffer:self];
}

// The offer came or went: tell the delegate on a later task. Chrome makes the
// offer while the tab strip notifies its observers, where the app mustn't act.
- (void)restoreOfferDidChange {
  __weak BEChromiumWindow* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        [weakSelf sendRestoreOfferIfChanged];
      }));
}

// Tells the delegate if statusText changed since it last heard.
- (void)sendStatusIfChanged {
  _statusUpdatePending = NO;
  // Nothing after windowWillClose:.
  if (!_window) {
    return;
  }
  NSString* status = [self statusText];
  if ([status isEqualToString:_status]) {
    return;
  }
  _status = status;
  [_delegate windowDidChangeStatus:self];
}

- (void)sendBookmarkBarIfChanged {
  _bookmarkBarUpdatePending = NO;
  // Nothing after windowWillClose:.
  if (!_window) {
    return;
  }
  const BOOL shows = [self showsBookmarkBar];
  if (shows == _showsBookmarkBar) {
    return;
  }
  _showsBookmarkBar = shows;
  [_delegate windowDidChangeBookmarkBar:self];
}

// The bar's clicks, menus and drops, made on first use; null once the window
// closed.
- (browser_engine::BEBookmarkBar*)bookmarkBar {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return nullptr;
  }
  if (!_bookmarkBar) {
    _bookmarkBar = std::make_unique<browser_engine::BEBookmarkBar>(browser);
  }
  return _bookmarkBar.get();
}

- (void)sendExtensionActionsUpdate {
  _extensionActionsUpdatePending = NO;
  // Nothing after windowWillClose:.
  if (_window) {
    [_delegate windowDidUpdateExtensionActions:self];
  }
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

- (NSRect)bookmarkButtonRect {
  return _window ? [_delegate bookmarkButtonRectForWindow:self] : NSZeroRect;
}

- (void)fullscreenStateDidChange {
  // Chrome calls this while its FullscreenController notifies (from a task it
  // posted). Look again on a task of our own, so the app never runs inside
  // Chrome's fullscreen code, and tell it only of a real change: in and
  // straight back out is none.
  __weak BEChromiumWindow* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        [weakSelf sendPageFullscreenIfChanged];
      }));
}

- (void)offerRestoreAfterCrash {
  BrowserWindowInterface* browser = [self browser];
  if (!browser || _offersRestoreAfterCrash) {
    return;
  }
  _offersRestoreAfterCrash = YES;
  // What the bubble's delegate takes when it's made
  // (session_crashed_bubble_view.cc). If a window opened outside startup has
  // acknowledged the crash already there's no lock, and the offer stands
  // anyway, as the bubble would.
  if (ExitTypeService* exit_type_service =
          ExitTypeService::GetInstanceForProfile(browser->GetProfile())) {
    _crashedLock = exit_type_service->CreateCrashedLock();
  }
  [self restoreOfferDidChange];
}

- (void)bookmarkBarStateDidChange {
  // From inside Chrome's tab-strip and navigation notifications.
  if (_bookmarkBarUpdatePending) {
    return;
  }
  _bookmarkBarUpdatePending = YES;
  __weak BEChromiumWindow* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        [weakSelf sendBookmarkBarIfChanged];
      }));
}

- (void)statusTextDidChange {
  // Chrome sets the bubble from inside its own updates (a link under the
  // pointer, a load's progress), often several times a task: look once, on a
  // task of our own, and tell the app only of a real change.
  if (_statusUpdatePending) {
    return;
  }
  _statusUpdatePending = YES;
  __weak BEChromiumWindow* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        [weakSelf sendStatusIfChanged];
      }));
}

- (void)browserWindowWillClose {
  if (!_window) {
    return;
  }
  [_delegate windowWillClose:self];
  _window = nullptr;
  _browser.reset();
  // After the app let go, so nothing makes it again; before the Browser and
  // its profile go, which the controller's providers read. A pending update
  // dies with it.
  _autocomplete.reset();
  _bookmarkBar.reset();
  // An offer still open goes with the window, as the bubble goes with its
  // browser: unless Chrome is shutting down, the crash counts as acknowledged
  // (ExitTypeService::CheckUserAckedCrash()). UNVERIFIED: that runs inside
  // ~Browser, where SessionService then rebuilds its commands from the open
  // browsers; it skips one without tabs or a window (session_service_base.cc),
  // read, not run.
  _offersRestoreAfterCrash = NO;
  _crashedLock.reset();
}

- (void)suggestionsDidUpdate:(NSArray<id<BESuggestion>>*)suggestions {
  if (_window) {
    [_delegate window:self didUpdateSuggestions:suggestions];
  }
}

- (void)extensionActionsDidChange {
  // From inside Chrome's models' notifications, where the app mustn't read
  // them back (the view models are still changing), and often for several
  // actions at once.
  if (_extensionActionsUpdatePending) {
    return;
  }
  _extensionActionsUpdatePending = YES;
  __weak BEChromiumWindow* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        [weakSelf sendExtensionActionsUpdate];
      }));
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

- (BOOL)isPageFullscreen {
  return _window && _window->IsPageFullscreen();
}

- (BOOL)offersRestoreAfterCrash {
  return _offersRestoreAfterCrash;
}

- (void)restoreAfterCrash {
  BrowserWindowInterface* browser = [self browser];
  if (!browser || !_offersRestoreAfterCrash) {
    return;
  }
  _offersRestoreAfterCrash = NO;
  [self restoreOfferDidChange];
  // SessionCrashedBubbleDelegate::RestorePreviousSession(): the lock goes
  // only once restoring has begun, so ExitTypeService waits for the restore
  // to finish before it lets the old session go.
  std::unique_ptr<ExitTypeService::CrashedLock> lock = std::move(_crashedLock);
  if (browser_shutdown::HasShutdownStarted() || browser->IsDeleteScheduled()) {
    // A late answer: the bubble takes it as handled and restores nothing.
    return;
  }
  // The last session's first window into this one (in place of a lone New
  // Tab page), the others as new windows. Asynchronous: the tabs arrive
  // later, as tab events.
  SessionRestore::RestoreSessionAfterCrash(browser);
}

- (void)declineRestoreAfterCrash {
  if (!_window || !_offersRestoreAfterCrash) {
    return;
  }
  _offersRestoreAfterCrash = NO;
  // As when the bubble closes: with no lock left, ExitTypeService takes the
  // crash as acknowledged, and Chrome saves the session from now on.
  _crashedLock.reset();
  [self restoreOfferDidChange];
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

- (NSArray<id<BEExtensionAction>>*)extensionActions {
  // None for guest profiles, as in Chrome, and none after windowWillClose:.
  browser_engine::BEExtensions* extensions =
      _window ? _window->extensions() : nullptr;
  return extensions ? extensions->GetActions() : @[];
}

- (void)runExtensionAction:(NSString*)identifier fromRect:(NSRect)rect {
  if (browser_engine::BEExtensions* extensions =
          _window ? _window->extensions() : nullptr) {
    extensions->Run(base::SysNSStringToUTF8(identifier), rect);
  }
}

// `point` in `view` as Chromium's screen coordinates, for its menus.
- (gfx::Point)screenPoint:(NSPoint)point inView:(NSView*)view {
  return gfx::ScreenPointFromNSPoint([view.window
      convertPointToScreen:[view convertPoint:point toView:nil]]);
}

- (void)showMenuForTabAtIndex:(NSInteger)index
                      atPoint:(NSPoint)point
                       inView:(NSView*)view {
  BrowserWindowInterface* browser = [self browser];
  if (browser && view.window) {
    browser_engine::ShowTabMenu(browser, _window->widget(),
                                static_cast<int>(index),
                                [self screenPoint:point inView:view]);
  }
}

- (void)showHistoryMenuForward:(BOOL)forward
                       atPoint:(NSPoint)point
                        inView:(NSView*)view {
  BrowserWindowInterface* browser = [self browser];
  if (browser && view.window) {
    browser_engine::ShowHistoryMenu(browser, _window->widget(), forward,
                                    [self screenPoint:point inView:view]);
  }
}

- (void)moveTabAtIndex:(NSInteger)index toNewWindowWithFrame:(NSRect)frame {
  TabStripModel* model = [self tabStripModel];
  if (!model || !model->ContainsIndex(static_cast<int>(index))) {
    return;
  }
  // As the tab menu's Move Tab to New Window (chrome::MoveTabsToNewWindow()),
  // then where the tab was dropped, as Chrome's tab dragging places it.
  tabs::TabInterface* tab = model->GetTabAtIndex(static_cast<int>(index));
  const tabs::TabHandle handle = tab->GetHandle();
  chrome::MoveTabsToNewWindow([self browser], {static_cast<int>(index)});
  tabs::TabInterface* moved = handle.Get();
  if (BrowserWindowInterface* target =
          moved ? moved->GetBrowserWindowInterface() : nullptr) {
    target->GetWindow()->SetBounds(gfx::ScreenRectFromNSRect(frame));
  }
}

- (void)moveTabAtIndex:(NSInteger)index
              toWindow:(id<BEWindow>)window
               atIndex:(NSInteger)targetIndex {
  TabStripModel* model = [self tabStripModel];
  BEChromiumWindow* target = [(id)window isKindOfClass:[BEChromiumWindow class]]
                                 ? static_cast<BEChromiumWindow*>(window)
                                 : nil;
  TabStripModel* targetModel = target ? [target tabStripModel] : nullptr;
  if (!model || !targetModel || targetModel == model ||
      !model->ContainsIndex(static_cast<int>(index)) || targetIndex < 0) {
    return;
  }
  // As dropping a dragged tab on another window's strip does (TabDragController
  // attaching it there): detached here, inserted and selected there.
  std::unique_ptr<tabs::TabModel> tab =
      model->DetachTabAtForInsertion(static_cast<int>(index));
  targetModel->InsertDetachedTabAt(
      std::min(static_cast<int>(targetIndex), targetModel->count()),
      std::move(tab), AddTabTypes::ADD_ACTIVE);
  [target browser]->GetWindow()->Activate();
}

- (void)restoreClosedItem:(int32_t)identifier {
  // The app's History menu calls this, never from inside a tab-strip change.
  if (BrowserWindowInterface* browser = [self browser]) {
    browser_engine::RestoreClosedItem(browser, identifier);
  }
}

- (NSString*)statusText {
  return _window ? base::SysUTF16ToNSString(_window->GetStatusText()) : @"";
}

- (BOOL)showsBookmarkBar {
  BrowserWindowInterface* browser = [self browser];
  const BookmarkBarController* controller =
      browser ? BookmarkBarController::From(browser) : nullptr;
  return controller && controller->bookmark_bar_state() == BookmarkBar::SHOW;
}

- (void)openBookmark:(int64_t)identifier event:(NSEvent*)event {
  // BookmarkBarView::OnButtonPressed(): where the click's modifiers and
  // button send it.
  const WindowOpenDisposition disposition =
      event ? ui::DispositionFromEventFlags(
                  ui::EventFlagsFromNSEventWithModifiers(event,
                                                         event.modifierFlags))
            : WindowOpenDisposition::CURRENT_TAB;
  // Last: opening can replace this window's page, or close nothing; the app
  // calls it from a click, never from inside a Chrome notification.
  if (browser_engine::BEBookmarkBar* bar = [self bookmarkBar]) {
    bar->Open(identifier, disposition);
  }
}

- (void)showMenuForBookmark:(int64_t)identifier
                    atPoint:(NSPoint)point
                     inView:(NSView*)view {
  NSWindow* window = view.window;
  browser_engine::BEBookmarkBar* bar = [self bookmarkBar];
  if (!bar || !window) {
    return;
  }
  const NSPoint screen =
      [window convertPointToScreen:[view convertPoint:point toView:nil]];
  bar->ShowMenu(identifier, gfx::ScreenPointFromNSPoint(screen));
}

- (void)moveBookmark:(int64_t)bookmark
            toFolder:(int64_t)folder
             atIndex:(NSInteger)index {
  if (browser_engine::BEBookmarkBar* bar = [self bookmarkBar];
      bar && index >= 0) {
    bar->Move(bookmark, folder, static_cast<size_t>(index));
  }
}

- (void)addBookmarkForURL:(NSURL*)url
                    title:(NSString*)title
                 toFolder:(int64_t)folder
                  atIndex:(NSInteger)index {
  if (browser_engine::BEBookmarkBar* bar = [self bookmarkBar];
      bar && index >= 0) {
    bar->Add(net::GURLWithNSURL(url), base::SysNSStringToUTF16(title), folder,
             static_cast<size_t>(index));
  }
}

- (void)suggestForText:(NSString*)text
    allowsInlineCompletion:(BOOL)allowsInlineCompletion {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return;
  }
  if (!_autocomplete) {
    _autocomplete =
        std::make_unique<browser_engine::BEAutocomplete>(browser, self);
  }
  _autocomplete->Start(base::SysNSStringToUTF16(text), allowsInlineCompletion);
}

- (void)stopSuggesting {
  if (_autocomplete) {
    _autocomplete->Stop();
  }
}

- (void)openSuggestionAtIndex:(NSInteger)index inNewTab:(BOOL)inNewTab {
  if (!_autocomplete || index < 0) {
    return;
  }
  // Last: opening can close this window's tab, and so the window.
  _autocomplete->Open(static_cast<size_t>(index), inNewTab);
}

@end
