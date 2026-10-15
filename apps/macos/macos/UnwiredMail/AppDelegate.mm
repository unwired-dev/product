#import "AppDelegate.h"
#import "UnwiredLanguagePreferences.h"
#import <React/RCTBundleURLProvider.h>
#import <ReactAppDependencyProvider/RCTAppDependencyProvider.h>
#import <os/log.h>
#import <GoogleSignIn/GoogleSignIn.h>

// UnwiredCommands.m: a window whose composer holds unsaved edits asks it before closing.
extern "C" BOOL UnwiredCloseGuarded(NSString *identifier);
extern "C" NSString *UnwiredGuardedWindow(void);

// Shared Swift in native/private-inbox receives APNs registration and Gmail wake hints.
@protocol UnwiredPushWakes
+ (void)registerDeviceToken:(NSData *)token;
+ (void)receiveRemoteNotification:(NSDictionary *)payload complete:(void (^)(NSString *))complete;
@end

@interface AppDelegate ()
@property(nonatomic, strong) RCTReactNativeFactory *reactFactory;
@property(nonatomic, strong) NSMutableArray<NSWindowController *> *inboxWindows;
@property(nonatomic) NSUInteger nextWindowNumber;
@property(nonatomic, copy) NSString *quittingWindow;
#if UNWIRED_NATIVE_TESTING
@property(nonatomic, strong) NSTimer *workTimer;
@property(nonatomic) NSUInteger workTicks;
@property(nonatomic, copy) NSString *sessionID;
#endif
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self
      andSelector:@selector(handleGoogleURL:reply:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
  self.dependencyProvider = [RCTAppDependencyProvider new];
  self.reactFactory = [[RCTReactNativeFactory alloc] initWithDelegate:self];
  self.inboxWindows = [NSMutableArray new];
  [self installMenus];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateLanguage:)
      name:UnwiredLanguageDidChange object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateLanguage:)
      name:NSCurrentLocaleDidChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelWindowClose:)
      name:@"UnwiredWindowCloseCancelled" object:nil];
#if UNWIRED_NATIVE_TESTING
  self.sessionID = NSUUID.UUID.UUIDString;
  __weak AppDelegate *weakSelf = self;
  self.workTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
    AppDelegate *owner = weakSelf;
    owner.workTicks += 1;
    [owner recordLifecycle:@"work"];
  }];
#endif
  [self recordLifecycle:@"launch"];
  // Ad-hoc builds lack the APNs entitlement; registration fails there and the interval poll remains.
  [NSApp registerForRemoteNotifications];
  [self newWindow:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)application:(NSApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
  [(Class<UnwiredPushWakes>)NSClassFromString(@"UnwiredPushWakes") registerDeviceToken:deviceToken];
}

- (void)application:(NSApplication *)application didReceiveRemoteNotification:(NSDictionary<NSString *, id> *)userInfo
{
  [(Class<UnwiredPushWakes>)NSClassFromString(@"UnwiredPushWakes") receiveRemoteNotification:userInfo
      complete:^(NSString *result) {}];
}

- (void)handleGoogleURL:(NSAppleEventDescriptor *)event reply:(NSAppleEventDescriptor *)reply
{
  NSString *value = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
  NSURL *url = value ? [NSURL URLWithString:value] : nil;
  if (url) [[GIDSignIn sharedInstance] handleURL:url];
}

- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge
{
  return [self bundleURL];
}

- (NSURL *)bundleURL
{
#if DEBUG
  return [[RCTBundleURLProvider sharedSettings] jsBundleURLForBundleRoot:@"index"];
#else
  NSURL *url = [NSBundle.mainBundle URLForResource:@"main" withExtension:@"jsbundle"];
  NSAssert(url != nil, @"Packaged JavaScript is required.");
  return url;
#endif
}

