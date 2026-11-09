#include "browser_engine/be_downloads.h"

#import <Foundation/Foundation.h>

#include <stdint.h>

#include <memory>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_engine.h"
#import "browser_engine/public/BEEngineOptional.h"
#include "chrome/browser/download/download_commands.h"
#include "chrome/browser/download/download_item_model.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/grit/generated_resources.h"
#include "components/download/content/public/all_download_item_notifier.h"
#include "components/download/public/common/download_danger_type.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_item_utils.h"
#include "content/public/browser/download_manager.h"
#include "net/base/apple/url_conversions.h"
#include "ui/base/l10n/l10n_util.h"
#include "url/gurl.h"

NS_ASSUME_NONNULL_BEGIN

// One download as the app reads it: the item as of the last update the app
// was sent (or is about to be), so it doesn't change between updates, and
// keeps the item's last state once the item is gone.
@interface BEChromiumDownload
    : NSObject <BEDownload, BEDownloadProfile, BEDownloadControl>
- (instancetype)initWithItem:(download::DownloadItem*)item
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Tells the delegate engineDidUpdateDownload: soon, at most once per task.
- (void)scheduleUpdate;
// The item is going (removed, destroyed, or no longer watched): keeps what it
// last was and never reaches it again. A scheduled update still goes.
- (void)detachFromItem;
@end

@interface BEChromiumDownload ()
- (void)readItem;
- (void)sendUpdate;
@end

NS_ASSUME_NONNULL_END

namespace {

BEDownloadState StateOfItem(const download::DownloadItem& item) {
  switch (item.GetState()) {
    case download::DownloadItem::IN_PROGRESS:
    case download::DownloadItem::MAX_DOWNLOAD_STATE:
      return BEDownloadStateInProgress;
    case download::DownloadItem::COMPLETE:
      return BEDownloadStateComplete;
    case download::DownloadItem::CANCELLED:
      return BEDownloadStateCancelled;
    case download::DownloadItem::INTERRUPTED:
      return BEDownloadStateInterrupted;
  }
  return BEDownloadStateInProgress;
}

// Held for being fetched insecurely: WARN or BLOCK, which the download bubble
// offers to keep (DownloadBubbleSecurityViewInfo::
// PopulateForInProgressOrComplete()). A SILENT_BLOCK one is interrupted.
bool IsHeldAsInsecure(const download::DownloadItem& item) {
  const download::DownloadItem::InsecureDownloadStatus status =
      item.GetInsecureDownloadStatus();
  return status == download::DownloadItem::InsecureDownloadStatus::WARN ||
         status == download::DownloadItem::InsecureDownloadStatus::BLOCK;
}

// Whether Chrome holds the file back for the user: it won't complete while
// insecure or dangerous (DownloadItemImpl::IsDownloadReadyForCompletion()).
bool NeedsApproval(const download::DownloadItem& item) {
  return item.GetState() == download::DownloadItem::IN_PROGRESS &&
         (IsHeldAsInsecure(item) || item.IsDangerous());
}

// Why, in the download bubble's words (its warning page's summary,
// DownloadBubbleSecurityViewInfo), without Safe Browsing's tailored and
// enterprise variants. Insecure first, as "Keep" validates that first.
NSString* WarningForItem(const download::DownloadItem& item) {
  int message_id = IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_DANGEROUS;
  if (IsHeldAsInsecure(item)) {
    message_id = IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_INSECURE;
  } else {
    switch (item.GetDangerType()) {
      case download::DOWNLOAD_DANGER_TYPE_DANGEROUS_FILE:
        message_id =
            IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_DANGEROUS_FILE_TYPE;
        break;
      case download::DOWNLOAD_DANGER_TYPE_UNCOMMON_CONTENT:
        message_id = IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_UNCOMMON_FILE;
        break;
      case download::DOWNLOAD_DANGER_TYPE_POTENTIALLY_UNWANTED:
        message_id = IDS_DOWNLOAD_BUBBLE_SUBPAGE_SUMMARY_WARNING_DECEPTIVE;
        break;
      default:
        // Safe Browsing's dangerous URL, content and host, and the scanning
        // and enterprise verdicts: "This file is dangerous".
        break;
    }
  }
  return base::SysUTF16ToNSString(l10n_util::GetStringUTF16(message_id));
}

}  // namespace

