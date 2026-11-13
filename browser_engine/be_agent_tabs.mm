// Agents' tabs (BEWindowAgentTabs): each agent's storage is a StoragePartition
// of the window's profile, which its tabs are made in
// (SiteInstance::CreateForFixedStoragePartition()), as Shuttle makes its
// agents' tabs (chrome/browser/shuttle/, BSD-licensed, Copyright 2026
// Silkweave). Content keeps a page to its partition across navigations; the
// touch points close the ways out Shuttle found: windows opened without an
// opener, links opened in a new tab, blank pages (31), and discarding,
// session restore and recently closed, which would bring a tab back in the
// profile's own storage (32).

#import "browser_engine/be_agent_tabs.h"

#import <Foundation/Foundation.h>

#include <array>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <tuple>
#include <utility>
#include <vector>

#include "base/barrier_closure.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/memory/ref_counted.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#import "browser_engine/be_tab.h"
#import "browser_engine/be_window.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/resource_coordinator/tab_lifecycle_unit_external.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/common/chrome_paths_internal.h"
#include "components/performance_manager/public/decorators/page_live_state_decorator.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/site_instance.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/storage_partition_config.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/url_constants.h"
#include "crypto/hash.h"
#include "extensions/common/constants.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/base/apple/url_conversions.h"
#include "services/network/public/mojom/clear_data_filter.mojom.h"
#include "services/network/public/mojom/network_context.mojom.h"
// Through //content/public/browser (whose StoragePartition::ClearData() takes
// one); //browser_engine may not depend on blink's common headers itself.
#include "third_party/blink/public/common/storage_key/storage_key.h"  // nogncheck
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

namespace browser_engine {

namespace {

// An agent's partition domain: this, then 32 letters a-p from the SHA-256 of
// the app's name for it (as an extension's id is made). StoragePartitionConfig
// wants [a-z] for a domain, which names the partition's directory
// (Storage/ext/<domain>); no two names share one, and the Mac's
// case-insensitive disk can't merge two. The name itself is the partition's
// name, so it can be read back. Kept on disk: don't change it.
constexpr std::string_view kAgentDomainPrefix = "beagent";
constexpr size_t kAgentDomainLength = kAgentDomainPrefix.size() + 32;

std::string AgentDomain(std::string_view name) {
  const std::array<uint8_t, crypto::hash::kSha256Size> hash =
      crypto::hash::Sha256(name);
  std::string domain(kAgentDomainPrefix);
  for (size_t i = 0; i < 16; ++i) {
    domain += static_cast<char>('a' + (hash[i] >> 4));
    domain += static_cast<char>('a' + (hash[i] & 0xf));
  }
  return domain;
}

bool IsAgentDomain(std::string_view domain) {
  return domain.size() == kAgentDomainLength &&
         domain.starts_with(kAgentDomainPrefix);
}

// The agent storage pages of `site_instance` keep to, or null.
const content::StoragePartitionConfig* AgentConfig(
    content::SiteInstance* site_instance) {
  content::StoragePartition* partition =
      site_instance ? site_instance->GetBrowserContext()->GetStoragePartition(
                          site_instance, /*can_create=*/false)
                    : nullptr;
  return partition && IsAgentDomain(partition->GetConfig().partition_domain())
             ? &partition->GetConfig()
             : nullptr;
}

const content::StoragePartitionConfig* AgentConfig(
    content::WebContents* contents) {
  // The main frame's SiteInstance, which a WebContents being destroyed still
  // has, until after its observers hear.
  return contents && contents->GetPrimaryMainFrame()
             ? AgentConfig(contents->GetSiteInstance())
             : nullptr;
}

// Chrome's own pages, which never open in an agent's storage: the profile's
// own is theirs.
bool IsChromePage(const GURL& url) {
  return url.SchemeIs(content::kChromeUIScheme) ||
         url.SchemeIs(content::kChromeUIUntrustedScheme) ||
         url.SchemeIs(content::kChromeDevToolsScheme) ||
         url.SchemeIs(extensions::kExtensionScheme);
}

// Every partition of `profile` in `domain` Chrome has loaded: one on disk and
// one in memory, at most. Loaded ones stay loaded until the profile goes.
std::vector<content::StoragePartition*> LoadedPartitions(
    Profile* profile,
    const std::string& domain) {
  std::vector<content::StoragePartition*> partitions;
  profile->ForEachLoadedStoragePartition(
      [&](content::StoragePartition* partition) {
        if (partition->GetConfig().partition_domain() == domain) {
          partitions.push_back(partition);
        }
      });
  return partitions;
}

// MARK: Deleting an agent's storage

// A partition still loaded when its agent is deleted can only be emptied, not
// removed (its databases are open); Chrome asks for the directory to be
// removed at the next launch (AsyncObliterateStoragePartition()'s
// `on_gc_required`). Chrome's own way, extensions' storage garbage
// collection, would remove every partition not loaded then, the other agents'
// too. So each such agent leaves a file named after its domain here, which
// FinishDeletingAgentStorage() acts on.
base::FilePath MarkerDirectory(const base::FilePath& profile_path) {
  return profile_path.Append(FILE_PATH_LITERAL("Storage"))
      .Append(FILE_PATH_LITERAL("be_deleted_agents"));
}

base::FilePath MarkerPath(const base::FilePath& profile_path,
                          const std::string& domain) {
  return MarkerDirectory(profile_path).AppendASCII(domain);
}

// One sequence for the marker files, so that a marker written and one
// removed later (the agent made again) happen in that order; one written as
// Chromium quits still lands (BLOCK_SHUTDOWN).
scoped_refptr<base::SequencedTaskRunner> MarkerTaskRunner() {
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> runner(
      base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::BLOCK_SHUTDOWN}));
  return *runner;
}

