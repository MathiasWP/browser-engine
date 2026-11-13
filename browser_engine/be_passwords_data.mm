#import "browser_engine/be_passwords_data.h"

#include <set>
#include <utility>

#include "base/apple/foundation_util.h"
#include "base/barrier_closure.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/location.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_window.h"
#include "chrome/browser/affiliations/affiliation_service_factory.h"
#include "chrome/browser/device_reauth/chrome_device_authenticator_factory.h"
#include "chrome/browser/password_manager/factories/account_password_store_factory.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/grit/generated_resources.h"
#include "components/device_reauth/device_authenticator.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/password_manager/core/browser/export/export_progress_status.h"
#include "components/password_manager/core/browser/export/password_manager_exporter.h"
#include "components/password_manager/core/browser/import/import_results.h"
#include "components/password_manager/core/browser/import/password_importer.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_manager_util.h"
#include "components/password_manager/core/browser/password_ui_utils.h"
#include "components/password_manager/core/browser/ui/affiliated_group.h"
#include "components/password_manager/core/browser/ui/credential_utils.h"
#include "components/password_manager/core/browser/ui/insecure_credentials_manager.h"
#include "components/password_manager/core/common/password_manager_constants.h"
#include "components/url_formatter/elide_url.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/clipboard/clipboard.h"
#include "ui/base/clipboard/clipboard_buffer.h"
#include "ui/base/clipboard/clipboard_sequence_number_token.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/base/l10n/l10n_util.h"
#include "url/gurl.h"

using password_manager::CredentialUIEntry;
using password_manager::ImportEntry;
using password_manager::ImportResults;
using password_manager::PasswordImporter;

@interface BEChromiumSavedPassword : NSObject <BESavedPassword>
- (instancetype)initWithIdentifier:(int64_t)identifier
                          username:(NSString*)username
                             sites:(NSArray<NSString*>*)sites
                          siteURLs:(NSArray<NSURL*>*)siteURLs
                     federatedWith:(NSString*)federatedWith
                           hasNote:(BOOL)hasNote
                          lastUsed:(NSDate*)lastUsed NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumSavedPassword

@synthesize identifier = _identifier;
@synthesize username = _username;
@synthesize sites = _sites;
@synthesize siteURLs = _siteURLs;
@synthesize federatedWith = _federatedWith;
@synthesize hasNote = _hasNote;
@synthesize lastUsed = _lastUsed;

- (instancetype)initWithIdentifier:(int64_t)identifier
                          username:(NSString*)username
                             sites:(NSArray<NSString*>*)sites
                          siteURLs:(NSArray<NSURL*>*)siteURLs
                     federatedWith:(NSString*)federatedWith
                           hasNote:(BOOL)hasNote
                          lastUsed:(NSDate*)lastUsed {
  if ((self = [super init])) {
    _identifier = identifier;
    _username = [username copy];
    _sites = [sites copy];
    _siteURLs = [siteURLs copy];
    _federatedWith = [federatedWith copy];
    _hasNote = hasNote;
    _lastUsed = [lastUsed copy];
  }
  return self;
}

@end

@interface BEChromiumPasswordGroup : NSObject <BEPasswordGroup>
- (instancetype)initWithName:(NSString*)name
                         url:(NSURL*)url
                   passwords:(NSArray<id<BESavedPassword>>*)passwords
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumPasswordGroup

@synthesize name = _name;
@synthesize url = _url;
@synthesize passwords = _passwords;

- (instancetype)initWithName:(NSString*)name
                         url:(NSURL*)url
                   passwords:(NSArray<id<BESavedPassword>>*)passwords {
  if ((self = [super init])) {
    _name = [name copy];
    _url = [url copy];
    _passwords = [passwords copy];
  }
  return self;
}

@end

@interface BEChromiumNeverSavedSite : NSObject <BENeverSavedSite>
- (instancetype)initWithIdentifier:(int64_t)identifier
                              site:(NSString*)site
                               url:(NSURL*)url NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumNeverSavedSite

@synthesize identifier = _identifier;
@synthesize site = _site;
@synthesize url = _url;

- (instancetype)initWithIdentifier:(int64_t)identifier
                              site:(NSString*)site
                               url:(NSURL*)url {
  if ((self = [super init])) {
    _identifier = identifier;
    _site = [site copy];
    _url = [url copy];
  }
  return self;
}

@end

@interface BEChromiumPasswordImportRow : NSObject <BEPasswordImportRow>
- (instancetype)initWithIdentifier:(NSInteger)identifier
                              site:(NSString*)site
                          username:(NSString*)username
                           problem:(NSString*)problem NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumPasswordImportRow

@synthesize identifier = _identifier;
@synthesize site = _site;
@synthesize username = _username;
@synthesize problem = _problem;

- (instancetype)initWithIdentifier:(NSInteger)identifier
                              site:(NSString*)site
                          username:(NSString*)username
                           problem:(NSString*)problem {
  if ((self = [super init])) {
    _identifier = identifier;
    _site = [site copy];
    _username = [username copy];
    _problem = [problem copy];
  }
  return self;
}

@end

