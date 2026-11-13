#import "browser_engine/be_profiles.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/numerics/safe_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_engine.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_avatar_icon_util.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_metrics.h"
#include "chrome/browser/profiles/profile_statistics.h"
#include "chrome/browser/profiles/profile_statistics_factory.h"
#include "chrome/browser/profiles/profile_window.h"
#include "chrome/browser/profiles/profiles_state.h"
#include "chrome/browser/themes/theme_service.h"
#include "chrome/browser/themes/theme_service_factory.h"
#include "chrome/browser/ui/profiles/profile_colors_util.h"
#include "chrome/browser/ui/profiles/profile_picker.h"
#include "chrome/browser/ui/webui/cr_components/theme_color_picker/customize_chrome_colors.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "skia/ext/skia_utils_mac.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/base/l10n/l10n_util_mac.h"
#include "ui/base/mojom/themes.mojom.h"
#include "ui/base/resource/resource_bundle.h"
#include "ui/gfx/image/image.h"

// A profile as the app reads it: a copy, made when the list was read.
@interface BEChromiumProfile : NSObject <BEProfile, BEProfileDetails>
- (instancetype)initWithEntry:(const ProfileAttributesEntry&)entry
                       isOpen:(BOOL)isOpen NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumProfile

@synthesize identifier = _identifier;
@synthesize name = _name;
@synthesize avatar = _avatar;
@synthesize avatarIndex = _avatarIndex;
@synthesize color = _color;
@synthesize isOpen = _isOpen;

- (instancetype)initWithEntry:(const ProfileAttributesEntry&)entry
                       isOpen:(BOOL)isOpen {
  if ((self = [super init])) {
    _identifier = base::SysUTF8ToNSString(entry.GetPath().BaseName().value());
    _name = base::SysUTF16ToNSString(entry.GetName());
    // The bundled avatars and Chrome's placeholder: the high-resolution ones
    // download from Google, which ungoogled-chromium doesn't reach.
    const gfx::Image avatar =
        entry.GetAvatarIcon(/*size_for_placeholder_avatar=*/64,
                            /*use_high_res_file=*/false);
    _avatar = avatar.IsEmpty() ? nil : avatar.ToNSImage();
    _avatarIndex = base::checked_cast<NSInteger>(entry.GetAvatarIconIndex());
    // The seed its theme was made from, as the layer keeps it in the entry
    // (SetColor()); none for Chrome's default.
    if (const std::optional<ProfileThemeColors> colors =
            entry.GetProfileThemeColorsIfSet()) {
      _color = skia::SkColorToSRGBNSColor(colors->profile_color_seed);
    }
    _isOpen = isOpen;
  }
  return self;
}

@end

// One of the avatars a profile can have, as Chrome's avatar selector offers
// it.
@interface BEChromiumProfileAvatarChoice : NSObject <BEProfileAvatarChoice>
- (instancetype)initWithIndex:(NSInteger)index
                        label:(NSString*)label
                        image:(NSImage*)image NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumProfileAvatarChoice

@synthesize index = _index;
@synthesize label = _label;
@synthesize image = _image;

- (instancetype)initWithIndex:(NSInteger)index
                        label:(NSString*)label
                        image:(NSImage*)image {
  if ((self = [super init])) {
    _index = index;
    _label = [label copy];
    _image = image;
  }
  return self;
}

@end

// One of Customize Chrome's colours.
@interface BEChromiumProfileColorChoice : NSObject <BEProfileColorChoice>
- (instancetype)initWithLabel:(NSString*)label
                        color:(NSColor*)color NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumProfileColorChoice

@synthesize label = _label;
@synthesize color = _color;

- (instancetype)initWithLabel:(NSString*)label color:(NSColor*)color {
  if ((self = [super init])) {
    _label = [label copy];
    _color = color;
  }
  return self;
}

@end

