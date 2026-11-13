// Importing from another browser, for the app's own page in place of
// chrome://settings/importData, into one window's profile (its everyday
// profile for a private window): Chrome's ImporterList finds the browsers,
// ExternalProcessImporterHost brings their data over in the importer utility
// process, and ProfileWriter writes it, as Settings' import dialog does
// (ImportDataHandler). Without its dialogs: the app picks the bookmarks file
// and tells the user to quit Firefox.

#ifndef BROWSER_ENGINE_BE_IMPORT_H_
#define BROWSER_ENGINE_BE_IMPORT_H_

#import <Foundation/Foundation.h>

#include <stdint.h>

#include <memory>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#import "browser_engine/public/BEEngineOptional.h"
#include "components/user_data_importer/common/importer_data_types.h"

class ImporterList;
class Profile;

namespace browser_engine {

class BEImportJob;

class BEImport {
 public:
  using FindCompletion = void (^)(NSArray<id<BEImportSource>>*);
  using Progress = void (^)(BEImportItems, BOOL);
  using Completion = void (^)(BEImportResult, BEImportItems);

  explicit BEImport(Profile* profile);
  BEImport(const BEImport&) = delete;
  BEImport& operator=(const BEImport&) = delete;
  // Imports under way go on to their end and still tell their completions;
  // a search under way answers with no sources.
  ~BEImport();

  // The browsers to import from, Chrome's likely default first; Safari also
  // when only the lack of Full Disk Access hides it.
  void FindSources(FindCompletion completion);
  // From a source of the last search.
  void Import(NSString* source,
              BEImportItems items,
              Progress progress,
              Completion completion);
  void ImportBookmarksFile(NSURL* file, Completion completion);
  // Every import this window started that hasn't ended.
  void Cancel();

 private:
  void SourcesDetected();
  void SourcesFound(bool safari_needs_full_disk_access);
  void Start(const user_data_importer::SourceProfile& source,
             uint16_t items,
             Progress progress,
             Completion completion);

  const raw_ptr<Profile> profile_;
  // Chrome's search, kept until the next one.
  std::unique_ptr<ImporterList> importer_list_;
  // The completions waiting for the search under way.
  NSMutableArray<FindCompletion>* waiting_finds_;
  // What the last search found, which identifiers name.
  std::vector<user_data_importer::SourceProfile> sources_;
  // The imports this window started, while they run.
  std::vector<base::WeakPtr<BEImportJob>> jobs_;
  base::WeakPtrFactory<BEImport> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_IMPORT_H_
