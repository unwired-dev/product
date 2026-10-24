#import <React/RCTUtils.h>
#import <React/RCTView.h>
#import <React/RCTViewManager.h>

// SF Symbols for both hosts and the Mac's Liquid Glass; the hosts target iOS and macOS 27.
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <React/RCTSurfaceTouchHandler.h>

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

// The Inbox window's Mailboxes sidebar: an AppKit split-view sidebar item showing this view's
// React children, so AppKit collapses and expands it with its own animation. While mounted, the view
// adds the item to its window's split view, beside the Inbox; the view itself takes no space.
// React Native macOS 0.81.9 has no split view; remove this view when it offers one.
@interface UnwiredSidebarView : RCTView
@property (nonatomic) CGFloat thickness;
@property (nonatomic, copy) RCTDirectEventBlock onCollapse;
@end

@implementation UnwiredSidebarView {
  NSViewController *_pane;
  // The pane is outside the React root view, so it delivers its own clicks to React.
  RCTSurfaceTouchHandler *_touchHandler;
  NSSplitViewItem *_item;
  __weak NSSplitViewController *_split;
}
- (instancetype)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    _pane = [NSViewController new];
    _pane.view = [RCTUIView new];
    _touchHandler = [RCTSurfaceTouchHandler new];
    [_touchHandler attachToView:_pane.view];
  }
  return self;
}
- (void)dealloc
{
  [self detach];
  [_touchHandler detachFromView:_pane.view];
}
- (void)didUpdateReactSubviews
{
  for (NSView *subview in self.reactSubviews) [_pane.view addSubview:subview];
}
- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  NSSplitViewController *split = (NSSplitViewController *)self.window.contentViewController;
  if (![split isKindOfClass:NSSplitViewController.class]) split = nil;
  if (split == _split && _item != nil) return;
  [self detach];
  if (split == nil) return;
  NSSplitViewItem *item = [NSSplitViewItem sidebarWithViewController:_pane];
  item.minimumThickness = self.thickness;
  item.maximumThickness = self.thickness;
  // A window at most 900pt wide starts without the sidebar, and narrowing a window below that hides it.
  item.collapsed = NSWidth(self.window.frame) <= 900;
  split.splitViewItems.lastObject.minimumThickness = 900 - self.thickness;
  [item addObserver:self forKeyPath:@"collapsed" options:0 context:nil];
  [split insertSplitViewItem:item atIndex:0];
  _item = item;
  _split = split;
  [self reportCollapse];
}
- (void)detach
{
  if (_item == nil) return;
  [_item removeObserver:self forKeyPath:@"collapsed"];
  [_split removeSplitViewItem:_item];
  _item = nil;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change
                       context:(void *)context
{
  [self reportCollapse];
}
- (void)reportCollapse
{
  if (self.onCollapse) self.onCollapse(@{@"collapsed": @(_item.collapsed)});
}
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

// The system Sign in with Apple button, black in Light and white in Dark per Apple's button styles.
// Its style is fixed at creation, so an appearance change replaces it. Remove this view when React
// Native macOS or a maintained package offers the button with an enabled state and both styles.
@interface UnwiredAppleIDButtonView : NSView
@property (nonatomic) BOOL enabled;
@property (nonatomic, copy) RCTDirectEventBlock onPress;
@end

@implementation UnwiredAppleIDButtonView {
  ASAuthorizationAppleIDButton *_button;
  BOOL _dark;
}
- (instancetype)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    _enabled = YES;
    [self render];
  }
  return self;
}
- (void)setEnabled:(BOOL)enabled { _enabled = enabled; _button.enabled = enabled; }
- (void)viewDidChangeEffectiveAppearance
{
  [super viewDidChangeEffectiveAppearance];
  [self render];
}
- (void)render
{
  BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[
    NSAppearanceNameAqua, NSAppearanceNameDarkAqua
  ]] isEqualToString:NSAppearanceNameDarkAqua];
  if (_button != nil && dark == _dark) return;
  _dark = dark;
  ASAuthorizationAppleIDButton *button = [ASAuthorizationAppleIDButton
      buttonWithType:ASAuthorizationAppleIDButtonTypeSignIn
               style:dark ? ASAuthorizationAppleIDButtonStyleWhite : ASAuthorizationAppleIDButtonStyleBlack];
  button.cornerRadius = 8;
  button.enabled = self.enabled;
  button.target = self;
  button.action = @selector(press);
  button.frame = self.bounds;
  button.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (_button == nil) {
    [self addSubview:button];
  } else {
    [self replaceSubview:_button with:button];
  }
  _button = button;
}
- (void)press
{
  if (self.onPress) self.onPress(@{});
}
@end

