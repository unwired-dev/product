// `UnwiredContacts` at the Jest native boundary: access is denied unless a test grants it, and a
// granted Mac holds `appleContacts.addresses`. It counts requests, each of which asks for access.
type ContactAddress = Readonly<{ sender: string; address: string }>;

export const appleContacts: {
  granted: boolean;
  addresses: readonly ContactAddress[];
  requests: number;
} = { granted: false, addresses: [], requests: 0 };

export const unwiredContacts = {
  addresses: () => {
    appleContacts.requests += 1;
    return Promise.resolve(
      appleContacts.granted ? appleContacts.addresses : [],
    );
  },
};
