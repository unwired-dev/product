#import "AppDelegate.h"
#import <React/RCTBundleURLProvider.h>
#import <ReactAppDependencyProvider/RCTAppDependencyProvider.h>
#import <os/log.h>

@interface AppDelegate ()
@property(nonatomic, strong) RCTReactNativeFactory *reactFactory;
@property(nonatomic, strong) NSMutableArray<NSWindowController *> *inboxWindows;
@property(nonatomic) NSUInteger nextWindowNumber;
#if UNWIRED_NATIVE_TESTING
@property(nonatomic, strong) NSTimer *workTimer;
@property(nonatomic) NSUInteger workTicks;
@property(nonatomic, copy) NSString *sessionID;
#endif
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  self.dependencyProvider = [RCTAppDependencyProvider new];
  self.reactFactory = [[RCTReactNativeFactory alloc] initWithDelegate:self];
  self.inboxWindows = [NSMutableArray new];
  [self installMenus];
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
  [self newWindow:nil];
  [NSApp activateIgnoringOtherApps:YES];
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
  window.title = [@"Inbox " stringByAppendingString:windowID];
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

- (void)installMenus
{
  NSMenu *main = [NSMenu new];
  NSMenuItem *appItem = [main addItemWithTitle:@"Unwired Mail" action:nil keyEquivalent:@""];
  NSMenu *app = [[NSMenu alloc] initWithTitle:@"Unwired Mail"];
  appItem.submenu = app;
  [app addItemWithTitle:@"Hide Unwired Mail" action:@selector(hide:) keyEquivalent:@"h"];
  [app addItem:[NSMenuItem separatorItem]];
  [app addItemWithTitle:@"Quit Unwired Mail" action:@selector(terminate:) keyEquivalent:@"q"];

  NSMenuItem *fileItem = [main addItemWithTitle:@"File" action:nil keyEquivalent:@""];
  NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
  fileItem.submenu = file;
  NSMenuItem *newItem = [file addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@"n"];
  newItem.target = self;
  [file addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];

  NSMenuItem *editItem = [main addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
  NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
  editItem.submenu = edit;
  [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

  NSMenuItem *windowItem = [main addItemWithTitle:@"Window" action:nil keyEquivalent:@""];
  NSMenu *windows = [[NSMenu alloc] initWithTitle:@"Window"];
  windowItem.submenu = windows;
  NSMenuItem *focus = [windows addItemWithTitle:@"Show Inbox" action:@selector(focusInbox:) keyEquivalent:@"0"];
  focus.target = self;
  [windows addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
  NSMenuItem *next = [windows addItemWithTitle:@"Next Window" action:@selector(nextWindow:) keyEquivalent:@"`"];
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