namespace browser_engine {

namespace {

ProfileManager* Manager() {
  return g_browser_process ? g_browser_process->profile_manager() : nullptr;
}

ProfileAttributesStorage* Storage() {
  ProfileManager* manager = Manager();
  return manager ? &manager->GetProfileAttributesStorage() : nullptr;
}

// The avatar at `index`, with Chrome's label for it ("Cat").
BEChromiumProfileAvatarChoice* AvatarChoice(size_t index,
                                            const gfx::Image& image) {
  return [[BEChromiumProfileAvatarChoice alloc]
      initWithIndex:base::checked_cast<NSInteger>(index)
              label:l10n_util::GetNSString(
                        profiles::GetDefaultAvatarLabelResourceIDAtIndex(index))
              image:image.ToNSImage()];
}

// A profile's theme colour as Chrome's colour picker sets it.
struct ThemeColor {
  SkColor seed;
  ui::mojom::BrowserColorVariant variant;
};

// The app's colour as Chrome's: sRGB, opaque. None for colours without
// components (patterns).
std::optional<SkColor> SkColorFromNSColor(NSColor* color) {
  NSColor* srgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!srgb) {
    return std::nullopt;
  }
  auto component = [](CGFloat value) {
    return base::ClampRound<U8CPU>(std::clamp<CGFloat>(value, 0, 1) * 255);
  };
  return SkColorSetRGB(component(srgb.redComponent),
                       component(srgb.greenComponent),
                       component(srgb.blueComponent));
}

// Chrome's colour for the app's: a choice's own colour object first (Blue
// and Cool grey, and Rose and Pink, share a seed and differ in variant), then
// a choice's value, then a colour of the app's own.
std::optional<ThemeColor> ThemeColorFor(
    NSArray<id<BEProfileColorChoice>>* choices,
    NSColor* color) {
  for (NSUInteger i = 0; i < choices.count; ++i) {
    if (choices[i].color == color) {
      const DynamicColorInfo& info = kDynamicCustomizeChromeColors[i];
      return ThemeColor{info.color, info.variant};
    }
  }
  const std::optional<SkColor> seed = SkColorFromNSColor(color);
  if (!seed) {
    return std::nullopt;
  }
  for (const DynamicColorInfo& info : kDynamicCustomizeChromeColors) {
    if (info.color == *seed) {
      return ThemeColor{info.color, info.variant};
    }
  }
  // One of the app's own, as Chrome's hue slider makes them
  // (ThemeColorPickerHandler::SetSeedColorFromHue()).
  return ThemeColor{*seed, ui::mojom::BrowserColorVariant::kTonalSpot};
}

// Runs `apply` with the profile at `path` loaded: now if it is, else once
// Chrome has loaded it, which then unloads it again (its theme and avatar are
// profile preferences, so Chrome's pages change them on a loaded profile).
void WithLoadedProfile(const base::FilePath& path,
                       base::OnceCallback<void(Profile*)> apply) {
  ProfileManager* manager = Manager();
  if (!manager) {
    return;
  }
  if (Profile* profile = manager->GetProfileByPath(path)) {
    std::move(apply).Run(profile);
    return;
  }
  manager->LoadProfileByPath(
      path, /*incognito=*/false,
      base::BindOnce(
          [](base::OnceCallback<void(Profile*)> apply, Profile* profile) {
            if (!profile) {
              return;
            }
            // Held for the change only. Its origin, like the picker's
            // statistics one, also ends Chrome's wait for the profile's
            // first window, so the profile unloads when it goes.
            std::unique_ptr<ScopedProfileKeepAlive> keep_alive =
                ScopedProfileKeepAlive::TryAcquire(
                    profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
            if (keep_alive) {
              std::move(apply).Run(profile);
            }
          },
          std::move(apply)));
}

// As ThemeColorPickerHandler::SetSeedColor() and SetDefaultColor(), then
// the colours in the profile's entry, which the picker and the profile's
// placeholder avatar are drawn from. Only Chrome's Views avatar button
// refreshes them otherwise (AvatarToolbarButton::OnThemeChanged()), and our
// windows have none; the seed is the one chosen, as Chrome's
// GetCurrentProfileThemeColors() keeps it.
void ApplyThemeColor(std::optional<ThemeColor> color, Profile* profile) {
  if (ThemeService* theme_service =
          ThemeServiceFactory::GetForProfile(profile)) {
    if (color) {
      theme_service->SetUserColorAndBrowserColorVariant(color->seed,
                                                        color->variant);
    } else {
      theme_service->SetUserColor(std::nullopt);
    }
    theme_service->UseDeviceTheme(false);
  }
  ProfileAttributesStorage* storage = Storage();
  ProfileAttributesEntry* entry =
      storage ? storage->GetProfileAttributesWithPath(profile->GetPath())
              : nullptr;
  if (!entry) {
    return;
  }
  std::optional<ProfileThemeColors> colors;
  if (color) {
    colors = GetProfileThemeColorsForAutogeneratedColor(color->seed);
    colors->profile_color_seed = color->seed;
  }
  entry->SetProfileThemeColors(colors);
}

// After a deletion Chrome opens a window for the profile it falls back to,
// unless its picker is open (webui::OpenNewWindowForProfile()): the app's
// picker stands in for it.
void OpenWindowAfterDeletion(Profile* profile) {
  id delegate = GetEngineDelegate();
  if ([delegate respondsToSelector:@selector(engine:showProfilePicker:)] &&
      [delegate engine:GetEngine()
          showProfilePicker:BEProfilePickerReasonAfterDeletion]) {
    return;
  }
  // Its window, or a new one as at startup: what Chrome's
  // FindOrCreateNewWindowForProfile(profile, IsProcessStartup::kYes,
  // IsFirstRun::kYes, false) there does, which is_new_profile asks for.
  profiles::OpenBrowserWindowForProfile(
      base::OnceCallback<void(BrowserWindowInterface*)>(),
      /*always_create=*/false, /*is_new_profile=*/true,
      /*open_command_line_urls=*/false, profile);
}

}  // namespace

BEProfiles::BEProfiles() = default;

BEProfiles::~BEProfiles() = default;

void BEProfiles::Start() {
  if (ProfileAttributesStorage* storage = Storage();
      storage && !observation_.IsObserving()) {
    observation_.Observe(storage);
    manager_observation_.Observe(g_browser_process->profile_manager());
    // The app's windows came before the list: it reads it now.
    NotifyChange();
  }
}

NSArray<id<BEProfile>>* BEProfiles::items() const {
  ProfileAttributesStorage* storage = Storage();
  if (!storage) {
    return @[];
  }
  // As Chrome's profile menu lists them, less the ones it hides.
  ProfileManager* manager = Manager();
  NSMutableArray<id<BEProfile>>* items = [NSMutableArray array];
  for (ProfileAttributesEntry* entry :
       storage->GetAllProfilesAttributesSortedByNameWithCheck()) {
    if (!entry->IsOmitted()) {
      [items addObject:[[BEChromiumProfile alloc]
                           initWithEntry:*entry
                                  isOpen:manager->GetProfileByPath(
                                             entry->GetPath()) != nullptr]];
    }
  }
  return items;
}

base::FilePath BEProfiles::PathForIdentifier(NSString* identifier) const {
  ProfileAttributesStorage* storage = Storage();
  if (!storage) {
    return base::FilePath();
  }
  const std::string name = base::SysNSStringToUTF8(identifier);
  for (ProfileAttributesEntry* entry :
       storage->GetAllProfilesAttributesSortedByNameWithCheck()) {
    if (entry->GetPath().BaseName().value() == name) {
      return entry->GetPath();
    }
  }
  return base::FilePath();
}

// MARK: The app's picker and editor

// static
NSInteger BEProfiles::GenericAvatarIndex() {
  return base::checked_cast<NSInteger>(profiles::GetPlaceholderAvatarIndex());
}

NSArray<id<BEProfileAvatarChoice>>* BEProfiles::AvatarChoices() const {
  // As GetIconsAndLabelsForProfileAvatarSelector() for a profile without an
  // account: the placeholder (in the default colours here, as no profile's
  // are known; avatarForProfile: draws a profile's own), then the modern
  // avatars. The older ones still show for profiles that have them, but
  // Chrome no longer offers them.
  ui::ResourceBundle& bundle = ui::ResourceBundle::GetSharedInstance();
  NSMutableArray<id<BEProfileAvatarChoice>>* choices = [NSMutableArray array];
  const size_t start = profiles::GetModernAvatarIconStartIndex();
  const size_t count = profiles::GetDefaultAvatarIconCount();
  // As big as the bundled avatars, drawn at twice that.
  int size = profiles::kAvatarIconSize;
  if (start < count) {
    const gfx::Image& first = bundle.GetNativeImageNamed(
        profiles::GetDefaultAvatarIconResourceIDAtIndex(start));
    if (!first.IsEmpty()) {
      size = first.Width();
    }
  }
  const size_t generic = profiles::GetPlaceholderAvatarIndex();
  const ProfileThemeColors colors = GetDefaultProfileThemeColors();
  const gfx::Image placeholder = profiles::GetSizedAvatarIcon(
      profiles::GetPlaceholderAvatarIconWithColors(
          colors.default_avatar_fill_color, colors.default_avatar_stroke_color,
          size * 2),
      size, size);
  [choices addObject:AvatarChoice(generic, placeholder)];
  for (size_t i = start; i < count; ++i) {
    const gfx::Image& image = bundle.GetNativeImageNamed(
        profiles::GetDefaultAvatarIconResourceIDAtIndex(i));
    if (image.IsEmpty()) {
      continue;
    }
    [choices addObject:AvatarChoice(i, image)];
  }
  return choices;
}

NSArray<id<BEProfileColorChoice>>* BEProfiles::ColorChoices() {
  if (!color_choices_) {
    NSMutableArray<id<BEProfileColorChoice>>* choices = [NSMutableArray array];
    for (const DynamicColorInfo& info : kDynamicCustomizeChromeColors) {
      [choices
          addObject:[[BEChromiumProfileColorChoice alloc]
                        initWithLabel:l10n_util::GetNSString(info.label_id)
                                color:skia::SkColorToSRGBNSColor(info.color)]];
    }
    color_choices_ = [choices copy];
  }
  return color_choices_;
}

NSImage* BEProfiles::Avatar(NSString* identifier, CGFloat points) const {
  ProfileAttributesStorage* storage = Storage();
  const base::FilePath path = PathForIdentifier(identifier);
  ProfileAttributesEntry* entry =
      storage && !path.empty() ? storage->GetProfileAttributesWithPath(path)
                               : nullptr;
  if (!entry) {
    return nil;
  }
  // The placeholder is drawn at the size asked for, the bundled avatars are
  // scaled; never the high-resolution files (see BEChromiumProfile).
  const int size = std::max(1, base::ClampRound(points));
  const gfx::Image image = entry->GetAvatarIcon(
      /*size_for_placeholder_avatar=*/size * 2, /*use_high_res_file=*/false);
  if (image.IsEmpty()) {
    return nil;
  }
  return profiles::GetSizedAvatarIcon(image, size, size).ToNSImage();
}

void BEProfiles::Create(NSString* name,
                        NSInteger avatar_index,
                        NSColor* color,
                        bool open_window,
                        void (^completion)(NSString*)) {
  ProfileAttributesStorage* storage = Storage();
  if (!storage || !profiles::IsProfileCreationAllowed()) {
    // Policy forbids it (BrowserAddPersonEnabled). The completion still
    // hears, once, on a later task.
    base::OnceClosure not_made = base::BindOnce(^{
      completion(nil);
    });
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, std::move(not_made));
    return;
  }
  std::u16string profile_name;
  base::TrimWhitespace(base::SysNSStringToUTF16(name ?: @""), base::TRIM_ALL,
                       &profile_name);
  const bool name_chosen = !profile_name.empty();
  if (!name_chosen) {
    profile_name = storage->ChooseNameForNewProfile();
  }
  std::optional<ThemeColor> theme_color;
  if (color) {
    // Resolved now: the choice is known by its object.
    theme_color = ThemeColorFor(ColorChoices(), color);
  }
  // As ProfilePickerView::SwitchToSignedOutPostIdentityFlow(), but visible
  // from the start: the app has asked for everything already, so there's no
  // customisation step for a hidden profile to wait on.
  ProfileManager::CreateMultiProfileAsync(
      profile_name,
      profiles::GetSanitizedAvatarIndex(
          base::saturated_cast<int>(avatar_index)),
      /*is_hidden=*/false,
      base::BindOnce(
          [](std::u16string profile_name, bool name_chosen,
             std::optional<ThemeColor> theme_color, bool open_window,
             void (^completion)(NSString*), Profile* profile) {
            if (!profile) {
              completion(nil);
              return;
            }
            if (name_chosen) {
              // As FinalizeNewProfileSetup(): the user's name, kept.
              if (ProfileAttributesStorage* storage = Storage()) {
                if (ProfileAttributesEntry* entry =
                        storage->GetProfileAttributesWithPath(
                            profile->GetPath())) {
                  entry->SetLocalProfileName(profile_name,
                                             /*is_default_name=*/false);
                }
              }
            }
            // The colour before the window, as the picker does, so it opens
            // in it.
            if (theme_color) {
              ApplyThemeColor(theme_color, profile);
            }
            if (open_window) {
              // As the picker opens a new profile: the first run's window.
              profiles::OpenBrowserWindowForProfile(
                  base::OnceCallback<void(BrowserWindowInterface*)>(),
                  /*always_create=*/true, /*is_new_profile=*/true,
                  /*open_command_line_urls=*/false, profile);
            }
            completion(
                base::SysUTF8ToNSString(profile->GetPath().BaseName().value()));
          },
          std::move(profile_name), name_chosen, theme_color, open_window,
          completion));
}

