#import "browser_engine/be_import.h"

#include <errno.h>
#include <unistd.h>

#include <algorithm>
#include <string>
#include <utility>

#include "base/apple/foundation_util.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/threading/scoped_blocking_call.h"
#import "browser_engine/be_window.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/importer/external_process_importer_host.h"
#include "chrome/browser/importer/firefox_profile_lock.h"
#include "chrome/browser/importer/importer_list.h"
#include "chrome/browser/importer/importer_progress_observer.h"
#include "chrome/browser/importer/profile_writer.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/grit/generated_resources.h"
#include "components/user_data_importer/common/importer_type.h"
#include "ui/base/l10n/l10n_util.h"

// A browser profile to import from, as the app reads it: a copy, made when
// the sources were found.
@interface BEChromiumImportSource : NSObject <BEImportSource>
- (instancetype)initWithIdentifier:(NSString*)identifier
                              name:(NSString*)name
                       profileName:(NSString*)profileName
                             items:(BEImportItems)items
               needsFullDiskAccess:(BOOL)needsFullDiskAccess
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@implementation BEChromiumImportSource

@synthesize identifier = _identifier;
@synthesize name = _name;
@synthesize profileName = _profileName;
@synthesize items = _items;
@synthesize needsFullDiskAccess = _needsFullDiskAccess;

- (instancetype)initWithIdentifier:(NSString*)identifier
                              name:(NSString*)name
                       profileName:(NSString*)profileName
                             items:(BEImportItems)items
               needsFullDiskAccess:(BOOL)needsFullDiskAccess {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _name = [name copy];
    _profileName = [profileName copy];
    _items = items;
    _needsFullDiskAccess = needsFullDiskAccess;
  }
  return self;
}

@end

namespace browser_engine {

namespace {

// What the app can ask for, as Chrome's importer names it. No importer brings
// COOKIES or HOME_PAGE.
struct Item {
  BEImportItems app;
  user_data_importer::ImportItem chrome;
};

constexpr Item kItems[] = {
    {BEImportItemHistory, user_data_importer::HISTORY},
    {BEImportItemBookmarks, user_data_importer::FAVORITES},
    {BEImportItemPasswords, user_data_importer::PASSWORDS},
    {BEImportItemSearchEngines, user_data_importer::SEARCH_ENGINES},
    {BEImportItemFormData, user_data_importer::AUTOFILL_FORM_DATA},
};

uint16_t ChromeItems(BEImportItems items) {
  uint16_t chrome_items = user_data_importer::NONE;
  for (const Item& item : kItems) {
    if (items & item.app) {
      chrome_items |= item.chrome;
    }
  }
  return chrome_items;
}

BEImportItems AppItems(uint16_t chrome_items) {
  BEImportItems items = 0;
  for (const Item& item : kItems) {
    if (chrome_items & item.chrome) {
      items |= item.app;
    }
  }
  return items;
}

// The kind of browser and its profile's folder rather than an index, so an
// identifier from an older search can't pick another browser.
std::string Identifier(const user_data_importer::SourceProfile& source) {
  return base::NumberToString(static_cast<int>(source.importer_type)) + ":" +
         source.source_path.value();
}

BEChromiumImportSource* MakeSource(
    const user_data_importer::SourceProfile& source,
    BOOL needs_full_disk_access) {
  return [[BEChromiumImportSource alloc]
       initWithIdentifier:base::SysUTF8ToNSString(Identifier(source))
                     name:base::SysUTF16ToNSString(source.importer_name)
              profileName:base::SysUTF16ToNSString(source.profile)
                    items:AppItems(source.services_supported)
      needsFullDiskAccess:needs_full_disk_access];
}

// `completion` on a later task: the importer can end an import inside
// StartImportSettings(), and the app may start another from its completion.
void TellLater(BEImport::Completion completion,
               BEImportResult result,
               BEImportItems imported) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        completion(result, imported);
      }));
}

