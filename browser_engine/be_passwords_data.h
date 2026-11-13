// Chrome's password manager for the app's own passwords page
// (BEWindowPasswords), for one window's profile (its everyday profile for a
// private window): the saved passwords and never-saved sites as Chrome's page
// lists them (SavedPasswordsPresenter), revealing and copying after macOS asks
// who it is, adding, editing and removing, CSV export and import, and the
// password check without Google (weak and reused passwords). Chrome's own page
// does the same through PasswordsPrivateDelegateImpl, whose types are its
// extension API's and whose import and export want a tab.
//
// Kept apart from be_passwords.mm, which is the offer to save a password a
// page just signed in with.

#ifndef BROWSER_ENGINE_BE_PASSWORDS_DATA_H_
#define BROWSER_ENGINE_BE_PASSWORDS_DATA_H_

#import <Foundation/Foundation.h>

#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/time/time.h"
#import "browser_engine/public/BEEngineOptional.h"
#include "components/device_reauth/device_reauth_metrics_util.h"
#include "components/password_manager/core/browser/ui/credential_ui_entry.h"
#include "components/password_manager/core/browser/ui/saved_passwords_presenter.h"

class Profile;

namespace base {
class FilePath;
}  // namespace base

namespace device_reauth {
class DeviceAuthenticator;
}  // namespace device_reauth

namespace password_manager {
class InsecureCredentialsManager;
class PasswordImporter;
class PasswordManagerExporter;
struct ImportResults;
}  // namespace password_manager

namespace browser_engine {

// macOS asking who it is (Touch ID, or the account's password without it), as
// Chrome's settings ask before showing a password or a card's number: Chrome's
// DeviceAuthenticator for the profile. A success counts for Chrome's own
// prompts too, so one within `validity` of the last isn't asked again.
//
// One request at a time across all windows, as macOS shows one prompt: a new
// one cancels the one waiting, which is answered as refused. Used by the
// passwords and the payment cards (be_autofill_data.mm).
class BEAuthentication {
 public:
  BEAuthentication(Profile* profile, device_reauth::DeviceAuthSource source);
  BEAuthentication(const BEAuthentication&) = delete;
  BEAuthentication& operator=(const BEAuthentication&) = delete;
  // A request still waiting is cancelled, and its `done` never runs.
  ~BEAuthentication();

  // `done` runs on a later task with whether the user is who they say, unless
  // this is gone by then. `message` follows "Chromium is trying to".
  void Authenticate(base::TimeDelta validity,
                    const std::u16string& message,
                    base::OnceCallback<void(bool)> done);

 private:
  // Cancels the request waiting: its `done` gets false.
  void Cancel();
  void OnAuthenticated(base::OnceCallback<void(bool)> done, bool success);
  void Finish(base::OnceCallback<void(bool)> done, bool success);

