// Agents' tabs (BEWindowAgentTabs): tabs in the user's window whose pages keep
// to storage of their own, one StoragePartition of the window's profile per
// agent, as the Shuttle browser keeps its agents (one profile, a partition
// each, the agent's tabs in the user's tab strip). The touch points keep them
// there: what they open keeps to it (31), and they're kept out of the
// profile's history, session and recently closed, and aren't discarded (32).

#ifndef BROWSER_ENGINE_BE_AGENT_TABS_H_
#define BROWSER_ENGINE_BE_AGENT_TABS_H_

#include <string>

#include "base/memory/scoped_refptr.h"

class GURL;
class Profile;
struct NavigateParams;

namespace base {
class FilePath;
}  // namespace base

namespace content {
class SiteInstance;
class WebContents;
}  // namespace content

namespace browser_engine {

// Whether `contents` keeps to an agent's storage (Hooks::IsAgentTab()).
bool IsAgentTab(content::WebContents* contents);

// The app's name for the agent storage `contents` keeps to; empty for the
// profile's own.
std::string GetAgentStorageName(content::WebContents* contents);

// Hooks::IsAgentStoragePath(): whether a partition's directory, from its
// profile's, is an agent's (Storage/ext/<agent's domain>/…).
bool IsAgentStoragePath(const base::FilePath& relative_partition_path);

// Hooks::GetSiteInstanceForNewTab(): a SiteInstance in the agent's storage
// when `params` opens a tab from a page that keeps to one.
scoped_refptr<content::SiteInstance> GetSiteInstanceForNewAgentTab(
    const NavigateParams& params,
    const GURL& url);

// For each WebContents a tab of ours shows: an agent's isn't discarded by
// Memory Saver (touch point 32 refuses every other discard).
void KeepAgentTabLoaded(content::WebContents* contents);

// Whether Memory Saver may discard the tab showing `contents`
// (chrome.tabs' autoDiscardable), and setting it.
bool IsAutoDiscardable(content::WebContents* contents);
void SetAutoDiscardable(content::WebContents* contents, bool auto_discardable);

// Once for each profile, when its first window opens: finishes deleting the
// agents' storage that was still in use when the app deleted it in an
// earlier run (deleteStoragePartition:completion:).
void FinishDeletingAgentStorage(Profile* profile);

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_AGENT_TABS_H_
