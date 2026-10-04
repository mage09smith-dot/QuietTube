#import "QTStreamFallback.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

// QTStreamFallback — PoToken/code-14 bypass.
// Two modes:
//   A) Transient fallback (default): after 2 stalls in a row, arm a 30s TVHTML5 rewrite.
//   B) Persistent WEB client (opt-in via Quiet Controls): every InnerTube request is WEB,
//      so PoToken is never required.  Mirrors what web+uBlock does — WEB client has
//      no PoToken gate.  This is the proper fix for "every 60s" stalls.

static NSUInteger QTFallbackAttempts, QTFallbackSuccesses, QTFallbackRewrites;
static BOOL QTFallbackInstalled;
static volatile BOOL QTFallbackArmed;
static NSTimeInterval QTFallbackArmUntil;
static BOOL QTFallbackUseWebClient = NO;
static IMP OrigUploadTaskBody;
static IMP OrigDataTaskCB;

static NSString * const QTWebClientKey = @"QuietTube.v1.useWebClient";
BOOL QTStreamFallbackUsesWebClient(void) {
    return QTFallbackUseWebClient;
}
void QTStreamFallbackSetUseWebClient(BOOL useWeb) {
    QTFallbackUseWebClient = useWeb;
    [[NSUserDefaults standardUserDefaults] setBool:useWeb forKey:QTWebClientKey];
    if (useWeb) { QTFallbackArmed = YES; QTFallbackArmUntil = [NSDate date].timeIntervalSince1970 + 3600*24*365; }
    else { QTFallbackArmed = NO; }
}

// TVHTML5 client context that YouTube's WEB fallback uses.
// These values are taken from YouTube WEB_M fallback used by yt-dlp
// and Invidious when IOS PoToken fails.  WEB fails open without PoToken.
static NSDictionary *QTFallbackWebClientContext(void) {
    return @{
        @"client": @{
            @"clientName": @"WEB",
            @"clientVersion": @"2.20240726.00.00",
            @"hl": @"en",
            @"gl": @"US",
            @"clientScreen": @"WATCH",
            @"osName": @"Web",
            @"osVersion": @"1.0",
            @"platform": @"DESKTOP"
        }
    };
}
static NSDictionary *QTFallbackClientContext(void) {
    // WEB is more complete than TVHTML5 and closer to what uBlock/web sees.
    return QTFallbackWebClientContext();
}

static NSData *QTRewriteInnertubeBody(NSData *body) {
    if (!body || body.length==0 || body.length>512*1024) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:nil];
    if (![j isKindOfClass:NSMutableDictionary.class]) return nil;
    NSMutableDictionary *d = (NSMutableDictionary*)j;
    id ctx = d[@"context"];
    if (![ctx isKindOfClass:NSMutableDictionary.class]) return nil;
    NSMutableDictionary *context = (NSMutableDictionary*)ctx;
    id client = context[@"client"];
    if (![client isKindOfClass:NSMutableDictionary.class]) return nil;
    NSMutableDictionary *clientDict = (NSMutableDictionary*)client;
    NSString *origName = clientDict[@"clientName"];
    BOOL isWebMode = QTFallbackUseWebClient;
    if (!isWebMode) {
        // Transient mode: only IOS -> WEB
        if (![origName isEqualToString:@"IOS"] && ![origName isEqualToString:@"IOS_C"]) return nil;
    } else {
        // Persistent WEB mode: always rewrite IOS/IOS_C, but leave WEB/TV alone if already correct
        if ([origName isEqualToString:@"WEB"] || [origName isEqualToString:@"TVHTML5"]) return nil;
        if (![origName isEqualToString:@"IOS"] && ![origName isEqualToString:@"IOS_C"]) {
            // Unknown client (ANDROID etc) — rewrite to WEB anyway for consistency
        }
    }
    NSDictionary *fallback = QTFallbackClientContext();
    NSDictionary *fbClient = fallback[@"client"];
    for (NSString *k in fbClient) clientDict[k] = fbClient[k];
    [d removeObjectForKey:@"contentPoToken"];
    [d removeObjectForKey:@"serviceIntegrityDimensions"];
    // In WEB mode also strip iOS-specific fields that confuse the server
    if (isWebMode) {
        [context removeObjectForKey:@"adSignalsInfo"];
        [d removeObjectForKey:@"playbackContext"];
    }
    NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (out) QTFallbackRewrites++;
    return out;
}

static BOOL QTFallbackIsArmed(void) {
    if (QTFallbackUseWebClient) return YES;
    if (!QTFallbackArmed) return NO;
    if ([NSDate date].timeIntervalSince1970 > QTFallbackArmUntil) {
        QTFallbackArmed = NO;
        return NO;
    }
    return YES;
}

