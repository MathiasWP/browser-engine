#import "browser_engine/be_bubble_anchor.h"

#include <memory>
#include <utility>

#include "ui/gfx/geometry/point.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/view.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/widget/widget.h"

namespace browser_engine {

BEBubbleAnchor::BEBubbleAnchor(views::Widget* widget) {
  // The view goes into the root view, next to the NonClientView, rather than
  // into the NativeViewHost with the app's view: a NativeViewHost takes any
  // child added to or removed from it for its own (re)attachment
  // (NativeViewHost::ViewHierarchyChanged()).
  auto view = std::make_unique<views::View>();
  view->SetProperty(views::kViewIgnoredByLayoutKey, true);
  view->SetCanProcessEventsWithinSubtree(false);
  view->GetViewAccessibility().SetIsIgnored(true);
  view_ = widget->GetRootView()->AddChildView(std::move(view));
}

// The root view keeps the view until the widget goes.
BEBubbleAnchor::~BEBubbleAnchor() = default;

gfx::Rect BEBubbleAnchor::ConvertFromScreen(const NSRect& screen_rect) const {
  // Through the screen, so Views' own conversion places it.
  const gfx::Rect bounds_in_screen = gfx::ScreenRectFromNSRect(screen_rect);
  gfx::Point origin = bounds_in_screen.origin();
  views::View::ConvertPointFromScreen(view_->parent(), &origin);
  return gfx::Rect(origin, bounds_in_screen.size());
}

int BEBubbleAnchor::GetRootWidth() const {
  return view_->parent()->width();
}

views::BubbleAnchor BEBubbleAnchor::AnchorAt(const gfx::Rect& rect) {
  view_->SetBoundsRect(rect);
  return views::BubbleAnchor(view_.get());
}

}  // namespace browser_engine
