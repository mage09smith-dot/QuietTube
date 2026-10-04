#import "QTSponsorEngine.h"
#import "QTSponsorSkip.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// ============ state ============
static NSString *QTECurrentVideoID;
static NSArray<NSDictionary*> *QTECurrentSegments; // filtered for current prefs
static NSArray<NSDictionary*> *QTERawSegments; // raw from SB
static NSMutableSet<NSNumber*> *QTESkippedTokens;
static __weak id QTEController;
static NSHashTable<UIView*> *QTEBars;
static NSUInteger QTEFetchCount, QTEHitCount, QTESkippedCount;
static NSTimer *QTEPollTimer;
static BOOL QTEEngineInstalled;

// ============ helpers ============
static BOOL QTEEnabled(void) { return QTSponsorSkipEnabled(); }

static id QTEObjMsg(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (!obj || ![obj respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(obj,s);
}
static double QTEDblMsg(id obj, NSArray<NSString*> *sels) {
    for (NSString *n in sels) {
        SEL s = NSSelectorFromString(n);
        if ([obj respondsToSelector:s]) return ((double(*)(id,SEL))objc_msgSend)(obj,s);
    }
    return 0;
}
static NSString *QTEVideoIDFromObj(id obj) {
    if ([obj isKindOfClass:NSString.class] && [(NSString*)obj length]==11) return obj;
    if ([obj isKindOfClass:NSString.class]) {
        // not 11 chars — not a videoID
    }
    for (NSString *sel in @[@"videoID",@"videoId",@"currentVideoID",@"identifier"]) {
        id v = QTEObjMsg(obj, sel);
        if ([v isKindOfClass:NSString.class] && [v length]==11) return v;
        if ([v isKindOfClass:NSString.class] && [v length]>0 && [v length]!=11) {
            // might be channel ID — skip
        }
    }
    id det = QTEObjMsg(obj, @"videoDetails");
    if (det && det!=obj) {
        NSString *r = QTEVideoIDFromObj(det);
        if (r) return r;
    }
    for (NSString *sel in @[@"singleVideo",@"currentVideo",@"activeVideo",@"playerResponse",@"currentVideo"]) {
        id sub = QTEObjMsg(obj, sel);
        if (sub && sub!=obj) {
            NSString *r = QTEVideoIDFromObj(sub);
            if (r) return r;
        }
    }
    return nil;
}
static NSString *QTEFindViaGIMMe(void) {
    Class gimme = NSClassFromString(@"GIMMe");
    for (NSString *selName in @[@"sharedInstance",@"sharedGIMMe"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![gimme respondsToSelector:sel]) continue;
        @try {
            id inst = ((id(*)(id,SEL))objc_msgSend)(gimme, sel);
            for (NSString *cSel in @[@"singleVideoController",@"watchController",@"playerViewController",@"activeVideoController"]) {
                SEL cs = NSSelectorFromString(cSel);
                if (![inst respondsToSelector:cs]) continue;
                @try {
                    id vc = ((id(*)(id,SEL))objc_msgSend)(inst, cs);
                    NSString *vid = QTEVideoIDFromObj(vc);
                    if (vid) return vid;
                    id sv = QTEObjMsg(vc, @"singleVideo");
                    vid = QTEVideoIDFromObj(sv);
                    if (vid) return vid;
                } @catch(__unused NSException *e) {}
            }
        } @catch(__unused NSException *e) {}
    }
    return nil;
}
// Last skipped segment for Undo
static NSDictionary *QTELastSkipped;
static double QTELastSkipFrom;
void QTEUndoLastSkip(void) {
    if (!QTELastSkipped || !QTEController) return;
    double start = [QTELastSkipped[@"start"] doubleValue];
    if (!QTELastSkipped[@"start"]) start = [QTELastSkipped[@"segment"][0] doubleValue];
    // Seek back to just before segment start
    double target = MAX(0, start - 0.6);
    id ctrl = QTEController;
    SEL sel = NSSelectorFromString(@"seekToTime:");
    if ([ctrl respondsToSelector:sel]) ((void(*)(id,SEL,double))objc_msgSend)(ctrl, sel, target);
    // Allow re-trigger suppression to expire
    if (QTESkippedTokens) [QTESkippedTokens removeObject:@([QTECurrentSegments indexOfObject:QTELastSkipped])];
    QTELastSkipped = nil;
    QTCount(@"sponsorSkip: undo");
}

static void QTESeekTo(id controller, double t) {
    SEL sel = NSSelectorFromString(@"seekToTime:");
    if ([controller respondsToSelector:sel]) { ((void(*)(id,SEL,double))objc_msgSend)(controller, sel, t); return; }
    sel = NSSelectorFromString(@"scrubToTime:");
    if ([controller respondsToSelector:sel]) { ((void(*)(id,SEL,double))objc_msgSend)(controller, sel, t); return; }
    @try {
        AVPlayer *p = [controller valueForKey:@"player"];
        if ([p isKindOfClass:AVPlayer.class]) [p seekToTime:CMTimeMakeWithSeconds(t, NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    } @catch(__unused NSException *e) {}
}

// ============ color ============
static UIColor *QTEColorForCategory(NSString *cat) {
    if ([cat isEqualToString:@"intro"]) return [UIColor colorWithRed:0.23 green:0.56 blue:0.99 alpha:0.92]; // blue
    if ([cat isEqualToString:@"outro"]) return [UIColor colorWithRed:0.99 green:0.68 blue:0.14 alpha:0.92]; // amber
    if ([cat isEqualToString:@"selfpromo"]) return [UIColor colorWithRed:0.99 green:0.86 blue:0.18 alpha:0.92]; // yellow
    if ([cat isEqualToString:@"interaction"]) return [UIColor colorWithRed:0.73 green:0.32 blue:0.99 alpha:0.92]; // purple
    if ([cat isEqualToString:@"preview"]) return [UIColor colorWithRed:0.30 green:0.85 blue:0.55 alpha:0.92];
    return [UIColor colorWithRed:0.09 green:0.80 blue:0.39 alpha:0.92]; // sponsor green
}
static NSString *QTELabelForCategory(NSString *cat) {
    if ([cat isEqualToString:@"sponsor"]) return @"Sponsor";
    if ([cat isEqualToString:@"intro"]) return @"Intro";
    if ([cat isEqualToString:@"outro"]) return @"Outro";
    if ([cat isEqualToString:@"selfpromo"]) return @"Self-promo";
    if ([cat isEqualToString:@"interaction"]) return @"Interaction";
    if ([cat isEqualToString:@"preview"]) return @"Preview";
    if ([cat isEqualToString:@"music_offtopic"]) return @"Music";
    return cat ?: @"Sponsor";
}

// ============ cache ============
static NSCache<NSString*,NSArray*> *QTECache;
static NSURLSession *QTESession;
static NSCache<NSString*,NSArray*> *QTECacheGet(void) {
    static dispatch_once_t once; dispatch_once(&once, ^{ QTECache=[NSCache new]; QTECache.countLimit=128; });
    return QTECache;
}
static NSURLSession *QTESessionGet(void) {
    static dispatch_once_t once; dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg=[NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest=12; cfg.timeoutIntervalForResource=20;
        cfg.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
        QTESession=[NSURLSession sessionWithConfiguration:cfg];
    });
    return QTESession;
}
static NSArray<NSString*> *QTEEnabledCategories(void) {
    NSMutableArray *cats=[NSMutableArray array];
    for (NSString *c in @[@"sponsor",@"intro",@"outro",@"selfpromo",@"interaction",@"preview",@"music_offtopic",@"filler",@"hook",@"poi_highlight"]) {
        if (QTSponsorCategoryEnabled(c)) [cats addObject:c];
    }
    return cats;
}

// ============ network ============
static void QTEFetch(NSString *vid, void (^completion)(NSArray *segs)) {
    if (!vid.length) { if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    NSArray<NSString*> *cats = QTEEnabledCategories();
    if (!cats.count) { if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", vid, [cats componentsJoinedByString:@","]];
    NSArray *cached = [QTECacheGet() objectForKey:cacheKey];
    if (cached) {
        QTEHitCount++;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }
    // Try disk cache
    NSString *path = nil;
    {
        NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (cache) path = [[cache stringByAppendingPathComponent:@"QuietTube/SponsorSkip"] stringByAppendingPathComponent:[QTSponsorHashForVideoID(vid) stringByAppendingPathExtension:@"json"]];
    }
    // --- disk cache: hydrate immediately, show greenline instantly ---
    BOOL hadDiskSegments = NO;
    NSData *diskData = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (diskData) {
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:diskData options:0 error:nil];
        NSArray *segs = j[@"segments"];
        NSTimeInterval fetched = [j[@"fetched"] doubleValue];
        if ([segs isKindOfClass:NSArray.class] && fetched>0 && [[NSDate date] timeIntervalSince1970]-fetched < 7*24*60*60) {
            NSMutableArray *filtered=[NSMutableArray array];
            for (NSDictionary *s in segs) if ([cats containsObject:s[@"category"]]) [filtered addObject:s];
            NSArray *sorted=[filtered sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){ return [a[@"start"] compare:b[@"start"]]; }];
            NSMutableArray *norm=[NSMutableArray array];
            for (NSDictionary *s in sorted) {
                if (s[@"segment"] && s[@"start"]) [norm addObject:s];
                else if (s[@"start"] && s[@"end"]) [norm addObject:@{@"segment":@[s[@"start"],s[@"end"]], @"category":s[@"category"]?:@"sponsor", @"start":s[@"start"], @"end":s[@"end"]}];
                else [norm addObject:s];
            }
            if (norm.count) {
                [QTECacheGet() setObject:norm forKey:cacheKey];
                hadDiskSegments = YES;
                QTEHitCount++;
                // hydrate engine state immediately so greenline appears without waiting for network
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([vid isEqualToString:QTECurrentVideoID]) {
                        QTECurrentSegments = norm;
                        QTERawSegments = norm;
                        for (UIView *b in QTEBars) [b setNeedsLayout];
                    }
                });
                if (completion) {
                    NSArray *copy = [norm copy];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(copy); });
                }
            }
        }
    }
    // --- network fetch with mirror fallback ---
    NSArray<NSString*> *mirrors = @[@"https://sponsor.ajay.app", @"https://sponsorblock.kavin.rocks", @"https://sb.ltn.fi"];
    __block NSInteger mirrorIdx = 0;
    __block void (^tryMirror)(void);
    NSString *wvid = vid; NSArray *wcats = cats;
    __block NSString *wPath = path;
    QTEFetchCount++;
    if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"result":@"start", @"cached":@(0)});
    tryMirror = ^{
        if (mirrorIdx >= (NSInteger)mirrors.count) {
            // all mirrors failed — keep disk if we had it, otherwise report empty
            if (!hadDiskSegments && completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
            return;
        }
        NSString *base = mirrors[mirrorIdx];
        NSURLComponents *comp=[NSURLComponents componentsWithString:[base stringByAppendingString:@"/api/skipSegments"]];
        NSData *catData=[NSJSONSerialization dataWithJSONObject:wcats options:0 error:nil];
        NSString *catJSON= catData ? [[NSString alloc] initWithData:catData encoding:NSUTF8StringEncoding] : @"[]";
        comp.queryItems=@[[NSURLQueryItem queryItemWithName:@"videoID" value:wvid], [NSURLQueryItem queryItemWithName:@"categories" value:catJSON]];
        NSURL *url=comp.URL;
        if (!url) { mirrorIdx++; tryMirror(); return; }
        NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod=@"GET"; [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
        NSURLSessionDataTask *task=[QTESessionGet() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err){
            NSHTTPURLResponse *http=[resp isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse*)resp:nil;
            NSInteger status = http.statusCode;
            if (!err && status==200 && data.length<=1024*1024) {
                id j=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSMutableArray *segs=[NSMutableArray array];
                if ([j isKindOfClass:NSArray.class]) {
                    for (id item in (NSArray*)j) {
                        if (![item isKindOfClass:NSDictionary.class]) continue;
                        NSString *cat=item[@"category"]; NSArray *seg=item[@"segment"]; NSString *act=item[@"actionType"];
                        if (![cat isKindOfClass:NSString.class] || ![wcats containsObject:cat] || (act && ![act isEqualToString:@"skip"]) || ![seg isKindOfClass:NSArray.class] || seg.count!=2) continue;
                        NSNumber *s=seg[0], *e=seg[1];
                        if (![s isKindOfClass:NSNumber.class] || ![e isKindOfClass:NSNumber.class]) continue;
                        double start=[s doubleValue], end=[e doubleValue];
                        if (!isfinite(start) || !isfinite(end) || start<0 || end<=start) continue;
                        [segs addObject:@{@"segment":@[@(start),@(end)], @"category":cat, @"start":@(start), @"end":@(end)}];
                    }
                }
                NSArray *result=[segs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){ return [a[@"start"] compare:b[@"start"]]; }];
                if (result.count) [QTECacheGet() setObject:result forKey:cacheKey];
                if (wvid && wPath) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
                        [[NSFileManager defaultManager] createDirectoryAtPath:wPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
                        NSDictionary *payload=@{@"videoID":wvid, @"segments":result, @"fetched":@([[NSDate date] timeIntervalSince1970])};
                        NSData *d=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
                        if (d) { [d writeToFile:wPath options:NSDataWritingAtomic error:nil]; [[NSURL fileURLWithPath:wPath] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil]; }
                    });
                }
                if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(wvid)?:@"none", @"result":@"success", @"segments":@(result.count), @"filtered":@(result.count), @"status":@(status)});
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![wvid isEqualToString:QTECurrentVideoID]) { if (completion) completion(result); return; }
                    // CRITICAL: don't clobber non-empty disk segments with empty network result
                    if (!result.count && hadDiskSegments && QTECurrentSegments.count>0) {
                        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(wvid)?:@"none", @"result":@"keep_disk", @"segments":@(QTECurrentSegments.count)});
                        if (completion) completion(QTECurrentSegments);
                        return;
                    }
                    QTERawSegments = result;
                    QTECurrentSegments = [QTSponsorFilteredSegments(result) count] ? QTSponsorFilteredSegments(result) : result;
                    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(wvid)?:@"none", @"result":@"store", @"segments":@(result.count), @"cached":@(0)});
                    for (UIView *bar in QTEBars) [bar setNeedsLayout];
                    if (completion) completion(result);
                });
                return;
            } else if (status==404) {
                if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(wvid)?:@"none", @"result":@"not_found", @"status":@(status)});
                // 404 is authoritative empty — video truly has no segments
                NSArray *empty=@[];
                if (wvid && wPath) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
                        NSDictionary *payload=@{@"videoID":wvid, @"segments":empty, @"fetched":@([[NSDate date] timeIntervalSince1970])};
                        NSData *d=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
                        if (d) [d writeToFile:wPath options:NSDataWritingAtomic error:nil];
                    });
                }
                // don't clobber disk if it had data — 404 may be per-mirror inconsistency
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (hadDiskSegments && QTECurrentSegments.count>0) {
                        if (completion) completion(QTECurrentSegments);
                        return;
                    }
                    QTERawSegments=@[]; QTECurrentSegments=@[];
                    for (UIView *bar in QTEBars) [bar setNeedsLayout];
                    if (completion) completion(@[]);
                });
                return;
            } else {
                // Cloudflare / timeout / 5xx — try next mirror
                if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(wvid)?:@"none", @"result":@"mirror_failed", @"status":@(status)});
                mirrorIdx++;
                tryMirror();
                return;
            }
        }];
        [task resume];
    };
    tryMirror();
}

