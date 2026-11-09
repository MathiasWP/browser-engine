// Page info drawn by the app (BESiteInfo): Chrome's PageInfo for the page, with
// our PageInfoUI collecting what it shows (the connection, permissions,
// cookies) in Chrome's own words, and the app's changes going back through
// PageInfo as its bubble's do.

#ifndef BROWSER_ENGINE_BE_PAGE_INFO_H_
#define BROWSER_ENGINE_BE_PAGE_INFO_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngineOptional.h"

namespace content {
class WebContents;
}  // namespace content

NS_ASSUME_NONNULL_BEGIN

@interface BEChromiumSiteInfo : NSObject <BESiteInfo>
// Page info for `contents`'s page; nil for a page without one (a new tab).
- (nullable instancetype)initWithContents:(content::WebContents*)contents
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_PAGE_INFO_H_
