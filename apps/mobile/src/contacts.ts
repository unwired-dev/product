import { Contact, ContactField, requestPermissionsAsync } from 'expo-contacts';
import { useEffect, useRef, useState } from 'react';

type ContactAddress = Readonly<{ sender: string; address: string }>;

const fields = [ContactField.FULL_NAME, ContactField.EMAILS] as const;

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
        const { granted } = await requestPermissionsAsync();
        const contacts = granted ? await Contact.getAllDetails(fields) : [];
        setAddresses(
          contacts.flatMap(({ fullName, emails }) =>
            emails.flatMap(({ address }) =>
              address === undefined
                ? []
                : [{ sender: fullName ?? '', address }],
            ),
          ),
        );
      } catch {
        // Unreadable contacts leave recent correspondents as the only suggestions.
      }
    })();
  }, [asking]);
  return addresses;
}
