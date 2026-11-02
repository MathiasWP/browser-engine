// A page as the app reads it (BEVisitedPage), for the lists that hold pages:
// recently visited (be_visited.h) and most visited (be_most_visited.h).

#ifndef BROWSER_ENGINE_BE_VISITED_PAGE_H_
#define BROWSER_ENGINE_BE_VISITED_PAGE_H_

#import <Foundation/Foundation.h>

#import "browser_engine/public/BEEngine.h"

NS_ASSUME_NONNULL_BEGIN

// Its list keeps the object while the page is listed, and sets its title and
// icon as they come (a title often comes after the visit).
@interface BEChromiumVisitedPage : NSObject <BEVisitedPage>
- (instancetype)initWithURL:(NSURL*)url NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readwrite, copy) NSString* title;
@property(nonatomic, readwrite, nullable) NSImage* favicon;
@end

NS_ASSUME_NONNULL_END

#endif  // BROWSER_ENGINE_BE_VISITED_PAGE_H_
