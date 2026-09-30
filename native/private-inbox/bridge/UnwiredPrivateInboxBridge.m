#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(UnwiredPrivateInbox, NSObject)
RCT_EXTERN_METHOD(open:(NSString *)seed resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(setUnread:(NSString *)identifier unread:(BOOL)unread resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
@end