void WriteMarker(const base::FilePath& marker) {
  if (base::CreateDirectory(marker.DirName())) {
    std::ignore = base::WriteFile(marker, std::string_view());
  }
}

void RemoveMarker(const base::FilePath& marker) {
  std::ignore = base::DeleteFile(marker);
}

// Where an agent's HTTP cache is: on the Mac in ~/Library/Caches, beside the
// profile's (ProfileNetworkContextService), which removing the partition's
// directory leaves.
base::FilePath CacheDirectory(const base::FilePath& profile_path,
                              const std::string& domain) {
  base::FilePath cache;
  chrome::GetUserCacheDirectory(
      profile_path.Append(FILE_PATH_LITERAL("Storage"))
          .Append(FILE_PATH_LITERAL("ext"))
          .AppendASCII(domain),
      &cache);
  return cache;
}

void RemoveCache(const base::FilePath& cache) {
  std::ignore = base::DeletePathRecursively(cache);
}

std::vector<std::string> ReadMarkers(const base::FilePath& directory) {
  std::vector<std::string> domains;
  base::FileEnumerator markers(directory, /*recursive=*/false,
                               base::FileEnumerator::FILES);
  for (base::FilePath marker = markers.Next(); !marker.empty();
       marker = markers.Next()) {
    const std::string domain = marker.BaseName().AsUTF8Unsafe();
    if (IsAgentDomain(domain)) {
      domains.push_back(domain);
    }
  }
  return domains;
}

// How often each agent storage (profile path, domain) was opened in this run:
// a deletion that finds it opened again since it began leaves no marker.
std::map<std::pair<base::FilePath, std::string>, int>& Opened() {
  static base::NoDestructor<
      std::map<std::pair<base::FilePath, std::string>, int>>
      opened;
  return *opened;
}

void DidOpenAgentStorage(Profile* profile, const std::string& domain) {
  if (profile->IsOffTheRecord()) {
    return;  // Nothing of it on disk.
  }
  ++Opened()[{profile->GetPath(), domain}];
  // The agent made again after it was deleted: what's in its partition now is
  // the new agent's.
  MarkerTaskRunner()->PostTask(
      FROM_HERE,
      base::BindOnce(&RemoveMarker, MarkerPath(profile->GetPath(), domain)));
}

void DeleteAgentStorage(Profile* profile,
                        const std::string& name,
                        base::OnceClosure done) {
  const std::string domain = AgentDomain(name);
  const std::vector<content::StoragePartition*> loaded =
      LoadedPartitions(profile, domain);
  // A private window's agents are kept in memory only, and its profile's
  // directory is the everyday profile's: there's nothing to remove from
  // disk, and the everyday profile's agent of the same name stays.
  const bool on_disk = !profile->IsOffTheRecord();
  base::RepeatingClosure step = base::BarrierClosure(
      loaded.size() * (on_disk ? 2 : 3) + (on_disk ? 1 : 0) +
          (on_disk && loaded.empty() ? 1 : 0),
      std::move(done));
  for (content::StoragePartition* partition : loaded) {
    // What emptying a partition leaves (StoragePartition::ClearData()), which
    // Chrome's Delete browsing data clears on its own as well.
    partition->GetNetworkContext()->ClearHttpCache(
        base::Time(), base::Time::Max(), /*filter=*/nullptr,
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::OnceClosure(step)));
    partition->ClearCodeCaches(base::Time(), base::Time::Max(),
                               base::RepeatingCallback<bool(const GURL&)>(),
                               step);
    if (!on_disk) {
      partition->ClearData(content::StoragePartition::REMOVE_DATA_MASK_ALL,
                           blink::StorageKey(), base::Time(), base::Time::Max(),
                           step);
    }
  }
  if (!on_disk) {
    return;
  }
  // Empties the loaded partitions (cookies, storage, service workers…, all
  // but the GPU's shader cache) and removes the domain's directory, unless a
  // partition in it is loaded: then the marker, unless the agent was made
  // again meanwhile.
  const base::FilePath profile_path = profile->GetPath();
  if (loaded.empty()) {
    MarkerTaskRunner()->PostTaskAndReply(
        FROM_HERE,
        base::BindOnce(&RemoveCache, CacheDirectory(profile_path, domain)),
        step);
  }
  const int opened = Opened()[{profile_path, domain}];
  profile->AsyncObliterateStoragePartition(
      domain,
      base::BindOnce(
          [](const base::FilePath& profile_path, const std::string& domain,
             int opened) {
            if (Opened()[{profile_path, domain}] != opened) {
              return;
            }
            MarkerTaskRunner()->PostTask(
                FROM_HERE,
                base::BindOnce(&WriteMarker, MarkerPath(profile_path, domain)));
          },
          profile_path, domain, opened),
      step);
}

