#include "browser_engine/be_autocomplete.h"

#import <Foundation/Foundation.h>

#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/strings/strcat.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#import "browser_engine/be_window.h"
#include "chrome/browser/autocomplete/autocomplete_classifier_factory.h"
#include "chrome/browser/autocomplete/chrome_autocomplete_provider_client.h"
#include "chrome/browser/omnibox/autocomplete_controller_emitter_factory.h"
#include "chrome/browser/omnibox/chrome_omnibox_navigation_observer_base.h"
#include "chrome/browser/predictors/autocomplete_action_predictor.h"
#include "chrome/browser/predictors/autocomplete_action_predictor_factory.h"
#include "chrome/browser/predictors/loading_predictor.h"
#include "chrome/browser/predictors/loading_predictor_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/omnibox/browser/autocomplete_classifier.h"
#include "components/omnibox/browser/autocomplete_controller_config.h"
#include "components/omnibox/browser/autocomplete_controller_emitter.h"
#include "components/omnibox/browser/autocomplete_enums.h"
#include "components/omnibox/browser/autocomplete_match_type.h"
#include "components/omnibox/browser/autocomplete_provider.h"
#include "components/omnibox/browser/autocomplete_provider_client.h"
#include "components/omnibox/browser/autocomplete_result.h"
#include "components/omnibox/browser/location_bar_model.h"
#include "components/omnibox/common/omnibox_features.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_service.h"
#include "components/search_engines/template_url_starter_pack_data.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents.h"
#include "net/base/apple/url_conversions.h"
#include "services/network/public/cpp/constants.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"

NS_ASSUME_NONNULL_BEGIN

// One suggestion as the app reads it: a copy, which doesn't change.
@interface BEChromiumSuggestion : NSObject <BESuggestion>
- (instancetype)initWithKind:(BESuggestionKind)kind
                        text:(NSString*)text
                      detail:(NSString*)detail
                         url:(NSURL*)url
            inlineCompletion:(NSString*)inlineCompletion
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

@implementation BEChromiumSuggestion

@synthesize kind = _kind;
@synthesize text = _text;
@synthesize detail = _detail;
@synthesize url = _url;
@synthesize inlineCompletion = _inlineCompletion;

- (instancetype)initWithKind:(BESuggestionKind)kind
                        text:(NSString*)text
                      detail:(NSString*)detail
                         url:(NSURL*)url
            inlineCompletion:(NSString*)inlineCompletion {
  if ((self = [super init])) {
    _kind = kind;
    _text = [text copy];
    _detail = [detail copy];
    _url = [url copy];
    _inlineCompletion = [inlineCompletion copy];
  }
  return self;
}

@end

