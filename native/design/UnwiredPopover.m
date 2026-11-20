#import <React/RCTView.h>
#import <React/RCTViewManager.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <React/RCTSurfaceTouchHandler.h>

// An AppKit popover showing this view's React children, without an arrow, above this view's top
// edge, or below its bottom edge when `below`.
// AppKit presents and animates it, closes it when the person clicks elsewhere or presses Escape,
// and the view then reports `onClose`. VoiceOver names the popover by `title`.
// React Native macOS 0.83.0 has no popover; remove this view when it offers one.
@interface UnwiredPopoverView : RCTView <NSPopoverDelegate>
@property (nonatomic) BOOL shown;
@property (nonatomic) BOOL below;
@property (nonatomic) CGFloat contentWidth;
@property (nonatomic) CGFloat contentHeight;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) RCTDirectEventBlock onClose;
@end

@implementation UnwiredPopoverView {
  NSPopover *_popover;
  // The edge the popover opens from, a point tall: AppKit does not show a popover from an empty
  // rect, and this view is zero-height (#1792). It clips to its bounds, or the popover keeps its
  // arrow.
  NSView *_edge;
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
    _edge = [NSView new];
    _edge.clipsToBounds = YES;
    [self addSubview:_edge];
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
  [self anchor:YES];
  _popover.contentSize = NSMakeSize(self.contentWidth, self.contentHeight);
  [self anchor:NO];
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
    // The edge is not flipped, so its top is the maximum Y.
    [self anchor:YES];
    [_popover showRelativeToRect:_edge.bounds
                          ofView:_edge
                   preferredEdge:self.below ? NSRectEdgeMinY : NSRectEdgeMaxY];
    [self anchor:NO];
  }
}
// NSPopover has no property to hide its arrow (#2254). Shown against the whole bounds of its
// positioning view, it drops the arrow and stays in place once those bounds shift by a point. A
// resize places it again, so it is placed against the unshifted bounds.
- (void)anchor:(BOOL)anchored
{
  _edge.frame = NSInsetRect(self.bounds, 0, -0.5);
  _edge.bounds = (NSRect){NSMakePoint(0, anchored ? 0 : 1), _edge.frame.size};
}
- (void)popoverWillShow:(NSNotification *)notification
{
  NSWindow *window = _popover.contentViewController.view.window;
  window.accessibilityLabel = self.title;
  // An `autoFocus` input took focus when the content joined this window; AppKit would otherwise
  // focus the first input as the window becomes key.
  NSResponder *focused = window.firstResponder;
  if ([focused isKindOfClass:NSTextView.class] && ((NSTextView *)focused).isFieldEditor) {
    focused = (NSResponder *)((NSTextView *)focused).delegate;
  }
  if ([focused isKindOfClass:NSView.class]) window.initialFirstResponder = (NSView *)focused;
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
RCT_EXPORT_VIEW_PROPERTY(title, NSString)
RCT_EXPORT_VIEW_PROPERTY(onClose, RCTDirectEventBlock)
- (RCTView *)view { return [UnwiredPopoverView new]; }
@end

#endif
