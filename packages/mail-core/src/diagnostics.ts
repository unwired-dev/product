import type * as Schema from 'effect/Schema';

import * as Effect from 'effect/Effect';
import * as Predicate from 'effect/Predicate';
import * as References from 'effect/References';
import * as SchemaIssue from 'effect/SchemaIssue';

// Codes the native Private Inbox, Registration and Assistance bridges reject with.
const nativeCodes = new Set([
  'assistance-disabled',
  'busy',
  'attachment-missing',
  'cancelled',
  'conflict',
  'declined',
  'device-ineligible',
  'enrollment-unavailable',
  'gmail-unavailable',
  'identity-owned',
  'invalid-identity',
  'locked',
  'mailbox-invalidated',
  'mailbox-revoked',
  'model-not-ready',
  'refused',
  'removal-refused',
  'stale-authentication',
  'unavailable',
  'unsupported-locale',
]);
const errorNames = new Set([
  'AbortError',
  'Error',
  'RangeError',
  'SyntaxError',
  'TimeoutError',
  'TypeError',
]);

// Rejections from native hosts and seed providers can carry account data in any
// field, so logs keep only allow-listed codes and error names.
export function rejectionDiagnostic(cause: unknown): string {
  // DOMException has a numeric code, so only string codes are reported as codes.
  if (Predicate.hasProperty(cause, 'code') && Predicate.isString(cause.code)) {
    return nativeCodes.has(cause.code)
      ? `code ${cause.code}`
      : 'unrecognized code';
  }
  if (Predicate.isError(cause)) {
    return errorNames.has(cause.name) ? cause.name : 'unrecognized error';
  }
  return typeof cause;
}

const issueEntries = SchemaIssue.makeFormatterStandardSchemaV1();

// Issue messages can quote the rejected input, so decode failures log only where
// the input failed.
export function decodeDiagnostic(error: Schema.SchemaError): string {
  const paths = issueEntries(error.issue).issues.map(({ path = [] }) =>
    path.length === 0
      ? '(root)'
      : path
          .map((segment) =>
            String(Predicate.isObject(segment) ? segment.key : segment),
          )
          .join('.'),
  );
  return `invalid at ${[...new Set(paths)].join(', ')}`;
}

// Hosts surface console.error as failures (React Native LogBox, Xcode); Effect's
// default logger writes through console.log.
export async function runLogged<A>(program: Effect.Effect<A>): Promise<A> {
  return Effect.runPromise(
    program.pipe(Effect.provideService(References.LogToStderr, true)),
  );
}
