#import <TargetConditionals.h>
#import <React/RCTView.h>
#import <React/RCTViewManager.h>

static NSString *const UnwiredCommandHintSeen = @"UnwiredCommandPaletteHintSeen";

#if !TARGET_OS_OSX
static UIResponder *UnwiredFirstResponder(UIView *view)
{
  if (view.isFirstResponder) return view;
  for (UIView *child in view.subviews) {
    UIResponder *responder = UnwiredFirstResponder(child);
    if (responder) return responder;
  }
  return nil;
}
#endif

@interface UnwiredCommandPaletteHeaderView : RCTView
@end

@implementation UnwiredCommandPaletteHeaderView
@end

@interface UnwiredCommandPaletteView : RCTView
#if !TARGET_OS_OSX
<UIGestureRecognizerDelegate>
#endif
@property(nonatomic, copy) RCTDirectEventBlock onCommandKey;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL active;
@property(nonatomic, copy) NSString *presentation;
@property(nonatomic) CGFloat headerInset;
#if TARGET_OS_OSX
@property(nonatomic, strong) id keyMonitor;
@property(nonatomic, weak) NSResponder *previousResponder;
#else
@property(nonatomic, weak) UIResponder *previousResponder;
@property(nonatomic, strong) UIPanGestureRecognizer *headerPan;
#endif
@end

@implementation UnwiredCommandPaletteView

#if TARGET_OS_OSX
- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  if (self.keyMonitor) {
    [NSEvent removeMonitor:self.keyMonitor];
    self.keyMonitor = nil;
  }
  if (!self.window) return;
  __weak UnwiredCommandPaletteView *weakSelf = self;
  self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
    UnwiredCommandPaletteView *owner = weakSelf;
    if (!owner.enabled || owner.window != NSApp.keyWindow || event.window != owner.window) return event;
    NSString *key = nil;
    NSEventModifierFlags modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift)) == NSEventModifierFlagCommand && [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"p"]) key = @"open";
    if (owner.active && !(modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift))) {
      NSResponder *responder = owner.window.firstResponder;
      if ([responder conformsToProtocol:@protocol(NSTextInputClient)] && [(id<NSTextInputClient>)responder hasMarkedText]) return event;
      if (event.keyCode == 126) key = @"up";
      if (event.keyCode == 125) key = @"down";
      if (event.keyCode == 53) key = @"escape";
      if (event.keyCode == 36 || event.keyCode == 76) key = @"enter";
    }
    if (!key || !owner.onCommandKey) return event;
    if ([key isEqualToString:@"open"] && !owner.active) owner.previousResponder = owner.window.firstResponder;
    owner.onCommandKey(@{@"key": key});
    return nil;
  }];
}

- (void)dealloc
{
  if (_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
}

#else
- (BOOL)canBecomeFirstResponder { return YES; }

- (void)didMoveToWindow
{
  [super didMoveToWindow];
  [self.headerPan.view removeGestureRecognizer:self.headerPan];
  if (self.window) {
    self.headerPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(headerDragged:)];
    self.headerPan.delegate = self;
    [self.window addGestureRecognizer:self.headerPan];
  }
  if (self.window && self.enabled && !UnwiredFirstResponder(self.window)) [self becomeFirstResponder];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch
{
  CGPoint point = [touch locationInView:self];
  if (!self.enabled || self.active || !CGRectContainsPoint(self.bounds, point) || point.y < self.headerInset) return NO;
  for (UIView *view = touch.view; view && view != self.window; view = view.superview) {
    if ([view isKindOfClass:UnwiredCommandPaletteHeaderView.class] || [view isKindOfClass:UINavigationBar.class]) return YES;
  }
  return point.y <= self.headerInset + 60;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture
{
  CGPoint movement = [self.headerPan translationInView:self];
  return movement.y > 0 && movement.y > fabs(movement.x) * 1.5;
}

- (void)headerDragged:(UIPanGestureRecognizer *)gesture
{
  CGPoint movement = [gesture translationInView:self];
  if (gesture.state == UIGestureRecognizerStateEnded && movement.y >= 36 && self.onCommandKey) {
    self.previousResponder = UnwiredFirstResponder(self.window);
    self.onCommandKey(@{@"key": @"open"});
  }
}

- (void)setEnabled:(BOOL)enabled
{
  _enabled = enabled;
  if (enabled && self.window && !UnwiredFirstResponder(self.window)) [self becomeFirstResponder];
}


- (NSArray<UIKeyCommand *> *)keyCommands
{
  if (!self.enabled) return @[];
  NSMutableArray<UIKeyCommand *> *commands = [NSMutableArray new];
  if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
    UIKeyCommand *open = [UIKeyCommand keyCommandWithInput:@"p" modifierFlags:UIKeyModifierCommand action:@selector(openCommands:)];
    open.wantsPriorityOverSystemBehavior = YES;
    [commands addObject:open];
  }
  if (self.active) {
    for (NSString *input in @[UIKeyInputUpArrow, UIKeyInputDownArrow, UIKeyInputEscape]) {
      UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:input modifierFlags:0 action:@selector(navigateCommands:)];
      command.wantsPriorityOverSystemBehavior = YES;
      [commands addObject:command];
    }
  }
  return commands;
}

