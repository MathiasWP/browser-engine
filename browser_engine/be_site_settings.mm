#import "browser_engine/be_site_settings.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <string_view>
#include <utility>
#include <vector>

#include "base/metrics/user_metrics.h"
#include "base/metrics/user_metrics_action.h"
#include "base/notreached.h"
#include "base/strings/sys_string_conversions.h"
#include "browser_engine/be_browser_window.h"
#include "chrome/browser/ui/browser_content_setting_bubble_model_delegate.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/color/chrome_color_id.h"
#include "chrome/browser/ui/content_settings/content_setting_bubble_model.h"
#include "chrome/browser/ui/content_settings/content_setting_image_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/content_setting_bubble_contents.h"
#include "chrome/grit/generated_resources.h"
#include "components/content_settings/browser/page_specific_content_settings.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "services/device/public/cpp/device_features.h"
#include "services/device/public/cpp/geolocation/geolocation_system_permission_manager.h"
#include "services/device/public/cpp/geolocation/location_system_permission_status.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/bubble/bubble_frame_view.h"
#include "ui/views/controls/label.h"
#include "ui/views/style/typography.h"

NS_ASSUME_NONNULL_BEGIN

// One icon as the app reads it: a copy, which doesn't change.
@interface BEChromiumSiteSetting : NSObject <BESiteSetting>
- (instancetype)initWithIdentifier:(NSString*)identifier
                             title:(NSString*)title
                         isBlocked:(BOOL)isBlocked NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumSiteSetting

@synthesize identifier = _identifier;
@synthesize title = _title;
@synthesize isBlocked = _isBlocked;

- (instancetype)initWithIdentifier:(NSString*)identifier
                             title:(NSString*)title
                         isBlocked:(BOOL)isBlocked {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _title = [title copy];
    _isBlocked = isBlocked;
  }
  return self;
}

@end

