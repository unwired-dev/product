#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSNotificationName const UnwiredLanguageDidChange;
FOUNDATION_EXPORT NSDictionary *UnwiredLanguageSettings(void);
FOUNDATION_EXPORT BOOL UnwiredSetLanguage(NSString *language);
FOUNDATION_EXPORT NSString *UnwiredNativeText(NSString *key);
