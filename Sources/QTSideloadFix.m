#import "QTSideloadFix.h"
#import "QTCore.h"
#import "QTDiagnosticLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static NSString * const QTYouTubeBundleID = @"com.google.ios.youtube";
static NSString * const QTYouTubeName = @"YouTube";

static BOOL QTIsSideloadedCheck(void) {
    NSURL *receipt = NSBundle.mainBundle.appStoreReceiptURL;
    NSString *path = receipt.path;
    if (!path.length) return YES;
    return ![NSFileManager.defaultManager fileExistsAtPath:path];
}
BOOL QTIsSideloaded(void) { return QTIsSideloadedCheck(); }

// ---- helpers ----


// ---- bundle spoof ----
static IMP OrigBundleIdentifier;
static IMP OrigInfoDictionary;
static IMP OrigInfoValue;
static IMP OrigBundleWithIdentifier;

static NSString *QTBundleIdentifier(id self, SEL _cmd) {
    if (self == NSBundle.mainBundle) return QTYouTubeBundleID;
    return OrigBundleIdentifier ? ((NSString*(*)(id,SEL))OrigBundleIdentifier)(self,_cmd) : nil;
}
static NSDictionary *QTInfoDictionary(id self, SEL _cmd) {
    NSDictionary *info = OrigInfoDictionary ? ((NSDictionary*(*)(id,SEL))OrigInfoDictionary)(self,_cmd) : nil;
    if (self != NSBundle.mainBundle || !info) return info;
    NSMutableDictionary *m = [info mutableCopy];
    m[@"CFBundleIdentifier"] = QTYouTubeBundleID;
    m[@"CFBundleDisplayName"] = QTYouTubeName;
    m[@"CFBundleName"] = QTYouTubeName;
    return [m copy];
}
static id QTInfoValue(id self, SEL _cmd, NSString *key) {
    if (self == NSBundle.mainBundle) {
        if ([key isEqualToString:@"CFBundleIdentifier"]) return QTYouTubeBundleID;
        if ([key isEqualToString:@"CFBundleDisplayName"] || [key isEqualToString:@"CFBundleName"]) return QTYouTubeName;
    }
    return OrigInfoValue ? ((id(*)(id,SEL,id))OrigInfoValue)(self,_cmd,key) : nil;
}
static id QTBundleWithIdentifier(id self, SEL _cmd, NSString *bid) {
    if ([bid isEqualToString:QTYouTubeBundleID]) return NSBundle.mainBundle;
    return OrigBundleWithIdentifier ? ((id(*)(id,SEL,id))OrigBundleWithIdentifier)(self,_cmd,bid) : nil;
}

// ---- YTVersionUtils ----
static NSString *QTAppName(id self, SEL _cmd) { return QTYouTubeName; }
static NSString *QTAppID(id self, SEL _cmd) { return QTYouTubeBundleID; }

// ---- isFromAppStore ----
static BOOL QTTrue(id self, SEL _cmd) { return YES; }

// ---- keychain accessGroup ----
static NSString *QTCurrentAccessGroup(void) {
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *q = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"QTDummyItem",
            (__bridge id)kSecAttrService: @"QTDummyService",
            (__bridge id)kSecReturnAttributes: @YES
        };
        CFTypeRef res = NULL;
        OSStatus s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        if (s == errSecItemNotFound) s = SecItemAdd((__bridge CFDictionaryRef)q, &res);
        if (s == errSecDuplicateItem) s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        if (s == errSecSuccess && res) {
            NSDictionary *a = CFBridgingRelease(res);
            id v = a[(__bridge id)kSecAttrAccessGroup];
            if ([v isKindOfClass:NSString.class]) group = [v copy];
            else if (res) CFRelease(res);
        } else if (res) CFRelease(res);
    });
    return group;
}
static NSString *QTAccessGroup(id self, SEL _cmd) { return QTCurrentAccessGroup(); }

