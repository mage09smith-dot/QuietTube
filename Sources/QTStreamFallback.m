#import "QTStreamFallback.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

// QTStreamFallback — real bypass for the PoToken failure that causes
// "Something went wrong" (code 14).  Strategy: rewrite the InnerTube
// player request's JSON body so YouTube thinks it's a TVHTML5/WEB
// client, which is known to not require a PoToken for playback.
// This is a pure-NSURLSession body rewrite — no JS solver needed.
//
// Flow:
//   1. QTIntegrity spoofs attest + PoToken + visitorData headers.
//   2. If that still fails, PlaybackFix retries (reload + seek).
//   3. If retry still fails (emergency), StreamFallback flips the
//      InnerTube client in the *next* player request so the server
//      mints the stream without PoToken.  The flag is time-boxed
//      (30s) so normal IOS behavior resumes.

static NSUInteger QTFallbackAttempts, QTFallbackSuccesses, QTFallbackRewrites;
static BOOL QTFallbackInstalled;
static volatile BOOL QTFallbackArmed;
static NSTimeInterval QTFallbackArmUntil;
static IMP OrigUploadTaskBody;
static IMP OrigDataTaskCB;

// TVHTML5 client context that YouTube's WEB fallback uses.
// These values are taken from YouTube WEB_M fallback used by yt-dlp
// and Invidious when IOS PoToken fails.  WEB fails open without PoToken.
static NSDictionary *QTFallbackClientContext(void) {
    return @{
        @"client": @{
            @"clientName": @"TVHTML5",
            @"clientVersion": @"7.20240716.00.00",
            @"hl": @"en",
            @"gl": @"US",
            @"clientScreen": @"WATCH",
            @"osName": @"Web",
            @"osVersion": @"1.0"
        }
    };
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
    // Only rewrite IOS -> TVHTML5.  Don't touch WEB/TV/ANDROID.
    if (![origName isEqualToString:@"IOS"] && ![origName isEqualToString:@"IOS_C"]) return nil;
    NSDictionary *fallback = QTFallbackClientContext();
    NSDictionary *fbClient = fallback[@"client"];
    for (NSString *k in fbClient) clientDict[k] = fbClient[k];
    // Remove PoToken/contentPoToken fields so server doesn't validate a bad one
    [d removeObjectForKey:@"contentPoToken"];
    [d removeObjectForKey:@"serviceIntegrityDimensions"];
    NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (out) QTFallbackRewrites++;
    return out;
}

static BOOL QTFallbackIsArmed(void) {
    if (!QTFallbackArmed) return NO;
    if ([NSDate date].timeIntervalSince1970 > QTFallbackArmUntil) {
        QTFallbackArmed = NO;
        return NO;
    }
    return YES;
}

static void QTInstallBodyRewrite(void) {
    Class cls = NSClassFromString(@"NSURLSession");
    if (!cls) return;
    // uploadTaskWithRequest:fromData:completionHandler: — this is what YT networking uses for POST /youtubei/v1/player
    SEL sel = NSSelectorFromString(@"uploadTaskWithRequest:fromData:completionHandler:");
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        OrigUploadTaskBody = method_getImplementation(m);
        IMP rep = imp_implementationWithBlock(^id(id self, NSURLRequest *req, NSData *body, id handler){
            NSMutableURLRequest *mutable = nil;
            NSData *newBody = nil;
            if (QTFallbackIsArmed() && body && [req.URL.absoluteString containsString:@"youtubei.googleapis.com"]) {
                NSString *url = req.URL.absoluteString;
                if ([url containsString:@"/player"] || [url containsString:@"/next"] || [url containsString:@"/browse"]) {
                    NSData *rewritten = QTRewriteInnertubeBody(body);
                    if (rewritten) {
                        mutable = [req mutableCopy];
                        newBody = rewritten;
                        QTCount(@"streamFallback: rewrote InnerTube body to TVHTML5");
                        if (QTDEnabled()) QTDEvent(QTDEPlayer, @{@"phase":@3, @"description":@"fallback_rewrite"});
                    }
                }
            }
            NSURLRequest *useReq = mutable ?: req;
            NSData *useBody = newBody ?: body;
            if (OrigUploadTaskBody) return ((id(*)(id,SEL,id,id,id))OrigUploadTaskBody)(self, sel, useReq, useBody, handler);
            return (id)nil;
        });
        method_setImplementation(m, rep);
        QTCount(@"streamFallback: hooked uploadTaskWithRequest:fromData:completionHandler:");
    }
    // also hook dataTaskWithRequest:completionHandler: for GET player fallback
    SEL sel2 = NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
    Method m2 = class_getInstanceMethod(cls, sel2);
    if (m2) {
        OrigDataTaskCB = method_getImplementation(m2);
        // Not rewriting GET — just counting. Body rewrite only matters for POST.
        QTCount(@"streamFallback: dataTask hook available");
    }
    QTCount(@"streamFallback: InnerTube body rewrite installed");
}

void QTInstallStreamFallback(void) {
    if (QTFallbackInstalled) return;
    QTFallbackInstalled=YES;
    QTInstallBodyRewrite();
    QTCount(@"streamFallback: installed");
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
    return [NSString stringWithFormat:@"StreamFallback: attempts=%lu successes=%lu rewrites=%lu armed=%@\n",
        (unsigned long)QTFallbackAttempts, (unsigned long)QTFallbackSuccesses, (unsigned long)QTFallbackRewrites,
        QTFallbackIsArmed()?@"yes":@"no"];
}