@interface BEChromiumPasswordImport : NSObject <BEPasswordImport>
- (instancetype)initWithStatus:(BEPasswordImportStatus)status
                 importedCount:(NSInteger)importedCount
                          rows:(NSArray<id<BEPasswordImportRow>>*)rows
                 canDeleteFile:(BOOL)canDeleteFile NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumPasswordImport

@synthesize status = _status;
@synthesize importedCount = _importedCount;
@synthesize rows = _rows;
@synthesize canDeleteFile = _canDeleteFile;

- (instancetype)initWithStatus:(BEPasswordImportStatus)status
                 importedCount:(NSInteger)importedCount
                          rows:(NSArray<id<BEPasswordImportRow>>*)rows
                 canDeleteFile:(BOOL)canDeleteFile {
  if ((self = [super init])) {
    _status = status;
    _importedCount = importedCount;
    _rows = [rows copy];
    _canDeleteFile = canDeleteFile;
  }
  return self;
}

@end

namespace browser_engine {

namespace {

// How long a copied password stays on the clipboard, as on Chrome's page
// (PasswordsPrivateDelegateImpl's kClipboardClearDelay).
constexpr base::TimeDelta kClipboardClearDelay = base::Seconds(120);

// The one asking now, of all windows'.
BEAuthentication* g_asking = nullptr;

// An NSURL for the app, which wants one: about:blank for the rare address
// NSURL can't hold.
NSURL* ToNSURL(const GURL& url) {
  NSURL* converted = url.is_valid() ? net::NSURLWithGURL(url) : nil;
  return converted ?: [NSURL URLWithString:@"about:blank"];
}

BEChromiumSavedPassword* SavedPassword(int64_t identifier,
                                       const CredentialUIEntry& credential) {
  // The sites as Chrome's page lists them ("Sites"), with their links.
  NSMutableArray<NSString*>* sites = [NSMutableArray array];
  NSMutableArray<NSURL*>* urls = [NSMutableArray array];
  for (const CredentialUIEntry::DomainInfo& domain :
       credential.GetAffiliatedDomains()) {
    [sites addObject:base::SysUTF8ToNSString(domain.name)];
    [urls addObject:ToNSURL(domain.url)];
  }
  // CreatePasswordUiEntryFromCredentialUiEntry()'s federation_text.
  NSString* federated_with = nil;
  if (credential.federation_origin.IsValid()) {
    federated_with =
        base::SysUTF16ToNSString(url_formatter::FormatUrlForSecurityDisplay(
            credential.federation_origin.GetURL(),
            url_formatter::SchemeDisplay::OMIT_CRYPTOGRAPHIC));
  }
  return [[BEChromiumSavedPassword alloc]
      initWithIdentifier:identifier
                username:base::SysUTF16ToNSString(credential.username)
                   sites:sites
                siteURLs:urls
           federatedWith:federated_with
                 hasNote:!credential.note.empty()
                lastUsed:credential.last_used_time.is_null()
                             ? nil
                             : credential.last_used_time.ToNSDate()];
}

BEPasswordImportStatus ImportStatus(ImportResults::Status status) {
  switch (status) {
    case ImportResults::SUCCESS:
      return BEPasswordImportStatusImported;
    case ImportResults::CONFLICTS:
      return BEPasswordImportStatusConflicts;
    case ImportResults::IO_ERROR:
    case ImportResults::BAD_FORMAT:
      return BEPasswordImportStatusUnreadable;
    case ImportResults::MAX_FILE_SIZE:
    case ImportResults::NUM_PASSWORDS_EXCEEDED:
      return BEPasswordImportStatusTooLarge;
    case ImportResults::IMPORT_ALREADY_ACTIVE:
      return BEPasswordImportStatusBusy;
    case ImportResults::NONE:
    case ImportResults::UNKNOWN_ERROR:
    case ImportResults::DISMISSED:
      return BEPasswordImportStatusFailed;
  }
  return BEPasswordImportStatusFailed;
}

// Why a row didn't come in, in the words of Chrome's import dialog.
NSString* ImportProblem(ImportEntry::Status status) {
  int message = IDS_PASSWORD_MANAGER_UI_IMPORT_ERROR_UNKNOWN;
  switch (status) {
    case ImportEntry::MISSING_PASSWORD:
      message = IDS_PASSWORD_MANAGER_UI_IMPORT_MISSING_PASSWORD;
      break;
    case ImportEntry::MISSING_URL:
      message = IDS_PASSWORD_MANAGER_UI_IMPORT_MISSING_URL;
      break;
    case ImportEntry::INVALID_URL:
      message = IDS_PASSWORD_MANAGER_UI_IMPORT_INVALID_URL;
      break;
    case ImportEntry::LONG_URL:
      message = IDS_PASSWORD_MANAGER_UI_IMPORT_LONG_URL;
      break;
    case ImportEntry::LONG_PASSWORD:
      message = IDS_PASSWORD_MANAGER_UI_IMPORT_LONG_PASSWORD;
      break;
    case ImportEntry::LONG_USERNAME:
      message = IDS_PASSWORD_MANAGER_UI_IMPORT_LONG_USERNAME;
      break;
    case ImportEntry::LONG_NOTE:
    case ImportEntry::LONG_CONCATENATED_NOTE:
      message = IDS_PASSWORD_MANAGER_UI_IMPORT_LONG_NOTE;
      break;
    // Only the profile store is imported into; its message has no account
    // to name.
    case ImportEntry::CONFLICT_PROFILE:
    case ImportEntry::CONFLICT_ACCOUNT:
      message = IDS_PASSWORD_MANAGER_UI_IMPORT_CONFLICT_DEVICE;
      break;
    // A row the parser couldn't read.
    case ImportEntry::NONE:
    case ImportEntry::UNKNOWN_ERROR:
    case ImportEntry::VALID:
      break;
  }
  return base::SysUTF16ToNSString(l10n_util::GetStringUTF16(message));
}

id<BEPasswordImport> MakeImport(const ImportResults& results,
                                bool can_delete_file) {
  // With conflicts, the rows are the conflicts, identified as
  // ContinueImport() wants them; otherwise the rows that didn't come in.
  const bool conflicts = results.status == ImportResults::CONFLICTS;
  NSMutableArray<id<BEPasswordImportRow>>* rows = [NSMutableArray array];
  NSInteger index = 0;
  for (const ImportEntry& entry : results.displayed_entries) {
    [rows
        addObject:[[BEChromiumPasswordImportRow alloc]
                      initWithIdentifier:conflicts ? entry.id : index
                                    site:base::SysUTF8ToNSString(entry.url)
                                username:base::SysUTF8ToNSString(entry.username)
                                 problem:conflicts
                                             ? @""
                                             : ImportProblem(entry.status)]];
    ++index;
  }
  return [[BEChromiumPasswordImport alloc]
      initWithStatus:ImportStatus(results.status)
       importedCount:static_cast<NSInteger>(results.number_imported)
                rows:rows
       canDeleteFile:can_delete_file];
}

id<BEPasswordImport> MakeImport(BEPasswordImportStatus status) {
  return [[BEChromiumPasswordImport alloc] initWithStatus:status
                                            importedCount:0
                                                     rows:@[]
                                            canDeleteFile:NO];
}

// PasswordsPrivateDelegateImpl::ClearClipboard(): unless something else was
// copied since.
void ClearClipboardIfUnchanged(ui::ClipboardSequenceNumberToken copied) {
  ui::Clipboard* clipboard = ui::Clipboard::GetForCurrentThread();
  if (clipboard->GetSequenceNumber(ui::ClipboardBuffer::kCopyPaste) == copied) {
    clipboard->Clear(ui::ClipboardBuffer::kCopyPaste);
  }
}

}  // namespace

// MARK: BEAuthentication

BEAuthentication::BEAuthentication(Profile* profile,
                                   device_reauth::DeviceAuthSource source)
    : profile_(profile->GetOriginalProfile()), source_(source) {}

BEAuthentication::~BEAuthentication() {
  // The request waiting goes unanswered: its prompt closes.
  weak_factory_.InvalidateWeakPtrs();
  Cancel();
}

void BEAuthentication::Authenticate(base::TimeDelta validity,
                                    const std::u16string& message,
                                    base::OnceCallback<void(bool)> done) {
  // DeviceAuthenticatorMac DCHECKs that it has no request waiting, and two
  // prompts at once would confuse: the older is refused, as Chrome's settings
  // page does (PasswordsPrivateDelegateImpl::AuthenticateUser()).
  if (g_asking) {
    g_asking->Cancel();
  }
  // The profile's DeviceAuthenticatorProxy holds the time of the last success,
  // shared with Chrome's own prompts; it exists for every regular profile.
  authenticator_ = ChromeDeviceAuthenticatorFactory::GetForProfile(
      profile_, device_reauth::DeviceAuthParams(validity, source_));
  if (!authenticator_) {
    OnAuthenticated(std::move(done), false);
    return;
  }
  g_asking = this;
  // Within `validity`, this answers inside the call; otherwise Touch ID
  // answers on a later task, and the account's password prompt runs from one.
  authenticator_->AuthenticateWithMessage(
      message, base::BindOnce(&BEAuthentication::OnAuthenticated,
                              weak_factory_.GetWeakPtr(), std::move(done)));
}

void BEAuthentication::Cancel() {
  if (g_asking == this) {
    g_asking = nullptr;
  }
  // Its callback runs inside Cancel(), refused; it goes once that returns.
  if (std::unique_ptr<device_reauth::DeviceAuthenticator> authenticator =
          std::move(authenticator_)) {
    authenticator->Cancel();
  }
}

void BEAuthentication::OnAuthenticated(base::OnceCallback<void(bool)> done,
                                       bool success) {
  if (g_asking == this) {
    g_asking = nullptr;
  }
  // The authenticator may be calling from inside itself: it goes later.
  if (authenticator_) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(authenticator_));
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(&BEAuthentication::Finish, weak_factory_.GetWeakPtr(),
                     std::move(done), success));
}

