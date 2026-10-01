import type * as Schema from 'effect/Schema';

import * as Predicate from 'effect/Predicate';
import * as SchemaIssue from 'effect/SchemaIssue';

// Codes the native Private Inbox and Registration bridges reject with.
const nativeCodes = new Set([
  'busy',
  'cancelled',
  'declined',
  'gmail-unavailable',
  'identity-owned',
  'invalid-identity',
  'locked',
  'stale-authentication',
  'unavailable',
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
  if (Predicate.hasProperty(cause, 'code')) {
    return Predicate.isString(cause.code) && nativeCodes.has(cause.code)
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
