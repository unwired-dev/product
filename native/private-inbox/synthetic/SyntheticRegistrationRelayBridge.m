#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// Added only to registration Mock Mail Session builds, beside the relay it declares.
@interface RCT_EXTERN_MODULE(UnwiredSyntheticRegistration, RCTEventEmitter)
RCT_EXTERN_METHOD(answer:(NSString *)id reply:(NSString *)reply)
RCT_EXTERN_METHOD(refuse:(NSString *)id code:(NSString *)code)
RCT_EXTERN_METHOD(readState:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(saveState:(NSString *)state resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
@end
