#import "QTStreamFallback.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

// QTStreamFallback -- PoToken/code-14 bypass.
// Two modes:
//   A) Transient fallback (default): after 2 stalls in a row, arm a 30s TVHTML5 rewrite.
//   B) Persistent WEB client (opt-in via Quiet Controls): every InnerTube request is WEB,
//      so PoToken is never required.  Mirrors what web+uBlock does -- WEB client has
//      no PoToken gate.  This is the proper fix for "every 60s" stalls.

static NSUInteger QTFallbackAttempts, QTFallbackSuccesses, QTFallbackRewrites;
static BOOL QTFallbackInstalled;
static volatile BOOL QTFallbackArmed;
static NSTimeInterval QTFallbackArmUntil;
static BOOL QTFallbackUseWebClient = NO;
static IMP OrigUploadTaskBody;
static IMP OrigDataTaskCB;

static NSString * const QTWebClientKey = @"QuietTube.v1.useWebClient";
static NSString * const QTWebClientKeyLegacy = @"QuietTube.v1.useWebClient";
BOOL QTStreamFallbackUsesWebClient(void) {
    return QTFallbackUseWebClient;
}
void QTStreamFallbackSetUseWebClient(BOOL useWeb) {
    QTFallbackUseWebClient = useWeb;
    // Canonical key is QTPrefix+useWebClient; also mirror legacy for readers.
    [[NSUserDefaults standardUserDefaults] setBool:useWeb forKey:@"QuietTube.v1.useWebClient"];
    // QTCore will mirror to canonical on next launch -- also set directly here
    [[NSUserDefaults standardUserDefaults] setBool:useWeb forKey:QTWebClientKeyLegacy];
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
            // Unknown client (ANDROID etc) -- rewrite to WEB anyway for consistency
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


static IMP QTStreamFallbackOrigUpload = NULL;
static IMP QTStreamFallbackOrigDataCB = NULL;
static IMP QTStreamFallbackOrigData = NULL;

static BOOL QTStreamFallbackTryRewrite(NSURLRequest *req, NSData *body, NSMutableURLRequest **outReq, NSData **outBody) {
    @try {
        if (!QTFallbackIsArmed() || !req || !req.URL.absoluteString || ![req.URL.absoluteString containsString:@"youtubei"]) return NO;
        NSString *url = req.URL.absoluteString;
        // Log every youtubei request for debugging (proves hook hit)
        @try {
            if (QTDEnabled() && [url containsString:@"youtubei"]) {
                QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":[NSString stringWithFormat:@"yt_req url=%@", url]});
            }
        } @catch (__unused NSException *ex) {}
        if (![url containsString:@"/player"] && ![url containsString:@"/next"] && ![url containsString:@"/browse"]) return NO;
        NSData *srcBody = body;
        if (!srcBody) srcBody = req.HTTPBody;
        if (!srcBody) {
            if (QTDEnabled() && [url containsString:@"/player"]) {
                NSString *mode = QTFallbackUseWebClient?@"WEB":@"transient";
                QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":[NSString stringWithFormat:@"player_req mode=%@ orig=? rewrote=no-body", mode]});
            }
            return NO;
        }
        NSString *origClient = nil;
        @try {
            id j0 = [NSJSONSerialization JSONObjectWithData:srcBody options:0 error:nil];
            if ([j0 isKindOfClass:NSDictionary.class]) origClient = j0[@"context"][@"client"][@"clientName"];
        } @catch (__unused NSException *ex) {}
        NSData *rewritten = QTRewriteInnertubeBody(srcBody);
        BOOL didRewrite = (rewritten != nil);
        if (didRewrite) {
            if (body) {
                if (outBody) *outBody = rewritten;
            } else {
                NSMutableURLRequest *m = [req mutableCopy];
                m.HTTPBody = rewritten;
                if (outReq) *outReq = m;
            }
            @try { QTCount(@"streamFallback: rewrote InnerTube body to WEB"); } @catch(__unused NSException *ex){}
            if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description": @"fallback_rewrite_WEB", @"ad":@(1), @"scope":@(QTFallbackUseWebClient?1:0)});
        }
        if (QTDEnabled() && [url containsString:@"/player"]) {
            NSString *mode = QTFallbackUseWebClient?@"WEB":@"transient";
            QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":[NSString stringWithFormat:@"player_req mode=%@ orig=%@ rewrote=%@", mode, origClient?:@"?", didRewrite?@"yes":@"no"]});
        }
        return didRewrite;
    } @catch (__unused NSException *ex) { return NO; }
}

static void QTInstallBodyRewrite(void) {
    @try {
        Class cls = NSClassFromString(@"NSURLSession");
        if (!cls) return;
        // uploadTaskWithRequest:fromData:completionHandler:
        {
            SEL sel = NSSelectorFromString(@"uploadTaskWithRequest:fromData:completionHandler:");
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                QTStreamFallbackOrigUpload = method_getImplementation(m);
                IMP orig = QTStreamFallbackOrigUpload;
                SEL selCopy = sel;
                IMP rep = imp_implementationWithBlock(^id(id self, NSURLRequest *req, NSData *body, id handler){
                    NSMutableURLRequest *mReq = nil;
                    NSData *mBody = nil;
                    @try {
                        NSMutableURLRequest *mr = nil; NSData *mb = nil;
                        if (QTStreamFallbackTryRewrite(req, body, &mr, &mb)) { mReq = mr; mBody = mb; }
                    } @catch (__unused NSException *ex) {}
                    NSURLRequest *useReq = mReq ?: req;
                    NSData *useBody = mBody ?: body;
                    if (orig) return ((id(*)(id,SEL,id,id,id))orig)(self, selCopy, useReq, useBody, handler);
                    return (id)nil;
                });
                method_setImplementation(m, rep);
                @try { QTCount(@"streamFallback: hooked uploadTaskWithRequest:fromData:completionHandler:"); } @catch(__unused NSException *ex){}
            }
        }
        // dataTaskWithRequest:completionHandler:
        {
            SEL sel = NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                QTStreamFallbackOrigDataCB = method_getImplementation(m);
                IMP orig = QTStreamFallbackOrigDataCB;
                SEL selCopy = sel;
                IMP rep = imp_implementationWithBlock(^id(id self, NSURLRequest *req, id handler){
                    NSMutableURLRequest *mReq = nil;
                    @try {
                        NSMutableURLRequest *mr = nil;
                        if (QTStreamFallbackTryRewrite(req, nil, &mr, NULL)) mReq = mr;
                    } @catch (__unused NSException *ex) {}
                    NSURLRequest *useReq = mReq ?: req;
                    if (orig) return ((id(*)(id,SEL,id,id))orig)(self, selCopy, useReq, handler);
                    return (id)nil;
                });
                method_setImplementation(m, rep);
                @try { QTCount(@"streamFallback: hooked dataTaskWithRequest:completionHandler:"); } @catch(__unused NSException *ex){}
                @try { QTCount(@"streamFallback: dataTask hook available"); } @catch(__unused NSException *ex){}
            } else {
                @try { QTCount(@"streamFallback: dataTask hook available"); } @catch(__unused NSException *ex){}
            }
        }
        // dataTaskWithRequest:
        {
            SEL sel = NSSelectorFromString(@"dataTaskWithRequest:");
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                QTStreamFallbackOrigData = method_getImplementation(m);
                IMP orig = QTStreamFallbackOrigData;
                SEL selCopy = sel;
                IMP rep = imp_implementationWithBlock(^id(id self, NSURLRequest *req){
                    NSMutableURLRequest *mReq = nil;
                    @try {
                        NSMutableURLRequest *mr = nil;
                        if (QTStreamFallbackTryRewrite(req, nil, &mr, NULL)) mReq = mr;
                    } @catch (__unused NSException *ex) {}
                    NSURLRequest *useReq = mReq ?: req;
                    if (orig) return ((id(*)(id,SEL,id))orig)(self, selCopy, useReq);
                    return (id)nil;
                });
                method_setImplementation(m, rep);
                @try { QTCount(@"streamFallback: hooked dataTaskWithRequest:"); } @catch(__unused NSException *ex){}
            }
        }
        @try { QTCount(@"streamFallback: InnerTube body rewrite scheduled"); } @catch(__unused NSException *ex){}
    } @catch (__unused NSException *ex) {}
}


void QTInstallStreamFallback(void) {
    if (QTFallbackInstalled) return;
    QTFallbackInstalled=YES;
    // Read canonical first, fall back to legacy key.  Default ON if absent (fresh exp37).
    NSString *canon = @"QuietTube.v1.useWebClient";
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:canon];
    if (v == nil) v = [[NSUserDefaults standardUserDefaults] objectForKey:QTWebClientKey];
    if (v == nil) {
        QTFallbackUseWebClient = YES;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:canon];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:QTWebClientKey];
    } else {
        QTFallbackUseWebClient = [v boolValue];
    }
    if (QTFallbackUseWebClient) {
        QTFallbackArmed = YES;
        QTFallbackArmUntil = [NSDate date].timeIntervalSince1970 + 3600*24*365;
    }
    QTInstallBodyRewrite();
    @try {
        QTCount(QTFallbackUseWebClient ? @"streamFallback: installed (WEB persistent)" : @"streamFallback: installed");
        if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description": QTFallbackUseWebClient?@"fallback_mode_WEB":@"fallback_mode_transient"});
    } @catch(__unused NSException *e){}
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
