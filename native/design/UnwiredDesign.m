#import <React/RCTView.h>
#import <React/RCTViewManager.h>

// SF Symbols and Liquid Glass for both hosts, which target iOS and macOS 27.
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
#import <React/UIView+React.h>
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

@interface UnwiredGlassView : UIVisualEffectView
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL interactive;
@end

@implementation UnwiredGlassView
- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithEffect:[UIGlassEffect new]])) {
    self.frame = frame;
    self.layer.cornerCurve = kCACornerCurveContinuous;
  }
  return self;
}
- (void)setCornerRadius:(CGFloat)cornerRadius
{
  _cornerRadius = cornerRadius;
  self.layer.cornerRadius = cornerRadius;
}
- (void)setInteractive:(BOOL)interactive
{
  _interactive = interactive;
  UIGlassEffect *effect = [UIGlassEffect new];
  effect.interactive = interactive;
  self.effect = effect;
}
// A visual effect view hosts subviews in its content view, where interactive glass sees their touches.
- (void)didUpdateReactSubviews
{
  for (UIView *subview in self.reactSubviews) [self.contentView addSubview:subview];
}
@end
#endif

#if !TARGET_OS_OSX
// The compact Inbox and reader supply their own Back pill; restore native chrome when they leave.
@interface UnwiredNavigationChromeView : UIView
@property (nonatomic, weak) UINavigationController *navigation;
@property (nonatomic) BOOL previousHidden;
@end

@implementation UnwiredNavigationChromeView
- (void)didMoveToWindow
{
  [super didMoveToWindow];
  if (self.window == nil) {
    [self.navigation setNavigationBarHidden:self.previousHidden animated:NO];
    self.navigation = nil;
    return;
  }
  UIResponder *responder = self;
  while (responder != nil && ![responder isKindOfClass:[UIViewController class]]) {
    responder = responder.nextResponder;
  }
  UINavigationController *navigation = ((UIViewController *)responder).navigationController;
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
@implementation UnwiredContextMenuView
- (NSMenu *)menuForEvent:(NSEvent *)event
{
  if (self.sections.count == 0) return [super menuForEvent:event];
  NSMenu *menu = [NSMenu new];
  for (NSDictionary *section in self.sections) {
    if (menu.numberOfItems > 0) [menu addItem:[NSMenuItem separatorItem]];
    for (NSDictionary *item in section[@"items"]) [menu addItem:[self menuItem:item]];
  }
  return menu;
}

- (NSMenuItem *)menuItem:(NSDictionary *)item
{
  NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:item[@"title"] action:nil keyEquivalent:@""];
  NSImage *image = [NSImage imageWithSystemSymbolName:item[@"symbol"] accessibilityDescription:nil];
  if ([item[@"destructive"] boolValue]) {
    menuItem.attributedTitle = [[NSAttributedString alloc] initWithString:item[@"title"]
        attributes:@{NSForegroundColorAttributeName: self.destructiveColor}];
    image = [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithHierarchicalColor:self.destructiveColor]];
  }
  menuItem.image = image;
  NSArray<NSDictionary *> *items = item[@"items"];
  if (items != nil) {
    menuItem.submenu = [[NSMenu alloc] initWithTitle:item[@"title"]];
    for (NSDictionary *child in items) [menuItem.submenu addItem:[self menuItem:child]];
  } else {
    menuItem.target = self;
    menuItem.action = @selector(select:);
    menuItem.representedObject = item[@"id"];
  }
  return menuItem;
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

// The navigation layer's material; on iOS a control group's content sits inside it.
@interface UnwiredGlassManager : RCTViewManager
@end

@implementation UnwiredGlassManager
RCT_EXPORT_MODULE(UnwiredGlass)
RCT_EXPORT_VIEW_PROPERTY(cornerRadius, CGFloat)
#if !TARGET_OS_OSX
RCT_EXPORT_VIEW_PROPERTY(interactive, BOOL)
#endif
- (UnwiredPlatformView *)view { return [UnwiredGlassView new]; }
@end
