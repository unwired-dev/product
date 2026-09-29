#import "AppDelegate.h"

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    __attribute__((objc_precise_lifetime)) AppDelegate *delegate = [AppDelegate new];
    app.delegate = delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