void BEAuthentication::Finish(base::OnceCallback<void(bool)> done,
                              bool success) {
  std::move(done).Run(success);
}

// MARK: BEPasswordsData

BEPasswordsData::BEPasswordsData(Profile* profile,
                                 base::RepeatingClosure changed)
    : profile_(profile->GetOriginalProfile()),
      changed_(std::move(changed)),
      authentication_(profile_,
                      device_reauth::DeviceAuthSource::kPasswordManager) {
  // As PasswordsPrivateDelegateFactory makes Chrome's page's presenter: the
  // profile store, which is all there is without Google's sync, and the
  // account store, empty without signing in; no passkeys (Google Password
  // Manager's). Grouping needs the affiliation service, whose data comes from
  // Google: without it, credentials group by registrable domain.
  affiliations::AffiliationService* affiliations =
      AffiliationServiceFactory::GetForProfile(profile_);
  scoped_refptr<password_manager::PasswordStoreInterface> profile_store =
      ProfilePasswordStoreFactory::GetForProfile(
          profile_, ServiceAccessType::EXPLICIT_ACCESS);
  if (!affiliations || !profile_store) {
    return;
  }
  presenter_ = std::make_unique<password_manager::SavedPasswordsPresenter>(
      affiliations, std::move(profile_store),
      AccountPasswordStoreFactory::GetForProfile(
          profile_, ServiceAccessType::EXPLICIT_ACCESS));
  insecure_ = std::make_unique<password_manager::InsecureCredentialsManager>(
      presenter_.get());
  presenter_observation_.Observe(presenter_.get());
  presenter_->Init(
      base::BindOnce(&BEPasswordsData::OnLoaded, weak_factory_.GetWeakPtr()));
}