// Whether Safari's bookmarks are there but macOS keeps them from the app.
// ImporterList lists Safari only when ~/Library/Safari/Bookmarks.plist is
// readable, and without Full Disk Access TCC refuses it (EPERM), where a Mac
// whose Safari was never used has no such file (ENOENT). Blocks: off the main
// thread.
bool SafariNeedsFullDiskAccess() {
  base::ScopedBlockingCall scoped_blocking_call(FROM_HERE,
                                                base::BlockingType::MAY_BLOCK);
  const base::FilePath bookmarks =
      base::apple::GetUserLibraryPath().Append("Safari").Append(
          "Bookmarks.plist");
  return access(bookmarks.value().c_str(), R_OK) != 0 &&
         (errno == EPERM || errno == EACCES);
}

}  // namespace

// One import from start to end, owning itself. Chrome's host deletes itself
// when the import ends (ImportEnded()), and the job goes with it. Until then
// the job keeps the profile loaded: the host and its ProfileWriter hold it
// unowned, and the window may close.
class BEImportJob : public importer::ImporterProgressObserver {
 public:
  // Starts an import; null, after telling `completion`, if the profile is
  // going away. The import may have ended by the time this returns.
  static base::WeakPtr<BEImportJob> Start(
      Profile* profile,
      const user_data_importer::SourceProfile& source,
      uint16_t items,
      BEImport::Progress progress,
      BEImport::Completion completion);

  BEImportJob(const BEImportJob&) = delete;
  BEImportJob& operator=(const BEImportJob&) = delete;

  // Ends the import, and with it this job, before it returns.
  void Cancel();

 private:
  BEImportJob(std::unique_ptr<ScopedProfileKeepAlive> keep_alive,
              BEImport::Progress progress,
              BEImport::Completion completion);
  ~BEImportJob() override;

  // importer::ImporterProgressObserver:
  void ImportStarted() override;
  void ImportItemStarted(user_data_importer::ImportItem item) override;
  void ImportItemEnded(user_data_importer::ImportItem item) override;
  void ImportEnded() override;

  // `progress_` on a later task, as the completion: the app may cancel from
  // it, which would delete the host inside its own notification.
  void TellProgress(user_data_importer::ImportItem item, BOOL done);

  const std::unique_ptr<ScopedProfileKeepAlive> keep_alive_;
  BEImport::Progress progress_;
  BEImport::Completion completion_;
  // Chrome's host, until the import ends.
  raw_ptr<ExternalProcessImporterHost> host_ = nullptr;
  // What came over: the items whose import ended.
  BEImportItems imported_ = 0;
  bool cancelled_ = false;
  base::WeakPtrFactory<BEImportJob> weak_factory_{this};
};

// static
base::WeakPtr<BEImportJob> BEImportJob::Start(
    Profile* profile,
    const user_data_importer::SourceProfile& source,
    uint16_t items,
    BEImport::Progress progress,
    BEImport::Completion completion) {
  // There's no keep-alive origin for an import the user started; this one is
  // Chrome's for the first run's bookmarks import.
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive =
      ScopedProfileKeepAlive::TryAcquire(
          profile,
          ProfileKeepAliveOrigin::kWaitingForBookmarksImportOnFirstRun);
  if (!keep_alive) {
    TellLater(completion, BEImportResultFailed, 0);
    return nullptr;
  }
  auto* job = new BEImportJob(std::move(keep_alive), progress, completion);
  base::WeakPtr<BEImportJob> weak_job = job->weak_factory_.GetWeakPtr();
  // As ImportDataHandler::StartImport(), headless: a locked Firefox profile
  // cancels instead of showing Chrome's lock dialog (BEImport checked the lock
  // first). The job is the observer before the import starts, since it can
  // end inside StartImportSettings().
  auto* host = new ExternalProcessImporterHost();
  host->set_headless();
  host->set_observer(job);
  job->host_ = host;
  host->StartImportSettings(source, profile, items, new ProfileWriter(profile));
  return weak_job;
}

BEImportJob::BEImportJob(std::unique_ptr<ScopedProfileKeepAlive> keep_alive,
                         BEImport::Progress progress,
                         BEImport::Completion completion)
    : keep_alive_(std::move(keep_alive)),
      progress_(progress),
      completion_(completion) {}

