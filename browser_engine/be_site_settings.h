// The site-setting icons Chrome's address bar shows for a page, behind BETab's
// siteSettings and showSiteSetting:fromRect:: pop-ups or redirects blocked,
// the camera or microphone in use, location used or blocked, and the rest of
// Chrome's ContentSettingImageModels at M156. Chrome's Views location bar
// (LocationBarView, with a ContentSettingImageView per model) isn't in our
// windows: the app draws the icons, and their bubbles anchor to the rect it
// shows one at.

#ifndef BROWSER_ENGINE_BE_SITE_SETTINGS_H_
#define BROWSER_ENGINE_BE_SITE_SETTINGS_H_

#import <Foundation/Foundation.h>

#include <memory>
#include <optional>
#include <string>

#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/time/time.h"
#import "browser_engine/be_bubble_anchor.h"
#import "browser_engine/public/BEEngine.h"
#import "browser_engine/public/BEEngineOptional.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"

namespace content {
class WebContents;
}  // namespace content

namespace tabs {
class TabInterface;
}  // namespace tabs

namespace browser_engine {

class BEBrowserWindow;

// The icons Chrome's location bar would show for `contents`, in its order
// (ContentSettingImageModel::GenerateContentSettingImageModels()), each
// looked at now. Empty for a null `contents`.
NSArray<id<BESiteSetting>>* GetSiteSettings(content::WebContents* contents);

// A click on `tab`'s icon `identifier`, which the app shows at `rect` (in the
// window's coordinates, from its bottom left). Does nothing unless `tab` is
// the active tab of one of our windows and shows that icon now.
void ShowSiteSetting(tabs::TabInterface* tab,
                     const std::string& identifier,
                     NSRect rect);

// The popover for `tab`'s icon `identifier`, for the app to draw in place of
// Chrome's bubble: its bubble model's content and actions. Nil where the
// bubble stays Chrome's (camera and microphone, with their device menus, and
// bubbles with controls of their own), or when the icon isn't shown now.
id<BESiteSettingPopover> MakeSiteSettingPopover(tabs::TabInterface* tab,
                                                const std::string& identifier);

// What Chrome's location bar keeps for its icons per window: the open bubble,
// and what else it refreshes them for. Made by BEBrowserWindow before the app
// hears of the window, destroyed before its widget. Changes go to the window
// (BEBrowserWindow::OnSiteSettingsChanged()).
class BESiteSettings : public views::WidgetObserver {
 public:
  explicit BESiteSettings(BEBrowserWindow* window);
  BESiteSettings(const BESiteSettings&) = delete;
  BESiteSettings& operator=(const BESiteSettings&) = delete;
  ~BESiteSettings() override;

  // A click on icon `identifier` of `contents`, the window's active page,
  // which the app shows at `rect` (in the window's coordinates, from its
  // bottom left): Chrome's bubble for it, below `rect`. A click on the icon
  // whose bubble is open closes it. Does nothing for an icon the page doesn't
  // show.
  void Show(content::WebContents* contents,
            const std::string& identifier,
            NSRect rect);

  // Closes the open bubble, if there is one.
  void CloseBubble();

 private:
  class GeolocationObserver;

  // A bubble that closed while a mouse button was down: a press outside the
  // bubble closed it (see OnBubbleClosed()).
  struct BubbleClosedByPress {
    std::string identifier;
    // Where the press was, in screen coordinates (AppKit's).
    NSPoint location;
    base::TimeTicks time;
  };

  // The open bubble is closing or gone.
  void OnBubbleClosed();

  // views::WidgetObserver:
  void OnWidgetClosing(views::Widget* widget) override;
  void OnWidgetDestroying(views::Widget* widget) override;

  const raw_ptr<BEBrowserWindow> window_;

  // What bubbles anchor to, as to Chrome's icon, moved over the icon's rect
  // before each bubble.
  BEBubbleAnchor anchor_;

  // The open bubble's (it owns itself), from Show() until it closes; one at a
  // time, as Chrome's location bar shows one.
  raw_ptr<views::Widget> bubble_widget_ = nullptr;
  // The icon it's for.
  std::string bubble_identifier_;
  // ContentSettingImageView records the location bubble closing while it
  // says location is off in macOS.
  bool record_geolocation_dialog_closed_ = false;
  base::ScopedObservation<views::Widget, views::WidgetObserver>
      bubble_observation_{this};

  // Until the next Show().
  std::optional<BubbleClosedByPress> bubble_closed_by_press_;

  // Null where Chrome has no system location permission to watch.
  std::unique_ptr<GeolocationObserver> geolocation_observer_;
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_SITE_SETTINGS_H_
