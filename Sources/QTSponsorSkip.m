#import "QTSponsorSkip.h"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

NSString * const QTSponsorSkipEnabledKey = @"QuietTube.v1.sponsorSkip";
NSString * const QTSponsorSkipIntroOutroKey = @"QuietTube.v1.sponsorSkipIntroOutro";
NSString * const QTSponsorSkipSelfPromoKey = @"QuietTube.v1.sponsorSkipSelfPromo";
NSString * const QTSponsorSkipAPIURL = @"https://sponsor.ajay.app";

static NSUInteger QTSponsorSkippedTotal = 0;
static NSUInteger QTSponsorFetchCount = 0;
static NSUInteger QTSponsorCacheHits = 0;

// ytkace-style per-controller storage
static const void *QTSponsorSegmentsAssoc = &QTSponsorSegmentsAssoc;
static const void *QTSponsorVideoAssoc = &QTSponsorVideoAssoc;
static const void *QTSponsorSkippedAssoc = &QTSponsorSkippedAssoc;
static const void *QTSponsorMarkerAssoc = &QTSponsorMarkerAssoc;
static const void *QTSponsorRenderedAssoc = &QTSponsorRenderedAssoc;
static const void *QTSponsorBoundsAssoc = &QTSponsorBoundsAssoc;
static const void *QTSponsorDurationAssoc = &QTSponsorDurationAssoc;
static __weak id QTCurrentSponsorController;
static __weak id YTKACELastPlayerController;
static NSHashTable<UIView *> *QTSponsorBars;
static BOOL QTSponsorTimeUpdatesEnabled;

static NSCache<NSString *, NSArray *> *QTSponsorClientCache;
static NSURLSession *QTSponsorSession;

BOOL QTSponsorSkipEnabled(void) { return [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipEnabledKey]; }
BOOL QTSponsorSkipIntroOutroEnabled(void) { return QTSponsorSkipEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipIntroOutroKey]; }
BOOL QTSponsorSkipSelfPromoEnabled(void) { return QTSponsorSkipEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipSelfPromoKey]; }
BOOL QTSponsorCategoryEnabled(NSString *cat) {
    if ([cat isEqualToString:@"sponsor"]) return QTSponsorSkipEnabled();
    if ([cat isEqualToString:@"intro"] || [cat isEqualToString:@"outro"]) return QTSponsorSkipIntroOutroEnabled();
    if ([cat isEqualToString:@"selfpromo"]) return QTSponsorSkipSelfPromoEnabled();
    if ([cat isEqualToString:@"interaction"] || [cat isEqualToString:@"preview"] || [cat isEqualToString:@"music_offtopic"] || [cat isEqualToString:@"filler"] || [cat isEqualToString:@"hook"] || [cat isEqualToString:@"poi_highlight"]) return QTSponsorSkipEnabled();
    return NO;
}
static NSInteger QTSponsorCategoryBehavior(NSString *cat) {
    // 0 = skip, 1 = ask, 2 = hidden, 3 = disabled — we only auto-skip sponsor, others follow prefs
    if ([cat isEqualToString:@"sponsor"]) return 0;
    if ([cat isEqualToString:@"intro"] || [cat isEqualToString:@"outro"]) return QTSponsorSkipIntroOutroEnabled()?0:3;
    if ([cat isEqualToString:@"selfpromo"]) return QTSponsorSkipSelfPromoEnabled()?0:3;
    return QTSponsorSkipEnabled()?0:3;
}

NSString *QTSponsorHashForVideoID(NSString *vid) {
    if (!vid.length) return nil;
    NSData *d=[vid dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, h);
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hex appendFormat:@"%02x",h[i]];
    return hex;
}
NSString *QTSponsorPrefixForVideoID(NSString *vid){ NSString *h=QTSponsorHashForVideoID(vid); return h.length>=4?[h substringToIndex:4]:nil; }

