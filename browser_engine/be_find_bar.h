// Find in page with the app's own find bar: Chrome's FindBarController drives
// this FindBar, which tells the app what to show; the app's typing and buttons
// come back through -[BEChromiumWindow findText:forward:] and -endFind.

#ifndef BROWSER_ENGINE_BE_FIND_BAR_H_
#define BROWSER_ENGINE_BE_FIND_BAR_H_

#include <string>
#include <string_view>

#include "base/memory/raw_ptr.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "ui/gfx/range/range.h"

namespace browser_engine {

class BEBrowserWindow;

class BEFindBar : public FindBar {
 public:
  explicit BEFindBar(BEBrowserWindow* window);
  BEFindBar(const BEFindBar&) = delete;
  BEFindBar& operator=(const BEFindBar&) = delete;
  ~BEFindBar() override;

  // FindBar:
  FindBarController* GetFindBarController() const override;
  void SetFindBarController(FindBarController* find_bar_controller) override;
  void Show(bool animate, bool focus) override;
  void Hide(bool animate) override;
  void SetFocusAndSelection() override;
  void ClearResults(
      const find_in_page::FindNotificationDetails& results) override;
  void StopAnimation() override {}
  void MoveWindowIfNecessary() override {}
  void SetFindTextAndSelectedRange(const std::u16string& find_text,
                                   const gfx::Range& selected_range) override;
  std::u16string_view GetFindText() const override;
  gfx::Range GetSelectedRange() const override;
  void UpdateUIForFindResult(
      const find_in_page::FindNotificationDetails& result,
      const std::u16string& find_text) override;
  void AudibleAlert() override {}
  bool IsFindBarVisible() const override;
  void RestoreSavedFocus() override {}
  bool HasGlobalFindPasteboard() const override;
  void UpdateFindBarForChangedWebContents() override {}
  bool CanPopulateFromSelectedText() override;
  const FindBarTesting* GetFindBarTesting() const override;
  bool HasFocus() const override;
  void CloseOverlappingBubbles() override {}
  views::Widget* GetHostWidget() override;

 private:
  const raw_ptr<BEBrowserWindow> window_;
  raw_ptr<FindBarController> controller_ = nullptr;
  std::u16string text_;
  bool visible_ = false;
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_FIND_BAR_H_