BEPasswordsData::~BEPasswordsData() {
  weak_factory_.InvalidateWeakPtrs();
  // An export under way stops, and its file goes: the app never hears of it.
  if (exporter_ && exporter_->GetProgressStatus() ==
                       password_manager::ExportProgressStatus::kInProgress) {
    exporter_->Cancel();
  }
}

NSArray<id<BEPasswordGroup>>* BEPasswordsData::PasswordGroups() {
  return groups_ ?: @[];
}

NSArray<id<BENeverSavedSite>>* BEPasswordsData::NeverSavedSites() {
  return never_saved_ ?: @[];
}

void BEPasswordsData::OnSavedPasswordsChanged(
    const password_manager::PasswordStoreChangeList& changes) {
  // After any change from anyone (the save offer, Delete browsing data,
  // another window), once the presenter has grouped them again.
  Rebuild();
  changed_.Run();
}

void BEPasswordsData::OnLoaded() {
  // Right after the first OnSavedPasswordsChanged().
  loaded_ = true;
  std::vector<base::OnceClosure> tasks;
  tasks.swap(when_loaded_);
  for (base::OnceClosure& task : tasks) {
    std::move(task).Run();
  }
}

void BEPasswordsData::WhenLoaded(base::OnceClosure task) {
  if (loaded_) {
    std::move(task).Run();
    return;
  }
  when_loaded_.push_back(std::move(task));
}

void BEPasswordsData::Later(base::OnceClosure task) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BEPasswordsData::RunTask,
                                weak_factory_.GetWeakPtr(), std::move(task)));
}

void BEPasswordsData::RunTask(base::OnceClosure task) {
  std::move(task).Run();
}

void BEPasswordsData::Rebuild() {
  // PasswordsPrivateDelegateImpl::GetCredentialGroups() and SetCredentials():
  // the groups by name, each sign-in once with all its sites, then the
  // never-saved sites.
  std::map<CredentialKey, int64_t> identifiers;
  std::map<int64_t, CredentialUIEntry> credentials;
  std::vector<int64_t> listed;
  NSMutableArray<id<BEPasswordGroup>>* groups = [NSMutableArray array];
  for (const password_manager::AffiliatedGroup& group :
       presenter_->GetAffiliatedGroups()) {
    NSMutableArray<id<BESavedPassword>>* passwords = [NSMutableArray array];
    GURL group_url;
    for (const CredentialUIEntry& credential : group.GetCredentials()) {
      if (!credential.passkey_credential_id.empty()) {
        continue;
      }
      const int64_t identifier = IdentifierFor(credential, identifiers);
      credentials.emplace(identifier, credential);
      listed.push_back(identifier);
      [passwords addObject:SavedPassword(identifier, credential)];
      if (group_url.is_empty()) {
        group_url = credential.GetURL();
      }
    }
    if (!passwords.count) {
      continue;
    }
    // The group's icon URL is Google's (gstatic) when the affiliation service
    // has none: the app asks history for the site's own icon instead.
    [groups addObject:[[BEChromiumPasswordGroup alloc]
                          initWithName:base::SysUTF8ToNSString(
                                           group.GetDisplayName())
                                   url:ToNSURL(group_url)
                             passwords:passwords]];
  }

  // CreateUrlCollectionFromCredential(): the site shown, and its link.
  NSMutableArray<id<BENeverSavedSite>>* never_saved = [NSMutableArray array];
  for (const CredentialUIEntry& blocked : presenter_->GetBlockedSites()) {
    const int64_t identifier = IdentifierFor(blocked, identifiers);
    credentials.emplace(identifier, blocked);
    [never_saved
        addObject:[[BEChromiumNeverSavedSite alloc]
                      initWithIdentifier:identifier
                                    site:base::SysUTF8ToNSString(
                                             password_manager::GetShownOrigin(
                                                 blocked))
                                     url:ToNSURL(password_manager::GetShownUrl(
                                             blocked))]];
  }

  identifiers_ = std::move(identifiers);
  credentials_ = std::move(credentials);
  listed_ = std::move(listed);
  groups_ = groups;
  never_saved_ = never_saved;
}

