import type { NativeMailAssistance } from '@private-email/mail-core/assistance-enablement';
import type { NativePreferences } from '@private-email/mail-core/commands';
import type { NativeHostModule } from '@private-email/mail-core/host';
import type { TurboModule } from 'react-native';

import { createHost } from '@private-email/mail-core/host';
import { microsoftMailAvailable } from '@private-email/mail-core/registration';
import { answerSyntheticRegistration } from '@private-email/mail-core/synthetic-registration';
import { NativeEventEmitter, TurboModuleRegistry } from 'react-native';

interface RegistrationModule
  extends
    TurboModule,
    NativeHostModule,
    NativeMailAssistance,
    NativePreferences {}

// The host's only lookup of its native module, on first use.
export const native = () =>
  TurboModuleRegistry.getEnforcing<RegistrationModule>('UnwiredRegistration');

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

export const {
  registration,
  gmailMailboxes,
  drafts,
  outbox,
  freshness,
  remoteContent,
  start,
  followWakes,
} = createHost(native);
