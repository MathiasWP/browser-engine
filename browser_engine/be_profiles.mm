#import "browser_engine/be_profiles.h"

#import <AppKit/AppKit.h>

#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_engine.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "ui/gfx/image/image.h"

// A profile as the app reads it: a copy, made when the list was read.
@interface BEChromiumProfile : NSObject <BEProfile>
- (instancetype)initWithEntry:(const ProfileAttributesEntry&)entry
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumProfile

@synthesize identifier = _identifier;
@synthesize name = _name;
@synthesize avatar = _avatar;

- (instancetype)initWithEntry:(const ProfileAttributesEntry&)entry {
  if ((self = [super init])) {
    _identifier = base::SysUTF8ToNSString(entry.GetPath().BaseName().value());
    _name = base::SysUTF16ToNSString(entry.GetName());
    // The bundled avatars and Chrome's placeholder: the high-resolution ones
    // download from Google, which ungoogled-chromium doesn't reach.
    const gfx::Image avatar =
        entry.GetAvatarIcon(/*size_for_placeholder_avatar=*/64,
                            /*use_high_res_file=*/false);
    _avatar = avatar.IsEmpty() ? nil : avatar.ToNSImage();
  }
  return self;
}

@end

namespace browser_engine {

namespace {

ProfileAttributesStorage* Storage() {
  ProfileManager* manager =
      g_browser_process ? g_browser_process->profile_manager() : nullptr;
  return manager ? &manager->GetProfileAttributesStorage() : nullptr;
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
  NSMutableArray<id<BEProfile>>* items = [NSMutableArray array];
  for (ProfileAttributesEntry* entry :
       storage->GetAllProfilesAttributesSortedByNameWithCheck()) {
    if (!entry->IsOmitted()) {
      [items addObject:[[BEChromiumProfile alloc] initWithEntry:*entry]];
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

void BEProfiles::OnProfileManagerDestroying() {
  // The engine outlives it.
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
