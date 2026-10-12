import * as Schema from 'effect/Schema';

// Codes native operations and Convex replies end with; host-facing codes are a subset.
const CodeSchema = Schema.Literals([
  'busy',
  'cancelled',
  'declined',
  'deleted',
  'enrollment-code-invalid',
  'enrollment-unavailable',
  'gmail-unavailable',
  'identity-owned',
  'invalid-identity',
  'locked',
  // A transport failure that permits reading the last verified local state.
  'offline',
  'recovery-key-mismatch',
  'removal-refused',
  'revoked',
  'stale-authentication',
  'unavailable',
  // Distinguished by the flow only; hosts see them as other codes.
  'apple-authorization-required',
  'pending-device-unavailable',
  // An IMAP or SMTP server refused the login, or offered no verified TLS.
  'imap-refused',
  'imap-insecure',
  'smtp-refused',
  'smtp-insecure',
]);
export type Code = typeof CodeSchema.Type;

// The flow's own distinctions, as the codes hosts have always received.
export const hostCodes: Partial<Record<Code, Code>> = {
  offline: 'unavailable',
  'pending-device-unavailable': 'unavailable',
  revoked: 'unavailable',
  deleted: 'unavailable',
  'apple-authorization-required': 'removal-refused',
};

// The fixed texts hosts have always received with each code.
const messages: Partial<Record<Code, string>> = {
  busy: 'Authorization is already running.',
  cancelled: 'Sign-in was cancelled.',
  'recovery-key-mismatch': 'That does not match the end of your Recovery Key.',
  'enrollment-code-invalid': "That code does not match the new device's code.",
  'enrollment-unavailable': 'That device request is no longer available.',
  locked: 'Unlock your device to open your saved account.',
};

export class RegistrationRejected extends Schema.TaggedError<RegistrationRejected>()(
  'RegistrationRejected',
  { code: CodeSchema, message: Schema.String, cause: Schema.Defect() },
) {}

export const rejected = (code: Code, cause?: unknown) =>
  new RegistrationRejected({
    code,
    message:
      messages[code] ??
      'Registration could not finish. Retry with your saved account.',
    cause,
  });
export const isCode = Schema.is(CodeSchema);
