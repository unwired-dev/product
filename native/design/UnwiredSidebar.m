#import <React/RCTView.h>
#import <React/RCTViewManager.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <React/RCTSurfaceTouchHandler.h>

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

@interface UnwiredSidebarManager : RCTViewManager
@end

@implementation UnwiredSidebarManager
RCT_EXPORT_MODULE(UnwiredSidebar)
RCT_EXPORT_VIEW_PROPERTY(thickness, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(onCollapse, RCTDirectEventBlock)
- (RCTView *)view { return [UnwiredSidebarView new]; }
@end

#endif