// The second half of an earlier run's deletions (above): `domains` with a
// marker, none of whose partitions should be loaded yet.
void RemoveDeletedAgentStorage(base::WeakPtr<Profile> profile,
                               std::vector<std::string> domains) {
  if (!profile) {
    return;
  }
  for (const std::string& domain : domains) {
    const base::FilePath marker = MarkerPath(profile->GetPath(), domain);
    if (!LoadedPartitions(profile.get(), domain).empty()) {
      // Made again before this ran; its old data went when it was deleted.
      MarkerTaskRunner()->PostTask(FROM_HERE,
                                   base::BindOnce(&RemoveMarker, marker));
      continue;
    }
    auto in_use = base::MakeRefCounted<base::RefCountedData<bool>>(false);
    profile->AsyncObliterateStoragePartition(
        domain,
        base::BindOnce(
            [](scoped_refptr<base::RefCountedData<bool>> in_use) {
              in_use->data = true;
            },
            in_use),
        base::BindOnce(
            [](scoped_refptr<base::RefCountedData<bool>> in_use,
               const base::FilePath& marker, const base::FilePath& cache) {
              // Runs after `on_gc_required` would have: the marker stays for
              // the next launch if the directory couldn't go.
              if (!in_use->data) {
                MarkerTaskRunner()->PostTask(
                    FROM_HERE, base::BindOnce(&RemoveCache, cache));
                MarkerTaskRunner()->PostTask(
                    FROM_HERE, base::BindOnce(&RemoveMarker, marker));
              }
            },
            in_use, marker, CacheDirectory(profile->GetPath(), domain)));
  }
}

}  // namespace

bool IsAgentTab(content::WebContents* contents) {
  return AgentConfig(contents) != nullptr;
}

bool IsAgentStoragePath(const base::FilePath& relative_partition_path) {
  // StoragePartitionImplMap::GetStoragePartitionPath()'s layout:
  // Storage/ext/<domain>/<"def", or the name's hash>.
  const std::vector<base::FilePath::StringType> parts =
      relative_partition_path.GetComponents();
  return parts.size() == 4 && parts[0] == FILE_PATH_LITERAL("Storage") &&
         parts[1] == FILE_PATH_LITERAL("ext") &&
         IsAgentDomain(base::FilePath(parts[2]).AsUTF8Unsafe());
}

std::string GetAgentStorageName(content::WebContents* contents) {
  const content::StoragePartitionConfig* config = AgentConfig(contents);
  return config ? config->partition_name() : std::string();
}

scoped_refptr<content::SiteInstance> GetSiteInstanceForNewAgentTab(
    const NavigateParams& params,
    const GURL& url) {
  Profile* profile = params.browser ? params.browser->GetProfile() : nullptr;
  if (!profile || IsChromePage(url)) {
    return nullptr;
  }
  // The page that opens it: a link's frame (a ⌘ or middle click, which comes
  // as OpenURLFromTab() with the frame's SiteInstance), or the frame of the
  // page's menu ("Open link in new tab", which names only the frame). Not
  // `params.source_contents`, which Navigate() sets to the window's active
  // tab when nothing opens it (⌘T in an agent's tab).
  content::SiteInstance* source = params.source_site_instance.get();
  if (!source && params.initiator_frame_token) {
    content::RenderFrameHost* initiator =
        content::RenderFrameHost::FromFrameToken(
            content::GlobalRenderFrameHostToken(params.initiator_process_id,
                                                *params.initiator_frame_token));
    source = initiator ? initiator->GetSiteInstance() : nullptr;
  }
  const content::StoragePartitionConfig* config = AgentConfig(source);
  // In the same profile only: "Open link in private window" takes the page
  // to the private profile, out of the agent's storage, as for any page.
  if (!config || source->GetBrowserContext() != profile) {
    return nullptr;
  }
  return content::SiteInstance::CreateForFixedStoragePartition(profile, url,
                                                               *config);
}