bool BEProfiles::Rename(NSString* identifier, NSString* name) {
  ProfileAttributesStorage* storage = Storage();
  const base::FilePath path = PathForIdentifier(identifier);
  ProfileAttributesEntry* entry =
      storage && !path.empty() ? storage->GetProfileAttributesWithPath(path)
                               : nullptr;
  std::u16string profile_name;
  base::TrimWhitespace(base::SysNSStringToUTF16(name ?: @""), base::TRIM_ALL,
                       &profile_name);
  if (!entry || profile_name.empty()) {
    return false;
  }
  if (Profile* profile = Manager()->GetProfileByPath(path)) {
    // As Settings' manage page: the profile's preference, which the entry
    // follows.
    profiles::UpdateProfileName(profile, profile_name);
  } else {
    // As the picker, which renames profiles that aren't loaded.
    entry->SetLocalProfileName(profile_name, /*is_default_name=*/false);
  }
  return true;
}

void BEProfiles::SetAvatarIndex(NSString* identifier, NSInteger index) {
  const base::FilePath path = PathForIdentifier(identifier);
  if (path.empty()) {
    return;
  }
  // As Settings' manage page (ManageProfileHandler): the profile's
  // preferences, which the entry follows.
  WithLoadedProfile(
      path,
      base::BindOnce(
          [](size_t avatar_index, Profile* profile) {
            profiles::SetDefaultProfileAvatarIndex(profile, avatar_index);
          },
          profiles::GetSanitizedAvatarIndex(base::saturated_cast<int>(index))));
}

