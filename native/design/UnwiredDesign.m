#import <React/RCTViewManager.h>

// SF Symbols and Liquid Glass for both hosts, which target iOS and macOS 27.
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <React/RCTView.h>

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

@interface UnwiredGlassView : UIVisualEffectView
@property (nonatomic) CGFloat cornerRadius;
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
@end
#endif

#if !TARGET_OS_OSX
// The compact reader supplies its own Back pill; restore native chrome when it leaves.
@interface UnwiredReaderChromeView : UIView
@property (nonatomic, weak) UINavigationController *navigation;
@property (nonatomic) BOOL previousHidden;
@end

@implementation UnwiredReaderChromeView
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

@interface UnwiredReaderChromeManager : RCTViewManager
@end

@implementation UnwiredReaderChromeManager
RCT_EXPORT_MODULE(UnwiredReaderChrome)
- (UIView *)view { return [UnwiredReaderChromeView new]; }
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

// The navigation layer's material, drawn behind the controls laid over it.
@interface UnwiredGlassManager : RCTViewManager
@end

@implementation UnwiredGlassManager
RCT_EXPORT_MODULE(UnwiredGlass)
RCT_EXPORT_VIEW_PROPERTY(cornerRadius, CGFloat)
- (UnwiredPlatformView *)view { return [UnwiredGlassView new]; }
@end
