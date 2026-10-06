#import <Foundation/Foundation.h>
void QTInstallStreamFallback(void);
BOOL QTStreamFallbackHandleError(id overlay, NSError *error, double savedTime);
// Persistent WEB client mode: user can opt-in to avoid PoToken entirely.
// When enabled at launch, every InnerTube request is rewritten to WEB -- no code 14.
BOOL QTStreamFallbackUsesWebClient(void);
void QTStreamFallbackSetUseWebClient(BOOL useWeb);
NSString *QTStreamFallbackReport(void);
