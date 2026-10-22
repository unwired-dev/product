#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(UnwiredAssistanceQualification, NSObject)
RCT_EXTERN_METHOD(begin:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(record:(NSString *)line resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
@end