// A push button that AppKit draws, presses and focuses. A focus colour replaces the system focus
// ring, as Dark's accent/ink does.
@interface UnwiredFocusButton : NSButton
@property (nonatomic, copy) NSColor *focusColor;
@end

@implementation UnwiredFocusButton
- (void)setFocusColor:(NSColor *)focusColor
{
  _focusColor = [focusColor copy];
  self.focusRingType = focusColor == nil ? NSFocusRingTypeDefault : NSFocusRingTypeNone;
  [self showFocus:self.window.firstResponder == self];
}
- (BOOL)becomeFirstResponder
{
  BOOL became = [super becomeFirstResponder];
  if (became) [self showFocus:YES];
  return became;
}
- (BOOL)resignFirstResponder
{
  BOOL resigned = [super resignFirstResponder];
  if (resigned) [self showFocus:NO];
  return resigned;
}
- (void)showFocus:(BOOL)focused
{
  self.layer.cornerRadius = NSHeight(self.bounds) / 2;
  self.layer.borderWidth = focused && self.focusColor != nil ? 3 : 0;
  self.layer.borderColor = self.focusColor.CGColor;
}
@end

// The push button inside a plain view, so that React Native's wrapper stays out of accessibility and
// VoiceOver reaches only the button. A tint is the bezel colour of a primary or brand button, whose
// title is semibold. React Native macOS 0.81.9's Button is a TouchableOpacity; remove this view when
// React Native macOS offers an NSButton.
@interface UnwiredPushButtonView : NSView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSColor *tint;
@property (nonatomic, copy) NSColor *textColor;
@property (nonatomic, copy) NSColor *focusColor;
@property (nonatomic) BOOL destructive;
@property (nonatomic) BOOL enabled;
@property (nonatomic, copy) RCTDirectEventBlock onPress;
@end

@implementation UnwiredPushButtonView {
  UnwiredFocusButton *_button;
}
- (instancetype)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    _enabled = YES;
    _button = [UnwiredFocusButton new];
    _button.bezelStyle = NSBezelStylePush;
    _button.controlSize = NSControlSizeLarge;
    _button.wantsLayer = YES;
    _button.target = self;
    _button.action = @selector(press);
    _button.frame = self.bounds;
    _button.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_button];
  }
  return self;
}
// React Native forwards its accessibility props here, and its wrapper reports what this view does.
- (BOOL)isAccessibilityElement { return NO; }
- (void)setText:(NSString *)text { _text = [text copy]; [self render]; }
- (void)setLabel:(NSString *)label { _label = [label copy]; _button.accessibilityLabel = label; }
- (void)setTint:(NSColor *)tint { _tint = [tint copy]; [self render]; }
- (void)setTextColor:(NSColor *)textColor { _textColor = [textColor copy]; [self render]; }
- (void)setFocusColor:(NSColor *)focusColor { _focusColor = [focusColor copy]; _button.focusColor = focusColor; }
- (void)setDestructive:(BOOL)destructive { _destructive = destructive; _button.hasDestructiveAction = destructive; }
- (void)setEnabled:(BOOL)enabled { _enabled = enabled; [self render]; }
- (void)render
{
  _button.enabled = self.enabled;
  _button.bezelColor = self.tint;
  _button.tintProminence = self.tint ? NSTintProminencePrimary : NSTintProminenceAutomatic;
  NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
  paragraph.alignment = NSTextAlignmentCenter;
  NSColor *color = self.textColor ?: NSColor.controlTextColor;
  _button.attributedTitle = [[NSAttributedString alloc]
      initWithString:self.text ?: @""
          attributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:13
                                                     weight:self.tint ? NSFontWeightSemibold : NSFontWeightRegular],
            NSForegroundColorAttributeName : self.enabled ? color : [color colorWithAlphaComponent:0.4],
            NSParagraphStyleAttributeName : paragraph,
          }];
}
- (void)press
{
  if (self.onPress) self.onPress(@{});
}
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
// The bar's title view, sized as React Native lays out its content.
@interface UnwiredBarTitleView : UIView
@property (nonatomic, strong) UIView *content;
@end

