#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(UnwiredRegistration, NSObject)
RCT_EXTERN_METHOD(restore:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(signIn:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(authorizeGmail:(BOOL)reselect resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
@end