@implementation BEChromiumDownload {
  // Null once the item is gone.
  download::DownloadItem* _item;
  BOOL _updatePending;
}

@synthesize identifier = _identifier;
@synthesize isPrivate = _isPrivate;
@synthesize profileIdentifier = _profileIdentifier;
@synthesize sourceURL = _sourceURL;
@synthesize fileURL = _fileURL;
@synthesize receivedBytes = _receivedBytes;
@synthesize totalBytes = _totalBytes;
@synthesize state = _state;
@synthesize needsApproval = _needsApproval;
@synthesize warning = _warning;
@synthesize isPaused = _isPaused;
@synthesize canPause = _canPause;
@synthesize canResume = _canResume;
@synthesize canRetry = _canRetry;

- (instancetype)initWithItem:(download::DownloadItem*)item {
  if ((self = [super init])) {
    _item = item;
    _identifier = item->GetId();
    content::BrowserContext* context =
        content::DownloadItemUtils::GetBrowserContext(item);
    _isPrivate = context && context->IsOffTheRecord();
    // As BEChromiumWindow's profileIdentifier: the profile folder's name.
    Profile* profile = context ? Profile::FromBrowserContext(context) : nullptr;
    const base::FilePath folder =
        profile ? profile->GetOriginalProfile()->GetPath() : base::FilePath();
    _profileIdentifier = base::SysUTF8ToNSString(folder.BaseName().value());
    [self readItem];
  }
  return self;
}

// What the app reads, from the item as it is now.
- (void)readItem {
  const download::DownloadItem& item = *_item;
  const GURL& url = item.GetURL();
  _sourceURL = url.is_valid() ? net::NSURLWithGURL(url) : nil;
  // Empty until Chrome has picked the name, which may be after a Save panel.
  const base::FilePath& path = item.GetTargetFilePath();
  _fileURL = path.empty() ? nil : base::apple::FilePathToNSURL(path);
  _receivedBytes = item.GetReceivedBytes();
  // 0 while unknown. Once all data is saved it's the size, even of an empty
  // file.
  const int64_t total = item.GetTotalBytes();
  _totalBytes = (total > 0 || item.AllDataSaved()) ? total : -1;
  _state = StateOfItem(item);
  _needsApproval = NeedsApproval(item);
  _warning = _needsApproval ? WarningForItem(item) : @"";
  _isPaused = item.IsPaused();
  // As Chrome's download bubble offers them (DownloadUIModel::
  // IsCommandEnabled()).
  DownloadItemModel model(_item);
  DownloadCommands commands(model.GetWeakPtr());
  _canPause = commands.IsCommandEnabled(DownloadCommands::PAUSE);
  _canResume = commands.IsCommandEnabled(DownloadCommands::RESUME);
  // Chrome enables Retry for any download; its bubble offers it only for one
  // that stopped where it can't go on.
  _canRetry = item.GetState() == download::DownloadItem::INTERRUPTED &&
              !_canResume && commands.IsCommandEnabled(DownloadCommands::RETRY);
}

- (void)scheduleUpdate {
  if (_updatePending) {
    return;
  }
  _updatePending = YES;
  // Strong, so the last update (cancelled, say) goes even after the item has
  // gone and before the app holds this object.
  BEChromiumDownload* download = self;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        [download sendUpdate];
      }));
}

- (void)sendUpdate {
  _updatePending = NO;
  if (_item) {
    [self readItem];
  }
  [browser_engine::GetEngineDelegate() engineDidUpdateDownload:self];
}

- (void)detachFromItem {
  if (!_item) {
    return;
  }
  [self readItem];
  _item = nullptr;
}

// MARK: BEDownload

- (void)approve {
  if (!_item || !NeedsApproval(*_item)) {
    return;
  }
  // The download bubble's "Keep" (DownloadBubbleUIController::
  // ProcessDownloadButtonPress()): ValidateInsecureDownload() for an insecure
  // file, else ValidateDangerousDownload(). A file that is both is held again
  // for the second.
  DownloadItemModel model(_item);
  DownloadCommands commands(model.GetWeakPtr());
  commands.ExecuteCommand(DownloadCommands::KEEP);
}

