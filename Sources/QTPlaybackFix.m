#import "QTPlaybackFix.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import "QTStreamFallback.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

// Playback fix -- handles "Something went wrong" PoToken/integrity stalls.
// Strategy: on sideload stall (code 14/0) do a stall-aware retry with seek
// coalescing.  Also shields the player during rapid scrubbing (your
// circular-retry screenshot) by debouncing seek storms.

static NSString * const QTPlaybackErrorDomain = @"com.google.ios.youtube.ErrorDomain.playback";

static IMP OrigCurrentVideoMediaTime;
static IMP OrigSeekToTime;
static IMP OrigHandleError;

static double QTLatestTime = 0;
static NSTimeInterval QTLastSeekTime = 0;
static NSUInteger QTSeekBurstCount = 0;
static BOOL QTIsRetrying = NO;
static BOOL QTEmergencyRunning = NO;
static NSTimeInterval QTLastRetryAt = 0;
static NSUInteger QTRetryCount = 0;
static NSUInteger QTFixStallRecovered = 0;
static NSUInteger QTFixEmergencyRetried = 0;
static NSUInteger QTFixSeekSuppressed = 0;
static NSTimeInterval QTFixLastStallAt = 0;
static NSUInteger QTFixConsecutiveStalls = 0;

static double QTCurrentVideoMediaTime(id self, SEL _cmd) {
    double v = OrigCurrentVideoMediaTime ? ((double(*)(id,SEL))OrigCurrentVideoMediaTime)(self,_cmd) : 0;
    QTLatestTime = v;
    return v;
}
static void QTSeekToTime(id self, SEL _cmd, double t) {
    NSTimeInterval now = CACurrentMediaTime();
    // Seek storm detection -- but never hide the latest position from recovery.
    // Always update QTLatestTime so a later retry seeks to where the user ended.
    QTLatestTime = t;
    if (now - QTLastSeekTime < 0.22) {
        QTSeekBurstCount++;
        if (QTSeekBurstCount > 2) {
            QTLastSeekTime = now;
            QTFixSeekSuppressed++;
        } else {
            QTLastSeekTime = now;
        }
    } else {
        QTSeekBurstCount = 0;
        QTLastSeekTime = now;
    }
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

static void QTShowWebPlayerNudge(void) {
    @try {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"QuietTube.v1.useWebClient"]) return;
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"QuietTube.v1.webNudgeShown"]) return;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"QuietTube.v1.webNudgeShown"];
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                UIWindow *win = nil;
                for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                    if (![sc isKindOfClass:UIWindowScene.class]) continue;
                    UIWindowScene *ws = (UIWindowScene*)sc;
                    if (ws.activationState != UISceneActivationStateForegroundActive) continue;
                    for (UIWindow *w in ws.windows) if (w.isKeyWindow) { win = w; break; }
                    if (win) break;
                }
                UIViewController *top = win.rootViewController;
                while (top.presentedViewController) top = top.presentedViewController;
                if (!top) return;
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Playback error" message:@"YouTube showed 'Something went wrong'. Turn on Switch to Web Player in Quiet Controls -> Playback and restart to prevent this. (Like web + uBlock, Web player avoids the PoToken check.)" preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [a addAction:[UIAlertAction actionWithTitle:@"Open Quiet Controls" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){
                    @try {
                        UIViewController *page = QTSettingsController();
                        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
                        nav.modalPresentationStyle = UIModalPresentationPageSheet;
                        [top presentViewController:nav animated:YES completion:nil];
                    } @catch (__unused NSException *e) {}
                }]];
                [top presentViewController:a animated:YES completion:nil];
            } @catch (__unused NSException *e) {}
        });
    } @catch (__unused NSException *e) {}
}

