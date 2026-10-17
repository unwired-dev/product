import * as Effect from 'effect/Effect';
import * as Exit from 'effect/Exit';
import * as Layer from 'effect/Layer';
import * as ManagedRuntime from 'effect/ManagedRuntime';
import * as Option from 'effect/Option';
import * as Random from 'effect/Random';
import * as References from 'effect/References';
import * as Schema from 'effect/Schema';

import type { SyntheticRegistrationRelay } from '../synthetic-registration.ts';

import { EncryptedPayload } from '../registration-replies.ts';
import {
  Call,
  Identity,
  Receipt,
  SyntheticConvex,
  SyntheticStateStorage,
} from './synthetic-convex.ts';
import { SyntheticApple, SyntheticGoogle } from './synthetic-gmail.ts';
import { SyntheticMicrosoft } from './synthetic-graph.ts';
import {
  SyntheticRefusal,
  SyntheticScenario,
  refuse,
} from './synthetic-relay.ts';

export { sealEnrollment } from './enrollment-approval.ts';
export { SyntheticGmailMessages, SyntheticGoogle } from './synthetic-gmail.ts';
export { SyntheticScenario } from './synthetic-relay.ts';

// One request from the native relay: the seam it asks for and its JSON fields.
const Request = Schema.Struct({
  id: Schema.String,
  operation: Schema.String,
  payload: Schema.Record(Schema.String, Schema.Unknown),
});
const Text = Schema.NullOr(Schema.String);
const Subject = Schema.Struct({ subject: Schema.String });
const Owned = Schema.Struct({ product: Receipt, identifier: Schema.String });
const unavailable = () => new SyntheticRefusal({ code: 'unavailable' });

// The synthetic provider and backend layers for one launch, over the run's stored state.
export const syntheticRegistrationLayer = (relay: SyntheticRegistrationRelay) =>
  Layer.mergeAll(
    SyntheticGoogle.layer,
    SyntheticApple.layer,
    SyntheticMicrosoft.layer,
    SyntheticConvex.layer,
  ).pipe(
    Layer.provide(
      Layer.effect(
        SyntheticScenario,
        Random.next.pipe(
          Effect.map((launch) => ({
            scenario: relay.scenario,
            launch: String(launch),
          })),
        ),
      ),
    ),
    Layer.provide(
      Layer.succeed(SyntheticStateStorage, {
        read: Effect.tryPromise({
          try: () => relay.readState(),
          catch: unavailable,
        }).pipe(
          Effect.flatMap(Schema.decodeUnknownEffect(Text)),
          Effect.mapError(unavailable),
        ),
        save: (state) =>
          Effect.tryPromise({
            try: () => relay.saveState(state),
            catch: unavailable,
          }),
      }),
    ),
  );

const services = Effect.all({
  google: SyntheticGoogle,
  apple: SyntheticApple,
  microsoft: SyntheticMicrosoft,
  convex: SyntheticConvex,
});
type Services = Effect.Success<typeof services>;
// Each seam's request fields and the synthetic service that answers it.
const seam =
  <S extends Schema.Top, A, E>(
    schema: S,
    answer: (services: Services, input: S['Type']) => Effect.Effect<A, E>,
  ) =>
  (fields: unknown) =>
    Effect.flatMap(
      Effect.all([services, Schema.decodeUnknownEffect(schema)(fields)]),
      ([found, input]) => answer(found, input),
    );
const none = Schema.Struct({});
const seams: Readonly<
  Record<
    string,
    (
      fields: unknown,
    ) => Effect.Effect<
      unknown,
      unknown,
      SyntheticGoogle | SyntheticApple | SyntheticMicrosoft | SyntheticConvex
    >
  >
