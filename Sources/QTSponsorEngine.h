#import <Foundation/Foundation.h>
// QTSponsorEngine — ground-up SponsorSkip engine.
// Replaces the old QTSponsorSkip incremental patches.
// Single owner for: video detection, network, cache, skip, HUD, markers.

void QTSponsorEngineInstall(void);
void QTSponsorEngineVideoChanged(NSString *videoID);
NSString *QTSponsorEngineReport(void);
