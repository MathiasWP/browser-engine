#import "browser_engine/be_window.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <memory>
#include <optional>
#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/token.h"
#include "browser_engine/be_autocomplete.h"
#include "browser_engine/be_bookmark_bar.h"
#include "browser_engine/be_browser_window.h"
#include "browser_engine/be_history.h"
#include "browser_engine/be_settings_data.h"
#import "browser_engine/be_closed.h"
#import "browser_engine/be_engine.h"
#import "browser_engine/be_extensions_manager.h"
#import "browser_engine/be_autofill_data.h"
#import "browser_engine/be_import.h"
#import "browser_engine/be_passwords_data.h"
#import "browser_engine/be_extensions.h"
#include "browser_engine/be_menus.h"
#import "browser_engine/be_tab.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/predictors/loading_predictor.h"
#include "chrome/browser/predictors/loading_predictor_factory.h"
#include "chrome/browser/preloading/bookmarkbar_preload/bookmarkbar_preload_pipeline_manager.h"
#include "chrome/browser/preloading/chrome_preloading.h"
#include "chrome/browser/preloading/new_tab_page_preload/new_tab_page_preload_pipeline_manager.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/reading_list/reading_list_model_factory.h"
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
#include "chrome/browser/ui/tabs/tab_group_model.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_delegate.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/tabs/public/tab_features.h"
#include "chrome/browser/ui/tabs/tab_strip_user_gesture_details.h"
#include "components/reading_list/core/reading_list_entry.h"
#include "components/reading_list/core/reading_list_model.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_id.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_group.h"
#include "components/tabs/public/tab_interface.h"
#include "net/base/apple/url_conversions.h"
#include "services/network/public/cpp/constants.h"
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
    case BECommandNewTabToRight:
      return IDC_NEW_TAB_TO_RIGHT;
    case BECommandMuteSite:
      return IDC_WINDOW_MUTE_SITE;
    case BECommandPinTab:
      return IDC_WINDOW_PIN_TAB;
    case BECommandGroupTab:
      return IDC_WINDOW_GROUP_TAB;
    case BECommandCloseOtherTabs:
      return IDC_WINDOW_CLOSE_OTHER_TABS;
    case BECommandCloseTabsToRight:
      return IDC_WINDOW_CLOSE_TABS_TO_RIGHT;
    case BECommandMoveTabToNewWindow:
      return IDC_MOVE_TAB_TO_NEW_WINDOW;
    case BECommandBookmarkAllTabs:
      return IDC_BOOKMARK_ALL_TABS;
  }
  return -1;
}

}  // namespace

// What the app sees of a group: a copy of it when `tabGroups` was read.
@interface BEChromiumTabGroup : NSObject <BETabGroup>
- (instancetype)initWithGroup:(const tab_groups::TabGroupId&)group
                      visuals:(const tab_groups::TabGroupVisualData&)visuals
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumTabGroup

@synthesize identifier = _identifier;
@synthesize title = _title;
@synthesize color = _color;
@synthesize isCollapsed = _isCollapsed;

- (instancetype)initWithGroup:(const tab_groups::TabGroupId&)group
                      visuals:(const tab_groups::TabGroupVisualData&)visuals {
  if ((self = [super init])) {
    _identifier = base::SysUTF8ToNSString(group.ToString());
    _title = base::SysUTF16ToNSString(visuals.title());
    // BETabGroupColor follows TabGroupColorId's order.
    _color = static_cast<BETabGroupColor>(visuals.color());
    _isCollapsed = visuals.is_collapsed();
  }
  return self;
}

@end

// One reading list entry as the app reads it: a copy, which doesn't change.
@interface BEChromiumReadingListItem : NSObject <BEReadingListItem>
- (instancetype)initWithEntry:(const ReadingListEntry&)entry;
@end

@implementation BEChromiumReadingListItem

@synthesize url = _url;
@synthesize title = _title;
@synthesize isRead = _isRead;
@synthesize added = _added;

