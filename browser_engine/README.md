# browser_engine: Chromium as our app's engine

The embedding layer that turns this ungoogled-chromium build into the engine the
browser app (Swift, AppKit) runs **in its own process**, as Dia runs ArcCore. Chrome's
browser layer stays in charge: `Browser`, `TabStripModel`, profiles, session restore,
commands, extensions, downloads. What goes is Chrome's Views browser UI (`BrowserView`):
in its place is `BEBrowserWindow`, Chrome's third production `BrowserWindow` after
`BrowserView` and Webium's `WebUIBrowserWindow`, whose shape it follows at M156.

The app and the engine meet only in `public/BEEngine.h` (a verbatim copy of the app's
`Sources/BrowserEngineAPI/include/BEEngine.h`; `BE_API_VERSION` 11) and `public/BEEngineOptional.h`
(the same, for additions the app uses only where an engine has them, so adding one leaves
`BE_API_VERSION` and the engines built for it alone; 4 Nov 2026). The framework exports one
function, `BEEngineCreate`.

First draft, 30 Oct 2026, against Chromium 156.0.8078.47. Nothing here has been compiled
yet; the first CI run is the first compile (see "Risks for the first compile").

## How it fits together

```
app main()  ─ makes NSApp (its own NSApplication, CrAppControlProtocol)
            ─ dlopen(Contents/Frameworks/Chromium Framework.framework) → BEEngineCreate(1)
            ─ [engine runWithArguments:delegate:]  → ChromeMain(argv) (blocks until quit)
Chromium    ─ startup / session restore / ⌘N / window.open / chrome.windows.create
            ─ Browser::Browser → BrowserWindow::CreateBrowserWindow  (patch 03)
                 → BEBrowserWindow: views::Widget (NSWindow) + NativeViewHost
            ─ BrowserWindowFeatures::InitPostWindowConstruction → embedder hook (patch 05)
                 → BEChromiumWindow → [delegate engineDidCreateWindow:]   (synchronous)
app         ─ window.delegate = …; [window setContentView:root]; (no tabs yet)
Chromium    ─ adds tabs → TabStripModelObserver → didInsertTab:/didActivateTab:…
app         ─ puts tab.view (the WebContents' NSView) in its page area
```

- **The window.** Chrome makes a `views::Widget` for each normal window, exactly as Webium
  does (`BENativeWidgetMac` is Webium's `WebUIBrowserNativeWidgetMac`: full-size content
  view, transparent title bar, `WindowClass::kBrowser`, Chrome's command dispatcher). The
  widget's client contents view is a `views::NativeViewHost`; the app's root NSView, given
  through `-[BEWindow setContentView:]`, is attached to it.
  *Why a NativeViewHost and not a plain subview of the widget's content NSView:* it is how
  `views::WebView` hosts pages on the Mac (`native_view_host_mac.mm` adds the NSView to the
  widget's `BridgedContentView` and keeps its frame equal to the client area), and it keeps
  the view in Views' accessibility tree (`NativeViewHost::GetNativeViewAccessible`), so
  VoiceOver can walk from the window into the page. A bare `addSubview:` would be invisible
  to Views' focus and accessibility. Its one constraint: `AttachNativeView()` CHECKs that the
  view has no child widgets, so call `setContentView:` once, before pages show.
- **Pages.** `BETab.view` is `WebContents::GetNativeView()`; the app adds it where it wants
  (content_shell style). Page visibility follows the NSView entering and leaving the window.
- **Tabs and windows to the app.** `BEBrowserWindow` observes the `TabStripModel` and
  forwards insert/remove/move/replace, then activation, from `OnTabStripModelChanged()`.
  Not from `BrowserWindow::OnActiveTabChanged()`: `Browser` observes the strip first and calls
  that before our observer runs, so a new foreground tab would be "activated" before it was
  "inserted". `BETab` objects are kept per `TabHandle` for the process, so a tab is the same
  object across windows and across discarding (`kReplaced` swaps its WebContents; the app
  gets `didActivateTab:` again and must re-read `tab.view`).
- **Updates.** Each `BETab` watches its WebContents (loading, progress, navigation, title,
  security, crash) and its favicon driver, plus Chrome's own `OnTabChangedAt()` and the
  window's `UpdateToolbar*`/`UpdateTitleBar` calls, the location bar's
  `UpdateContentSettingsIcons()` for the active tab (site settings), and the tab's
  `ContentInfoBarManager` (infobars); `tabDidUpdate:` is coalesced to one per task.
- **Commands.** `BECommand` maps to Chrome command ids and runs through
  `chrome::ExecuteCommand` / `chrome::IsCommandEnabled`, so tab restore, extensions and
  policies see them as Chrome's own. Key equivalents the page doesn't take are redispatched
  to the app's main menu (Webium's Mac path), then to the widget's FocusManager (extension
  shortcuts), as `BrowserView::HandleKeyboardEvent` does. Chrome's own accelerator table on
  the Mac (F12, F7, Esc) follows BrowserView too: the page sees the key first, and Chrome runs
  it only if the page and the app's menu don't. Only reserved commands run before the page,
  and on the Mac those (⌘W, ⌘T...) are the app's menu items.
- **Start and quit.** No `AppController`, no main menu, no `BrowserCrApplication` when
  embedded (patches 07, 08, 09). The hooks take over AppController's part: its keep-alive
  (the process lives with no windows), dropping it on `NSApplicationWillTerminateNotification`
  (which `chrome::HandleAppExitingForPlatform()` posts when the last browser is gone), the
  TabRestoreService reset at the end of the main loop, queueing `openURLs:` until startup
  is done. `-[BEEngine quit]` is AppController's `-tryToTerminateApplication` minus its
  dialogs: `chrome::OnClosingAllBrowsers(true)` + `chrome::CloseAllBrowsersAndQuit()`
  (BrowserCloseManager runs beforeunload everywhere; "Stay" cancels the quit), after which
  `runWithArguments:delegate:` returns.

## File map

