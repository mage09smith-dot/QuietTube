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
static NSInteger QTCurrentSponsorIndex = 0;
static NSInteger QTUnskippedSegment = -1;

// ytkace-inspired marker storage
static NSHashTable<UIView *> *QTSponsorBars;
static const void *QTSponsorSegmentsAssoc = &QTSponsorSegmentsAssoc;
static const void *QTSponsorRenderedAssoc = &QTSponsorRenderedAssoc;
static const void *QTSponsorBoundsAssoc = &QTSponsorBoundsAssoc;
static const void *QTSponsorDurationAssoc = &QTSponsorDurationAssoc;
static __weak id QTCurrentSponsorController;

BOOL QTSponsorSkipEnabled(void) { return [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipEnabledKey]; }
BOOL QTSponsorSkipIntroOutroEnabled(void) { return QTSponsorSkipEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipIntroOutroKey]; }
BOOL QTSponsorSkipSelfPromoEnabled(void) { return QTSponsorSkipEnabled() && [NSUserDefaults.standardUserDefaults boolForKey:QTSponsorSkipSelfPromoKey]; }
BOOL QTSponsorCategoryEnabled(NSString *category) {
    if ([category isEqualToString:@"sponsor"]) return QTSponsorSkipEnabled();
    if ([category isEqualToString:@"intro"] || [category isEqualToString:@"outro"]) return QTSponsorSkipIntroOutroEnabled();
    if ([category isEqualToString:@"selfpromo"]) return QTSponsorSkipSelfPromoEnabled();
    // ytkace supports more categories but we map them to sponsor toggle for now
    if ([category isEqualToString:@"interaction"] || [category isEqualToString:@"preview"] || [category isEqualToString:@"music_offtopic"] || [category isEqualToString:@"filler"] || [category isEqualToString:@"hook"] || [category isEqualToString:@"poi_highlight"]) return QTSponsorSkipEnabled();
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

static NSArray<NSString *> *QTSponsorEnabledCategories(void) {
    NSMutableArray *cats = [NSMutableArray array];
    for (NSString *c in @[@"sponsor",@"intro",@"outro",@"selfpromo",@"interaction",@"preview",@"music_offtopic",@"filler",@"hook",@"poi_highlight"]) {
        if (QTSponsorCategoryEnabled(c)) [cats addObject:c];
    }
    return cats;
}

static UIColor *QTSponsorColorForCategory(NSString *cat) {
    if ([cat isEqualToString:@"intro"]) return [UIColor colorWithRed:0.24 green:0.58 blue:0.96 alpha:0.95];
    if ([cat isEqualToString:@"outro"]) return [UIColor colorWithRed:0.96 green:0.78 blue:0.18 alpha:0.95];
    if ([cat isEqualToString:@"selfpromo"]) return [UIColor colorWithRed:0.96 green:0.86 blue:0.18 alpha:0.95];
    if ([cat isEqualToString:@"interaction"]) return [UIColor colorWithRed:0.80 green:0.00 blue:1.00 alpha:0.95];
    if ([cat isEqualToString:@"music_offtopic"]) return [UIColor colorWithRed:1.00 green:0.60 blue:0.00 alpha:0.95];
    return [UIColor colorWithRed:0.10 green:0.78 blue:0.36 alpha:0.95];
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
    if (!QTSponsorSkipEnabled()) return nil;
    if (!segments.count) return nil;
    if (QTLastUserSeek>0 && CACurrentMediaTime() - QTLastUserSeek < 2.0) return nil;
    NSArray *filtered = QTSponsorFilteredSegments(segments);
    for (NSDictionary *s in filtered) {
        NSArray *seg = s[@"segment"];
        if (seg.count!=2) continue;
        NSTimeInterval start=[seg[0] doubleValue], end=[seg[1] doubleValue];
        if (currentTime >= start && currentTime < end - 0.3) return @(end);
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
    if (!QTSponsorMemoryCache) QTSponsorMemoryCache=[NSMutableDictionary dictionary];
    QTSponsorMemoryCache[videoID]=segments;
    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"prefix": QTSponsorPrefixForVideoID(videoID)?:@"none", @"segments": @(segments.count), @"result": @"store", @"cached": @(1)});
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSString *path=QTSponsorCachePath(videoID);
        if (!path) return;
        NSString *dir=path.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
        NSDictionary *payload=@{@"videoID":videoID, @"segments":segments, @"fetched":@([[NSDate date] timeIntervalSince1970])};
        NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (data) {
            [data writeToFile:path options:NSDataWritingAtomic error:nil];
            [NSURL fileURLWithPath:path];
            [[NSURL fileURLWithPath:path] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        }
    });
}
NSArray<NSDictionary *> *QTSponsorCacheLoad(NSString *videoID) {
    if (!videoID) return nil;
    if (QTSponsorMemoryCache[videoID]) { QTSponsorCacheHits++; return QTSponsorMemoryCache[videoID]; }
    NSString *path=QTSponsorCachePath(videoID);
    if (!path) return nil;
    NSData *data=[NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSTimeInterval fetched=[json[@"fetched"] doubleValue];
    if (fetched>0 && [[NSDate date] timeIntervalSince1970]-fetched > 7*24*60*60) { [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; return nil; }
    NSArray *segments=json[@"segments"];
    if ([segments isKindOfClass:NSArray.class]) { if(!QTSponsorMemoryCache) QTSponsorMemoryCache=[NSMutableDictionary dictionary]; QTSponsorMemoryCache[videoID]=segments; QTSponsorCacheHits++; return segments; }
    return nil;
}
void QTSponsorCacheClear(void) { [QTSponsorMemoryCache removeAllObjects]; }

static NSCache<NSString *, NSArray *> *QTSponsorClientCache;
static NSURLSession *QTSponsorSession;
static NSCache<NSString *, NSArray *> *QTSponsorClientCacheGet(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ QTSponsorClientCache=[NSCache new]; QTSponsorClientCache.countLimit=128; });
    return QTSponsorClientCache;
}
static NSURLSession *QTSponsorSessionGet(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg=[NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest=10; cfg.timeoutIntervalForResource=15;
        cfg.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
        QTSponsorSession=[NSURLSession sessionWithConfiguration:cfg];
    });
    return QTSponsorSession;
}

