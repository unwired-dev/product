import type * as Types from 'effect/Types';

import { sha256 } from '@noble/hashes/sha2.js';
import * as Arr from 'effect/Array';
import * as Context from 'effect/Context';
import * as Effect from 'effect/Effect';
import * as Base64 from 'effect/encoding/Base64';
import * as Hex from 'effect/encoding/Hex';
import * as Layer from 'effect/Layer';
import * as Order from 'effect/Order';
import * as Predicate from 'effect/Predicate';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { Reply, SyntheticRefusal } from './synthetic-relay.ts';

import {
  EncryptedPayload,
  KeyEnvelope,
  StoredPayload,
} from '../registration-replies.ts';
import { SyntheticScenario, refuse, reply } from './synthetic-relay.ts';

const Strings = Schema.Record(Schema.String, Schema.String);
const Lists = Schema.Record(
  Schema.String,
  Schema.mutable(Schema.Array(Schema.String)),
);
// Convex's Product Sync rules over the run's Keychain, so relaunches keep its records.
const State = Schema.Struct({
  recovery: Schema.Record(Schema.String, EncryptedPayload),
  // The Recovery Key verifier published with each account's recovery envelope.
  verifiers: Strings,
  records: Schema.Record(
    Schema.String,
    Schema.Record(Schema.String, StoredPayload),
  ),
  // Delivery claims this device holds, by account; no other device claims in mock sessions.
  claims: Lists,
  // Open enrollment requests by Pending Device id, with the encryption key they name.
  requests: Schema.Record(
    Schema.String,
    Schema.Struct({ account: Schema.String, deviceKey: Schema.String }),
  ),
  // Pending Devices whose Recovery Key proof matched, with the encryption key it named.
  recovered: Strings,
  // Device identifiers each account admitted: the one that created its keys, then others.
  admitted: Lists,
  // Each account's key epoch, once a removal moved it past the first.
  epochs: Schema.Record(Schema.String, Schema.Finite),
  // Bound encryption keys and each device's latest key ring envelope, by Trusted Device id.
  deviceKeys: Strings,
  envelopes: Schema.Record(Schema.String, KeyEnvelope),
  // Activated removal proposals with their epochs, and the one whose Recovery Key is current.
  proposals: Schema.Record(Schema.String, Schema.Finite),
  recoveryProposal: Strings,
  removed: Schema.mutable(Schema.Array(Schema.String)),
  // This device's identifiers another device removed; they stay refused.
  removedIdentifiers: Schema.mutable(Schema.Array(Schema.String)),
  // Product Accounts this device deleted; their sign-ins are refused afterwards.
  deleted: Schema.mutable(Schema.Array(Schema.String)),
  // The launch that first connected; a later launch learns of this device's removal.
  connectedLaunch: Schema.optionalKey(Schema.String),
});
type SyntheticState = Types.DeepMutable<typeof State.Type>;
const StateJSON = Schema.fromJsonString(State);
const empty = (): SyntheticState => ({
  recovery: {},
  verifiers: {},
  records: {},
  claims: {},
  requests: {},
  recovered: {},
  admitted: {},
  epochs: {},
  deviceKeys: {},
  envelopes: {},
  proposals: {},
  recoveryProposal: {},
  removed: [],
  removedIdentifiers: [],
  deleted: [],
});
const without = <V>(record: Readonly<Record<string, V>>, key: string) =>
  Object.fromEntries(Object.entries(record).filter(([name]) => name !== key));

// Where the run keeps its state between launches: the native relay's Keychain item.
export class SyntheticStateStorage extends Context.Service<
  SyntheticStateStorage,
  {
    readonly read: Effect.Effect<string | null, SyntheticRefusal>;
    readonly save: (state: string) => Effect.Effect<unknown, SyntheticRefusal>;
  }
>()('@private-email/mail-core/testing/SyntheticStateStorage') {}

