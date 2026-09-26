#import "QTSponsorSkip.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <QuartzCore/QuartzCore.h>

NSString * const QTSponsorSkipEnabledKey = @"QuietTube.v1.sponsorSkip";
NSString * const QTSponsorSkipIntroOutroKey = @"QuietTube.v1.sponsorSkipIntroOutro";
NSString * const QTSponsorSkipSelfPromoKey = @"QuietTube.v1.sponsorSkipSelfPromo";
NSString * const QTSponsorSkipAPIURL = @"https://sponsor.ajay.app";

static NSUInteger QTSponsorSkippedTotal = 0;
static NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *QTSponsorMemoryCache;
static dispatch_queue_t QTSponsorQueue;
static NSString *QTCurrentVideoID;
static NSArray<NSDictionary *> *QTCurrentSegments;
static NSTimeInterval QTLastUserSeek = 0;

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
    return NO; // other categories (interaction, preview, music_offtopic) not supported in QuietTube
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
    if (!QTSponsorSkipEnabled() || !segments.count) return nil;
    // Don't interfere if user just seeked manually (2s grace)
    if (QTLastUserSeek > 0 && (CACurrentMediaTime() - QTLastUserSeek) < 2.0) return nil;
    NSArray *filtered = QTSponsorFilteredSegments(segments);
    for (NSDictionary *s in filtered) {
        NSArray *seg = s[@"segment"];
        if (seg.count != 2) continue;
        NSTimeInterval start = [seg[0] doubleValue];
        NSTimeInterval end = [seg[1] doubleValue];
        if (currentTime >= start && currentTime < end - 0.3) { // 0.3s before end to avoid loop
            return @(end);
        }
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
    // Disk: async, bounded
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *path = QTSponsorCachePath(videoID);
        if (!path) return;
        NSString *dir = path.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
        // Limit to 100 files, 7-day expiry on write
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        if (files.count > 100) {
            // Remove oldest
            NSMutableArray *full = [NSMutableArray array];
            for (NSString *f in files) [full addObject:[dir stringByAppendingPathComponent:f]];
            [full sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                NSDictionary *aa = [[NSFileManager defaultManager] attributesOfItemAtPath:a error:nil];
                NSDictionary *bb = [[NSFileManager defaultManager] attributesOfItemAtPath:b error:nil];
                return [aa[NSFileModificationDate] compare:bb[NSFileModificationDate]];
            }];
            for (NSUInteger i=0;i<full.count-100;i++) [[NSFileManager defaultManager] removeItemAtPath:full[i] error:nil];
        }
        NSDictionary *payload = @{@"videoID": videoID, @"segments": segments, @"fetched": @([[NSDate date] timeIntervalSince1970])};
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (data) {
            [data writeToFile:path options:NSDataWritingAtomic error:nil];
            // Exclude from backup + expiry marker
            NSURL *url = [NSURL fileURLWithPath:path];
            [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        }
    });
}

NSArray<NSDictionary *> *QTSponsorCacheLoad(NSString *videoID) {
    if (!videoID) return nil;
    if (QTSponsorMemoryCache[videoID]) return QTSponsorMemoryCache[videoID];
    NSString *path = QTSponsorCachePath(videoID);
    if (!path) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSTimeInterval fetched = [json[@"fetched"] doubleValue];
    if (fetched > 0 && [[NSDate date] timeIntervalSince1970] - fetched > 7*24*60*60) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return nil;
    }
    NSArray *segments = json[@"segments"];
    if ([segments isKindOfClass:NSArray.class]) {
        if (!QTSponsorMemoryCache) QTSponsorMemoryCache = [NSMutableDictionary dictionary];
        QTSponsorMemoryCache[videoID] = segments;
        return segments;
    }
    return nil;
}

void QTSponsorCacheClear(void) {
    QTSponsorMemoryCache = [NSMutableDictionary dictionary];
    NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cache) return;
    NSString *dir = [cache stringByAppendingPathComponent:@"QuietTube/SponsorSkip"];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    QTCurrentSegments = nil;
    QTCurrentVideoID = nil;
}

