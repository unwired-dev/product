import {
  Contact,
  ContactField,
  getPermissionsAsync,
  requestPermissionsAsync,
} from 'expo-contacts';
import { useEffect, useRef, useState } from 'react';

type ContactAddress = Readonly<{
  sender: string;
  address: string;
  // The contact's recorded given name, empty when none is recorded.
  given?: string;
}>;

const fields = [
  ContactField.FULL_NAME,
  ContactField.GIVEN_NAME,
  ContactField.EMAILS,
] as const;

// Every email address of the Apple Contacts this app may read, under the contact's name. With
// `ask`, they are read the first time `reading` is true, requesting Contacts access then; without
// it, only contacts already readable are read, each time `reading` turns true or `attempt` changes
// while it is, so access granted meanwhile counts, and they are dropped when it turns false. Until access is granted there are
// none; `failed` tells that reading them failed, and `settled` that the read finished. They stay in memory on this device, never saved or synchronized.
export function useContactAddresses(
  reading: boolean,
  ask = true,
  attempt = 0,
): Readonly<{
  addresses: readonly ContactAddress[];
  failed: boolean;
  settled: boolean;
}> {
  const [read, setRead] = useState<{
    addresses: readonly ContactAddress[];
    failed: boolean;
    settled: boolean;
  }>({ addresses: [], failed: false, settled: false });
  const asked = useRef(false);
  useEffect(() => {
    if (!reading || (ask && asked.current)) {
      return;
    }
    asked.current = true;
    // A read still running when `reading` turns false is dropped without asking.
    let current = true;
    const keep = (next: Readonly<typeof read>) => {
      if (current || ask) {
        setRead(next);
      }
    };
    void (async () => {
      try {
        const { granted } = await (ask
          ? requestPermissionsAsync()
          : getPermissionsAsync());
        const contacts = granted ? await Contact.getAllDetails(fields) : [];
        keep({
          addresses: contacts.flatMap(({ fullName, givenName, emails }) =>
            emails.flatMap(({ address }) =>
              address === undefined
                ? []
                : [{ sender: fullName ?? '', address, given: givenName ?? '' }],
            ),
          ),
          failed: false,
          settled: true,
        });
      } catch {
        // Unreadable contacts leave recent correspondents as the only suggestions.
        keep({ addresses: [], failed: true, settled: true });
      }
    })();
    return () => {
      current = false;
      if (!ask) {
        setRead({ addresses: [], failed: false, settled: false });
      }
    };
  }, [reading, ask, attempt]);
  return read;
}