namespace browser_engine {

namespace {

// Chrome's desktop omnibox providers (AutocompleteClassifier::
// DefaultOmniboxProviders()), less those that need Google, a server other than
// the search engine, or UI the app doesn't have: zero-prefix suggestions, Drive
// documents, on-device suggestion models, tabs from other devices, history
// clusters and embeddings, Lens, featured search (keyword-mode chips), and the
// calculator (answers from Google's suggest server). The open-tab provider
// matches open tabs by title and address (unscoped, below).
constexpr AutocompleteProvider::Type kProviderTypes =
    AutocompleteProvider::Type::kBookmark |
    AutocompleteProvider::Type::kBuiltin |
    AutocompleteProvider::Type::kHistoryQuick |
    AutocompleteProvider::Type::kHistoryUrl |
    AutocompleteProvider::Type::kKeyword |
    AutocompleteProvider::Type::kOpenTab |
    AutocompleteProvider::Type::kSearch |
    AutocompleteProvider::Type::kShortcuts;

// Whether opening `match` switches to a tab instead of loading its page.
bool IsTabSwitch(const AutocompleteMatch& match) {
  // Only Chrome's open-tab matches. A page that's also open elsewhere
  // (has_tab_match) still opens here: in Chrome its row navigates, and only
  // its "Switch to this tab" button switches.
  return match.type == omnibox::AutocompleteMatchType::kOpenTab;
}

// Chrome's match types as the app's kinds. As the omnibox's icons
// (AutocompleteMatch::GetVectorIcon()), a bookmarked page is a bookmark
// whichever provider found it.
BESuggestionKind KindForMatch(const AutocompleteMatch& match, bool bookmarked) {
  if (IsTabSwitch(match)) {
    return BESuggestionKindOpenTab;
  }
  if (AutocompleteMatch::IsSearchType(match.type)) {
    return BESuggestionKindSearch;
  }
  if (bookmarked ||
      match.type == omnibox::AutocompleteMatchType::kBookmarkTitle) {
    return BESuggestionKindBookmark;
  }
  switch (match.type) {
    case omnibox::AutocompleteMatchType::kHistoryUrl:
    case omnibox::AutocompleteMatchType::kHistoryTitle:
    case omnibox::AutocompleteMatchType::kHistoryBody:
    case omnibox::AutocompleteMatchType::kHistoryKeyword:
    case omnibox::AutocompleteMatchType::kHistoryCluster:
    case omnibox::AutocompleteMatchType::kHistoryEmbeddings:
      return BESuggestionKindHistory;
    default:
      // The address as typed (kUrlWhatYouTyped), and addresses not visited
      // yet: Chrome's own pages (BuiltinProvider) and sites the search engine
      // suggests (kNavsuggest).
      return BESuggestionKindAddress;
  }
}

// Opens `match` as the omnibox does once the user picked it
// (OmniboxEditModel::OpenMatch(), ChromeOmniboxClient::OnAutocompleteAccept(),
// chrome::OpenCurrentURL()). Nothing here may use the BEAutocomplete: the
// navigation can close this window's tab, and so the window.
void OpenMatch(BrowserWindowInterface* browser,
               const std::u16string& text,
               const AutocompleteMatch& match,
               const AutocompleteInput& input,
               WindowOpenDisposition disposition) {
  if (IsTabSwitch(match)) {
    // TabSwitchAction::Execute(): Navigate() finds the tab among the
    // profile's windows, selects it and shows its window, or opens the page
    // if the tab has gone since.
    NavigateParams params(browser, match.destination_url,
                          ui::PAGE_TRANSITION_GENERATED);
    params.disposition = WindowOpenDisposition::SWITCH_TO_TAB;
    Navigate(&params);
    return;
  }

  Profile* profile = browser->GetProfile();
  NavigateParams params(browser, match.destination_url,
                        ui::PageTransitionFromInt(
                            match.transition |
                            ui::PAGE_TRANSITION_FROM_ADDRESS_BAR));
  params.disposition = disposition;
  params.tabstrip_add_types =
      AddTabTypes::ADD_FORCE_INDEX | AddTabTypes::ADD_INHERIT_OPENER;
  // An address typed without a scheme that Chrome tries as https:// falls
  // back to http:// (TypedNavigationUpgradeThrottle).
  params.is_using_https_as_default_scheme =
      input.added_default_scheme_to_typed_url();
  params.url_typed_with_http_scheme =
      input.typed_url_had_http_scheme() &&
      match.type == omnibox::AutocompleteMatchType::kUrlWhatYouTyped;
  for (const auto& [name, value] : match.extra_headers) {
    base::StrAppend(&params.extra_headers, {name, ": ", value, "\r\n"});
  }
  base::WeakPtr<content::NavigationHandle> navigation = Navigate(&params);

  // Once the page has loaded, the Shortcuts provider learns that `text` led
  // to `match`. No alternate address: that is the "did you mean http://text/"
  // infobar for single words.
  ChromeOmniboxNavigationObserverBase::Create(navigation.get(), profile, text,
                                              match, AutocompleteMatch());
}

// Whether `text` starts with a search engine's keyword and a space: where
// Chrome's omnibox enters keyword mode by itself
// (OmniboxEditModel::MaybeAcceptKeywordBySpace()), so "bing.com harbour"
// searches Bing, as Settings › Site search shortcuts says. The starter pack's
// ("@tabs", "@history", "@bookmarks"), the built-in engines', and the user's
// own once active (TemplateURL::CanBeUsedForKeywordMatching()). Not an
// extension's, which Chrome hands to the extension (CanOpen()).
bool IsKeywordInput(const std::u16string& text, Profile* profile) {
  const size_t space = text.find(u' ');
  if (text.empty() || space == 0 || space == std::u16string::npos) {
    return false;
  }
  TemplateURLService* service =
      TemplateURLServiceFactory::GetForProfile(profile);
  const TemplateURL* template_url =
      service ? service->GetTemplateURLForKeyword(text.substr(0, space))
              : nullptr;
  return template_url &&
         template_url->type() != TemplateURL::OMNIBOX_API_EXTENSION &&
         template_url->CanBeUsedForKeywordMatching();
}

}  // namespace

BEAutocomplete::BEAutocomplete(BrowserWindowInterface* browser,
                               BEChromiumWindow* window)
    : browser_(browser),
      window_(window),
      scheme_classifier_(browser->GetProfile()) {
  Profile* profile = browser->GetProfile();
  // As OmniboxController makes the omnibox's (omnibox_controller.cc). The
  // provider client is the classifier's, without the active page that
  // ChromeOmniboxClient gives it for Lens and contextual search.
  controller_ = std::make_unique<AutocompleteController>(
      std::make_unique<ChromeAutocompleteProviderClient>(profile),
      AutocompleteControllerConfig{
          .provider_types = AutocompleteClassifier::DefaultOmniboxProviders() &
                            static_cast<int>(kProviderTypes),
          // Open tabs match what's typed, not only after "@tabs" (as in the
          // CrOS launcher), so the app can offer to switch to them.
          .unscoped_open_tab_suggestions = true});
  controller_->AddObserver(this);
  // So chrome://omnibox shows the queries, as for the omnibox.
  if (AutocompleteControllerEmitter* emitter =
          AutocompleteControllerEmitterFactory::GetForBrowserContext(profile)) {
    controller_->AddObserver(emitter);
  }
}

BEAutocomplete::~BEAutocomplete() {
  controller_->RemoveObserver(this);
}

void BEAutocomplete::Start(const std::u16string& text,
                           bool allow_inline_completion) {
  if (!active_) {
    // A new edit, as when the user starts typing in the omnibox
    // (OmniboxEditModel::SetInputInProgressNoNotify()).
    active_ = true;
    controller_->ResetSession();
  }
  text_ = text;
  shown_is_current_ = false;

  // As OmniboxEditModel::StartAutocomplete(), with the page and https-first
  // setting ChromeOmniboxClient gives it; in keyword mode after a search
  // engine's keyword and a space (IsKeywordInput()).
  AutocompleteInput input(
      text, text.length(), GetPageClassification(), scheme_classifier_,
      base::FeatureList::IsEnabled(omnibox::kDefaultTypedNavigationsToHttps));
  if (content::WebContents* contents =
          browser_->GetTabStripModel()->GetActiveWebContents()) {
    input.set_current_url(contents->GetVisibleURL());
    input.set_current_title(contents->GetTitle());
  }
  input.set_prevent_inline_autocomplete(!allow_inline_completion);
  const bool keyword_mode = IsKeywordInput(text, browser_->GetProfile());
  input.set_allow_exact_keyword_match(keyword_mode);
  input.set_in_keyword_mode(keyword_mode);
  input.set_omit_asynchronous_matches(false);
  // Reports a first result before it returns (OnResultChanged()).
  controller_->Start(input);
}

void BEAutocomplete::Stop() {
  if (!active_) {
    return;
  }
  // Nothing was opened, unless Open() taught the predictor first (then it has
  // nothing left to learn from).
  Learn(GURL());
  // First: Stop() reports the cleared result before it returns, and the app
  // isn't told.
  active_ = false;
  text_.clear();
  shown_matches_.clear();
  shown_is_current_ = false;
  // OmniboxController::StopAutocomplete(/*clear_result=*/true).
  controller_->Stop(AutocompleteStopReason::kClobbered);
}

void BEAutocomplete::Open(size_t index, WindowOpenDisposition disposition) {
  if (!active_) {
    return;
  }
  AutocompleteMatch match;
  AutocompleteInput input;
  if (index == 0 && (!shown_is_current_ || shown_matches_.empty())) {
    if (!GetMatchForReturn(&match, &input)) {
      return;
    }
  } else if (index < shown_matches_.size()) {
    // What the user saw, even if they have typed since.
    match = shown_matches_[index];
    input = shown_input_;
  } else {
    return;
  }

  // Only from a list the user saw (AutocompleteActionPredictor::
  // OnOmniboxOpenedUrl() learns nothing with the omnibox's popup closed).
  if (!shown_matches_.empty()) {
    Learn(match.destination_url);
  }

  BrowserWindowInterface* browser = browser_;
  const std::u16string text = text_;
  // The omnibox's edit ends as it opens a match (OmniboxEditModel::OpenMatch()
  // reverts it).
  Stop();
  OpenMatch(browser, text, match, input, disposition);
}

void BEAutocomplete::OnResultChanged(AutocompleteController* controller,
                                     bool default_match_changed) {
  if (!active_ || update_pending_) {
    return;
  }
  update_pending_ = true;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BEAutocomplete::SendUpdate,
                                weak_factory_.GetWeakPtr()));
}