BEImportJob::~BEImportJob() = default;

void BEImportJob::Cancel() {
  if (!host_) {
    return;
  }
  cancelled_ = true;
  // The host tells ImportEnded(), which deletes this job, and then deletes
  // itself.
  host_->Cancel();
}

void BEImportJob::ImportStarted() {}

void BEImportJob::ImportItemStarted(user_data_importer::ImportItem item) {
  TellProgress(item, NO);
}

void BEImportJob::ImportItemEnded(user_data_importer::ImportItem item) {
  imported_ |= AppItems(item);
  TellProgress(item, YES);
}

void BEImportJob::ImportEnded() {
  // The host deletes itself when this returns.
  host_ = nullptr;
  // As ImportDataHandler: it worked if anything came over.
  BEImportResult result = BEImportResultFailed;
  if (cancelled_) {
    result = BEImportResultCancelled;
  } else if (imported_) {
    result = BEImportResultSucceeded;
  }
  TellLater(completion_, result, imported_);
  delete this;
}

void BEImportJob::TellProgress(user_data_importer::ImportItem item, BOOL done) {
  BEImport::Progress progress = progress_;
  const BEImportItems app_item = AppItems(item);
  if (!progress || !app_item) {
    return;
  }
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        progress(app_item, done);
      }));
}

BEImport::BEImport(Profile* profile)
    : profile_(profile->GetOriginalProfile()),
      waiting_finds_([NSMutableArray array]) {}

BEImport::~BEImport() {
  // Completions run once: a search under way finds nothing now.
  NSArray<FindCompletion>* waiting = [waiting_finds_ copy];
  if (waiting.count) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{
          for (FindCompletion completion in waiting) {
            completion(@[]);
          }
        }));
  }
}

void BEImport::FindSources(FindCompletion completion) {
  const bool searching = waiting_finds_.count > 0;
  [waiting_finds_ addObject:[completion copy]];
  if (searching) {
    return;
  }
  // As ImportDataHandler::HandleInitializeImportDialog(), less the bookmarks
  // file entry: that's ImportBookmarksFile(), with the app's file panel.
  importer_list_ = std::make_unique<ImporterList>();
  importer_list_->DetectSourceProfiles(
      g_browser_process->GetApplicationLocale(),
      /*include_interactive_profiles=*/false,
      base::BindOnce(&BEImport::SourcesDetected, weak_factory_.GetWeakPtr()));
}

void BEImport::SourcesDetected() {
  for (size_t i = 0; i < importer_list_->count(); ++i) {
    if (importer_list_->GetSourceProfileAt(i).importer_type ==
        user_data_importer::TYPE_SAFARI) {
      SourcesFound(/*safari_needs_full_disk_access=*/false);
      return;
    }
  }
  // Chrome drops Safari silently when it can't read it; the app tells the
  // user why instead.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&SafariNeedsFullDiskAccess),
      base::BindOnce(&BEImport::SourcesFound, weak_factory_.GetWeakPtr()));
}

void BEImport::SourcesFound(bool safari_needs_full_disk_access) {
  sources_.clear();
  NSMutableArray<id<BEImportSource>>* sources = [NSMutableArray array];
  for (size_t i = 0; i < importer_list_->count(); ++i) {
    const user_data_importer::SourceProfile& source =
        importer_list_->GetSourceProfileAt(i);
    sources_.push_back(source);
    [sources addObject:MakeSource(source, NO)];
  }
  if (safari_needs_full_disk_access) {
    // Last: nothing comes from it until the app has the access and has been
    // opened again. Not in `sources_`, so importing from it fails.
    user_data_importer::SourceProfile safari;
    safari.importer_name = l10n_util::GetStringUTF16(IDS_IMPORT_FROM_SAFARI);
    safari.importer_type = user_data_importer::TYPE_SAFARI;
    safari.services_supported = user_data_importer::FAVORITES;
    [sources addObject:MakeSource(safari, YES)];
  }
  // On a later task: a completion may search again.
  NSArray<FindCompletion>* waiting = [waiting_finds_ copy];
  [waiting_finds_ removeAllObjects];
  NSArray<id<BEImportSource>>* found = [sources copy];
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        for (FindCompletion completion in waiting) {
          completion(found);
        }
      }));
}

