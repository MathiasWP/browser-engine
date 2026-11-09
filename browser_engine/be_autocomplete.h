// The address bar's suggestions for one window, behind BEWindow's
// suggestForText:allowsInlineCompletion:, stopSuggesting and
// openSuggestionAtIndex:inNewTab:. Chrome's AutocompleteController, made as
// the omnibox makes it, and its matches opened as the omnibox opens them.

#ifndef BROWSER_ENGINE_BE_AUTOCOMPLETE_H_
#define BROWSER_ENGINE_BE_AUTOCOMPLETE_H_

#include <memory>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_scheme_classifier.h"
#include "components/omnibox/browser/autocomplete_controller.h"
#include "components/omnibox/browser/autocomplete_input.h"
#include "components/omnibox/browser/autocomplete_match.h"
#include "third_party/metrics_proto/omnibox_event.pb.h"
#include "ui/base/window_open_disposition.h"

@class BEChromiumWindow;

class BrowserWindowInterface;

namespace browser_engine {

// One per window: BEChromiumWindow makes it for the first suggestion and
// destroys it when the window closes. Suggestions go to the window
// (-suggestionsDidUpdate:) after the task that changed them, at most once per
// task, so never from inside a call from the app.
class BEAutocomplete : public AutocompleteController::Observer {
 public:
  BEAutocomplete(BrowserWindowInterface* browser, BEChromiumWindow* window);
  BEAutocomplete(const BEAutocomplete&) = delete;
  BEAutocomplete& operator=(const BEAutocomplete&) = delete;
  ~BEAutocomplete() override;

  // Suggests for `text`, typed in the address field with the cursor at its
  // end. The first call after Stop() starts a new edit.
  void Start(const std::u16string& text, bool allow_inline_completion);
  // Ends the edit: stops Chrome's providers and forgets the suggestions. The
  // window hears nothing more until the next Start().
  void Stop();
  // Opens the suggestion at `index` of the last update the window was sent,
  // then ends the edit, here or in a new foreground tab or window. Index 0
  // while the window has nothing for the latest text is Return: what the
  // omnibox would open for that text.
  void Open(size_t index, WindowOpenDisposition disposition);

  // AutocompleteController::Observer:
  void OnResultChanged(AutocompleteController* controller,
                       bool default_match_changed) override;

 private:
  // Sends the window the controller's current result.
  void SendUpdate();
  // What Chrome's omnibox does for the page the user is likely to open, as
  // they type (ChromeOmniboxClient::OnTextChanged()): what the action
  // predictor, which learns which page is opened after what's typed,
  // recommends for the default match. A prerender of it in the active tab,
  // which opening it then shows at once, or a connection made ahead.
  void Preload(const AutocompleteResult& result);
  // Teaches the action predictor that what was typed led to `opened_url`, or
  // to nothing (an empty URL: the edit ended), as Chrome's omnibox does
  // (ChromeOmniboxClient::OnURLOpenedFromOmnibox(), OnRevert()).
  void Learn(const GURL& opened_url);

  // What the omnibox reports for the active page (LocationBarModelImpl): the
  // NTP, about:blank, the home page, a results page of the default search
  // engine, or OTHER.
  metrics::OmniboxEventProto::PageClassification GetPageClassification() const;

  // Whether the app can be offered `match`: one that navigates. Not Chrome's
  // informational rows, matches that run an action or enter keyword mode
  // instead, or an extension's keyword, which Chrome hands to the extension
  // (OmniboxEditModel::OpenMatch()).
  bool CanOpen(const AutocompleteMatch& match) const;

  // For Return while the window has nothing for `text_`: the default match of
  // the query under way, else Chrome's classification of the text, as
  // OmniboxEditModel::GetInfoForCurrentText() picks. False if neither opens.
  bool GetMatchForReturn(AutocompleteMatch* match, AutocompleteInput* input);

  const raw_ptr<BrowserWindowInterface> browser_;
  __weak BEChromiumWindow* window_;
  const ChromeAutocompleteSchemeClassifier scheme_classifier_;
  std::unique_ptr<AutocompleteController> controller_;

  // Between Start() and Stop().
  bool active_ = false;
  // What was last given to Start().
  std::u16string text_;

  // What the window was last sent, and the input it was for. The matches
  // point into the controller's providers, so they're declared after it.
  AutocompleteInput shown_input_;
  std::vector<AutocompleteMatch> shown_matches_;
  // Whether that was for `text_`.
  bool shown_is_current_ = false;

  bool update_pending_ = false;
  base::WeakPtrFactory<BEAutocomplete> weak_factory_{this};
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_AUTOCOMPLETE_H_
