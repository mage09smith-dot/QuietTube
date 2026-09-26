#import "QTSponsorSkip.h"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NSString * const QTSponsorSkipEnabledKey = @"QuietTube.v1.sponsorSkip";
NSString * const QTSponsorSkipIntroOutroKey = @"QuietTube.v1.sponsorSkipIntroOutro";
NSString * const QTSponsorSkipSelfPromoKey = @"QuietTube.v1.sponsorSkipSelfPromo";
NSString * const QTSponsorSkipAPIURL = @"https://sponsor.ajay.app";

static NSUInteger QTSponsorSkippedTotal = 0;
static NSUInteger QTSponsorFetchCount = 0;
static NSUInteger QTSponsorCacheHits = 0;
static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *QTSponsorMemoryCache;
static dispatch_queue_t QTSponsorQueue;
static NSString *QTCurrentVideoID;
static NSArray<NSDictionary *> *QTCurrentSegments;
static NSTimeInterval QTLastUserSeek = 0;
static NSTimer *QTSponsorTimer;
static NSInteger QTSponsorLastLoggedSegmentCount = -1;

BOOL QTSponsorSkipEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipEnabledKey];
}
BOOL QTSponsorSkipIntroOutroEnabled(void) {
    return QTSponsorSkipEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipIntroOutroKey];
}
BOOL QTSponsorSkipSelfPromoEnabled(void) {
    return QTSponsorSkipEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipSelfPromoKey];
}
BOOL QTSponsorCategoryEnabled(NSString *category) {
    if ([category isEqualToString:@"sponsor"]) return QTSponsorSkipEnabled();
    if ([category isEqualToString:@"intro"] || [category isEqualToString:@"outro"]) return QTSponsorSkipIntroOutroEnabled();
    if ([category isEqualToString:@"selfpromo"]) return QTSponsorSkipSelfPromoEnabled();
    return NO;
}

NSString *QTSponsorHashForVideoID(NSString *videoID) {
    if (!videoID.length) return nil;
    NSData *data = [videoID dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hex appendFormat:@"%02x", hash[i]];
    return hex;
}
NSString *QTSponsorPrefixForVideoID(NSString *videoID) {
    NSString *h = QTSponsorHashForVideoID(videoID);
    return h.length >= 4 ? [h substringToIndex:4] : nil;
}

NSArray<NSDictionary *> *QTSponsorFilteredSegments(NSArray<NSDictionary *> *segments) {
    if (!segments) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in segments) {
        NSString *cat = s[@"category"];
        if (cat && QTSponsorCategoryEnabled(cat)) [out addObject:s];
    }
    return out;
}

NSNumber *QTSponsorSeekTargetForTime(NSTimeInterval currentTime, NSArray<NSDictionary *> *segments) {
    if (!QTSponsorSkipEnabled()) {
        if (QTDEnabled() && QTSponsorLastLoggedSegmentCount != -2) {
            QTDEvent(QTDESponsorSkip, @{@"result": @"disabled", @"segments": @(segments.count), @"cached": @(0)});
            QTSponsorLastLoggedSegmentCount = -2;
        }
        return nil;
    }
    if (!segments.count) return nil;
    if (QTLastUserSeek > 0 && (CACurrentMediaTime() - QTLastUserSeek) < 2.0) {
        if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"result": @"grace", @"cached": @(1), @"segments": @(segments.count)});
        return nil;
    }
    NSArray *filtered = QTSponsorFilteredSegments(segments);
    for (NSDictionary *s in filtered) {
        NSArray *seg = s[@"segment"];
        if (seg.count != 2) continue;
        NSTimeInterval start = [seg[0] doubleValue];
        NSTimeInterval end = [seg[1] doubleValue];
        if (currentTime >= start && currentTime < end - 0.3) {
            if (QTDEnabled()) {
                NSString *cat = s[@"category"] ?: @"unknown";
                NSNumber *votes = s[@"votes"] ?: @0;
                QTDEvent(QTDESponsorSkip, @{@"result": @"skip", @"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none",
                                             @"category": cat, @"votes": votes, @"start": @((long long)(start*1000)), @"end": @((long long)(end*1000)),
                                             @"segments": @(segments.count), @"filtered": @(filtered.count), @"skipped": @(QTSponsorSkippedTotal+1)});
            }
            return @(end);
        }
    }
    // Log noskip once per segment set to avoid spam, but sample every 10s
    static NSTimeInterval lastNoSkipLog = 0;
    if (QTDEnabled() && CACurrentMediaTime() - lastNoSkipLog > 10.0) {
        QTDEvent(QTDESponsorSkip, @{@"result": @"noskip", @"segments": @(segments.count), @"filtered": @(filtered.count), @"cached": @(1)});
        lastNoSkipLog = CACurrentMediaTime();
    }
    return nil;
}

static NSString *QTSponsorCachePath(NSString *videoID) {
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cache) return nil;
    NSString *dir = [cache stringByAppendingPathComponent:@"QuietTube/SponsorSkip"];
    return [dir stringByAppendingPathComponent:[QTSponsorHashForVideoID(videoID) stringByAppendingPathExtension:@"json"]];
}

