#import "QTPlaybackFix.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import "QTStreamFallback.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Playback fix adapted from YTPlaybackFix (Mark02, MIT) + YTKACE (itzzace, MIT).
// Handles the "Something went wrong" PO-token / integrity stall that fires on
// sideloaded builds.  Does NOT depend on a separate VISION client; it does a
// local retry with stall detection.  HLS/VISION fallback is a separate concern
// and is NOT bundled here (requires JS solver).

static NSString * const QTPlaybackErrorDomain = @"com.google.ios.youtube.ErrorDomain.playback";

static IMP OrigCurrentVideoMediaTime;
static IMP OrigSeekToTime;
static IMP OrigHandleError;

static double QTLatestTime = 0;
static BOOL QTIsRetrying = NO;
static BOOL QTEmergencyRunning = NO;
static NSUInteger QTRetryCount = 0;
static NSUInteger QTFixStallRecovered = 0;
static NSUInteger QTFixEmergencyRetried = 0;

// forward
static void QTSendRetryEvent(id overlay, NSString *stage);
static BOOL QTReloadPlayer(id pvc, NSString *stage);
static void QTSeek(id player, double pos, NSString *stage);
static double QTPosition(id player);

static double QTCurrentVideoMediaTime(id self, SEL _cmd) {
    double v = OrigCurrentVideoMediaTime ? ((double(*)(id,SEL))OrigCurrentVideoMediaTime)(self,_cmd) : 0;
    QTLatestTime = v;
    return v;
}
static void QTSeekToTime(id self, SEL _cmd, double t) {
    QTLatestTime = t;
    if (OrigSeekToTime) ((void(*)(id,SEL,double))OrigSeekToTime)(self,_cmd,t);
}
static void QTCallOriginalHandleError(id self, SEL _cmd, id err) {
    if (OrigHandleError) ((void(*)(id,SEL,id))OrigHandleError)(self,_cmd,err);
}

static id QTParentResponder(id overlay) {
    SEL s = NSSelectorFromString(@"parentResponder");
    if (![overlay respondsToSelector:s]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(overlay, s);
}
static void QTSendRetryEvent(id overlay, NSString *stage) {
    id responder = QTParentResponder(overlay);
    if (!responder) return;
    Class ec = NSClassFromString(@"YTPlayerTapToRetryResponderEvent");
    SEL fac = NSSelectorFromString(@"eventWithFirstResponder:");
    if (!ec || ![ec respondsToSelector:fac]) return;
    id ev = ((id(*)(Class,SEL,id))objc_msgSend)(ec, fac, responder);
    SEL send = NSSelectorFromString(@"send");
    if (!ev || ![ev respondsToSelector:send]) return;
    ((void(*)(id,SEL))objc_msgSend)(ev, send);
    if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description": stage});
}
static BOOL QTReloadPlayer(id pvc, NSString *stage) {
    SEL ag = NSSelectorFromString(@"activeVideo");
    if (!pvc || ![pvc respondsToSelector:ag]) return NO;
    id video = ((id(*)(id,SEL))objc_msgSend)(pvc, ag);
    SEL reload = NSSelectorFromString(@"player:reloadWithContext:");
    SEL mediaGetter = NSSelectorFromString(@"mediaPlayer");
    Class ctxCls = NSClassFromString(@"MLPlayerReloadContext");
    SEL ctxInit = NSSelectorFromString(@"initWithStartPlayback:refreshStreamingData:");
    if (!video || !ctxCls || ![video respondsToSelector:reload] || ![video respondsToSelector:mediaGetter]) return NO;
    id alloc = [ctxCls alloc];
    if (![alloc respondsToSelector:ctxInit]) return NO;
    id ctx = ((id(*)(id,SEL,BOOL,BOOL))objc_msgSend)(alloc, ctxInit, YES, YES);
    if (!ctx) return NO;
    id media = ((id(*)(id,SEL))objc_msgSend)(video, mediaGetter);
    ((void(*)(id,SEL,id,id))objc_msgSend)(video, reload, media, ctx);
    if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description": stage});
    return YES;
}
static void QTSeek(id player, double pos, NSString *stage) {
    SEL s = NSSelectorFromString(@"seekToTime:");
    if (![player respondsToSelector:s]) return;
    ((void(*)(id,SEL,double))objc_msgSend)(player, s, pos);
    (void)stage;
}
static double QTPosition(id player) {
    SEL s = NSSelectorFromString(@"currentVideoMediaTime");
    if (![player respondsToSelector:s]) return -1;
    return ((double(*)(id,SEL))objc_msgSend)(player, s);
}

static void QTScheduleCaptionRestore(id player) {
    // YTKACE restores captions after a reload; QuietTube reuses the same hook if present.
    SEL sel = NSSelectorFromString(@"YTKACECaptionsRestore");
    // Try calling via runtime if YTKACE helper exists (no hard dep)
    __weak id wp = player;
    double delays[] = {0.6, 1.5, 3.0};
    for (int i=0;i<3;i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i]*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id p = wp; if (!p) return;
            // generic: if a CaptionsRestore function exists, call it via objc
            // otherwise no-op (harmless)
            if ([p respondsToSelector:sel]) ((void(*)(id,SEL))objc_msgSend)(p, sel);
        });
    }
}

