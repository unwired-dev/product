#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(UnwiredAssistance, NSObject)
RCT_EXTERN_METHOD(availability:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(summarize:(NSString *)request input:(NSString *)input resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(cancel:(NSString *)request resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
@end