void BEProfiles::SetColor(NSString* identifier, NSColor* color) {
  const base::FilePath path = PathForIdentifier(identifier);
  if (path.empty()) {
    return;
  }
  std::optional<ThemeColor> theme_color;
  if (color) {
    theme_color = ThemeColorFor(ColorChoices(), color);
  }
  WithLoadedProfile(path, base::BindOnce(&ApplyThemeColor, theme_color));
}

void BEProfiles::CountData(
    NSString* identifier,
    void (^update)(NSDictionary<NSString*, NSNumber*>*)) {
  StopCountingData();
  const base::FilePath path = PathForIdentifier(identifier);
  ProfileManager* manager = Manager();
  if (path.empty() || !manager) {
    return;
  }
  // As ProfilePickerHandler::HandleGetProfileStatistics(): the profile
  // loaded, and kept so until the counting stops.
  base::OnceCallback<void(Profile*)> gather =
      base::BindOnce(&BEProfiles::GatherStatistics, weak_factory_.GetWeakPtr(),
                     counting_, update);
  if (Profile* profile = manager->GetProfileByPath(path)) {
    std::move(gather).Run(profile);
  } else {
    manager->LoadProfileByPath(path, /*incognito=*/false, std::move(gather));
  }
}

void BEProfiles::StopCountingData() {
  ++counting_;
  counting_keep_alive_.reset();
}