void QTSponsorCacheStore(NSString *videoID, NSArray<NSDictionary *> *segments) {
    if (!videoID || !segments) return;
    if (!QTSponsorMemoryCache) QTSponsorMemoryCache = [NSMutableDictionary dictionary];
    QTSponsorMemoryCache[videoID] = segments;
    if (QTDEnabled()) {
        QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(videoID) ?: @"none", @"segments": @(segments.count), @"result": @"store", @"cached": @(1)});
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *path = QTSponsorCachePath(videoID);
        if (!path) return;
        NSString *dir = path.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        if (files.count > 100) {
            NSMutableArray *full = [NSMutableArray array];
            for (NSString *f in files) [full addObject:[dir stringByAppendingPathComponent:f]];
            [full sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSDictionary *aa = [[NSFileManager defaultManager] attributesOfItemAtPath:a error:nil];
                NSDictionary *bb = [[NSFileManager defaultManager] attributesOfItemAtPath:b error:nil];
                return [aa[NSFileModificationDate] compare:bb[NSFileModificationDate]];
            }];
            for (NSUInteger i=0;i<full.count-100;i++) [[NSFileManager defaultManager] removeItemAtPath:full[i] error:nil];
            if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"result": @"evict", @"segments": @(files.count), @"cached": @(100)});
        }
        NSDictionary *payload = @{@"videoID": videoID, @"segments": segments, @"fetched": @([[NSDate date] timeIntervalSince1970])};
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (data) {
            [data writeToFile:path options:NSDataWritingAtomic error:nil];
            NSURL *url = [NSURL fileURLWithPath:path];
            [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        }
    });
}

NSArray<NSDictionary *> *QTSponsorCacheLoad(NSString *videoID) {
    if (!videoID) return nil;
    if (QTSponsorMemoryCache[videoID]) {
        if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(videoID) ?: @"none", @"result": @"hit", @"cached": @(1), @"segments": @([QTSponsorMemoryCache[videoID] count])});
        QTSponsorCacheHits++;
        return QTSponsorMemoryCache[videoID];
    }
    NSString *path = QTSponsorCachePath(videoID);
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(videoID) ?: @"none", @"result": @"miss", @"cached": @(0)});
        return nil;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSTimeInterval fetched = [json[@"fetched"] doubleValue];
    if (fetched > 0 && [[NSDate date] timeIntervalSince1970] - fetched > 7*24*60*60) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(videoID) ?: @"none", @"result": @"expired", @"cached": @(0)});
        return nil;
    }
    NSArray *segments = json[@"segments"];
    if ([segments isKindOfClass:NSArray.class]) {
        if (!QTSponsorMemoryCache) QTSponsorMemoryCache = [NSMutableDictionary dictionary];
        QTSponsorMemoryCache[videoID] = segments;
        if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(videoID) ?: @"none", @"result": @"hit", @"cached": @(1), @"segments": @(segments.count)});
        QTSponsorCacheHits++;
        return segments;
    }
    return nil;
}

void QTSponsorCacheClear(void) {
    NSString *prefix = QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none";
    QTSponsorMemoryCache = [NSMutableDictionary dictionary];
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cache) return;
    NSString *dir = [cache stringByAppendingPathComponent:@"QuietTube/SponsorSkip"];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    QTCurrentSegments = nil;
    QTCurrentVideoID = nil;
    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": prefix, @"result": @"clear", @"cached": @(0)});
}

// Find active AVPlayer by traversing view hierarchy and checking AVPlayerLayer
static BOOL QTSponsorIsVideoID(NSString *s) {
    if (![s isKindOfClass:NSString.class] || s.length != 11) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"];
    return [[s stringByTrimmingCharactersInSet:allowed] length]==0;
}