int64_t BEPasswordsData::IdentifierFor(
    const CredentialUIEntry& credential,
    std::map<CredentialKey, int64_t>& identifiers) {
  CredentialKey key(password_manager::CreateCredentialSortKey(credential),
                    credential.password);
  // Listed twice (it shouldn't be): each its own.
  if (identifiers.contains(key)) {
    return next_identifier_++;
  }
  auto known = identifiers_.find(key);
  const int64_t identifier =
      known != identifiers_.end() ? known->second : next_identifier_++;
  identifiers.emplace(std::move(key), identifier);
  return identifier;
}

const CredentialUIEntry* BEPasswordsData::Find(int64_t identifier) const {
  auto found = credentials_.find(identifier);
  return found != credentials_.end() ? &found->second : nullptr;
}

// MARK: Reveal and copy

void BEPasswordsData::Reveal(int64_t identifier,
                             void (^completion)(NSString*, NSString*)) {
  if (!Find(identifier)) {
    Later(base::BindOnce(^{
      completion(nil, nil);
    }));
    return;
  }
  // RequestCredentialsDetails(): the password and its note, after asking.
  authentication_.Authenticate(
      password_manager::constants::kPasswordManagerAuthValidity,
      l10n_util::GetStringUTF16(
          IDS_PASSWORDS_PAGE_AUTHENTICATION_PROMPT_BIOMETRIC_SUFFIX),
      base::BindOnce(&BEPasswordsData::OnRevealAuthenticated,
                     weak_factory_.GetWeakPtr(), identifier, completion));
}

void BEPasswordsData::OnRevealAuthenticated(int64_t identifier,
                                            void (^completion)(NSString*,
                                                               NSString*),
                                            bool authenticated) {
  // Looked up again: it may have changed or gone while macOS asked.
  const CredentialUIEntry* credential =
      authenticated ? Find(identifier) : nullptr;
  if (!credential) {
    completion(nil, nil);
    return;
  }
  completion(base::SysUTF16ToNSString(credential->password),
             base::SysUTF16ToNSString(credential->note));
}

void BEPasswordsData::Copy(int64_t identifier, void (^completion)(BOOL)) {
  const CredentialUIEntry* credential = Find(identifier);
  if (!credential || credential->password.empty()) {
    Later(base::BindOnce(^{
      completion(NO);
    }));
    return;
  }
  authentication_.Authenticate(
      password_manager::constants::kPasswordManagerAuthValidity,
      l10n_util::GetStringUTF16(
          IDS_PASSWORDS_PAGE_COPY_AUTHENTICATION_PROMPT_BIOMETRIC_SUFFIX),
      base::BindOnce(&BEPasswordsData::OnCopyAuthenticated,
                     weak_factory_.GetWeakPtr(), identifier, completion));
}

void BEPasswordsData::OnCopyAuthenticated(int64_t identifier,
                                          void (^completion)(BOOL),
                                          bool authenticated) {
  const CredentialUIEntry* credential =
      authenticated ? Find(identifier) : nullptr;
  if (!credential || credential->password.empty()) {
    completion(NO);
    return;
  }
  // WriteToClipboardAndScheduleClear(): marked confidential, which on a Mac
  // is the pasteboard's concealed type, kept out of clipboard managers'
  // history. The writer writes when it goes, so the sequence number after is
  // the copy's.
  {
    ui::ScopedClipboardWriter writer(ui::ClipboardBuffer::kCopyPaste);
    writer.WriteText(credential->password);
    writer.MarkAsConfidential();
  }
  // Not tied to this window: the password goes even if the window closes
  // first.
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(&ClearClipboardIfUnchanged,
                     ui::Clipboard::GetForCurrentThread()->GetSequenceNumber(
                         ui::ClipboardBuffer::kCopyPaste)),
      kClipboardClearDelay);
  completion(YES);
}

// MARK: Add, edit and remove

bool BEPasswordsData::Add(NSString* site,
                          NSString* username,
                          NSString* password,
                          NSString* note) {
  // Before the passwords have loaded, a username saved already can't be told
  // apart.
  if (!presenter_ || !loaded_) {
    return false;
  }
  // PasswordsPrivateDelegateImpl::AddPassword(), with GetUrlCollection()'s
  // check of the address first.
  std::string address;
  base::TrimWhitespaceASCII(base::SysNSStringToUTF8(site), base::TRIM_ALL,
                            &address);
  const GURL url = password_manager_util::StripAuthAndParams(
      password_manager_util::ConstructGURLWithScheme(address));
  if (!password_manager::IsValidPasswordURL(url)) {
    return false;
  }
  password_manager::CredentialFacet facet;
  facet.url = url;
  facet.signon_realm = password_manager_util::GetSignonRealm(url);
  CredentialUIEntry credential;
  credential.facets.push_back(std::move(facet));
  credential.username = base::SysNSStringToUTF16(username);
  credential.password = base::SysNSStringToUTF16(password);
  credential.note = base::SysNSStringToUTF16(note);
  credential.stored_in = {password_manager::PasswordForm::Store::kProfileStore};
  // False for an empty password or a username saved for the site already.
  // Adding takes the site off the never-saved list too.
  return presenter_->AddCredential(credential);
}