// ============ skip logic ============
static void QTEEvaluate(id controller, double time) {
    if (!QTEEnabled()) return;
    NSArray *segments = QTECurrentSegments;
    if (!segments.count) return;
    if (!QTESkippedTokens) { QTESkippedTokens=[NSMutableSet set]; }
    // allow re-evaluation after seeking back
    __block BOOL didSkip=NO;
    [segments enumerateObjectsUsingBlock:^(NSDictionary *seg, NSUInteger idx, BOOL *stop){
        if (didSkip) { *stop=YES; return; }
        double start=[seg[@"start"] doubleValue];
        if (!seg[@"start"]) start=[seg[@"segment"][0] doubleValue];
        double end=[seg[@"end"] doubleValue];
        if (!seg[@"end"]) end=[seg[@"segment"][1] doubleValue];
        if (!isfinite(start) || !isfinite(end) || end<=start) return;
        NSString *cat=seg[@"category"]?:@"sponsor";
        NSNumber *token=@(idx);
        if (time < start - 1.0) [QTESkippedTokens removeObject:token];
        if (time >= start && time < end - 0.35 && ![QTESkippedTokens containsObject:token]) {
            [QTESkippedTokens addObject:token];
            didSkip=YES;
            double target = end + 0.12;
            QTELastSkipped = seg;
            QTELastSkipFrom = time;
            QTESeekTo(controller, target);
            QTESkippedCount++;
            QTCount(@"sponsorSkip: segment skipped");
            if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"prefix": QTECurrentVideoID?QTSponsorPrefixForVideoID(QTECurrentVideoID):@"none", @"result":@"skipped", @"category":cat, @"start":@((long long)(start*1000)), @"end":@((long long)(end*1000)), @"skipped":@(QTESkippedCount)});
            // HUD with Undo button
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *top=nil;
                for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                    if (![sc isKindOfClass:UIWindowScene.class]) continue;
                    UIWindowScene *ws=(UIWindowScene*)sc;
                    if (ws.activationState!=UISceneActivationStateForegroundActive) continue;
                    for (UIWindow *w in ws.windows) if (w.isKeyWindow) { top=w.rootViewController; break; }
                    if (top) break;
                }
                while (top.presentedViewController) top=top.presentedViewController;
                if (!top.view.window) return;
                UIView *banner=[[UIView alloc] init];
                banner.backgroundColor=[UIColor colorWithWhite:0.09 alpha:0.96];
                banner.layer.cornerRadius=13; banner.translatesAutoresizingMaskIntoConstraints=NO;
                banner.layer.shadowColor=UIColor.blackColor.CGColor; banner.layer.shadowOpacity=0.22; banner.layer.shadowRadius=8; banner.layer.shadowOffset=CGSizeMake(0, 4);
                UIStackView *stack=[[UIStackView alloc] init];
                stack.axis=UILayoutConstraintAxisHorizontal; stack.alignment=UIStackViewAlignmentCenter; stack.spacing=12;
                stack.translatesAutoresizingMaskIntoConstraints=NO;
                UILabel *lab=[UILabel new];
                lab.text=[NSString stringWithFormat:@"Skipped %@ (%.0fs)", QTELabelForCategory(cat), end-start];
                lab.textColor=UIColor.whiteColor; lab.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
                UIButton *undo=[UIButton buttonWithType:UIButtonTypeSystem];
                [undo setTitle:@"Undo" forState:UIControlStateNormal];
                undo.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightBold];
                [undo setTitleColor:[UIColor systemYellowColor] forState:UIControlStateNormal];
                undo.backgroundColor=[UIColor colorWithWhite:1 alpha:0.14]; undo.layer.cornerRadius=8;
                undo.contentEdgeInsets=UIEdgeInsetsMake(6, 12, 6, 12);
                [undo addTarget:nil action:@selector(QTEUndoTapped) forControlEvents:UIControlEventTouchUpInside];
                // Use block-based target via associated object
                objc_setAssociatedObject(undo, "banner", banner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [undo addAction:[UIAction actionWithTitle:@"" image:nil identifier:nil handler:^(__kindof UIAction *a){
                    UIView *b = objc_getAssociatedObject(a.sender, "banner");
                    [UIView animateWithDuration:0.18 animations:^{ b.alpha=0; } completion:^(__unused BOOL f){ [b removeFromSuperview]; }];
                    QTEUndoLastSkip();
                }] forControlEvents:UIControlEventTouchUpInside];
                [stack addArrangedSubview:lab];
                [stack addArrangedSubview:undo];
                [banner addSubview:stack];
                [NSLayoutConstraint activateConstraints:@[
                    [stack.topAnchor constraintEqualToAnchor:banner.topAnchor constant:9],
                    [stack.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14],
                    [stack.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-10],
                    [stack.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-9],
                ]];
                banner.alpha=0; banner.transform=CGAffineTransformMakeScale(0.96,0.96);
                [top.view addSubview:banner];
                UILayoutGuide *safe=top.view.safeAreaLayoutGuide;
                [NSLayoutConstraint activateConstraints:@[
                    [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
                    [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-56],
                    [banner.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
                    [banner.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],
                ]];
                [UIView animateWithDuration:0.22 animations:^{ banner.alpha=1; banner.transform=CGAffineTransformIdentity; }];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(4.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (banner.superview) [UIView animateWithDuration:0.22 animations:^{ banner.alpha=0; banner.transform=CGAffineTransformMakeScale(0.96,0.96);} completion:^(__unused BOOL f){ [banner removeFromSuperview]; }];
                });
            });
            *stop=YES;
        }
    }];
}

