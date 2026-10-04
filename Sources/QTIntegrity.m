#import "QTIntegrity.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

// ============ bundle constants ============
static NSString *const QTYTBundleID = @"com.google.ios.youtube";
static NSString *const QTYTName     = @"YouTube";
static NSString *const QTYTVersion  = @"21.38.2"; // expected YT base

// ============ diagnostics ============
static NSMutableArray<NSString*> *QTIntLog;
static NSUInteger QTIntHookCount, QTIntMissCount;
static void QTIntTrace(NSString *msg) {
    if (!QTIntLog) QTIntLog = [NSMutableArray array];
    if (QTIntLog.count < 80) [QTIntLog addObject:msg];
    QTCount(msg);
}
static void QTIntInstalled(NSString *cls, NSString *sel) {
    QTIntHookCount++;
    QTIntTrace([NSString stringWithFormat:@"integrity: %@/%@ installed", cls, sel]);
}
static void QTIntMiss(NSString *cls, NSString *sel) {
    QTIntMissCount++;
}

// sideload detection — receipt + bundleID both
static BOOL QTIntSideloadedCheck(void) {
    if (![NSBundle.mainBundle.bundleIdentifier containsString:@"youtube"] &&
        ![NSBundle.mainBundle.bundleIdentifier isEqualToString:QTYTBundleID]) {
        // bundle already spoofed? check orig
        // fallback to receipt
    }
    NSURL *receipt = NSBundle.mainBundle.appStoreReceiptURL;
    if (!receipt.path.length) return YES;
    if (![NSFileManager.defaultManager fileExistsAtPath:receipt.path]) return YES;
    // additionally, if bundleID isn't com.google.ios.youtube, it's sideloaded
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    // read raw without spoof
    @try {
        NSDictionary *info = [NSBundle.mainBundle infoDictionary];
        NSString *raw = info[@"CFBundleIdentifier"];
        if (raw && ![raw isEqualToString:QTYTBundleID]) return YES;
        (void)bid;
    } @catch(__unused NSException *e) {}
    return NO;
}
BOOL QTIntegrityIsSideloaded(void) { return QTIntSideloadedCheck(); }

// ============ helper: scan all classes for selector ============
static Class QTFindClassWithSelector(SEL sel, NSString *hint) {
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    Class found = Nil;
    for (unsigned int i=0;i<count;i++) {
        if (class_getInstanceMethod(list[i], sel)) {
            NSString *name = NSStringFromClass(list[i]);
            if ([name containsString:hint] || [name hasPrefix:@"YT"] || [name hasPrefix:@"GUL"] || [name hasPrefix:@"FIR"] || [name hasPrefix:@"DC"] || [name hasPrefix:@"AS"]) {
                found = list[i]; break;
            }
        }
        if (class_getClassMethod(list[i], sel)) {
            NSString *name = NSStringFromClass(list[i]);
            if ([name containsString:hint]) { found = list[i]; break; }
        }
    }
    // fallback: any class with that selector
    if (!found) {
        for (unsigned int i=0;i<count;i++) {
            if (class_getInstanceMethod(list[i], sel) || class_getClassMethod(list[i], sel)) { found = list[i]; break; }
        }
    }
    free(list);
    return found;
}

// swizzle helpers
static BOOL QTSwizzleInstance(Class cls, SEL sel, IMP rep, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, rep);
    return YES;
}
static BOOL QTSwizzleClass(Class cls, SEL sel, IMP rep, IMP *outOrig) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, rep);
    return YES;
}

// ============ orig storage ============
static IMP OrigBundleIdentifier, OrigInfoDictionary, OrigInfoValue, OrigBundleWithIdentifier;
static IMP OrigAppAttestGenerateKey, OrigAppAttestAttestKey, OrigAppAttestGenerateAssertion;
static IMP OrigDCGenerateToken, OrigDCGenerateTokenNew;
static IMP OrigBotGuardGeneratePoToken, OrigBotGuardCreateChallenge;
static IMP OrigGULIsFromAppStore, OrigFASIsFAS;
static IMP OrigSSOSetTemporary, OrigSSOInit;
static IMP OrigGroupContainer;
static IMP OrigSetDelegate;
static IMP OrigNSURLSessionDataTask;

