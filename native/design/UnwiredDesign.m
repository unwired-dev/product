#import <React/RCTView.h>
#import <React/RCTViewManager.h>

// SF Symbols for both hosts and the Mac's Liquid Glass; the hosts target iOS and macOS 27.
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>

typedef NSView UnwiredPlatformView;

// Core React Native modal accessibility properties are not implemented on Mac.
@interface UnwiredModalBackgroundView : RCTView
@property (nonatomic) BOOL accessibilityElementsHidden;
@end

@implementation UnwiredModalBackgroundView
- (void)setAccessibilityElementsHidden:(BOOL)hidden
{
  if (_accessibilityElementsHidden == hidden) return;
  _accessibilityElementsHidden = hidden;
  NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
}
- (BOOL)isAccessibilityElement
{
  return self.accessibilityElementsHidden ? NO : [super isAccessibilityElement];
}
- (NSArray *)accessibilityChildren
{
  return self.accessibilityElementsHidden ? @[] : [super accessibilityChildren];
}
- (id)accessibilityHitTest:(NSPoint)point
{
  return self.accessibilityElementsHidden ? nil : [super accessibilityHitTest:point];
}
@end

@interface UnwiredModalBackgroundManager : RCTViewManager
@end

@implementation UnwiredModalBackgroundManager
RCT_EXPORT_MODULE(UnwiredModalBackground)
RCT_EXPORT_VIEW_PROPERTY(accessibilityElementsHidden, BOOL)
- (RCTView *)view { return [UnwiredModalBackgroundView new]; }
@end

@interface UnwiredSymbolView : NSImageView
@property (nonatomic, copy) NSString *name;
@property (nonatomic) CGFloat size;
@property (nonatomic, strong) NSColor *color;
@end

@implementation UnwiredSymbolView
- (instancetype)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    self.imageScaling = NSImageScaleNone;
    self.imageAlignment = NSImageAlignCenter;
    self.accessibilityElement = NO;
  }
  return self;
}
- (void)setName:(NSString *)name { _name = [name copy]; [self render]; }
- (void)setSize:(CGFloat)size { _size = size; [self render]; }
- (void)setColor:(NSColor *)color { _color = color; self.contentTintColor = color; }
- (void)render
{
  NSImageSymbolConfiguration *configuration =
      [NSImageSymbolConfiguration configurationWithPointSize:self.size weight:NSFontWeightRegular];
  self.image = self.name == nil ? nil
      : [[NSImage imageWithSystemSymbolName:self.name accessibilityDescription:nil]
            imageWithSymbolConfiguration:configuration];
}
@end

@interface UnwiredGlassView : NSGlassEffectView
@end

@implementation UnwiredGlassView
@end
#else
#import <UIKit/UIKit.h>

typedef UIView UnwiredPlatformView;

@interface UnwiredSymbolView : UIImageView
@property (nonatomic, copy) NSString *name;
@property (nonatomic) CGFloat size;
@property (nonatomic, strong) UIColor *color;
@end

@implementation UnwiredSymbolView
- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    self.contentMode = UIViewContentModeCenter;
  }
  return self;
}
- (void)setName:(NSString *)name { _name = [name copy]; [self render]; }
- (void)setSize:(CGFloat)size { _size = size; [self render]; }
- (void)setColor:(UIColor *)color { _color = color; self.tintColor = color; }
- (void)render
{
  UIImageSymbolConfiguration *configuration =
      [UIImageSymbolConfiguration configurationWithPointSize:self.size weight:UIImageSymbolWeightRegular];
  self.image = self.name == nil ? nil
      : [UIImage systemImageNamed:self.name withConfiguration:configuration];
}
@end

#endif

#if !TARGET_OS_OSX
// The compact Inbox supplies its own Back pill; restore native chrome when it leaves. The compact
// reader keeps the system bar, whose Back is named backLabel and shows backCount beside the
// chevron, with surface behind the bar. A screen popped by Back or the edge swipe reports onPop,
// so its own route can follow.
@interface UnwiredNavigationChromeView : UIView
@property (nonatomic, weak) UINavigationController *navigation;
@property (nonatomic, weak) UINavigationController *stack;
@property (nonatomic, weak) UIViewController *screen;
@property (nonatomic) BOOL previousHidden;
@property (nonatomic, copy) RCTDirectEventBlock onPop;
@property (nonatomic, copy) NSString *backLabel;
@property (nonatomic, copy) NSString *backCount;
@property (nonatomic, strong) UIColor *surface;
@end

