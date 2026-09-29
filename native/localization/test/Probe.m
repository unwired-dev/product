#import "UnwiredLanguagePreferences.h"

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
    NSDictionary *result = @{@"settings": UnwiredLanguageSettings(),
      @"showInbox": UnwiredNativeText(@"showInbox"), @"hide": UnwiredNativeText(@"hide")};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    [NSFileHandle.fileHandleWithStandardOutput writeData:data];
  }
  return 0;
}
