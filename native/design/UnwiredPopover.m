#import <React/RCTView.h>
#import <React/RCTViewManager.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <React/RCTSurfaceTouchHandler.h>

// An AppKit popover showing this view's React children, pointing up from this view's top edge, or
// down from its bottom edge when `below`.
// AppKit presents and animates it, closes it when the person clicks elsewhere or presses Escape,
// and the view then reports `onClose`.
// React Native macOS 0.81.9 has no popover; remove this view when it offers one.
@interface UnwiredPopoverView : RCTView <NSPopoverDelegate>
@property (nonatomic) BOOL shown;
@property (nonatomic) BOOL below;
@property (nonatomic) CGFloat contentWidth;
@property (nonatomic) CGFloat contentHeight;
@property (nonatomic, copy) RCTDirectEventBlock onClose;
@end

@implementation UnwiredPopoverView {
  NSPopover *_popover;
  // The popover is outside the React root view, so it delivers its own clicks to React.
  RCTSurfaceTouchHandler *_touchHandler;
  // `shown` closed the popover, and AppKit reports the close only after its animation ends.
  BOOL _closing;
}
- (instancetype)initWithFrame:(NSRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    NSViewController *content = [NSViewController new];
    content.view = [RCTUIView new];
    _touchHandler = [RCTSurfaceTouchHandler new];
    [_touchHandler attachToView:content.view];
    _popover = [NSPopover new];
    _popover.contentViewController = content;
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.delegate = self;
  }
  return self;
}
- (void)dealloc
{
  _popover.delegate = nil;
  [_popover close];
  [_touchHandler detachFromView:_popover.contentViewController.view];
}
- (void)didUpdateReactSubviews
{
  for (NSView *subview in self.reactSubviews) [_popover.contentViewController.view addSubview:subview];
}
- (void)didSetProps:(NSArray<NSString *> *)changedProps
{
  _popover.contentSize = NSMakeSize(self.contentWidth, self.contentHeight);
  // Only `shown` presents, so resizing content never reopens a popover the person closed.
  if ([changedProps containsObject:@"shown"]) [self present];
}
- (void)viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  [self present];
}
- (void)present
{
  if (!self.shown || self.window == nil) {
    if (_popover.shown) _closing = YES;
    [_popover close];
  } else if (!_popover.shown && !_closing) {
    // React Native's views are flipped, so their top edge is the minimum Y.
    [_popover showRelativeToRect:self.bounds
                          ofView:self
                   preferredEdge:self.below ? NSRectEdgeMaxY : NSRectEdgeMinY];
  }
}
- (void)popoverDidClose:(NSNotification *)notification
{
  // A popover shown again while it was closing opens once the close ends, without reporting it.
  if (_closing) {
    _closing = NO;
    if (self.shown && self.window != nil) {
      [self present];
      return;
    }
  }
  if (self.onClose) self.onClose(@{});
}
@end

@interface UnwiredPopoverManager : RCTViewManager
@end

@implementation UnwiredPopoverManager
RCT_EXPORT_MODULE(UnwiredPopover)
RCT_EXPORT_VIEW_PROPERTY(shown, BOOL)
RCT_EXPORT_VIEW_PROPERTY(below, BOOL)
RCT_EXPORT_VIEW_PROPERTY(contentWidth, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(contentHeight, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(onClose, RCTDirectEventBlock)
- (RCTView *)view { return [UnwiredPopoverView new]; }
@end

#endif