// The count on a disk, as Mail's Back shows unread mail; the template image takes the bar's tint
// and the number shows the glass through it.
static UIImage *UnwiredCountDisk(NSString *count)
{
  NSDictionary *attributes = @{
    NSFontAttributeName : [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold]
  };
  CGSize text = [count sizeWithAttributes:attributes];
  CGFloat height = 22;
  CGFloat width = MAX(height, ceil(text.width) + 10);
  UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width, height)]
      imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blackColor setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, width, height)
                                    cornerRadius:height / 2] fill];
        CGContextSetBlendMode(context.CGContext, kCGBlendModeClear);
        [count drawAtPoint:CGPointMake((width - text.width) / 2, (height - text.height) / 2)
            withAttributes:attributes];
      }];
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@implementation UnwiredNavigationChromeView
- (void)didMoveToWindow
{
  [super didMoveToWindow];
  if (self.window == nil) {
    // A collapsed split view's nested stacks share its outer bar, so a screen covered by another
    // keeps its bar state until it returns; restoring it would set the covering screen's bar.
    if (![self.stack.viewControllers containsObject:self.navigation]
        || self.stack.topViewController == self.navigation) {
      [self.navigation setNavigationBarHidden:self.previousHidden animated:NO];
      self.navigation = nil;
    }
    // A covered screen stays in the stack that showed it; a popped one has left it while the
    // stack is still shown.
    dispatch_async(dispatch_get_main_queue(), ^{
      UIViewController *ancestor = self.screen;
      while (ancestor != nil && ancestor != self.stack) ancestor = ancestor.parentViewController;
      if (self.window == nil && ancestor == nil && self.stack.viewIfLoaded.window != nil && self.onPop) {
        self.onPop(@{});
      }
    });
    return;
  }
  UIResponder *responder = self;
  while (responder != nil && ![responder isKindOfClass:[UIViewController class]]) {
    responder = responder.nextResponder;
  }
  self.screen = (UIViewController *)responder;
  UINavigationController *navigation = self.screen.navigationController;
  // A collapsed split view nests each column's navigation in one outer stack, which pops them.
  UINavigationController *stack = navigation;
  while (stack.navigationController.splitViewController != nil
         && stack.navigationController.splitViewController == stack.splitViewController) {
    stack = stack.navigationController;
  }
  self.stack = stack;
  if (navigation != nil && navigation != self.navigation) {
    self.navigation = navigation;
    self.previousHidden = navigation.navigationBarHidden;
    // UIKit pops a collapsed split view's screen by the edge swipe only while its bar shows.
    [navigation setNavigationBarHidden:self.backLabel == nil || stack == navigation animated:NO];
  }
  [self updateBack];
}

- (void)didSetProps:(NSArray<NSString *> *)changedProps
{
  [self updateBack];
}

// The Back to the screen beneath is that screen's backBarButtonItem.
- (void)updateBack
{
  NSArray<UIViewController *> *screens = self.stack.viewControllers;
  NSUInteger index = [screens indexOfObject:self.navigation];
  if (self.backLabel == nil || self.window == nil || index == NSNotFound || index == 0) return;
  // React Native owns the screen's own background; its column's view lies behind the bar too.
  self.navigation.view.backgroundColor = self.surface;
  UIBarButtonItem *back = self.backCount.length == 0
      ? [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil]
      : [[UIBarButtonItem alloc] initWithImage:UnwiredCountDisk(self.backCount)
                                         style:UIBarButtonItemStylePlain
                                        target:nil
                                        action:nil];
  back.accessibilityLabel = self.backLabel;
  screens[index - 1].navigationItem.backBarButtonItem = back;
}
@end

@interface UnwiredNavigationChromeManager : RCTViewManager
@end

