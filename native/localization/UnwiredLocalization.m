#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import "UnwiredLanguagePreferences.h"

@interface UnwiredLocalization : RCTEventEmitter <RCTBridgeModule>
@end

@implementation UnwiredLocalization
RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (NSDictionary *)constantsToExport { return UnwiredLanguageSettings(); }
- (NSArray<NSString *> *)supportedEvents { return @[@"languageSettingsChanged"]; }

- (void)startObserving
{
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(localeChanged:)
      name:NSCurrentLocaleDidChangeNotification object:nil];
}

- (void)stopObserving
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)localeChanged:(NSNotification *)notification
{
  [self sendEventWithName:@"languageSettingsChanged" body:nil];
}

RCT_EXPORT_METHOD(getSettings:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(UnwiredLanguageSettings());
}

RCT_EXPORT_METHOD(setLanguage:(NSString *)language resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
  // The bridge converts JavaScript null to nil for NSString arguments.
  if (!UnwiredSetLanguage(language)) {
    reject(@"unsupported_language", @"Unsupported interface language.", nil);
    return;
  }
  resolve(UnwiredLanguageSettings());
}
@end
