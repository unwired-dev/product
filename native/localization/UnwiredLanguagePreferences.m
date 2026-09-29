#import "UnwiredLanguagePreferences.h"

NSNotificationName const UnwiredLanguageDidChange = @"UnwiredLanguageDidChange";
static NSString *const preferenceKey = @"interfaceLanguage";

static id catalog(NSString *name)
{
  NSURL *directory = [NSBundle.mainBundle URLForResource:@"catalogs" withExtension:@"bundle"];
  NSURL *url = [directory URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]];
  NSData *data = [NSData dataWithContentsOfURL:url];
  NSCAssert(data != nil, @"Bundled translation catalogs are required.");
  return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

NSDictionary *UnwiredLanguageSettings(void)
{
  NSArray *languages = [catalog(@"languages") valueForKey:@"code"];
  NSString *preference = [NSUserDefaults.standardUserDefaults stringForKey:preferenceKey];
  if (![languages containsObject:preference]) preference = nil;
  NSString *language = preference ?: [NSBundle preferredLocalizationsFromArray:languages
      forPreferences:NSLocale.preferredLanguages].firstObject ?: @"en";
  NSLocale *current = NSLocale.currentLocale;
  NSMutableArray<NSString *> *components = [NSMutableArray arrayWithObject:current.languageCode];
  if (current.scriptCode) [components addObject:current.scriptCode];
  if (current.regionCode) [components addObject:current.regionCode];
  NSString *locale = preference ?: [components componentsJoinedByString:@"-"];
  return @{@"preference": preference ?: NSNull.null, @"language": language, @"locale": locale};
}

BOOL UnwiredSetLanguage(NSString *language)
{
  if (language && ![[catalog(@"languages") valueForKey:@"code"] containsObject:language]) return NO;
  if (language) {
    [NSUserDefaults.standardUserDefaults setObject:language forKey:preferenceKey];
  } else {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:preferenceKey];
  }
  [NSNotificationCenter.defaultCenter postNotificationName:UnwiredLanguageDidChange object:nil];
  return YES;
}

NSString *UnwiredNativeText(NSString *key)
{
  NSString *language = UnwiredLanguageSettings()[@"language"];
  return catalog(language)[@"native"][key] ?: catalog(@"en")[@"native"][key];
}
