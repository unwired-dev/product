#import "UnwiredLanguagePreferences.h"
#import <dispatch/dispatch.h>

NSNotificationName const UnwiredLanguageDidChange = @"UnwiredLanguageDidChange";
static NSString *const preferenceKey = @"interfaceLanguage";

static id catalog(NSString *name)
{
  static NSMutableDictionary<NSString *, id> *catalogs;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ catalogs = [NSMutableDictionary new]; });
  @synchronized (catalogs) {
    id cached = catalogs[name];
    if (cached) return cached;
    NSURL *directory = [NSBundle.mainBundle URLForResource:@"catalogs" withExtension:@"bundle"];
    NSURL *url = [directory URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]];
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSCAssert(data != nil, @"Bundled translation catalogs are required.");
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    catalogs[name] = parsed;
    return parsed;
  }
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
  NSDictionary<NSString *, NSString *> *keywords =
      [NSLocale componentsFromLocaleIdentifier:current.localeIdentifier];
  NSMutableArray<NSString *> *extensions = [NSMutableArray array];
  NSString *calendar = keywords[@"calendar"];
  if (calendar) {
    NSDictionary *calendarAliases = @{@"gregorian": @"gregory", @"ethiopic-amete-alem": @"ethioaa"};
    [extensions addObject:@"ca"];
    [extensions addObject:calendarAliases[calendar] ?: calendar];
  }
  NSString *numbers = keywords[@"numbers"];
  if (numbers) {
    [extensions addObject:@"nu"];
    [extensions addObject:numbers];
  }
  // The locale identifier omits the user's 12/24-hour override.
  NSString *hourPattern = [NSDateFormatter dateFormatFromTemplate:@"j" options:0 locale:current];
  NSDictionary<NSString *, NSString *> *hourCycles =
      @{@"K": @"h11", @"h": @"h12", @"H": @"h23", @"k": @"h24"};
  BOOL quoted = NO;
  for (NSUInteger index = 0; index < hourPattern.length; index++) {
    NSString *symbol = [hourPattern substringWithRange:NSMakeRange(index, 1)];
    if ([symbol isEqualToString:@"'"]) quoted = !quoted;
    NSString *cycle = quoted ? nil : hourCycles[symbol];
    if (cycle) {
      [extensions addObject:@"hc"];
      [extensions addObject:cycle];
      break;
    }
  }
  if (extensions.count) {
    [components addObject:@"u"];
    [components addObjectsFromArray:extensions];
  }
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
