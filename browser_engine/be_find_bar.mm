#import "browser_engine/be_find_bar.h"

#include "base/strings/sys_string_conversions.h"
#include "browser_engine/be_browser_window.h"
#import "browser_engine/be_window.h"
#include "components/find_in_page/find_notification_details.h"

namespace browser_engine {

BEFindBar::BEFindBar(BEBrowserWindow* window) : window_(window) {}

BEFindBar::~BEFindBar() = default;

FindBarController* BEFindBar::GetFindBarController() const {
  return controller_;
}

void BEFindBar::SetFindBarController(FindBarController* find_bar_controller) {
  controller_ = find_bar_controller;
}

void BEFindBar::Show(bool animate, bool focus) {
  visible_ = true;
  [window_->objc_window() showFindBarWithText:base::SysUTF16ToNSString(text_)];
}

void BEFindBar::Hide(bool animate) {
  if (!visible_) {
    return;
  }
  visible_ = false;
  [window_->objc_window() hideFindBar];
}

void BEFindBar::SetFocusAndSelection() {
  // ⌘F again on an open bar: the app gives its field the keyboard.
  [window_->objc_window() showFindBarWithText:base::SysUTF16ToNSString(text_)];
}

void BEFindBar::ClearResults(
    const find_in_page::FindNotificationDetails& results) {
  [window_->objc_window() didFindMatch:0 of:0 final:YES];
}

void BEFindBar::SetFindTextAndSelectedRange(const std::u16string& find_text,
                                            const gfx::Range& selected_range) {
  text_ = find_text;
}

std::u16string_view BEFindBar::GetFindText() const {
  return text_;
}

gfx::Range BEFindBar::GetSelectedRange() const {
  return gfx::Range(0, text_.size());
}

void BEFindBar::UpdateUIForFindResult(
    const find_in_page::FindNotificationDetails& result,
    const std::u16string& find_text) {
  text_ = find_text;
  [window_->objc_window() didFindMatch:result.active_match_ordinal()
                                    of:result.number_of_matches()
                                 final:result.final_update()];
}

bool BEFindBar::IsFindBarVisible() const {
  return visible_;
}

bool BEFindBar::HasGlobalFindPasteboard() const {
  return true;  // The Mac's find pasteboard, as FindBarHost on the Mac.
}

bool BEFindBar::CanPopulateFromSelectedText() {
  return true;
}

const FindBarTesting* BEFindBar::GetFindBarTesting() const {
  return nullptr;
}

bool BEFindBar::HasFocus() const {
  return false;  // The app's field, which Chrome doesn't see.
}

views::Widget* BEFindBar::GetHostWidget() {
  return nullptr;
}

}  // namespace browser_engine