// ============ markers ============
static const void *QTEMarkerKey = &QTEMarkerKey;
static const void *QTERenderedKey = &QTERenderedKey;
static void QTERender(UIView *receiver, UIView *target, BOOL fullHeight) {
    if (!QTEEnabled()) {
        CAShapeLayer *old = objc_getAssociatedObject(receiver, QTEMarkerKey);
        old.hidden = YES; return;
    }
    NSArray *segments = QTECurrentSegments;
    if (!segments) segments = @[];
    // filtered already, but ensure
    segments = QTSponsorFilteredSegments(segments);
    CAShapeLayer *container = objc_getAssociatedObject(receiver, QTEMarkerKey);
    if (!container) {
        container=[CAShapeLayer layer];
        container.name=@"QuietTubeSponsorMarkers";
        objc_setAssociatedObject(receiver, QTEMarkerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (container.superlayer != target.layer) {
        [container removeFromSuperlayer];
        [target.layer addSublayer:container];
    }
    container.frame=target.bounds;
    container.zPosition=10000;
    id controller = QTEController;
    double duration = QTEDblMsg(controller, @[@"currentVideoTotalMediaTime",@"currentVideoTotalTime",@"currentVideoDuration",@"totalMediaTime"]);
    if (duration<1) {
        // try to get duration from current segments max end
        double maxEnd=0;
        for (NSDictionary *s in segments) { double e=[s[@"end"] doubleValue]; if (!s[@"end"]) e=[s[@"segment"][1] doubleValue]; if (e>maxEnd) maxEnd=e; }
        if (maxEnd>10) duration = maxEnd + 30; else duration = 600;
    }
    BOOL enabled = QTEEnabled() && duration>0 && segments.count>0;
    container.hidden = !enabled;
    if (!enabled) return;
    NSArray *rendered = objc_getAssociatedObject(receiver, QTERenderedKey);
    BOOL rebuild = rendered != segments || container.sublayers.count != segments.count;
    if (rebuild) {
        [container.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
        for (NSDictionary *seg in segments) {
            CALayer *m=[CALayer layer];
            NSString *cat=seg[@"category"]?:@"sponsor";
            m.backgroundColor=QTEColorForCategory(cat).CGColor;
            m.zPosition=1; m.cornerRadius=1.2;
            m.borderColor=[UIColor colorWithWhite:0 alpha:0.18].CGColor; m.borderWidth=0.5;
            m.shadowColor=QTEColorForCategory(cat).CGColor; m.shadowOpacity=0.35; m.shadowRadius=2; m.shadowOffset=CGSizeZero;
            [container addSublayer:m];
            // Add label for segments wide enough
            // label is added as sublayer only if width warrants it (done in layout pass)
        }
        objc_setAssociatedObject(receiver, QTERenderedKey, segments, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat width=target.bounds.size.width, height=target.bounds.size.height;
    if (width<10 || height<1) return;
    CGFloat thickness=3, offset=MAX(0, height-3);
    if (!fullHeight) {
        CGFloat w=width, bestW=0,bestH=0,bestY=0; BOOL found=NO;
        NSMutableArray *pending=[NSMutableArray arrayWithObject:target];
        NSUInteger visited=0;
        while (pending.count && visited<80) {
            UIView *node=pending.firstObject; [pending removeObjectAtIndex:0]; visited++;
            if (node!=target && !node.hidden && node.alpha>0.05) {
                CGRect f=[node convertRect:node.bounds toView:target];
                CGFloat nw=CGRectGetWidth(f), nh=CGRectGetHeight(f);
                if (nw >= w*0.50 && nh>0.5 && nh<=18) {
                    BOOL better=!found;
                    if (!better && nw>bestW+2) better=YES;
                    else if (!better && nw>=bestW-2) {
                        if (CGRectGetMinY(f)>bestY+0.5) better=YES;
                        else if (fabs(CGRectGetMinY(f)-bestY)<=0.5 && nh>bestH) better=YES;
                    }
                    if (better){ bestW=nw; bestH=nh; bestY=CGRectGetMinY(f); found=YES; }
                }
            }
            [pending addObjectsFromArray:node.subviews];
        }
        if (found){ thickness=bestH; offset=bestY; }
    } else { thickness=height; offset=0; }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (NSUInteger i=0;i<segments.count && i<container.sublayers.count;i++) {
        NSDictionary *seg=segments[i];
        double s=[seg[@"start"] doubleValue]; if (!seg[@"start"]) s=[seg[@"segment"][0] doubleValue];
        double e=[seg[@"end"] doubleValue]; if (!seg[@"end"]) e=[seg[@"segment"][1] doubleValue];
        if (e>duration) e=duration;
        CALayer *m=container.sublayers[i];
        CGFloat x=(CGFloat)(s/duration)*width;
        CGFloat w=MAX(2, (CGFloat)((e-s)/duration)*width);
        if (x<0) x=0; if (x+w>width) w=width-x;
        m.frame=CGRectMake(x, offset, w, thickness);
    }
    [CATransaction commit];
}

// ============ public ============
void QTSponsorEngineVideoChanged(NSString *vid) {
    if (!vid.length || [vid isEqualToString:QTECurrentVideoID]) return;
    QTECurrentVideoID=[vid copy];
    QTECurrentSegments=@[]; QTERawSegments=@[];
    QTESkippedTokens=[NSMutableSet set];
    if (!QTEEnabled()) {
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"result":@"disabled", @"cached":@(0)});
        for (UIView *b in QTEBars) [b setNeedsLayout];
        return;
    }
    if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"result":@"engine_miss", @"cached":@(0)});
    QTEFetch(vid, ^(NSArray *segs){
        QTERawSegments=segs?:@[];
        QTECurrentSegments= QTSponsorFilteredSegments(segs)?:@[];
        // fallback: if filtered empty but raw has sponsor, use raw sponsor
        if (!QTECurrentSegments.count && segs.count) {
            NSMutableArray *sponsorOnly=[NSMutableArray array];
            for (NSDictionary *s in segs) if ([s[@"category"] isEqualToString:@"sponsor"]) [sponsorOnly addObject:s];
            if (sponsorOnly.count) QTECurrentSegments=sponsorOnly;
        }
        for (UIView *b in QTEBars) [b setNeedsLayout];
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"result":@"engine_ready", @"segments":@(QTECurrentSegments.count), @"cached":@(0)});
    });
}