void BEProfiles::Delete(NSString* identifier) {
  const base::FilePath path = PathForIdentifier(identifier);
  ProfileManager* manager = Manager();
  if (path.empty() || !manager || !profiles::IsMultipleProfilesEnabled()) {
    return;
  }
  // As ProfilePickerHandler::HandleRemoveProfile(): the counting's keep-alive
  // lasts until the deletion is under way, so the profile isn't unloaded and
  // loaded again for it.
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive =
      std::move(counting_keep_alive_);
  ++counting_;
  // webui::DeleteProfileAtPath(), whose window after the deletion the app's
  // picker may stand in for. Closing the profile's windows asks their pages
  // first; one that stays cancels the deletion, silently.
  manager->GetDeleteProfileHelper().MaybeScheduleProfileForDeletion(
      path, base::BindOnce(&OpenWindowAfterDeletion),
      ProfileMetrics::DELETE_PROFILE_USER_MANAGER);
}

void BEProfiles::Pick(NSString* identifier) {
  const base::FilePath path = PathForIdentifier(identifier);
  if (path.empty()) {
    return;
  }
  // As ProfilePickerFlowController::PickProfile(): the pages the app was
  // opened with, if Chrome kept them for the picker, go to the first profile
  // picked. Its window, or a new one.
  const bool open_command_line_urls =
      ProfilePicker::GetOpenCommandLineUrlsInNextProfileOpened();
  ProfilePicker::SetOpenCommandLineUrlsInNextProfileOpened(false);
  profiles::SwitchToProfile(path, /*always_create=*/false,
                            base::OnceCallback<void(BrowserWindowInterface*)>(),
                            open_command_line_urls);
}

