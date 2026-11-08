// The app's colours for what Chrome still draws itself (its bubbles, dialogs,
// menus' Views and chrome:// pages): one colour mixer, appended after all of
// Chrome's, pins the Material "system" tokens (kColorSys*) every leaf colour
// derives from. WebUI reads them through chrome://theme/colors.css, which is
// made from the same providers. Light and dark come from the ColorProviderKey,
// which follows NSApp's appearance.

#ifndef BROWSER_ENGINE_BE_PALETTE_H_
#define BROWSER_ENGINE_BE_PALETTE_H_

#import <AppKit/AppKit.h>

namespace browser_engine {

// Keeps `palette` (-[BEEnginePalette setPalette:]'s keys); once the mixer is
// installed, every window and page takes it at once. UI thread, any time.
void SetPalette(NSDictionary<NSString*, NSColor*>* palette);

// Appends the mixer, once, after Chrome's own (ChromeBrowserMainParts::
// ToolkitInitialized() appends those; PreCreateThreads comes after).
void InstallPaletteMixer();

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_PALETTE_H_
