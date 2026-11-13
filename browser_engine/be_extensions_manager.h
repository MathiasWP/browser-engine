// The app's own extensions page (BEWindowExtensionsManager): what Chrome's
// chrome://extensions and chrome://extensions/shortcuts show and do, for one
// window's profile (its everyday profile for a private window). The list comes
// from Chrome's own ExtensionInfoGenerator, which builds that page's data;
// actions make the calls the page's developerPrivate and management functions
// make, without the page's WebUI and Views dialogs (the app asks first).

#ifndef BROWSER_ENGINE_BE_EXTENSIONS_MANAGER_H_
#define BROWSER_ENGINE_BE_EXTENSIONS_MANAGER_H_

#import <Foundation/Foundation.h>

#include <memory>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#import "browser_engine/public/BEEngineOptional.h"

class BrowserWindowInterface;
class Profile;

namespace extensions {
class Extension;
class ExtensionInfoGenerator;
namespace api::developer_private {
struct ExtensionInfo;
}  // namespace api::developer_private
}  // namespace extensions

namespace browser_engine {

// One per window, made when the app first asks, destroyed with the window
// (before its profile). Completions still outstanding then never run.
class BEExtensionsManager {
 public:
  // `profile` is the window's; a private window's original profile is used,
  // as Chrome offers its extensions page only there. `changed` runs, at most
  // once per task and never from inside Chrome's notifications, whenever the
  // list should be read again.
  BEExtensionsManager(Profile* profile, base::RepeatingClosure changed);
  BEExtensionsManager(const BEExtensionsManager&) = delete;
  BEExtensionsManager& operator=(const BEExtensionsManager&) = delete;
  ~BEExtensionsManager();

  // The list as last made, by name; empty until the first one arrives. A read
  // of a list that misses a change makes a new one, which `changed` announces.
  NSArray<id<BEExtension>>* Extensions();
  bool DeveloperMode() const;
  bool CanChangeDeveloperMode() const;

  void SetDeveloperMode(bool on);
  void SetEnabled(const std::string& id, bool enabled);
  bool Remove(const std::string& id);
  void SetIncognitoAllowed(const std::string& id, bool allowed);
  void SetFileAccessAllowed(const std::string& id, bool allowed);
  void SetSiteAccess(const std::string& id, BEExtensionSiteAccess access);
  bool SetSiteAllowed(const std::string& id,
                      const std::string& site,
                      bool allowed);
  void SetPinned(const std::string& id, bool pinned);
  // In a tab of `browser`, the window's (see the .mm for private windows).
  void OpenOptions(const std::string& id, BrowserWindowInterface* browser);
  bool SetShortcut(const std::string& id,
                   const std::string& command,
                   const std::string& keys);
  void SetCommandGlobal(const std::string& id,
                        const std::string& command,
                        bool global);
  void SetShortcutsSuspended(bool suspended);

  // Developer mode. Each completion runs once, on a later task.
  void LoadUnpacked(const base::FilePath& path,
                    void (^completion)(NSString* identifier, NSString* error));
  void Reload(const std::string& id, void (^completion)(NSString* error));
  void UpdateAll(void (^completion)(void));
  void Inspect(id<BEExtensionView> view, const std::string& id);
  void SetCollectsErrors(const std::string& id, bool collects);
  void ClearErrors(const std::string& id);

 private:
  class Observers;

  // An unpacked extension being reloaded, until it loads again or fails to.
  struct PendingReload {
    base::FilePath path;
    void (^completion)(NSString* error);
  };

  // Something the list shows may have changed: from Chrome's notifications,
  // and after our own actions whose effect Chrome doesn't announce.
  void ListChanged();
  // On a later task after ListChanged(), once however many came.
  void Update();
  void Generate();
  void OnGenerated(
      std::vector<extensions::api::developer_private::ExtensionInfo> infos);
  void Tell();

  // An unpacked extension at `path` loaded (empty `error`) or failed to.
  void FinishReloads(const base::FilePath& path, const std::u16string& error);
  void OnUnpackedLoaded(void (^completion)(NSString*, NSString*),
                        const extensions::Extension* extension,
                        const base::FilePath& path,
                        const std::u16string& error);
  // Runs `block` on a later task, unless this is destroyed first.
  void RunLater(void (^block)(void));

  // Any extension Chrome has, on, off, crashed or blocked; null for an id it
  // doesn't. Never kept across a call that may reload it.
  const extensions::Extension* Find(const std::string& id) const;

  const raw_ptr<Profile> profile_;
  base::RepeatingClosure changed_;

  // The list as last made; nil until the first one arrives.
  NSArray<id<BEExtension>>* __strong list_;
  // Something changed since the list (or the one being made) was begun.
  bool stale_ = true;
  // The app read the list since it was last told: it's showing it, so a
  // change makes a new list before telling.
  bool read_since_told_ = false;
  bool update_pending_ = false;
  // The generation under way, null between them (one at a time: a generator
  // makes only one list).
  std::unique_ptr<extensions::ExtensionInfoGenerator> generator_;

  std::vector<PendingReload> pending_reloads_;
  // Whether we suspended the profile's extension shortcuts, to undo it if the
  // window closes first.
  bool shortcuts_suspended_ = false;

  // After everything they report to.
  std::unique_ptr<Observers> observers_;
  base::WeakPtrFactory<BEExtensionsManager> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_EXTENSIONS_MANAGER_H_