const SignInProvider = Schema.Literals(['google', 'apple']);
export const Identity = Schema.Struct({
  provider: SignInProvider,
  subject: Schema.String,
});
export const Receipt = Schema.Struct({
  productAccountId: Schema.String,
  trustedDeviceId: Schema.String,
  trustedDeviceCredential: Schema.String,
  pending: Schema.optionalKey(Schema.Boolean),
  signInProviders: Schema.optionalKey(Schema.Array(SignInProvider)),
  productSyncMaterialInitialized: Schema.optionalKey(Schema.Boolean),
});
type SignIn = typeof Identity.Type;
type Product = typeof Receipt.Type;
type Payload = typeof EncryptedPayload.Type;
export const Call = Schema.Struct({
  path: Schema.String,
  args: Schema.Record(Schema.String, Schema.Unknown),
  identity: Schema.NullOr(Identity),
  product: Schema.NullOr(Receipt),
});
// A credentialed call this device makes, with the receipt its device proof names.
type Presented = Readonly<{
  args: Readonly<Record<string, unknown>>;
  identity: SignIn | null;
  product: Product;
}>;
const Activation = Schema.Struct({
  trustedDeviceToRevokeId: Schema.String,
  proposalId: Schema.String,
  expectedKeyEpoch: Schema.Int,
  keyEnvelopes: Schema.Array(
    Schema.Struct({
      trustedDeviceId: Schema.String,
      deviceEncryptionPublicKey: Schema.String,
      encapsulatedKeyBase64: Schema.String,
      ciphertextBase64: Schema.String,
    }),
  ),
  recoveryWrappedAccountKey: EncryptedPayload,
  recoveryVerifier: Schema.String,
});

// The lost trusted device of `registration-recovery`'s account, sealed by native code for the fixed
// Recovery Key that journey types: its recovery envelope, verifier and one encrypted mailbox.
const lostDevice = {
  account: 'synthetic-product-account',
  recovery: {
    algorithm: 'AES-GCM-256',
    ciphertextBase64:
      'Fn87FN5drvttVngqQ2bL8erzOgNcGHseqMyBtgkLwvvvFWzDr2IrQGM+eJiZzzC2lE812/xEFeGmKAsH+J2DylBrCsBNFgeX82o3JCPkEZ8DOuXAgMhaq1S/tQ==',
    keyVersion: 1,
    nonceBase64: 'XL69HIEudlmiQH7u',
    schemaVersion: 3,
    tagBase64: 'XerQY75RpYJ+/FsDaX2qtQ==',
  },
  verifier: '0689248a24ce2251c651e89dff1967f4f2222f2178bb98cd5010d90581fbf6d0',
  mailbox: {
    payloadIdentifier: 'mailbox.4522f315d883760cd42fe8fd1d8bef94',
    encryptedPayload: {
      algorithm: 'AES-GCM-256',
      ciphertextBase64:
        'KeQkFr6YfZuWplzEC5ZhFxSfApNv8W5PZm7Qs/jDpaJWxfM8AtQtHVxlK1l3G4C0PuXWWwU=',
      keyVersion: 1,
      nonceBase64: '3BrbBY34fqNm/4OQ',
      schemaVersion: 1,
      tagBase64: 'f2cgA+NjtE/G1lmDaBJpHA==',
    },
    updatedAt: 1,
  },
} as const;
// The other device of the `registration-revocation` account, which this device removes, with the
// Curve25519 public key of 32 bytes of 7 that only the synthetic iPad would hold.
const iPad = {
  id: 'synthetic-ipad',
  key: 'E75P6uryBMf9M1j8nAByGIHRdCeBKCJ+xnTzf3/pe20=',
};
const pendingPrefix = 'synthetic-pending-';
const devicePrefix = 'synthetic-device-';
const recoveryRecord = 'product-account-recovery-v1';
// Each synthetic sign-in identity owns its own Product Account; in the link scenario the Google
// identity is unregistered and may join the Apple account.
const accounts = new Map([
  ['synthetic-product-subject', 'synthetic-product-account'],
  ['synthetic-apple-subject', 'synthetic-apple-product-account'],
]);
const isBase64 = (value: unknown): value is string =>
  Predicate.isString(value) && Result.isSuccess(Base64.decode(value));
// Convex's Recovery Key check: the digest of the presented proof is the account's verifier.
const proves = (proof: unknown, verifier: string | undefined) =>
  Predicate.isString(proof) &&
  verifier !== undefined &&
  Hex.encode(sha256(new TextEncoder().encode(proof))) === verifier;
