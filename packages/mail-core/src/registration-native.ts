import { mailProfilesUpgradeRequiredErrorCode } from '@private-email/contracts/productSync';
import * as Effect from 'effect/Effect';
import * as Predicate from 'effect/Predicate';
import * as Schema from 'effect/Schema';

import type { Code } from './registration-rejection.ts';
import type {
  BackendCall,
  NativeRegistrationVault,
} from './registration-vault.ts';

import { decodeDiagnostic, rejectionCode } from './diagnostics.ts';
import { isCode, rejected } from './registration-rejection.ts';
import {
  BackendReply,
  RegistrationRecordSchema,
} from './registration-vault.ts';

// Convex error codes the flow distinguishes; others are unavailable.
export const backendCodes: Readonly<Record<string, Code>> = {
  SIGN_IN_IDENTITY_OWNED: 'identity-owned',
  SIGN_IN_PROVIDER_ALREADY_LINKED: 'identity-owned',
  SIGN_IN_RECENT_AUTHENTICATION_REQUIRED: 'stale-authentication',
  SIGN_IN_LINK_EXPIRED: 'stale-authentication',
  SIGN_IN_NOT_LINKED: 'invalid-identity',
  ENROLLMENT_REQUEST_UNAVAILABLE: 'enrollment-unavailable',
  PENDING_DEVICE_UNAVAILABLE: 'pending-device-unavailable',
  TRUSTED_DEVICE_REVOKED: 'revoked',
  PRODUCT_ACCOUNT_DELETED: 'deleted',
  PRODUCT_ACCOUNT_DELETION_ABORTED: 'deletion-aborted',
  [mailProfilesUpgradeRequiredErrorCode]: 'upgrade-required',
};
export const backendCode = (code: string | undefined) =>
  (code !== undefined && Object.hasOwn(backendCodes, code)
    ? backendCodes[code]
    : undefined) ?? 'unavailable';

// A Convex HTTP API reply; ConvexError data carries a stable code.
export const Envelope = Schema.fromJsonString(
  Schema.Struct({
    status: Schema.String,
    value: Schema.optionalKey(Schema.Unknown),
    errorData: Schema.optionalKey(Schema.Struct({ code: Schema.String })),
  }),
);
const decodeEnvelope = Schema.decodeUnknownEffect(Envelope);

export const failWith = (code: Code) => Effect.fail(rejected(code));
export const unreadable = (error: Schema.SchemaError) =>
  Effect.logError(
    'Registration reply unreadable:',
    decodeDiagnostic(error),
  ).pipe(Effect.andThen(Effect.fail(rejected('unavailable', error))));
// This device's access to the Product Account has ended; it keeps none of its data.
export const endsAccess: ReadonlySet<Code> = new Set(['revoked', 'deleted']);

// The native vault's operations as Effects: each result is decoded, and each rejection keeps its
// fixed code.
export function nativeSteps(vault: NativeRegistrationVault) {
  const native = Effect.fnUntraced(function* <S extends Schema.Top>(
    operation: () => Promise<unknown>,
    schema: S,
  ) {
    const value = yield* Effect.tryPromise({
      try: operation,
      catch: (cause) => {
        const code = rejectionCode(cause);
        return rejected(isCode(code) ? code : 'unavailable', cause);
      },
    });
    return yield* Schema.decodeUnknownEffect(schema)(value).pipe(
      Effect.catch(unreadable),
    );
  });
  const step = (operation: () => Promise<unknown>) =>
    native(operation, Schema.Null).pipe(Effect.asVoid);
  const record = native(
    vault.registration,
    Schema.NullOr(RegistrationRecordSchema),
  );
  const saved = record.pipe(
    Effect.filterOrFail(Predicate.isNotNull, () => rejected('unavailable')),
  );
  // This device's Product Sync state, which must be readable.
  const sync = saved.pipe(
    Effect.flatMap(({ productSync }) =>
      productSync === undefined || productSync === 'unreadable'
        ? failWith('unavailable')
        : Effect.succeed(productSync),
    ),
  );
  // A Convex function result; application errors carry a code whatever the HTTP status.
  const convexReply = Effect.fnUntraced(function* (request: BackendCall) {
    const reply = yield* native(() => vault.call(request), BackendReply);
    const envelope = yield* decodeEnvelope(reply.body).pipe(
      Effect.catch(unreadable),
    );
    return {
      ...envelope,
      succeeded: envelope.status === 'success' && reply.status === 200,
    };
  });
  const convex = Effect.fnUntraced(function* <S extends Schema.Top>(
    request: BackendCall,
    schema: S,
  ) {
    const envelope = yield* convexReply(request);
    if (!envelope.succeeded) {
      return yield* failWith(backendCode(envelope.errorData?.code));
    }
    return yield* Schema.decodeUnknownEffect(schema)(envelope.value).pipe(
      Effect.catch(unreadable),
    );
  });
  return { native, step, record, saved, sync, convexReply, convex };
}
