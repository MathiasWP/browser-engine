// Where Chrome's bubbles anchor when what they belong to is the app's: an
// extension's toolbar button, a site setting's icon in the address bar. An
// empty view in our widget's root view, moved over the app's rect before each
// bubble, as if Chrome's own button were there.

#ifndef BROWSER_ENGINE_BE_BUBBLE_ANCHOR_H_
#define BROWSER_ENGINE_BE_BUBBLE_ANCHOR_H_

#import <Foundation/Foundation.h>

#include "base/memory/raw_ptr.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/views/bubble/bubble_anchor.h"

namespace views {
class View;
class Widget;
}  // namespace views

namespace browser_engine {

class BEBubbleAnchor {
 public:
  // Adds the view to `widget`'s root view, which owns it. Make this after the
  // widget's Init() and destroy it before the widget.
  explicit BEBubbleAnchor(views::Widget* widget);
  BEBubbleAnchor(const BEBubbleAnchor&) = delete;
  BEBubbleAnchor& operator=(const BEBubbleAnchor&) = delete;
  ~BEBubbleAnchor();

  // `screen_rect` (AppKit's screen coordinates, from the bottom left) in the
  // root view's coordinates, from its top left.
  gfx::Rect ConvertFromScreen(const NSRect& screen_rect) const;

  // The root view's width.
  int GetRootWidth() const;

  // Moves the view over `rect` (in the root view's coordinates) and returns it
  // for a bubble to anchor to.
  views::BubbleAnchor AnchorAt(const gfx::Rect& rect);

 private:
  // Out of layout, events and accessibility.
  raw_ptr<views::View> view_ = nullptr;
};

}  // namespace browser_engine

#endif  // BROWSER_ENGINE_BE_BUBBLE_ANCHOR_H_