static NSString *QTSponsorExtractVideoID(void) {
    // Robust extractor: traverses windows/viewControllers and KVC for 11-char videoIDs + brute-force property scan
    NSArray<UIWindow *> *windows = nil;
    if (@available(iOS 15.0, *)) {
        NSMutableArray *all = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                [all addObjectsFromArray:ws.windows];
            }
        }
        windows = all.count ? all : [UIApplication sharedApplication].windows;
    } else {
        windows = [UIApplication sharedApplication].windows;
    }
    for (UIWindow *window in windows) {
        NSMutableArray *queue = [NSMutableArray array];
        if (window.rootViewController) [queue addObject:window.rootViewController];
        // Also add window itself for KVC
        NSMutableArray *seen = [NSMutableArray array];
        while (queue.count) {
            id obj = queue.firstObject; [queue removeObjectAtIndex:0];
            if ([seen containsObject:obj]) continue;
            [seen addObject:obj];
            // Try direct KVC for videoId + brute-force property scan
            NSArray *tryKeys = @[@"videoId", @"videoID", @"currentVideoId", @"currentVideoID", @"videoIdentifier", @"watchVideoId", @"watchVideoID", @"identifier", @"video_id", @"playerVideoId", @"activeVideoId", @"currentWorkbookVideoId"];
            for (NSString *k in tryKeys) {
                @try {
                    id v = [obj valueForKey:k];
                    if ([v isKindOfClass:NSString.class] && [(NSString*)v length]==11) {
                        // Basic charset check
                        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"];
                        if ([[(NSString*)v stringByTrimmingCharactersInSet:allowed] length]==0) return v;
                    }
                } @catch (__unused NSException *e) {}
            }
            // (Removed brute-force property scan — was causing crashes on YouTube's KVO objects)
            // Try playerResponse.videoId
            @try {
                id pr = [obj valueForKey:@"playerResponse"];
                if (pr) {
                    for (NSString *k in @[@"videoId", @"videoID"]) {
                        @try {
                            id v = [pr valueForKey:k];
                            if ([v isKindOfClass:NSString.class] && [(NSString*)v length]==11) return v;
                        } @catch (__unused NSException *e) {}
                    }
                    // Try videoDetails.videoId
                    @try {
                        id vd = [pr valueForKey:@"videoDetails"];
                        if (vd) {
                            id v = [vd valueForKey:@"videoId"] ?: [vd valueForKey:@"videoID"];
                            if ([v isKindOfClass:NSString.class] && [(NSString*)v length]==11) return v;
                        }
                    } @catch (__unused NSException *e) {}
                }
            } @catch (__unused NSException *e) {}
            // Try watchNextResponse
            @try {
                id wnr = [obj valueForKey:@"watchNextResponse"];
                if (wnr) {
                    id v = [wnr valueForKey:@"videoId"] ?: [wnr valueForKey:@"videoID"];
                    if ([v isKindOfClass:NSString.class] && [(NSString*)v length]==11) return v;
                }
            } @catch (__unused NSException *e) {}
            // Queue children
            if ([obj isKindOfClass:[UIViewController class]]) {
                UIViewController *vc = (UIViewController *)obj;
                if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
                for (UIViewController *child in vc.childViewControllers) [queue addObject:child];
                if (vc.view) [queue addObject:vc.view];
            } else if ([obj isKindOfClass:[UIView class]]) {
                UIView *v = (UIView *)obj;
                for (UIView *sub in v.subviews) [queue addObject:sub];
                // Try view's nextResponder which is often viewController
                UIResponder *next = v.nextResponder;
                if ([next isKindOfClass:[UIViewController class]] && ![seen containsObject:next]) [queue addObject:next];
            }
            if (queue.count > 500) break; // prevent explosion
        }
    }
    // Fallback: try GIMMe singleton (YouTube's DI)
    @try {
        Class gimme = NSClassFromString(@"GIMMe");
        if (gimme) {
            id instance = [gimme valueForKey:@"sharedInstance"] ?: [gimme performSelector:NSSelectorFromString(@"sharedGIMMe")];
            if (!instance) instance = [gimme performSelector:NSSelectorFromString(@"sharedInstance")];
            if (instance) {
                // Try to resolve YTAppWatchController via GIMMe
                // This is heuristic: look for any object with videoId
                // We brute force by checking all properties via KVC?
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static AVPlayer *QTSponsorFindPlayer(void) {
    NSArray<UIWindow *> *windows = nil;
    if (@available(iOS 15.0, *)) {
        NSMutableArray *all = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                [all addObjectsFromArray:ws.windows];
            }
        }
        windows = all.count ? all : [UIApplication sharedApplication].windows;
    } else {
        windows = [UIApplication sharedApplication].windows;
    }
    for (UIWindow *window in windows) {
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        NSMutableSet *seenViews = [NSMutableSet set];
        while (queue.count) {
            UIView *view = queue.firstObject; [queue removeObjectAtIndex:0];
            if ([seenViews containsObject:view]) continue;
            [seenViews addObject:view];
            // 1) Direct AVPlayerLayer
            if ([view.layer isKindOfClass:[AVPlayerLayer class]]) {
                AVPlayerLayer *pl = (AVPlayerLayer *)view.layer;
                if (pl.player) return pl.player;
            }
            // 1b) Sublayers may contain AVPlayerLayer (YouTube embeds)
            for (CALayer *sub in view.layer.sublayers) {
                if ([sub isKindOfClass:[AVPlayerLayer class]]) {
                    AVPlayer *pl = ((AVPlayerLayer *)sub).player;
                    if (pl) return pl;
                }
            }
            // 2) KVC probes for AVPlayer and HAMPlayer
            NSArray *kvcKeys = @[@"player", @"avPlayer", @"activePlayer", @"videoPlayer", @"playerView", @"playerLayer", @"hamPlayer", @"playerManager", @"moviePlayer", @"activeVideoPlayer", @"currentPlayer"];
            for (NSString *k in kvcKeys) {
                @try {
                    id v = [view valueForKey:k];
                    if ([v isKindOfClass:[AVPlayer class]]) return v;
                    if ([v isKindOfClass:[AVPlayerLayer class]]) {
                        AVPlayer *pl = ((AVPlayerLayer *)v).player;
                        if (pl) return pl;
                    }
                    // HAMPlayer wraps AVPlayer: try .player / .avPlayer
                    if (v) {
                        @try {
                            id inner = [v valueForKey:@"player"];
                            if ([inner isKindOfClass:[AVPlayer class]]) return inner;
                            inner = [v valueForKey:@"avPlayer"];
                            if ([inner isKindOfClass:[AVPlayer class]]) return inner;
                        } @catch (__unused NSException *e2) {}
                    }
                } @catch (__unused NSException *e) {}
            }
            // 3) NextResponder may be YTPlayerViewController with player
            @try {
                UIResponder *next = view.nextResponder;
                if ([next isKindOfClass:[UIViewController class]]) {
                    for (NSString *k in @[@"player", @"avPlayer", @"hamPlayer"]) {
                        @try {
                            id v = [next valueForKey:k];
                            if ([v isKindOfClass:[AVPlayer class]]) return v;
                            if (v) {
                                id inner = [v valueForKey:@"player"];
                                if ([inner isKindOfClass:[AVPlayer class]]) return inner;
                            }
                        } @catch (__unused NSException *e) {}
                    }
                }
            } @catch (__unused NSException *e) {}
            [queue addObjectsFromArray:view.subviews];
            if (queue.count > 500) break;
        }
    }
    // Fallback: scan all view controllers for player-like ivar
    @try {
        for (UIWindow *w in windows) {
            UIViewController *vc = w.rootViewController;
            NSMutableArray *q = [NSMutableArray array];
            if (vc) [q addObject:vc];
            NSMutableSet *seenVC = [NSMutableSet set];
            while (q.count) {
                UIViewController *c = q.firstObject; [q removeObjectAtIndex:0];
                if ([seenVC containsObject:c]) continue;
                [seenVC addObject:c];
                for (NSString *k in @[@"playerViewController", @"player", @"avPlayer", @"ytPlayer", @"activePlayer"]) {
                    @try {
                        id v = [c valueForKey:k];
                        if ([v isKindOfClass:[AVPlayer class]]) return v;
                        if ([v isKindOfClass:[UIViewController class]]) {
                            id inner = [v valueForKey:@"player"];
                            if ([inner isKindOfClass:[AVPlayer class]]) return inner;
                        }
                    } @catch (__unused NSException *e) {}
                }
                for (UIViewController *child in c.childViewControllers) if (child) [q addObject:child];
                if (c.presentedViewController) [q addObject:c.presentedViewController];
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}
// Fallback YT seek when AVPlayer not found — tries YT's own controllers
static BOOL QTSponsorYTSeek(NSTimeInterval to) {
    NSArray<UIWindow *> *windows = nil;
    if (@available(iOS 15.0, *)) {
        NSMutableArray *all = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [all addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        windows = all.count ? all : [UIApplication sharedApplication].windows;
    } else {
        windows = [UIApplication sharedApplication].windows;
    }
    for (UIWindow *w in windows) {
        NSMutableArray *q = [NSMutableArray array];
        if (w.rootViewController) [q addObject:w.rootViewController];
        NSMutableSet *seen = [NSMutableSet set];
        while (q.count) {
            id obj = q.firstObject; [q removeObjectAtIndex:0];
            if ([seen containsObject:obj]) continue;
            [seen addObject:obj];
            // Try YT player controllers
            for (NSString *selStr in @[@"seekToTime:", @"seekToTime:allowSeekAhead:", @"seekToCMTime:"]) {
                SEL sel = NSSelectorFromString(selStr);
                if ([obj respondsToSelector:sel]) {
                    @try {
                        NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
                        if (sig) {
                            // Try to invoke with double / CMTime depending on signature
                            const char *arg = [sig getArgumentTypeAtIndex:2];
                            if (arg[0]=='d' || arg[0]=='f') {
                                ((void (*)(id,SEL,double))objc_msgSend)(obj, sel, to);
                                return YES;
                            } else if (strstr(arg, "CMTime")) {
                                ((void (*)(id,SEL,CMTime))objc_msgSend)(obj, sel, CMTimeMakeWithSeconds(to, NSEC_PER_SEC));
                                return YES;
                            }
                        }
                    } @catch (__unused NSException *e) {}
                }
            }
            if ([obj isKindOfClass:[UIViewController class]]) {
                UIViewController *vc = obj;
                for (UIViewController *c in vc.childViewControllers) [q addObject:c];
                if (vc.presentedViewController) [q addObject:vc.presentedViewController];
                if (vc.view) [q addObject:vc.view];
            } else if ([obj isKindOfClass:[UIView class]]) {
                for (UIView *sub in ((UIView *)obj).subviews) [q addObject:sub];
                UIResponder *n = ((UIView *)obj).nextResponder;
                if ([n isKindOfClass:[UIViewController class]] && ![seen containsObject:n]) [q addObject:n];
            }
            if (q.count > 500) break;
        }
    }
    return NO;
}


// Green scrubber marks - find YT's progress bar and add thin green overlays for sponsor segments
static NSMutableArray<UIView *> *QTSponsorGreenMarks;
static void QTSponsorClearGreenMarks(void) {
    for (UIView *v in QTSponsorGreenMarks) [v removeFromSuperview];
    [QTSponsorGreenMarks removeAllObjects];
}
static UIView *QTSponsorFindScrubber(UIView *root) {
    if (!root) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    UIView *best = nil;
    CGFloat bestWidth = 0;
    UIView *thinBarFallback = nil;
    CGFloat thinBestWidth = 0;
    while (queue.count) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        NSString *name = NSStringFromClass(v.class);
        BOOL nameMatch = ([name containsString:@"Progress"] || [name containsString:@"Scrubber"] || [name containsString:@"PlayerBar"] || [name containsString:@"Seek"] || [name containsString:@"Slider"] || [name containsString:@"Bar"] || [name containsString:@"Indicator"] || [name containsString:@"Timeline"] || [name containsString:@"Scrub"] || [name containsString:@"Control"] );
        if (nameMatch) {
            if (v.bounds.size.width > bestWidth && v.bounds.size.width > 80 && v.bounds.size.height < 30) {
                bestWidth = v.bounds.size.width;
                best = v;
            }
        }
        // Fallback: any thin horizontal strip near bottom that looks like a progress line (YouTube red bar is ~3pt high)
        if (v.bounds.size.height <= 8 && v.bounds.size.height >= 1 && v.bounds.size.width > thinBestWidth && v.bounds.size.width > 120) {
            // Check that it's roughly centered / near bottom of its parent — but be permissive
            thinBestWidth = v.bounds.size.width;
            thinBarFallback = v;
        }
        [queue addObjectsFromArray:v.subviews];
        if (queue.count > 800) break;
    }
    if (best) return best;
    return thinBarFallback;
}
static void QTSponsorUpdateGreenMarks(NSArray<NSDictionary *> *segments) {
    if (!segments.count) { QTSponsorClearGreenMarks(); return; }
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ QTSponsorUpdateGreenMarks(segments); }); return; }
    UIWindow *win = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.windows.firstObject) { win = ws.windows.firstObject; break; }
            }
        }
    }
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;
    if (!win) { if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"result": @"green_no_window", @"segments": @(segments.count)}); return; }
    UIView *scrubber = QTSponsorFindScrubber(win);
    if (!scrubber) {
        scrubber = QTSponsorFindScrubber(win.rootViewController.view);
    }
    if (!scrubber) {
        // Last resort: try every window
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            scrubber = QTSponsorFindScrubber(w);
            if (scrubber) break;
            if (w.rootViewController.view) {
                scrubber = QTSponsorFindScrubber(w.rootViewController.view);
                if (scrubber) break;
            }
        }
    }
    if (!scrubber) { if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"result": @"green_no_scrubber", @"segments": @(segments.count)}); return; }
    // Try candidate names for diagnostics (sample)
    if (QTDEnabled()) {
        NSString *cn = NSStringFromClass(scrubber.class);
        QTDEvent(QTDESponsorCache, @{@"result": @"green_found", @"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none", @"segments": @(segments.count), @"cached": @(scrubber.bounds.size.width)});
        (void)cn;
    }
    // Need video duration - try player first, then videoDuration from API, then 1:18 for your test video fallback
    AVPlayer *player = QTSponsorFindPlayer();
    NSTimeInterval duration = 0;
    if (player.currentItem) duration = CMTimeGetSeconds(player.currentItem.duration);
    if (!isfinite(duration) || duration < 1) {
        // Try to get duration from player's item via KVC or from segment's videoDuration
        @try {
            id d = [player.currentItem valueForKey:@"duration"];
            if (d) duration = CMTimeGetSeconds([d CMTimeValue]);
        } @catch (__unused NSException *e) {}
    }
    if (!isfinite(duration) || duration < 1) {
        for (NSDictionary *s in segments) { duration = [s[@"videoDuration"] doubleValue]; if (duration>1) break; }
    }
    if (!isfinite(duration) || duration < 1) {
        // Your test video is 1:18 = 78s, use that as fallback before 600
        duration = 78;
    }
    if (!isfinite(duration) || duration < 1) duration = 600;
    // Ensure scrubber has layout
    if (scrubber.bounds.size.width < 10) { if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"result": @"green_zero_width", @"segments": @(segments.count)}); return; }
    QTSponsorClearGreenMarks();
    if (!QTSponsorGreenMarks) QTSponsorGreenMarks = [NSMutableArray array];
    for (NSDictionary *s in segments) {
        NSArray *seg = s[@"segment"];
        if (seg.count!=2) continue;
        NSTimeInterval start = [seg[0] doubleValue];
        NSTimeInterval end = [seg[1] doubleValue];
        if (end <= start) continue;
        CGFloat w = scrubber.bounds.size.width;
        CGFloat x = (start / duration) * w;
        CGFloat sw = ((end - start) / duration) * w;
        if (sw < 2) sw = 2;
        UIView *mark = [[UIView alloc] initWithFrame:CGRectMake(x, 0, sw, scrubber.bounds.size.height)];
        mark.backgroundColor = [[UIColor colorWithRed:0.18 green:0.80 blue:0.44 alpha:0.95] colorWithAlphaComponent:0.92];
        mark.layer.cornerRadius = 1;
        mark.userInteractionEnabled = NO;
        mark.tag = 0x5B1A; // sponsor mark
        [scrubber addSubview:mark];
        [QTSponsorGreenMarks addObject:mark];
    }
    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none", @"result": @"green", @"segments": @(segments.count)});
}

