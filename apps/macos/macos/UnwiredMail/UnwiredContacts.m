#import <Contacts/Contacts.h>
#import <React/RCTBridgeModule.h>

// Apple Contacts for Recipient Suggestions, read on this device only.
@interface UnwiredContacts : NSObject <RCTBridgeModule>
@end

@implementation UnwiredContacts
RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup { return NO; }

// With `ask`, asks for access while the person has not decided; without it, never asks. Then
// resolves every email address of the readable contacts as { sender, address, given }, or none
// without access.
RCT_EXPORT_METHOD(addresses:(BOOL)ask resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject)
{
  CNContactStore *store = [CNContactStore new];
  void (^read)(BOOL) = ^(BOOL granted) {
    if (!granted) {
      resolve(@[]);
      return;
    }
    CNContactFetchRequest *request = [[CNContactFetchRequest alloc] initWithKeysToFetch:@[
      [CNContactFormatter descriptorForRequiredKeysForStyle:CNContactFormatterStyleFullName],
      CNContactGivenNameKey,
      CNContactEmailAddressesKey,
    ]];
    NSMutableArray *addresses = [NSMutableArray array];
    NSError *failure;
    BOOL enumerated = [store enumerateContactsWithFetchRequest:request error:&failure usingBlock:^(CNContact *contact, BOOL *stop) {
      NSString *sender = [CNContactFormatter stringFromContact:contact style:CNContactFormatterStyleFullName] ?: @"";
      for (CNLabeledValue<NSString *> *email in contact.emailAddresses) {
        [addresses addObject:@{@"sender": sender, @"address": email.value, @"given": contact.givenName}];
      }
    }];
    if (enumerated) {
      resolve(addresses);
    } else {
      reject(@"contacts_unreadable", @"Contacts could not be read.", failure);
    }
  };
  if (ask) {
    [store requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError *error) {
      read(granted);
    }];
  } else {
    read([CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts] == CNAuthorizationStatusAuthorized);
  }
}
@end
