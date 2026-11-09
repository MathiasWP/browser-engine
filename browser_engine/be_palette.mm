#import "browser_engine/be_palette.h"

#include <algorithm>
#include <cmath>

#include "base/functional/bind.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/color/color_id.h"
#include "ui/color/color_mixer.h"
#include "ui/color/color_provider.h"
#include "ui/color/color_provider_key.h"
#include "ui/color/color_provider_manager.h"
#include "ui/color/color_recipe.h"
#include "ui/color/color_transform.h"
#include "ui/native_theme/native_theme.h"

namespace browser_engine {

namespace {

// The palette's colours, resolved for one appearance.
struct Colors {
  SkColor accent;
  SkColor on_accent;
  SkColor accent_container;
  SkColor on_accent_container;
  SkColor surface;
  SkColor raised;
  SkColor text;
  SkColor secondary_text;
  SkColor separator;
  SkColor outline;
  SkColor focus_ring;
  SkColor selection;
};

struct Palette {
  bool set = false;
  bool installed = false;
  Colors light;
  Colors dark;
};

Palette& GetPalette() {
  static Palette palette;
  return palette;
}

SkColor ToSkColor(NSColor* color, SkColor fallback) {
  NSColor* srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!srgb) {
    return fallback;
  }
  auto channel = [](CGFloat value) {
    return static_cast<U8CPU>(std::lround(std::clamp(value, 0.0, 1.0) * 255));
  };
  return SkColorSetARGB(
      channel(srgb.alphaComponent), channel(srgb.redComponent),
      channel(srgb.greenComponent), channel(srgb.blueComponent));
}

// `palette`'s colours as they draw in `appearance` (dynamic colours differ).
Colors Resolve(NSDictionary<NSString*, NSColor*>* palette,
               NSAppearanceName appearance_name) {
  __block Colors colors;
  [[NSAppearance
      appearanceNamed:appearance_name] performAsCurrentDrawingAppearance:^{
    auto get = [&](NSString* key, SkColor fallback) {
      return ToSkColor(palette[key], fallback);
    };
    colors.accent = get(@"accent", SK_ColorBLUE);
    colors.on_accent = get(@"onAccent", SK_ColorWHITE);
    colors.accent_container = get(@"accentContainer", colors.accent);
    colors.on_accent_container = get(@"onAccentContainer", colors.on_accent);
    colors.surface = get(@"surface", SK_ColorWHITE);
    colors.raised = get(@"raised", colors.surface);
    colors.text = get(@"text", SK_ColorBLACK);
    colors.secondary_text = get(@"secondaryText", colors.text);
    colors.separator = get(@"separator", SK_ColorGRAY);
    colors.outline = get(@"outline", colors.separator);
    colors.focus_ring = get(@"focusRing", colors.accent);
    colors.selection = get(@"selection", colors.accent_container);
  }];
  return colors;
}

void AddPaletteMixer(ui::ColorProvider* provider,
                     const ui::ColorProviderKey& key) {
  using Key = ui::ColorProviderKey;
  const Palette& palette = GetPalette();
  // An extension's theme, a web app's colours and the high-contrast and
  // forced-colours modes keep Chrome's.
  if (!palette.set || key.custom_theme || key.app_controller ||
      key.forced_colors != Key::ForcedColors::kNone ||
      key.contrast_mode == Key::ContrastMode::kHigh) {
    return;
  }
  const Colors& c =
      key.color_mode == Key::ColorMode::kDark ? palette.dark : palette.light;
  ui::ColorMixer& mixer = provider->AddMixer();
  mixer[ui::kColorSysPrimary] = {c.accent};
  mixer[ui::kColorSysOnPrimary] = {c.on_accent};
  mixer[ui::kColorSysPrimaryContainer] = {c.accent_container};
  mixer[ui::kColorSysOnPrimaryContainer] = {c.on_accent_container};
  mixer[ui::kColorSysTonalContainer] = {c.accent_container};
  mixer[ui::kColorSysSurface] = {c.surface};
  mixer[ui::kColorSysBase] = {c.surface};
  mixer[ui::kColorSysBaseContainer] = {c.raised};
  mixer[ui::kColorSysBaseContainerElevated] = {c.raised};
  mixer[ui::kColorSysSurface1] = {c.raised};
  mixer[ui::kColorSysSurface2] = {c.raised};
  mixer[ui::kColorSysSurfaceVariant] = {c.separator};
  mixer[ui::kColorSysOnSurface] = {c.text};
  mixer[ui::kColorSysOnSurfaceSubtle] = {c.secondary_text};
  mixer[ui::kColorSysOnSurfaceSecondary] = {c.secondary_text};
  mixer[ui::kColorSysDivider] = {c.separator};
  mixer[ui::kColorSysOutline] = {c.outline};
  mixer[ui::kColorSysTonalOutline] = {c.outline};
  mixer[ui::kColorSysNeutralOutline] = {c.outline};
  mixer[ui::kColorSysStateFocusRing] = {c.focus_ring};
  mixer[ui::kColorSysStateTextHighlight] = {c.selection};
  // The Mac's native mixer sets the selection directly.
  mixer[ui::kColorTextSelectionBackground] = {c.selection};
}

// Every widget and page colours itself again (ColorProviderManager drops its
// providers, WebUI fetches colors.css again).
void Refresh() {
  if (ui::NativeTheme* theme = ui::NativeTheme::GetInstanceForNativeUi()) {
    theme->NotifyOnNativeThemeUpdated();
  }
}

}  // namespace

void SetPalette(NSDictionary<NSString*, NSColor*>* palette) {
  Palette& stored = GetPalette();
  stored.light = Resolve(palette, NSAppearanceNameAqua);
  stored.dark = Resolve(palette, NSAppearanceNameDarkAqua);
  stored.set = true;
  if (stored.installed) {
    Refresh();
  }
}

void InstallPaletteMixer() {
  Palette& palette = GetPalette();
  if (palette.installed) {
    return;
  }
  palette.installed = true;
  ui::ColorProviderManager::Get().AppendColorProviderInitializer(
      base::BindRepeating(&AddPaletteMixer));
}

}  // namespace browser_engine