- (instancetype)initWithEntry:(const ReadingListEntry&)entry {
  if ((self = [super init])) {
    _url = net::NSURLWithGURL(entry.URL());
    _title = base::SysUTF8ToNSString(entry.Title());
    _isRead = entry.IsRead();
    // Microseconds since the Unix epoch.
    _added = [NSDate dateWithTimeIntervalSince1970:entry.CreationTime() / 1e6];
  }
  return self;
}

@end

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
  // The history page's data: made when the app first asks, destroyed with the
  // window.
  std::unique_ptr<browser_engine::BEHistory> _history;
  // Settings' own pages' data: made when the app first asks, destroyed with
  // the window.
  std::unique_ptr<browser_engine::BESettingsData> _settingsData;
  // The app's extensions page, passwords, addresses and cards, and importing:
  // each made when the app first asks, destroyed with the window.
  std::unique_ptr<browser_engine::BEExtensionsManager> _extensionsManager;
  std::unique_ptr<browser_engine::BEPasswordsData> _passwordsData;
  std::unique_ptr<browser_engine::BEAutofillData> _autofillData;
  std::unique_ptr<browser_engine::BEImport> _importer;
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
  BOOL _tabGroupsUpdatePending;
  BOOL _tabSplitsUpdatePending;
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

- (browser_engine::BEHistory*)history {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return nullptr;
  }
  if (!_history) {
    _history = std::make_unique<browser_engine::BEHistory>(browser->GetProfile());
  }
  return _history.get();
}

- (browser_engine::BESettingsData*)settingsData {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return nullptr;
  }
  if (!_settingsData) {
    // Changes go to the delegate on a later task: the service may be in the
    // middle of a change of its own.
    __weak BEChromiumWindow* weakSelf = self;
    auto later = [](void (^tell)(void)) {
      return base::BindRepeating(
          [](void (^tell)(void)) {
            base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
                FROM_HERE, base::BindOnce(tell));
          },
          tell);
    };
    _settingsData = std::make_unique<browser_engine::BESettingsData>(
        browser->GetProfile(), later(^{
          BEChromiumWindow* window = weakSelf;
          id delegate = window.delegate;
          if ([delegate respondsToSelector:@selector
                        (windowDidChangeSearchEngines:)]) {
            [delegate windowDidChangeSearchEngines:window];
          }
        }),
        later(^{
          BEChromiumWindow* window = weakSelf;
          id delegate = window.delegate;
          if ([delegate respondsToSelector:@selector
                        (windowDidChangeSiteZoomLevels:)]) {
            [delegate windowDidChangeSiteZoomLevels:window];
          }
        }));
  }
  return _settingsData.get();
}

// A closure telling the delegate `tell` on a later task: the models change
// from inside their own notifications.
static base::RepeatingClosure TellLater(void (^tell)(void)) {
  return base::BindRepeating(
      [](void (^tell)(void)) {
        base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(tell));
      },
      tell);
}

- (browser_engine::BEExtensionsManager*)extensionsManager {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return nullptr;
  }
  if (!_extensionsManager) {
    __weak BEChromiumWindow* weakSelf = self;
    _extensionsManager = std::make_unique<browser_engine::BEExtensionsManager>(
        browser->GetProfile(), TellLater(^{
          BEChromiumWindow* window = weakSelf;
          id delegate = window.delegate;
          if ([delegate respondsToSelector:@selector
                        (windowDidChangeExtensions:)]) {
            [delegate windowDidChangeExtensions:window];
          }
        }));
  }
  return _extensionsManager.get();
}

- (browser_engine::BEPasswordsData*)passwordsData {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return nullptr;
  }
  if (!_passwordsData) {
    __weak BEChromiumWindow* weakSelf = self;
    _passwordsData = std::make_unique<browser_engine::BEPasswordsData>(
        browser->GetProfile(), TellLater(^{
          BEChromiumWindow* window = weakSelf;
          id delegate = window.delegate;
          if ([delegate respondsToSelector:@selector
                        (windowDidChangePasswords:)]) {
            [delegate windowDidChangePasswords:window];
          }
        }));
  }
  return _passwordsData.get();
}