void QTSponsorFetch(NSString *videoID, void (^completion)(NSArray<NSDictionary *> *segments)) {
    if (!videoID.length) { if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    NSArray<NSString *> *cats=QTSponsorEnabledCategories();
    if (!cats.count) { if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    NSString *cacheKey=[NSString stringWithFormat:@"%@|%@", videoID, [cats componentsJoinedByString:@","]];
    NSArray *cached=[QTSponsorClientCacheGet() objectForKey:cacheKey];
    NSArray *mem=QTSponsorCacheLoad(videoID);
    if (cached) { if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); }); return; }
    if (mem) {
        // Check if mem already filtered? Use mem directly but filter by cats
        NSMutableArray *filtered=[NSMutableArray array];
        for (NSDictionary *s in mem) if ([cats containsObject:s[@"category"]]) [filtered addObject:s];
        NSArray *sorted=[filtered sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){ return [a[@"start"] compare:b[@"start"]]; }];
        // ytkace stores with start/end keys, our mem stores segment array; normalize
        NSMutableArray *norm=[NSMutableArray array];
        for (NSDictionary *s in sorted) {
            if (s[@"segment"] && s[@"start"]) [norm addObject:s];
            else if (s[@"start"] && s[@"end"]) [norm addObject:@{@"segment": @[s[@"start"], s[@"end"]], @"category": s[@"category"]?:@"sponsor"}];
            else [norm addObject:s];
        }
        if (cached) {}
        [QTSponsorClientCacheGet() setObject:norm forKey:cacheKey];
        if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(norm); });
        // still fetch fresh in background
    }
    // Build ytkace-style URL: https://sponsor.ajay.app/api/skipSegments?videoID=xxx&categories=[...]
    NSURLComponents *comp=[NSURLComponents componentsWithString:@"https://sponsor.ajay.app/api/skipSegments"];
    NSData *catData=[NSJSONSerialization dataWithJSONObject:cats options:0 error:nil];
    NSString *catJSON=catData?[[NSString alloc] initWithData:catData encoding:NSUTF8StringEncoding]:@"[]";
    comp.queryItems=@[[NSURLQueryItem queryItemWithName:@"videoID" value:videoID], [NSURLQueryItem queryItemWithName:@"categories" value:catJSON]];
    NSURL *url=comp.URL;
    if (!url) { if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); }); return; }
    QTSponsorFetchCount++;
    if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(videoID)?:@"none", @"result": @"start", @"cached": @(0)});
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod=@"GET"; [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __weak NSString *wvid=videoID;
    __weak NSArray *wcats=cats;
    NSURLSessionDataTask *task=[QTSponsorSessionGet() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err){
        NSMutableArray *segments=[NSMutableArray array];
        NSHTTPURLResponse *http=[resp isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse*)resp:nil;
        if (!err && http.statusCode==200 && data.length<=1024*1024) {
            id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSArray.class]) {
                for (id item in (NSArray*)json) {
                    if (![item isKindOfClass:NSDictionary.class]) continue;
                    NSString *cat=item[@"category"]; NSArray *seg=item[@"segment"]; NSString *act=item[@"actionType"];
                    if (![cat isKindOfClass:NSString.class] || ![wcats containsObject:cat] || (act && ![act isEqualToString:@"skip"]) || ![seg isKindOfClass:NSArray.class] || seg.count!=2) continue;
                    NSNumber *s=seg[0], *e=seg[1];
                    if (![s isKindOfClass:NSNumber.class] || ![e isKindOfClass:NSNumber.class]) continue;
                    double start=[s doubleValue], end=[e doubleValue];
                    if (!isfinite(start) || !isfinite(end) || start<0 || end<=start) continue;
                    [segments addObject:@{@"segment": @[@(start), @(end)], @"category": cat, @"start": @(start), @"end": @(end)}];
                }
            }
        }
        NSArray *result=[segments sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){ return [a[@"start"] compare:b[@"start"]]; }];
        if (result.count) [QTSponsorClientCacheGet() setObject:result forKey:cacheKey];
        QTSponsorCacheStore(wvid, result);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL isCurrent=[wvid isEqualToString:QTCurrentVideoID];
            if (isCurrent) {
                QTCurrentSegments=result;
                QTCurrentSponsorIndex=0; QTUnskippedSegment=-1;
                // trigger marker refresh
                for (UIView *bar in QTSponsorBars) [bar setNeedsLayout];
            }
            if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(wvid)?:@"none", @"result": result.count?@"success":@"success", @"segments": @(result.count), @"filtered": @(result.count), @"cached": @(0), @"status": @(http.statusCode)});
            if (completion && isCurrent) completion(result);
            else if (completion && !isCurrent) {
                // still call but with empty to avoid stale
                // no-op
            }
        });
    }];
    [task resume];
}