void QTSponsorEngineInstall(void) {
    if (QTEEngineInstalled) return;
    QTEEngineInstalled=YES;
    if (!QTEBars) QTEBars=[NSHashTable weakObjectsHashTable];
    QTCount(@"sponsorEngine: installed");
    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"result":@"engine_installed", @"cached":@(1)});

    void (^tryHook)(NSString*,NSString*,id(^)(IMP,SEL)) = ^(NSString *clsName, NSString *selName, id (^factory)(IMP,SEL)){
        Class cls=NSClassFromString(clsName);
        SEL sel=NSSelectorFromString(selName);
        Method m=cls?class_getInstanceMethod(cls, sel):NULL;
        if (!m) {
            unsigned int count=0; Class *list=objc_copyClassList(&count);
            for (unsigned int i=0;i<count;i++) {
                Method cand=class_getInstanceMethod(list[i], sel);
                if (cand) {
                    NSString *name=NSStringFromClass(list[i]);
                    if ([name containsString:@"YT"] || [name containsString:@"Player"]){
                        cls=list[i]; m=cand; break;
                    }
                }
            }
            free(list);
        }
        if (!m) return;
        const char *enc=method_getTypeEncoding(m);
        IMP old=method_getImplementation(m);
        IMP rep=imp_implementationWithBlock(factory(old, sel));
        if (!rep) return;
        if (!class_addMethod(cls, sel, rep, enc)) method_setImplementation(m, rep);
        QTDEvent(QTDEHook, @{@"class":NSStringFromClass(cls), @"selector":selName, @"installed":@(1)});
    };
    void (^install)(void)=^{
        tryHook(@"YTPlayerViewController", @"playbackController:didActivateVideo:withPlaybackData:", ^id(IMP old, SEL sel){
            return ^(id vc, id a1, id a2, id a3){
                ((void(*)(id,SEL,id,id,id))old)(vc,sel,a1,a2,a3);
                QTEController=vc;
                NSString *vid=QTEVideoIDFromObj(a2)?:QTEVideoIDFromObj(a3)?:QTEVideoIDFromObj(vc)?:QTEVideoIDFromObj(a1)?:QTEFindViaGIMMe();
                if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": vid?QTSponsorPrefixForVideoID(vid):@"none", @"result": vid.length==11?@"engine_hook_vid":@"engine_hook_novid", @"cached":@(0)});
                if (vid.length==11) QTSponsorEngineVideoChanged(vid);
            };
        });
        tryHook(@"YTPlayerViewController", @"singleVideo:currentVideoTimeDidChange:", ^id(IMP old, SEL sel){
            return ^(id vc, id vid, double t){
                ((void(*)(id,SEL,id,double))old)(vc,sel,vid,t);
                double cur=QTEDblMsg(vc, @[@"currentVideoMediaTime"]);
                double res=cur>0?cur:t;
                QTEEvaluate(vc, res);
                if (QTDEnabled() && res>0) {
                    static NSTimeInterval last=0; if (CACurrentMediaTime()-last>6){ last=CACurrentMediaTime(); QTDEvent(QTDESponsorSkip, @{@"prefix": QTECurrentVideoID?QTSponsorPrefixForVideoID(QTECurrentVideoID):@"none", @"result":(QTECurrentSegments.count?@"tick":@"tick_noseg"), @"category":@"time", @"start":@((long long)(res*1000)), @"skipped":@(QTESkippedCount)}); }
                }
            };
        });
        tryHook(@"YTPlayerViewController", @"potentiallyMutatedSingleVideo:currentVideoTimeDidChange:", ^id(IMP old, SEL sel){
            return ^(id vc, id vid, double t){
                ((void(*)(id,SEL,id,double))old)(vc,sel,vid,t);
                double cur=QTEDblMsg(vc, @[@"currentVideoMediaTime"]);
                double res=cur>0?cur:t;
                QTEEvaluate(vc, res);
            };
        });
        tryHook(@"YTSingleVideo", @"setCurrentTime:", ^id(IMP old, SEL sel){
            return ^(id o, double t){ ((void(*)(id,SEL,double))old)(o,sel,t); if (t>0 && QTEController) QTEEvaluate(QTEController, t); };
        });
        tryHook(@"YTInlinePlayerBarContainerView", @"layoutSubviews", ^id(IMP old, SEL sel){
            return ^(id v){ ((void(*)(id,SEL))old)(v,sel); [QTEBars addObject:v]; UIView *t=v; for (UIView *sub in ((UIView*)v).subviews) if ([NSStringFromClass(sub.class) isEqualToString:@"YTModularPlayerBarView"]) { t=sub; break; } QTERender(v,t,NO); };
        });
        tryHook(@"YTWatchFloatingMiniplayerProgressBarView", @"layoutSubviews", ^id(IMP old, SEL sel){
            return ^(id v){ ((void(*)(id,SEL))old)(v,sel); [QTEBars addObject:v]; QTERender(v,v,YES); };
        });
    };
    install();
    for (NSNumber *d in @[@1,@3,@8]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(d.doubleValue*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ install(); });
    dispatch_async(dispatch_get_main_queue(), ^{
        if (QTEPollTimer) return;
        QTEPollTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *t){
            if (!QTEEnabled()) return;
            if (!QTECurrentVideoID || !QTEController) {
                NSString *found=QTEFindViaGIMMe();
                if (found.length==11 && ![found isEqualToString:QTECurrentVideoID]) {
                    QTSponsorEngineVideoChanged(found);
                }
            }
            if (QTEController) {
                double cur=QTEDblMsg(QTEController, @[@"currentVideoMediaTime"]);
                if (cur>0) QTEEvaluate(QTEController, cur);
            }
        }];
        @try{ NSString *f=QTEFindViaGIMMe(); if (f.length==11) QTSponsorEngineVideoChanged(f); } @catch(__unused NSException *e){}
    });
}

NSString *QTSponsorEngineReport(void) {
    return [NSString stringWithFormat:@"SponsorEngine: enabled=%@ skipped=%lu fetches=%lu hits=%lu cur=%@ segs=%lu raw=%lu\n",
        QTEEnabled()?@"on":@"off", (unsigned long)QTESkippedCount, (unsigned long)QTEFetchCount, (unsigned long)QTEHitCount,
        QTECurrentVideoID?QTSponsorPrefixForVideoID(QTECurrentVideoID):@"none", (unsigned long)QTECurrentSegments.count, (unsigned long)QTERawSegments.count];
}