namespace browser_engine {

namespace {

using content_settings::PageSpecificContentSettings;
using ImageType = ContentSettingImageModel::ImageType;

// How long after a press closed a bubble the click it began can come: the app
// hears of a click on its icon on mouse up (see BESiteSettings::Show()).
constexpr base::TimeDelta kPressToClick = base::Seconds(1);

// Chrome's location bar icons, each updated for `contents` as
// LocationBarView::RefreshContentSettingViews() updates them, without the
// ones it hides. The camera and microphone (and, with its feature, sensors)
// are among them even where Chrome's own bar shows them as activity
// indicators on its left instead (ContentSettingImageModel::
// IsLeftHandSideIndicatorEnabled()): the app's bar is the one place they show.
std::vector<std::unique_ptr<ContentSettingImageModel>> GetVisibleModels(
    content::WebContents* contents) {
  std::vector<std::unique_ptr<ContentSettingImageModel>> models =
      ContentSettingImageModel::GenerateContentSettingImageModels();
  for (const std::unique_ptr<ContentSettingImageModel>& model : models) {
    model->Update(contents);
  }
  std::erase_if(models,
                [](const std::unique_ptr<ContentSettingImageModel>& model) {
                  return !model->is_visible();
                });
  return models;
}

// The camera, the microphone or both, as the media icon tells them apart
// (ContentSettingMediaImageModel::UpdateAndGetVisibility()), which shows the
// camera unless only the microphone was used.
std::string_view GetMediaStreamIdentifier(content::WebContents* contents) {
  PageSpecificContentSettings* content_settings =
      PageSpecificContentSettings::GetForFrame(contents->GetPrimaryMainFrame());
  if (!content_settings) {
    return "camera";
  }
  const PageSpecificContentSettings::MicrophoneCameraState state =
      content_settings->GetMicrophoneCameraState();
  const bool camera = state.Has(PageSpecificContentSettings::kCameraAccessed);
  const bool microphone =
      state.Has(PageSpecificContentSettings::kMicrophoneAccessed);
  if (camera && microphone) {
    return "camera-microphone";
  }
  return microphone ? "microphone" : "camera";
}

// Chrome's kind of icon as the stable name the app knows
// (BESiteSetting.identifier), for a model updated for `contents`.
std::string_view GetIdentifier(const ContentSettingImageModel& model,
                               content::WebContents* contents) {
  // Every type, in Chrome's order. Warnings aren't errors in this build
  // (README.md), but this one is: a type Chrome adds stops the build here
  // rather than reaching the app without a name.
#pragma clang diagnostic push
#pragma clang diagnostic error "-Wswitch"
  switch (model.image_type()) {
    case ImageType::kCookies:
      return "cookies";
    case ImageType::kImages:
      return "images";
    case ImageType::kJavaScript:
      return "javascript";
    case ImageType::kPopups:
      return "popups";
    case ImageType::kGeolocation:
      return "location";
    case ImageType::kMixedScript:
      return "mixed-content";
    case ImageType::kProtocolHandlers:
      return "protocol-handlers";
    case ImageType::kMediaStream:
      return GetMediaStreamIdentifier(contents);
    case ImageType::kSensors:
      return "sensors";
    case ImageType::kAds:
      return "ads";
    case ImageType::kAutomaticDownloads:
      return "downloads";
    case ImageType::kMidiSysex:
      return "midi";
    case ImageType::kSound:
      return "sound";
    case ImageType::kFramebust:
      return "redirects";
    case ImageType::kClipboardReadWrite:
      return "clipboard";
    case ImageType::kNotifications:
      return "notifications";
    case ImageType::kStorageAccess:
      return "storage-access";
  }
#pragma clang diagnostic pop
  NOTREACHED();
}

// Whether Chrome strikes the icon through: the model's blocked state, and
// always for redirects, whose one icon is the struck-through one
// (ContentSettingImageModel::SetFramebustBlockedIcon(), which leaves
// is_blocked() false).
bool IsBlocked(const ContentSettingImageModel& model) {
  return model.is_blocked() || model.image_type() == ImageType::kFramebust;
}

}  // namespace

NSArray<id<BESiteSetting>>* GetSiteSettings(content::WebContents* contents) {
  if (!contents) {
    return @[];
  }
  std::vector<std::unique_ptr<ContentSettingImageModel>> models =
      GetVisibleModels(contents);
  NSMutableArray<id<BESiteSetting>>* settings =
      [NSMutableArray arrayWithCapacity:models.size()];
  for (const std::unique_ptr<ContentSettingImageModel>& model : models) {
    // The tooltip is what the icon says on hover ("Pop-ups blocked").
    [settings
        addObject:[[BEChromiumSiteSetting alloc]
                      initWithIdentifier:base::SysUTF8ToNSString(
                                             GetIdentifier(*model, contents))
                                   title:base::SysUTF16ToNSString(
                                             model->get_tooltip())
                               isBlocked:IsBlocked(*model)]];
  }
  return settings;
}

void ShowSiteSetting(tabs::TabInterface* tab,
                     const std::string& identifier,
                     NSRect rect) {
  BrowserWindowInterface* browser = tab->GetBrowserWindowInterface();
  BEBrowserWindow* window = BEBrowserWindow::FromBrowser(browser);
  // Chrome's icons are its window's active tab's. None in Chrome's own
  // windows (popups, apps), nor once ours is closing.
  if (!window || !window->site_settings() ||
      browser->GetTabStripModel()->GetActiveTab() != tab) {
    return;
  }
  window->site_settings()->Show(tab->GetContents(), identifier, rect);
}

// What else LocationBarView refreshes its icons for
// (OnSystemPermissionUpdated()): the app's location permission in macOS,
// which the location icon shows ("Location is turned off in macOS").
class BESiteSettings::GeolocationObserver
    : public device::GeolocationSystemPermissionManager::PermissionObserver {
 public:
  GeolocationObserver(BEBrowserWindow* window,
                      device::GeolocationSystemPermissionManager* manager)
      : window_(window) {
    observation_.Observe(manager);
  }
  GeolocationObserver(const GeolocationObserver&) = delete;
  GeolocationObserver& operator=(const GeolocationObserver&) = delete;
  ~GeolocationObserver() override = default;

 private:
  // device::GeolocationSystemPermissionManager::PermissionObserver:
  void OnSystemPermissionUpdated(
      device::LocationSystemPermissionStatus new_status) override {
    window_->OnSiteSettingsChanged();
  }
  void OnPermissionManagerShuttingDown() override { observation_.Reset(); }

  const raw_ptr<BEBrowserWindow> window_;
  base::ScopedObservation<
      device::GeolocationSystemPermissionManager,
      device::GeolocationSystemPermissionManager::PermissionObserver>
      observation_{this};
};

BESiteSettings::BESiteSettings(BEBrowserWindow* window)
    : window_(window), anchor_(window->widget()) {
  // As LocationBarView watches it. The manager is the browser process's,
  // made at startup.
  if (features::IsOsLevelGeolocationPermissionSupportEnabled()) {
    if (device::GeolocationSystemPermissionManager* manager =
            device::GeolocationSystemPermissionManager::GetInstance()) {
      geolocation_observer_ =
          std::make_unique<GeolocationObserver>(window, manager);
    }
  }
}

BESiteSettings::~BESiteSettings() {
  // As the window goes, an open bubble goes now, while the page and the
  // browser's ContentSettingBubbleModelDelegate its model uses are there.
  if (views::Widget* bubble_widget = bubble_widget_) {
    OnBubbleClosed();
    bubble_widget->CloseNow();
  }
}

void BESiteSettings::Show(content::WebContents* contents,
                          const std::string& identifier,
                          NSRect rect) {
  NSWindow* ns_window = window_->GetNativeWindow().GetNativeNSWindow();
  if (!ns_window || !contents) {
    return;
  }
  const NSRect screen_rect = [ns_window convertRectToScreen:rect];

  // A click on the icon whose bubble is open closes it, as in Chrome's
  // location bar. Usually it has closed already: the press activated the
  // window under it, which closes the bubble (BubbleDialogDelegate's
  // close-on-deactivate), and the app hears of the click only on mouse up.
  // Chrome's icon ignores the press that closed its bubble
  // (IconLabelBubbleView::OnMousePressed()); so do we, as BEExtensions::Run()
  // does for popups.
  const std::optional<BubbleClosedByPress> closed_by_press =
      std::exchange(bubble_closed_by_press_, std::nullopt);
  if (bubble_widget_ && bubble_identifier_ == identifier) {
    CloseBubble();
    return;
  }
  if (closed_by_press && closed_by_press->identifier == identifier &&
      NSPointInRect(closed_by_press->location, screen_rect) &&
      base::TimeTicks::Now() - closed_by_press->time < kPressToClick) {
    return;
  }

  // The model for the icon as the page shows it now; an icon it no longer
  // shows has none.
  std::vector<std::unique_ptr<ContentSettingImageModel>> models =
      GetVisibleModels(contents);
  auto it = std::ranges::find_if(
      models, [contents, &identifier](
                  const std::unique_ptr<ContentSettingImageModel>& model) {
        return GetIdentifier(*model, contents) == identifier;
      });
  if (it == models.end()) {
    return;
  }
  ContentSettingImageModel* model = it->get();
  // What the bubble's links go through: Chrome's settings pages, the cookies
  // dialog and help pages, opened in this window (BrowserWindowFeatures makes
  // it for every browser).
  BrowserContentSettingBubbleModelDelegate* delegate =
      BrowserContentSettingBubbleModelDelegate::From(window_->browser());
  if (!delegate) {
    return;
  }
  // One bubble at a time: another icon's goes (usually the press on this icon
  // closed it already).
  CloseBubble();
  if (bubble_widget_) {
    return;  // It wouldn't close.
  }

  // ContentSettingImageView::ShowBubbleImpl(): the model's bubble, dropping
  // down from the icon with its right edge on the icon's, and its title
  // styled as there.
  auto bubble = std::make_unique<ContentSettingBubbleContents>(
      model->CreateBubbleModel(delegate, contents), contents,
      anchor_.AnchorAt(anchor_.ConvertFromScreen(screen_rect)),
      views::BubbleBorder::TOP_RIGHT);
  ContentSettingBubbleContents* bubble_view = bubble.get();
  views::Widget* bubble_widget =
      views::BubbleDialogDelegateView::CreateBubble(std::move(bubble));
  if (views::BubbleFrameView* const frame_view =
          bubble_view->GetBubbleFrameView()) {
    if (views::Label* title_label = frame_view->default_title()) {
      title_label->SetTextStyle(views::style::STYLE_HEADLINE_4);
      title_label->SetEnabledColor(kColorActivityIndicatorForeground);
    }
  }
  bubble_widget_ = bubble_widget;
  bubble_identifier_ = identifier;
  record_geolocation_dialog_closed_ =
      model->image_type() == ImageType::kGeolocation &&
      model->explanatory_string_id() == IDS_GEOLOCATION_TURNED_OFF;
  bubble_observation_.Observe(bubble_widget);
  bubble_widget->Show();
}

void BESiteSettings::CloseBubble() {
  // Closing calls OnWidgetClosing().
  if (bubble_widget_) {
    bubble_widget_->Close();
  }
}

void BESiteSettings::OnBubbleClosed() {
  if (!bubble_widget_) {
    return;
  }
  bubble_observation_.Reset();
  bubble_widget_ = nullptr;
  // ContentSettingImageView::OnWidgetDestroying(), on the Mac.
  if (std::exchange(record_geolocation_dialog_closed_, false)) {
    base::RecordAction(
        base::UserMetricsAction("ContentSettings.GeolocationDialog.Closed"));
  }
  // A press outside the bubble closes it on mouse down; Show() needs to know
  // if that press began a click on the icon itself.
  // UNVERIFIED: that a press on the app's bar, in the bubble's parent window,
  // closes the bubble (close-on-deactivate) before the app hears of the
  // click. Read, as for extension popups (BEExtensions::OnPopupClosed()), not
  // run. If not, Show() finds the bubble open and closes it, which looks the
  // same.
  if ([NSEvent pressedMouseButtons] != 0) {
    bubble_closed_by_press_ = BubbleClosedByPress{
        bubble_identifier_, [NSEvent mouseLocation], base::TimeTicks::Now()};
  }
}

void BESiteSettings::OnWidgetClosing(views::Widget* widget) {
  OnBubbleClosed();
}

void BESiteSettings::OnWidgetDestroying(views::Widget* widget) {
  // CloseNow() skips OnWidgetClosing().
  OnBubbleClosed();
}

}  // namespace browser_engine