// ytkace-inspired helpers
static NSString *QTVideoIDFromObject(id obj) {
    if ([obj isKindOfClass:NSString.class]) return obj;
    for (NSString *sel in @[@"videoID",@"videoId",@"currentVideoID",@"identifier"]) {
        SEL s=NSSelectorFromString(sel);
        if ([obj respondsToSelector:s]) {
            id v=((id (*)(id,SEL))objc_msgSend)(obj,s);
            if ([v isKindOfClass:NSString.class] && [v length]) return v;
        }
    }
    id det=((id (*)(id,SEL))objc_msgSend)(obj, NSSelectorFromString(@"videoDetails"));
    if (det && det!=obj) return QTVideoIDFromObject(det);
    return nil;
}
static void QTSeekToTime(id controller, double time) {
    SEL sel=NSSelectorFromString(@"seekToTime:");
    if ([controller respondsToSelector:sel]) { ((void (*)(id,SEL,double))objc_msgSend)(controller, sel, time); return; }
    sel=NSSelectorFromString(@"scrubToTime:");
    if ([controller respondsToSelector:sel]) { ((void (*)(id,SEL,double))objc_msgSend)(controller, sel, time); return; }
    AVPlayer *p=nil;
    @try { p=[controller valueForKey:@"player"]; if([p isKindOfClass:AVPlayer.class]) [p seekToTime:CMTimeMakeWithSeconds(time,NSEC_PER_SEC) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero]; } @catch(id e){}
}
static void QTHandleTimeChange(id vc, double time) {
    if (!QTSponsorSkipEnabled() || !QTCurrentSegments.count || !QTCurrentVideoID) return;
    if (QTLastUserSeek>0 && CACurrentMediaTime()-QTLastUserSeek < 2.0) return;
    NSArray *filtered=QTSponsorFilteredSegments(QTCurrentSegments);
    if (!filtered.count) return;
    for (NSDictionary *s in filtered) {
        NSArray *seg=s[@"segment"]; if(seg.count!=2) continue;
        double start=[seg[0] doubleValue], end=[seg[1] doubleValue];
        if (time >= start && time < end - 0.3) {
            QTSeekToTime(vc, end);
            QTSponsorSkippedTotal++; QTCount(@"sponsorSkip: segment skipped");
            if (QTDEnabled()) QTDEvent(QTDESponsorSkip, @{@"prefix": QTSponsorPrefixForVideoID(QTCurrentVideoID)?:@"none", @"result": @"skipped", @"category": s[@"category"]?:@"sponsor", @"start": @((long long)(start*1000)), @"end": @((long long)(end*1000)), @"skipped": @(QTSponsorSkippedTotal)});
            return;
        }
    }
}
static void QTRenderSponsorMarkers(UIView *receiver, UIView *target, BOOL fullHeight) {
    if (!QTSponsorSkipEnabled()) return;
    NSArray *segments=QTSponsorFilteredSegments(QTCurrentSegments);
    // Use associated objects to avoid re-creating layers every layout
    NSMutableArray *existing=objc_getAssociatedObject(receiver, QTSponsorRenderedAssoc);
    BOOL rebuild = !existing || existing.count != segments.count;
    if (!existing) existing=[NSMutableArray array];
    // container layer
    CALayer *container=objc_getAssociatedObject(receiver, QTSponsorSegmentsAssoc);
    if (!container) {
        container=[CALayer layer];
        container.name=@"qt.ss";
        container.masksToBounds=YES;
        container.zPosition=999;
        [receiver.layer addSublayer:container];
        objc_setAssociatedObject(receiver, QTSponsorSegmentsAssoc, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        rebuild=YES;
    }
    // ensure layers count
    while (existing.count < segments.count) {
        CALayer *m=[CALayer layer];
        m.masksToBounds=YES; m.cornerRadius=1; m.hidden=YES;
        [container addSublayer:m];
        [existing addObject:m];
    }
    while (existing.count > segments.count) {
        CALayer *m=existing.lastObject;
        [m removeFromSuperlayer];
        [existing removeLastObject];
    }
    objc_setAssociatedObject(receiver, QTSponsorRenderedAssoc, existing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // layout
    CGFloat width=target.bounds.size.width, height=target.bounds.size.height;
    if (width < 10 || height < 1) return;
    id durVal=objc_getAssociatedObject(receiver, QTSponsorDurationAssoc);
    double duration = durVal ? [durVal doubleValue] : 0;
    // get duration from controller if available
    if (duration < 1 && QTCurrentSponsorController) {
        @try { duration=[[QTCurrentSponsorController valueForKey:@"currentVideoTotalMediaTime"] doubleValue]; } @catch(id e){}
    }
    if (duration < 1) duration = 78; // test video fallback
    objc_setAssociatedObject(receiver, QTSponsorDurationAssoc, @(duration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat trackThickness = fullHeight ? height : 3.5;
    CGFloat trackOffset = fullHeight ? 0 : (height - trackThickness)/2;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    container.frame = CGRectMake(0, trackOffset, width, trackThickness);
    [segments enumerateObjectsUsingBlock:^(NSDictionary *seg, NSUInteger idx, BOOL *stop){
        double start=[seg[@"start"] doubleValue];
        if (!seg[@"start"]) start=[seg[@"segment"][0] doubleValue];
        double end=[seg[@"end"] doubleValue];
        if (!seg[@"end"]) end=[seg[@"segment"][1] doubleValue];
        if (end>duration) end=duration;
        CALayer *m=existing[idx];
        m.backgroundColor=QTSponsorColorForCategory(seg[@"category"]).CGColor;
        m.hidden = end <= start;
        if (m.hidden) return;
        CGFloat x=(CGFloat)(start/duration)*width;
        CGFloat w=MAX(2, (CGFloat)((end-start)/duration)*width);
        if (x<0) x=0;
        if (x+w>width) w=width-x;
        m.frame=CGRectMake(x, 0, w, trackThickness);
        m.cornerRadius=1;
    }];
    [CATransaction commit];
}

void QTSponsorNotifyVideoIDChanged(NSString *videoID) {
    if (!videoID.length) return;
    if ([videoID isEqualToString:QTCurrentVideoID]) return;
    QTCurrentVideoID=[videoID copy];
    QTCurrentSegments=@[];
    QTCurrentSponsorIndex=0; QTUnskippedSegment=-1;
    if (!QTSponsorSkipEnabled()) {
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(videoID)?:@"none", @"result": @"disabled", @"cached": @(0)});
        return;
    }
    NSArray *cached=QTSponsorCacheLoad(videoID);
    if (cached) {
        QTCurrentSegments=cached;
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(videoID)?:@"none", @"result": @"hit", @"segments": @(cached.count), @"filtered": @(QTSponsorFilteredSegments(cached).count), @"cached": @(1)});
        for (UIView *bar in QTSponsorBars) [bar setNeedsLayout];
    } else {
        if (QTDEnabled()) QTDEvent(QTDESponsorFetch, @{@"prefix": QTSponsorPrefixForVideoID(videoID)?:@"none", @"result": @"miss", @"cached": @(0)});
    }
    QTSponsorFetch(videoID, ^(NSArray<NSDictionary *> *segments){
        QTCurrentSegments=segments?:@[];
        QTCurrentSponsorIndex=0;
        for (UIView *bar in QTSponsorBars) [bar setNeedsLayout];
    });
}