// A Convex function's reply envelope; HTTP actions answer with their own bodies.
const success = (value: unknown) => reply(200, { status: 'success', value });
const refusal = (code: string) =>
  reply(200, { status: 'error', errorData: { code } });
const byIdentifier = Order.mapInput(
  Order.String,
  ({ payloadIdentifier }: Readonly<{ payloadIdentifier: string }>) =>
    payloadIdentifier,
);
const payloadOf = (value: unknown) =>
  Schema.decodeUnknownEffect(EncryptedPayload)(value).pipe(
    Effect.orElseSucceed(() => null),
  );

// Convex as the native vault calls it: Product Account connections, the credentialed calls
// TypeScript names, and the Product Sync records native Draft sync keeps.
export class SyntheticConvex extends Context.Service<SyntheticConvex>()(
  '@private-email/mail-core/testing/SyntheticConvex',
  {
    make: Effect.gen(function* () {
      const { scenario, launch } = yield* SyntheticScenario;
      const storage = yield* SyntheticStateStorage;
      const saved = yield* storage.read;
      const state: SyntheticState =
        saved === null ? empty() : yield* Schema.decodeEffect(StateJSON)(saved);
      const writes = yield* Semaphore.make(1);
      // Encodes the state as it is when the write runs.
      const save = Effect.suspend(() =>
        Schema.encodeEffect(StateJSON)(state),
      ).pipe(Effect.flatMap(storage.save));
      // Applies a change and stores the result before anything is acknowledged.
      const update = <A, E, R>(change: Effect.Effect<A, E, R>) =>
        writes.withPermits(1)(Effect.tap(change, () => save));
      const changed = <A>(change: () => A) => update(Effect.sync(change));
      const removable = scenario === 'registration-revocation';
      // Another device already created this account's keys and saved a mailbox with them; in the
      // recovery scenario that device is lost, and the person holds the account's Recovery Key.
      if (
        scenario === 'registration-recovery' &&
        state.recovery[lostDevice.account] === undefined
      ) {
        yield* changed(() => {
          state.recovery[lostDevice.account] = lostDevice.recovery;
          state.verifiers[lostDevice.account] = lostDevice.verifier;
          state.admitted[lostDevice.account] = [
            'synthetic-trusted-installation',
          ];
          state.records[lostDevice.account] = {
            [lostDevice.mailbox.payloadIdentifier]: lostDevice.mailbox,
          };
        });
      }

      const epoch = (account: string) => state.epochs[account] ?? 1;
      // Another device's removal of this one is recorded by its bare device identifier.
      const revoked = ({ trustedDeviceId }: Product) =>
        trustedDeviceId.startsWith(devicePrefix) &&
        state.removedIdentifiers.includes(
          trustedDeviceId.slice(devicePrefix.length),
        );
      const list = (product: Product, prefix: string) =>
        Arr.sort(
          Object.values(state.records[product.productAccountId] ?? {}).filter(
            ({ payloadIdentifier }) => payloadIdentifier.startsWith(prefix),
          ),
          byIdentifier,
        );
      const get = (product: Product, identifier: string) =>
        state.records[product.productAccountId]?.[identifier] ?? null;
      // Compare-and-set: the stored record, which differs from the write when another one won.
      const put = Effect.fn('SyntheticConvex.put')(function* ({
        product,
        identifier,
        payload,
        expected,
      }: Readonly<{
        product: Product;
        identifier: string;
        payload: Payload;
        expected: number | null;
      }>) {
        const account = product.productAccountId;
        return yield* update(
          Effect.gen(function* () {
            if (payload.keyVersion !== epoch(account)) {
              return yield* refuse('PRODUCT_SYNC_KEY_ROTATION_REQUIRED');
            }
            const existing = state.records[account]?.[identifier];
            if (existing !== undefined && existing.updatedAt !== expected) {
              return existing;
            }
            const stored = {
              payloadIdentifier: identifier,
              encryptedPayload: payload,
              updatedAt: (existing?.updatedAt ?? 0) + 1,
            };
            state.records[account] = {
              ...state.records[account],
              [identifier]: stored,
            };
            return stored;
          }),
        );
      });

      // A Trusted Device for an admitted identifier; any other device of an account with keys
      // waits.
      const connectDevice = (account: string, deviceIdentifier: string) =>
        update(
          Effect.gen(function* () {
            if (state.removedIdentifiers.includes(deviceIdentifier)) {
              return yield* refuse('revoked');
            }
            const admitted = state.admitted[account] ?? [];
            if (
              admitted.includes(deviceIdentifier) ||
              (admitted.length === 0 && state.recovery[account] === undefined)
            ) {
              if (!admitted.includes(deviceIdentifier)) {
                state.admitted[account] = [...admitted, deviceIdentifier];
              }
              return { id: devicePrefix + deviceIdentifier, pending: false };
            }
            return { id: pendingPrefix + deviceIdentifier, pending: true };
          }),
        );
      const connect = Effect.fn('SyntheticConvex.connect')(function* (
        identity: SignIn,
        deviceIdentifier: string,
      ) {
        const account = accounts.get(identity.subject);
        if (account === undefined) {
          return yield* refuse('invalid-identity');
        }
        if (state.deleted.includes(account)) {
          return yield* refuse('deleted');
        }
        // Another device removes this one after its first sign-in; the relaunch learns of it. Its
        // identifier stays refused, and a new sign-in waits like any other new device.
        const earlier = yield* changed(() => {
          const first = state.connectedLaunch;
          state.connectedLaunch = first ?? launch;
          return first !== undefined && first !== launch;
        });
        const admitted = state.admitted[account] ?? [];
        if (
          scenario === 'registration-revoked' &&
          earlier &&
          admitted.includes(deviceIdentifier)
        ) {
          yield* changed(() => {
            state.admitted[account] = admitted.filter(
              (identifier) => identifier !== deviceIdentifier,
            );
            state.removedIdentifiers.push(deviceIdentifier);
          });
        }
        const device = yield* connectDevice(account, deviceIdentifier);
        return {
          productAccountId: account,
          trustedDeviceId: device.id,
          trustedDeviceCredential: 'a'.repeat(64),
          ...(device.pending ? { pending: true } : {}),
          signInProviders: [identity.provider],
          productSyncMaterialInitialized: state.recovery[account] !== undefined,
        };
      });

      // This device and, until it is removed, the iPad; other sessions remove nothing.
      const trustedDevices = ({ trustedDeviceId }: Product) => {
        const key = state.deviceKeys[trustedDeviceId];
        return !removable || state.removed.includes(iPad.id)
          ? []
          : [
              {
                id: trustedDeviceId,
                displayName: 'This device',
                registeredAt: 1_788_307_200_000,
                lastSeenAt: 1_788_307_200_000,
                platform: 'ios',
                ...(key === undefined
                  ? {}
                  : { deviceEncryptionPublicKey: key }),
              },
              {
                id: iPad.id,
                displayName: 'iPad',
                registeredAt: 1_788_220_800_000,
                lastSeenAt: 1_788_220_800_000,
                platform: 'ios',
                deviceEncryptionPublicKey: iPad.key,
              },
            ];
      };

      // Removing the iPad, when the proposal still matches the account: its new epoch, or a
      // refusal's status and code as the HTTP route answers.
      // Why removing the iPad is refused, when it is: the HTTP route's status and code, or the
      // earlier activation's epoch for a repeated proposal.
      const refusedRemoval = (
        product: Product,
        request: typeof Activation.Type,
      ): readonly [number, unknown] | undefined => {
        const activated = state.proposals[request.proposalId];
        if (activated !== undefined) {
          return [200, { keyEpoch: activated }];
        }
        if (!removable || request.trustedDeviceToRevokeId !== iPad.id) {
          return [404, { code: 'KEY_ROTATION_INVALID' }];
        }
        if (state.removed.includes(iPad.id)) {
          return [409, { code: 'TRUSTED_DEVICE_ALREADY_REMOVED' }];
        }
        const current = epoch(product.productAccountId);
        if (
          request.expectedKeyEpoch !== current ||
          !sealedForThisDevice(product, request.keyEnvelopes)
        ) {
          return [409, { code: 'KEY_ROTATION_CONFLICT' }];
        }
        const wrapped = request.recoveryWrappedAccountKey;
        return wrapped.keyVersion === current + 1 && wrapped.schemaVersion === 3
          ? undefined
          : [400, { code: 'KEY_ROTATION_INVALID' }];
      };
      // The rotation carries one envelope, for this device's bound encryption key alone.
      const sealedForThisDevice = (
        product: Product,
        envelopes: (typeof Activation.Type)['keyEnvelopes'],
      ) => {
        const [envelope] = envelopes;
        return (
          envelopes.length === 1 &&
          envelope?.trustedDeviceId === product.trustedDeviceId &&
          envelope.deviceEncryptionPublicKey ===
            state.deviceKeys[product.trustedDeviceId] &&
          [
            envelope.deviceEncryptionPublicKey,
            envelope.encapsulatedKeyBase64,
            envelope.ciphertextBase64,
          ].every(isBase64)
        );
      };
      // Removes the iPad when the proposal still matches the account, once: its new epoch.
      const removal = (
        product: Product,
        request: typeof Activation.Type,
      ): readonly [number, unknown] => {
        const refused = refusedRemoval(product, request);
        const [envelope] = request.keyEnvelopes;
        if (refused !== undefined || envelope === undefined) {
          return refused ?? [409, { code: 'KEY_ROTATION_CONFLICT' }];
        }
        const account = product.productAccountId;
        const next = epoch(account) + 1;
        state.removed.push(iPad.id);
        state.epochs[account] = next;
        state.envelopes[product.trustedDeviceId] = {
          keyEpoch: next,
          encapsulatedKeyBase64: envelope.encapsulatedKeyBase64,
          ciphertextBase64: envelope.ciphertextBase64,
        };
        state.recovery[account] = request.recoveryWrappedAccountKey;
        state.verifiers[account] = request.recoveryVerifier;
        state.proposals[request.proposalId] = next;
        state.recoveryProposal[account] = request.proposalId;
        return [200, { keyEpoch: next }];
      };
      const activate = Effect.fn('SyntheticConvex.activate')(function* ({
        args,
        product,
      }: Presented) {
        const request = yield* Schema.decodeUnknownEffect(Activation)(
          args,
        ).pipe(Effect.orElseSucceed(() => undefined));
        if (request === undefined) {
          return yield* reply(400, { code: 'KEY_ROTATION_INVALID' });
        }
        const [status, body] = yield* changed(() => removal(product, request));
        return yield* reply(status, body);
      });

      const initialize = Effect.fn('SyntheticConvex.initialize')(function* ({
        args,
        product,
      }: Presented) {
        const { recoveryVerifier: verifier, deviceEncryptionPublicKey } = args;
        const envelope = yield* payloadOf(args.encryptedPayload);
        if (
          envelope === null ||
          !Predicate.isString(verifier) ||
          !isBase64(deviceEncryptionPublicKey)
        ) {
          return yield* refusal('UNAVAILABLE');
        }
        const account = product.productAccountId;
        // The first recovery envelope becomes the account's key material.
        const initialized = yield* changed(() => {
          const existing = state.recovery[account];
          if (existing !== undefined) {
            return Schema.toEquivalence(EncryptedPayload)(existing, envelope);
          }
          state.recovery[account] = envelope;
          state.verifiers[account] = verifier;
          state.deviceKeys[product.trustedDeviceId] = deviceEncryptionPublicKey;
          return true;
        });
        return yield* success({ initialized });
      });
      // Admits a Pending Device whose Recovery Key matched, with the key the proof named.
      const completeEnrollment = Effect.fn(
        'SyntheticConvex.completeEnrollment',
      )(function* ({ args, product }: Presented) {
        const account = product.productAccountId;
        const id = product.trustedDeviceId;
        const authorized = state.recovered[id];
        if (
          args.keyVersion !== epoch(account) ||
          product.pending !== true ||
          !id.startsWith(pendingPrefix) ||
          authorized === undefined ||
          authorized !== args.deviceEncryptionPublicKey
        ) {
          return yield* success({ admitted: false });
        }
        const trustedDeviceId = devicePrefix + id.slice(pendingPrefix.length);
        yield* changed(() => {
          state.requests = without(state.requests, id);
          state.recovered = without(state.recovered, id);
          state.admitted[account] = [
            ...(state.admitted[account] ?? []),
            id.slice(pendingPrefix.length),
          ];
          state.deviceKeys[trustedDeviceId] = authorized;
        });
        return yield* success({ admitted: true, trustedDeviceId });
      });
      const putPayload = Effect.fn('SyntheticConvex.putPayload')(function* ({
        args,
        identity,
        product,
      }: Presented) {
        const { payloadIdentifier, expectedUpdatedAt } = args;
        const payload = yield* payloadOf(args.encryptedPayload);
        if (
          identity === null ||
          !Predicate.isString(payloadIdentifier) ||
          payload === null
        ) {
          return yield* refusal('UNAVAILABLE');
        }
        return yield* put({
          product,
          identifier: payloadIdentifier,
          payload,
          expected: Predicate.isNumber(expectedUpdatedAt)
            ? expectedUpdatedAt
            : null,
        }).pipe(
          Effect.flatMap(success),
          Effect.catchTag('SyntheticRefusal', ({ code }) => refusal(code)),
        );
      });

      // Signing out forgets this device; signing in again makes it wait for admission.
      const unregister = ({ args, product }: Presented) =>
        changed(() => {
          const admitted = state.admitted[product.productAccountId];
          if (admitted !== undefined) {
            state.admitted[product.productAccountId] = admitted.filter(
              (identifier) => identifier !== args.deviceIdentifier,
            );
          }
          state.requests = without(state.requests, product.trustedDeviceId);
        }).pipe(Effect.andThen(success({ registered: false })));

      // The Convex calls the native vault makes, answered as Convex would, by function path or
      // HTTP route.
      const handlers: Readonly<
        Record<
          string,
          (
            call: Presented,
          ) => Effect.Effect<Reply, Schema.SchemaError | SyntheticRefusal>
        >
      > = {
        'productAccount:isTrustedDeviceRevoked': ({ product }) =>
          success(revoked(product)),
        '/sign-in-links/request': ({ identity, product }) =>
          identity === null ||
          accounts.get(identity.subject) !== product.productAccountId
            ? refusal('SIGN_IN_NOT_LINKED')
            : success({
                linkTicket: 'b'.repeat(64),
                signInProviders: product.signInProviders ?? [identity.provider],
              }),
        '/sign-in-links/complete': ({ identity, product }) =>
          scenario !== 'registration-link' || identity === null
            ? refusal('SIGN_IN_IDENTITY_OWNED')
            : success({
                productAccountId: product.productAccountId,
                signInProviders: [
                  ...(product.signInProviders ?? []),
                  identity.provider,
                ],
              }),
        'productAccount:unregisterTrustedDevice': unregister,
        'productAccount:unregisterPendingDevice': unregister,
        // Enrollment, recovery, key rotation and removal, which TypeScript sequences. A new
        // request replaces the earlier key.
        'productSyncEnrollment:request': ({ args, product }) => {
          const { deviceEncryptionPublicKey: deviceKey } = args;
          return product.pending !== true ||
            state.recovery[product.productAccountId] === undefined ||
            !isBase64(args.enrollmentPublicKey) ||
            !isBase64(deviceKey)
            ? refuse('unavailable')
            : changed(() => {
                state.requests[product.trustedDeviceId] = {
                  account: product.productAccountId,
                  deviceKey,
                };
                state.recovered = without(
                  state.recovered,
                  product.trustedDeviceId,
                );
              }).pipe(
                Effect.andThen(success({ expiresAt: 1_788_400_000_000 })),
              );
        },
        // No synthetic trusted device approves here; that scenario still runs natively.
        'productSyncEnrollment:status': ({ product }) =>
          success({
            state:
              state.requests[product.trustedDeviceId] === undefined
                ? 'cancelled'
                : 'pending',
          }),
        'productSyncEnrollment:complete': completeEnrollment,
        'productSyncEnrollment:recover': ({ args, product }) => {
          const envelope = state.recovery[product.productAccountId];
          const { deviceEncryptionPublicKey: deviceKey } = args;
          return product.pending !== true ||
            !proves(
              args.recoveryProof,
              state.verifiers[product.productAccountId],
            ) ||
            !isBase64(deviceKey) ||
            envelope === undefined
            ? success(null)
            : changed(() => {
                state.recovered[product.trustedDeviceId] = deviceKey;
              }).pipe(Effect.andThen(success(envelope)));
        },
        // The synthetic devices in this session never wait for this device's approval.
        'productSyncEnrollment:listPending': () => success([]),
        // The current Recovery Key binds a key once; a different one is never replaced.
        'productSync:bindDeviceEncryptionKey': ({ args, product }) => {
          const { deviceEncryptionPublicKey: deviceKey } = args;
          const bound = state.deviceKeys[product.trustedDeviceId];
          if (
            !proves(
              args.recoveryProof,
              state.verifiers[product.productAccountId],
            ) ||
            !isBase64(deviceKey)
          ) {
            return success({ bound: false });
          }
          return bound !== undefined && bound !== deviceKey
            ? refuse('unavailable')
            : changed(() => {
                state.deviceKeys[product.trustedDeviceId] = deviceKey;
              }).pipe(Effect.andThen(success({ bound: true })));
        },
        'productSync:getEncryptedPayloadForTrustedDevice': ({
          args: { payloadIdentifier },
          identity,
          product,
        }) => {
          if (identity === null || !Predicate.isString(payloadIdentifier)) {
            return refusal('UNAVAILABLE');
          }
          if (payloadIdentifier !== recoveryRecord) {
            return success(get(product, payloadIdentifier));
          }
          const envelope = state.recovery[product.productAccountId];
          return success(
            envelope === undefined
              ? null
              : { payloadIdentifier, encryptedPayload: envelope, updatedAt: 1 },
          );
        },
        'productAccount:getProductSyncKeyRotation': ({ product }) =>
          success(state.envelopes[product.trustedDeviceId] ?? null),
        'productAccount:acknowledgeProductSyncKeyRotation': ({ args }) =>
          success({ keyEpoch: args.keyEpoch ?? 1 }),
        'productAccount:listTrustedDevices': ({ product }) =>
          success(trustedDevices(product)),
        'productAccount:getKeyRotationProposal': ({
          args: { proposalId },
          product,
        }) => {
          const proposed = Predicate.isString(proposalId)
            ? state.proposals[proposalId]
            : undefined;
          return success(
            proposed === undefined
              ? null
              : {
                  keyEpoch: proposed,
                  recoveryKeyCurrent:
                    state.recoveryProposal[product.productAccountId] ===
                    proposalId,
                },
          );
        },
        '/trusted-devices/revoke': activate,
        // Product Sync's initialization and mailbox descriptors, which TypeScript sequences.
        'productSync:initialize': initialize,
        'productSync:listEncryptedPayloadsForTrustedDevice': ({
          args: { payloadIdentifierPrefix: prefix },
          identity,
          product,
        }) =>
          identity === null || !Predicate.isString(prefix)
            ? refusal('UNAVAILABLE')
            : success({
                page: list(product, prefix),
                isDone: true,
                continueCursor: '',
              }),
        'productSync:putEncryptedPayloadIfUnchanged': putPayload,
        '/product-account/delete': ({ product }) =>
          changed(() => {
            state.deleted.push(product.productAccountId);
          }).pipe(Effect.andThen(reply(200, { deleted: true }))),
      };

      const call = Effect.fn('SyntheticConvex.call')(function* ({
        path,
        product,
        ...presented
      }: typeof Call.Type) {
        const handler = Object.hasOwn(handlers, path)
          ? handlers[path]
          : undefined;
        return yield* product === null || handler === undefined
          ? refusal('UNAVAILABLE')
          : handler({ ...presented, product });
      });

      return {
        call,
        connect,
        deviceRevoked: (product: Product) =>
          Effect.succeed({ revoked: revoked(product) }),
        list: (product: Product, prefix: string) =>
          Effect.succeed({ records: list(product, prefix) }),
        get: (product: Product, identifier: string) =>
          Effect.succeed({ stored: get(product, identifier) }),
        put: (request: Parameters<typeof put>[0]) =>
          put(request).pipe(Effect.map((stored) => ({ stored }))),
        claimDelivery: (product: Product, identifier: string) =>
          changed(() => {
            const claims = state.claims[product.productAccountId] ?? [];
            if (!claims.includes(identifier)) {
              state.claims[product.productAccountId] = [...claims, identifier];
            }
            return { claimed: true };
          }),
      } as const;
    }),
  },
) {
  /** Consumers provide SyntheticScenario and SyntheticStateStorage. */
  public static readonly layer = Layer.effect(this, this.make);
}