BEPasswordEditResult BEPasswordsData::Edit(int64_t identifier,
                                           NSString* username,
                                           NSString* password,
                                           NSString* note) {
  const CredentialUIEntry* found = Find(identifier);
  if (!presenter_ || !found || found->blocked_by_user) {
    return BEPasswordEditResultNotFound;
  }
  // PasswordsPrivateDelegateImpl::ChangeCredential(): every form behind the
  // entry, on all its sites. A copy: the presenter's change may come back
  // through Rebuild().
  const CredentialUIEntry original = *found;
  CredentialUIEntry updated = original;
  updated.username = base::SysNSStringToUTF16(username);
  updated.password = base::SysNSStringToUTF16(password);
  updated.note = base::SysNSStringToUTF16(note);
  switch (presenter_->EditSavedCredentials(original, updated)) {
    case password_manager::SavedPasswordsPresenter::EditResult::kSuccess:
    case password_manager::SavedPasswordsPresenter::EditResult::kNothingChanged:
      return BEPasswordEditResultSaved;
    case password_manager::SavedPasswordsPresenter::EditResult::kNotFound:
      return BEPasswordEditResultNotFound;
    case password_manager::SavedPasswordsPresenter::EditResult::kAlreadyExisits:
      return BEPasswordEditResultUsernameTaken;
    case password_manager::SavedPasswordsPresenter::EditResult::kEmptyPassword:
      return BEPasswordEditResultEmptyPassword;
  }
  return BEPasswordEditResultNotFound;
}

void BEPasswordsData::Remove(int64_t identifier) {
  const CredentialUIEntry* found = Find(identifier);
  if (!presenter_ || !found) {
    return;
  }
  // From every store it's in; UndoRemoval() brings it back, as Chrome's
  // toast does.
  const CredentialUIEntry credential = *found;
  presenter_->RemoveCredential(credential);
}

void BEPasswordsData::UndoRemoval() {
  if (presenter_) {
    presenter_->UndoLastRemoval();
  }
}

// MARK: Export

void BEPasswordsData::Export(NSURL* file, void (^completion)(BOOL)) {
  const base::FilePath path = base::apple::NSURLToFilePath(file);
  if (!presenter_ || path.empty() || exporting_) {
    Later(base::BindOnce(^{
      completion(NO);
    }));
    return;
  }
  exporting_ = true;
  // PasswordsPrivateDelegateImpl::ExportPasswords(): asking every time.
  authentication_.Authenticate(
      base::Seconds(0),
      l10n_util::GetStringUTF16(
          IDS_PASSWORDS_PAGE_EXPORT_AUTHENTICATION_PROMPT_BIOMETRIC_SUFFIX),
      base::BindOnce(&BEPasswordsData::OnExportAuthenticated,
                     weak_factory_.GetWeakPtr(), path, completion));
}

void BEPasswordsData::OnExportAuthenticated(const base::FilePath& path,
                                            void (^completion)(BOOL),
                                            bool authenticated) {
  if (!authenticated) {
    exporting_ = false;
    completion(NO);
    return;
  }
  WhenLoaded(base::BindOnce(&BEPasswordsData::StartExport,
                            weak_factory_.GetWeakPtr(), path, completion));
}

void BEPasswordsData::StartExport(const base::FilePath& path,
                                  void (^completion)(BOOL)) {
  // PasswordExportController, with the app's file in place of its save
  // panel: a CSV of the saved passwords (not the never-saved sites) that only
  // the user can read (0600). One exporter per export.
  exporter_ = std::make_unique<password_manager::PasswordManagerExporter>(
      *presenter_, base::DoNothing(),
      base::BindOnce(&BEPasswordsData::OnExported, weak_factory_.GetWeakPtr(),
                     completion));
  exporter_->PreparePasswordsForExport();
  exporter_->SetDestination(path);
}

void BEPasswordsData::OnExported(void (^completion)(BOOL)) {
  const bool exported = exporter_->GetProgressStatus() ==
                        password_manager::ExportProgressStatus::kSucceeded;
  // From inside the exporter, as PasswordExportController::ExportDone() does:
  // its completion is the last it does.
  exporter_.reset();
  exporting_ = false;
  Later(base::BindOnce(^{
    completion(exported);
  }));
}

// MARK: Import

bool BEPasswordsData::IsImporting() const {
  return import_starting_ ||
         (importer_ &&
          (importer_->IsState(PasswordImporter::kInProgress) ||
           importer_->IsState(PasswordImporter::kUserInteractionRequired)));
}

