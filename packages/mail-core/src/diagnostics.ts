import * as Predicate from 'effect/Predicate';

// Rejections from native hosts and seed providers can carry account data in their
// messages, so logs keep only the stable error code or error name.
export function rejectionDiagnostic(cause: unknown): string {
  if (Predicate.hasProperty(cause, 'code') && Predicate.isString(cause.code)) {
    return `code ${cause.code}`;
  }
  return Predicate.isError(cause) ? cause.name : typeof cause;
}
