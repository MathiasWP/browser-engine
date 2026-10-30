# browser_engine: Chromium as our app's engine

The embedding layer that turns this ungoogled-chromium build into the engine the
browser app (Swift, AppKit) runs **in its own process**, as Dia runs ArcCore. Chrome's
browser layer stays in charge: `Browser`, `TabStripModel`, profiles, session restore,
commands, extensions, downloads. What goes is Chrome's Views browser UI (`BrowserView`):
in its place is `BEBrowserWindow`, Chrome's third production `BrowserWindow` after
`BrowserView` and Webium's `WebUIBrowserWindow`, whose shape it follows at M156.

The app and the engine meet only in `public/BEEngine.h` (a verbatim copy of the app's
`Sources/BrowserEngineAPI/include/BEEngine.h`; `BE_API_VERSION` 1). The framework exports
one function, `BEEngineCreate`.

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
  window's `UpdateToolbar*`/`UpdateTitleBar` calls; `tabDidUpdate:` is coalesced to one per
  task.
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
| `browser_engine_hooks.{h,cc}` | `browser_engine::Hooks`, `IsEmbedded()`: the only thing the touch points call |
| `be_engine.{h,mm}` | `BEEngineCreate`, `BEChromiumEngine` (`BEEngine`), the hooks implementation, NSApp stand-ins |
| `be_browser_window.{h,mm}` | `BEBrowserWindow : BrowserWindow`, its widget delegate and `BENativeWidgetMac` |
| `be_browser_window_parts.{h,mm}` | Never-null parts Chrome asks for: `BELocationBar`, `BEExclusiveAccessContext`, `BEModalDialogHost`, `BEFindBarOwner` (Webium's, re-pointed) |
| `be_window.{h,mm}` | `BEChromiumWindow` (`BEWindow`): commands, tab strip events |
| `be_tab.{h,mm}` | `BEChromiumTab` (`BETab`): state, favicon, coalesced updates, the per-TabHandle registry |
| `../patches/browser_engine/*.patch` | The touch points (below) |
| `../.github/workflows/iterate.yml`, `../.github/scripts/github_iterate.sh` | The incremental build |

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

`iterate.yml` (workflow_dispatch, input `base_run_id` = a finished `build.yml` run with
flavor **dev**), on `macos-26-intel`:
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

Each run recompiles the 7 patched Chromium files (the patches are re-applied to a fresh
base), our 6 sources, and relinks the framework. To save those recompiles, a later dev base
can carry the touch points: add them to `patches/series` and copy `browser_engine/` into the
tree in `github_fetch_resources.sh`; the iterate script already skips applied patches.

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
- **Arguments.** Suggested: `--no-first-run --no-default-browser-check
  --disable-features=Glic` (below).

## Features to disable at startup (assume a BrowserView)

| Switch | Evidence (156.0.8078.47) |
|---|---|
| `--disable-features=Glic` | `chrome/browser/glic/widget/browser_conditions.cc:191`: `BrowserAttachObservation::OnBrowserCreated()` does `CHECK_DEREF(BrowserView::GetBrowserViewForBrowser(browser))` for every TYPE_NORMAL browser of a Glic-enabled profile. `kGlic` is enabled by default on Mac (`chrome/common/chrome_features.cc:530`); ungoogled's `disable-ai.patch` removes much of Glic, but not provably this path. |

Found while reading, not switchable (guard patches when they bite):
- Closing a **pinned** tab with ⌘W: `chrome/browser/ui/browser_commands.cc:1515-1516`
  (`CloseTab()` → pinned-tab toast) `CHECK(browser_view)`. The app shouldn't pin tabs yet.
- Extension dialogs anchored to the toolbar: `chrome/browser/ui/extensions/extension_dialog_utils_views.cc:90`
  dereferences `BrowserView::GetBrowserViewForBrowser(browser)` unchecked; every window
  gets an `ExtensionInstalledWatcher` (`browser_window_features.cc:416`). Likely the
  "post-install extension dialog" crash from docs/embedding.md.
- Toolbar actions invoked programmatically: `chrome/browser/ui/browser_actions.cc:812,1485,2014`
  `CHECK_DEREF(BrowserView::...)`. Unreachable without Chrome's toolbar, unless an extension
  or command triggers those actions.
- Null-checked (no action needed): `ios_promo_controller.cc:93`,
  `vertical_tab_iph_controller.cc:74`, `auto_picture_in_picture_window_occlusion_helper_widget.cc`,
  `dictation/application_registration_delegate.cc`, `toast_controller.cc` (no anchor → no toast).
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
- Autofill and password bubbles call `GetAutofillBubbleHandler()`, which is null for us (as
  for Webium); expect a crash when Chrome offers to save a password or address until
  milestone 2. Turning off "Offer to save passwords" and address autofill in prefs avoids it.

## BEBrowserWindow: real vs stubbed

Real: widget/NSWindow creation and placement saving, show/hide/activate/close (with
beforeunload through `UnloadController`), bounds, maximize/minimize/restore, fullscreen
(`ProcessFullscreen` → `FullscreenController::WindowFullscreenStateChanged`, also for the
window's own fullscreen button), z-order, flash, workspaces, active-state
(`BrowserActiveStateManager::DidBecomeActive/Inactive` from paint-as-active and `Show()`),
theme/color/native theme, contents size get/set, location-bar focus requests,
toolbar/title/reload/security updates → `tabDidUpdate:`, keyboard pre-handling and Mac
redispatch + FocusManager accelerators, accelerator provider, find bar (Chrome's Views
`FindBarHost`), tab-modal dialog host, exclusive-access context and bubble,
`ConfirmBrowserCloseWithPendingDownloads` (Chrome's `DownloadInProgressDialogView`, which runs
the callback), emoji panel, HaTS (runs the failure callback), `GetCanResize`,
`GetWindowShowState`, `GetRestoredState`.

Stubs (one line each, commented): top-controls sliding, status bubbles (none),
loading animations, `OnTabDetached`, autofill bubble handler (null), pinned toolbar actions
(null), custom tab bar, toolbar focus/size, tab dragging, link-opening animation, app menu,
tab-strip editing for tests, update dialog, intent picker, bookmark bubble, translate bubble
(`kBrowserWindowNotValid`, as Webium), download bubble (null), drag pre-handling, avatar
bubble, IPH, eye dropper (null), caret browsing dialog, tab search, incognito dialogs,
unframed mode, Chrome Labs, `AsBrowserView()` (null).

`BELocationBar` is Webium's stub without the permission dashboard: `IsDrawn()` is false, so
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
4. VoiceOver: `BrowserCrApplication` turns on Chrome's accessibility when VoiceOver or other
   assistive technology asks (`accessibilitySetValue:forAttribute:`, VoiceOver KVO,
   `kSonomaAccessibilityActivationRefinements`); the app's NSApplication doesn't. Pages may
   stay inaccessible until the app does the same.
5. The pending `openURLs:` flush runs from a task posted in `PreCreateThreads()`, assumed to
   run after startup's windows exist (the main loop starts after `PreMainMessageLoopRun`).

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