> = {
  'google.signIn': seam(
    Schema.Struct({ mail: Schema.Boolean, hint: Text }),
    ({ google }, { mail, hint }) => google.signIn(mail, hint),
  ),
  'google.refresh': seam(Subject, ({ google }, { subject }) =>
    google.refresh(subject),
  ),
  'google.verify': seam(Subject, ({ google }, { subject }) =>
    google.verify(subject),
  ),
  'google.gmail': seam(
    Schema.Struct({ subject: Schema.String, url: Schema.String, body: Text }),
    ({ google }, request) => google.gmail(request),
  ),
  'apple.signIn': seam(none, ({ apple }) => apple.signIn),
  'apple.credentialState': seam(Subject, ({ apple }, { subject }) =>
    apple.credentialState(subject),
  ),
  'microsoft.signIn': seam(none, ({ microsoft }) => microsoft.signIn),
  'microsoft.refresh': seam(none, ({ microsoft }) => microsoft.refresh),
  'microsoft.verify': seam(none, ({ microsoft }) => microsoft.verify),
  'microsoft.graph': seam(
    Schema.Struct({
      url: Schema.String,
      method: Schema.String,
      body: Text,
      contentType: Schema.String,
    }),
    ({ microsoft }, request) => microsoft.graph(request),
  ),
  'productSync.list': seam(
    Schema.Struct({ product: Receipt, prefix: Schema.String }),
    ({ convex }, { product, prefix }) => convex.list(product, prefix),
  ),
  'productSync.get': seam(Owned, ({ convex }, { product, identifier }) =>
    convex.get(product, identifier),
  ),
  'productSync.put': seam(
    Schema.Struct({
      product: Receipt,
      identifier: Schema.String,
      payload: EncryptedPayload,
      expectedUpdatedAt: Schema.NullOr(Schema.Finite),
    }),
    ({ convex }, { expectedUpdatedAt, ...request }) =>
      convex.put({ ...request, expected: expectedUpdatedAt }),
  ),
  'productSync.claimDelivery': seam(
    Owned,
    ({ convex }, { product, identifier }) =>
      convex.claimDelivery(product, identifier),
  ),
  'convex.deviceRevoked': seam(
    Schema.Struct({ product: Receipt }),
    ({ convex }, { product }) => convex.deviceRevoked(product),
  ),
  'convex.call': seam(Call, ({ convex }, call) => convex.call(call)),
  'convex.connect': seam(
    Schema.Struct({ identity: Identity, deviceIdentifier: Schema.String }),
    ({ convex }, { identity, deviceIdentifier }) =>
      convex.connect(identity, deviceIdentifier),
  ),
};

// Answers one native request through the synthetic service its seam names: the JSON reply, or
// the code the real service would refuse with.
export const answer = (
  operation: string,
  fields: Readonly<Record<string, unknown>>,
) => {
  const asked = Object.hasOwn(seams, operation) ? seams[operation] : undefined;
  return (asked === undefined ? refuse('unavailable') : asked(fields)).pipe(
    Effect.flatMap(Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown))),
    Effect.map((reply) => ({ reply })),
    Effect.catchIf(Schema.is(SyntheticRefusal), ({ code }) =>
      Effect.succeed({ code }),
    ),
    // Failures and defects alike refuse as an unavailable service, as the real one would.
    Effect.catchCause(() =>
      Effect.logError('Synthetic registration request failed:', operation).pipe(
        Effect.as({ code: 'unavailable' }),
      ),
    ),
  );
};

// Replaces the production module in registration Mock Mail Session bundles: every request the
// native relay forwards is answered, or refused.
export const answerSyntheticRegistration = (
  relay: SyntheticRegistrationRelay,
) => {
  const runtime = ManagedRuntime.make(syntheticRegistrationLayer(relay));
  const respond = async (value: unknown) => {
    const request = Schema.decodeUnknownOption(Request)(value);
    if (Option.isNone(request)) {
      return;
    }
    const { id, operation, payload } = request.value;
    const exit = await runtime.runPromiseExit(
      answer(operation, payload).pipe(
        Effect.provideService(References.LogToStderr, true),
      ),
    );
    // A layer that cannot start, such as unreadable stored state, refuses every request.
    const outcome = Exit.isSuccess(exit) ? exit.value : { code: 'unavailable' };
    if ('reply' in outcome) {
      relay.answer(id, outcome.reply);
    } else {
      relay.refuse(id, outcome.code);
    }
  };
  relay.listen((value) => {
    void respond(value);
  });
};