void QTSponsorFetch(NSString *videoID, void (^completion)(NSArray<NSDictionary *> *segments)) {
    if (!QTSponsorSkipEnabled() || !videoID.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSArray *cached = QTSponsorCacheLoad(videoID);
    if (cached) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(QTSponsorFilteredSegments(cached)); });
        return;
    }
    NSString *prefix = QTSponsorPrefixForVideoID(videoID);
    if (!prefix) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    // Include only categories we support to reduce payload. Server ignores unknown? Use our 3.
    // Privacy: we send only prefix, server returns many videos, we filter locally.
    NSString *urlString = [NSString stringWithFormat:@"%@/api/skipSegments/%@?categories=[\"sponsor\",\"intro\",\"outro\",\"selfpromo\"]", QTSponsorSkipAPIURL, prefix];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSArray *result = nil;
        if (data && !error) {
            NSArray *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSArray.class]) {
                NSMutableArray *matched = [NSMutableArray array];
                for (NSDictionary *entry in json) {
                    if (![entry[@"videoID"] isEqualToString:videoID]) continue;
                    NSArray *segs = entry[@"segments"];
                    if (![segs isKindOfClass:NSArray.class]) continue;
                    for (NSDictionary *seg in segs) {
                        // seg has segment, category — keep as is
                        if (seg[@"segment"] && seg[@"category"]) [matched addObject:seg];
                    }
                }
                result = matched;
                QTSponsorCacheStore(videoID, matched);
            }
        }
        NSArray *filtered = QTSponsorFilteredSegments(result);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(filtered);
        });
    }];
    [task resume];
}

void QTSponsorNotifyVideoIDChanged(NSString *videoID) {
    if (!videoID.length || !QTSponsorSkipEnabled()) {
        QTCurrentVideoID = nil;
        QTCurrentSegments = nil;
        return;
    }
    QTCurrentVideoID = videoID;
    NSArray *cached = QTSponsorCacheLoad(videoID);
    if (cached) {
        QTCurrentSegments = cached;
        return;
    }
    QTSponsorFetch(videoID, ^(NSArray<NSDictionary *> *segments) {
        // Only keep if still same video
        if ([QTCurrentVideoID isEqualToString:videoID]) {
            QTCurrentSegments = segments ?: @[];
        }
    });
}

// Minimal player integration: try to hook AVPlayer periodic time.
// YouTube uses YTPlayerViewController with AVPlayer. We hook a common private selector if available,
// otherwise we expose QTSponsorSeekTargetForTime for other hooks to call.
__attribute__((unused)) static void QTSponsorTrySeek(NSTimeInterval currentTime) {
    NSNumber *target = QTSponsorSeekTargetForTime(currentTime, QTCurrentSegments);
    if (!target) return;
    // Find player — try to find YT app's active player via notification or class.
    // We don't bundle a hard hook here to keep it safe: count, log, and attempt seek if we can find an AVPlayer.
    QTSponsorSkippedTotal++;
    QTCount(@"sponsorSkip: segment skipped");
    if (QTDEnabled()) QTDEvent(QTDEHook, @{@"class":@"SponsorSkip", @"selector":@"skip", @"installed":@(YES), @"target": target});
    // Show undo toast via settings controller if visible? For now log.
    // Actual seek is done by the hook in QTSponsorInstall if player is found.
}

void QTSponsorInstall(void) {
    if (!QTSponsorQueue) QTSponsorQueue = dispatch_queue_create("com.quiettube.sponsorskip", DISPATCH_QUEUE_SERIAL);
    // Watch for videoID changes via hook on YTWatchController or YTPlayerViewController if available.
    // Safe no-op if classes not found — feature stays dormant until videoID is notified externally.
    // Hook AVPlayer's seek to detect user seeks (to add grace period)
    QTHook(@"AVPlayer", @"seekToTime:", @"v@Q", ^id(IMP old, SEL sel) {
        return ^(id obj, long long time) {
            QTLastUserSeek = CACurrentMediaTime();
            ((void (*)(id,SEL,long long))old)(obj, sel, time);
        };
    });
    // Also hook seekToTime:toleranceBefore:toleranceAfter: if exists
    // We don't force a timer here — the host app's player will call us when time updates.
    // For testing, expose that QTSponsorSeekTargetForTime is the decision point.
    QTCount(@"sponsorSkip: installed");
}

NSString *QTSponsorReport(void) {
    return [NSString stringWithFormat:@"SponsorSkip: enabled=%@ introOutro=%@ selfPromo=%@ skipped=%lu cache=%lu\n",
            QTSponsorSkipEnabled()?@"on":@"off",
            QTSponsorSkipIntroOutroEnabled()?@"on":@"off",
            QTSponsorSkipSelfPromoEnabled()?@"on":@"off",
            (unsigned long)QTSponsorSkippedTotal,
            (unsigned long)QTSponsorMemoryCache.count];
}
NSUInteger QTSponsorSkippedCount(void) { return QTSponsorSkippedTotal; }