  const raw_ptr<Profile> profile_;
  const device_reauth::DeviceAuthSource source_;
  // The request waiting, if any.
  std::unique_ptr<device_reauth::DeviceAuthenticator> authenticator_;
  base::WeakPtrFactory<BEAuthentication> weak_factory_{this};
};

// One per window, made when the app first asks, destroyed with the window
// (before its profile). Completions still to come then never run.
//
// The passwords load once, from the first use; until then the lists are empty
// and the rest waits (export, import and the check) or fails (add, edit).
// Writes reach the stores a moment later, and come back as `changed`.
class BEPasswordsData
    : public password_manager::SavedPasswordsPresenter::Observer {
 public:
  // `changed` runs when passwords or never-saved sites change, from whoever.
  BEPasswordsData(Profile* profile, base::RepeatingClosure changed);
  BEPasswordsData(const BEPasswordsData&) = delete;
  BEPasswordsData& operator=(const BEPasswordsData&) = delete;
  ~BEPasswordsData() override;

  // As they were at the last change.
  NSArray<id<BEPasswordGroup>>* PasswordGroups();
  NSArray<id<BENeverSavedSite>>* NeverSavedSites();

  void Reveal(int64_t identifier,
              void (^completion)(NSString* password, NSString* note));
  void Copy(int64_t identifier, void (^completion)(BOOL copied));
  bool Add(NSString* site,
           NSString* username,
           NSString* password,
           NSString* note);
  BEPasswordEditResult Edit(int64_t identifier,
                            NSString* username,
                            NSString* password,
                            NSString* note);
  // A saved password or a never-saved site.
  void Remove(int64_t identifier);
  void UndoRemoval();

  void Export(NSURL* file, void (^completion)(BOOL exported));
  void Import(NSURL* file, void (^completion)(id<BEPasswordImport>));
  void Replace(NSArray<NSNumber*>* rows,
               void (^completion)(id<BEPasswordImport>));
  void FinishImport(bool delete_file);

  void Check(void (^completion)(NSArray<NSNumber*>* weak,
                                NSArray<NSArray<NSNumber*>*>* reused));

 private:
  // A credential as the app knows it: its sort key (sites, username and the
  // like) and its password, as Chrome's IdGenerator keys its ids, so a
  // credential keeps its identifier across changes until its username or
  // password changes.
  using CredentialKey =
      std::pair<password_manager::CredentialSortKey, std::u16string>;

  // password_manager::SavedPasswordsPresenter::Observer:
  void OnSavedPasswordsChanged(
      const password_manager::PasswordStoreChangeList& changes) override;

  void OnLoaded();
  // Runs `task` now if the passwords have loaded, else once they have.
  void WhenLoaded(base::OnceClosure task);
  // Runs `task` on a later task, unless this is gone by then.
  void Later(base::OnceClosure task);
  void RunTask(base::OnceClosure task);

  // Lists the presenter's credentials afresh, with their identifiers.
  void Rebuild();
  int64_t IdentifierFor(const password_manager::CredentialUIEntry& credential,
                        std::map<CredentialKey, int64_t>& identifiers);
  // The credential listed as `identifier`, or null.
  const password_manager::CredentialUIEntry* Find(int64_t identifier) const;

  void OnRevealAuthenticated(int64_t identifier,
                             void (^completion)(NSString*, NSString*),
                             bool authenticated);
  void OnCopyAuthenticated(int64_t identifier,
                           void (^completion)(BOOL),
                           bool authenticated);

  void OnExportAuthenticated(const base::FilePath& path,
                             void (^completion)(BOOL),
                             bool authenticated);
  void StartExport(const base::FilePath& path, void (^completion)(BOOL));
  void OnExported(void (^completion)(BOOL));

  void StartImport(const base::FilePath& path,
                   void (^completion)(id<BEPasswordImport>));
  void OnReplaceAuthenticated(std::vector<int> rows,
                              void (^completion)(id<BEPasswordImport>),
                              bool authenticated);
  void OnImported(void (^completion)(id<BEPasswordImport>),
                  const password_manager::ImportResults& results);
  // Whether an import is under way or waits for the app.
  bool IsImporting() const;

  void StartCheck(void (^completion)(NSArray<NSNumber*>*,
                                     NSArray<NSArray<NSNumber*>*>*));
  void OnChecked(void (^completion)(NSArray<NSNumber*>*,
                                    NSArray<NSArray<NSNumber*>*>*));

  const raw_ptr<Profile> profile_;
  base::RepeatingClosure changed_;

  // Null if the profile has no password store or affiliation service (the
  // presenter can't do without either): then nothing is listed.
  std::unique_ptr<password_manager::SavedPasswordsPresenter> presenter_;
  // The rest use the presenter, so go first.
  std::unique_ptr<password_manager::InsecureCredentialsManager> insecure_;
  base::ScopedObservation<password_manager::SavedPasswordsPresenter,
                          password_manager::SavedPasswordsPresenter::Observer>
      presenter_observation_{this};
  std::unique_ptr<password_manager::PasswordManagerExporter> exporter_;
  std::unique_ptr<password_manager::PasswordImporter> importer_;

  bool loaded_ = false;
  std::vector<base::OnceClosure> when_loaded_;

  // What the app was last given, and the credentials behind its identifiers
  // (saved passwords in the order listed, then never-saved sites).
  NSArray<id<BEPasswordGroup>>* __strong groups_ = nil;
  NSArray<id<BENeverSavedSite>>* __strong never_saved_ = nil;
  std::map<CredentialKey, int64_t> identifiers_;
  std::map<int64_t, password_manager::CredentialUIEntry> credentials_;
  std::vector<int64_t> listed_;
  int64_t next_identifier_ = 1;

  // From the app asking to export until the file is written or it fails.
  bool exporting_ = false;
  // From the app asking to import until the passwords have loaded.
  bool import_starting_ = false;
  // While the importer waits for conflicts to be resolved: what the app was
  // told, again if it refuses to be asked who it is, and how many there are.
  id<BEPasswordImport> __strong conflicts_ = nil;
  size_t conflict_count_ = 0;

  BEAuthentication authentication_;
  base::WeakPtrFactory<BEPasswordsData> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_PASSWORDS_DATA_H_