void KeepAgentTabLoaded(content::WebContents* contents) {
  if (IsAgentTab(contents)) {
    SetAutoDiscardable(contents, false);
  }
}

bool IsAutoDiscardable(content::WebContents* contents) {
  resource_coordinator::TabLifecycleUnitExternal* unit =
      resource_coordinator::TabLifecycleUnitExternal::FromWebContents(contents);
  return !unit || unit->IsAutoDiscardable();
}

void SetAutoDiscardable(content::WebContents* contents, bool auto_discardable) {
  // As chrome.tabs.update({autoDiscardable}) does, through the tab's
  // lifecycle unit, which keeps the setting for the tab; before Chrome has
  // made one for a new tab, straight to what Memory Saver reads.
  if (resource_coordinator::TabLifecycleUnitExternal* unit =
          resource_coordinator::TabLifecycleUnitExternal::FromWebContents(
              contents)) {
    unit->SetAutoDiscardable(auto_discardable);
    return;
  }
  performance_manager::PageLiveStateDecorator::SetIsAutoDiscardable(
      contents, auto_discardable);
}

void FinishDeletingAgentStorage(Profile* profile) {
  if (profile->IsOffTheRecord()) {
    return;
  }
  static base::NoDestructor<std::set<base::FilePath>> checked;
  if (!checked->insert(profile->GetPath()).second) {
    return;
  }
  MarkerTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&ReadMarkers, MarkerDirectory(profile->GetPath())),
      base::BindOnce(&RemoveDeletedAgentStorage, profile->GetWeakPtr()));
}

}  // namespace browser_engine

@implementation BEChromiumWindow (AgentTabs)

- (id<BETab>)openTabWithURL:(NSURL*)url
           storagePartition:(NSString*)partition
                   inMemory:(BOOL)inMemory
                     select:(BOOL)select {
  BrowserWindowInterface* browser = [self browser];
  TabStripModel* model = [self tabStripModel];
  const GURL gurl = net::GURLWithNSURL(url);
  const std::string name = base::SysNSStringToUTF8(partition);
  if (!browser || !model || !gurl.is_valid() || name.empty() ||
      browser_engine::IsChromePage(gurl)) {
    return nil;
  }
  Profile* profile = browser->GetProfile();
  const std::string domain = browser_engine::AgentDomain(name);
  browser_engine::DidOpenAgentStorage(profile, domain);
  // A private window's profile keeps it in memory whatever `inMemory` says.
  const content::StoragePartitionConfig config =
      content::StoragePartitionConfig::Create(profile, domain, name, inMemory);

  // As Chrome's navigator opens a tab (Navigate(), CreateTargetContents()),
  // with the page's SiteInstance in the agent's partition, which its
  // navigations keep to.
  content::WebContents::CreateParams create_params(
      profile, content::SiteInstance::CreateForFixedStoragePartition(
                   profile, gurl, config));
  create_params.initially_hidden = !select;
  auto tab = std::make_unique<tabs::TabModel>(
      content::WebContents::Create(create_params), model);
  const tabs::TabHandle handle = tab->GetHandle();
  // Before the tab is in the strip, as Navigate() loads a new tab's page.
  content::NavigationController::LoadURLParams load_params(gurl);
  load_params.transition_type = ui::PAGE_TRANSITION_AUTO_TOPLEVEL;
  tab->GetContents()->GetController().LoadURLWithParams(load_params);

  // At the end, not by its opener, and outside any group (the app puts it in
  // the agent's). The app hears didInsertTab: from inside.
  model->AddTab(std::move(tab), model->count(),
                ui::PAGE_TRANSITION_AUTO_TOPLEVEL,
                AddTabTypes::ADD_FORCE_INDEX |
                    (select ? AddTabTypes::ADD_ACTIVE : AddTabTypes::ADD_NONE));
  tabs::TabInterface* inserted = handle.Get();
  return inserted ? [BEChromiumTab tabForTab:inserted] : nil;
}

- (void)deleteStoragePartition:(NSString*)partition
                    completion:(void (^)(void))completion {
  void (^copied)(void) = [completion copy];
  // On a later task, as the app's other completions.
  base::OnceClosure done = base::BindOnce(^{
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{
          copied();
        }));
  });
  BrowserWindowInterface* browser = [self browser];
  const std::string name = base::SysNSStringToUTF8(partition);
  if (!browser || name.empty()) {
    std::move(done).Run();
    return;
  }
  browser_engine::DeleteAgentStorage(browser->GetProfile(), name,
                                     std::move(done));
}

@end