static NSArray<NSString*> *QTSponsorEnabledCategories(void){
    NSMutableArray *cats=[NSMutableArray array];
    for (NSString *c in @[@"sponsor",@"intro",@"outro",@"selfpromo",@"interaction",@"preview",@"music_offtopic",@"filler",@"hook",@"poi_highlight"]){
        if (QTSponsorCategoryEnabled(c)) [cats addObject:c];
    }
    return cats;
}
static UIColor *QTSponsorColorForCategory(NSString *cat){
    if ([cat isEqualToString:@"intro"]) return [UIColor colorWithRed:0.24 green:0.58 blue:0.96 alpha:0.95];
    if ([cat isEqualToString:@"outro"]) return [UIColor colorWithRed:0.96 green:0.78 blue:0.18 alpha:0.95];
    if ([cat isEqualToString:@"selfpromo"]) return [UIColor colorWithRed:0.96 green:0.86 blue:0.18 alpha:0.95];
    if ([cat isEqualToString:@"interaction"]) return [UIColor colorWithRed:0.80 green:0.00 blue:1.00 alpha:0.95];
    if ([cat isEqualToString:@"music_offtopic"]) return [UIColor colorWithRed:1.00 green:0.60 blue:0.00 alpha:0.95];
    return [UIColor colorWithRed:0.10 green:0.78 blue:0.36 alpha:0.95];
}
NSArray<NSDictionary*> *QTSponsorFilteredSegments(NSArray<NSDictionary*> *segs){
    if (!segs) return @[];
    NSMutableArray *out=[NSMutableArray array];
    for (NSDictionary *s in segs){ NSString *c=s[@"category"]; if (c && QTSponsorCategoryEnabled(c)) [out addObject:s]; }
    return out;
}
NSNumber *QTSponsorSeekTargetForTime(NSTimeInterval t, NSArray<NSDictionary*> *segs){ return nil; } // legacy

static NSCache<NSString*,NSArray*> *QTSponsorClientCacheGet(void){
    static dispatch_once_t once; dispatch_once(&once, ^{ QTSponsorClientCache=[NSCache new]; QTSponsorClientCache.countLimit=128; });
    return QTSponsorClientCache;
}
static NSURLSession *QTSponsorSessionGet(void){
    static dispatch_once_t once; dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg=[NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest=10; cfg.timeoutIntervalForResource=15;
        cfg.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
        QTSponsorSession=[NSURLSession sessionWithConfiguration:cfg];
    });
    return QTSponsorSession;
}
static NSMutableDictionary<NSString*,NSArray*> *QTSponsorMemoryCache;
static NSString *QTCurrentVideoID;
static NSArray<NSDictionary*> *QTCurrentSegments;