static NSInteger QTErrorCodeForRetry(NSError *err) {
    if (!err || ![err.domain isEqualToString:QTPlaybackErrorDomain]) return -1;
    if (err.code==14 || err.code==0) return (NSInteger)err.code;
    // also retry code 5 (network) on sideload where PoToken caused stream failure
    if (err.code==5) return (NSInteger)err.code;
    return -1;
}
static void QTHandleError(id self, SEL _cmd, id error) {
    // Always observe — mirrors QTFeatures handleError semantics.
    QTDError(error);
    if ([error isKindOfClass:NSError.class]) {
        QTAdPlaybackError(error);
        NSString *kind = [((NSError*)error).domain isEqualToString:QTPlaybackErrorDomain] ? @"YouTube" : @"other";
        QTCount([NSString stringWithFormat:@"playback error %@ code %ld",kind,(long)((NSError*)error).code]);
    }
    NSError *err = [error isKindOfClass:NSError.class] ? error : nil;
    NSInteger retryCode = QTErrorCodeForRetry(err);
    if (retryCode==-1) {
        QTCallOriginalHandleError(self,_cmd,error);
        return;
    }
    // dedup: don't retry same error repeatedly within window
    if (QTIsRetrying) {
        QTCallOriginalHandleError(self,_cmd,error);
        return;
    }
    QTIsRetrying = YES;
    QTRetryCount++;

    SEL pg = NSSelectorFromString(@"parentViewController");
    id pvc = [self respondsToSelector:pg] ? ((id(*)(id,SEL))objc_msgSend)(self, pg) : nil;
    double saved = QTLatestTime;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        double moved = QTPosition(pvc);
        if (moved > saved + 0.15) {
            QTIsRetrying = NO;
            QTFixStallRecovered++;
            return;
        }
        // still stalled -> retry
        // snapshot captions if helper exists
        SEL snap = NSSelectorFromString(@"YTKACECaptionsSnapshot");
        if (pvc && [pvc respondsToSelector:snap]) ((void(*)(id,SEL))objc_msgSend)(pvc, snap);

        if (!QTReloadPlayer(pvc, @"primary")) QTSendRetryEvent(self, @"primary");
        if (pvc) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                QTSeek(pvc, saved, @"primary");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    QTScheduleCaptionRestore(pvc);
                    if (!QTEmergencyRunning) {
                        QTEmergencyRunning = YES;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            double cur = QTPosition(pvc);
                            if (cur <= saved + 0.05) {
                                QTFixEmergencyRetried++;
                                QTStreamFallbackHandleError(self, err, saved);
                                if (!QTReloadPlayer(pvc, @"emergency")) QTSendRetryEvent(self, @"emergency");
                                QTSeek(pvc, saved, @"emergency");
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    QTScheduleCaptionRestore(pvc);
                                    QTIsRetrying = NO;
                                });
                            } else {
                                QTIsRetrying = NO;
                            }
                            QTEmergencyRunning = NO;
                        });
                    }
                });
            });
        } else {
            QTIsRetrying = NO;
        }
    });
}

void QTInstallPlaybackFix(void) {
    // Install early — before YTMainAppVideoPlayerOverlayViewController is instantiated.
    Class pvc = NSClassFromString(@"YTPlayerViewController");
    if (pvc) {
        Method m = class_getInstanceMethod(pvc, NSSelectorFromString(@"currentVideoMediaTime"));
        if (m) { OrigCurrentVideoMediaTime = method_getImplementation(m); method_setImplementation(m, (IMP)QTCurrentVideoMediaTime); }
        Method m2 = class_getInstanceMethod(pvc, NSSelectorFromString(@"seekToTime:"));
        if (m2) { OrigSeekToTime = method_getImplementation(m2); method_setImplementation(m2, (IMP)QTSeekToTime); }
    } else {
        QTHook(@"YTPlayerViewController", @"currentVideoMediaTime", @"d", ^id(IMP old, SEL s){ OrigCurrentVideoMediaTime=old; return ^double(id o){ return QTCurrentVideoMediaTime(o,s); }; });
        QTHook(@"YTPlayerViewController", @"seekToTime:", @"v@d", ^id(IMP old, SEL s){ OrigSeekToTime=old; return ^(id o,double t){ QTSeekToTime(o,s,t); }; });
    }
    Class over = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    if (over) {
        Method m = class_getInstanceMethod(over, NSSelectorFromString(@"handleError:"));
        if (m) { OrigHandleError = method_getImplementation(m); method_setImplementation(m, (IMP)QTHandleError); }
    } else {
        QTHook(@"YTMainAppVideoPlayerOverlayViewController", @"handleError:", @"v@", ^id(IMP old, SEL s){ OrigHandleError=old; return ^(id o, id e){ QTHandleError(o,s,e); }; });
    }
    QTCount(@"playbackFix: installed");
}

NSString *QTPlaybackFixReport(void) {
    return [NSString stringWithFormat:@"PlaybackFix: retries=%lu stallRecovered=%lu emergency=%lu retrying=%@\n",
        (unsigned long)QTRetryCount, (unsigned long)QTFixStallRecovered, (unsigned long)QTFixEmergencyRetried, QTIsRetrying?@"yes":@"no"];
}