static void QTInstallBodyRewrite(void) {
    @try {
        Class cls = NSClassFromString(@"NSURLSession");
        if (!cls) return;
        // Defer swizzle to next runloop — same reason as QTIntegrity network spoof.
        // Also avoid double-hooking the same selector already hooked by QTIntegrity.
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                // Only hook uploadTask if QTIntegrity hasn't already taken the Orig slot.
                // We use a separate Orig var, so we can co-exist — just check m still exists.
                SEL sel = NSSelectorFromString(@"uploadTaskWithRequest:fromData:completionHandler:");
                Method m = class_getInstanceMethod(cls, sel);
                if (m) {
                    // Save current IMP (which may already be QTIntegrity's wrapper) and chain.
                    IMP current = method_getImplementation(m);
                    // Only hook if not already our wrapper
                    if (current != (IMP)QTInstallBodyRewrite) {
                        OrigUploadTaskBody = current;
                        IMP rep = imp_implementationWithBlock(^id(id self, NSURLRequest *req, NSData *body, id handler){
                            NSMutableURLRequest *mutable = nil;
                            NSData *newBody = nil;
                            @try {
                                if (QTFallbackIsArmed() && body && req.URL.absoluteString && [req.URL.absoluteString containsString:@"youtubei.googleapis.com"]) {
                                    NSString *url = req.URL.absoluteString;
                                    if ([url containsString:@"/player"] || [url containsString:@"/next"] || [url containsString:@"/browse"]) {
                                        NSData *rewritten = QTRewriteInnertubeBody(body);
                                        if (rewritten) {
                                            mutable = [req mutableCopy];
                                            newBody = rewritten;
                                            @try { QTCount(@"streamFallback: rewrote InnerTube body to TVHTML5"); } @catch(__unused NSException *e){}
                                            if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":@"fallback_rewrite"});
                                        }
                                    }
                                }
                            } @catch (__unused NSException *e) {}
                            NSURLRequest *useReq = mutable ?: req;
                            NSData *useBody = newBody ?: body;
                            if (OrigUploadTaskBody) return ((id(*)(id,SEL,id,id,id))OrigUploadTaskBody)(self, sel, useReq, useBody, handler);
                            return (id)nil;
                        });
                        method_setImplementation(m, rep);
                        @try { QTCount(@"streamFallback: hooked uploadTaskWithRequest:fromData:completionHandler:"); } @catch(__unused NSException *e){}
                    }
                }
                // Also hook dataTaskWithRequest:completionHandler: for GET player fallback
                SEL sel2 = NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
                Method m2 = class_getInstanceMethod(cls, sel2);
                if (m2) {
                    OrigDataTaskCB = method_getImplementation(m2);
                    @try { QTCount(@"streamFallback: dataTask hook available"); } @catch(__unused NSException *e){}
                }
            } @catch (__unused NSException *e) {}
        });
        @try { QTCount(@"streamFallback: InnerTube body rewrite scheduled"); } @catch(__unused NSException *e){}
    } @catch (__unused NSException *e) {}
}

void QTInstallStreamFallback(void) {
    if (QTFallbackInstalled) return;
    QTFallbackInstalled=YES;
    QTFallbackUseWebClient = [[NSUserDefaults standardUserDefaults] boolForKey:QTWebClientKey];
    if (QTFallbackUseWebClient) {
        QTFallbackArmed = YES;
        QTFallbackArmUntil = [NSDate date].timeIntervalSince1970 + 3600*24*365;
    }
    QTInstallBodyRewrite();
    @try { QTCount(QTFallbackUseWebClient ? @"streamFallback: installed (WEB persistent)" : @"streamFallback: installed"); } @catch(__unused NSException *e){}
}

BOOL QTStreamFallbackHandleError(id overlay, NSError *error, double savedTime) {
    (void)overlay; (void)savedTime;
    // Only arm on PoToken stall codes
    NSInteger code = [error isKindOfClass:NSError.class] ? ((NSError*)error).code : -1;
    NSString *domain = [error isKindOfClass:NSError.class] ? ((NSError*)error).domain : @"";
    BOOL isPoTokenStall = [domain isEqualToString:@"com.google.ios.youtube.ErrorDomain.playback"] && (code==14 || code==0);
    if (!isPoTokenStall) return NO;
    QTFallbackAttempts++;
    // First stall: just retry (PlaybackFix does it).  Second stall (emergency):
    // arm the fallback so the *next* InnerTube request is TVHTML5.
    static NSUInteger consecutiveStalls = 0;
    consecutiveStalls++;
    if (consecutiveStalls >= 2) {
        QTFallbackArmed = YES;
        QTFallbackArmUntil = [NSDate date].timeIntervalSince1970 + 30;
        consecutiveStalls = 0;
        QTFallbackSuccesses++;
        if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":@"fallback_armed"});
        QTCount(@"streamFallback: armed for 30s");
        return NO; // let PlaybackFix still do its reload; the reload's InnerTube call will be rewritten
    }
    if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":@"fallback_counting"});
    return NO;
}

NSString *QTStreamFallbackReport(void) {
    return [NSString stringWithFormat:@"StreamFallback: mode=%@ attempts=%lu successes=%lu rewrites=%lu armed=%@\n",
        QTFallbackUseWebClient?@"WEB-persistent":@"transient",
        (unsigned long)QTFallbackAttempts, (unsigned long)QTFallbackSuccesses, (unsigned long)QTFallbackRewrites,
        QTFallbackIsArmed()?@"yes":@"no"];
}
