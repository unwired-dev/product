#import "UnwiredLanguagePreferences.h"

static NSDictionary *snapshot(void)
{
  return @{@"settings": UnwiredLanguageSettings(),
    @"showInbox": UnwiredNativeText(@"showInbox"), @"hide": UnwiredNativeText(@"hide")};
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    if ([arguments containsObject:@"--reset"]) {
      [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    } else if ([arguments containsObject:@"--system"]) {
      UnwiredSetLanguage(nil);
    } else if ([arguments containsObject:@"--english"]) {
      UnwiredSetLanguage(@"en");
    }
    [NSUserDefaults.standardUserDefaults synchronize];
    id result = snapshot();
    if ([arguments containsObject:@"--switch-languages"]) {
      NSMutableArray *snapshots = [NSMutableArray new];
      for (id preference in @[NSNull.null, @"en", NSNull.null]) {
        UnwiredSetLanguage(preference == NSNull.null ? nil : preference);
        [snapshots addObject:snapshot()];
      }
      result = snapshots;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    [NSFileHandle.fileHandleWithStandardOutput writeData:data];
  }
  return 0;
}