// ============ impl: bundle spoof ============
static NSString *QTBundleIdentifier(id self, SEL _cmd) {
    if (self == NSBundle.mainBundle) return QTYTBundleID;
    return OrigBundleIdentifier ? ((NSString*(*)(id,SEL))OrigBundleIdentifier)(self,_cmd) : nil;
}
static NSDictionary *QTInfoDictionary(id self, SEL _cmd) {
    NSDictionary *info = OrigInfoDictionary ? ((NSDictionary*(*)(id,SEL))OrigInfoDictionary)(self,_cmd) : nil;
    if (self != NSBundle.mainBundle || !info) return info;
    NSMutableDictionary *m = [info mutableCopy];
    m[@"CFBundleIdentifier"] = QTYTBundleID;
    m[@"CFBundleDisplayName"] = QTYTName;
    m[@"CFBundleName"] = QTYTName;
    return [m copy];
}
static id QTInfoValue(id self, SEL _cmd, NSString *key) {
    if (self == NSBundle.mainBundle) {
        if ([key isEqualToString:@"CFBundleIdentifier"]) return QTYTBundleID;
        if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"]) return QTYTName;
        if ([key isEqualToString:@"CFBundleShortVersionString"]) {
            // keep real YT version so version gate passes
            if (OrigInfoValue) {
                id v = ((id(*)(id,SEL,id))OrigInfoValue)(self,_cmd,key);
                if (v) return v;
            }
            return QTYTVersion;
        }
    }
    return OrigInfoValue ? ((id(*)(id,SEL,id))OrigInfoValue)(self,_cmd,key) : nil;
}
static id QTBundleWithIdentifier(id self, SEL _cmd, NSString *bid) {
    if ([bid isEqualToString:QTYTBundleID]) return NSBundle.mainBundle;
    return OrigBundleWithIdentifier ? ((id(*)(id,SEL,id))OrigBundleWithIdentifier)(self,_cmd,bid) : nil;
}

// YTVersionUtils
static NSString *QTAppName(id self, SEL _cmd) { return QTYTName; }
static NSString *QTAppID(id self, SEL _cmd) { return QTYTBundleID; }
static BOOL QTTrue(id self, SEL _cmd) { return YES; }
static BOOL QTFalse(id self, SEL _cmd) { return NO; }

// Access group
static NSString *QTCurrentAccessGroup(void) {
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                             (__bridge id)kSecAttrAccount: @"QTDummyItem",
                             (__bridge id)kSecAttrService: @"QTDummyService",
                             (__bridge id)kSecReturnAttributes: @YES };
        CFTypeRef res = NULL;
        OSStatus s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        if (s == errSecItemNotFound) s = SecItemAdd((__bridge CFDictionaryRef)q, &res);
        if (s == errSecDuplicateItem) s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        if (s == errSecSuccess && res) {
            NSDictionary *a = CFBridgingRelease(res);
            id v = a[(__bridge id)kSecAttrAccessGroup];
            if ([v isKindOfClass:NSString.class]) group = [v copy];
            else CFRelease(res);
        } else if (res) CFRelease(res);
    });
    return group;
}
static NSString *QTAccessGroup(id self, SEL _cmd) { return QTCurrentAccessGroup(); }

// SSO
static void QTSetTemporaryDisabled(id self, SEL _cmd, BOOL v) {
    if (OrigSSOSetTemporary) ((void(*)(id,SEL,BOOL))OrigSSOSetTemporary)(self,_cmd,NO);
}
static id QTSSOInit(id self, SEL _cmd, id cid, id svc) {
    id val = OrigSSOInit ? ((id(*)(id,SEL,id,id))OrigSSOInit)(self,_cmd,cid,svc) : self;
    if (val) @try {
        [val setValue:QTYTName forKey:@"_shortAppName"];
        [val setValue:QTYTBundleID forKey:@"_applicationIdentifier"];
    } @catch(__unused NSException *e) {}
    return val;
}
static NSURL *QTGroupContainerURL(id self, SEL _cmd, NSString *ident) {
    NSURL *orig = OrigGroupContainer ? ((NSURL*(*)(id,SEL,id))OrigGroupContainer)(self,_cmd,ident) : nil;
    if (orig || ![ident containsString:@"group."]) return orig;
    NSURL *sup = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] lastObject];
    if (!sup) return nil;
    NSURL *fb = [sup URLByAppendingPathComponent:@"AppGroup" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:fb withIntermediateDirectories:YES attributes:nil error:nil];
    return fb;
}
static BOOL QTAppOpenURL(id self, SEL _cmd, UIApplication *app, NSURL *url, NSDictionary *opts) {
    SEL legacy = NSSelectorFromString(@"application:openURL:sourceApplication:annotation:");
    if ([self respondsToSelector:legacy]) {
        id src = opts[UIApplicationOpenURLOptionsSourceApplicationKey];
        id ann = opts[UIApplicationOpenURLOptionsAnnotationKey];
        return ((BOOL(*)(id,SEL,id,id,id,id))objc_msgSend)(self, legacy, app, url, src, ann);
    }
    SEL older = NSSelectorFromString(@"application:handleOpenURL:");
    if ([self respondsToSelector:older]) return ((BOOL(*)(id,SEL,id,id))objc_msgSend)(self, older, app, url);
    return NO;
}
static void QTSetDelegate(id self, SEL _cmd, id del) {
    if (del && [NSBundle.mainBundle objectForInfoDictionaryKey:@"LSSupportsOpeningDocumentsInPlace"]) {
        SEL openSel = NSSelectorFromString(@"application:openURL:options:");
        Class dc = object_getClass(del);
        if (!class_getInstanceMethod(dc, openSel)) class_addMethod(dc, openSel, (IMP)QTAppOpenURL, "B@:@@@");
    }
    if (OrigSetDelegate) ((void(*)(id,SEL,id))OrigSetDelegate)(self,_cmd,del);
}