- (void)newWindow:(id)sender
{
  self.nextWindowNumber += 1;
  NSString *windowID = [NSString stringWithFormat:@"%lu", (unsigned long)self.nextWindowNumber];
  NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 720)
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
  window.title = [UnwiredNativeText(@"windowTitle") stringByReplacingOccurrencesOfString:@"{{number}}" withString:windowID];
  window.identifier = [@"inbox-window-" stringByAppendingString:windowID];
  window.accessibilityIdentifier = window.identifier;
  window.minSize = NSMakeSize(760, 480);
  window.releasedWhenClosed = NO;
  window.delegate = self;
  window.autorecalculatesKeyViewLoop = YES;
  NSView *rootView = [self.reactFactory.rootViewFactory viewWithModuleName:@"UnwiredMail"
      initialProperties:@{@"windowId": windowID}];
  rootView.frame = window.contentView.bounds;
  NSViewController *content = [NSViewController new];
  content.view = rootView;
  window.contentViewController = content;
  NSWindowController *controller = [[NSWindowController alloc] initWithWindow:window];
  [self.inboxWindows addObject:controller];
  [window center];
  [window setFrameTopLeftPoint:NSMakePoint(window.frame.origin.x + 24 * (self.inboxWindows.count - 1),
      NSMaxY(window.frame) - 24 * (self.inboxWindows.count - 1))];
  [controller showWindow:self];
  [window makeKeyAndOrderFront:self];
  [NSApp addWindowsItem:window title:window.title filename:NO];
  [self recordLifecycle:@"window-open"];
}

// Command-P opens the key Inbox window's Command Palette; its JavaScript listens for the window.
- (void)showCommands:(id)sender
{
  NSWindow *window = NSApp.keyWindow;
  if (window.identifier == nil) return;
  [NSNotificationCenter.defaultCenter postNotificationName:@"UnwiredOpenCommandPalette" object:window.identifier];
}

- (void)focusInbox:(id)sender
{
  if (self.inboxWindows.count == 0) {
    [self newWindow:sender];
    return;
  }
  NSWindow *window = self.inboxWindows.firstObject.window;
  [window deminiaturize:self];
  [window makeKeyAndOrderFront:self];
}

- (void)nextWindow:(id)sender
{
  if (self.inboxWindows.count == 0) return;
  NSUInteger index = [self.inboxWindows indexOfObjectPassingTest:
      ^BOOL(NSWindowController *controller, NSUInteger index, BOOL *stop) {
        return controller.window == NSApp.keyWindow;
      }];
  NSUInteger next = index == NSNotFound ? 0 : (index + 1) % self.inboxWindows.count;
  NSWindow *window = self.inboxWindows[next].window;
  [window deminiaturize:self];
  [window makeKeyAndOrderFront:self];
}

- (BOOL)windowShouldClose:(NSWindow *)window
{
  if (!UnwiredCloseGuarded(window.identifier)) return YES;
  [NSNotificationCenter.defaultCenter postNotificationName:@"UnwiredWindowShouldClose" object:window.identifier];
  return NO;
}

// Quit advances through guarded windows only after each composer allows closing.
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
  NSString *guarded = UnwiredGuardedWindow();
  if (guarded == nil) return NSTerminateNow;
  self.quittingWindow = guarded;
  for (NSWindow *window in NSApp.windows) {
    if ([window.identifier isEqualToString:guarded]) {
      [window deminiaturize:self];
      [window makeKeyAndOrderFront:self];
      [window performClose:self];
    }
  }
  return NSTerminateCancel;
}

- (void)cancelWindowClose:(NSNotification *)notification
{
  if ([self.quittingWindow isEqualToString:notification.object]) self.quittingWindow = nil;
}

- (void)windowWillClose:(NSNotification *)notification
{
  NSWindow *window = notification.object;
  [NSApp removeWindowsItem:window];
  NSIndexSet *closed = [self.inboxWindows indexesOfObjectsPassingTest:
      ^BOOL(NSWindowController *controller, NSUInteger index, BOOL *stop) {
        return controller.window == window;
      }];
  [self.inboxWindows removeObjectsAtIndexes:closed];
  // Destroy this React surface while the application factory and JS runtime remain alive.
  window.contentViewController = nil;
  [self recordLifecycle:@"window-close"];
  if ([self.quittingWindow isEqualToString:window.identifier]) {
    self.quittingWindow = nil;
    // The original termination request must finish returning Cancel before retrying.
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:self]; });
  }
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
  [self recordLifecycle:@"window-focus"];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible
{
  [self focusInbox:sender];
  return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
#if UNWIRED_NATIVE_TESTING
  [self.workTimer invalidate];
#endif
  [self recordLifecycle:@"quit"];
}

