#import "browser_engine/be_preferences.h"

#import <CoreFoundation/CoreFoundation.h>

#include <cmath>
#include <limits>
#include <optional>
#include <string>
#include <utility>

#include "base/apple/foundation_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/zoom/chrome_zoom_level_prefs.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"

namespace browser_engine {

namespace {

// The header names no domain or codes; the app shows localizedDescription.
NSString* const kErrorDomain = @"BEPreferencesErrorDomain";

enum ErrorCode : NSInteger {
  kUnknownPreference = 1,
  kNotUserModifiable,
  kWrongType,
};

// The PrefService that has a preference named `name`: the everyday profile's,
// else Local State's. Null if neither has one, or once Chromium has quit.
PrefService* PrefServiceFor(const std::string& name) {
  if (!g_browser_process) {
    return nullptr;
  }
  // The profile -[BEEngine dataFolder] is (Local State's last used profile).
  if (Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded()) {
    if (profile->GetPrefs()->FindPreference(name)) {
      return profile->GetPrefs();
    }
  }
  PrefService* local_state = g_browser_process->local_state();
  return local_state && local_state->FindPreference(name) ? local_state
                                                          : nullptr;
}

// After a preference is written: those Chrome puts into effect only as its
// own settings page sets them, not as the preference changes, put into effect
// the same way. The default page zoom (Settings › Appearance › Page zoom) goes
// through ChromeZoomLevelPrefs, which tells the profile's zoom map.
void ApplyPreference(const std::string& name,
                     PrefService* prefs,
                     bool cleared) {
  if (name != prefs::kPartitionDefaultZoomLevel) {
    return;
  }
  Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
  ChromeZoomLevelPrefs* zoom = profile && profile->GetPrefs() == prefs
                                   ? profile->GetZoomLevelPrefs()
                                   : nullptr;
  if (!zoom) {
    return;
  }
  zoom->SetDefaultZoomLevelPref(zoom->GetDefaultZoomLevelPref());
  // Setting it writes it; put back to its default, it stays unchanged.
  if (cleared) {
    prefs->ClearPref(name);
  }
}

const PrefService::Preference* FindPreference(NSString* name) {
  const std::string pref_name = base::SysNSStringToUTF8(name);
  PrefService* prefs = PrefServiceFor(pref_name);
  return prefs ? prefs->FindPreference(pref_name) : nullptr;
}

// `value` in Foundation: @YES and @NO (kCFBooleanTrue/False), other NSNumbers
// (integer or double), NSString, NSArray and NSDictionary.
id ObjectFromValue(const base::Value& value) {
  switch (value.type()) {
    case base::Value::Type::BOOLEAN:
      return value.GetBool() ? @YES : @NO;
    case base::Value::Type::INTEGER:
      return @(value.GetInt());
    case base::Value::Type::DOUBLE:
      return @(value.GetDouble());
    case base::Value::Type::STRING:
      return base::SysUTF8ToNSString(value.GetString());
    case base::Value::Type::LIST: {
      NSMutableArray* array =
          [NSMutableArray arrayWithCapacity:value.GetList().size()];
      for (const base::Value& item : value.GetList()) {
        [array addObject:ObjectFromValue(item)];
      }
      return array;
    }
    case base::Value::Type::DICT: {
      NSMutableDictionary* dictionary =
          [NSMutableDictionary dictionaryWithCapacity:value.GetDict().size()];
      for (const auto [key, item] : value.GetDict()) {
        dictionary[base::SysUTF8ToNSString(key)] = ObjectFromValue(item);
      }
      return dictionary;
    }
    case base::Value::Type::NONE:
    case base::Value::Type::BINARY:
      break;
  }
  // Preferences are JSON: NONE is a null inside a list or dictionary, and
  // there's no BINARY.
  return NSNull.null;
}

// The reverse of ObjectFromValue(), or nullopt for what a base::Value can't
// hold: other classes, keys that aren't strings, whole numbers beyond 32 bits,
// NaN and infinities.
std::optional<base::Value> ValueFromObject(id object) {
  if ([object isKindOfClass:NSNumber.class]) {
    NSNumber* number = object;
    const CFTypeID type = CFGetTypeID((__bridge CFTypeRef)number);
    if (type == CFBooleanGetTypeID()) {
      return base::Value(static_cast<bool>(number.boolValue));
    }
    // An NSDecimalNumber isn't a CFNumber; it's taken as a double too.
    if (type != CFNumberGetTypeID() ||
        CFNumberIsFloatType((__bridge CFNumberRef)number)) {
      const double real = number.doubleValue;
      if (!std::isfinite(real)) {
        return std::nullopt;
      }
      return base::Value(real);
    }
    if ([number compare:@(std::numeric_limits<int>::max())] ==
            NSOrderedDescending ||
        [number compare:@(std::numeric_limits<int>::min())] ==
            NSOrderedAscending) {
      return std::nullopt;
    }
    return base::Value(number.intValue);
  }
  if ([object isKindOfClass:NSString.class]) {
    return base::Value(base::SysNSStringToUTF8(object));
  }
  if ([object isKindOfClass:NSArray.class]) {
    NSArray* array = object;
    base::ListValue list;
    for (id item in array) {
      std::optional<base::Value> item_value = ValueFromObject(item);
      if (!item_value) {
        return std::nullopt;
      }
      list.Append(std::move(*item_value));
    }
    return base::Value(std::move(list));
  }
  if ([object isKindOfClass:NSDictionary.class]) {
    NSDictionary* dictionary = object;
    base::DictValue dict;
    for (id key in dictionary) {
      NSString* string_key = base::apple::ObjCCast<NSString>(key);
      std::optional<base::Value> item_value = ValueFromObject(dictionary[key]);
      if (!string_key || !item_value) {
        return std::nullopt;
      }
      dict.Set(base::SysNSStringToUTF8(string_key), std::move(*item_value));
    }
    return base::Value(std::move(dict));
  }
  if ([object isKindOfClass:NSNull.class]) {
    return base::Value();
  }
  return std::nullopt;
}

// For error messages.
NSString* TypeName(base::Value::Type type) {
  switch (type) {
    case base::Value::Type::NONE:
      return @"null";
    case base::Value::Type::BOOLEAN:
      return @"a boolean";
    case base::Value::Type::INTEGER:
      return @"a whole number";
    case base::Value::Type::DOUBLE:
      return @"a floating-point number";
    case base::Value::Type::STRING:
      return @"a string";
    case base::Value::Type::BINARY:
      return @"binary data";
    case base::Value::Type::DICT:
      return @"a dictionary";
    case base::Value::Type::LIST:
      return @"a list";
  }
  return @"a value";
}

// Fills in `error`, if asked for, and returns NO.
BOOL Refuse(NSError** error, ErrorCode code, NSString* reason) {
  if (error) {
    *error = [NSError errorWithDomain:kErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey : reason}];
  }
  return NO;
}

}  // namespace

}  // namespace browser_engine

