// Chrome's profiles to the app, as its profile menu lists them
// (ProfileAttributesStorage): for -[BEEngine profiles], with
// engineDidChangeProfiles: when one comes, goes, or changes its name, avatar
// or colour. And what the app's own profile picker and editor do with them, in
// place of chrome://profile-picker and chrome://settings/manageProfile
// (BEEngineProfiles, be_engine_profiles.mm), with the calls those pages make.

#ifndef BROWSER_ENGINE_BE_PROFILES_H_
#define BROWSER_ENGINE_BE_PROFILES_H_

#import <AppKit/AppKit.h>

#include <memory>
#include <optional>
#include <string>

#include "base/files/file_path.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#import "browser_engine/public/BEEngine.h"
#import "browser_engine/public/BEEngineOptional.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_attributes_storage_observer.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/profiles/profile_statistics_common.h"

class Profile;
class ProfileManager;
class ScopedProfileKeepAlive;

namespace browser_engine {

// One for the process, in the engine, watching from when Chromium has
// started until the ProfileManager, which holds the list, goes.
class BEProfiles : public ProfileAttributesStorageObserver,
                   public ProfileManagerObserver {
 public:
  BEProfiles();
  BEProfiles(const BEProfiles&) = delete;
  BEProfiles& operator=(const BEProfiles&) = delete;
  ~BEProfiles() override;

  // Watches the profile list, once there's a ProfileManager.
  void Start();

  // The profiles Chrome's menu shows, in its order.
  NSArray<id<BEProfile>>* items() const;

  // The profile folder for `identifier` (a profile's folder name), or empty if
  // there's no such profile.
  base::FilePath PathForIdentifier(NSString* identifier) const;

  // MARK: The app's picker and editor (BEEngineProfiles)

  // Chrome's placeholder avatar, drawn from the profile's colours.
  static NSInteger GenericAvatarIndex();
  // The generic avatar first, then the ones Chrome offers (its modern ones).
  NSArray<id<BEProfileAvatarChoice>>* AvatarChoices() const;
  // Customize Chrome's colours; the same objects every time.
  NSArray<id<BEProfileColorChoice>>* ColorChoices();
  NSImage* Avatar(NSString* identifier, CGFloat points) const;

  // A local profile, as the picker's "Continue without an account" makes
  // one, then `completion` with its identifier (nil if it wasn't made).
  void Create(NSString* name,
              NSInteger avatar_index,
              NSColor* color,
              bool open_window,
              void (^completion)(NSString*));
  bool Rename(NSString* identifier, NSString* name);
  void SetAvatarIndex(NSString* identifier, NSInteger index);
  void SetColor(NSString* identifier, NSColor* color);

  // The counts the picker's delete dialog shows, until stopped; one count at
  // a time.
  void CountData(NSString* identifier,
                 void (^update)(NSDictionary<NSString*, NSNumber*>*));
  void StopCountingData();
  void Delete(NSString* identifier);

  // Opens the profile chosen in the app's picker.
  void Pick(NSString* identifier);
  // `from` and `to` index items().
  void Move(NSInteger from, NSInteger to);

  bool CanCreateProfiles() const;
  bool GuestModeEnabled() const;
  void OpenGuestWindow();
  bool ShowsPickerOnStartup() const;
  void SetShowsPickerOnStartup(bool shows);

 private:
  // ProfileAttributesStorageObserver:
  void OnProfileAdded(const base::FilePath& profile_path) override;
  void OnProfileWasRemoved(const base::FilePath& profile_path,
                           const std::u16string& profile_name) override;
  void OnProfileNameChanged(const base::FilePath& profile_path,
                            const std::u16string& old_profile_name) override;
  void OnProfileAvatarChanged(const base::FilePath& profile_path) override;
  void OnProfileHighResAvatarLoaded(
      const base::FilePath& profile_path) override;
  void OnProfileIsOmittedChanged(const base::FilePath& profile_path) override;
  void OnProfileThemeColorsChanged(const base::FilePath& profile_path) override;

  // ProfileManagerObserver (its OnProfileAdded is another one's):
  using ProfileManagerObserver::OnProfileAdded;
  void OnProfileManagerDestroying() override;

  // Tells the engine delegate, once per task.
  void NotifyChange();
  void SendChange();

  // CountData()'s steps, for the counting `counting_` still names.
  void GatherStatistics(int counting,
                        void (^update)(NSDictionary<NSString*, NSNumber*>*),
                        Profile* profile);
  void StatisticsReceived(int counting,
                          void (^update)(NSDictionary<NSString*, NSNumber*>*),
                          profiles::ProfileCategoryStats stats);

  base::ScopedObservation<ProfileAttributesStorage,
                          ProfileAttributesStorageObserver>
      observation_{this};
  base::ScopedObservation<ProfileManager, ProfileManagerObserver>
      manager_observation_{this};
  bool change_pending_ = false;
  // ColorChoices(), made once: SetColor() knows a choice by its object.
  NSArray<id<BEProfileColorChoice>>* color_choices_;
  // The counting under way: a new one, or stopping, makes the old one's
  // answers stale.
  int counting_ = 0;
  // Keeps the profile being counted loaded, as the picker does.
  std::unique_ptr<ScopedProfileKeepAlive> counting_keep_alive_;
  base::WeakPtrFactory<BEProfiles> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_PROFILES_H_
