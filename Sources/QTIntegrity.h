#import <Foundation/Foundation.h>
// QTIntegrity — bulletproof sideload / Attest / PoToken bypass
// Covers: bundle spoof, DeviceCheck, AppAttest, BotGuard, PoToken, receipt,
// GUL/Firebase, keychain, group container, BotGuard JS, and network context.
// All hooks are class-scan driven so renames in future YT builds still hit.
void QTInstallIntegrity(void);
BOOL QTIntegrityIsSideloaded(void);
NSString *QTIntegrityReport(void);