static NSInteger QTErrorCodeForRetry(NSError *err) {
    if (!err || ![err.domain isEqualToString:QTPlaybackErrorDomain]) return -1;
    if (err.code==14 || err.code==0) return (NSInteger)err.code;
    if (err.code==5) return (NSInteger)err.code;
    return -1;
}
static void QTHandleError(id self, SEL _cmd, id error) {
    // Detailed pipeline input logging -- code/domain/userInfo keys, underlying error, and handleError call site
    @try {
        if ([error isKindOfClass:NSError.class]) {
            NSError *e = (NSError*)error;
            NSString *uiKeys = [[e.userInfo allKeys] componentsJoinedByString:@","];
            id underlying = e.userInfo[NSUnderlyingErrorKey];
            NSString *uDesc = [underlying isKindOfClass:NSError.class] ? [NSString stringWithFormat:@"%@:%ld", ((NSError*)underlying).domain, (long)((NSError*)underlying).code] : (underlying ? NSStringFromClass([underlying class]) : @"nil");
            if (QTDEnabled()) QTDEvent(QTDEPlaybackError, @{@"code":@(e.code), @"domain":@([e.domain isEqualToString:QTPlaybackErrorDomain]?1:0), @"depth":@0, @"result": e.localizedDescription?:@"", @"prefix": uiKeys?:@"", @"category": uDesc?:@"nil"});
            QTDError(error);
        } else {
            QTDError(error);
        }
    } @catch (__unused NSException *ex) { QTDError(error); }
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
    // If WEB mode is already on, do NOT reload-loop -- WEB should not produce code 14.
    // If it still does, log heavily and only nudge once, then stop retrying.
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"QuietTube.v1.useWebClient"]) {
        if (QTDEnabled()) QTDEvent(QTDEPlaybackError, @{@"code":@(err.code), @"domain":@1, @"depth":@99, @"result":@"web_mode_stall_unexpected"});
        QTCallOriginalHandleError(self,_cmd,error);
        return;
    }
    NSTimeInterval sinceSeek = CACurrentMediaTime() - QTLastSeekTime;
    if (sinceSeek < 0.45 && QTSeekBurstCount >= 3) {
        QTFixSeekSuppressed++;
        if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":@"seek_suppressed"});
        QTCallOriginalHandleError(self,_cmd,error);
        return;
    }
    NSTimeInterval sinceRetry = CACurrentMediaTime() - QTLastRetryAt;
    // Kill 15s loop: once we have hit 3 consecutive stalls within 60s, stop retrying and nudge to WEB.
    if (QTFixConsecutiveStalls >= 3 && (CACurrentMediaTime() - QTFixLastStallAt) < 60) {
        if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":@"stall_loop_killed"});
        QTShowWebPlayerNudge();
        QTCallOriginalHandleError(self,_cmd,error);
        return;
    }
    if (QTIsRetrying || (sinceRetry < 1.2 && QTRetryCount > 0)) {
        NSTimeInterval sinceStall = CACurrentMediaTime() - QTFixLastStallAt;
        if (sinceStall < 45 && QTFixConsecutiveStalls >= 2) QTShowWebPlayerNudge();
        QTCallOriginalHandleError(self,_cmd,error);
        return;
    }
    QTIsRetrying = YES;
    QTLastRetryAt = CACurrentMediaTime();
    QTFixConsecutiveStalls++;
    QTFixLastStallAt = CACurrentMediaTime();
    QTRetryCount++;
    double saved = QTLatestTime;
    if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":[NSString stringWithFormat:@"retry_start saved=%.2f stall#%lu", saved, (unsigned long)QTFixConsecutiveStalls]});

    SEL pg = NSSelectorFromString(@"parentViewController");
    id pvc = [self respondsToSelector:pg] ? ((id(*)(id,SEL))objc_msgSend)(self, pg) : nil;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        double moved = QTPosition(pvc);
        if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":[NSString stringWithFormat:@"retry_check saved=%.2f moved=%.2f", saved, moved]});
        if (moved > saved + 0.15) {
            QTIsRetrying = NO;
            QTFixStallRecovered++;
            QTFixConsecutiveStalls = 0;
            if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":@"stall_recovered"});
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
                                // Persistent failure -- transient WEB arm + nudge (once)
                                QTStreamFallbackHandleError(self, err, saved);
                                if (QTFixConsecutiveStalls >= 3) QTShowWebPlayerNudge();
                                // Break loop: only one emergency reload per stall burst.
                                // Further handleError in next 2s will hit the sinceRetry guard above.
                                if (!QTReloadPlayer(pvc, @"emergency")) QTSendRetryEvent(self, @"emergency");
                                QTSeek(pvc, saved, @"emergency");
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    QTScheduleCaptionRestore(pvc);
                                    QTIsRetrying = NO;
                                });
                            } else {
                                QTFixConsecutiveStalls = 0;
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
    // Install early -- before YTMainAppVideoPlayerOverlayViewController is instantiated.
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
    return [NSString stringWithFormat:@"PlaybackFix: retries=%lu stallRecovered=%lu emergency=%lu seekSuppressed=%lu retrying=%@\n",
        (unsigned long)QTRetryCount, (unsigned long)QTFixStallRecovered, (unsigned long)QTFixEmergencyRetried, (unsigned long)QTFixSeekSuppressed, QTIsRetrying?@"yes":@"no"];
}