void BEProfiles::Move(NSInteger from, NSInteger to) {
  ProfileAttributesStorage* storage = Storage();
  if (!storage) {
    return;
  }
  // `from` and `to` index the list the app has, which leaves out the
  // profiles Chrome hides; Chrome's order (Local State's profile order, which
  // its lists follow with ProfilesReordering) has them all.
  std::vector<ProfileAttributesEntry*> shown =
      storage->GetAllProfilesAttributesSortedByNameWithCheck();
  std::erase_if(shown, [](const ProfileAttributesEntry* entry) {
    return entry->IsOmitted();
  });
  const auto count = static_cast<NSInteger>(shown.size());
  if (from < 0 || to < 0 || from >= count || to >= count || from == to) {
    return;
  }
  const std::vector<ProfileAttributesEntry*> order =
      storage->GetAllProfilesAttributesSortedForDisplay();
  const auto from_it = std::ranges::find(order, shown[from]);
  const auto to_it = std::ranges::find(order, shown[to]);
  if (from_it == order.end() || to_it == order.end()) {
    return;
  }
  // As ProfilePickerHandler::HandleUpdateProfileOrder().
  storage->UpdateProfilesOrderPref(static_cast<size_t>(from_it - order.begin()),
                                   static_cast<size_t>(to_it - order.begin()));
  // Chrome tells no observer the order changed.
  NotifyChange();
}

