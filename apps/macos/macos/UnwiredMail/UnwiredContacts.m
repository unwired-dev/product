#import <Contacts/Contacts.h>
#import <React/RCTBridgeModule.h>

// Apple Contacts for Recipient Suggestions, read on this device only.
@interface UnwiredContacts : NSObject <RCTBridgeModule>
@end

@implementation UnwiredContacts
RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup { return NO; }

// Asks for access only while the person has not decided, then resolves every email address of the
// readable contacts as { sender, address }, or none without access.
RCT_EXPORT_METHOD(addresses:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
  CNContactStore *store = [CNContactStore new];
  [store requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError *error) {
    if (!granted) {
      resolve(@[]);
      return;
    }
    CNContactFetchRequest *request = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[
      [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName],
      CNContactEmailAddressesKey,
    ]];
    NSMutableArray *addresses = [NSMutableArray array];
    NSError *failure;
    BOOL read = [store enumerateContactsWithFetchRequest:request error:&failure usingBlock:^(CNContact *contact, BOOL *stop) {
      NSString *sender = [CNContactFormatter stringFromContact:contact style:CNContactFormatterStyleFullName] ?: @"";
      for (CNLabeledValue<NSString *> *email in contact.emailAddresses) {
        [addresses addObject:@{@"sender": sender, @"address": email.value}];
      }
    }];
    if (read) {
      resolve(addresses);
    } else {
      reject(@"contacts_unreadable", @"Contacts could not be read.", failure);
    }
  }];
}
@end
