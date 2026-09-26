#import <Foundation/Foundation.h>

// QuietTube SponsorSkip — SponsorBlock integration, hash-private, off by default.
// No network when disabled. When enabled, fetches via 4-char SHA256 prefix.

extern NSString * const QTSponsorSkipEnabledKey; // QuietTube.v1.sponsorSkip
extern NSString * const QTSponsorSkipIntroOutroKey; // QuietTube.v1.sponsorSkipIntroOutro
extern NSString * const QTSponsorSkipSelfPromoKey; // QuietTube.v1.sponsorSkipSelfPromo
extern NSString * const QTSponsorSkipAPIURL; // https://sponsor.ajay.app

BOOL QTSponsorSkipEnabled(void);
BOOL QTSponsorSkipIntroOutroEnabled(void);
BOOL QTSponsorSkipSelfPromoEnabled(void);

// Hash a videoID with SHA256 and return lowercased hex string
NSString *QTSponsorHashForVideoID(NSString *videoID);
// First 4 hex chars of hash
NSString *QTSponsorPrefixForVideoID(NSString *videoID);

// Category mapping: SponsorBlock categories -> QuietTube toggles
// "sponsor" is always controlled by master. "intro"/"outro" by introOutro, "selfpromo" by selfPromo.
BOOL QTSponsorCategoryEnabled(NSString *category);

// Filter segments for current settings. Input: array of dicts {segment: [start,end], category: string}
// Returns filtered array (only enabled categories)
NSArray<NSDictionary *> *QTSponsorFilteredSegments(NSArray<NSDictionary *> *segments);

// Given currentTime and filtered segments, returns @(seekTo) if should skip, else nil.
// Segments are {segment: @[@(start), @(end)], category: @"sponsor"} with times in seconds.
NSNumber *QTSponsorSeekTargetForTime(NSTimeInterval currentTime, NSArray<NSDictionary *> *segments);

// Cache
void QTSponsorCacheStore(NSString *videoID, NSArray<NSDictionary *> *segments);
NSArray<NSDictionary *> *QTSponsorCacheLoad(NSString *videoID);
void QTSponsorCacheClear(void);

// Network (hash-private). Calls completion on main queue with filtered segments or nil on error.
// Uses 4-char prefix: GET https://sponsor.ajay.app/api/skipSegments/<prefix>
// Client filters for exact videoID locally.
void QTSponsorFetch(NSString *videoID, void (^completion)(NSArray<NSDictionary *> *segments));

// Install player time observer (called once at launch if enabled). Safe to call even when disabled.
void QTSponsorInstall(void);
void QTSponsorNotifyVideoIDChanged(NSString *videoID);

// For diagnostics
NSString *QTSponsorReport(void);
NSUInteger QTSponsorSkippedCount(void);