bool BEProfiles::CanCreateProfiles() const {
  return Storage() && profiles::IsProfileCreationAllowed();
}

bool BEProfiles::GuestModeEnabled() const {
  return Storage() && profiles::IsGuestModeEnabled();
}

void BEProfiles::OpenGuestWindow() {
  if (GuestModeEnabled()) {
    profiles::SwitchToGuestProfile();
  }
}

bool BEProfiles::ShowsPickerOnStartup() const {
  PrefService* local_state =
      g_browser_process ? g_browser_process->local_state() : nullptr;
  return local_state &&
         local_state->GetBoolean(prefs::kBrowserShowProfilePickerOnStartup);
}

void BEProfiles::SetShowsPickerOnStartup(bool shows) {
  // As ProfilePickerHandler::HandleAskOnStartupChanged(). Chrome asks only
  // with two profiles or more (ProfilePicker::GetStartupMode()), and a policy
  // may decide instead.
  if (PrefService* local_state =
          g_browser_process ? g_browser_process->local_state() : nullptr) {
    local_state->SetBoolean(prefs::kBrowserShowProfilePickerOnStartup, shows);
  }
}

void BEProfiles::GatherStatistics(
    int counting,
    void (^update)(NSDictionary<NSString*, NSNumber*>*),
    Profile* profile) {
  if (!profile || counting != counting_) {
    return;
  }
  counting_keep_alive_ = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kProfileStatistics);
  if (!counting_keep_alive_) {
    return;
  }
  ProfileStatistics* statistics =
      ProfileStatisticsFactory::GetForProfile(profile);
  if (!statistics) {
    return;
  }
  // Called again as each count arrives, with all those so far.
  statistics->GatherStatistics(
      base::BindRepeating(&BEProfiles::StatisticsReceived,
                          weak_factory_.GetWeakPtr(), counting, update));
}

void BEProfiles::StatisticsReceived(
    int counting,
    void (^update)(NSDictionary<NSString*, NSNumber*>*),
    profiles::ProfileCategoryStats stats) {
  if (counting != counting_) {
    return;
  }
  // "BrowsingHistory", "Passwords", "Bookmarks", "Autofill"
  // (profiles::kProfileStatisticsCategories).
  NSMutableDictionary<NSString*, NSNumber*>* counts =
      [NSMutableDictionary dictionary];
  for (const profiles::ProfileCategoryStat& stat : stats) {
    counts[base::SysUTF8ToNSString(stat.category)] = @(stat.count);
  }
  update(counts);
}

// MARK: Observing

void BEProfiles::OnProfileAdded(const base::FilePath& profile_path) {
  NotifyChange();
}

void BEProfiles::OnProfileWasRemoved(const base::FilePath& profile_path,
                                     const std::u16string& profile_name) {
  NotifyChange();
}

void BEProfiles::OnProfileNameChanged(const base::FilePath& profile_path,
                                      const std::u16string& old_profile_name) {
  NotifyChange();
}

void BEProfiles::OnProfileAvatarChanged(const base::FilePath& profile_path) {
  NotifyChange();
}

void BEProfiles::OnProfileHighResAvatarLoaded(
    const base::FilePath& profile_path) {
  NotifyChange();
}

void BEProfiles::OnProfileIsOmittedChanged(const base::FilePath& profile_path) {
  NotifyChange();
}

void BEProfiles::OnProfileThemeColorsChanged(
    const base::FilePath& profile_path) {
  NotifyChange();
}

void BEProfiles::OnProfileManagerDestroying() {
  // The engine outlives it.
  counting_keep_alive_.reset();
  ++counting_;
  observation_.Reset();
  manager_observation_.Reset();
}

void BEProfiles::NotifyChange() {
  if (change_pending_) {
    return;
  }
  change_pending_ = true;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(&BEProfiles::SendChange, weak_factory_.GetWeakPtr()));
}

void BEProfiles::SendChange() {
  change_pending_ = false;
  [GetEngineDelegate() engineDidChangeProfiles:GetEngine()];
}

}  // namespace browser_engine