// ============ DeviceCheck / AppAttest / PoToken spoof ============
// Strategy: make every integrity check return "valid" locally so YT never
// asks the server to mint a PoToken that would fail, and if it does ask,
// inject a synthetic token that bypasses the server check on playback.

// DeviceCheck: DCDevice
static void QTDCSpoof_DCDevice(Class cls) {
    // +[DCDevice currentDevice] is not needed — we spoof the instance methods
    // -[DCDevice isSupported] -> YES
    // -[DCDevice generateTokenWithCompletionHandler:] -> immediate fake token
    SEL sup = NSSelectorFromString(@"isSupported");
    Method m = class_getInstanceMethod(cls, sup);
    if (m) { method_setImplementation(m, (IMP)QTTrue); QTIntInstalled(@"DCDevice", @"isSupported"); }
    else QTIntMiss(@"DCDevice", @"isSupported");

    SEL gen = NSSelectorFromString(@"generateTokenWithCompletionHandler:");
    Method mg = class_getInstanceMethod(cls, gen);
    if (mg) {
        OrigDCGenerateToken = method_getImplementation(mg);
        IMP rep = imp_implementationWithBlock(^void(id self, id handler){
            // handler is void (^)(NSData *token, NSError *error)
            if (!handler) return;
            NSData *fake = [@"quietube-dc-fake-token-0000000000000000" dataUsingEncoding:NSUTF8StringEncoding];
            void (^cb)(NSData*,NSError*) = handler;
            // complete async to mimic real DeviceCheck
            dispatch_async(dispatch_get_main_queue(), ^{ cb(fake, nil); });
            QTIntTrace(@"integrity: DCDevice generateToken spoofed");
        });
        method_setImplementation(mg, rep);
        QTIntInstalled(@"DCDevice", @"generateTokenWithCompletionHandler:");
    } else QTIntMiss(@"DCDevice", @"generateTokenWithCompletionHandler:");

    // iOS 14+ variant: generateTokenWithCompletionHandler: is sometimes on DCAppAttestService
    // also try generateTokenWithOptions:completionHandler:
    SEL gen2 = NSSelectorFromString(@"generateTokenWithOptions:completionHandler:");
    Method mg2 = class_getInstanceMethod(cls, gen2);
    if (mg2) {
        OrigDCGenerateTokenNew = method_getImplementation(mg2);
        IMP rep2 = imp_implementationWithBlock(^void(id self, id opts, id handler){
            if (!handler) return;
            NSData *fake = [@"quietube-dc-fake-token-0000000000000000" dataUsingEncoding:NSUTF8StringEncoding];
            void (^cb)(NSData*,NSError*) = handler;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(fake, nil); });
        });
        method_setImplementation(mg2, rep2);
        QTIntInstalled(@"DCDevice", @"generateTokenWithOptions:completionHandler:");
    }
}

static void QTSpoof_DCAppAttestService(Class cls) {
    // DCAppAttestService: isSupported -> YES, generateKeyWithCompletionHandler -> fake keyId
    SEL sup = NSSelectorFromString(@"isSupported");
    Method m = class_getInstanceMethod(cls, sup);
    if (!m) m = class_getClassMethod(cls, sup);
    if (m) {
        method_setImplementation(m, (IMP)QTTrue);
        QTIntInstalled(NSStringFromClass(cls), @"isSupported");
    }
    // Also try class method variant
    SEL supC = NSSelectorFromString(@"isSupported");
    Method mc = class_getClassMethod(cls, supC);
    if (mc && m != mc) { method_setImplementation(mc, (IMP)QTTrue); }

    SEL gen = NSSelectorFromString(@"generateKeyWithCompletionHandler:");
    Method mg = class_getInstanceMethod(cls, gen);
    if (!mg) mg = class_getClassMethod(cls, gen);
    if (mg) {
        OrigAppAttestGenerateKey = method_getImplementation(mg);
        IMP rep = imp_implementationWithBlock(^void(id self, id handler){
            if (!handler) return;
            void (^cb)(NSString*,NSError*) = handler;
            dispatch_async(dispatch_get_main_queue(), ^{ cb(@"quietube-fake-key-id-00000000-0000-0000-0000-000000000000", nil); });
            QTIntTrace(@"integrity: DCAppAttestService generateKey spoofed");
        });
        method_setImplementation(mg, rep);
        QTIntInstalled(NSStringFromClass(cls), @"generateKeyWithCompletionHandler:");
    }
    SEL attest = NSSelectorFromString(@"attestKey:clientDataHash:completionHandler:");
    Method ma = class_getInstanceMethod(cls, attest);
    if (!ma) ma = class_getClassMethod(cls, attest);
    if (ma) {
        OrigAppAttestAttestKey = method_getImplementation(ma);
        IMP rep = imp_implementationWithBlock(^void(id self, NSString *keyId, NSData *hash, id handler){
            if (!handler) return;
            void (^cb)(NSData*,NSError*) = handler;
            NSData *fakeAttest = [@"quietube-fake-attestation-object-000000000000" dataUsingEncoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{ cb(fakeAttest, nil); });
            QTIntTrace(@"integrity: DCAppAttestService attestKey spoofed");
        });
        method_setImplementation(ma, rep);
        QTIntInstalled(NSStringFromClass(cls), @"attestKey:clientDataHash:completionHandler:");
    }
    SEL assertion = NSSelectorFromString(@"generateAssertion:clientDataHash:completionHandler:");
    Method mas = class_getInstanceMethod(cls, assertion);
    if (!mas) mas = class_getClassMethod(cls, assertion);
    if (mas) {
        OrigAppAttestGenerateAssertion = method_getImplementation(mas);
        IMP rep = imp_implementationWithBlock(^void(id self, NSString *keyId, NSData *hash, id handler){
            if (!handler) return;
            void (^cb)(NSData*,NSError*) = handler;
            NSData *fake = [@"quietube-fake-assertion-000000000000" dataUsingEncoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{ cb(fake, nil); });
        });
        method_setImplementation(mas, rep);
        QTIntInstalled(NSStringFromClass(cls), @"generateAssertion:clientDataHash:completionHandler:");
    }
}

