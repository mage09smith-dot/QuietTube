#import <Foundation/Foundation.h>
void QTInstallStreamFallback(void);
BOOL QTStreamFallbackHandleError(id overlay, NSError *error, double savedTime);
NSString *QTStreamFallbackReport(void);