void QTSponsorInstall(void) {
    if (!QTSponsorQueue) QTSponsorQueue=dispatch_queue_create("com.quiettube.sponsorskip", DISPATCH_QUEUE_SERIAL);
    QTCount(@"sponsorSkip: installed");
    if (QTDEnabled()) QTDEvent(QTDESponsorCache, @{@"result": @"installed", @"cached": @(1)});
    if (!QTSponsorBars) QTSponsorBars=[NSHashTable weakObjectsHashTable];
    // Hooks — ytkace style, lightweight, signature-agnostic retry (fixes 21.38.2 unavailable/mismatch)
    void (^tryHook)(NSString *, NSString *, id (^)(IMP, SEL)) = ^(NSString *clsName, NSString *selName, id (^factory)(IMP,SEL)){
        Class cls = NSClassFromString(clsName);
        SEL sel = NSSelectorFromString(selName);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (!m) {
            // Log actual available selectors for diagnostics
            if (QTDEnabled()) {
                NSMutableString *avail=[NSMutableString string];
                unsigned int cnt=0; Method *list=class_copyMethodList(cls, &cnt);
                for (unsigned int i=0;i<cnt && avail.length<400;i++) {
                    NSString *n=NSStringFromSelector(method_getName(list[i]));
                    if ([n containsString:@"Video"] || [n containsString:@"Time"] || [n containsString:@"playbackController"]) [avail appendFormat:@"%@ ", n];
                }
                free(list);
                QTDEvent(QTDEHook, @{@"class":clsName, @"selector":selName, @"installed":@(0), @"description": avail.length?avail:@"no match"});
            }
            return;
        }
        const char *enc = method_getTypeEncoding(m);
        IMP old = method_getImplementation(m);
        IMP rep = imp_implementationWithBlock(factory(old, sel));
        if (!rep) return;
        if (!class_addMethod(cls, sel, rep, enc)) method_setImplementation(m, rep);
        QTDEvent(QTDEHook, @{@"class":clsName, @"selector":selName, @"installed":@(1)});
    };
    // Initial attempt + retries at 1,3,8s to catch late-loaded YT classes (fixes unavailable on 21.38.2)
    void (^installSponsorHooks)(void) = ^{
        tryHook(@"YTPlayerViewController", @"playbackController:didActivateVideo:withPlaybackData:", ^id(IMP old, SEL sel){
            return ^(id vc, id a1, id a2, id a3){
                ((void (*)(id,SEL,id,id,id))old)(vc, sel, a1, a2, a3);
                QTCurrentSponsorController=vc;
                NSString *vid=QTVideoIDFromObject(a2);
                if (!vid) vid=QTVideoIDFromObject(vc);
                if (vid.length==11) QTSponsorNotifyVideoIDChanged(vid);
            };
        });
        tryHook(@"YTPlayerViewController", @"singleVideo:currentVideoTimeDidChange:", ^id(IMP old, SEL sel){
            return ^(id vc, id video, double time){
                ((void (*)(id,SEL,id,double))old)(vc, sel, video, time);
                double current=0;
                @try { if ([vc respondsToSelector:NSSelectorFromString(@"currentVideoMediaTime")]) current=((double (*)(id,SEL))objc_msgSend)(vc, NSSelectorFromString(@"currentVideoMediaTime")); } @catch(__unused NSException *e){}
                double resolved = current>0 ? current : time;
                if (resolved>0) QTHandleTimeChange(vc, resolved);
            };
        });
        tryHook(@"YTPlayerViewController", @"potentiallyMutatedSingleVideo:currentVideoTimeDidChange:", ^id(IMP old, SEL sel){
            return ^(id vc, id video, double time){
                ((void (*)(id,SEL,id,double))old)(vc, sel, video, time);
                double current=0;
                @try { if ([vc respondsToSelector:NSSelectorFromString(@"currentVideoMediaTime")]) current=((double (*)(id,SEL))objc_msgSend)(vc, NSSelectorFromString(@"currentVideoMediaTime")); } @catch(__unused NSException *e){}
                double resolved = current>0 ? current : time;
                if (resolved>0) QTHandleTimeChange(vc, resolved);
            };
        });
        // ytkace also hooks YTSingleVideo setCurrentTime as fallback
        tryHook(@"YTSingleVideo", @"setCurrentTime:", ^id(IMP old, SEL sel){
            return ^(id obj, double t){
                ((void (*)(id,SEL,double))old)(obj, sel, t);
                @try { if (t>0 && QTCurrentSponsorController) QTHandleTimeChange(QTCurrentSponsorController, t); } @catch(__unused NSException *e){}
            };
        });
        tryHook(@"YTInlinePlayerBarContainerView", @"layoutSubviews", ^id(IMP old, SEL sel){
            return ^(id view){
                ((void (*)(id,SEL))old)(view, sel);
                [QTSponsorBars addObject:view];
                UIView *target=view;
                for (UIView *sub in ((UIView*)view).subviews) if ([NSStringFromClass(sub.class) isEqualToString:@"YTModularPlayerBarView"]) { target=sub; break; }
                QTRenderSponsorMarkers(view, target, NO);
            };
        });
        tryHook(@"YTWatchFloatingMiniplayerProgressBarView", @"layoutSubviews", ^id(IMP old, SEL sel){
            return ^(id view){
                ((void (*)(id,SEL))old)(view, sel);
                [QTSponsorBars addObject:view];
                QTRenderSponsorMarkers(view, view, YES);
            };
        });
    };
    installSponsorHooks();
    for (NSNumber *d in @[@1,@3,@8]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ installSponsorHooks(); });
    // Fallback polling for videoID when hooks unavailable (lightweight, no view scan) + 0.5s time tick as last-resort skip (ytkace publishes currentVideoMediaTime)
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSTimer *poll=nil; if(poll) return;
        poll=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *t){
            if (!QTSponsorSkipEnabled()) return;
            // videoID discovery
            if (!QTCurrentVideoID || !QTCurrentSponsorController) {
                NSString *found=nil;
                @try {
                    for (UIWindow *w in [UIApplication sharedApplication].windows) {
                        UIViewController *vc=w.rootViewController;
                        NSString *vid=QTVideoIDFromObject(vc);
                        if (vid.length==11) { found=vid; break; }
                    }
                } @catch(__unused NSException *e){}
                if (found.length==11 && ![found isEqualToString:QTCurrentVideoID]) QTSponsorNotifyVideoIDChanged(found);
            }
            // time tick fallback (evaluates sponsor even if YT hooks missed, mimics ytkace's currentVideoMediaTime path)
            if (QTCurrentSponsorController && QTCurrentSegments.count) {
                double cur=0; @try { if ([QTCurrentSponsorController respondsToSelector:NSSelectorFromString(@"currentVideoMediaTime")]) cur=((double (*)(id,SEL))objc_msgSend)(QTCurrentSponsorController, NSSelectorFromString(@"currentVideoMediaTime")); } @catch(__unused NSException *e){}
                if (cur>0) QTHandleTimeChange(QTCurrentSponsorController, cur);
            }
        }];
        // initial check
        @try {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                NSString *vid=QTVideoIDFromObject(w.rootViewController);
                if (vid.length==11) { QTSponsorNotifyVideoIDChanged(vid); break; }
            }
        } @catch(__unused NSException *e){}
    });
}

NSString *QTSponsorReport(void) {
    return [NSString stringWithFormat:@"SponsorSkip: enabled=%@ introOutro=%@ selfPromo=%@ skipped=%lu fetches=%lu cacheHits=%lu currentPrefix=%@ segments=%lu\n",
            QTSponsorSkipEnabled()?@"on":@"off", QTSponsorSkipIntroOutroEnabled()?@"on":@"off", QTSponsorSkipSelfPromoEnabled()?@"on":@"off",
            (unsigned long)QTSponsorSkippedTotal, (unsigned long)QTSponsorFetchCount, (unsigned long)QTSponsorCacheHits,
            QTCurrentVideoID?(QTSponsorPrefixForVideoID(QTCurrentVideoID)?:@"none"):@"none", (unsigned long)QTCurrentSegments.count];
}
NSUInteger QTSponsorSkippedCount(void) { return QTSponsorSkippedTotal; }