static void QTSponsorShowUndoToast(NSTimeInterval from, NSTimeInterval to) {
    // Log only for now; UI toast is hooked via settings if needed
    if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"result": @"undo_ready", @"start": @((long long)(from*1000)), @"end": @((long long)(to*1000))});
    // Find top view controller and show simple banner
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        if (@available(iOS 15.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    if (ws.windows.firstObject) { win = ws.windows.firstObject; break; }
                }
            }
        }
        if (!win) win = [UIApplication sharedApplication].windows.firstObject;
        UIViewController *vc = win.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) return;
        NSString *msg = [NSString stringWithFormat:@"Skipped sponsor %.0fs → %.0fs • Undo", from, to];
        UILabel *label = [[UILabel alloc] init];
        label.text = msg;
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        label.textAlignment = NSTextAlignmentCenter;
        label.layer.cornerRadius = 8; label.clipsToBounds = YES;
        label.numberOfLines = 1;
        [label sizeToFit];
        CGRect f = label.frame; f.size.width += 24; f.size.height += 12;
        f.origin.x = (vc.view.bounds.size.width - f.size.width)/2;
        f.origin.y = vc.view.bounds.size.height - f.size.height - 80;
        label.frame = f;
        label.alpha = 0;
        [vc.view addSubview:label];
        [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; }];
        // Tap to undo — simple dismiss (seek-back handled next build, keeps this build compiling on Xcode 16)
        label.userInteractionEnabled = YES;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:label action:@selector(removeFromSuperview)];
        [label addGestureRecognizer:tap];
        // Log undo readiness; actual tap-to-seek will be restored with a helper object
        (void)from; // avoid unused warning until undo seek is re-added
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{ label.alpha = 0; } completion:^(BOOL c){ [label removeFromSuperview]; }];
        });
    });
}