void BEPasswordsData::Import(NSURL* file,
                             void (^completion)(id<BEPasswordImport>)) {
  const base::FilePath path = base::apple::NSURLToFilePath(file);
  // PasswordImportController::Import(): one import at a time.
  id<BEPasswordImport> refused =
      !presenter_ || path.empty() ? MakeImport(BEPasswordImportStatusFailed)
      : IsImporting()             ? MakeImport(BEPasswordImportStatusBusy)
                                  : nil;
  if (refused) {
    Later(base::BindOnce(^{
      completion(refused);
    }));
    return;
  }
  // The importer compares the file with the passwords saved, so it waits for
  // them.
  import_starting_ = true;
  WhenLoaded(base::BindOnce(&BEPasswordsData::StartImport,
                            weak_factory_.GetWeakPtr(), path, completion));
}

void BEPasswordsData::StartImport(const base::FilePath& path,
                                  void (^completion)(id<BEPasswordImport>)) {
  import_starting_ = false;
  conflicts_ = nil;
  conflict_count_ = 0;
  // A fresh importer each time, as PasswordImportController's after a reset.
  // The file is read on a worker and parsed in a sandboxed utility process
  // (at most 1000 KB and 3000 rows); its passwords go to the profile store.
  importer_ = std::make_unique<PasswordImporter>(*presenter_);
  importer_->Import(path, password_manager::PasswordForm::Store::kProfileStore,
                    base::BindOnce(&BEPasswordsData::OnImported,
                                   weak_factory_.GetWeakPtr(), completion));
}

void BEPasswordsData::Replace(NSArray<NSNumber*>* rows,
                              void (^completion)(id<BEPasswordImport>)) {
  // PasswordImportController::ContinueImport(): only while the importer waits
  // for the conflicts to be resolved.
  if (!importer_ ||
      !importer_->IsState(PasswordImporter::kUserInteractionRequired)) {
    id<BEPasswordImport> refused =
        MakeImport(IsImporting() ? BEPasswordImportStatusBusy
                                 : BEPasswordImportStatusFailed);
    Later(base::BindOnce(^{
      completion(refused);
    }));
    return;
  }
  // ContinueImport() CHECKs that each is a conflict's.
  std::set<int> chosen;
  for (NSNumber* row in rows) {
    const NSInteger index = row.integerValue;
    if (index >= 0 && static_cast<size_t>(index) < conflict_count_) {
      chosen.insert(static_cast<int>(index));
    }
  }
  std::vector<int> replaced(chosen.begin(), chosen.end());
  if (replaced.empty()) {
    // Keeping what's saved needs no asking.
    importer_->ContinueImport(
        replaced, base::BindOnce(&BEPasswordsData::OnImported,
                                 weak_factory_.GetWeakPtr(), completion));
    return;
  }
  // PasswordsPrivateDelegateImpl::ContinueImport(): replacing saved passwords
  // asks every time.
  authentication_.Authenticate(
      base::Seconds(0),
      l10n_util::GetStringUTF16(
          IDS_PASSWORDS_PAGE_IMPORT_AUTHENTICATION_PROMPT_BIOMETRIC_SUFFIX),
      base::BindOnce(&BEPasswordsData::OnReplaceAuthenticated,
                     weak_factory_.GetWeakPtr(), std::move(replaced),
                     completion));
}

void BEPasswordsData::OnReplaceAuthenticated(
    std::vector<int> rows,
    void (^completion)(id<BEPasswordImport>),
    bool authenticated) {
  // Finished by the app while macOS asked.
  if (!importer_ ||
      !importer_->IsState(PasswordImporter::kUserInteractionRequired)) {
    completion(MakeImport(BEPasswordImportStatusFailed));
    return;
  }
  // Refused: the import still waits on the same conflicts.
  if (!authenticated) {
    completion(conflicts_);
    return;
  }
  importer_->ContinueImport(
      rows, base::BindOnce(&BEPasswordsData::OnImported,
                           weak_factory_.GetWeakPtr(), completion));
}

void BEPasswordsData::OnImported(void (^completion)(id<BEPasswordImport>),
                                 const ImportResults& results) {
  // Everything came in: the importer keeps the file's path for DeleteFile().
  const bool can_delete_file =
      importer_ && importer_->IsState(PasswordImporter::kFinished);
  id<BEPasswordImport> result = MakeImport(results, can_delete_file);
  if (results.status == ImportResults::CONFLICTS) {
    conflicts_ = result;
    conflict_count_ = results.displayed_entries.size();
  } else {
    conflicts_ = nil;
    conflict_count_ = 0;
  }
  // The importer can answer from inside ContinueImport().
  Later(base::BindOnce(^{
    completion(result);
  }));
}

void BEPasswordsData::FinishImport(bool delete_file) {
  // PasswordImportController::ResetImporter(): not while it works.
  if (!importer_ || importer_->IsState(PasswordImporter::kInProgress)) {
    return;
  }
  if (delete_file && importer_->IsState(PasswordImporter::kFinished)) {
    // On a worker, with its own copy of the path.
    importer_->DeleteFile();
  }
  importer_.reset();
  conflicts_ = nil;
  conflict_count_ = 0;
}

// MARK: Check

void BEPasswordsData::Check(void (^completion)(NSArray<NSNumber*>*,
                                               NSArray<NSArray<NSNumber*>*>*)) {
  if (!insecure_) {
    Later(base::BindOnce(^{
      completion(@[], @[]);
    }));
    return;
  }
  WhenLoaded(base::BindOnce(&BEPasswordsData::StartCheck,
                            weak_factory_.GetWeakPtr(), completion));
}