@implementation UnwiredNavigationChromeManager
RCT_EXPORT_MODULE(UnwiredNavigationChrome)
RCT_EXPORT_VIEW_PROPERTY(onPop, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(backLabel, NSString)
RCT_EXPORT_VIEW_PROPERTY(backCount, NSString)
RCT_EXPORT_VIEW_PROPERTY(surface, UIColor)
- (UIView *)view { return [UnwiredNavigationChromeView new]; }
@end
#endif

// The system context menu for its content: long-press or pointer secondary click on iPhone and
// iPad, right-click or Control-click on the Mac. Sections are separated groups of items, each an
// `id`, `title` and SF Symbol `symbol`, optionally `destructive` or a submenu of `items`; a
// `palette` section shows its items side by side on iPhone and iPad.
@interface UnwiredContextMenuView : RCTView
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@property (nonatomic, copy) RCTDirectEventBlock onSelect;
#if TARGET_OS_OSX
@property (nonatomic, strong) NSColor *destructiveColor;
#else
@property (nonatomic, strong) UIColor *previewColor;
@property (nonatomic) CGFloat previewRadius;
#endif
@end

#if TARGET_OS_OSX
// A menu item for each entry: an action reporting its `id` to `target`'s `select:`, or a submenu.
// An optional `subtitle` shows beneath the title and `checked` adds a checkmark.
static NSMenuItem *UnwiredMenuItem(NSDictionary *item, id target, NSColor *destructiveColor)
{
  NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:item[@"title"] action:nil keyEquivalent:@""];
  NSString *symbol = item[@"symbol"];
  NSImage *image = symbol.length > 0 ? [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] : nil;
  if ([item[@"destructive"] boolValue]) {
    menuItem.attributedTitle = [[NSAttributedString alloc] initWithString:item[@"title"]
        attributes:@{NSForegroundColorAttributeName: destructiveColor}];
    image = [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithHierarchicalColor:destructiveColor]];
  }
  menuItem.image = image;
  menuItem.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
  NSString *subtitle = item[@"subtitle"];
  if (subtitle.length > 0) menuItem.subtitle = subtitle;
  if ([item[@"checked"] boolValue]) menuItem.state = NSControlStateValueOn;
  NSArray<NSDictionary *> *items = item[@"items"];
  if (items != nil) {
    menuItem.submenu = [[NSMenu alloc] initWithTitle:item[@"title"]];
    for (NSDictionary *child in items) [menuItem.submenu addItem:UnwiredMenuItem(child, target, destructiveColor)];
  } else {
    menuItem.target = target;
    menuItem.action = @selector(select:);
    menuItem.representedObject = item[@"id"];
  }
  return menuItem;
}

static NSMenu *UnwiredMenu(NSArray<NSDictionary *> *sections, id target, NSColor *destructiveColor)
{
  NSMenu *menu = [NSMenu new];
  for (NSDictionary *section in sections) {
    if (menu.numberOfItems > 0) [menu addItem:[NSMenuItem separatorItem]];
    for (NSDictionary *item in section[@"items"]) [menu addItem:UnwiredMenuItem(item, target, destructiveColor)];
  }
  return menu;
}

@implementation UnwiredContextMenuView
- (NSMenu *)menuForEvent:(NSEvent *)event
{
  if (self.sections.count == 0) return [super menuForEvent:event];
  return UnwiredMenu(self.sections, self, self.destructiveColor);
}

- (void)select:(NSMenuItem *)sender
{
  if (self.onSelect) self.onSelect(@{@"id": sender.representedObject});
}
@end
#else
static UIMenuElement *UnwiredMenuElement(NSDictionary *item, void (^select)(NSString *identifier))
{
  NSString *symbol = item[@"symbol"];
  UIImage *image = symbol.length > 0 ? [UIImage systemImageNamed:symbol] : nil;
  NSArray<NSDictionary *> *items = item[@"items"];
  if (items != nil) {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray new];
    for (NSDictionary *child in items) [children addObject:UnwiredMenuElement(child, select)];
    return [UIMenu menuWithTitle:item[@"title"] image:image identifier:nil options:0 children:children];
  }
  NSString *identifier = item[@"id"];
  UIAction *action = [UIAction actionWithTitle:item[@"title"] image:image identifier:nil
      handler:^(__unused UIAction *action) { select(identifier); }];
  if ([item[@"destructive"] boolValue]) action.attributes = UIMenuElementAttributesDestructive;
  NSString *subtitle = item[@"subtitle"];
  if (subtitle.length > 0) action.subtitle = subtitle;
  if ([item[@"checked"] boolValue]) action.state = UIMenuElementStateOn;
  return action;
}

static UIMenu *UnwiredMenu(NSArray<NSDictionary *> *sections, void (^select)(NSString *identifier))
{
  NSMutableArray<UIMenuElement *> *groups = [NSMutableArray new];
  for (NSDictionary *section in sections) {
    NSMutableArray<UIMenuElement *> *elements = [NSMutableArray new];
    for (NSDictionary *item in section[@"items"]) [elements addObject:UnwiredMenuElement(item, select)];
    UIMenu *group = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                  options:UIMenuOptionsDisplayInline children:elements];
    if ([section[@"palette"] boolValue]) group.preferredElementSize = UIMenuElementSizeMedium;
    [groups addObject:group];
  }
  return [UIMenu menuWithChildren:groups];
}

@interface UnwiredContextMenuView () <UIContextMenuInteractionDelegate>
@end

@implementation UnwiredContextMenuView
- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    [self addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
  }
  return self;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location
{
  if (self.sections.count == 0) return nil;
  __weak UnwiredContextMenuView *weakSelf = self;
  return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
      actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return UnwiredMenu(weakSelf.sections, ^(NSString *identifier) {
          if (weakSelf.onSelect) weakSelf.onSelect(@{@"id": identifier});
        });
      }];
}

