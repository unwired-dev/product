#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(UnwiredErrorReporting, NSObject)
RCT_EXTERN_METHOD(errorReportingRead:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(errorReportingConsent:(BOOL)enabled renewIdentity:(BOOL)renewIdentity generation:(double)generation resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(errorReportingSave:(double)generation document:(NSString *)document resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(errorReportingRequest:(NSString *)operation body:(NSString *)body generation:(double)generation resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(errorReportingTakeNative:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
@end