- (browser_engine::BEAutofillData*)autofillData {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return nullptr;
  }
  if (!_autofillData) {
    __weak BEChromiumWindow* weakSelf = self;
    _autofillData = std::make_unique<browser_engine::BEAutofillData>(
        browser->GetProfile(),
        TellLater(^{
          BEChromiumWindow* window = weakSelf;
          id delegate = window.delegate;
          if ([delegate respondsToSelector:@selector
                        (windowDidChangeAddresses:)]) {
            [delegate windowDidChangeAddresses:window];
          }
        }),
        TellLater(^{
          BEChromiumWindow* window = weakSelf;
          id delegate = window.delegate;
          if ([delegate respondsToSelector:@selector
                        (windowDidChangePaymentCards:)]) {
            [delegate windowDidChangePaymentCards:window];
          }
        }));
  }
  return _autofillData.get();
}

- (browser_engine::BEImport*)importer {
  BrowserWindowInterface* browser = [self browser];
  if (!browser) {
    return nullptr;
  }
  if (!_importer) {
    _importer = std::make_unique<browser_engine::BEImport>(browser->GetProfile());
  }
  return _importer.get();
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

- (void)tabGroupsDidChange {
  // A new group comes as several changes (made, its first tab, its look).
  if (_tabGroupsUpdatePending) {
    return;
  }
  _tabGroupsUpdatePending = YES;
  __weak BEChromiumWindow* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        BEChromiumWindow* strongSelf = weakSelf;
        if (strongSelf) {
          strongSelf->_tabGroupsUpdatePending = NO;
          if (strongSelf->_window) {
            [strongSelf->_delegate windowDidChangeTabGroups:strongSelf];
          }
        }
      }));
}

- (void)tabSplitsDidChange {
  // A new split comes as several changes (its tabs moved together, then the
  // split).
  if (_tabSplitsUpdatePending) {
    return;
  }
  _tabSplitsUpdatePending = YES;
  __weak BEChromiumWindow* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        BEChromiumWindow* strongSelf = weakSelf;
        if (!strongSelf) {
          return;
        }
        strongSelf->_tabSplitsUpdatePending = NO;
        id delegate = strongSelf->_delegate;
        if (strongSelf->_window &&
            [delegate respondsToSelector:@selector(windowDidChangeTabSplits:)]) {
          [(id<BEWindowDelegateSplits>)delegate
              windowDidChangeTabSplits:strongSelf];
        }
      }));
}