void BEImport::Import(NSString* source,
                      BEImportItems items,
                      Progress progress,
                      Completion completion) {
  const std::string identifier = base::SysNSStringToUTF8(source);
  auto it = std::ranges::find_if(
      sources_, [&identifier](const user_data_importer::SourceProfile& s) {
        return Identifier(s) == identifier;
      });
  if (it == sources_.end()) {
    TellLater(completion, BEImportResultFailed, 0);
    return;
  }
  // As ImportDataHandler::HandleImportData(): what was asked for, of what
  // the source can give.
  const uint16_t chrome_items = ChromeItems(items) & it->services_supported;
  if (!chrome_items) {
    TellLater(completion, BEImportResultFailed, 0);
    return;
  }
  if (it->importer_type == user_data_importer::TYPE_FIREFOX) {
    // Firefox locks its profile while it runs. Headless, the host would only
    // cancel, which looks like any failure: check first, and let go again
    // before the host takes the lock itself.
    FirefoxProfileLock lock(it->source_path);
    if (!lock.HasAcquired()) {
      TellLater(completion, BEImportResultBrowserOpen, 0);
      return;
    }
  }
  Start(*it, chrome_items, progress, completion);
}

void BEImport::ImportBookmarksFile(NSURL* file, Completion completion) {
  if (!file.isFileURL) {
    TellLater(completion, BEImportResultFailed, 0);
    return;
  }
  // As ImportDataHandler::FileSelected(): bookmarks into "Imported", with
  // their keywords as search engines and their icons.
  user_data_importer::SourceProfile source;
  source.importer_type = user_data_importer::TYPE_BOOKMARKS_FILE;
  source.source_path = base::apple::NSURLToFilePath(file);
  Start(source, user_data_importer::FAVORITES, nil, completion);
}

void BEImport::Cancel() {
  // Each job ends, and goes, inside its Cancel().
  std::vector<base::WeakPtr<BEImportJob>> jobs = std::move(jobs_);
  jobs_.clear();
  for (const base::WeakPtr<BEImportJob>& job : jobs) {
    if (job) {
      job->Cancel();
    }
  }
}

void BEImport::Start(const user_data_importer::SourceProfile& source,
                     uint16_t items,
                     Progress progress,
                     Completion completion) {
  std::erase_if(jobs_,
                [](const base::WeakPtr<BEImportJob>& job) { return !job; });
  // Another import still running goes on, as Chrome's dialog lets it.
  if (base::WeakPtr<BEImportJob> job =
          BEImportJob::Start(profile_, source, items, progress, completion)) {
    jobs_.push_back(std::move(job));
  }
}

}  // namespace browser_engine

@implementation BEChromiumWindow (Import)

- (void)findImportSources:
    (void (^)(NSArray<id<BEImportSource>>* sources))completion {
  if (browser_engine::BEImport* importer = [self importer]) {
    importer->FindSources(completion);
  }
}

- (void)importFrom:(NSString*)source
             items:(BEImportItems)items
          progress:(void (^)(BEImportItems item, BOOL done))progress
        completion:(void (^)(BEImportResult result,
                             BEImportItems imported))completion {
  if (browser_engine::BEImport* importer = [self importer]) {
    importer->Import(source, items, progress, completion);
  }
}

- (void)importBookmarksFile:(NSURL*)file
                 completion:(void (^)(BEImportResult result,
                                      BEImportItems imported))completion {
  if (browser_engine::BEImport* importer = [self importer]) {
    importer->ImportBookmarksFile(file, completion);
  }
}

- (void)cancelImport {
  if (browser_engine::BEImport* importer = [self importer]) {
    importer->Cancel();
  }
}

@end