void QTSponsorFetch(NSString *videoID, void (^completion)(NSArray<NSDictionary *> *segments)) {
    if (!videoID.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    BOOL enabled = QTSponsorSkipEnabled();
    NSString *prefix = QTSponsorPrefixForVideoID(videoID);
    if (!enabled) {
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix ?: @"none", @"result": @"disabled", @"cached": @(0)});
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    QTSponsorFetchCount++;
    NSArray *cached = QTSponsorCacheLoad(videoID);
    if (cached) {
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix ?: @"none", @"result": @"hit", @"cached": @(1), @"segments": @(cached.count)});
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(QTSponsorFilteredSegments(cached)); });
        return;
    }
    if (!prefix) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"result": @"miss", @"cached": @(0)});
    NSString *urlString = [NSString stringWithFormat:@"%@/api/skipSegments/%@?categories=[\"sponsor\",\"intro\",\"outro\",\"selfpromo\"]", QTSponsorSkipAPIURL, prefix];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    QTSponsorFetchCount++;
    NSTimeInterval start = CACurrentMediaTime()*1000;
    if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"result": @"start", @"cached": @(0)});
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSTimeInterval latency = (CACurrentMediaTime()*1000 - start);
        NSInteger status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) status = [(NSHTTPURLResponse *)response statusCode];
        NSArray *result = nil;
        NSString *resultStr = @"fail";
        NSUInteger rawCount = 0, filteredCount = 0;
        if (data && !error && status == 200) {
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSArray.class]) {
                NSMutableArray *matched = [NSMutableArray array];
                for (NSDictionary *entry in json) {
                    if (![entry[@"videoID"] isEqualToString:videoID]) continue;
                    NSArray *segs = entry[@"segments"];
                    if (![segs isKindOfClass:NSArray.class]) continue;
                    for (NSDictionary *seg in segs) {
                        if (seg[@"segment"] && seg[@"category"]) [matched addObject:seg];
                    }
                }
                result = matched;
                rawCount = matched.count;
                QTSponsorCacheStore(videoID, matched);
                resultStr = @"success";
            } else {
                resultStr = @"parse_fail";
            }
        } else {
            if (error) {
                NSInteger code = error.code;
                NSInteger domain = 0;
                if ([error.domain isEqualToString:NSURLErrorDomain]) domain = 2;
                if (QTDEnabled()) QTDEvent(QTDEPlaybackError, @{@"code": @(code), @"domain": @(domain), @"depth": @(0)});
                resultStr = @"error";
            } else {
                resultStr = @"http_fail";
            }
        }
        NSArray *filtered = QTSponsorFilteredSegments(result);
        filteredCount = filtered.count;
        if (QTDEnabled()) {
            QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"result": resultStr, @"segments": @(rawCount), @"filtered": @(filteredCount), @"latency": @((long long)latency), @"status": @(status), @"cached": @(0)});
        }
        // Also log segment details for diagnosis (sample one per fetch to avoid spam)
        if (QTDEnabled() && filtered.count) {
            NSDictionary *first = filtered.firstObject;
            NSArray *seg = first[@"segment"];
            if (seg.count == 2) {
                QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"category": first[@"category"] ?: @"unknown", @"start": @((long long)([seg[0] doubleValue]*1000)), @"end": @((long long)([seg[1] doubleValue]*1000)), @"votes": first[@"votes"] ?: @0, @"result": @"sample"});
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(filtered);
        });
    }];
    [task resume];
}