@implementation UnwiredBarTitleView
- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
  }
  return self;
}
- (void)dealloc { [_content removeObserver:self forKeyPath:@"bounds"]; }
- (void)setContent:(UIView *)content
{
  [_content removeObserver:self forKeyPath:@"bounds"];
  if (_content.superview == self) [_content removeFromSuperview];
  _content = content;
  if (content != nil) {
    [content addObserver:self forKeyPath:@"bounds" options:0 context:nil];
    [self addSubview:content];
  }
  [self invalidateIntrinsicContentSize];
}
- (CGSize)intrinsicContentSize { return self.content.bounds.size; }
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
  [self invalidateIntrinsicContentSize];
}
@end

// Hides the native navigation bar while a compact screen shows its own header. A screen that names
// its Back in backLabel keeps the system bar instead, with backCount beside the chevron, surface
// behind the bar and its React Native child as the bar's title.
@interface UnwiredNavigationChromeView : UIView
@property (nonatomic, weak) UINavigationController *navigation;
@property (nonatomic, weak) UINavigationController *stack;
@property (nonatomic) BOOL previousHidden;
@property (nonatomic, strong) UnwiredBarTitleView *title;
@property (nonatomic, copy) NSString *backLabel;
@property (nonatomic, copy) NSString *backCount;
@property (nonatomic, strong) UIColor *surface;
@end

// UIKit fills a held Back's history menu from the screens' titles, which these columns leave empty,
// so it showed a blank capsule (#968); Back offers no menu, as react-native-screens'
// disableBackButtonMenu does.
@interface UnwiredBackItem : UIBarButtonItem
@end

@implementation UnwiredBackItem
- (void)setMenu:(UIMenu *)menu {}
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
      if (self.navigation.navigationItem.titleView == self.title) {
        self.navigation.navigationItem.titleView = nil;
      }
      self.navigation = nil;
    }
    return;
  }
  UIResponder *responder = self;
  while (responder != nil && ![responder isKindOfClass:[UIViewController class]]) {
    responder = responder.nextResponder;
  }
  UINavigationController *navigation = ((UIViewController *)responder).navigationController;
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
    [self updateHidden];
  }
  [self updateBack];
}

- (void)didSetProps:(NSArray<NSString *> *)changedProps
{
  // Only an uncovered screen sets the shared bar.
  if ([changedProps containsObject:@"backLabel"] && self.stack.topViewController == self.navigation) {
    [self updateHidden];
  }
  [self updateBack];
}

// React Native's child is the bar's title view rather than a subview of this zero-sized view.
- (void)didUpdateReactSubviews
{
  UIView *content = self.reactSubviews.firstObject;
  if (content != self.title.content) {
    if (self.title == nil) self.title = [UnwiredBarTitleView new];
    self.title.content = content;
  }
  [self updateBack];
}

// UIKit pops a collapsed split view's screen by the edge swipe only while its bar shows.
- (void)updateHidden
{
  [self.navigation setNavigationBarHidden:self.backLabel == nil || self.stack == self.navigation
                                 animated:NO];
}

