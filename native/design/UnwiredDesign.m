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
// The compact Inbox and reader supply their own Back pill; restore native chrome when they leave.
// A screen popped by the edge swipe reports onPop, so its own Back can follow.
@interface UnwiredNavigationChromeView : UIView
@property (nonatomic, weak) UINavigationController *navigation;
@property (nonatomic, weak) UINavigationController *stack;
@property (nonatomic, weak) UIViewController *screen;
@property (nonatomic) BOOL previousHidden;
@property (nonatomic, copy) RCTDirectEventBlock onPop;
@end

@implementation UnwiredNavigationChromeView
- (void)didMoveToWindow
{
  [super didMoveToWindow];
  if (self.window == nil) {
    [self.navigation setNavigationBarHidden:self.previousHidden animated:NO];
    self.navigation = nil;
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
    [navigation setNavigationBarHidden:YES animated:NO];
  }
}
@end

@interface UnwiredNavigationChromeManager : RCTViewManager
@end

@implementation UnwiredNavigationChromeManager
RCT_EXPORT_MODULE(UnwiredNavigationChrome)
RCT_EXPORT_VIEW_PROPERTY(onPop, RCTDirectEventBlock)
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
static NSMenu *UnwiredMenuOf(NSString *title, NSArray<NSDictionary *> *sections, id target, NSColor *destructiveColor);

// An item sends `select:` to `target` with its `id`; `symbol`, `checked` and `disabled` are optional.
static NSMenuItem *UnwiredMenuItem(NSDictionary *item, id target, NSColor *destructiveColor)
{
  NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:item[@"title"] action:nil keyEquivalent:@""];
  NSString *symbol = item[@"symbol"];
  NSImage *image = symbol == nil ? nil : [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
  if ([item[@"destructive"] boolValue]) {
    menuItem.attributedTitle = [[NSAttributedString alloc] initWithString:item[@"title"]
        attributes:@{NSForegroundColorAttributeName: destructiveColor}];
    image = [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithHierarchicalColor:destructiveColor]];
  }
  menuItem.image = image;
  menuItem.state = [item[@"checked"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  menuItem.enabled = ![item[@"disabled"] boolValue];
  NSArray<NSDictionary *> *items = item[@"items"];
  if (items != nil) {
    menuItem.submenu = UnwiredMenuOf(item[@"title"], @[@{@"items": items}], target, destructiveColor);
  } else {
    menuItem.target = target;
    menuItem.action = @selector(select:);
    menuItem.representedObject = item[@"id"];
  }
  return menuItem;
}

// Sections of items, set apart by separators.
static NSMenu *UnwiredMenuOf(NSString *title, NSArray<NSDictionary *> *sections, id target, NSColor *destructiveColor)
{
  NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
  menu.autoenablesItems = NO;
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
  return UnwiredMenuOf(@"", self.sections, self, self.destructiveColor);
}

- (void)select:(NSMenuItem *)sender
{
  if (self.onSelect) self.onSelect(@{@"id": sender.representedObject});
}
@end
#else
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
        NSMutableArray<UIMenuElement *> *sections = [NSMutableArray new];
        for (NSDictionary *section in weakSelf.sections) {
          NSMutableArray<UIMenuElement *> *elements = [NSMutableArray new];
          for (NSDictionary *item in section[@"items"]) [elements addObject:[weakSelf element:item]];
          UIMenu *group = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                        options:UIMenuOptionsDisplayInline children:elements];
          if ([section[@"palette"] boolValue]) group.preferredElementSize = UIMenuElementSizeMedium;
          [sections addObject:group];
        }
        return [UIMenu menuWithChildren:sections];
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

- (UIMenuElement *)element:(NSDictionary *)item
{
  UIImage *image = [UIImage systemImageNamed:item[@"symbol"]];
  NSArray<NSDictionary *> *items = item[@"items"];
  if (items != nil) {
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray new];
    for (NSDictionary *child in items) [children addObject:[self element:child]];
    return [UIMenu menuWithTitle:item[@"title"] image:image identifier:nil options:0 children:children];
  }
  NSString *identifier = item[@"id"];
  __weak UnwiredContextMenuView *weakSelf = self;
  UIAction *action = [UIAction actionWithTitle:item[@"title"] image:image identifier:nil
      handler:^(__unused UIAction *action) {
        if (weakSelf.onSelect) weakSelf.onSelect(@{@"id": identifier});
      }];
  if ([item[@"destructive"] boolValue]) action.attributes = UIMenuElementAttributesDestructive;
  return action;
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

#if TARGET_OS_OSX
// Answers one pop-up menu with its chosen item's id, or null when nothing was chosen.
@interface UnwiredMenuChoice : NSObject
@property (nonatomic, copy) RCTPromiseResolveBlock resolve;
@end

@implementation UnwiredMenuChoice
- (void)select:(NSMenuItem *)sender { [self answer:sender.representedObject]; }

- (void)answer:(id)value
{
  if (self.resolve) self.resolve(value);
  self.resolve = nil;
}
@end

// A control's menu: pull-down below it, or a pop-up whose checked item lies over it. React Native
// macOS's ActionSheetIOS menu has no checked or destructive items and no separators.
@interface UnwiredMenu : NSObject <RCTBridgeModule>
@end

@implementation UnwiredMenu
@synthesize viewRegistry_DEPRECATED = _viewRegistry_DEPRECATED;
RCT_EXPORT_MODULE()

- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }

RCT_EXPORT_METHOD(show:(nonnull NSNumber *)anchor
                  sections:(NSArray<NSDictionary *> *)sections
                  destructiveColor:(id)destructiveColor
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSView *view = [self.viewRegistry_DEPRECATED viewForReactTag:anchor];
  UnwiredMenuChoice *choice = [UnwiredMenuChoice new];
  choice.resolve = resolve;
  NSMenu *menu = UnwiredMenuOf(@"", sections, choice, [RCTConvert NSColor:destructiveColor]);
  NSMenuItem *checked = nil;
  for (NSMenuItem *item in menu.itemArray) {
    if (item.state == NSControlStateValueOn) checked = item;
  }
  NSRect bounds = view.bounds;
  // The checked item's top lies on the control's top edge; a pull-down menu starts at its bottom.
  CGFloat y = (checked != nil) == view.isFlipped ? NSMinY(bounds) : NSMaxY(bounds);
  // Tracking returns once the menu closes, after sending a chosen item's action.
  if (view.window != nil && menu.numberOfItems > 0) {
    [menu popUpMenuPositioningItem:checked atLocation:NSMakePoint(NSMinX(bounds), y) inView:view];
  }
  [choice answer:[NSNull null]];
}
@end
#endif

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