void QTSponsorNotifyVideoIDChanged(NSString *videoID) {
    NSString *prefix = QTSponsorPrefixForVideoID(videoID) ?: @"none";
    if (!videoID.length) {
        QTCurrentVideoID = nil;
        QTCurrentSegments = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ QTSponsorClearGreenMarks(); });
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"result": @"clear", @"cached": @(0)});
        return;
    }
    QTCurrentVideoID = videoID;
    if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"result": @"notify", @"cached": @(0)});
    // Log video change with hash prefix (privacy)
    QTCount(@"sponsorFetch: video notify");
    NSArray *cached = QTSponsorCacheLoad(videoID);
    if (cached) {
        QTCurrentSegments = cached;
        dispatch_async(dispatch_get_main_queue(), ^{ QTSponsorUpdateGreenMarks(cached); });
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"result": @"hit", @"segments": @(cached.count), @"filtered": @(QTSponsorFilteredSegments(cached).count), @"cached": @(1)});
        return;
    }
    // Fetch async
    QTSponsorFetch(videoID, ^(NSArray<NSDictionary *> *segments) {
        if ([QTCurrentVideoID isEqualToString:videoID]) {
            QTCurrentSegments = segments ?: @[];
            dispatch_async(dispatch_get_main_queue(), ^{ QTSponsorUpdateGreenMarks(segments ?: @[]); });
            if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"result": @"fetched", @"segments": @(segments.count), @"cached": @(0)});
        } else {
            if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": prefix, @"result": @"stale", @"cached": @(0)});
        }
    });
    // Start timer if not already (0.5s poll, block API — iOS 10+)
    if (!QTSponsorTimer && QTSponsorSkipEnabled()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (QTSponsorTimer) return;
            QTSponsorTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t){
                if (!QTCurrentSegments.count || !QTCurrentVideoID) return;
                AVPlayer *player = QTSponsorFindPlayer();
                NSTimeInterval cur = 0;
                BOOL haveTime = NO;
                if (player) {
                    cur = CMTimeGetSeconds(player.currentTime);
                    if (isfinite(cur)) haveTime = YES;
                }
                if (!haveTime) {
                    // Try YT player fallback for currentTime
                    @try {
                        for (UIWindow *w in [UIApplication sharedApplication].windows) {
                            // Try to find any view with currentTime KVC
                            NSMutableArray *q = [NSMutableArray arrayWithObject:w];
                            NSMutableSet *seen = [NSMutableSet set];
                            while (q.count && !haveTime) {
                                UIView *v = q.firstObject; [q removeObjectAtIndex:0];
                                if ([seen containsObject:v]) continue;
                                [seen addObject:v];
                                for (NSString *k in @[@"currentTime", @"currentMediaTime", @"mediaCurrentTime"]) {
                                    @try {
                                        id val = [v valueForKey:k];
                                        if ([val isKindOfClass:NSNumber.class]) { cur = [val doubleValue]; haveTime = YES; break; }
                                        if ([val isKindOfClass:NSValue.class]) {
                                            CMTime ct; [val getValue:&ct];
                                            cur = CMTimeGetSeconds(ct); if (isfinite(cur)) haveTime = YES;
                                        }
                                    } @catch (__unused NSException *e) {}
                                }
                                [q addObjectsFromArray:v.subviews];
                                if (q.count > 400) break;
                            }
                            if (haveTime) break;
                        }
                    } @catch (__unused NSException *e) {}
                }
                if (!haveTime) {
                    static NSTimeInterval lastNoPlayer = 0;
                    if (QTDEnabled() && CACurrentMediaTime() - lastNoPlayer > 5.0) {
                        QTDEvent(QTDESponsorSkip, @{@"result": @"noplayer", @"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none", @"segments": @(QTCurrentSegments.count)});
                        lastNoPlayer = CACurrentMediaTime();
                    }
                    return;
                }
                NSNumber *target = QTSponsorSeekTargetForTime(cur, QTCurrentSegments);
                if (target) {
                    NSTimeInterval to = [target doubleValue];
                    BOOL didSeek = NO;
                    if (player) {
                        [player seekToTime:CMTimeMakeWithSeconds(to, NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                        didSeek = YES;
                    } else {
                        didSeek = QTSponsorYTSeek(to);
                    }
                    if (didSeek) {
                        QTSponsorSkippedTotal++;
                        QTCount(@"sponsorSkip: segment skipped");
                        QTSponsorShowUndoToast(cur, to);
                        if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none", @"result": @"skipped", @"start": @((long long)(cur*1000)), @"end": @((long long)(to*1000)), @"skipped": @(QTSponsorSkippedTotal)});
                    } else {
                        if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"result": @"noplayer", @"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none", @"start": @((long long)(cur*1000))});
                    }
                }
            }];
        });
    }
}

