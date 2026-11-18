// Apple Contacts at the Jest native boundary: access is denied unless a test grants it, and a
// granted device holds `appleContacts.contacts`, or fails to read them while `unreadable`. It
// counts access requests and reads.
type Email = Readonly<{ id: string; address?: string }>;
type Details = Readonly<{
  id: string;
  fullName: string | null;
  givenName?: string | null;
  emails: readonly Email[];
}>;

export const appleContacts: {
  granted: boolean;
  unreadable: boolean;
  contacts: readonly Details[];
  requests: number;
  reads: number;
} = { granted: false, unreadable: false, contacts: [], requests: 0, reads: 0 };

export const ContactField = {
  FULL_NAME: 'fullName',
  GIVEN_NAME: 'givenName',
  EMAILS: 'emails',
} as const;

export const requestPermissionsAsync = () => {
  appleContacts.requests += 1;
  return Promise.resolve({ granted: appleContacts.granted });
};

export const getPermissionsAsync = () =>
  Promise.resolve({ granted: appleContacts.granted });

export const Contact = {
  getAllDetails: () => {
    appleContacts.reads += 1;
    return appleContacts.unreadable
      ? Promise.reject(new Error('contacts_unreadable'))
      : Promise.resolve(appleContacts.contacts);
  },
};