// The Back to the screen beneath is that screen's backBarButtonItem.
- (void)updateBack
{
  NSArray<UIViewController *> *screens = self.stack.viewControllers;
  NSUInteger index = [screens indexOfObject:self.navigation];
  if (self.backLabel == nil || self.window == nil || index == NSNotFound || index == 0) return;
  // React Native owns the screen's own background; its column's view lies behind the bar too.
  self.navigation.view.backgroundColor = self.surface;
  self.navigation.navigationItem.titleView = self.title.content == nil ? nil : self.title;
  UIBarButtonItem *back = self.backCount.length == 0
      ? [[UnwiredBackItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil]
      : [[UnwiredBackItem alloc] initWithImage:UnwiredCountDisk(self.backCount)
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
static NSMenu *UnwiredMenuOf(NSString *title, NSArray<NSDictionary *> *sections, id target, NSColor *destructiveColor);

// An item sends `select:` to `target` with its `id`; `symbol`, `checked` and `disabled` are optional.
static NSMenuItem *UnwiredMenuItem(NSDictionary *item, id target, NSColor *destructiveColor)
{
  NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:item[@"title"] action:nil keyEquivalent:@""];
  if (item[@"accessibilityLabel"] != nil) menuItem.accessibilityLabel = item[@"accessibilityLabel"];
  NSString *symbol = item[@"symbol"];
  NSImage *image = symbol.length == 0 ? nil : [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
  if ([item[@"destructive"] boolValue]) {
    menuItem.attributedTitle = [[NSAttributedString alloc] initWithString:item[@"title"]
        attributes:@{NSForegroundColorAttributeName: destructiveColor}];
    image = [image imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithHierarchicalColor:destructiveColor]];
  }
  menuItem.image = image;
  // macOS 27 hides menu images by default; the design shows them.
  menuItem.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
  NSString *subtitle = item[@"subtitle"];
  if (subtitle.length > 0) menuItem.subtitle = subtitle;
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

// A control's menu, dropping below it with any checked item marked. React Native
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
  NSRect bounds = view.bounds;
  // The menu drops below its control, as the design's Mac menus do.
  CGFloat bottom = view.isFlipped ? NSMaxY(bounds) : NSMinY(bounds);
  // Tracking returns once the menu closes, after sending a chosen item's action.
  if (view.window != nil && menu.numberOfItems > 0) {
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(bounds), bottom) inView:view];
  }
  [choice answer:[NSNull null]];
}
@end

// A pop-up button that AppKit draws, focuses and opens: with a symbol, a pull-down showing it;
// otherwise a pop-up showing `text`, its chosen item's title. The button sits inside a plain view,
// so that React Native's wrapper stays out of accessibility and VoiceOver reaches only the button.
// React Native macOS 0.81.9 has no pop-up button; remove this view when it offers one.
@interface UnwiredPopUpButtonView : NSView
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *symbol;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSColor *destructiveColor;
@property (nonatomic) BOOL enabled;
@property (nonatomic, copy) RCTDirectEventBlock onSelect;
@end

@implementation UnwiredPopUpButtonView {
  NSPopUpButton *_button;
}
- (instancetype)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    _enabled = YES;
    _button = [[NSPopUpButton alloc] initWithFrame:self.bounds pullsDown:NO];
    _button.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _button.autoenablesItems = NO;
    [self addSubview:_button];
  }
  return self;
}
- (BOOL)isAccessibilityElement { return NO; }
- (void)setLabel:(NSString *)label { _label = [label copy]; _button.accessibilityLabel = label; }
- (void)setEnabled:(BOOL)enabled { _enabled = enabled; _button.enabled = enabled; }
// React Native applies the whole prop batch before rebuilding the menu.
- (void)didSetProps:(NSArray<NSString *> *)changedProps { [self render]; }
// The menu always shows the items React Native last gave it; a choice only reports their id.
- (void)render
{
  NSMenu *menu = UnwiredMenuOf(@"", @[@{@"items": self.items ?: @[]}], self,
                               self.destructiveColor ?: NSColor.systemRedColor);
  NSMenuItem *shown = [[NSMenuItem alloc] initWithTitle:self.text ?: @"" action:nil keyEquivalent:@""];
  if (self.symbol.length > 0) {
    shown.image = [NSImage imageWithSystemSymbolName:self.symbol accessibilityDescription:nil];
  }
  // A pull-down shows its first item, which its menu leaves out.
  _button.pullsDown = self.symbol.length > 0;
  if (_button.pullsDown) [menu insertItem:shown atIndex:0];
  _button.menu = menu;
  NSPopUpButtonCell *cell = _button.cell;
  cell.usesItemFromMenu = _button.pullsDown;
  if (!_button.pullsDown) {
    NSInteger checked = [menu.itemArray indexOfObjectPassingTest:^BOOL(NSMenuItem *item, NSUInteger i, BOOL *stop) {
      return item.state == NSControlStateValueOn;
    }];
    [_button selectItemAtIndex:checked == NSNotFound ? -1 : checked];
    cell.menuItem = shown;
  }
}
// AppKit selects the chosen item after this action, so the shown items return once it has.
- (void)select:(NSMenuItem *)sender
{
  if (self.onSelect) self.onSelect(@{@"id": sender.representedObject});
  dispatch_async(dispatch_get_main_queue(), ^{ [self render]; });
}
@end