@implementation BEChromiumPreferences

- (id)valueForPreference:(NSString*)name {
  const PrefService::Preference* pref = browser_engine::FindPreference(name);
  const base::Value* value = pref ? pref->GetValue() : nullptr;
  return value ? browser_engine::ObjectFromValue(*value) : nil;
}

- (BOOL)isPreferenceModified:(NSString*)name {
  // A value in the user's own store, even one policy overrides.
  // IsDefaultValue() would count policy, extensions and the command line too.
  const PrefService::Preference* pref = browser_engine::FindPreference(name);
  return pref && pref->HasUserSetting();
}

- (BOOL)canSetPreference:(NSString*)name {
  // Not when policy, a supervisor, an extension or the command line sets it.
  const PrefService::Preference* pref = browser_engine::FindPreference(name);
  return pref && pref->IsUserModifiable();
}

- (BOOL)setValue:(id)value
    forPreference:(NSString*)name
            error:(NSError**)error {
  const std::string pref_name = base::SysNSStringToUTF8(name);
  PrefService* prefs = browser_engine::PrefServiceFor(pref_name);
  const PrefService::Preference* pref =
      prefs ? prefs->FindPreference(pref_name) : nullptr;
  if (!pref) {
    return browser_engine::Refuse(
        error, browser_engine::kUnknownPreference,
        [NSString stringWithFormat:@"There's no preference named “%@”.", name]);
  }
  if (!pref->IsUserModifiable()) {
    return browser_engine::Refuse(
        error, browser_engine::kNotUserModifiable,
        [NSString stringWithFormat:@"“%@” is set by policy, an extension or "
                                   @"the command line, so it can't be changed.",
                                   name]);
  }
  if (!value) {
    prefs->ClearPref(pref_name);
    browser_engine::ApplyPreference(pref_name, prefs, /*cleared=*/true);
    return YES;
  }

  std::optional<base::Value> new_value = browser_engine::ValueFromObject(value);
  if (!new_value) {
    return browser_engine::Refuse(
        error, browser_engine::kWrongType,
        [NSString stringWithFormat:
                      @"“%@” can't hold that value. Preferences hold booleans, "
                      @"numbers (whole ones within 32 bits), strings, and "
                      @"arrays and dictionaries (with string keys) of these.",
                      name]);
  }
  // A whole number does for a floating-point preference.
  if (new_value->is_int() && pref->GetType() == base::Value::Type::DOUBLE) {
    new_value = base::Value(new_value->GetDouble());
  }
  // PrefService::Set() takes only the registered type (NOTREACHED otherwise).
  if (new_value->type() != pref->GetType()) {
    return browser_engine::Refuse(
        error, browser_engine::kWrongType,
        [NSString
            stringWithFormat:@"“%@” holds %@, not %@.", name,
                             browser_engine::TypeName(pref->GetType()),
                             browser_engine::TypeName(new_value->type())]);
  }
  prefs->Set(pref_name, *new_value);
  browser_engine::ApplyPreference(pref_name, prefs, /*cleared=*/false);
  return YES;
}

@end