static NSString *QTSponsorCachePath(NSString *vid){
    NSString *cache=NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cache) return nil;
    NSString *dir=[cache stringByAppendingPathComponent:@"QuietTube/SponsorSkip"];
    return [dir stringByAppendingPathComponent:[QTSponsorHashForVideoID(vid) stringByAppendingPathExtension:@"json"]];
}
void QTSponsorCacheStore(NSString *vid, NSArray<NSDictionary*> *segs){
    if (!vid || !segs) return;
    if (!QTSponsorMemoryCache) QTSponsorMemoryCache=[NSMutableDictionary dictionary];
    QTSponsorMemoryCache[vid]=segs;
    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"segments": @(segs.count), @"result": @"store", @"cached": @(1)});
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSString *path=QTSponsorCachePath(vid);
        if (!path) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
        NSDictionary *payload=@{@"videoID":vid, @"segments":segs, @"fetched":@([[NSDate date] timeIntervalSince1970])};
        NSData *d=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (d){ [d writeToFile:path options:NSDataWritingAtomic error:nil]; [[NSURL fileURLWithPath:path] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil]; }
    });
}
NSArray<NSDictionary*> *QTSponsorCacheLoad(NSString *vid){
    if (!vid) return nil;
    if (QTSponsorMemoryCache[vid]){ QTSponsorCacheHits++; return QTSponsorMemoryCache[vid]; }
    NSString *path=QTSponsorCachePath(vid);
    NSData *d=[NSData dataWithContentsOfFile:path]; if (!d) return nil;
    NSDictionary *j=[NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    NSTimeInterval f=[j[@"fetched"] doubleValue];
    if (f>0 && [[NSDate date] timeIntervalSince1970]-f > 7*24*60*60){ [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; return nil; }
    NSArray *segs=j[@"segments"];
    if ([segs isKindOfClass:NSArray.class]){ if (!QTSponsorMemoryCache) QTSponsorMemoryCache=[NSMutableDictionary dictionary]; QTSponsorMemoryCache[vid]=segs; QTSponsorCacheHits++; return segs; }
    return nil;
}
void QTSponsorCacheClear(void){ [QTSponsorMemoryCache removeAllObjects]; }

void QTSponsorFetch(NSString *vid, void (^completion)(NSArray<NSDictionary*> *segs)){
    if (!vid.length){ if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    NSArray<NSString*> *cats=QTSponsorEnabledCategories();
    if (!cats.count){ if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    NSString *cacheKey=[NSString stringWithFormat:@"%@|%@", vid, [cats componentsJoinedByString:@","]];
    NSArray *cached=[QTSponsorClientCacheGet() objectForKey:cacheKey];
    if (cached){ if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); }); return; }
    NSArray *mem=QTSponsorCacheLoad(vid);
    if (mem){
        NSMutableArray *filtered=[NSMutableArray array];
        for (NSDictionary *s in mem) if ([cats containsObject:s[@"category"]]) [filtered addObject:s];
        NSArray *sorted=[filtered sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){ return [a[@"start"] compare:b[@"start"]]; }];
        NSMutableArray *norm=[NSMutableArray array];
        for (NSDictionary *s in sorted){
            if (s[@"segment"] && s[@"start"]) [norm addObject:s];
            else if (s[@"start"] && s[@"end"]) [norm addObject:@{@"segment": @[s[@"start"], s[@"end"]], @"category": s[@"category"]?:@"sponsor", @"start": s[@"start"], @"end": s[@"end"]}];
            else [norm addObject:s];
        }
        [QTSponsorClientCacheGet() setObject:norm forKey:cacheKey];
        if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(norm); });
        // still refresh from network in background — mem may be stale
    }
    NSURLComponents *comp=[NSURLComponents componentsWithString:@"https://sponsor.ajay.app/api/skipSegments"];
    NSData *catData=[NSJSONSerialization dataWithJSONObject:cats options:0 error:nil];
    NSString *catJSON=catData?[[NSString alloc] initWithData:catData encoding:NSUTF8StringEncoding]:@"[]";
    comp.queryItems=@[[NSURLQueryItem queryItemWithName:@"videoID" value:vid], [NSURLQueryItem queryItemWithName:@"categories" value:catJSON]];
    NSURL *url=comp.URL;
    if (!url){ if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    QTSponsorFetchCount++;
    if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"result": @"start", @"cached": @(0), @"description": vid});
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod=@"GET"; [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __weak NSString *wvid=vid; __weak NSArray *wcats=cats;
    NSURLSessionDataTask *task=[QTSponsorSessionGet() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err){
        NSMutableArray *segs=[NSMutableArray array];
        NSHTTPURLResponse *http=[resp isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse*)resp:nil;
        if (!err && http.statusCode==200 && data.length<=1024*1024){
            id j=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j isKindOfClass:NSArray.class]){
                for (id item in (NSArray*)j){
                    if (![item isKindOfClass:NSDictionary.class]) continue;
                    NSString *cat=item[@"category"]; NSArray *seg=item[@"segment"]; NSString *act=item[@"actionType"];
                    if (![cat isKindOfClass:NSString.class] || ![wcats containsObject:cat] || (act && ![act isEqualToString:@"skip"]) || ![seg isKindOfClass:NSArray.class] || seg.count!=2) continue;
                    NSNumber *s=seg[0], *e=seg[1];
                    if (![s isKindOfClass:NSNumber.class] || ![e isKindOfClass:NSNumber.class]) continue;
                    double start=[s doubleValue], end=[e doubleValue];
                    if (!isfinite(start) || !isfinite(end) || start<0 || end<=start) continue;
                    [segs addObject:@{@"segment": @[@(start), @(end)], @"category": cat, @"start": @(start), @"end": @(end)}];
                }
            }
        }
        NSArray *result=[segs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){ return [a[@"start"] compare:b[@"start"]]; }];
        if (result.count) [QTSponsorClientCacheGet() setObject:result forKey:cacheKey];
        QTSponsorCacheStore(wvid, result);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL isCurrent=[wvid isEqualToString:QTCurrentVideoID];
            // per-controller storage like ytkace: update associated objects
            if (QTCurrentSponsorController){
                NSString *curVid=objc_getAssociatedObject(QTCurrentSponsorController, QTSponsorVideoAssoc);
                if ([curVid isEqualToString:wvid]){
                    objc_setAssociatedObject(QTCurrentSponsorController, QTSponsorSegmentsAssoc, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    objc_setAssociatedObject(QTCurrentSponsorController, QTSponsorSkippedAssoc, [NSMutableSet set], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
            if (isCurrent){
                QTCurrentSegments=result;
                for (UIView *bar in QTSponsorBars) [bar setNeedsLayout];
            }
            if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(wvid)?:@"none", @"result": @"success", @"segments": @(result.count), @"filtered": @(result.count), @"cached": @(0), @"status": @(http.statusCode), @"description": wvid});
            if (completion && isCurrent) completion(result);
        });
    }];
    [task resume];
}

