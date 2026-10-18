import type { TurboModule } from 'react-native';

import { microsoftMailAvailable } from '@private-email/mail-core/registration';
import { answerSyntheticRegistration } from '@private-email/mail-core/synthetic-registration';
import { NativeEventEmitter, TurboModuleRegistry } from 'react-native';

import { native } from './host.ts';

export {
  registration,
  gmailMailboxes,
  drafts,
  outbox,
  wakes,
  freshness,
  remoteContent,
  errorReporting,
  start,
  followWakes,
  native,
} from './host.ts';

interface SyntheticRegistrationModule extends TurboModule {
  readonly getConstants: () => Readonly<{ scenario?: unknown }>;
  readonly answer: (id: string, reply: string) => void;
  readonly refuse: (id: string, code: string) => void;
  readonly readState: () => Promise<unknown>;
  readonly saveState: (state: string) => Promise<unknown>;
  readonly addListener: (eventName: string) => void;
  readonly removeListeners: (count: number) => void;
}
// Registration Mock Mail Sessions answer the native vault's provider and backend requests from
// TypeScript; other builds have no answerer.
if (answerSyntheticRegistration !== undefined) {
  const relay = TurboModuleRegistry.getEnforcing<SyntheticRegistrationModule>(
    'UnwiredSyntheticRegistration',
  );
  answerSyntheticRegistration({
    scenario: String(relay.getConstants().scenario),
    listen: (request) => {
      new NativeEventEmitter(relay).addListener('request', request);
    },
    answer: (id, reply) => {
      relay.answer(id, reply);
    },
    refuse: (id, code) => {
      relay.refuse(id, code);
    },
    readState: () => relay.readState(),
    saveState: (state) => relay.saveState(state),
  });
}

// Whether this build can authorize Microsoft mail.
export const microsoftMail = () =>
  microsoftMailAvailable(native().getConstants?.());
