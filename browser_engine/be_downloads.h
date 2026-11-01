// Downloads to the app: Chrome's DownloadItems of every profile our windows
// show, as BEDownload objects, through -[BEEngineDelegate
// engineDidUpdateDownload:].

#ifndef BROWSER_ENGINE_BE_DOWNLOADS_H_
#define BROWSER_ENGINE_BE_DOWNLOADS_H_

#include <memory>
#include <vector>

class Profile;

namespace browser_engine {

class ProfileDownloads;

// One for the process, in the engine's hooks. A profile is watched from the
// first of our windows that shows it until its DownloadManager goes down,
// which for a private window's profile is when its last window closes.
//
// Each download the app hears of is one BEDownload for the item's life. The
// app is told after the task that changed it, at most once per item per task
// (Chrome reports progress twice a second), so never from inside a call from
// the app.
class BEDownloads {
 public:
  BEDownloads();
  BEDownloads(const BEDownloads&) = delete;
  BEDownloads& operator=(const BEDownloads&) = delete;
  ~BEDownloads();

  // Watches `profile`'s downloads, unless they're watched already.
  void ObserveProfile(Profile* profile);

 private:
  std::vector<std::unique_ptr<ProfileDownloads>> profiles_;
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_DOWNLOADS_H_
