// The one way Chromium's own code calls into //browser_engine.
//
// The touch-point patches in patches/browser_engine/ include only this header.
// It declares nothing but forward-declared types, so it never pulls the layer's
// headers into Chromium files, and changing the layer recompiles none of them.

#ifndef BROWSER_ENGINE_BROWSER_ENGINE_HOOKS_H_
#define BROWSER_ENGINE_BROWSER_ENGINE_HOOKS_H_

class BrowserWindow;
class BrowserWindowInterface;

namespace views {
class Widget;
}  // namespace views

namespace browser_engine {

// Implemented by the layer (be_engine.mm). Every call is on the UI thread.
class Hooks {
 public:
  virtual ~Hooks() = default;

  // browser_window_factory.cc: our window for `browser`, or null to let Chrome
  // make its own (Views) window. The caller takes ownership.
  virtual BrowserWindow* CreateBrowserWindow(
      BrowserWindowInterface* browser) = 0;

  // embedder_browser_window_features.cc: `browser` and its window are fully
  // constructed and have no tabs yet. Called for every browser type.
  virtual void BrowserWindowInitialized(BrowserWindowInterface* browser) = 0;

  // browser_window_features.cc: the views::Widget of our window for
  // `browser`, or null if `browser` doesn't have one of our windows.
  virtual views::Widget* GetWidgetForBrowser(
      BrowserWindowInterface* browser) = 0;

  // chrome_browser_main_mac.mm: what AppController does at these two points,
  // since the app (not AppController) is NSApp's delegate when embedded.
  virtual void PreCreateThreads() = 0;
  virtual void DidEndMainMessageLoop() = 0;
};

// Set once by BEEngine before it calls ChromeMain; never unset. Null when the
// framework runs as the plain Chromium.app, and in every child process.
void SetHooks(Hooks* hooks);
Hooks* GetHooks();

// True when Chromium runs inside our app.
inline bool IsEmbedded() {
  return GetHooks() != nullptr;
}

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BROWSER_ENGINE_HOOKS_H_
