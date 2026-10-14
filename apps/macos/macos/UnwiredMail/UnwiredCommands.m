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

// The control that had keyboard focus in each window when its Command Palette opened, which
// closing the palette hands focus back to: an Inbox row or button as well as a text field. Weak,
// so a closed window is forgotten; a removed control can live on in React Native's recycled views.
static NSMapTable<NSWindow *, NSView *> *savedResponders(void)
{
  static NSMapTable<NSWindow *, NSView *> *responders;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ responders = [NSMapTable weakToWeakObjectsMapTable]; });
  return responders;
}

static NSWindow *windowNamed(NSString *identifier)
{
  for (NSWindow *window in NSApp.windows) {
    if ([window.identifier isEqualToString:identifier]) return window;
  }
  return nil;
}

RCT_EXPORT_METHOD(saveFocus:(NSString *)identifier)
{
  NSWindow *window = windowNamed(identifier);
  if (window == nil) return;
  // Forget an earlier opening's control, which a palette that left with its screen never restored:
  // React Native recycles a removed view into another place, which could otherwise get focus.
  [savedResponders() removeObjectForKey:window];
  NSResponder *responder = window.firstResponder;
  // A focused text field edits through the window's shared field editor; keep the field itself.
  if ([responder isKindOfClass:NSTextView.class] && ((NSTextView *)responder).isFieldEditor) {
    responder = (NSResponder *)((NSTextView *)responder).delegate;
  }
  if ([responder isKindOfClass:NSView.class]) {
    [savedResponders() setObject:(NSView *)responder forKey:window];
  }
}

RCT_EXPORT_METHOD(restoreFocus:(NSString *)identifier)
{
  NSWindow *window = windowNamed(identifier);
  if (window == nil) return;
  NSView *view = [savedResponders() objectForKey:window];
  [savedResponders() removeObjectForKey:window];
  // Only a control still in this window gets focus back.
  if (view.window == window) {
    [window makeFirstResponder:view];
  }
}
@end