- (void)openCommands:(UIKeyCommand *)command
{
  if (!self.active) self.previousResponder = UnwiredFirstResponder(self.window);
  if (self.onCommandKey) self.onCommandKey(@{@"key": @"open"});
}

- (void)navigateCommands:(UIKeyCommand *)command
{
  NSString *key = [command.input isEqualToString:UIKeyInputUpArrow] ? @"up" : [command.input isEqualToString:UIKeyInputDownArrow] ? @"down" : @"escape";
  if (self.onCommandKey) self.onCommandKey(@{@"key": key});
}
#endif

- (void)setPresentation:(NSString *)presentation
{
  BOOL active = [presentation isEqualToString:@"open"];
  if (active && !_active && !self.previousResponder) {
#if TARGET_OS_OSX
    self.previousResponder = self.window.firstResponder;
#else
    self.previousResponder = UnwiredFirstResponder(self.window);
#endif
  }
  if (!active) {
    if (_active && [presentation isEqualToString:@"dismissed"]) {
#if TARGET_OS_OSX
      [self.window makeFirstResponder:self.previousResponder];
#else
      if (![self.previousResponder becomeFirstResponder]) [self becomeFirstResponder];
#endif
    }
    self.previousResponder = nil;
  }
  _active = active;
  _presentation = [presentation copy];
#if !TARGET_OS_OSX
  if ([presentation isEqualToString:@"completed"]) {
    // Wait for the palette input to detach; a destination that took focus keeps it.
    __weak UnwiredCommandPaletteView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      UnwiredCommandPaletteView *owner = weakSelf;
      if (owner.enabled && [owner.presentation isEqualToString:@"completed"] && owner.window && !UnwiredFirstResponder(owner.window)) {
        [owner becomeFirstResponder];
      }
    });
  }
#endif
}
@end

@interface UnwiredCommandPalette : RCTViewManager
@end

@implementation UnwiredCommandPalette
RCT_EXPORT_MODULE()
RCT_EXPORT_VIEW_PROPERTY(onCommandKey, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(enabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(presentation, NSString)
RCT_EXPORT_VIEW_PROPERTY(headerInset, CGFloat)

+ (BOOL)requiresMainQueueSetup { return YES; }
- (RCTView *)view { return [UnwiredCommandPaletteView new]; }
- (NSDictionary *)constantsToExport
{
  return @{@"hintSeen": @([NSUserDefaults.standardUserDefaults boolForKey:UnwiredCommandHintSeen])};
}
RCT_EXPORT_METHOD(markHintSeen)
{
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:UnwiredCommandHintSeen];
}
@end

@interface UnwiredCommandPaletteHeader : RCTViewManager
@end

@implementation UnwiredCommandPaletteHeader
RCT_EXPORT_MODULE()
+ (BOOL)requiresMainQueueSetup { return YES; }
- (RCTView *)view { return [UnwiredCommandPaletteHeaderView new]; }
@end
