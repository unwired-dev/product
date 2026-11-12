import type { TurboModule } from 'react-native';

import { useEffect, useRef, useState } from 'react';
import { TurboModuleRegistry } from 'react-native';

type ContactAddress = Readonly<{ sender: string; address: string }>;

type ContactsModule = TurboModule & {
  // Asks for Contacts access when the person has not decided yet, then reads every email address of
  // the readable contacts, or none without access.
  readonly addresses: () => Promise<readonly ContactAddress[]>;
};

// Every email address of the Apple Contacts this app may read, under the contact's name. Contacts
// access is requested the first time `asking` is true; until it is granted, or when reading fails,
// there are none. They stay in memory on this device, never saved or synchronized.
export function useContactAddresses(
  asking: boolean,
): readonly ContactAddress[] {
  const [addresses, setAddresses] = useState<readonly ContactAddress[]>([]);
  const asked = useRef(false);
  useEffect(() => {
    if (!asking || asked.current) {
      return;
    }
    asked.current = true;
    void (async () => {
      try {
        setAddresses(
          await TurboModuleRegistry.getEnforcing<ContactsModule>(
            'UnwiredContacts',
          ).addresses(),
        );
      } catch {
        // Unreadable contacts leave recent correspondents as the only suggestions.
      }
    })();
  }, [asking]);
  return addresses;
}
