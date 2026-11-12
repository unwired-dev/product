// Apple Contacts at the Jest native boundary: access is denied unless a test grants it, and a
// granted device holds `appleContacts.contacts`. It counts access requests and reads.
type Email = Readonly<{ id: string; address?: string }>;
type Details = Readonly<{
  id: string;
  fullName: string | null;
  emails: readonly Email[];
}>;

export const appleContacts: {
  granted: boolean;
  contacts: readonly Details[];
  requests: number;
  reads: number;
} = { granted: false, contacts: [], requests: 0, reads: 0 };

export const ContactField = {
  FULL_NAME: 'fullName',
  EMAILS: 'emails',
} as const;

export const requestPermissionsAsync = () => {
  appleContacts.requests += 1;
  return Promise.resolve({ granted: appleContacts.granted });
};

export const Contact = {
  getAllDetails: () => {
    appleContacts.reads += 1;
    return Promise.resolve(appleContacts.contacts);
  },
};
