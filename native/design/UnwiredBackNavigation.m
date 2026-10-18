#import <React/RCTView.h>
#import <React/RCTViewManager.h>
#import <UIKit/UIKit.h>

@interface UnwiredBackNavigationView : RCTView <UIGestureRecognizerDelegate>
@property (nonatomic, copy) RCTDirectEventBlock onBack;
@property (nonatomic, strong) UIScreenEdgePanGestureRecognizer *backGesture;
@property (nonatomic) CGFloat initialDistance;
@end

@implementation UnwiredBackNavigationView
- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    _backGesture = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(back:)];
    _backGesture.edges = UIRectEdgeLeft;
    _backGesture.delegate = self;
    [self addGestureRecognizer:_backGesture];
  }
  return self;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer
{
  if (self.onBack == nil || self.window == nil || UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) {
    return NO;
  }
  CGPoint velocity = [self.backGesture velocityInView:self.superview];
  if (velocity.x <= 0 || velocity.x <= fabs(velocity.y)) {
    return NO;
  }
  // Only the innermost destination under the finger handles this gesture.
  CGPoint point = [recognizer locationInView:self.window];
  UIView *touched = [self.window hitTest:point withEvent:nil];
  while (touched != nil && touched != self) {
    if ([touched isKindOfClass:UnwiredBackNavigationView.class]) {
      return NO;
    }
    touched = touched.superview;
  }
  return touched == self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other
{
  // A Settings detail consumes Back before the containing native Settings stack can pop.
  if ([other.view isKindOfClass:UnwiredBackNavigationView.class] &&
      [other.view isDescendantOfView:self]) {
    return NO;
  }
  return [other isKindOfClass:UIPanGestureRecognizer.class];
}

- (void)back:(UIScreenEdgePanGestureRecognizer *)gesture
{
  CGFloat width = CGRectGetWidth(self.bounds);
  if (gesture.state == UIGestureRecognizerStateBegan) {
    self.initialDistance = self.subviews.firstObject.layer.presentationLayer.affineTransform.tx;
    for (UIView *content in self.subviews) {
      [content.layer removeAllAnimations];
    }
  }
  CGFloat distance = MAX(0, MIN(width, self.initialDistance + [gesture translationInView:self].x));
  if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
    if (!UIAccessibilityIsReduceMotionEnabled()) {
      for (UIView *content in self.subviews) {
        content.transform = CGAffineTransformMakeTranslation(distance, 0);
      }
    }
    return;
  }
  if (gesture.state != UIGestureRecognizerStateEnded &&
      gesture.state != UIGestureRecognizerStateCancelled &&
      gesture.state != UIGestureRecognizerStateFailed) {
    return;
  }
  CGFloat velocity = [gesture velocityInView:self.superview].x;
  BOOL committed = gesture.state == UIGestureRecognizerStateEnded &&
      distance > 0 && velocity >= 0 && (distance >= width / 3 || (distance >= 20 && velocity >= 600));
  // The existing action may refuse to leave or ask to save a Draft; it owns dismissal.
  [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.3
      delay:0
      usingSpringWithDamping:1
      initialSpringVelocity:0
      options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
      animations:^{
        for (UIView *content in self.subviews) {
          content.transform = CGAffineTransformIdentity;
        }
      }
      completion:nil];
  if (committed && self.onBack != nil) {
    self.onBack(@{});
  }
}
@end

@interface UnwiredBackNavigationManager : RCTViewManager
@end

@implementation UnwiredBackNavigationManager
RCT_EXPORT_MODULE(UnwiredBackNavigation)
RCT_EXPORT_VIEW_PROPERTY(onBack, RCTDirectEventBlock)
- (UIView *)view { return [UnwiredBackNavigationView new]; }
@end
