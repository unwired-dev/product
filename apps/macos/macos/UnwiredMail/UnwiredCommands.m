#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

// The Commands… menu item, Command-P, tells the key window's JavaScript to open its Command Palette.
NSNotificationName const UnwiredOpenCommandPalette = @"UnwiredOpenCommandPalette";
// Closing a window whose composer holds unsaved edits asks its JavaScript first.
NSNotificationName const UnwiredWindowShouldClose = @"UnwiredWindowShouldClose";

// The windows whose composer holds edits that closing them would lose.
static NSMutableSet<NSString *> *guardedWindows(void)
{
  static NSMutableSet<NSString *> *windows;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ windows = [NSMutableSet set]; });
  return windows;
}

// Called on the main thread by the window and application delegates.
BOOL UnwiredCloseGuarded(NSString *identifier)
{
  return identifier != nil && [guardedWindows() containsObject:identifier];
}

// Each Inbox window's Mail Profile, which AppKit saves with its restorable state.
static NSMutableDictionary<NSString *, NSString *> *windowProfiles(void)
{
  static NSMutableDictionary<NSString *, NSString *> *profiles;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ profiles = [NSMutableDictionary dictionary]; });
  return profiles;
}

NSString *UnwiredWindowProfile(NSString *identifier)
{
  return identifier == nil ? nil : windowProfiles()[identifier];
}

NSString *UnwiredGuardedWindow(void)
{
  for (NSWindow *window in NSApp.windows) {
    if (UnwiredCloseGuarded(window.identifier)) return window.identifier;
  }
  return nil;
}

@interface UnwiredCommands : RCTEventEmitter <RCTBridgeModule>
@end

@implementation UnwiredCommands
RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (NSArray<NSString *> *)supportedEvents { return @[@"openCommandPalette", @"windowShouldClose", @"settingsClosed"]; }

- (void)startObserving
{
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(openCommandPalette:)
      name:UnwiredOpenCommandPalette object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowShouldClose:)
      name:UnwiredWindowShouldClose object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsClosed:)
      name:@"UnwiredSettingsClosed" object:nil];
}

- (void)stopObserving
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)openCommandPalette:(NSNotification *)notification
{
  [self sendEventWithName:@"openCommandPalette" body:@{@"window": notification.object ?: @""}];
}

- (void)windowShouldClose:(NSNotification *)notification
{
  [self sendEventWithName:@"windowShouldClose" body:@{@"window": notification.object ?: @""}];
}

- (void)settingsClosed:(NSNotification *)notification
{
  [self sendEventWithName:@"settingsClosed" body:notification.object];
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

// The composer marks its window while closing it would lose edits.
RCT_EXPORT_METHOD(guardClose:(NSString *)identifier guarded:(BOOL)guarded)
{
  if (guarded) {
    [guardedWindows() addObject:identifier];
  } else {
    [guardedWindows() removeObject:identifier];
  }
}

// A refused close also cancels any Quit waiting for this composer.
RCT_EXPORT_METHOD(finishClose:(NSString *)identifier allowed:(BOOL)allowed)
{
  if (!allowed) {
    [NSNotificationCenter.defaultCenter postNotificationName:@"UnwiredWindowCloseCancelled" object:identifier];
    return;
  }
  [guardedWindows() removeObject:identifier];
  [windowNamed(identifier) performClose:nil];
}

// Every Inbox window's Settings entry points open the one Settings window, as Command-, does.
RCT_EXPORT_METHOD(openSettings:(nonnull NSNumber *)requestSerial)
{
  [NSApp sendAction:NSSelectorFromString(@"showSettings:") to:NSApp.delegate from:requestSerial];
}

// The Settings window closes itself once no Inbox can open, as after signing out.
RCT_EXPORT_METHOD(closeSettings)
{
  [NSApp sendAction:NSSelectorFromString(@"closeSettings:") to:NSApp.delegate from:nil];
}

// The Settings window's palette returns to an Inbox window, as Window > Show Inbox does.
RCT_EXPORT_METHOD(focusInbox)
{
  [NSApp sendAction:NSSelectorFromString(@"focusInbox:") to:NSApp.delegate from:nil];
}

RCT_EXPORT_METHOD(setWindowProfile:(NSString *)identifier profile:(NSString *)profile)
{
  windowProfiles()[identifier] = profile;
  [windowNamed(identifier) invalidateRestorableState];
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
