// Permission prompts drawn by the app (BEPermissionPrompt): every tab's
// PermissionRequestManager makes its prompts with our factory, which gives
// the app the prompts Chrome would show as its anchored bubble, when the tab's
// delegate draws them, and Chrome's own prompts otherwise (quiet prompts, the
// page-embedded permission element's, approximate location).

#ifndef BROWSER_ENGINE_BE_PERMISSION_PROMPT_H_
#define BROWSER_ENGINE_BE_PERMISSION_PROMPT_H_

namespace content {
class WebContents;
}  // namespace content

namespace browser_engine {

// Has `contents`'s permission requests shown through our factory. For each
// WebContents a tab of ours shows (a discarded tab's new one too).
void UseAppPermissionPrompts(content::WebContents* contents);

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_PERMISSION_PROMPT_H_