// ytkace helpers
static id QTObjectMessage(id receiver, NSString *selName){
    SEL sel=NSSelectorFromString(selName);
    if (!receiver || ![receiver respondsToSelector:sel]) return nil;
    return ((id (*)(id,SEL))objc_msgSend)(receiver, sel);
}
static double QTDoubleMessage(id receiver, NSArray<NSString*> *sels){
    for (NSString *n in sels){
        SEL s=NSSelectorFromString(n);
        if ([receiver respondsToSelector:s]) return ((double (*)(id,SEL))objc_msgSend)(receiver, s);
    }
    return 0;
}
static NSString *QTVideoIDFromObject(id obj){
    if ([obj isKindOfClass:NSString.class]) return obj;
    for (NSString *sel in @[@"videoID", @"videoId", @"currentVideoID", @"identifier"]){
        id v=QTObjectMessage(obj, sel);
        if ([v isKindOfClass:NSString.class] && [v length]) return v;
    }
    id det=QTObjectMessage(obj, @"videoDetails");
    if (det && det!=obj) return QTVideoIDFromObject(det);
    // also try singleVideo/currentVideo
    for (NSString *sel in @[@"singleVideo", @"currentVideo", @"activeVideo", @"playerResponse"]){
        id sub=QTObjectMessage(obj, sel);
        if (sub && sub!=obj){
            NSString *vid=QTVideoIDFromObject(sub);
            if (vid.length==11) return vid;
        }
    }
    return nil;
}
static NSString *QTFindVideoIDViaGIMMe(void){
    Class gimme=NSClassFromString(@"GIMMe");
    for (NSString *selName in @[@"sharedInstance",@"sharedGIMMe"]){
        SEL sel=NSSelectorFromString(selName);
        if ([gimme respondsToSelector:sel]){
            @try{
                id inst=((id (*)(id,SEL))objc_msgSend)(gimme, sel);
                for (NSString *cSel in @[@"singleVideoController",@"watchController",@"playerViewController"]){
                    SEL cs=NSSelectorFromString(cSel);
                    if ([inst respondsToSelector:cs]){
                        @try{
                            id vc=((id (*)(id,SEL))objc_msgSend)(inst, cs);
                            NSString *vid=QTVideoIDFromObject(vc);
                            if (vid.length==11) return vid;
                            id sv=QTObjectMessage(vc, @"singleVideo");
                            vid=QTVideoIDFromObject(sv);
                            if (vid.length==11) return vid;
                        } @catch(__unused NSException *e){}
                    }
                }
            } @catch(__unused NSException *e){}
        }
    }
    return nil;
}
static NSString *QTFindVideoIDByScanningWindows(void){
    @try{
        for (UIWindow *w in [UIApplication sharedApplication].windows){
            NSMutableArray *queue=[NSMutableArray array];
            if (w.rootViewController) [queue addObject:w.rootViewController];
            NSMutableSet *seen=[NSMutableSet set];
            while (queue.count){
                UIViewController *vc=queue.firstObject; [queue removeObjectAtIndex:0];
                if (!vc || [seen containsObject:vc]) continue;
                [seen addObject:vc];
                NSString *vid=QTVideoIDFromObject(vc);
                if (vid.length==11) return vid;
                for (UIViewController *c in vc.childViewControllers) [queue addObject:c];
                if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
                if ([vc isKindOfClass:UINavigationController.class]){
                    UINavigationController *nav=(UINavigationController*)vc;
                    if (nav.visibleViewController) [queue addObject:nav.visibleViewController];
                }
                if ([vc isKindOfClass:UITabBarController.class]){
                    UITabBarController *tab=(UITabBarController*)vc;
                    if (tab.selectedViewController) [queue addObject:tab.selectedViewController];
                }
                @try{
                    UIResponder *r=vc.view.nextResponder;
                    while (r){ NSString *v2=QTVideoIDFromObject(r); if (v2.length==11) return v2; r=r.nextResponder; }
                } @catch(__unused NSException *e){}
            }
        }
    } @catch(__unused NSException *e){}
    return nil;
}
static void QTSeekToTime(id controller, double t){
    SEL sel=NSSelectorFromString(@"seekToTime:");
    if ([controller respondsToSelector:sel]){ ((void (*)(id,SEL,double))objc_msgSend)(controller, sel, t); return; }
    sel=NSSelectorFromString(@"scrubToTime:");
    if ([controller respondsToSelector:sel]){ ((void (*)(id,SEL,double))objc_msgSend)(controller, sel, t); return; }
    @try{ AVPlayer *p=[controller valueForKey:@"player"]; if([p isKindOfClass:AVPlayer.class]) [p seekToTime:CMTimeMakeWithSeconds(t,NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero]; } @catch(__unused NSException *e){}
}
static void QTEvaluateSponsorTime(id controller, double time){
    if (!QTSponsorSkipEnabled()) return;
    NSArray<NSDictionary*> *segments=objc_getAssociatedObject(controller, QTSponsorSegmentsAssoc);
    if (!segments.count) segments=QTCurrentSegments;
    if (!segments.count) return;
    NSMutableSet<NSNumber*> *skipped=objc_getAssociatedObject(controller, QTSponsorSkippedAssoc);
    if (!skipped){ skipped=[NSMutableSet set]; objc_setAssociatedObject(controller, QTSponsorSkippedAssoc, skipped, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    // Use a short dispatch queue delay to avoid re-entrant seek loops
    __block BOOL didSkip = NO;
    [segments enumerateObjectsUsingBlock:^(NSDictionary *seg, NSUInteger idx, BOOL *stop){
        if (didSkip) { *stop=YES; return; }
        double start=[seg[@"start"] doubleValue];
        if (!seg[@"start"]) start=[seg[@"segment"][0] doubleValue];
        double end=[seg[@"end"] doubleValue];
        if (!seg[@"end"]) end=[seg[@"segment"][1] doubleValue];
        if (!isfinite(start) || !isfinite(end) || end <= start) return;
        NSString *cat=seg[@"category"]?:@"sponsor";
        NSInteger behavior=QTSponsorCategoryBehavior(cat);
        if (behavior==2 || behavior==3) return;
        NSNumber *token=@(idx);
        if (time < start -1.0) [skipped removeObject:token];
        if (time >= start && time < end -0.4 && ![skipped containsObject:token]){
            [skipped addObject:token];
            didSkip = YES;
            // Seek slightly past segment end to avoid re-trigger on keyframe
            double target = end + 0.15;
            QTSeekToTime(controller, target);
            QTSponsorSkippedTotal++; QTCount(@"sponsorSkip: segment skipped");
            if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"prefix": QTCurrentVideoID?QTSponsorPrefixForVideoID(QTCurrentVideoID):@"none", @"result": @"skipped", @"category": cat, @"start": @((long long)(start*1000)), @"end": @((long long)(end*1000)), @"skipped": @(QTSponsorSkippedTotal)});
            // show Undo HUD
            dispatch_async(dispatch_get_main_queue(), ^{
                // minimal HUD — reuse existing banner if available
                UIViewController *top = nil;
                for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                    if (![sc isKindOfClass:UIWindowScene.class]) continue;
                    UIWindowScene *ws = (UIWindowScene*)sc;
                    if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                    for (UIWindow *w in ws.windows) if (w.isKeyWindow) { top = w.rootViewController; break; }
                    if (top) break;
                }
                while (top.presentedViewController) top = top.presentedViewController;
                if (!top.view.window) return;
                UIView *banner = [[UIView alloc] init];
                banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
                banner.layer.cornerRadius = 12; banner.translatesAutoresizingMaskIntoConstraints = NO;
                UILabel *lab = [UILabel new];
                lab.text = [NSString stringWithFormat:@"Skipped %@ (%.0fs)", cat, end-start];
                lab.textColor = UIColor.whiteColor; lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
                lab.translatesAutoresizingMaskIntoConstraints = NO;
                [banner addSubview:lab];
                [NSLayoutConstraint activateConstraints:@[
                    [lab.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10],
                    [lab.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14],
                    [lab.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-14],
                    [lab.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10],
                ]];
                banner.alpha = 0; banner.transform = CGAffineTransformMakeScale(0.96, 0.96);
                [top.view addSubview:banner];
                UILayoutGuide *safe = top.view.safeAreaLayoutGuide;
                [NSLayoutConstraint activateConstraints:@[
                    [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
                    [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54],
                ]];
                [UIView animateWithDuration:0.22 animations:^{ banner.alpha=1; banner.transform=CGAffineTransformIdentity; }];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.22 animations:^{ banner.alpha=0; banner.transform=CGAffineTransformMakeScale(0.96,0.96);} completion:^(__unused BOOL f){ [banner removeFromSuperview]; }];
                });
            });
            *stop=YES;
        }
    }];
}
static void QTRenderSponsorMarkers(UIView *receiver, UIView *target, BOOL fullHeight){
    if (!QTSponsorSkipEnabled() && !QTDEnabled()) return;
    id controller=QTCurrentSponsorController;
    NSArray *segments=objc_getAssociatedObject(controller, QTSponsorSegmentsAssoc);
    if (!segments.count) segments=QTCurrentSegments;
    segments=QTSponsorFilteredSegments(segments);
    if (!segments.count && !QTDEnabled()) {
        // hide any existing container
        CAShapeLayer *old = objc_getAssociatedObject(receiver, QTSponsorMarkerAssoc);
        old.hidden = YES;
        return;
    }
    CAShapeLayer *container=objc_getAssociatedObject(receiver, QTSponsorMarkerAssoc);
    if (!container){
        container=[CAShapeLayer layer];
        container.name=@"YTKACESponsorMarkers";
        objc_setAssociatedObject(receiver, QTSponsorMarkerAssoc, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (container.superlayer != target.layer){
        [container removeFromSuperlayer];
        [target.layer addSublayer:container];
    }
    container.frame=target.bounds;
    container.zPosition=10000;
    double duration=QTDoubleMessage(controller, @[@"currentVideoTotalMediaTime",@"currentVideoTotalTime",@"currentVideoDuration",@"totalMediaTime"]);
    if (duration<1) duration=78;
    BOOL enabled=QTSponsorSkipEnabled() && duration>0 && segments.count!=0;
    container.hidden=!enabled;
    if (!enabled) return;
    NSArray *rendered=objc_getAssociatedObject(receiver, QTSponsorRenderedAssoc);
    BOOL rebuild=rendered!=segments || container.sublayers.count!=segments.count;
    if (rebuild){
        [container.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
        for (NSDictionary *seg in segments){
            CALayer *m=[CALayer layer];
            NSString *cat=seg[@"category"]?:@"sponsor";
            m.backgroundColor=QTSponsorColorForCategory(cat).CGColor;
            m.zPosition=1;
            [container addSublayer:m];
        }
        objc_setAssociatedObject(receiver, QTSponsorRenderedAssoc, segments, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat width=target.bounds.size.width, height=target.bounds.size.height;
    if (width<10 || height<1) return;
    CGFloat trackThickness=2, trackOffset=MAX(0, height-2);
    if (!fullHeight){
        CGFloat measured=0, measuredOffset=0;
        // use ytkace track geometry
        CGFloat w=width;
        CGFloat bestW=0,bestH=0,bestY=0; BOOL found=NO;
        NSMutableArray *pending=[NSMutableArray arrayWithObject:target];
        NSUInteger visited=0;
        while (pending.count && visited<60){
            UIView *node=pending.firstObject; [pending removeObjectAtIndex:0]; visited++;
            if (node!=target && !node.hidden && node.alpha>0.05){
                CGRect f=[node convertRect:node.bounds toView:target];
                CGFloat nw=CGRectGetWidth(f), nh=CGRectGetHeight(f);
                if (nw >= w*0.55 && nh>0.5 && nh<=16){
                    BOOL better=!found;
                    if (!better && nw>bestW+2) better=YES;
                    else if (!better && nw>=bestW-2){
                        if (CGRectGetMinY(f)>bestY+0.5) better=YES;
                        else if (fabs(CGRectGetMinY(f)-bestY)<=0.5 && nh>bestH) better=YES;
                    }
                    if (better){ bestW=nw; bestH=nh; bestY=CGRectGetMinY(f); found=YES; }
                }
            }
            [pending addObjectsFromArray:node.subviews];
        }
        if (found){ trackThickness=bestH; trackOffset=bestY; }
    } else { trackThickness=height; trackOffset=0; }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (NSUInteger i=0;i<segments.count && i<container.sublayers.count;i++){
        NSDictionary *seg=segments[i];
        double s=[seg[@"start"] doubleValue]; if (!seg[@"start"]) s=[seg[@"segment"][0] doubleValue];
        double e=[seg[@"end"] doubleValue]; if (!seg[@"end"]) e=[seg[@"segment"][1] doubleValue];
        if (e>duration) e=duration;
        CALayer *m=container.sublayers[i];
        CGFloat x=(CGFloat)(s/duration)*width;
        CGFloat w=MAX(2, (CGFloat)((e-s)/duration)*width);
        if (x<0) x=0; if (x+w>width) w=width-x;
        m.frame=CGRectMake(x, trackOffset, w, trackThickness);
        m.cornerRadius=1;
    }
    [CATransaction commit];
}

void QTSponsorNotifyVideoIDChanged(NSString *vid){
    if (!vid.length || [vid isEqualToString:QTCurrentVideoID]) return;
    QTCurrentVideoID=[vid copy];
    QTCurrentSegments=@[];
    if (!QTSponsorSkipEnabled()){
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"result": @"disabled", @"cached": @(0)});
        return;
    }
    NSArray *cached=QTSponsorCacheLoad(vid);
    if (cached){
        QTCurrentSegments=cached;
        // also set per-controller
        if (QTCurrentSponsorController){
            objc_setAssociatedObject(QTCurrentSponsorController, QTSponsorSegmentsAssoc, cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(QTCurrentSponsorController, QTSponsorSkippedAssoc, [NSMutableSet set], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"result": @"hit", @"segments": @(cached.count), @"filtered": @(QTSponsorFilteredSegments(cached).count), @"cached": @(1)});
        for (UIView *bar in QTSponsorBars) [bar setNeedsLayout];
    } else {
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(vid)?:@"none", @"result": @"miss", @"cached": @(0)});
    }
    QTSponsorFetch(vid, ^(NSArray<NSDictionary*> *segs){
        QTCurrentSegments=segs?:@[];
        if (QTCurrentSponsorController){
            objc_setAssociatedObject(QTCurrentSponsorController, QTSponsorSegmentsAssoc, QTCurrentSegments, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (UIView *bar in QTSponsorBars) [bar setNeedsLayout];
    });
}

void QTSponsorInstall(void){
    if (!QTSponsorBars) QTSponsorBars=[NSHashTable weakObjectsHashTable];
    QTCount(@"sponsorSkip: installed");
    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"result": @"installed", @"cached": @(1)});
    QTSponsorTimeUpdatesEnabled=QTSponsorSkipEnabled();
    // hook installer — signature-agnostic, scans all classes for selector to handle 21.38.2 renames
    void (^tryHook)(NSString*,NSString*,id(^)(IMP,SEL)) = ^(NSString *clsName, NSString *selName, id (^factory)(IMP,SEL)){
        Class cls=NSClassFromString(clsName);
        SEL sel=NSSelectorFromString(selName);
        Method m=cls?class_getInstanceMethod(cls, sel):NULL;
        // if not found, scan all classes for that selector
        if (!m){
            unsigned int count=0;
            Class *list=objc_copyClassList(&count);
            for (unsigned int i=0;i<count;i++){
                Method cand=class_getInstanceMethod(list[i], sel);
                if (cand){
                    // also need class name contains YT or Player to avoid random
                    NSString *name=NSStringFromClass(list[i]);
                    if ([name containsString:@"YT"] || [name containsString:@"Player"]){
                        cls=list[i]; m=cand; break;
                    }
                }
            }
            free(list);
        }
        if (!m){
            if (QTDEnabled()) QTDEvent(QTDEHook, @{@"class":clsName, @"selector":selName, @"installed":@(0), @"description":@"no match"});
            return;
        }
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
                ((void (*)(id,SEL,id,id,id))old)(vc, sel, a1, a2, a3);
                QTCurrentSponsorController=vc;
                YTKACELastPlayerController=vc;
                NSString *vid=QTVideoIDFromObject(a2)?:QTVideoIDFromObject(a3)?:QTVideoIDFromObject(vc)?:QTVideoIDFromObject(a1)?:QTFindVideoIDViaGIMMe()?:QTFindVideoIDByScanningWindows();
                if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": vid?QTSponsorPrefixForVideoID(vid):@"none", @"result": vid.length==11?@"hook_vid":@"hook_novid", @"cached":@(0), @"description":[NSString stringWithFormat:@"a1=%@ a2=%@ a3=%@ vc=%@", NSStringFromClass([a1 class]), NSStringFromClass([a2 class]), NSStringFromClass([a3 class]), NSStringFromClass([vc class])]});
                if (vid.length==11){ 
                    objc_setAssociatedObject(vc, QTSponsorVideoAssoc, vid, OBJC_ASSOCIATION_COPY_NONATOMIC);
                    objc_setAssociatedObject(vc, QTSponsorSegmentsAssoc, @[], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    QTSponsorNotifyVideoIDChanged(vid);
                    // also fetch per-controller directly like ytkace
                    __weak id weakVC=vc;
                    NSString *copyVid=vid;
                    QTSponsorFetch(copyVid, ^(NSArray *segs){
                        id strong=weakVC;
                        NSString *cur=objc_getAssociatedObject(strong, QTSponsorVideoAssoc);
                        if (strong && [cur isEqualToString:copyVid]){
                            objc_setAssociatedObject(strong, QTSponsorSegmentsAssoc, segs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            for (UIView *bar in QTSponsorBars) [bar setNeedsLayout];
                        }
                    });
                }
            };
        });
        tryHook(@"YTPlayerViewController", @"singleVideo:currentVideoTimeDidChange:", ^id(IMP old, SEL sel){
            return ^(id vc, id vid, double t){
                ((void (*)(id,SEL,id,double))old)(vc, sel, vid, t);
                double cur=QTDoubleMessage(vc, @[@"currentVideoMediaTime"]);
                double res=cur>0?cur:t;
                if (QTSponsorTimeUpdatesEnabled) QTEvaluateSponsorTime(vc, res);
            };
        });
        tryHook(@"YTPlayerViewController", @"potentiallyMutatedSingleVideo:currentVideoTimeDidChange:", ^id(IMP old, SEL sel){
            return ^(id vc, id vid, double t){
                ((void (*)(id,SEL,id,double))old)(vc, sel, vid, t);
                double cur=QTDoubleMessage(vc, @[@"currentVideoMediaTime"]);
                double res=cur>0?cur:t;
                if (QTSponsorTimeUpdatesEnabled) QTEvaluateSponsorTime(vc, res);
                if (QTDEnabled() && res>0){
                    static NSTimeInterval last=0; if (CACurrentMediaTime()-last>5){ last=CACurrentMediaTime(); QTDEvent(QTDESponsorSkip, @{@"prefix": QTCurrentVideoID?QTSponsorPrefixForVideoID(QTCurrentVideoID):@"none", @"result": (objc_getAssociatedObject(vc,QTSponsorSegmentsAssoc)?@"tick":@"tick_noseg"), @"category":@"time", @"start":@((long long)(res*1000)), @"skipped":@(QTSponsorSkippedTotal)}); }
                }
            };
        });
        tryHook(@"YTSingleVideo", @"setCurrentTime:", ^id(IMP old, SEL sel){
            return ^(id o, double t){ ((void (*)(id,SEL,double))old)(o,sel,t); if (t>0 && QTCurrentSponsorController) QTEvaluateSponsorTime(QTCurrentSponsorController, t); };
        });
        tryHook(@"YTInlinePlayerBarContainerView", @"layoutSubviews", ^id(IMP old, SEL sel){
            return ^(id v){ ((void (*)(id,SEL))old)(v,sel); [QTSponsorBars addObject:v]; UIView *t=v; for (UIView *sub in ((UIView*)v).subviews) if ([NSStringFromClass(sub.class) isEqualToString:@"YTModularPlayerBarView"]) { t=sub; break; } QTRenderSponsorMarkers(v,t,NO); };
        });
        tryHook(@"YTWatchFloatingMiniplayerProgressBarView", @"layoutSubviews", ^id(IMP old, SEL sel){
            return ^(id v){ ((void (*)(id,SEL))old)(v,sel); [QTSponsorBars addObject:v]; QTRenderSponsorMarkers(v,v,YES); };
        });
        // also hook any other class that has the didActivate selector (21.38.2 moved it)
        // we already did scan in tryHook
    };
    install();
    for (NSNumber *d in @[@1,@3,@8]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ install(); });
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSTimer *poll=nil; if(poll) return;
        poll=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *t){
            if (!QTSponsorSkipEnabled()) return;
            if (!QTCurrentVideoID || !QTCurrentSponsorController){
                NSString *found=QTFindVideoIDViaGIMMe()?:QTFindVideoIDByScanningWindows();
                if (found.length==11 && ![found isEqualToString:QTCurrentVideoID]){
                    if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(found), @"result": @"poll_found", @"cached": @(0)});
                    QTSponsorNotifyVideoIDChanged(found);
                } else if (!found.length && QTDEnabled()){
                    static NSTimeInterval last=0; if (CACurrentMediaTime()-last>10){ last=CACurrentMediaTime(); QTDEvent(QTDESponsorFetch, @{@"prefix":@"none", @"result":@"poll_novid", @"cached":@(0)}); }
                }
            }
            if (QTCurrentSponsorController){
                double cur=QTDoubleMessage(QTCurrentSponsorController, @[@"currentVideoMediaTime"]);
                if (cur>0 && QTSponsorTimeUpdatesEnabled) QTEvaluateSponsorTime(QTCurrentSponsorController, cur);
            }
        }];
        @try{ NSString *f=QTFindVideoIDViaGIMMe()?:QTFindVideoIDByScanningWindows(); if (f.length==11) QTSponsorNotifyVideoIDChanged(f); } @catch(__unused NSException *e){}
    });
}
NSString *QTSponsorReport(void){
    return [NSString stringWithFormat:@"SponsorSkip: enabled=%@ introOutro=%@ selfPromo=%@ skipped=%lu fetches=%lu cacheHits=%lu currentPrefix=%@ segments=%lu\n", QTSponsorSkipEnabled()?@"on":@"off", QTSponsorSkipIntroOutroEnabled()?@"on":@"off", QTSponsorSkipSelfPromoEnabled()?@"on":@"off", (unsigned long)QTSponsorSkippedTotal, (unsigned long)QTSponsorFetchCount, (unsigned long)QTSponsorCacheHits, QTCurrentVideoID?(QTSponsorPrefixForVideoID(QTCurrentVideoID)?:@"none"):@"none", (unsigned long)(QTCurrentSegments.count ?: ((NSArray*)objc_getAssociatedObject(QTCurrentSponsorController, QTSponsorSegmentsAssoc)).count)];
}
NSUInteger QTSponsorSkippedCount(void){ return QTSponsorSkippedTotal; }