- (void)cancel {
  if (!_item) {
    return;
  }
  if (NeedsApproval(*_item)) {
    // The bubble's "Delete": Chrome removes the download and its partial file
    // (DownloadUIModel::ExecuteCommand(DISCARD) → DownloadItem::Remove()).
    // The item is destroyed before this returns.
    DownloadItemModel model(_item);
    DownloadCommands commands(model.GetWeakPtr());
    commands.ExecuteCommand(DownloadCommands::DISCARD);
    return;
  }
  if (!_item->IsDone()) {
    _item->Cancel(/*user_cancel=*/true);
  }
}

// MARK: BEDownloadControl

- (void)pause {
  [self runCommand:DownloadCommands::PAUSE];
}

- (void)resume {
  [self runCommand:DownloadCommands::RESUME];
}

- (void)retry {
  [self runCommand:DownloadCommands::RETRY];
}

- (void)runCommand:(DownloadCommands::Command)command {
  if (!_item) {
    return;
  }
  DownloadItemModel model(_item);
  DownloadCommands commands(model.GetWeakPtr());
  if (commands.IsCommandEnabled(command)) {
    commands.ExecuteCommand(command);
  }
}

@end

namespace browser_engine {

// One profile's downloads: an object for each item the app hears of, kept for
// the item's life. When the manager goes down, the notifier stops watching it
// but not its items, so the app still hears them cancelled before they're
// destroyed (DownloadManagerImpl::Shutdown()).
class ProfileDownloads : public download::AllDownloadItemNotifier::Observer {
 public:
  explicit ProfileDownloads(content::DownloadManager* manager)
      : downloads_([[NSMutableDictionary alloc] init]),
        notifier_(manager, this) {
    // Downloads under way before the profile's first window (an extension's);
    // the notifier only reports what happens from now on.
    content::DownloadManager::DownloadVector items;
    manager->GetAllDownloads(&items);
    for (download::DownloadItem* item : items) {
      Update(item);
    }
  }
  ProfileDownloads(const ProfileDownloads&) = delete;
  ProfileDownloads& operator=(const ProfileDownloads&) = delete;
  ~ProfileDownloads() override {
    // The notifier stops watching the items left, which outlive it; their
    // objects must not reach them after.
    for (BEChromiumDownload* download in downloads_.allValues) {
      [download detachFromItem];
    }
  }

  // Null once the manager has gone down.
  content::DownloadManager* manager() const { return notifier_.GetManager(); }

  // download::AllDownloadItemNotifier::Observer:
  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override {
    Update(item);
  }
  void OnDownloadUpdated(content::DownloadManager* manager,
                         download::DownloadItem* item) override {
    Update(item);
  }
  void OnDownloadRemoved(content::DownloadManager* manager,
                         download::DownloadItem* item) override {
    Forget(item);
  }
  void OnDownloadDestroyed(content::DownloadManager* manager,
                           download::DownloadItem* item) override {
    Forget(item);
  }

 private:
  void Update(download::DownloadItem* item) {
    NSNumber* key = @(item->GetId());
    BEChromiumDownload* download = downloads_[key];
    if (!download) {
      // What Chrome's own download UI is told of (DownloadUIController): no
      // transient downloads, nor those loaded from history at startup unless
      // they run again.
      if (!DownloadItemModel(item).ShouldNotifyUI()) {
        return;
      }
      download = [[BEChromiumDownload alloc] initWithItem:item];
      downloads_[key] = download;
    }
    [download scheduleUpdate];
  }

  void Forget(download::DownloadItem* item) {
    NSNumber* key = @(item->GetId());
    [downloads_[key] detachFromItem];
    [downloads_ removeObjectForKey:key];
  }

  // By GetId(), which is unique within the profile. Main thread only.
  NSMutableDictionary<NSNumber*, BEChromiumDownload*>* downloads_;
  // Last: it may call in from its constructor.
  download::AllDownloadItemNotifier notifier_;
};

BEDownloads::BEDownloads() = default;

BEDownloads::~BEDownloads() = default;

void BEDownloads::ObserveProfile(Profile* profile) {
  // A private profile's manager goes down with the profile, which leaves its
  // watcher holding nothing of it: drop those.
  std::erase_if(profiles_,
                [](const std::unique_ptr<ProfileDownloads>& downloads) {
                  return !downloads->manager();
                });
  content::DownloadManager* manager = profile->GetDownloadManager();
  for (const std::unique_ptr<ProfileDownloads>& downloads : profiles_) {
    if (downloads->manager() == manager) {
      return;
    }
  }
  profiles_.push_back(std::make_unique<ProfileDownloads>(manager));
}

}  // namespace browser_engine