// ---- SSOConfiguration ----
static IMP OrigSSOSetTemporary;
static IMP OrigSSOInit;
static void QTSetTemporaryDisabled(id self, SEL _cmd, BOOL v) {
    if (OrigSSOSetTemporary) ((void(*)(id,SEL,BOOL))OrigSSOSetTemporary)(self,_cmd,NO);
}
static id QTSSOInit(id self, SEL _cmd, id cid, id svc) {
    id val = OrigSSOInit ? ((id(*)(id,SEL,id,id))OrigSSOInit)(self,_cmd,cid,svc) : self;
    if (val) @try {
        [val setValue:QTYouTubeName forKey:@"_shortAppName"];
        [val setValue:QTYouTubeBundleID forKey:@"_applicationIdentifier"];
    } @catch (__unused NSException *e) {}
    return val;
}

// ---- group container ----
static IMP OrigGroupContainer;
static NSURL *QTGroupContainerURL(id self, SEL _cmd, NSString *ident) {
    NSURL *orig = OrigGroupContainer ? ((NSURL*(*)(id,SEL,id))OrigGroupContainer)(self,_cmd,ident) : nil;
    if (orig || ![ident containsString:@"group."]) return orig;
    NSURL *sup = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] lastObject];
    if (!sup) return nil;
    NSURL *fb = [sup URLByAppendingPathComponent:@"AppGroup" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:fb withIntermediateDirectories:YES attributes:nil error:nil];
    return fb;
}

// ---- application delegate openURL shim ----
static IMP OrigSetDelegate;
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
        if (!class_getInstanceMethod(dc, openSel)) {
            class_addMethod(dc, openSel, (IMP)QTAppOpenURL, "B@:@@@");
        }
    }
    if (OrigSetDelegate) ((void(*)(id,SEL,id))OrigSetDelegate)(self,_cmd,del);
}

