#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// The Commands… menu item, Command-P, tells the key window's JavaScript to open its Command Palette.
NSNotificationName const UnwiredOpenCommandPalette = @"UnwiredOpenCommandPalette";

@interface UnwiredCommands : RCTEventEmitter <RCTBridgeModule>
@end

@implementation UnwiredCommands
RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (NSArray<NSString *> *)supportedEvents { return @[@"openCommandPalette"]; }

- (void)startObserving
{
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(openCommandPalette:)
      name:UnwiredOpenCommandPalette object:nil];
}

- (void)stopObserving
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)openCommandPalette:(NSNotification *)notification
{
  [self sendEventWithName:@"openCommandPalette" body:@{@"window": notification.object ?: @""}];
}
@end