// ASDeviceCheck / Apple Private?
static void QTSpoof_BotGuardAndPoToken(void) {
    // Hunt all classes containing BotGuard, PoToken, Attest, Integrity, Visitor
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    for (unsigned int i=0;i<count;i++) {
        NSString *name = NSStringFromClass(list[i]);
        BOOL isBotGuard = [name containsString:@"BotGuard"] || [name containsString:@"BOTGUARD"] || [name containsString:@"PoToken"] || [name containsString:@"POToken"] || [name containsString:@"Attest"] || [name containsString:@"Integrity"] || [name containsString:@"VisitorData"];
        if (!isBotGuard) continue;
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(list[i], &mcount);
        // Also check class methods
        Method *cmethods = class_copyMethodList(object_getClass(list[i]), &mcount);
        // Try to spoof any method returning NSData/NSString that looks like token generation
        for (unsigned int j=0;j<mcount;j++) {
            SEL sel = method_getName(methods[j]);
            NSString *selName = NSStringFromSelector(sel);
            // heuristics: methods that generate tokens/attestations
            if ([selName containsString:@"poToken"] || [selName containsString:@"PoToken"] ||
                [selName containsString:@"generate"] || [selName containsString:@"attest"] ||
                [selName containsString:@"integrity"] || [selName containsString:@"mint"]) {
                const char *types = method_getTypeEncoding(methods[j]);
                // only spoof object returns
                if (types[0] == '@') {
                    // don't break; log
                    QTIntTrace([NSString stringWithFormat:@"integrity: candidate %@ -[%@ %@] types=%s", name, name, selName, types]);
                }
            }
        }
        free(methods);
        // avoid leaking cmethods count mismatch; just ignore
        (void)cmethods;
    }
    free(list);

    // Direct known PoToken classes (YTPoToken, YTPoTokenProvider, etc)
    NSArray *poTokenClasses = @[@"YTPoTokenProvider", @"YTPoTokenManager", @"YTPoToken", @"YTAttestService", @"YTIntegrityService", @"YTBotGuardService", @"YTColdConfig", @"YTVisitorDataProvider"];
    for (NSString *clsName in poTokenClasses) {
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;
        unsigned int mc = 0;
        Method *ml = class_copyMethodList(cls, &mc);
        for (unsigned int k=0;k<mc;k++) {
            SEL sel = method_getName(ml[k]);
            NSString *s = NSStringFromSelector(sel);
            if ([s containsString:@"poToken"] || [s containsString:@"PoToken"] || [s containsString:@"token"] || [s containsString:@"attest"] || [s containsString:@"integrity"]) {
                QTIntTrace([NSString stringWithFormat:@"integrity: PoToken class %@ sel %@ types %s", clsName, s, method_getTypeEncoding(ml[k])]);
            }
        }
        free(ml);
        // also class methods
        mc = 0;
        ml = class_copyMethodList(object_getClass(cls), &mc);
        for (unsigned int k=0;k<mc;k++) {
            SEL sel = method_getName(ml[k]);
            NSString *s = NSStringFromSelector(sel);
            if ([s containsString:@"poToken"] || [s containsString:@"PoToken"] || [s containsString:@"token"]) {
                QTIntTrace([NSString stringWithFormat:@"integrity: PoToken(C) %@ sel %@ types %s", clsName, s, method_getTypeEncoding(ml[k])]);
            }
        }
        free(ml);
    }

    // Aggressive PoToken hook: signature-aware.
    // We must not guess block arity — use method_getTypeEncoding to decide.
    // For methods with completionHandler: we detect it and call with (token,nil).
    NSArray *poSelectors = @[@"generatePoTokenWithCompletionHandler:", @"generatePoToken:", @"mintPoToken:", @"mintPoTokenWithCompletionHandler:", @"fetchPoToken:", @"requestPoToken:", @"generateAttestationWithCompletionHandler:", @"generateIntegrityTokenWithCompletionHandler:"];
    for (NSString *selStr in poSelectors) {
        SEL sel = NSSelectorFromString(selStr);
        unsigned int cc = 0;
        Class *cl = objc_copyClassList(&cc);
        for (unsigned int idx=0; idx<cc; idx++) {
            Method m = class_getInstanceMethod(cl[idx], sel);
            BOOL isClassMethod = NO;
            if (!m) { m = class_getClassMethod(cl[idx], sel); isClassMethod = (m!=NULL); }
            if (!m) continue;
            const char *enc = method_getTypeEncoding(m);
            if (!enc) continue;
            // Parse enc to decide return type and arg count
            char retType = enc[0];
            BOOL hasCompletion = [selStr containsString:@"CompletionHandler"];
            unsigned int argCount = method_getNumberOfArguments(m);
            IMP fake = NULL;
            if (hasCompletion && argCount >= 3) {
                // -foo:(id)completion:(block) — block is last arg
                if (argCount==3) {
                    fake = imp_implementationWithBlock(^void(id self, id handler){
                        if (!handler) return;
                        // handler is void(^)(NSString *token, NSError *error) or (NSData*,NSError*)
                        // call with fake string token; if callee expects NSData it'll still be non-nil
                        void (^cb)(id,NSError*) = (void(^)(id,NSError*))handler;
                        NSString *fakeToken = @"quietube-potoken-000000000000000000000000000000000000000000000000";
                        dispatch_async(dispatch_get_main_queue(), ^{ @try{ cb(fakeToken,nil); } @catch(__unused NSException *e){} });
                        QTIntTrace([NSString stringWithFormat:@"integrity: spoofed %@ -%@", NSStringFromClass(cl[idx]), selStr]);
                    });
                } else if (argCount==4) {
                    fake = imp_implementationWithBlock(^void(id self, id a1, id handler){
                        if (!handler) handler=a1;
                        if (!handler) return;
                        void (^cb)(id,NSError*) = (void(^)(id,NSError*))handler;
                        NSString *fakeToken = @"quietube-potoken-000000000000000000000000000000000000000000000000";
                        dispatch_async(dispatch_get_main_queue(), ^{ @try{ cb(fakeToken,nil); } @catch(__unused NSException *e){} });
                        QTIntTrace([NSString stringWithFormat:@"integrity: spoofed %@ -%@", NSStringFromClass(cl[idx]), selStr]);
                    });
                } else {
                    // fallback: treat last arg as block
                    fake = imp_implementationWithBlock(^void(id self, id a1, id a2, id a3){
                        id handler = a3 ?: a2 ?: a1;
                        if (!handler) return;
                        void (^cb)(id,NSError*) = (void(^)(id,NSError*))handler;
                        NSString *fakeToken = @"quietube-potoken-000000000000000000000000000000000000000000000000";
                        dispatch_async(dispatch_get_main_queue(), ^{ @try{ cb(fakeToken,nil); } @catch(__unused NSException *e){} });
                        QTIntTrace([NSString stringWithFormat:@"integrity: spoofed %@ -%@", NSStringFromClass(cl[idx]), selStr]);
                    });
                }
            } else {
                // no completion — return fake token directly
                if (retType=='@') {
                    fake = imp_implementationWithBlock(^id(id self){
                        QTIntTrace([NSString stringWithFormat:@"integrity: spoofed %@ -%@", NSStringFromClass(cl[idx]), selStr]);
                        return @"quietube-potoken-fake";
                    });
                } else if (retType=='c' || retType=='B') {
                    fake = (IMP)QTTrue;
                } else {
                    continue;
                }
            }
            method_setImplementation(m, fake);
            QTIntInstalled(NSStringFromClass(cl[idx]), selStr);
            (void)isClassMethod; (void)enc;
        }
        free(cl);
    }
}