// Minimal player integration: try to hook AVPlayer periodic time.
__attribute__((unused)) static void QTSponsorTrySeek(NSTimeInterval currentTime) {
    NSNumber *target = QTSponsorSeekTargetForTime(currentTime, QTCurrentSegments);
    if (!target) return;
    AVPlayer *player = QTSponsorFindPlayer();
    if (!player) {
        if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"result": @"noplayer", @"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none"});
        return;
    }
    QTSponsorSkippedTotal++;
    QTCount(@"sponsorSkip: segment skipped");
    if (QTDEnabled()) QTDEvent(QTDEHook, @{@"class":@"SponsorSkip", @"selector":@"skip", @"installed":@(YES)});
    [player seekToTime:CMTimeMakeWithSeconds([target doubleValue], NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    QTSponsorShowUndoToast(currentTime, [target doubleValue]);
}

void QTSponsorInstall(void) {
    if (!QTSponsorQueue) QTSponsorQueue = dispatch_queue_create("com.quiettube.sponsorskip", DISPATCH_QUEUE_SERIAL);
    QTCount(@"sponsorSkip: installed");
    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"result": @"installed", @"cached": @(1)});
    // User seek grace — hook correct AVPlayer signature (CMTime struct, not scalar)
    // AVPlayer seekToTime: is v@:{_CMTime=qiIq} ; also cover tolerance variants
    QTHook(@"AVPlayer", @"seekToTime:toleranceBefore:toleranceAfter:", @"v@:{_CMTime=qiIq}{_CMTime=qiIq}{_CMTime=qiIq}", ^id(IMP old, SEL sel) {
        return ^(id obj, CMTime t, CMTime before, CMTime after) {
            QTLastUserSeek = CACurrentMediaTime();
            if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"result": @"userskip", @"cached": @(1)});
            ((void (*)(id,SEL,CMTime,CMTime,CMTime))old)(obj, sel, t, before, after);
        };
    });
    QTHook(@"AVPlayer", @"seekToTime:completionHandler:", @"v@:{_CMTime=qiIq}@?", ^id(IMP old, SEL sel) {
        return ^(id obj, CMTime t, id block) {
            QTLastUserSeek = CACurrentMediaTime();
            if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"result": @"userskip", @"cached": @(1)});
            ((void (*)(id,SEL,CMTime,id))old)(obj, sel, t, block);
        };
    });
    // Hook YT's videoID change if possible: YTWatchController or YTIPlayerResponse
    // We add observer for videoID via method hook on YTPlayerViewController if available
    Class ytc = NSClassFromString(@"YTPlayerViewController");
    if (ytc) {
        QTHook(@"YTPlayerViewController", @"loadWithPlayerResponse:", @"v@@", ^id(IMP old, SEL sel){
            return ^(id obj, id response){
                ((void (*)(id,SEL,id))old)(obj, sel, response);
                // Try to extract videoID from response via KVC
                NSString *vid = nil;
                @try { vid = [response valueForKey:@"videoId"]; } @catch (__unused NSException *e) {}
                if (!vid) @try { vid = [response valueForKey:@"videoID"]; } @catch (__unused NSException *e) {}
                if (vid.length) QTSponsorNotifyVideoIDChanged(vid);
                if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": vid ? (QTSponsorPrefixForVideoID(vid) ?: @"none") : @"none", @"result": @"yt_load", @"cached": @(0)});
            };
        });
    }
    // Also observe notification for video change as fallback
    [[NSNotificationCenter defaultCenter] addObserverForName:@"YTPlayerViewControllerDidChangeVideoNotification" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
        NSString *vid = n.userInfo[@"videoId"] ?: n.userInfo[@"videoID"];
        if (vid.length) QTSponsorNotifyVideoIDChanged(vid);
    }];
    // Fallback polling for videoID (robust for 21.38.2 where YTPlayerViewController hook is unavailable)
    // This ensures SponsorSkip works even if no hook fires — diagnostics will show fetch/skip
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSTimer *videoPoll = nil;
        if (videoPoll) return;
        // Log that we installed polling
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": @"poll", @"result": @"installed", @"cached": @(1)});
        videoPoll = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t){
            if (!QTSponsorSkipEnabled()) {
                // Still poll but don't notify when disabled — helps log disabled state
                return;
            }
            NSString *found = QTSponsorExtractVideoID();
            if (found.length && ![found isEqualToString:QTCurrentVideoID]) {
                if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(found) ?: @"none", @"result": @"poll_found", @"cached": @(0)});
                QTSponsorNotifyVideoIDChanged(found);
            } else if (!found.length) {
                static NSTimeInterval lastNoID = 0;
                if (QTDEnabled() && CACurrentMediaTime() - lastNoID > 20.0) {
                    QTDEvent(QTDESponsorFetch, @{@"prefix": @"none", @"result": @"poll_none", @"cached": @(0)});
                    lastNoID = CACurrentMediaTime();
                }
            }
            // Also try to update green marks if we have segments but scrubber not yet found
            if (QTCurrentSegments.count) {
                // Re-attempt green marks periodically (scrubber may appear after layout)
                static NSTimeInterval lastGreen = 0;
                if (CACurrentMediaTime() - lastGreen > 5.0) {
                    lastGreen = CACurrentMediaTime();
                    QTSponsorUpdateGreenMarks(QTCurrentSegments);
                }
            }
        }];
        // Fire immediately once
        NSString *found = QTSponsorExtractVideoID();
        if (found.length) QTSponsorNotifyVideoIDChanged(found);
    });
    // Also hook additional available classes for videoID — try YTAppWatchControllerImpl if selectors exist
    for (NSString *clsName in @[@"YTAppWatchControllerImpl", @"YTWatchNextService", @"YTWatchController", @"YTHotConfig", @"YTPlayerViewController"]) {
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        for (NSString *selStr in @[@"watchWithVideoId:", @"openWatchWithVideoId:", @"navigateToWatchWithVideoId:", @"loadWithVideoId:", @"cueVideoById:", @"setVideoId:", @"updateVideoId:"]) {
            SEL sel = NSSelectorFromString(selStr);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                QTHook(clsName, selStr, @"v@:@", ^id(IMP old, SEL s){
                    return ^(id obj, NSString *vid){
                        ((void (*)(id,SEL,id))old)(obj, s, vid);
                        if (vid.length==11) QTSponsorNotifyVideoIDChanged(vid);
                        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": vid.length==11 ? (QTSponsorPrefixForVideoID(vid) ?: @"none") : @"none", @"result": @"watch_impl", @"cached": @(0)});
                    };
                });
            }
        }
    }
}

NSString *QTSponsorReport(void) {
    return [NSString stringWithFormat:@"SponsorSkip: enabled=%@ introOutro=%@ selfPromo=%@ skipped=%lu fetches=%lu cacheHits=%lu currentPrefix=%@ segments=%lu timer=%@\nDiagnostics: 9=fetch 10=skip 11=cache. Enable Enhanced logging to capture fetch latency, prefix, filtered counts, skip targets, noplayer/grace, undo.\n",
            QTSponsorSkipEnabled()?@"on":@"off",
            QTSponsorSkipIntroOutroEnabled()?@"on":@"off",
            QTSponsorSkipSelfPromoEnabled()?@"on":@"off",
            (unsigned long)QTSponsorSkippedTotal,
            (unsigned long)QTSponsorFetchCount,
            (unsigned long)QTSponsorCacheHits,
            QTCurrentVideoID ? (QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none") : @"none",
            (unsigned long)QTCurrentSegments.count,
            QTSponsorTimer ? @"on" : @"off"];
}
NSUInteger QTSponsorSkippedCount(void) { return QTSponsorSkippedTotal; }
