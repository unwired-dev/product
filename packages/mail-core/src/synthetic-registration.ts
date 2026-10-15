// The native relay of a registration Mock Mail Session: the real vault asks it for each synthetic
// provider and backend answer. Values cross as JSON; credentials and keys stay native.
export interface SyntheticRegistrationRelay {
  readonly scenario: string;
  readonly listen: (request: (value: unknown) => void) => void;
  readonly answer: (id: string, reply: string) => void;
  readonly refuse: (id: string, code: string) => void;
  readonly readState: () => Promise<unknown>;
  readonly saveState: (state: string) => Promise<unknown>;
}

// Only registration Mock Mail Session bundles substitute the synthetic layers that answer it.
export const answerSyntheticRegistration:
  | ((relay: SyntheticRegistrationRelay) => void)
  | undefined = undefined;