| File | What |
|---|---|
| `BUILD.gn` | `:hooks` (dependency-free, what Chromium's files include) and `:browser_engine` (the layer; linked into the framework via `//chrome:chrome_dll`) |
| `public/BEEngine.h` | The interface, verbatim from the app |
| `browser_engine_hooks.{h,cc}` | `browser_engine::Hooks`, `IsEmbedded()`: the only thing the touch points call (content's two in touch point 31 only `IsEmbedded()`) |
| `be_engine.{h,mm}` | `BEEngineCreate`, `BEChromiumEngine` (`BEEngine`), the hooks implementation, NSApp stand-ins, and BrowserCrApplication's accessibility activation (`BEAppAccessibility`) |
| `be_preferences.{h,mm}` | `BEChromiumPreferences` (`BEPreferences`): the last used profile's `PrefService`, then Local State |
| `be_downloads.{h,mm}` | `BEDownloads`: the downloads of every profile with one of our windows (`AllDownloadItemNotifier`), as `BEDownload` objects; keep and discard as Chrome's download bubble does |
| `be_passwords.{h,mm}` | `TabPasswordOffer`: Chrome's offer to save or update a password, read from the tab's password page action (the bubble itself needs Chrome's toolbar), as `BEPasswordOffer`; its answers replay the bubble's (`SaveUpdateBubbleController`) |
| `be_autocomplete.{h,mm}` | `BEAutocomplete`: a window's address-bar suggestions, Chrome's `AutocompleteController` with the omnibox's local providers, and opening a suggestion as the omnibox does |
| `be_browser_window.{h,mm}` | `BEBrowserWindow : BrowserWindow`, its widget delegate and `BENativeWidgetMac` |
| `be_browser_window_parts.{h,mm}` | Never-null parts Chrome asks for: `BELocationBar`, `BEExclusiveAccessContext`, `BEModalDialogHost`, `BEFindBarOwner` (Webium's, re-pointed), and `BEStatusBubble` (a link's address or the load status, for `BEWindow.statusText`) |
| `be_bubble_anchor.{h,mm}` | `BEBubbleAnchor`: what Chrome's bubbles anchor to when their button is the app's, an empty view in the widget's root view placed over the app's rect (extension popups, site-setting bubbles) |
| `be_extensions.{h,mm}` | `BEExtensions`: a window's extension buttons, Chrome's `ExtensionsToolbarViewModel` with this as its delegate and the window's `ExtensionsContainer` (so `ExtensionsContainer::From()`, `chrome.action.openPopup()` and extension shortcuts find our windows); popups anchor to the app's button rect (`BEBubbleAnchor`) |
| `be_infobars.{h,mm}` | `TabInfobars`: the page's infobars (`BETab.infobars`) from the tab's `ContentInfoBarManager`, watched across WebContents swaps, as `BEInfobar` (one object per infobar for its life), since only BrowserView shows infobars; the answers are those of Chrome's `ConfirmInfoBar`, `InfoBarView` and `TabSharingInfoBar` |
| `be_site_settings.{h,mm}` | The address bar's site-setting icons (`BETab.siteSettings`): Chrome's `ContentSettingImageModel`s for the page, as `BESiteSetting`; `BESiteSettings`, per window, shows an icon's `ContentSettingBubbleContents` below the app's rect, as a click on Chrome's `ContentSettingImageView` does, and watches the macOS location permission as `LocationBarView` does |
| `be_closed.{h,mm}` | `BERecentlyClosed`: the everyday profile's `TabRestoreService` entries as Chrome's History menu lists them (`BEEngine.recentlyClosed`), `RestoreClosedItem()`, and `RequestPageFavicon()`, the menu's icon request for both its sections |
| `be_visited.{h,mm}` | `BERecentlyVisited`: the everyday profile's latest pages as Chrome's History menu lists them ("Recently Visited": `HistoryService::QueryHistory()` with the menu's options, asked again 750 ms after history changes), as `BEVisitedPage` (`BEEngine.recentlyVisited`) |
| `be_bookmarks.{h,mm}` | `BEBookmarks`: the everyday profile's bookmarks as Chrome's Bookmarks menu lists them (`BookmarkMenuBridge`, through `BookmarkMergedSurfaceService`) and its bookmarks bar shows them (the bar folder, All Bookmarks), as `BEBookmark` (`BEEngine.bookmarks`, `bookmarkBar`, `otherBookmarks`), listed again on the first read after a change, which `engineDidChangeBookmarks:` announces; icons from `BookmarkModel::GetFavicon()` when read |
| `be_bookmark_bar.{h,mm}` | `BEBookmarkBar`: a window's bookmarks bar as `BookmarkBarView` drives Chrome's: `BookmarkBarUIControllerImpl` with the desktop adapters opens bookmarks and folders and shows Chrome's `BookmarkContextMenu`; drops go through `BookmarkUIOperationsHelperMergedSurfaces::DropBookmarks()` with the bar's drop rules. `BEBrowserWindow` is the window's `BookmarkBarController::Delegate`, for `BEWindow.showsBookmarkBar` |
| `be_window.{h,mm}` | `BEChromiumWindow` (`BEWindow`): commands, tab strip events, extension actions, status text |
| `be_window_native_ui.mm` | The app's own UI in place of Chrome's, for a window: bookmark editing, the tab menu's and tab group editor's commands, find in page, the history page's data (`BEWindowBookmarkEditing`, `BEWindowTabCommands`, `BEWindowFind`, `BEWindowHistory`) |
| `be_window_splits.mm` | Split view for the app (`BEWindowSplits`): Chrome's own split tabs (`TabStripModel::AddToNewSplit` and the rest), so sessions, restore and ⇧⌘T keep them. `BEBrowserWindow::OnSplitTabChanged` tells the app (`windowDidChangeTabSplits:`) and gives both panes the window's colours; a click in the other pane activates its tab (`TabObserver::OnWebContentsFocused`), as Chrome's `MultiContentsView` does |
| `be_find_bar.{h,mm}` | `BEFindBar : FindBar`, for a window whose app draws the find bar: Chrome's `FindBarController` drives it, and it tells the app |
| `be_history.{h,mm}` | `BEHistory`: a window's history page data, `HistoryService::QueryHistory()` and `ExpireHistory()` asked as `BrowsingHistoryService` asks them |
| `be_page_dialogs.{h,mm}` | The page's dialogs drawn by the app (`BEPageDialog`): our `TabModalDialogView` (touch point 27), app-modal dialog factory in front of Chrome's (beforeunload), `LoginHandler` (28) and external protocol dialog (29) |
| `be_permission_prompt.{h,mm}` | Permission prompts drawn by the app (`BEPermissionPrompt`): each tab's `PermissionRequestManager` makes its prompts with our factory, which falls back to Chrome's for quiet and page-embedded prompts |
| `be_settings_data.{h,mm}` | `BESettingsData`: Settings' own pages for a window's profile: Delete browsing data (Chrome's counters, with its dialog's words, and `browsing_data_important_sites_util::Remove()` with its dialog's masks), search engines and site search (`TemplateURLService`, as `KeywordEditorController` lists them), sites with their own zoom (`HostZoomMap`) |
| `be_page_info.{h,mm}` | `BEChromiumSiteInfo` (`BESiteInfo`): Chrome's `PageInfo` for the page with our `PageInfoUI`, which keeps what it shows (the security summary, permissions, cookies) in Chrome's words; the app's permission changes go through `PageInfo::OnSitePermissionChanged()` as the bubble's do |
| `be_extensions_manager.{h,mm}` | `BEExtensionsManager`: the app's extensions page for a window's profile (`BEWindowExtensionsManager`): Chrome's `ExtensionInfoGenerator` (what chrome://extensions shows), the developerPrivate and management functions' calls for every action, `DeveloperPrivateEventRouter`'s observers for changes; options pages open as tabs, never chrome://extensions/?options= |
| `be_task_manager.{h,mm}` | `BEChromiumTaskManager` (`BETaskManager`, from `BEEngineTaskManager`): Chrome's `TaskManagerInterface` observed every 2 s for CPU, memory and network, as its own window does; ids checked with `IsTaskValid` before every call |
| `be_devtools_session.{h,mm}` | The DevTools protocol for the app: `BEChromiumDevToolsSession` (`BEDevToolsSession`), an in-process `DevToolsAgentHostClient` (as `--remote-debugging-pipe`'s, without its switch: no infobar, `navigator.webdriver` false) on a tab's tab target (`BETabDevTools`; the page through `Target.setAutoAttach` flatten) or a new browser target (`BEEngineDevTools`), access as `IsTrusted`/`MayAttachToURL`/`MayRead`/`MayWriteLocalFiles`, messages on a later task; `setAgentActive:` as Chrome's actor holds a tab it acts on (`ActorTask::DidContentsEnterActorControl()`: a visible, awake capture, page focus, in-page `<select>` menus) and not discardable |
| `be_agent_tabs.{h,mm}` | Agents' tabs (`BEWindowAgentTabs`, `BETab.storagePartition`), Shuttle's model: a StoragePartition of the window's profile per agent (domain `beagent` + 32 letters of the name's SHA-256, the name as partition name), tabs made with `SiteInstance::CreateForFixedStoragePartition()` at the end of the strip; new tabs opened from them keep to it (touch point 31), they're kept out of history, sessions, recently closed, discarding (32) and the address bar's open tabs (`be_autocomplete.mm`), and keep their session cookies (33). Deleting: caches, then `AsyncObliterateStoragePartition()`, and the HTTP cache's directory in `~/Library/Caches`, which that leaves; a partition still loaded is emptied, and its directories removed at the next launch (a marker in `Storage/be_deleted_agents/`) |
| `be_passwords_data.{h,mm}` | `BEPasswordsData`: the app's passwords page for a window's profile (`BEWindowPasswords`): a `SavedPasswordsPresenter`, `InsecureCredentialsManager` (weak and reused only), CSV export and import (`PasswordManagerExporter`, `PasswordImporter`), and `BEAuthentication` (macOS's check of who's there, one at a time, as Chrome's device authenticator does it) |
| `be_autofill_data.{h,mm}` | `BEAutofillData`: the app's addresses and payment cards sheets (`BEWindowAddresses`, `BEWindowPaymentCards`): the profile's `AddressDataManager` and `PaymentsDataManager`, local data only, each country's address form, Chrome's card checks and "Verify it's you" |
| `be_import.{h,mm}` | `BEImport`: importing into a window's profile (`BEWindowImport`): `ImporterList` and `ExternalProcessImporterHost`, headless, each import owning itself with its profile kept alive; Safari's bookmarks need Full Disk Access, which the sources say |
| `be_profiles.{h,mm}`, `be_engine_profiles.mm` | `BEProfiles`: Chrome's profiles as its profile menu lists them (`BEEngine.profiles`), and for the app's own editor and picker (`BEEngineProfiles`): create, rename, avatar and colour (written into the profile's entry too, which only Chrome's toolbar button did), data counts, delete, pick |
| `be_palette.{h,mm}` | The app's palette for what Chrome still draws: a colour mixer appended last that pins Chrome's `kColorSys*` tokens |
| `be_tab.{h,mm}` | `BEChromiumTab` (`BETab`): state, favicon, bookmark state (Chrome's `BookmarkTabHelper`), zoom (`ZoomController`), sound and mute (`RecentlyAudibleHelper`, `SetTabAudioMuted`), site settings (`be_site_settings.h`), infobars (`be_infobars.h`), coalesced updates, the per-TabHandle registry |
| `../patches/browser_engine/*.patch` | The touch points (below) |
| `../.github/workflows/iterate.yml`, `../.github/scripts/github_iterate.sh` | The incremental build |
| `../.github/workflows/devsession.yml`, `../.github/scripts/github_devsession.sh` | Dev sessions: one runner building every push |
| `../.github/scripts/github_pack_headers.py`, `../tools/check.sh` | Compiling layer files on a Mac against the build's headers |
| `../.github/workflows/retry.yml` | Rerunning release jobs GitHub lost the runner of |

## Touch points (`patches/browser_engine/`)

Brave's rules: one-line hooks in functions we own the outcome of, never in a widely included
header, each patch small and commented. Every patched file includes only
`browser_engine/browser_engine_hooks.h` (forward declarations only), with `// nogncheck`
where the target has no GN dependency on `:hooks`, so editing the layer recompiles no
Chromium file. Generated against the M156 sources with ungoogled-chromium's patches applied
(two of the files, `chrome/BUILD.gn` and `tab_features.cc`, are touched by ungoogled
patches), and checked with `git apply --check` the way the build applies them.

| Patch | File | Why |
|---|---|---|
| 01 | `chrome/BUILD.gn` | `//browser_engine` in the Mac `chrome_dll` deps, the source set `chrome_framework` links |
| 02 | `chrome/app/framework.exports` | `_BEEngineCreate` survives `-exported_symbols_list` |
| 03 | `chrome/browser/ui/views/frame/browser_window_factory.cc` | Our window when embedded, before Webium's arm. The hook returns null for anything but `TYPE_NORMAL`, which keeps Chrome's Views windows for popups, apps, DevTools, PiP |
| 04 | `chrome/browser/ui/browser_window/internal/browser_window_features.cc` | The focus-manager arm next to Webium's: without it no `ExtensionKeybindingRegistryViews` |
| 05 | `chrome/browser/ui/browser_window/internal/embedder_browser_window_features.cc` | Chrome's hook for embedders: the window is complete, has no tabs, isn't shown → `engineDidCreateWindow:` |
| 06 | `chrome/browser/ui/tabs/tab_features.cc` | No `SadTabHelper` (Webium's gate): `SadTabController` dereferences a BrowserView (`sad_tab_controller.cc:32-34`) |
| 07 | `chrome/browser/chrome_browser_main_mac.mm` | CEF's guard: no AppController or main menu in `PreCreateThreads()`; also `DidEndMainMessageLoop()`, since `AppController.sharedController` creates one (and takes `NSApp.delegate`) on first use |
| 08 | `chrome/app/chrome_main_delegate.cc` | `PreBrowserMain()`: no `RegisterBrowserCrApp()` (it CHECKs that NSApp is a `BrowserCrApplication`) |
| 09 | `chrome/browser/browser_process_platform_part_mac.mm` | Found while reading: `AttemptExit(false)` (IDC_EXIT) asks `AppController.sharedController` for the confirm-to-quit panel, which would create AppController and steal NSApp's delegate |
| 10 | `chrome/browser/ui/read_anything/read_anything_side_panel_controller.cc` | Found on the first run: closing the active tab CHECK-failed in Reading Mode's `TabWillDetach()` (no `SidePanelUI`, `CHECK_IS_TEST`). Webium's exit |
| 11 | `chrome/browser/ui/toasts/toast_controller.cc` | `CreateToast()` without an anchor view is `CHECK_IS_TEST` too. Webium's exit: no toasts in our windows yet |
| 12 | `chrome/browser/devtools/devtools_window_views.cc` | Docked DevTools: `UpdateBrowserWindow()` only tells a BrowserView about resizing, dock side and undocking. For our window it calls `UpdateToolbar(inspected)`, which updates that tab, so the app lays out again |
| 13 | `chrome/browser/ui/autofill/address_bubbles_controller.cc` | Chrome's address save and update bubbles look up their window with `FindBrowserWindowWithWebContents()`, which finds BrowserViews only; for our windows, the tab's own `BrowserWindow` (whose handler is Chrome's `AutofillBubbleHandlerImpl`, anchored to the app's star). No Chrome-on-iOS promo after saving, which dereferenced `AsBrowserView()` |
| 14 | `chrome/browser/download/download_prefs.cc` | Inside the app, files go to Downloads without asking, as in Chrome and Safari: ungoogled-chromium's iridium patch asks by default. The setting stays |
| 15 | `components/search_engines/template_url_prepopulate_data.cc` | The default search engine: ungoogled-chromium's "No Search" replaced Google, so typed words searched nothing. Inside the app the fallback default is DuckDuckGo (`GetPrepopulatedFallbackSearch()`) |
| 16 | `chrome/browser/prefs/session_startup_pref.cc` | Inside the app, "Continue where you left off" is the startup default (`GetDefaultStartupType()`), as Mac apps restore their windows |
| 17 | `chrome/browser/renderer_context_menu/render_view_context_menu.cc` | Right-click items for what our windows don't have yet: "Open in Reading Mode" (Chrome's side panel; nothing happened). "Open link in split view" stays since 10 Nov: the app shows splits (`BEWindowSplits`) |
| 18 | `components/password_manager/core/browser/password_manager.cc` | Inside the app, Chrome offers to save passwords, as Chrome and Safari do: ungoogled-chromium's inox defaults turn `credentials_enable_service` off. The setting stays |
| 19 | `chrome/browser/ui/views/session_crashed_bubble_view.cc` | After a crash Chrome waits for its "Restore pages?" bubble to be answered, keeping the old session and saving no new one. The bubble needs a BrowserView, so for our window `ShowBubble()` hands the offer to the window (`Hooks::ShowSessionCrashedBubble`), which offers it to the app (`BEWindow.offersRestoreAfterCrash`) |
| 20 | `chrome/browser/preloading/preloading_prefs.cc` | Inside the app, Chrome's standard preloading is the default, as in Chrome: likely next pages are resolved, connected to and prerendered, and the loading predictor connects early to the hosts a site loads from. ungoogled-chromium's inox defaults turn it off, which made repeat visits to sites like Reddit start slower. The setting stays |
| 21 | `chrome/browser/ui/browser_web_contents_delegate/browser_web_contents_delegate.cc` | `UpdateTargetURL()` and `ContentsMouseEvent()` cast each status bubble to `StatusBubbleViews` and its base view to `ContentsWebView`. For our windows (no BrowserView) the active page's link goes to our one bubble, and leaving the page clears it |
| 22 | `chrome/browser/ui/extensions/extension_install_ui_desktop.cc` | After an install, the "added" dialog's closing callback points the toolbar at the new extension, dereferencing the BrowserView unchecked (`OnInstallSuccess()`); for our windows it stops there |
| 23 | (removed 10 Nov) | Was: the bookmarks bar's right-click menu without "Open in Split View". The app shows splits now (`BEWindowSplits`), so Chrome's item stays |
| 24 | `components/autofill/core/common/autofill_prefs.cc` | Inside the app, Chrome offers to save addresses and payment cards and fills them, as Chrome and Safari do: ungoogled-chromium's inox defaults turn `autofill.profile_enabled` and `autofill.credit_card_enabled` off. The settings stay |
| 25 | `components/performance_manager/user_tuning/prefs.cc` | Inside the app, Memory Saver is on by default: tabs left alone long enough sleep, and reload when chosen. Chrome's own default is off; the setting stays |
| 26 | `components/password_manager/core/browser/password_feature_manager_impl.cc`, `chrome/app/generated_resources.grd` | Chrome suggests strong passwords without sync (ungoogled-chromium has none, so it never did), and its prompt says the password is kept "on this device" |
| 27 | `chrome/browser/ui/views/javascript_tab_modal_dialog_view_views.cc` | `alert()`, `confirm()`, `prompt()`: `JavaScriptTabModalDialogManagerDelegateDesktop::CreateNewDialog()` asks the layer first, which returns its own `TabModalDialogView` for a tab whose app draws page dialogs (`be_page_dialogs.mm`) |
| 28 | `chrome/browser/ui/views/login_handler_views.cc` | HTTP sign-in: `LoginHandler::Create()` asks the layer first, which returns its own `LoginHandler` (the app's dialog, filled from the password manager) |
| 29 | `chrome/browser/ui/views/external_protocol_dialog.cc` | "Open <app>?": `RunExternalProtocolDialog()` asks the layer first, which asks in the app and launches as the dialog's Open does |
| 30 | `chrome/browser/ui/views/profiles/profile_picker_view.cc` | `ProfilePicker::Show()` asks the layer first (`Hooks::ShowProfilePicker`), which asks the app (`engine:showProfilePicker:`): the app's own picker at startup and for Manage and Add; Chrome's for first run, a locked profile and Google's flows |
| 31 | `content/browser/site_instance_impl.cc`, `content/browser/web_contents/web_contents_impl.cc`, `chrome/browser/ui/navigator/browser_navigator.cc` | Agents' tabs keep to their StoragePartition where Shuttle found pages leaving it (its fixes, BSD-licensed): a fixed partition binds its BrowsingInstance from the start and site-less SiteInstances (about:blank) report it; noopener and `target=_blank` windows from a fixed partition keep to it, as guests' do; a link opened in a new tab or window (⌘, middle click, the page's menu) gets a SiteInstance in the opener's agent partition (`Hooks::GetSiteInstanceForNewTab`, from the link's frame, never `source_contents`, which Navigate() fills with the active tab) |
| 32 | `chrome/browser/history/history_tab_helper.cc`, `chrome/browser/sessions/session_tab_helper_factory.cc`, `chrome/browser/sessions/session_service_base.cc`, `components/sessions/content/content_live_tab.cc`, `chrome/browser/resource_coordinator/tab_lifecycle_unit.cc` | Agents' tabs (`Hooks::IsAgentTab`) add no history (as a private window's), aren't saved with the session (no SessionTabHelper delegate, skipped when rebuilt: a saved tab without navigations isn't restored), aren't in recently closed (left out as never loaded, alone or with their window or group) and are never discarded (a discard's new WebContents would be in the profile's own storage) |
| 33 | `chrome/browser/net/profile_network_context_service.cc` | An agent's partition on disk keeps its session cookies across launches (`Hooks::IsAgentStoragePath`), as the main partition does when the session is restored; Chrome drops every other partition's. Agents stay signed in where sites sign in with session cookies (Shuttle's fork commit 46) |

**Webium's other `BrowserWindowFeatures` arms, and why there's no patch for them:**
- `BrowserElementsWebUiBrowser`: with Webium off, features make `BrowserElementsViewsImpl`;
  our window calls its `Init()` with the NativeViewHost, as `BrowserView::AddedToWidget()` does.
- `FindBarOwnerWebUIBrowser`: `FindBarOwner` registers itself on the browser's
  `UnownedUserDataHost`, where `FindBarOwner::From()` looks, so our window owns a
  `BEFindBarOwner` and `CreateFindBar()` makes Chrome's `FindBarHost` on it.
- `WebUIBrowserExclusiveAccessContext`: `ExclusiveAccessManager` asks the window
  (`GetExclusiveAccessContext()`), which returns its own `BEExclusiveAccessContext`.
- `BrowserFocusControllerWebUI`: we get `StubBrowserFocusController`; ⌘L goes through
  `BrowserWindow::SetFocusToLocationBar()` anyway.
- `ZoomBubbleManagerWebUIBrowser` / `WebUIBrowserSidePanelUI`: not created for us. The zoom
  bubble is only asked for by the Views toolbar and Webium (`ZoomViewController` callers), and
  side panels are milestone 2. `bookmark_bar_controller_->SetDelegate` is skipped; the
  controller null-checks its delegate.

## How the build job uses it

`iterate.yml` (workflow_dispatch; input `base_run_id`, a finished `build.yml` run with flavor
**dev** or an iterate run made with `save_base`, defaulting to `.github/dev-base.txt`), on
`macos-26-intel`:
1. Same setup as building.yml's resuming jobs: checkout with submodules, copy the scripts,
   `github_prepare_xcode.sh`, Spotlight off, download `github_build_artifact_x86_64` from the
   base run (`run-id` + `github-token`, `actions: read`), `github_setup_env_toolchain.sh`,
   `github_unpack_archive.sh` (→ `build/src`, same path as the build jobs, so ninja's state
   and absolute paths match).
2. `github_iterate.sh build`: refuses a non-dev base; `rsync -r -c --delete` (openrsync on macOS)
   `browser_engine/` → `build/src/browser_engine/` (unchanged files keep their mtimes); applies
   each patch with `git apply` from `build/src` **with `GIT_CEILING_DIRECTORIES=build`**
   (otherwise git finds our checkout around `build/src` and silently skips every file:
   "Skipped patch"), skipping patches the base already has; `ninja build.ninja` to regenerate
   (a dry run would stop at regeneration); `ninja -n` count, failing above 5,000 edges
   (`BE_MAX_EDGES`) with `-d explain` output; `ninja -C out/Default chrome`.
3. `github_iterate.sh package`: checks `_BEEngineCreate` is exported (`nm -gU`), then
   `upload_engine/` = `Chromium.app.zip` (`ditto -c -k --keepParent`), `BEEngine.h`,
   `engine.json` (`chromium_version`, `ungoogled_revision`, `git_sha`, `api_version`,
   `arch`, `base_run_id`, `run_id`) → artifact `engine_x86_64`.

**The engine for daily use**: `build.yml` with flavor **engine** is the release build
(official, ThinLTO, PGO) with the layer copied in and the touch points applied in
`github_before_build.sh`, as step 2 does on a dev base. After the last build job,
`github_prepare_artifacts.sh` runs `github_iterate.sh package` too, and the job uploads
`engine_x86_64` like an iterate run. It takes the full build's day or two. On the dev Mac, a
release build (ungoogled 155) first painted YouTube and Reddit 10–30% sooner than the dev base
(156), and Google about the same.

**Where an iterate run's time goes** (2 Nov, run 41502624089): 16–23 minutes getting the 8 GB
base onto the fresh runner (download and unpack; streaming one into the other was no faster),
2 minutes regenerating the build files, then rebuilding everything that changed since the base
(45 files, 8 minutes) and relinking (1 minute). Until 2 Nov each run also redid all of DevTools'
TypeScript bundling (about 970 of 1,042 build steps): Homebrew's freshly installed esbuild and
tsc were newer than its outputs. `github_setup_env_toolchain.sh` now dates them back.

**Keeping the base close:** `iterate.yml` with `save_base` also packs and uploads the run's build
state (`github_iterate.sh pack`, about 15 minutes more) as `github_build_artifact_x86_64`, like a
build job. Put that run's id in `.github/dev-base.txt`: later runs and sessions then rebuild only
what changed after it, and skip regenerating the build files unless a `BUILD.gn` changed.

**Dev sessions** (`devsession.yml`, `github_devsession.sh`): one runner downloads and unpacks the
base once, then builds every push to the branch it was started on, keeping the build state, for
up to about 5½ hours or until `idle_minutes` pass without a push. Touch points that changed are
reversed (from copies of the last applied ones) before `github_iterate.sh build` applies them
again, so files no change touches keep their mtimes. Each engine goes to the prerelease
`dev-session` as `engine-<sha>.zip` (the iterate artifact's three files), or `engine-<sha>.log`
when its build failed; the ten newest stay. The app's `scripts/fetch-engine.sh session <commit>`
waits for one and fetches it.

**The optimised engine in about an hour** (9 Nov): `iterate.yml` with `optimised` starts from a
saved optimised build (`build.yml` flavor engine; the run in `.github/optimised-base.txt`, or
`base_run_id`) instead of a dev base. Its build state keeps the ThinLTO cache
(`out/Default/thinlto-cache`, Chromium's default), so after the changed files compile, the
framework relinks reusing every module that didn't change. Measured on run 42679690338 (base
41730416187 from 3 Nov, master of 9 Nov: the layer, patches 25–29, 3,374 ninja steps): 18 min
download, 13 min unpack, 27 min compile and relink, 62 min end to end, against a day or two from
scratch and 3 h 15 min for a cold ThinLTO link alone. Changes pile up on an old base (each run
redoes everything since it), so now and then make a fresh one: `save_base` (about 30 minutes
more: the state is 37 GB unpacked, 12 GB packed) or a full `build.yml` engine run, and put its
run id in `.github/optimised-base.txt`.

**Checking on the Mac** (`tools/check.sh`): compiles the layer's sources and the touch points'
files with the engine build's clang, compile commands and headers, which an iterate run made
with `pack_headers` uploads (`github_pack_headers.py`: every header in the tree, the generated
ones, libc++, clang and its plugins, and the touch points' files before our patches). Compile
errors in about a minute; it doesn't link. A touch point newer than the pack patches files it
lacks: those come from Chromium's own sources at the pack's version (once; marked in
`src/fetched/`) and compile with the command of the nearest file the pack has, and a patch that
doesn't apply to them (ungoogled's patches or domain substitution changed the file) is skipped.
It doesn't run GN: a dependency a target's visibility list refuses (`//browser_engine` may not
depend on `//third_party/blink/public/common:headers`, found on 9 Nov) shows only in the session's
`gn gen`, as `Dependency not allowed`.

**Lost runners:** `retry.yml` reruns a failed `build.yml` job when its annotations say GitHub
lost the runner ("lost communication with the server"), up to twice; the job resumes from the
last finished job's saved state.

## What the app must do (runtime contract)

- **Bundle the framework where Chrome looks for it.** Chrome derives the framework, helper
  and resource paths from the *executable*: `chrome::GetFrameworkBundlePath()` is
  `<app>/Contents/Frameworks/Chromium Framework.framework/Versions/156.0.8078.47`
  (`chrome_paths_mac.mm`), and `SetUpBundleOverrides()` makes the app's bundle the outer
  bundle. So the app embeds `Chromium Framework.framework` from `Chromium.app.zip` in its own
  `Contents/Frameworks` (ForkEngine.load already looks there), signed together with the app.
  The app's `CFBundleIdentifier` becomes Chrome's base bundle id; `CrProductDirName` in its
  Info.plist names the profile folder (`~/Library/Application Support/<name>`, default
  `Chromium`), or pass `--user-data-dir=`.
- **NSApp.** An NSApplication subclass adopting `CrAppProtocol`/`CrAppControlProtocol`
  (the app's `BrowserApplication` does). Chromium sends NSApp two more things that Chrome's
  `BrowserCrApplication` answers, and the engine answers them for the app, adding the methods at
  runtime (`AddMissingAppMethods()` in `be_engine.mm`), because only Chromium's side can act on
  them:
  - `-addNativeEventProcessorObserver:` / `-removeNativeEventProcessorObserver:`
    (content's responsiveness watcher, `native_event_observer_mac.mm`; the observers are
    ignored, which only costs Chrome's jank metrics), and
  - `-cancelTerminate:` (sent by `chrome_browser_application_mac::CancelTerminate()` when the
    user stays on a page during quit): it clears Chrome's trying-to-quit state, so the next ⌘Q
    works. The app must not implement it.
  `BrowserCrApplication -sendEvent:` also forwards ⌘-keyUp and JIS Eisu/Kana keyDown events to
  the key window (AppKit swallows them; pages miss those keys otherwise); the app's
  `BrowserApplication` does the same.
- **⌘Q and `terminate:`.** Route `-terminate:` to `-[BEEngine quit]` and never call
  `[super terminate:]` while the engine runs (AppKit would `exit()` without Chrome's shutdown;
  CEF clients do the same with `CefQuitMessageLoop`). Chrome itself reaches quit through
  `[NSApp terminate:nil]` (`chrome::AttemptExit()` → `chrome_browser_application_mac::Terminate()`:
  chrome://quit, restarts after updates or flags, IDC_EXIT), so it must land in `quit` too.
  `NSApplicationWillTerminateNotification` (and so `-applicationWillTerminate:`) is Chromium's
  "shutting down now", posted after every window has closed; `runWithArguments:` returns
  after it.
- **Launch Services and the Dock.** Forward `application:openURLs:` to `openURLs:` (queued
  until startup is done). On `applicationShouldHandleReopen:hasVisibleWindows:` with no
  windows, call `openWindowPrivate:NO` (AppController did).
- **In `engineDidCreateWindow:`** set the delegate, call `setContentView:` once and style the
  window; don't run commands synchronously (the Browser is still being constructed).
  After `windowWillClose:`, `nativeWindow` is nil and every call is a no-op.
- **Don't change the tab strip from inside a tab event.** `didInsertTab:`, `didRemoveTab:`,
  `didMoveTab:` and `didActivateTab:` arrive synchronously from
  `TabStripModelObserver::OnTabStripModelChanged()`. Activating, moving or closing a tab
  there, or running a command that does, trips `TabStripModel`'s re-entrancy `CHECK`
  (`tab_strip_model.cc`). Post it to the next turn of the run loop instead.
- **Site settings.** Read `siteSettings` of the selected tab when it's activated and on
  each `tabDidUpdate:` (it's computed on every read, as Chrome's location bar refreshes its
  icons), and hide the icons while the user edits the address, as Chrome does
  (`LocationBarView::ShouldHideContentSettingImage()`). Call `showSiteSetting:fromRect:` on
  mouse up, as for extension buttons: the press that closed an icon's bubble doesn't
  reopen it. The bubble closes by itself when another tab is activated, the page
  navigates, or the window closes; nothing tells the app when it closes.
- **Infobars.** Read `infobars` of the selected tab when it's activated and on each
  `tabDidUpdate:`, which follows a task after one comes, goes or is replaced (by a new
  object). Each of Chrome's infobars is one object for its whole life: until it's answered
  or closed, a navigation expires it (most go when the page changes; tab sharing and most
  startup warnings stay), the page crashes, or the tab is discarded or closed. Then its
  methods do nothing, and it keeps its last text. Its text and buttons don't change while it
  lives: Chrome reads them once, as its own infobar does. They're all the page's, oldest
  first. Chrome shows only the active tab's, and holds closable ones back by priority (at
  most one of default priority at a time, the next once it closes:
  `InfoBarContainerWithPriority`); v11 doesn't carry priority. `pressButtonAtIndex:` is
  Chrome's button: OK, then Cancel (`buttons[0]` is always the default, Chrome's prominent
  one), or for tab sharing Stop, "Share this tab instead" and the indicator that the site may
  scroll and zoom the shared tab, which opens Page Info. A greyed-out button (v11 can't say
  which) and a bad index do nothing. An answer usually removes the infobar; tab sharing's
  remove or replace every tab's. `openLink` is a plain click: a "Learn more" link opens in a
  new foreground tab; the alternate-address one ("Did you mean to go to http://intranet/?",
  a link inside Chrome's message, so its text is in `message` too) loads in this tab.
  `close` does nothing unless `isClosable`. Answer from the app's own events, not from
  inside a tab-strip event (`didInsertTab:`...): Page Info's button reloads the page, Stop
  ends a capture. `chrome://infobar-internals` (an internal debugging page:
  `chrome://chrome-urls` turns those on) makes each kind on the current tab.
- **Bookmarks and History menus.** Read `bookmarks`, `recentlyVisited` and `recentlyClosed`
  when the menu opens; before Chromium has started they're empty. `bookmarks` is what Chrome's
  Bookmarks menu lists below its own items: the managed bookmarks' folder (when a policy sets
  any), the bookmarks bar's bookmarks and folders, then Other Bookmarks and Mobile Bookmarks as
  folders. Each of those three folders is left out while it's empty, and everything is until
  the bookmarks have loaded. Chrome draws a separator before the managed folder or the bar's
  bookmarks, and one before Other or Mobile Bookmarks; v10 doesn't say where those groups
  meet. An empty folder has no `children` (Chrome shows "(empty)" in it). A bookmark's
  `favicon` is nil until Chrome has loaded it: the first read starts the load, as Chrome's
  menu does when it adds the item, and a later read has it (Chrome shows its default page icon
  meanwhile). `recentlyVisited` is the 15 pages visited last within 90 days, newest first,
  each once, without pages that weren't found. It's asked for 750 ms after history loads and
  after each change, so a visit shows up about a second later. Its icons arrive later, into
  the same objects. Titles are whole: Chrome's menus cut them in the middle to 400 points in
  the menu font (`gfx::ElideMenuItemTitle()`). Chrome opens both menus' items as
  `PAGE_TRANSITION_AUTO_BOOKMARK`, in the active tab, a background tab with ⌘ or a window
  with ⇧. v10 has no call for that: `loadURL:` records a typed visit (which the address bar
  ranks higher), `openURL:inBackground:` a link.
- **The bookmarks bar (v12).** Show it while `showsBookmarkBar` is set; Chrome decides
  (`BookmarkBarController`): always with the visibility preference at Always Show (⇧⌘B,
  `BECommandToggleBookmarkBar`), otherwise only on a new tab page once there are bookmarks
  (Chrome may turn that off itself after a couple of weeks of the bar on new tab pages), never
  for guests or while a page is full screen. `windowDidChangeBookmarkBar:` says when it
  changes, tab switches included. Draw `bookmarkBar`'s children in order, a chevron menu for
  those that don't fit, and `otherBookmarks` (titled "All Bookmarks") at the end when it's
  there; read them again on `engineDidChangeBookmarks:`, which also comes when an icon has
  loaded. There's no hint text in an empty bar at M156. A click is `openBookmark:event:` with
  the click's event, so Chrome picks the tab or window as its bar does; for a folder, show its
  bookmarks as a menu, and send `openBookmark:event:` for a ⌘- or middle click, which opens
  them all. Right-click is `showMenuForBookmark:atPoint:inView:` (0 for the bar itself):
  Chrome's own menu, whose Edit…, Add Page… and Add Folder… open Chrome's bookmark editor on the
  window. Drops are `moveBookmark:toFolder:atIndex:` (a bookmark dragged on the bar; the index
  counts before the move) and `addBookmarkForURL:title:toFolder:atIndex:` (a link from a page
  or another app). ⌘D and the star save into the folder used last, Other Bookmarks on a new
  profile, as in Chrome, so they show under All Bookmarks; Chrome's bookmark bubble (v13) is
  where the user picks the bar instead.
- **The star (v13).** Run `BECommandBookmarkPage` for the app's star, as for ⌘D: Chrome
  bookmarks the page if it isn't and shows its bookmark bubble (name, folder, Remove, More…),
  pointing at `bookmarkButtonRectForWindow:`, which the delegate answers with the star's rect
  in window coordinates, or an empty rect for the window's top right. `setBookmarked:` stays for
  a star that only toggles.
- **Answer the restore offer.** After a crash, `offersRestoreAfterCrash` is set on the startup
  window; until the app calls `restoreAfterCrash` or `declineRestoreAfterCrash`, Chrome saves no
  new session.
- **DevTools sessions and agents' tabs (13 Nov).** A tab's session is on its tab target, which
  has only Target, IO and Tracing: send `Target.setAutoAttach {autoAttach: true,
  waitForDebuggerOnStart: false, flatten: true}` first, then the page's commands with the
  `sessionId` of `Target.attachedToTarget`, which comes again for each page swapped in. For
  agents, access 0: untrusted (no `Target.createTarget`/`getTargets`, typed keys don't reach
  Chrome's or the app's shortcuts), and going to a chrome:// page ends the session. The close
  handler also comes when Chrome refuses the session (DevTools policy) and when the tab closes;
  open a new one then. A browser session needs `Trusted`; its `Target.createTarget` opens tabs in
  the profile's own storage, so a relay for agents rewrites or refuses it. `setAgentActive:YES`
  only while acting (it keeps the Mac awake, as Chrome's actor does), `NO` after. Agents' tabs:
  open them from the app's own events, never inside a tab-strip event; the app groups them. Nil
  for Chrome's own pages (chrome://, extensions), which keep to the profile's storage. A tab an
  agent's page opens is the agent's too (`storagePartition`), and none is restored after a
  relaunch: the app reopens what it needs. Close an agent's tabs before
  `deleteStoragePartition:`. Shared with the profile still: permissions and site settings, the
  downloads list, extensions, password and autofill offers, saved favicons.
- **Arguments.** Suggested: `--no-first-run --no-default-browser-check
  --disable-features=Glic` (below).

## Features to disable at startup (assume a BrowserView)

| Switch | Evidence (156.0.8078.47) |
|---|---|
| `--disable-features=LensOverlay` | Lens items appear when the search engine is Google; opening the overlay `CHECK`s for a contents web view our window doesn't have (`overlay_base_controller.cc:662-666`). |
| `--disable-features=MediaRouter` | Cast shows an unattached bubble (no BrowserView to anchor to), and ungoogled-chromium builds without mDNS, so it finds almost nothing. |
| `--enable-features=DisableQRGenerator` | ungoogled's switch; "Create QR code" dereferences Chrome's toolbar (`qrcode_window_controller.cc:45-46`). |
| `--disable-features=Glic` | `chrome/browser/glic/widget/browser_conditions.cc:191`: `BrowserAttachObservation::OnBrowserCreated()` does `CHECK_DEREF(BrowserView::GetBrowserViewForBrowser(browser))` for every TYPE_NORMAL browser of a Glic-enabled profile. `kGlic` is enabled by default on Mac (`chrome/common/chrome_features.cc:530`); ungoogled's `disable-ai.patch` removes much of Glic, but not provably this path. |

Found while reading, not switchable (guard patches when they bite):
- Closing a **pinned** tab with ⌘W: `chrome/browser/ui/browser_commands.cc:1515-1516`
  (`CloseTab()` → pinned-tab toast) `CHECK(browser_view)`. The app shouldn't pin tabs yet.
- Extension dialogs anchored to the toolbar: `chrome/browser/ui/extensions/extension_dialog_utils_views.cc:90`
  (`ShowDialog(BrowserWindowInterface*, …)`) dereferences
  `BrowserView::GetBrowserViewForBrowser(browser)` unchecked. The native-window variants find
  our `ExtensionsContainer` or fall back to a window-modal dialog. The post-install crash
  (`extension_install_ui_desktop.cc:161-163`) is touch point 22.
- Toolbar actions invoked programmatically: `chrome/browser/ui/browser_actions.cc:812,1485,2014`
  `CHECK_DEREF(BrowserView::...)`. Unreachable without Chrome's toolbar, unless an extension
  or command triggers those actions.
- Null-checked (no action needed): `ios_promo_controller.cc:93`,
  `vertical_tab_iph_controller.cc:74`, `auto_picture_in_picture_window_occlusion_helper_widget.cc`,
  `dictation/application_registration_delegate.cc`.
- Choosers (Bluetooth, USB, serial, HID): `chooser_bubble_ui.cc:303-311` dereferences the
  BrowserView unchecked.
- Pointer and keyboard lock prompts: `exclusive_access_permission_prompt.cc:25` calls
  `GetChipController()->ShowPermissionChip()` unchecked. That path only runs with
  `kKeyboardLockPrompt`, which is off by default at 156.
- Chrome's own Views windows (popups, app windows) validate menu items through
  `AppController.sharedController` (`browser_native_widget_mac.mm:478`). If the app's menu
  reaches them, that makes an AppController, which takes over `NSApp.delegate`. That would need
  a guard like patch 09.
- `chrome_exe_main_mac.cc` registers PartitionAlloc's malloc zone before any thread starts.
  The app doesn't, so the zone is swapped when the framework loads, which is only safe while
  the process has one thread. The app loads it first thing in `main()`.
- Autofill and payments bubbles: `BEAutofillBubbleHandler` answers every `Show*` with a bubble
  that does nothing, since callers `CHECK` what they get. So no autofill, card or Autofill AI
  bubble shows yet. Addresses are declined (patch 13). Password bubbles return early without
  Chrome's toolbar (`password_bubble_view_base.cc:64-68`); the app shows Chrome's offer itself
  (`be_passwords.mm`, `BETab.passwordOffer`).
- "Create QR code" (`qrcode_window_controller.cc:45-46`) dereferences Chrome's toolbar. The app
  launches with ungoogled's `--enable-features=DisableQRGenerator`, which hides it.
- "Send to your devices" (`send_tab_to_self_bubble_controller.cc:107-108`) does the same, but
  only shows with sync or sign-in, which ungoogled-chromium doesn't offer.
- Site-setting bubbles (`be_site_settings.mm`): their links go through the browser's
  `BrowserContentSettingBubbleModelDelegate` (settings pages and help pages as tabs in our
  window, the cookies dialog as a tab-modal dialog), with no BrowserView. Infobars they add
  (a cookie setting changed: "reload to apply") reach the app as the tab's `infobars`
  (`be_infobars.mm`). Chrome's bubble that opens by itself
  (`ShouldAutoOpenBubble()`: camera, microphone or location allowed for the site but off
  in macOS) doesn't, since only the app knows where the icon is; the icon shows struck
  through, and a click opens it. At 156 Chrome's bar shows camera and microphone as an
  activity indicator on its left (`kLeftHandSideActivityIndicators`), whose click opens
  Page Info on ordinary pages; ours are among the icons, and open the media bubble.
- Downloads: Chrome's download UI isn't made for our windows (`DownloadToolbarUIController` is
  BrowserView's), and nothing assumes it. The app shows them from `engineDidUpdateDownload:`.
  Files fetched insecurely are held until the app keeps them; with Safe Browsing off nothing is
  "dangerous". ungoogled-chromium doesn't quarantine downloads; the app does when one completes.

## BEBrowserWindow: real vs stubbed

Real: widget/NSWindow creation and placement saving, show/hide/activate/close (with
beforeunload through `UnloadController`), bounds, maximize/minimize/restore, fullscreen
(`ProcessFullscreen` → `FullscreenController::WindowFullscreenStateChanged`, also for the
window's own fullscreen button, onto the screen a page asks for), page fullscreen reported to the
app (`FullscreenController::RegisterOnFullscreenStateChanged` → `windowDidChangePageFullscreen:`,
so its bar steps aside), z-order, flash, workspaces, active-state
(`BrowserActiveStateManager::DidBecomeActive/Inactive` from paint-as-active and `Show()`),
theme/color/native theme, contents size get/set, location-bar focus requests,
toolbar/title/reload/security updates → `tabDidUpdate:`, keyboard pre-handling and Mac
redispatch + FocusManager accelerators, accelerator provider, find bar (Chrome's Views
`FindBarHost`), tab-modal dialog host, exclusive-access context and bubble,
`ConfirmBrowserCloseWithPendingDownloads` (Chrome's `DownloadInProgressDialogView`, which runs
the callback), emoji panel, HaTS (runs the failure callback), `GetCanResize`,
`GetWindowShowState`, `GetRestoredState`.

Stubs (one line each, commented): top-controls sliding,
loading animations, `OnTabDetached`, pinned toolbar actions
(null), custom tab bar, toolbar focus/size, tab dragging, link-opening animation, app menu,
tab-strip editing for tests, update dialog, intent picker, bookmark bubble, translate bubble
(`kBrowserWindowNotValid`, as Webium), download bubble (null), drag pre-handling, avatar
bubble, IPH, eye dropper (null), caret browsing dialog, tab search, incognito dialogs,
unframed mode, Chrome Labs, `AsBrowserView()` (null).

`BELocationBar` is Webium's stub without the permission dashboard, except that
`UpdateContentSettingsIcons()` sends the active tab's `tabDidUpdate:` (the app re-reads
`siteSettings`). `IsDrawn()` is false, so
permission requests take the bubble path (`permission_prompt_factory.cc`). That path checks
`GetChipController()` (null) for null and anchors to `GetChipAnchor()`, which floats the bubble
over the window: an empty anchor dereferences the BrowserView (`bubble_anchor_util_views.cc`).

## UNVERIFIED

Marked in code with `// UNVERIFIED:`, plus what reading couldn't settle:
1. `be_browser_window.mm` `OnWindowCloseRequested()`: re-arming `MakeCloseSynchronous` on every
   close (Webium re-arms only when refused) so the second `Close()` reaches
   `UnloadController::OnWindowCloseComplete()`.
2. `be_engine.mm` `DidEndMainMessageLoop()`: the last used profile stands in for
   AppController's last active profile.
3. Hit-testing and window dragging with the app's NSView covering `BridgedContentView` under
   a transparent title bar (`kBrowser` window class): the app's bar must say where the window
   can be dragged (`mouseDownCanMoveWindow` / `_opaqueRectForWindowMoveWhenInTitlebar`).
4. VoiceOver: the engine does BrowserCrApplication's accessibility activation for the app's NSApp
   (`AddMissingAppMethods()` → `BEAppAccessibility`): VoiceOver through content's
   `voiceOverEnabled` KVO, `AXEnhancedUserInterface` from other assistive technology (2 s
   debounce), and `accessibilityRole` (Voice Control). It applies only while the app's class
   doesn't override those methods itself, and hasn't been tried with VoiceOver running. Not ported:
   `accessibilityFocusedUIElement` (focus across processes, for PWA app shims).
5. The pending `openURLs:` flush runs from a task posted in `PreCreateThreads()`, assumed to
   run after startup's windows exist (the main loop starts after `PreMainMessageLoopRun`).
6. `be_site_settings.mm`: a press on the app's icon closes its open bubble before the app
   hears of the click (close-on-deactivate), as `BEExtensions` assumes for popups; if not,
   `Show()` finds the bubble open and closes it, which looks the same.
7. `be_infobars.mm`: the tab-sharing message comes from the infobar's view, which is never
   shown (`TabSharingInfoBar::GetStatusMessageViewForTesting()`: a label, or the status
   view's accessible name, set without a widget). Read, not run, like the whole tab-sharing
   path in our windows (`TabSharingUIViews` adding infobars to every tab of every browser).
8. DevTools sessions and agents' tabs (13 Nov), compiled, never run: that an agent's tab
   stays in its partition through about:blank, `window.open` with and without an opener,
   `target=_blank`, ⌘/middle clicks and "Open link in new tab" (touch points 31; content's
   `CHECK`s on a BrowsingInstance's partition, which the binding must satisfy); that history,
   sessions, recently closed and discarding leave it out (32) and its session cookies survive a
   relaunch (33); hidden agent-active tabs' rAF, timers, focus and in-page `<select>`; screenshots
   of a background tab never shown (its view may be 0×0 until the app sizes it).

## Open questions

- Which window types become ours next: popups (`window.open` with features) and app windows
  are Chrome's Views windows for now (the factory hook decides; no patch change needed).
- The title-bar height the traffic lights center in (`kTitlebarHeight`, Webium's 40) should
  come from the app's bar.
- Downloads at quit: Mac Chrome asks in AppController (`shouldQuitWithInProgressDownloads`);
  `quit` cancels them silently today. Confirm-to-quit (⌘Q hold) is gone with AppController.
- Incognito windows get the widget's color provider, not Chrome's dark incognito theme.
- `google-chrome://`/`chromium://` launch URLs aren't stripped as AppController does.
- Code signing: the app re-signs the framework and helpers with its identity; library
  validation and the helpers' entitlements need checking on the first run.

## Risks for the first compile

1. Signatures copied from Webium are trusted where Webium compiles at M156
   (`NativeWidgetMac` overrides, `FindBarOwner`, `ExclusiveAccessContext`); the rest were read
   from M156 headers. A second reading, file by file, checked every override and API against
   the 156 sources. It also ran the Objective-C++ files through Apple clang with ARC, against
   stand-in headers that copy the 156 signatures. Both found no errors. Only Chromium's own
   clang, on the real headers, settles it.
2. GN: every dep label was checked to exist at the tag; visibility lists were checked for
   the ones that have them. Undeclared includes (`// nogncheck`) only matter to `gn check`,
   which the build doesn't run.
3. Warnings aren't errors in this build (`treat_warnings_as_errors=false`,
   `clang_use_chrome_plugins=false`), so nullability and style issues won't stop it.
4. The 5,000-edge guard assumes the dev base finished; an unfinished base chain fails fast.
