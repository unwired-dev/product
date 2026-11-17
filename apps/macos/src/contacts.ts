import type { TurboModule } from 'react-native';

import { useEffect, useRef, useState } from 'react';
import { TurboModuleRegistry } from 'react-native';

type ContactAddress = Readonly<{
  sender: string;
  address: string;
  // The contact's recorded given name, empty when none is recorded.
  given?: string;
}>;

type ContactsModule = TurboModule & {
  // With `ask`, asks for Contacts access when the person has not decided yet; without it, never
  // asks. Then reads every email address of the readable contacts, or none without access.
  readonly addresses: (ask: boolean) => Promise<readonly ContactAddress[]>;
};

// Every email address of the Apple Contacts this app may read, under the contact's name, read the
// first time `reading` is true. With `ask`, Contacts access is requested then; without it, only
// contacts already readable are read. Until access is granted there are none; `failed` tells that
// reading them failed. They stay in memory on this device, never saved or synchronized.
export function useContactAddresses(
  reading: boolean,
  ask = true,
): Readonly<{ addresses: readonly ContactAddress[]; failed: boolean }> {
  const [read, setRead] = useState<{
    addresses: readonly ContactAddress[];
    failed: boolean;
  }>({ addresses: [], failed: false });
  const asked = useRef(false);
  useEffect(() => {
    if (!reading || asked.current) {
      return;
    }
    asked.current = true;
    void (async () => {
      try {
        setRead({
          addresses:
            await TurboModuleRegistry.getEnforcing<ContactsModule>(
              'UnwiredContacts',
            ).addresses(ask),
          failed: false,
        });
      } catch {
        // Unreadable contacts leave recent correspondents as the only suggestions.
        setRead({ addresses: [], failed: true });
      }
    })();
  }, [reading, ask]);
  return read;
}