void BEAutocomplete::SendUpdate() {
  update_pending_ = false;
  if (!active_) {
    return;
  }
  AutocompleteProviderClient* client =
      controller_->autocomplete_provider_client();
  TemplateURLService* template_url_service = client->GetTemplateURLService();
  const bookmarks::BookmarkModel* bookmark_model = client->GetBookmarkModel();
  const AutocompleteResult& result = controller_->result();

  shown_input_ = controller_->input();
  shown_matches_.clear();
  shown_matches_.reserve(result.size());
  shown_is_current_ = true;
  NSMutableArray<id<BESuggestion>>* suggestions =
      [NSMutableArray arrayWithCapacity:result.size()];
  for (const AutocompleteMatch& match : result) {
    NSURL* url =
        CanOpen(match) ? net::NSURLWithGURL(match.destination_url) : nil;
    if (!url) {
      continue;
    }
    const BESuggestionKind kind = KindForMatch(
        match, bookmark_model &&
                   bookmark_model->IsBookmarked(match.destination_url));
    // A search names its engine when Chrome has nothing to put beside it.
    std::u16string detail = match.description;
    if (detail.empty() && AutocompleteMatch::IsSearchType(match.type)) {
      if (const TemplateURL* engine =
              match.GetTemplateURL(template_url_service)) {
        detail = engine->short_name();
      }
    }
    // Only the default match is completed inline, and only the first match
    // can be the default.
    NSString* inline_completion =
        &match == result.default_match()
            ? base::SysUTF16ToNSString(match.inline_autocompletion)
            : @"";
    [suggestions
        addObject:[[BEChromiumSuggestion alloc]
                          initWithKind:kind
                                  text:base::SysUTF16ToNSString(match.contents)
                                detail:base::SysUTF16ToNSString(detail)
                                   url:url
                      inlineCompletion:inline_completion]];
    shown_matches_.push_back(match);
  }
  Preload(result);
  // Last: the app may start, stop or open from inside.
  [window_ suggestionsDidUpdate:suggestions];
}

