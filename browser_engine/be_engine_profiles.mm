// BEEngineProfiles: the app's own profile picker and editor, through the
// engine's profile list (be_profiles.h), which does what Chrome's picker and
// manage-profile pages do. Before Chromium has started there's no list: the
// properties are empty and the calls do nothing.

#import "browser_engine/be_engine.h"

#import <AppKit/AppKit.h>

#import "browser_engine/be_profiles.h"

@implementation BEChromiumEngine (Profiles)

- (NSArray<id<BEProfileAvatarChoice>>*)profileAvatarChoices {
  browser_engine::BEProfiles* profiles = [self profilesModel];
  return profiles ? profiles->AvatarChoices() : @[];
}

- (NSArray<id<BEProfileColorChoice>>*)profileColorChoices {
  browser_engine::BEProfiles* profiles = [self profilesModel];
  return profiles ? profiles->ColorChoices() : @[];
}

- (NSInteger)genericAvatarIndex {
  return browser_engine::BEProfiles::GenericAvatarIndex();
}

- (NSImage*)avatarForProfile:(NSString*)identifier size:(CGFloat)points {
  browser_engine::BEProfiles* profiles = [self profilesModel];
  return profiles ? profiles->Avatar(identifier, points) : nil;
}

- (void)createProfileNamed:(NSString*)name
               avatarIndex:(NSInteger)avatarIndex
                     color:(NSColor*)color
                openWindow:(BOOL)openWindow
                completion:(void (^)(NSString* identifier))completion {
  browser_engine::BEProfiles* profiles = [self profilesModel];
  if (!profiles) {
    // Nothing was made, which the completion still hears, once.
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(nil);
    });
    return;
  }
  profiles->Create(name, avatarIndex, color, openWindow, completion);
}

- (BOOL)renameProfile:(NSString*)identifier to:(NSString*)name {
  browser_engine::BEProfiles* profiles = [self profilesModel];
  return profiles && profiles->Rename(identifier, name);
}

- (void)setAvatarIndex:(NSInteger)index forProfile:(NSString*)identifier {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->SetAvatarIndex(identifier, index);
  }
}

- (void)setColor:(NSColor*)color forProfile:(NSString*)identifier {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->SetColor(identifier, color);
  }
}

- (void)countDataOfProfile:(NSString*)identifier
                    update:
                        (void (^)(NSDictionary<NSString*, NSNumber*>* counts))
                            update {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->CountData(identifier, update);
  }
}

- (void)stopCountingProfileData {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->StopCountingData();
  }
}

- (void)deleteProfile:(NSString*)identifier {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->Delete(identifier);
  }
}

- (void)pickProfile:(NSString*)identifier {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->Pick(identifier);
  }
}

- (void)moveProfileAtIndex:(NSInteger)from toIndex:(NSInteger)to {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->Move(from, to);
  }
}

- (BOOL)canCreateProfiles {
  browser_engine::BEProfiles* profiles = [self profilesModel];
  return profiles && profiles->CanCreateProfiles();
}

- (BOOL)guestModeEnabled {
  browser_engine::BEProfiles* profiles = [self profilesModel];
  return profiles && profiles->GuestModeEnabled();
}

- (void)openGuestWindow {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->OpenGuestWindow();
  }
}

- (BOOL)showsProfilePickerOnStartup {
  browser_engine::BEProfiles* profiles = [self profilesModel];
  return profiles && profiles->ShowsPickerOnStartup();
}

- (void)setShowsProfilePickerOnStartup:(BOOL)shows {
  if (browser_engine::BEProfiles* profiles = [self profilesModel]) {
    profiles->SetShowsPickerOnStartup(shows);
  }
}

@end