void QTInstallSideloadFix(void) {
    // Avoid QTDEnabled() before QTDConfigure -- constructor ordering.
    BOOL sideloaded = QTIsSideloadedCheck();

    // accessGroup must be primed early for SSO
    if (sideloaded) QTCurrentAccessGroup();

    // UIApplication setDelegate shim (fixes openURL on sideloaded)
    {
        Class c = NSClassFromString(@"UIApplication");
        Method m = class_getInstanceMethod(c, NSSelectorFromString(@"setDelegate:"));
        if (m) OrigSetDelegate = method_getImplementation(m);
        // use QTHook for safety where possible, but direct replace for UIApplication which may not be loaded yet
        if (c && m) method_setImplementation(m, (IMP)QTSetDelegate);
        else {
            // fallback via QTHook if class not yet present -- will retry via QTHook path
            QTHook(@"UIApplication", @"setDelegate:", @"v@", ^id(IMP old, SEL sel){
                OrigSetDelegate = old;
                return ^(id obj, id del){ QTSetDelegate(obj, sel, del); };
            });
        }
    }

    NSString *realID = NSBundle.mainBundle.bundleIdentifier;
    if (![realID isEqualToString:QTYouTubeBundleID]) {
        // bundleWithIdentifier: (class method on NSBundle)
        Class mc = object_getClass((id)NSClassFromString(@"NSBundle"));
        SEL sel = NSSelectorFromString(@"bundleWithIdentifier:");
        Method m = class_getClassMethod(NSClassFromString(@"NSBundle"), sel);
        if (m) { OrigBundleWithIdentifier = method_getImplementation(m); method_setImplementation(m, (IMP)QTBundleWithIdentifier); }
        // bundleIdentifier
        {
            Class c = NSClassFromString(@"NSBundle");
            SEL s = NSSelectorFromString(@"bundleIdentifier");
            Method mm = class_getInstanceMethod(c, s);
            if (mm) { OrigBundleIdentifier = method_getImplementation(mm); method_setImplementation(mm, (IMP)QTBundleIdentifier); }
        }
        // infoDictionary
        {
            Class c = NSClassFromString(@"NSBundle");
            SEL s = NSSelectorFromString(@"infoDictionary");
            Method mm = class_getInstanceMethod(c, s);
            if (mm) { OrigInfoDictionary = method_getImplementation(mm); method_setImplementation(mm, (IMP)QTInfoDictionary); }
        }
        // objectForInfoDictionaryKey:
        {
            Class c = NSClassFromString(@"NSBundle");
            SEL s = NSSelectorFromString(@"objectForInfoDictionaryKey:");
            Method mm = class_getInstanceMethod(c, s);
            if (mm) { OrigInfoValue = method_getImplementation(mm); method_setImplementation(mm, (IMP)QTInfoValue); }
        }
    }

    // YTVersionUtils spoof (used for poToken / attestation client name)
    {
        Class c = NSClassFromString(@"YTVersionUtils");
        if (c) {
            Method m1 = class_getClassMethod(c, NSSelectorFromString(@"appName"));
            if (m1) method_setImplementation(m1, (IMP)QTAppName);
            Method m2 = class_getClassMethod(c, NSSelectorFromString(@"appID"));
            if (m2) method_setImplementation(m2, (IMP)QTAppID);
        } else {
            // deferred via QTHook
            QTHook(@"YTVersionUtils", @"appName", @"@", ^id(IMP old, SEL s){ return ^NSString*(id o){ return QTYouTubeName; }; });
            QTHook(@"YTVersionUtils", @"appID", @"@", ^id(IMP old, SEL s){ return ^NSString*(id o){ return QTYouTubeBundleID; }; });
        }
    }

    {
        Class c = NSClassFromString(@"GULAppEnvironmentUtil");
        Method m = c ? class_getClassMethod(c, NSSelectorFromString(@"isFromAppStore")) : NULL;
        if (m) method_setImplementation(m, (IMP)QTTrue);
        else QTHook(@"GULAppEnvironmentUtil", @"isFromAppStore", @"B", ^id(IMP old, SEL s){ return ^BOOL(id o){ return YES; }; });
    }
    {
        Class c = NSClassFromString(@"APMAEU");
        Method m = c ? class_getClassMethod(c, NSSelectorFromString(@"isFAS")) : NULL;
        if (m) method_setImplementation(m, (IMP)QTTrue);
        else QTHook(@"APMAEU", @"isFAS", @"B", ^id(IMP old, SEL s){ return ^BOOL(id o){ return YES; }; });
    }

    // SSO -- needed for Google sign-in on sideloaded bundle
    {
        Class c = NSClassFromString(@"SSOConfiguration");
        if (c) {
            Method m = class_getInstanceMethod(c, NSSelectorFromString(@"temporarilyDisableSafariSignIn"));
            if (m) {
                // BOOL getter -> YES
                method_setImplementation(m, (IMP)QTTrue);
            }
            Method m2 = class_getInstanceMethod(c, NSSelectorFromString(@"shouldEnableSafariSignIn"));
            if (m2) method_setImplementation(m2, (IMP)QTTrue);
            Method m3 = class_getInstanceMethod(c, NSSelectorFromString(@"setTemporarilyDisableSafariSignIn:"));
            if (m3) { OrigSSOSetTemporary = method_getImplementation(m3); method_setImplementation(m3, (IMP)QTSetTemporaryDisabled); }
            Method m4 = class_getInstanceMethod(c, NSSelectorFromString(@"initWithClientID:supportedAccountServices:"));
            if (m4) { OrigSSOInit = method_getImplementation(m4); method_setImplementation(m4, (IMP)QTSSOInit); }
        }
    }
    // keychain accessGroup
    for (NSString *clsName in @[@"SSOKeychainHelper", @"SSOKeychainCore"]) {
        Class c = NSClassFromString(clsName);
        if (!c) continue;
        for (NSString *sel in @[@"accessGroup", @"sharedAccessGroup"]) {
            Method m = class_getClassMethod(c, NSSelectorFromString(sel));
            if (m) method_setImplementation(m, (IMP)QTAccessGroup);
        }
    }
    {
        Class c = NSClassFromString(@"UICKeyChainStore");
        Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(@"accessGroup")) : NULL;
        if (m) method_setImplementation(m, (IMP)QTAccessGroup);
    }
    // group container fallback
    {
        Class c = NSClassFromString(@"NSFileManager");
        Method m = class_getInstanceMethod(c, NSSelectorFromString(@"containerURLForSecurityApplicationGroupIdentifier:"));
        if (m) { OrigGroupContainer = method_getImplementation(m); method_setImplementation(m, (IMP)QTGroupContainerURL); }
    }
    // SSOClientLogin defaultSourceString spoof
    {
        Class c = NSClassFromString(@"SSOClientLogin");
        Method m = c ? class_getClassMethod(c, NSSelectorFromString(@"defaultSourceString")) : NULL;
        if (m) method_setImplementation(m, (IMP)QTAppID);
    }

    QTCount(@"sideloadFix: installed");
}