void BEAutocomplete::Preload(const AutocompleteResult& result) {
  content::WebContents* contents =
      browser_->GetTabStripModel()->GetActiveWebContents();
  const AutocompleteMatch* match = result.default_match();
  Profile* profile = browser_->GetProfile();
  predictors::AutocompleteActionPredictor* predictor =
      predictors::AutocompleteActionPredictorFactory::GetForProfile(profile);
  if (!contents || !match || text_.empty() || !predictor) {
    return;
  }
  predictor->RegisterTransitionalMatches(text_, result);
  switch (predictor->RecommendAction(text_, *match, contents)) {
    case predictors::AutocompleteActionPredictor::ACTION_PRERENDER:
      // Not the page already shown, nor while DevTools is open in the tab
      // (ChromeOmniboxClient::OnTextChanged(), DoPrerender()).
      if (match->destination_url != contents->GetLastCommittedURL() &&
          !AutocompleteMatch::IsSearchType(match->type) &&
          !content::DevToolsAgentHost::IsDebuggerAttached(contents)) {
        predictor->StartPrerendering(match->destination_url, *contents);
      }
      break;
    case predictors::AutocompleteActionPredictor::ACTION_PRECONNECT:
      // ChromeOmniboxClient::DoPreconnect().
      if (match->destination_url.SchemeIs("chrome-extension")) {
        break;
      }
      if (predictors::LoadingPredictor* loading_predictor =
              predictors::LoadingPredictorFactory::GetForProfile(profile)) {
        loading_predictor->PrepareForPageLoad(
            /*initiator_origin=*/std::nullopt, match->destination_url,
            predictors::HintOrigin::OMNIBOX,
            network::GetNoOpNetworkRestrictionsId(),
            predictors::AutocompleteActionPredictor::IsPreconnectable(*match));
      }
      break;
    case predictors::AutocompleteActionPredictor::ACTION_NONE:
      break;
  }
}

