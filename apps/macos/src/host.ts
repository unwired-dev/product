import type { NativeMailAssistance } from '@private-email/mail-core/assistance-enablement';
import type { NativePreferences } from '@private-email/mail-core/commands';
import type { NativeErrorReporting } from '@private-email/mail-core/error-reporting';
import type { NativeHostModule } from '@private-email/mail-core/host';
import type { TurboModule } from 'react-native';

import { createHost } from '@private-email/mail-core/host';
import { TurboModuleRegistry } from 'react-native';

import { localization } from './localization.ts';

interface RegistrationModule
  extends
    TurboModule,
    NativeHostModule,
    NativeMailAssistance,
    NativePreferences {
  // Events: `draftImportProgress`, `{ id, fraction }`, while a Draft asset's file is read.
  readonly addListener: (eventName: string) => void;
  readonly removeListeners: (count: number) => void;
}

interface ReportingModule extends TurboModule, NativeErrorReporting {
  readonly getConstants: () => Readonly<{ initialState?: unknown }>;
}

// The host's only lookup of its native module, on first use.
export const native = () =>
  TurboModuleRegistry.getEnforcing<RegistrationModule>('UnwiredRegistration');

const reportingNative = () =>
  TurboModuleRegistry.getEnforcing<ReportingModule>('UnwiredErrorReporting');
let initialReportingState: unknown = undefined;
try {
  initialReportingState = reportingNative().getConstants().initialState;
} catch {
  // Missing reporting bindings leave consent unknown until the ordinary read.
}

export const {
  registration,
  gmailMailboxes,
  drafts,
  mailTemplates,
  sendReminders,
  blockedSenders,
  pins,
  unsubscribe,
  inboxPreferences,
  readingPreferences,
  outbox,
  wakes,
  freshness,
  remoteContent,
  errorReporting,
  start,
  followWakes,
  followBadge,
  followReminderNotifications,
  followNotificationActions,
  notifications,
} = createHost(native, {
  reportingNative,
  initialReportingState,
  translate: () => localization.i18n.t,
});