void BEPasswordsData::StartCheck(
    void (^completion)(NSArray<NSNumber*>*, NSArray<NSArray<NSNumber*>*>*)) {
  // Chrome's password check without its leak check (Google's): weak passwords
  // by zxcvbn, and passwords reused across sites that aren't affiliated, each
  // on a worker.
  base::RepeatingClosure done = base::BarrierClosure(
      2, base::BindOnce(&BEPasswordsData::OnChecked, weak_factory_.GetWeakPtr(),
                        completion));
  insecure_->StartWeakCheck(done);
  insecure_->StartReuseCheck(done);
}

void BEPasswordsData::OnChecked(
    void (^completion)(NSArray<NSNumber*>*, NSArray<NSArray<NSNumber*>*>*)) {
  // The manager knows them per site; the app, by its listed sign-ins.
  std::set<std::u16string> weak_passwords;
  std::set<std::u16string> reused_passwords;
  for (const CredentialUIEntry& credential :
       insecure_->GetInsecureCredentialEntries()) {
    if (credential.IsWeak()) {
      weak_passwords.insert(credential.password);
    }
    if (credential.IsReused()) {
      reused_passwords.insert(credential.password);
    }
  }
  NSMutableArray<NSNumber*>* weak_identifiers = [NSMutableArray array];
  std::vector<std::vector<int64_t>> reused_groups;
  std::map<std::u16string, size_t> reused_group_index;
  for (int64_t identifier : listed_) {
    const CredentialUIEntry& credential = credentials_.at(identifier);
    if (credential.password.empty()) {
      continue;
    }
    if (weak_passwords.contains(credential.password)) {
      [weak_identifiers addObject:@(identifier)];
    }
    if (reused_passwords.contains(credential.password)) {
      auto [group, added] = reused_group_index.try_emplace(
          credential.password, reused_groups.size());
      if (added) {
        reused_groups.emplace_back();
      }
      reused_groups[group->second].push_back(identifier);
    }
  }
  // Sign-ins merged into one for affiliated sites can leave a password listed
  // once: not reused, as far as the app can see.
  NSMutableArray<NSArray<NSNumber*>*>* reused = [NSMutableArray array];
  for (const std::vector<int64_t>& group : reused_groups) {
    if (group.size() < 2) {
      continue;
    }
    NSMutableArray<NSNumber*>* identifiers = [NSMutableArray array];
    for (int64_t identifier : group) {
      [identifiers addObject:@(identifier)];
    }
    [reused addObject:identifiers];
  }
  completion(weak_identifiers, reused);
}

}  // namespace browser_engine

// MARK: BEWindowPasswords

@implementation BEChromiumWindow (Passwords)

- (NSArray<id<BEPasswordGroup>>*)passwordGroups {
  browser_engine::BEPasswordsData* data = [self passwordsData];
  return data ? data->PasswordGroups() : @[];
}

- (NSArray<id<BENeverSavedSite>>*)neverSavedSites {
  browser_engine::BEPasswordsData* data = [self passwordsData];
  return data ? data->NeverSavedSites() : @[];
}

- (void)revealPassword:(int64_t)identifier
            completion:
                (void (^)(NSString* password, NSString* note))completion {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->Reveal(identifier, completion);
  }
}

- (void)copyPassword:(int64_t)identifier
          completion:(void (^)(BOOL copied))completion {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->Copy(identifier, completion);
  }
}

- (BOOL)addPasswordForSite:(NSString*)site
                  username:(NSString*)username
                  password:(NSString*)password
                      note:(NSString*)note {
  browser_engine::BEPasswordsData* data = [self passwordsData];
  return data && data->Add(site, username, password, note);
}

- (BEPasswordEditResult)editPassword:(int64_t)identifier
                            username:(NSString*)username
                            password:(NSString*)password
                                note:(NSString*)note {
  browser_engine::BEPasswordsData* data = [self passwordsData];
  return data ? data->Edit(identifier, username, password, note)
              : BEPasswordEditResultNotFound;
}

- (void)removePassword:(int64_t)identifier {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->Remove(identifier);
  }
}

- (void)undoPasswordRemoval {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->UndoRemoval();
  }
}

- (void)exportPasswordsToFile:(NSURL*)file
                   completion:(void (^)(BOOL exported))completion {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->Export(file, completion);
  }
}

- (void)importPasswordsFromFile:(NSURL*)file
                     completion:
                         (void (^)(id<BEPasswordImport> result))completion {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->Import(file, completion);
  }
}

- (void)replacePasswords:(NSArray<NSNumber*>*)rows
              completion:(void (^)(id<BEPasswordImport> result))completion {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->Replace(rows, completion);
  }
}

- (void)finishPasswordImportDeletingFile:(BOOL)deleteFile {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->FinishImport(deleteFile);
  }
}

- (void)checkPasswordsWithCompletion:
    (void (^)(NSArray<NSNumber*>* weak,
              NSArray<NSArray<NSNumber*>*>* reused))completion {
  if (browser_engine::BEPasswordsData* data = [self passwordsData]) {
    data->Check(completion);
  }
}

@end