- (void)updateLanguage:(NSNotification *)notification
{
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateLanguage:notification]; });
    return;
  }
  [self installMenus];
  for (NSWindowController *controller in self.inboxWindows) {
    NSWindow *window = controller.window;
    NSString *number = [window.identifier substringFromIndex:@"inbox-window-".length];
    window.title = [UnwiredNativeText(@"windowTitle") stringByReplacingOccurrencesOfString:@"{{number}}" withString:number];
    [NSApp addWindowsItem:window title:window.title filename:NO];
  }
}

- (void)installMenus
{
  NSMenu *main = [NSMenu new];
  NSMenuItem *appItem = [main addItemWithTitle:UnwiredNativeText(@"app") action:nil keyEquivalent:@""];
  NSMenu *app = [[NSMenu alloc] initWithTitle:UnwiredNativeText(@"app")];
  appItem.submenu = app;
  [app addItemWithTitle:UnwiredNativeText(@"hide") action:@selector(hide:) keyEquivalent:@"h"];
  [app addItem:[NSMenuItem separatorItem]];
  [app addItemWithTitle:UnwiredNativeText(@"quit") action:@selector(terminate:) keyEquivalent:@"q"];

  NSMenuItem *fileItem = [main addItemWithTitle:UnwiredNativeText(@"file") action:nil keyEquivalent:@""];
  NSMenu *file = [[NSMenu alloc] initWithTitle:UnwiredNativeText(@"file")];
  fileItem.submenu = file;
  NSMenuItem *newItem = [file addItemWithTitle:UnwiredNativeText(@"newWindow") action:@selector(newWindow:) keyEquivalent:@"n"];
  newItem.target = self;
  [file addItemWithTitle:UnwiredNativeText(@"closeWindow") action:@selector(performClose:) keyEquivalent:@"w"];

  NSMenuItem *editItem = [main addItemWithTitle:UnwiredNativeText(@"edit") action:nil keyEquivalent:@""];
  NSMenu *edit = [[NSMenu alloc] initWithTitle:UnwiredNativeText(@"edit")];
  editItem.submenu = edit;
  [edit addItemWithTitle:UnwiredNativeText(@"copy") action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:UnwiredNativeText(@"selectAll") action:@selector(selectAll:) keyEquivalent:@"a"];

  NSMenuItem *viewItem = [main addItemWithTitle:UnwiredNativeText(@"view") action:nil keyEquivalent:@""];
  NSMenu *view = [[NSMenu alloc] initWithTitle:UnwiredNativeText(@"view")];
  viewItem.submenu = view;
  NSMenuItem *commands = [view addItemWithTitle:UnwiredNativeText(@"commands") action:@selector(showCommands:) keyEquivalent:@"p"];
  commands.target = self;

  NSMenuItem *windowItem = [main addItemWithTitle:UnwiredNativeText(@"window") action:nil keyEquivalent:@""];
  NSMenu *windows = [[NSMenu alloc] initWithTitle:UnwiredNativeText(@"window")];
  windowItem.submenu = windows;
  NSMenuItem *focus = [windows addItemWithTitle:UnwiredNativeText(@"showInbox") action:@selector(focusInbox:) keyEquivalent:@"0"];
  focus.target = self;
  [windows addItemWithTitle:UnwiredNativeText(@"minimize") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  NSMenuItem *next = [windows addItemWithTitle:UnwiredNativeText(@"nextWindow") action:@selector(nextWindow:) keyEquivalent:@"`"];
  next.target = self;
  [windows addItem:[NSMenuItem separatorItem]];
  NSApp.mainMenu = main;
  NSApp.windowsMenu = windows;
}

- (void)recordLifecycle:(NSString *)event
{
  if (![event isEqualToString:@"work"]) {
    os_log_info(OS_LOG_DEFAULT, "Mac lifecycle %{public}@ windows=%lu", event, (unsigned long)self.inboxWindows.count);
  }
#if UNWIRED_NATIVE_TESTING
  NSString *path = NSProcessInfo.processInfo.environment[@"UNWIRED_LIFECYCLE_PATH"];
  if (path.length == 0) return;
  NSDictionary *record = @{@"event": event, @"pid": @(NSProcessInfo.processInfo.processIdentifier),
      @"session": self.sessionID ?: @"starting", @"windows": @(self.inboxWindows.count), @"workTicks": @(self.workTicks)};
  NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
  NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
  if (handle == nil) return;
  [handle seekToEndOfFile];
  [handle writeData:data];
  [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
  [handle closeFile];
#endif
}
@end