// The pressed content lifts as an opaque card, as transparent rows and headers would not read.
- (UITargetedPreview *)preview
{
  UIPreviewParameters *parameters = [UIPreviewParameters new];
  parameters.backgroundColor = self.previewColor;
  parameters.visiblePath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:self.previewRadius];
  return [[UITargetedPreview alloc] initWithView:self parameters:parameters];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                                configuration:(UIContextMenuConfiguration *)configuration
        highlightPreviewForItemWithIdentifier:(id<NSCopying>)identifier
{
  return [self preview];
}

- (UITargetedPreview *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                                configuration:(UIContextMenuConfiguration *)configuration
          dismissalPreviewForItemWithIdentifier:(id<NSCopying>)identifier
{
  return [self preview];
}
@end
#endif

@interface UnwiredContextMenuManager : RCTViewManager
@end

@implementation UnwiredContextMenuManager
RCT_EXPORT_MODULE(UnwiredContextMenu)
RCT_EXPORT_VIEW_PROPERTY(sections, NSArray)
RCT_EXPORT_VIEW_PROPERTY(onSelect, RCTDirectEventBlock)
#if TARGET_OS_OSX
RCT_EXPORT_VIEW_PROPERTY(destructiveColor, NSColor)
#else
RCT_EXPORT_VIEW_PROPERTY(previewColor, UIColor)
RCT_EXPORT_VIEW_PROPERTY(previewRadius, CGFloat)
#endif
- (UnwiredPlatformView *)view { return [UnwiredContextMenuView new]; }
@end

// A pull-down button whose system menu opens on tap or click, with the same items as the context
// menu. Its React content draws the label and passes touches to the button: UIButton's primary
// action menu on iPhone and iPad, and a menu below the view on the Mac, also from the keyboard
// and VoiceOver.
#if TARGET_OS_OSX
@interface UnwiredMenuButtonView : RCTView
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@property (nonatomic, copy) RCTDirectEventBlock onSelect;
@end

@implementation UnwiredMenuButtonView
- (void)showMenu
{
  if (self.sections.count == 0) return;
  NSMenu *menu = UnwiredMenu(self.sections, self, NSColor.systemRedColor);
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(self.bounds) + 4) inView:self];
}

- (void)mouseDown:(NSEvent *)event { [self showMenu]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { NSRectFill(self.bounds); }

- (void)keyDown:(NSEvent *)event
{
  if ([event.charactersIgnoringModifiers isEqualToString:@" "] || [event.charactersIgnoringModifiers isEqualToString:@"\r"]) {
    [self showMenu];
  } else {
    [super keyDown:event];
  }
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityPopUpButtonRole; }
- (BOOL)accessibilityPerformPress
{
  [self showMenu];
  return YES;
}

- (void)select:(NSMenuItem *)sender
{
  if (self.onSelect) self.onSelect(@{@"id": sender.representedObject});
}
@end
#else
@interface UnwiredMenuButtonView : UIButton
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@property (nonatomic, copy) RCTDirectEventBlock onSelect;
@end

@implementation UnwiredMenuButtonView
- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    self.showsMenuAsPrimaryAction = YES;
  }
  return self;
}

- (void)setSections:(NSArray<NSDictionary *> *)sections
{
  _sections = [sections copy];
  __weak UnwiredMenuButtonView *weakSelf = self;
  self.menu = UnwiredMenu(_sections, ^(NSString *identifier) {
    if (weakSelf.onSelect) weakSelf.onSelect(@{@"id": identifier});
  });
}
@end
#endif

@interface UnwiredMenuButtonManager : RCTViewManager
@end

@implementation UnwiredMenuButtonManager
RCT_EXPORT_MODULE(UnwiredMenuButton)
RCT_EXPORT_VIEW_PROPERTY(sections, NSArray)
RCT_EXPORT_VIEW_PROPERTY(onSelect, RCTDirectEventBlock)
- (UnwiredPlatformView *)view { return [UnwiredMenuButtonView new]; }
@end

// A decorative symbol: its control carries the accessible label.
@interface UnwiredSymbolManager : RCTViewManager
@end

@implementation UnwiredSymbolManager
RCT_EXPORT_MODULE(UnwiredSymbol)
RCT_EXPORT_VIEW_PROPERTY(name, NSString)
RCT_EXPORT_VIEW_PROPERTY(size, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(color, UIColor)
- (UnwiredPlatformView *)view { return [UnwiredSymbolView new]; }
@end

#if TARGET_OS_OSX
// The navigation layer's material, drawn behind the controls laid over it. iOS uses expo-glass-effect.
@interface UnwiredGlassManager : RCTViewManager
@end

@implementation UnwiredGlassManager
RCT_EXPORT_MODULE(UnwiredGlass)
RCT_EXPORT_VIEW_PROPERTY(cornerRadius, CGFloat)
- (UnwiredPlatformView *)view { return [UnwiredGlassView new]; }
@end
#endif
