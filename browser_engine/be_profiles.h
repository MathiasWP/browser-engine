// Chrome's profiles to the app, as its profile menu lists them
// (ProfileAttributesStorage): for -[BEEngine profiles], with
// engineDidChangeProfiles: when one comes, goes, or changes its name or
// avatar.

#ifndef BROWSER_ENGINE_BE_PROFILES_H_
#define BROWSER_ENGINE_BE_PROFILES_H_

#import <Foundation/Foundation.h>

#include <string>

#include "base/files/file_path.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#import "browser_engine/public/BEEngine.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_attributes_storage_observer.h"
#include "chrome/browser/profiles/profile_manager_observer.h"

class ProfileManager;

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

  // ProfileManagerObserver (its OnProfileAdded is another one's):
  using ProfileManagerObserver::OnProfileAdded;
  void OnProfileManagerDestroying() override;

  // Tells the engine delegate, once per task.
  void NotifyChange();
  void SendChange();

  base::ScopedObservation<ProfileAttributesStorage,
                          ProfileAttributesStorageObserver>
      observation_{this};
  base::ScopedObservation<ProfileManager, ProfileManagerObserver>
      manager_observation_{this};
  bool change_pending_ = false;
  base::WeakPtrFactory<BEProfiles> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_PROFILES_H_