// A question in a sheet on its anchor's window, answering the chosen button's index. React Native
// macOS's Alert asks over the key window and cannot withdraw a question its asker no longer owns.
@interface UnwiredAlert : NSObject <RCTBridgeModule>
@property (nonatomic, readonly) NSMutableDictionary<NSNumber *, NSAlert *> *shown;
@end

@implementation UnwiredAlert
@synthesize viewRegistry_DEPRECATED = _viewRegistry_DEPRECATED;
RCT_EXPORT_MODULE()

- (instancetype)init
{
  if ((self = [super init])) _shown = [NSMutableDictionary dictionary];
  return self;
}

- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }

// A complete selectable text, such as a link's destination, that scrolls beyond a few lines: an
// alert's own text grows the sheet past the screen.
static NSScrollView *UnwiredPassage(NSString *text)
{
  NSScrollView *scroll = [NSTextView scrollableTextView];
  scroll.drawsBackground = NO;
  scroll.frame = NSMakeRect(0, 0, 220, 1);
  NSTextView *view = scroll.documentView;
  view.editable = NO;
  view.drawsBackground = NO;
  view.alignment = NSTextAlignmentCenter;
  view.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
  view.textColor = NSColor.labelColor;
  view.textContainerInset = NSZeroSize;
  view.textContainer.lineFragmentPadding = 0;
  view.string = text;
  [view.layoutManager ensureLayoutForTextContainer:view.textContainer];
  CGFloat height = [view.layoutManager usedRectForTextContainer:view.textContainer].size.height;
  scroll.frame = NSMakeRect(0, 0, 220, MIN(ceil(height), 120));
  return scroll;
}

// The first button is the default. `cancel`, the last unless given, answers Escape, and
// `destructive` reads as destructive. A `symbol` replaces the app icon, and a `passage` shows
// below the detail.
RCT_EXPORT_METHOD(show:(nonnull NSNumber *)anchor
                  request:(nonnull NSNumber *)request
                  question:(NSDictionary *)question
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  NSWindow *window = [self.viewRegistry_DEPRECATED viewForReactTag:anchor].window;
  if (window == nil) {
    resolve([NSNull null]);
    return;
  }
  NSArray<NSString *> *buttons = [RCTConvert NSStringArray:question[@"buttons"]];
  id given = RCTNilIfNull(question[@"cancel"]);
  NSInteger cancel = given ? [RCTConvert NSInteger:given] : (NSInteger)buttons.count - 1;
  NSAlert *alert = [NSAlert new];
  alert.messageText = [RCTConvert NSString:question[@"title"]];
  alert.informativeText = [RCTConvert NSString:question[@"detail"]];
  for (NSString *button in buttons) [alert addButtonWithTitle:button];
  if (RCTNilIfNull(question[@"destructive"])) {
    alert.buttons[[RCTConvert NSInteger:question[@"destructive"]]].hasDestructiveAction = YES;
  }
  NSDictionary *symbol = RCTNilIfNull(question[@"symbol"]);
  if (symbol != nil) {
    NSImageSymbolConfiguration *look = [[NSImageSymbolConfiguration configurationWithPointSize:40 weight:NSFontWeightRegular]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[RCTConvert NSColor:symbol[@"color"]]]];
    alert.icon = [[NSImage imageWithSystemSymbolName:[RCTConvert NSString:symbol[@"name"]] accessibilityDescription:nil]
        imageWithSymbolConfiguration:look];
  }
  if (RCTNilIfNull(question[@"passage"])) alert.accessoryView = UnwiredPassage([RCTConvert NSString:question[@"passage"]]);
  // A first Cancel is also the default. AppKit gives a button titled Cancel Escape in place of
  // Return, so it takes Return here, and its sheet maps Escape to it whatever its title.
  id escape = nil;
  if (cancel == 0) {
    alert.buttons.firstObject.keyEquivalent = @"\r";
    __weak NSAlert *asked = alert;
    escape = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
      if (event.window != asked.window || ![event.charactersIgnoringModifiers isEqualToString:@"\033"]) return event;
      [asked.buttons.firstObject performClick:nil];
      return nil;
    }];
  } else {
    alert.buttons[cancel].keyEquivalent = @"\033";
  }
  self.shown[request] = alert;
  [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
    if (escape != nil) [NSEvent removeMonitor:escape];
    [self.shown removeObjectForKey:request];
    NSInteger index = response - NSAlertFirstButtonReturn;
    resolve(index >= 0 && index < (NSInteger)buttons.count ? @(index) : [NSNull null]);
  }];
  // The passage would take focus and swallow Return; the alert itself keeps it, as without one.
  if (alert.accessoryView != nil) [alert.window makeFirstResponder:nil];
}

