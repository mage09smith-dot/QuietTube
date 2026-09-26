#import "QTSponsorSkip.h"
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
static AVPlayer *QTSponsorFindPlayer(void) {
    // Try to find via shared application windows
    // iOS 15+ scene-aware window lookup (falls back to deprecated windows for older)
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
        // BFS over view hierarchy
        NSMutableArray *queue = [NSMutableArray arrayWithObject:window];
        while (queue.count) {
            UIView *view = queue.firstObject; [queue removeObjectAtIndex:0];
            // Check layer for AVPlayerLayer
            if ([view.layer isKindOfClass:[AVPlayerLayer class]]) {
                AVPlayerLayer *pl = (AVPlayerLayer *)view.layer;
                if (pl.player) return pl.player;
            }
            // Also check if view is YTPlayerViewController's view with player property via KVC
            @try {
                id maybePlayer = [view valueForKey:@"player"];
                if ([maybePlayer isKindOfClass:[AVPlayer class]]) return maybePlayer;
                id playerView = [view valueForKey:@"playerView"];
                if ([playerView isKindOfClass:[AVPlayerLayer class]]) {
                    AVPlayer *p = ((AVPlayerLayer *)playerView).player;
                    if (p) return p;
                }
            } @catch (__unused NSException *e) {}
            [queue addObjectsFromArray:view.subviews];
        }
    }
    // Fallback: try to find YT app's player via class
    Class ytpvc = NSClassFromString(@"YTPlayerViewController");
    if (ytpvc) {
        // Search for instances via runtime? Not reliable, skip
    }
    return nil;
}


// Green scrubber marks - find YT's progress bar and add thin green overlays for sponsor segments
static NSMutableArray<UIView *> *QTSponsorGreenMarks;
static void QTSponsorClearGreenMarks(void) {
    for (UIView *v in QTSponsorGreenMarks) [v removeFromSuperview];
    [QTSponsorGreenMarks removeAllObjects];
}
static UIView *QTSponsorFindScrubber(UIView *root) {
    if (!root) return nil;
    // BFS for views that look like progress/scrubber (YT uses YTPlayerBar, YTInlinePlayerBar)
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    UIView *best = nil;
    CGFloat bestWidth = 0;
    while (queue.count) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        NSString *name = NSStringFromClass(v.class);
        if ([name containsString:@"Progress"] || [name containsString:@"Scrubber"] || [name containsString:@"PlayerBar"] || [name containsString:@"Seek"]) {
            if (v.bounds.size.width > bestWidth && v.bounds.size.width > 100 && v.bounds.size.height < 20) {
                bestWidth = v.bounds.size.width;
                best = v;
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return best;
}
static void QTSponsorUpdateGreenMarks(NSArray<NSDictionary *> *segments) {
    if (!segments.count) { QTSponsorClearGreenMarks(); return; }
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
    if (!win) return;
    UIView *scrubber = QTSponsorFindScrubber(win);
    if (!scrubber) {
        // Try again from keyWindow's root
        scrubber = QTSponsorFindScrubber(win.rootViewController.view);
    }
    if (!scrubber) return;
    // Need video duration - try to get from player
    AVPlayer *player = QTSponsorFindPlayer();
    NSTimeInterval duration = 0;
    if (player.currentItem) duration = CMTimeGetSeconds(player.currentItem.duration);
    if (!isfinite(duration) || duration < 1) {
        // Try first segment's videoDuration or fallback to 600
        for (NSDictionary *s in segments) { duration = [s[@"videoDuration"] doubleValue]; if (duration>1) break; }
        if (!isfinite(duration) || duration<1) duration = 600;
    }
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
                if (!player) return;
                NSTimeInterval cur = CMTimeGetSeconds(player.currentTime);
                if (!isfinite(cur)) return;
                NSNumber *target = QTSponsorSeekTargetForTime(cur, QTCurrentSegments);
                if (target) {
                    NSTimeInterval to = [target doubleValue];
                    [player seekToTime:CMTimeMakeWithSeconds(to, NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                    QTSponsorSkippedTotal++;
                    QTCount(@"sponsorSkip: segment skipped");
                    QTSponsorShowUndoToast(cur, to);
                    if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID) ?: @"none", @"result": @"skipped", @"start": @((long long)(cur*1000)), @"end": @((long long)(to*1000)), @"skipped": @(QTSponsorSkippedTotal)});
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
    QTHook(@"AVPlayer", @"seekToTime:", @"v@Q", ^id(IMP old, SEL sel) {
        return ^(id obj, long long time) {
            QTLastUserSeek = CACurrentMediaTime();
            if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"result": @"userskip", @"cached": @(1)});
            ((void (*)(id,SEL,long long))old)(obj, sel, time);
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