// ============ NSURLRequest context spoof ============
// YouTube's InnerTube context includes visitorData, client info. We ensure
// the request serializer doesn't send a broken attest header.
static IMP OrigUploadTaskWithRequest;
static IMP OrigDataTaskWithRequestAndDelegate;
static void QTScrubYouTubeRequest(NSMutableURLRequest *mutable) {
    NSString *url = mutable.URL.absoluteString ?: @"";
    if (!([url containsString:@"youtubei.googleapis.com"] || [url containsString:@"googlevideo.com"] || [url containsString:@"youtube.com"])) return;
    NSString *existingPo = [mutable valueForHTTPHeaderField:@"X-Goog-PoToken"];
    if (!existingPo) {
        [mutable setValue:@"QUlEAAAAAQEAAABQAgAAAEAQABgAIAAoAFAAZABhAGQAcQBkAGEAcABhAGoAaABrAGwAbQBuAG8AcABxAHIAcwB0AHUAdgB3AHgAeQB6ADAAMQAyADMANABFAEcASQBNAE8AUQBT" forHTTPHeaderField:@"X-Goog-PoToken"];
        QTIntTrace(@"integrity: injected fake X-Goog-PoToken");
    }
    NSString *visitor = [mutable valueForHTTPHeaderField:@"X-Goog-Visitor-Id"];
    if (!visitor || visitor.length < 10) {
        [mutable setValue:@"Cgtzc2NsY0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0NDQ0MIDAwMDAwMDAwMDAwMA" forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    }
    NSString *client = [mutable valueForHTTPHeaderField:@"X-YouTube-Client-Version"];
    if (!client) [mutable setValue:QTYTVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];
    // Also ensure User-Agent looks like YouTube IOS
    NSString *ua = [mutable valueForHTTPHeaderField:@"User-Agent"];
    if (!ua || ![ua containsString:@"YouTube"]) {
        [mutable setValue:[NSString stringWithFormat:@"com.google.ios.youtube/%@ (iPhone; iOS 17.5; Scale/3.00)", QTYTVersion] forHTTPHeaderField:@"User-Agent"];
    }
}
static void QTInstallNetworkSpoof(void) {
    Class cls = NSClassFromString(@"NSURLSession");
    if (!cls) return;
    // Primary: dataTaskWithRequest:completionHandler:
    {
        SEL sel = NSSelectorFromString(@"dataTaskWithRequest:completionHandler:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            OrigNSURLSessionDataTask = method_getImplementation(m);
            IMP rep = imp_implementationWithBlock(^id(id self, NSURLRequest *req, id handler){
                NSMutableURLRequest *mutable = [req mutableCopy] ?: [NSMutableURLRequest requestWithURL:req.URL];
                if (!mutable) mutable = (NSMutableURLRequest*)req;
                QTScrubYouTubeRequest(mutable);
                if (OrigNSURLSessionDataTask) return ((id(*)(id,SEL,id,id))OrigNSURLSessionDataTask)(self, sel, mutable ?: req, handler);
                return (id)nil;
            });
            method_setImplementation(m, rep);
            QTIntInstalled(@"NSURLSession", @"dataTaskWithRequest:completionHandler:");
        }
    }
    // Secondary: uploadTaskWithRequest:fromData:completionHandler: (used by YT networking)
    {
        SEL sel = NSSelectorFromString(@"uploadTaskWithRequest:fromData:completionHandler:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            OrigUploadTaskWithRequest = method_getImplementation(m);
            IMP rep = imp_implementationWithBlock(^id(id self, NSURLRequest *req, NSData *body, id handler){
                NSMutableURLRequest *mutable = [req mutableCopy] ?: [NSMutableURLRequest requestWithURL:req.URL];
                if (!mutable) mutable = (NSMutableURLRequest*)req;
                QTScrubYouTubeRequest(mutable);
                if (OrigUploadTaskWithRequest) return ((id(*)(id,SEL,id,id,id))OrigUploadTaskWithRequest)(self, sel, mutable ?: req, body, handler);
                return (id)nil;
            });
            method_setImplementation(m, rep);
            QTIntInstalled(@"NSURLSession", @"uploadTaskWithRequest:fromData:completionHandler:");
        }
    }
    // Tertiary: dataTaskWithRequest: (no completion, delegate-based — used by some YT stacks)
    {
        SEL sel = NSSelectorFromString(@"dataTaskWithRequest:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            OrigDataTaskWithRequestAndDelegate = method_getImplementation(m);
            IMP rep = imp_implementationWithBlock(^id(id self, NSURLRequest *req){
                NSMutableURLRequest *mutable = [req mutableCopy] ?: [NSMutableURLRequest requestWithURL:req.URL];
                if (!mutable) mutable = (NSMutableURLRequest*)req;
                QTScrubYouTubeRequest(mutable);
                if (OrigDataTaskWithRequestAndDelegate) return ((id(*)(id,SEL,id))OrigDataTaskWithRequestAndDelegate)(self, sel, mutable ?: req);
                return (id)nil;
            });
            method_setImplementation(m, rep);
            QTIntInstalled(@"NSURLSession", @"dataTaskWithRequest:");
        }
    }
}

// ============ main installer ============
void QTInstallIntegrity(void) {
    QTIntLog = [NSMutableArray array];
    // 1. Always install — even on "store" builds, the receipt may still be missing (LiveContainer)
    QTCurrentAccessGroup(); // prime early

    // 2. UIApplication setDelegate shim
    {
        Class c = NSClassFromString(@"UIApplication");
        Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(@"setDelegate:")) : NULL;
        if (m) { OrigSetDelegate = method_getImplementation(m); method_setImplementation(m, (IMP)QTSetDelegate); }
        else QTHook(@"UIApplication", @"setDelegate:", @"v@", ^id(IMP old, SEL s){ OrigSetDelegate=old; return ^(id o, id d){ QTSetDelegate(o,s,d); }; });
        QTIntInstalled(@"UIApplication", @"setDelegate:");
    }
    // 3. NSBundle spoof
    NSString *realID = NSBundle.mainBundle.bundleIdentifier; // raw, before hook
    // Always hook bundleIdentifier even if it already matches, to survive re-reads
    {
        Class c = NSClassFromString(@"NSBundle");
        Method m1 = class_getInstanceMethod(c, NSSelectorFromString(@"bundleIdentifier"));
        if (m1) { OrigBundleIdentifier = method_getImplementation(m1); method_setImplementation(m1, (IMP)QTBundleIdentifier); QTIntInstalled(@"NSBundle", @"bundleIdentifier"); }
        Method m2 = class_getInstanceMethod(c, NSSelectorFromString(@"infoDictionary"));
        if (m2) { OrigInfoDictionary = method_getImplementation(m2); method_setImplementation(m2, (IMP)QTInfoDictionary); QTIntInstalled(@"NSBundle", @"infoDictionary"); }
        Method m3 = class_getInstanceMethod(c, NSSelectorFromString(@"objectForInfoDictionaryKey:"));
        if (m3) { OrigInfoValue = method_getImplementation(m3); method_setImplementation(m3, (IMP)QTInfoValue); QTIntInstalled(@"NSBundle", @"objectForInfoDictionaryKey:"); }
        Method m4 = class_getClassMethod(c, NSSelectorFromString(@"bundleWithIdentifier:"));
        if (m4) { OrigBundleWithIdentifier = method_getImplementation(m4); method_setImplementation(m4, (IMP)QTBundleWithIdentifier); QTIntInstalled(@"NSBundle", @"bundleWithIdentifier:"); }
        (void)realID;
    }
    // 4. YTVersionUtils
    {
        Class c = NSClassFromString(@"YTVersionUtils");
        if (c) {
            Method m1 = class_getClassMethod(c, NSSelectorFromString(@"appName"));
            if (m1) { method_setImplementation(m1, (IMP)QTAppName); QTIntInstalled(@"YTVersionUtils", @"appName"); }
            Method m2 = class_getClassMethod(c, NSSelectorFromString(@"appID"));
            if (m2) { method_setImplementation(m2, (IMP)QTAppID); QTIntInstalled(@"YTVersionUtils", @"appID"); }
        } else {
            QTHook(@"YTVersionUtils", @"appName", @"@", ^id(IMP o, SEL s){ return ^NSString*(id x){ return QTYTName; }; });
            QTHook(@"YTVersionUtils", @"appID", @"@", ^id(IMP o, SEL s){ return ^NSString*(id x){ return QTYTBundleID; }; });
            QTIntInstalled(@"YTVersionUtils", @"appName/appID (deferred)");
        }
    }
    // 5. isFromAppStore / isFAS
    {
        Class c = NSClassFromString(@"GULAppEnvironmentUtil");
        Method m = c ? class_getClassMethod(c, NSSelectorFromString(@"isFromAppStore")) : NULL;
        if (m) { OrigGULIsFromAppStore = method_getImplementation(m); method_setImplementation(m, (IMP)QTTrue); QTIntInstalled(@"GULAppEnvironmentUtil", @"isFromAppStore"); }
        else QTHook(@"GULAppEnvironmentUtil", @"isFromAppStore", @"B", ^id(IMP o, SEL s){ return ^BOOL(id x){ return YES; }; });
    }
    {
        Class c = NSClassFromString(@"APMAEU");
        Method m = c ? class_getClassMethod(c, NSSelectorFromString(@"isFAS")) : NULL;
        if (m) { OrigFASIsFAS = method_getImplementation(m); method_setImplementation(m, (IMP)QTTrue); QTIntInstalled(@"APMAEU", @"isFAS"); }
        else QTHook(@"APMAEU", @"isFAS", @"B", ^id(IMP o, SEL s){ return ^BOOL(id x){ return YES; }; });
    }
    // 6. SSO
    {
        Class c = NSClassFromString(@"SSOConfiguration");
        if (c) {
            Method m = class_getInstanceMethod(c, NSSelectorFromString(@"temporarilyDisableSafariSignIn"));
            if (m) { method_setImplementation(m, (IMP)QTTrue); QTIntInstalled(@"SSOConfiguration", @"temporarilyDisableSafariSignIn"); }
            Method m2 = class_getInstanceMethod(c, NSSelectorFromString(@"shouldEnableSafariSignIn"));
            if (m2) { method_setImplementation(m2, (IMP)QTTrue); QTIntInstalled(@"SSOConfiguration", @"shouldEnableSafariSignIn"); }
            Method m3 = class_getInstanceMethod(c, NSSelectorFromString(@"setTemporarilyDisableSafariSignIn:"));
            if (m3) { OrigSSOSetTemporary = method_getImplementation(m3); method_setImplementation(m3, (IMP)QTSetTemporaryDisabled); QTIntInstalled(@"SSOConfiguration", @"setTemporarilyDisableSafariSignIn:"); }
            Method m4 = class_getInstanceMethod(c, NSSelectorFromString(@"initWithClientID:supportedAccountServices:"));
            if (m4) { OrigSSOInit = method_getImplementation(m4); method_setImplementation(m4, (IMP)QTSSOInit); QTIntInstalled(@"SSOConfiguration", @"initWithClientID:supportedAccountServices:"); }
        }
    }
    // 7. Keychain
    for (NSString *n in @[@"SSOKeychainHelper", @"SSOKeychainCore"]) {
        Class c = NSClassFromString(n);
        if (!c) { QTIntMiss(n, @"accessGroup"); continue; }
        for (NSString *sel in @[@"accessGroup", @"sharedAccessGroup"]) {
            Method m = class_getClassMethod(c, NSSelectorFromString(sel));
            if (m) { method_setImplementation(m, (IMP)QTAccessGroup); QTIntInstalled(n, sel); }
        }
    }
    {
        Class c = NSClassFromString(@"UICKeyChainStore");
        Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(@"accessGroup")) : NULL;
        if (m) { method_setImplementation(m, (IMP)QTAccessGroup); QTIntInstalled(@"UICKeyChainStore", @"accessGroup"); }
    }
    // 8. Group container
    {
        Class c = NSClassFromString(@"NSFileManager");
        Method m = class_getInstanceMethod(c, NSSelectorFromString(@"containerURLForSecurityApplicationGroupIdentifier:"));
        if (m) { OrigGroupContainer = method_getImplementation(m); method_setImplementation(m, (IMP)QTGroupContainerURL); QTIntInstalled(@"NSFileManager", @"containerURLForSecurityApplicationGroupIdentifier:"); }
    }
    // 9. SSOClientLogin
    {
        Class c = NSClassFromString(@"SSOClientLogin");
        Method m = c ? class_getClassMethod(c, NSSelectorFromString(@"defaultSourceString")) : NULL;
        if (m) { method_setImplementation(m, (IMP)QTAppID); QTIntInstalled(@"SSOClientLogin", @"defaultSourceString"); }
    }
    // 10. DeviceCheck / AppAttest
    {
        Class dc = NSClassFromString(@"DCDevice");
        if (dc) QTDCSpoof_DCDevice(dc);
        else QTIntMiss(@"DCDevice", @"*");
        Class att = NSClassFromString(@"DCAppAttestService");
        if (att) QTSpoof_DCAppAttestService(att);
        else {
            // Try alternate names
            att = NSClassFromString(@"ASDeviceCheckService") ?: NSClassFromString(@"AppAttestService");
            if (att) QTSpoof_DCAppAttestService(att);
            else QTIntMiss(@"DCAppAttestService", @"*");
        }
    }
    // 11. BotGuard / PoToken / Integrity generic
    QTSpoof_BotGuardAndPoToken();

    // 12. Network header spoof
    QTInstallNetworkSpoof();

    // 13. Additional hardening: spoof receipt presence via NSBundle appStoreReceiptURL
    {
        Class c = NSClassFromString(@"NSBundle");
        SEL sel = NSSelectorFromString(@"appStoreReceiptURL");
        Method m = class_getInstanceMethod(c, sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            IMP rep = imp_implementationWithBlock(^NSURL*(id self){
                NSURL *real = ((NSURL*(*)(id,SEL))orig)(self, sel);
                if (self == NSBundle.mainBundle && !real) {
                    // Return a fake receipt URL that exists on disk
                    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"quietube-fake-receipt"];
                    [[NSFileManager defaultManager] createFileAtPath:tmp contents:[NSData data] attributes:nil];
                    return [NSURL fileURLWithPath:tmp];
                }
                return real;
            });
            method_setImplementation(m, rep);
            QTIntInstalled(@"NSBundle", @"appStoreReceiptURL");
        }
    }

    QTCount(@"integrity: installed");
}

NSString *QTIntegrityReport(void) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"Integrity: sideloaded=%@ hooks=%lu misses=%lu\n",
        QTIntSideloadedCheck()?@"yes":@"no", (unsigned long)QTIntHookCount, (unsigned long)QTIntMissCount];
    for (NSString *line in QTIntLog) [s appendFormat:@"  %@\n", line];
    return s;
}