// Withdraws a question whose asker has moved on; it answers nothing.
RCT_EXPORT_METHOD(retire:(nonnull NSNumber *)request)
{
  NSWindow *sheet = self.shown[request].window;
  [sheet.sheetParent endSheet:sheet returnCode:NSModalResponseAbort];
}
@end
#endif

#if !TARGET_OS_OSX
// A pull-down button whose system menu opens on tap, with the same items as the context menu.
// Its React content draws the label and passes touches to UIButton's primary action menu. The
// Mac drops the same menu below its control through UnwiredMenu.
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

#if !TARGET_OS_OSX
@interface UnwiredMenuButtonManager : RCTViewManager
@end

@implementation UnwiredMenuButtonManager
RCT_EXPORT_MODULE(UnwiredMenuButton)
RCT_EXPORT_VIEW_PROPERTY(sections, NSArray)
RCT_EXPORT_VIEW_PROPERTY(onSelect, RCTDirectEventBlock)
- (UnwiredPlatformView *)view { return [UnwiredMenuButtonView new]; }
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

@interface UnwiredSidebarManager : RCTViewManager
@end

@implementation UnwiredSidebarManager
RCT_EXPORT_MODULE(UnwiredSidebar)
RCT_EXPORT_VIEW_PROPERTY(thickness, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(onCollapse, RCTDirectEventBlock)
- (UnwiredPlatformView *)view { return [UnwiredSidebarView new]; }
@end

@interface UnwiredAppleIDButtonManager : RCTViewManager
@end

@implementation UnwiredAppleIDButtonManager
RCT_EXPORT_MODULE(UnwiredAppleIDButton)
RCT_EXPORT_VIEW_PROPERTY(enabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(onPress, RCTDirectEventBlock)
- (UnwiredPlatformView *)view { return [UnwiredAppleIDButtonView new]; }
@end

@interface UnwiredPushButtonManager : RCTViewManager
@end

@implementation UnwiredPushButtonManager
RCT_EXPORT_MODULE(UnwiredPushButton)
RCT_EXPORT_VIEW_PROPERTY(text, NSString)
RCT_EXPORT_VIEW_PROPERTY(label, NSString)
RCT_EXPORT_VIEW_PROPERTY(tint, NSColor)
RCT_EXPORT_VIEW_PROPERTY(textColor, NSColor)
RCT_EXPORT_VIEW_PROPERTY(focusColor, NSColor)
RCT_EXPORT_VIEW_PROPERTY(destructive, BOOL)
RCT_EXPORT_VIEW_PROPERTY(enabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(onPress, RCTDirectEventBlock)
- (UnwiredPlatformView *)view { return [UnwiredPushButtonView new]; }
@end

@interface UnwiredPopUpButtonManager : RCTViewManager
@end

@implementation UnwiredPopUpButtonManager
RCT_EXPORT_MODULE(UnwiredPopUpButton)
RCT_EXPORT_VIEW_PROPERTY(items, NSArray)
RCT_EXPORT_VIEW_PROPERTY(text, NSString)
RCT_EXPORT_VIEW_PROPERTY(symbol, NSString)
RCT_EXPORT_VIEW_PROPERTY(label, NSString)
RCT_EXPORT_VIEW_PROPERTY(destructiveColor, NSColor)
RCT_EXPORT_VIEW_PROPERTY(enabled, BOOL)
RCT_EXPORT_VIEW_PROPERTY(onSelect, RCTDirectEventBlock)
- (UnwiredPlatformView *)view { return [UnwiredPopUpButtonView new]; }
@end
#endif