void BEAutocomplete::Learn(const GURL& opened_url) {
  predictors::AutocompleteActionPredictor* predictor =
      predictors::AutocompleteActionPredictorFactory::GetForProfile(
          browser_->GetProfile());
  // Its database loads after startup; until then it neither learns nor
  // recommends (AutocompleteActionPredictor::OnOmniboxOpenedUrl()).
  if (!predictor || !predictor->initialized()) {
    return;
  }
  predictor->UpdateDatabaseFromTransitionalMatches(opened_url);
}

metrics::OmniboxEventProto::PageClassification
BEAutocomplete::GetPageClassification() const {
  // The window's own model, which ChromeOmniboxClient reads through its
  // location bar.
  const LocationBarModel* model = LocationBarModel::From(browser_.get());
  return model ? model->GetPageClassification(/*is_prefetch=*/false)
               : metrics::OmniboxEventProto::OTHER;
}

bool BEAutocomplete::CanOpen(const AutocompleteMatch& match) const {
  if (!match.destination_url.is_valid() || match.takeover_action ||
      match.type == omnibox::AutocompleteMatchType::kNullResultMessage ||
      AutocompleteMatch::IsFeaturedSearchType(match.type)) {
    return false;
  }
  const TemplateURL* template_url = match.GetTemplateURL(
      controller_->autocomplete_provider_client()->GetTemplateURLService());
  return !template_url ||
         template_url->type() != TemplateURL::OMNIBOX_API_EXTENSION;
}

bool BEAutocomplete::GetMatchForReturn(AutocompleteMatch* match,
                                       AutocompleteInput* input) {
  // While a query runs, Return opens its default match; the query for
  // `text_` has had its synchronous pass (Start()).
  if (const AutocompleteMatch* default_match =
          controller_->result().default_match();
      default_match && CanOpen(*default_match)) {
    *match = *default_match;
    *input = controller_->input();
    return true;
  }
  // With nothing to go on, the omnibox classifies the text.
  AutocompleteClassifier* classifier =
      AutocompleteClassifierFactory::GetForProfile(browser_->GetProfile());
  if (!classifier) {
    return false;
  }
  classifier->Classify(text_, /*in_keyword_mode=*/false,
                       /*allow_exact_keyword_match=*/false,
                       GetPageClassification(), match,
                       /*alternate_nav_url=*/nullptr);
  return CanOpen(*match);
}

}  // namespace browser_engine