- (void)wantsEditorForTabGroup:(const tab_groups::TabGroupId&)group {
  // Posted after any pending tabGroupsDidChange task, so the app shows the
  // group before it's asked where it is.
  NSString* identifier = base::SysUTF8ToNSString(group.ToString());
  __weak BEChromiumWindow* weakSelf = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        BEChromiumWindow* strongSelf = weakSelf;
        if (strongSelf && strongSelf->_window) {
          [strongSelf->_delegate window:strongSelf
                 wantsEditorForTabGroup:identifier];
        }
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
  // History's answers still on their way are cancelled with it.
  _history.reset();
  _settingsData.reset();
  _extensionsManager.reset();
  _passwordsData.reset();
  _autofillData.reset();
  // An import under way goes on to its end (it keeps its profile alive).
  _importer.reset();
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

// The window's group with `identifier`, if it still has it.
- (std::optional<tab_groups::TabGroupId>)groupWithIdentifier:
    (NSString*)identifier {
  TabStripModel* model = [self tabStripModel];
  const std::optional<base::Token> token =
      base::Token::FromString(base::SysNSStringToUTF8(identifier));
  if (!model || !model->group_model() || !token) {
    return std::nullopt;
  }
  const tab_groups::TabGroupId group =
      tab_groups::TabGroupId::FromRawToken(*token);
  if (!model->group_model()->ContainsTabGroup(group)) {
    return std::nullopt;
  }
  return group;
}

- (NSString*)profileIdentifier {
  BrowserWindowInterface* browser = [self browser];
  return browser ? base::SysUTF8ToNSString(browser->GetProfile()
                                               ->GetOriginalProfile()
                                               ->GetPath()
                                               .BaseName()
                                               .value())
                 : @"";
}

- (NSArray<id<BETabGroup>>*)tabGroups {
  TabStripModel* model = [self tabStripModel];
  if (!model || !model->group_model()) {
    return @[];
  }
  // A group's tabs are next to each other: each run is one group.
  NSMutableArray<id<BETabGroup>>* groups = [NSMutableArray array];
  std::optional<tab_groups::TabGroupId> previous;
  for (int index = 0; index < model->count(); ++index) {
    const std::optional<tab_groups::TabGroupId> group =
        model->GetTabGroupForTab(index);
    if (group && group != previous) {
      [groups addObject:[[BEChromiumTabGroup alloc]
                            initWithGroup:*group
                                  visuals:*model->group_model()
                                                ->GetTabGroup(*group)
                                                ->visual_data()]];
    }
    previous = group;
  }
  return groups;
}

- (void)setTabGroup:(NSString*)identifier collapsed:(BOOL)collapsed {
  TabStripModel* model = [self tabStripModel];
  const std::optional<tab_groups::TabGroupId> group =
      [self groupWithIdentifier:identifier];
  if (!group) {
    return;
  }
  const tab_groups::TabGroupVisualData visuals =
      *model->group_model()->GetTabGroup(*group)->visual_data();
  if (visuals.is_collapsed() == static_cast<bool>(collapsed)) {
    return;
  }
  // As a click on Chrome's group header
  // (BrowserTabStripController::ToggleTabGroupCollapsedState()): the selected
  // tab leaves a collapsing group for the next tab outside it, or a new tab.
  tabs::TabInterface* active = model->GetActiveTab();
  if (collapsed && active && active->GetGroup() == group) {
    if (const std::optional<int> next =
            model->GetNextExpandedActiveTab(*group)) {
      model->ActivateTabAt(*next,
                           TabStripUserGestureDetails(
                               TabStripUserGestureDetails::GestureType::kOther));
    } else {
      model->delegate()->AddTabAt(GURL(), -1, /*foreground=*/true);
    }
  }
  // The app heard of the switch, and may have changed the group: look again,
  // as Chrome does after activating.
  if (!model->group_model()->ContainsTabGroup(*group)) {
    return;
  }
  model->ChangeTabGroupVisuals(
      *group,
      tab_groups::TabGroupVisualData(visuals.title(), visuals.color(),
                                     collapsed),
      model->group_model()->GetTabGroup(*group)->IsCustomized());
}

- (void)showEditorForTabGroup:(NSString*)identifier
                       atRect:(NSRect)rect
                       inView:(NSView*)view {
  const std::optional<tab_groups::TabGroupId> group =
      [self groupWithIdentifier:identifier];
  if (group && view.window) {
    _window->ShowTabGroupEditor(
        *group, [view.window convertRectToScreen:[view convertRect:rect
                                                            toView:nil]]);
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

// BEWindowPreloading: what Chrome's bookmark buttons (BookmarkButton) and New
// Tab page tiles (MostVisitedHandler) do for the page under the pointer, for
// the app's own bookmarks bar and New Tab page.

- (void)preconnectToURL:(NSURL*)url from:(BEPreloadSource)source {
  // BookmarkButton::StartPreconnecting(), MostVisitedHandler::
  // PreconnectMostVisitedTile().
  BrowserWindowInterface* browser = [self browser];
  const GURL gurl = net::GURLWithNSURL(url);
  if (!browser || !gurl.SchemeIsHTTPOrHTTPS()) {
    return;
  }
  if (predictors::LoadingPredictor* predictor =
          predictors::LoadingPredictorFactory::GetForProfile(
              browser->GetProfile())) {
    predictor->PrepareForPageLoad(
        /*initiator_origin=*/std::nullopt, gurl,
        source == BEPreloadSourceBookmarkBar
            ? predictors::HintOrigin::BOOKMARK_BAR
            : predictors::HintOrigin::NEW_TAB_PAGE,
        network::GetNoOpNetworkRestrictionsId(), /*preconnectable=*/true);
  }
}

- (void)prerenderURL:(nullable NSURL*)url from:(BEPreloadSource)source {
  TabStripModel* model = [self tabStripModel];
  tabs::TabInterface* tab = model ? model->GetActiveTab() : nullptr;
  if (!tab || !tab->GetTabFeatures()) {
    return;
  }
  const GURL gurl = url ? net::GURLWithNSURL(url) : GURL();
  // On mouse-down, and dropped as the pointer leaves (BookmarkButton::
  // OnMousePressed(), OnMouseExited(); MostVisitedHandler::
  // PrerenderMostVisitedTile(), CancelPrerender()). Chrome's pipelines check
  // the preloading setting, and drop a prerender the next navigation doesn't
  // use.
  if (source == BEPreloadSourceBookmarkBar) {
    BookmarkBarPreloadPipelineManager* manager =
        tab->GetTabFeatures()->bookmarkbar_preload_pipeline_manager();
    if (!manager) {
      return;
    }
    if (gurl.SchemeIsHTTPOrHTTPS()) {
      manager->StartPrerender(gurl);
    } else {
      manager->ResetPrerender();
    }
    return;
  }
  NewTabPagePreloadPipelineManager* manager =
      tab->GetTabFeatures()->new_tab_page_preload_pipeline_manager();
  if (!manager) {
    return;
  }
  if (gurl.SchemeIsHTTPOrHTTPS()) {
    manager->StartPrerender(gurl,
                            chrome_preloading_predictor::kPointerDownOnNewTabPage);
  } else {
    manager->ResetPrerender();
  }
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
  _autocomplete->Open(static_cast<size_t>(index),
                      inNewTab ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                               : WindowOpenDisposition::CURRENT_TAB);
}

// BEWindowOpening: ⇧Return in Chrome's omnibox.
- (void)openSuggestionInNewWindowAtIndex:(NSInteger)index {
  if (!_autocomplete || index < 0) {
    return;
  }
  _autocomplete->Open(static_cast<size_t>(index),
                      WindowOpenDisposition::NEW_WINDOW);
}

// BEWindowReadingList: Chrome's reading list (ReadingListModel), the
// window's profile's, as Chrome's side panel and tab menu use it.

- (ReadingListModel*)readingListModel {
  BrowserWindowInterface* browser = [self browser];
  return browser ? ReadingListModelFactory::GetForBrowserContext(
                       browser->GetProfile())
                 : nullptr;
}

- (NSArray<id<BEReadingListItem>>*)readingListItems {
  ReadingListModel* model = [self readingListModel];
  if (!model || !model->loaded()) {
    return @[];
  }
  std::vector<scoped_refptr<const ReadingListEntry>> entries;
  for (const GURL& url : model->GetKeys()) {
    if (scoped_refptr<const ReadingListEntry> entry =
            model->GetEntryByURL(url)) {
      entries.push_back(entry);
    }
  }
  std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
    return a->CreationTime() > b->CreationTime();
  });
  NSMutableArray<id<BEReadingListItem>>* items =
      [NSMutableArray arrayWithCapacity:entries.size()];
  for (const auto& entry : entries) {
    [items addObject:[[BEChromiumReadingListItem alloc] initWithEntry:*entry]];
  }
  return items;
}

- (BOOL)canAddToReadingList:(NSURL*)url {
  ReadingListModel* model = [self readingListModel];
  return model && model->loaded() &&
         model->IsUrlSupported(net::GURLWithNSURL(url));
}

- (void)addToReadingList:(NSURL*)url title:(NSString*)title {
  ReadingListModel* model = [self readingListModel];
  const GURL gurl = net::GURLWithNSURL(url);
  if (!model || !model->loaded() || !model->IsUrlSupported(gurl)) {
    return;
  }
  model->AddOrReplaceEntry(gurl, base::SysNSStringToUTF8(title),
                           reading_list::ADDED_VIA_CURRENT_APP,
                           /*estimated_read_time=*/std::nullopt,
                           /*creation_time=*/std::nullopt);
}

- (void)setReadingListItem:(NSURL*)url read:(BOOL)read {
  if (ReadingListModel* model = [self readingListModel];
      model && model->loaded()) {
    model->SetReadStatusIfExists(net::GURLWithNSURL(url), read);
  }
}

- (void)removeFromReadingList:(NSURL*)url {
  if (ReadingListModel* model = [self readingListModel];
      model && model->loaded()) {
    model->RemoveEntryByURL(net::GURLWithNSURL(url), FROM_HERE);
  }
}

@end
