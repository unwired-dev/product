import type { NativeRegistration } from '@private-email/mail-core/registration';
import type { TurboModule } from 'react-native';

import { createRegistration } from '@private-email/mail-core/registration';
import { TurboModuleRegistry } from 'react-native';

interface RegistrationModule extends TurboModule, NativeRegistration {}
const native = () =>
  TurboModuleRegistry.getEnforcing<RegistrationModule>('UnwiredRegistration');

export const registration = createRegistration({
  restore: () => native().restore(),
  signIn: (provider) => native().signIn(provider),
  authorizeGmail: (reselect) => native().authorizeGmail(reselect),
  link: (provider) => native().link(provider),
  confirmRecoveryKey: (entry) => native().confirmRecoveryKey(entry),
  approveEnrollment: (requestId, code) =>
    native().approveEnrollment(requestId, code),
  declineEnrollment: (requestId) => native().declineEnrollment(requestId),
  refreshPrivateSync: () => native().refreshPrivateSync(),
});
