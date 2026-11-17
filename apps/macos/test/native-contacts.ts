// `UnwiredContacts` at the Jest native boundary: access is denied unless a test grants it, and a
// granted Mac holds `appleContacts.addresses`, or fails to read them while `unreadable`. It counts
// requests that may ask for access.
type ContactAddress = Readonly<{
  sender: string;
  address: string;
  given?: string;
}>;

export const appleContacts: {
  granted: boolean;
  unreadable: boolean;
  addresses: readonly ContactAddress[];
  requests: number;
} = { granted: false, unreadable: false, addresses: [], requests: 0 };

export const unwiredContacts = {
  addresses: async (ask: boolean) => {
    if (ask) {
      appleContacts.requests += 1;
    }
    if (appleContacts.granted && appleContacts.unreadable) {
      throw new Error('contacts_unreadable');
    }
    return appleContacts.granted ? appleContacts.addresses : [];
  },
};
