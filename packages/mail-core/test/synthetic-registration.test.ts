import * as Effect from 'effect/Effect';
import * as Base64Url from 'effect/encoding/Base64Url';
import * as Layer from 'effect/Layer';
import * as Result from 'effect/Result';
import * as Schema from 'effect/Schema';

import type { SyntheticRegistrationRelay } from '../src/synthetic-registration.ts';

import {
  SyntheticGmailMessages,
  SyntheticGoogle,
  SyntheticScenario,
  answerSyntheticRegistration,
} from '../src/testing/synthetic-registration.ts';

const Message = Schema.fromJsonString(
  Schema.Struct({
    payload: Schema.Struct({
      headers: Schema.Array(
        Schema.Struct({ name: Schema.String, value: Schema.String }),
      ),
      body: Schema.optionalKey(
        Schema.Struct({ size: Schema.Finite, data: Schema.String }),
      ),
    }),
  }),
);
const Page = Schema.fromJsonString(
  Schema.Struct({
    messages: Schema.Array(Schema.Struct({ id: Schema.String })),
    nextPageToken: Schema.optionalKey(Schema.String),
  }),
);
const Receipt = Schema.Struct({
  trustedDeviceId: Schema.String,
  pending: Schema.optionalKey(Schema.Boolean),
});
// A Convex function's HTTP reply, whose body is the Convex envelope.
const Exchange = Schema.Struct({
  status: Schema.Finite,
  body: Schema.fromJsonString(
    Schema.Struct({ status: Schema.String, value: Schema.Unknown }),
  ),
});
type Outcome = Readonly<{ reply?: string; code?: string }>;
// A reply's JSON, as the native relay would parse it.
const decoded = <S extends Schema.Top & { readonly DecodingServices: never }>(
  schema: S,
  outcome: Outcome,
) => Schema.decodeUnknownSync(Schema.fromJsonString(schema))(outcome.reply);
const identity = { provider: 'google', subject: 'synthetic-product-subject' };
const deviceKey = 'ZGV2aWNlLWVuY3J5cHRpb24ta2V5';
const attachment = 'attachment; filename=body.html';

// One launch's relay over the run's state, as the native relay keeps it between launches.
function launch(scenario: string, storage: { state: string | null }) {
  const listeners: Array<(value: unknown) => void> = [];
  const waiting = new Map<string, (outcome: Outcome) => void>();
  const relay: SyntheticRegistrationRelay = {
    scenario,
    listen: (listener) => {
      listeners.push(listener);
    },
    answer: (id, reply) => {
      waiting.get(id)?.({ reply });
    },
    refuse: (id, code) => {
      waiting.get(id)?.({ code });
    },
    readState: () => Promise.resolve(storage.state),
    saveState: (state) => {
      storage.state = state;
      return Promise.resolve(null);
    },
  };
  answerSyntheticRegistration(relay);
  let next = 0;
  return (operation: string, payload: Readonly<Record<string, unknown>>) => {
    next += 1;
    const id = String(next);
    const { promise, resolve } = Promise.withResolvers<Outcome>();
    waiting.set(id, resolve);
    for (const listener of listeners) {
      listener({ id, operation, payload });
    }
    return promise;
  };
}

// The synthetic Google layer, optionally over an injected test mailbox.
function gmail(
  messages?: Readonly<Record<string, Readonly<Record<string, string>>>>,
) {
  const scenario = Layer.succeed(SyntheticScenario, {
    scenario: 'registration-declined',
    launch: 'test',
  });
  const layer = SyntheticGoogle.layer.pipe(
    Layer.provide(scenario),
    Layer.provide(
      messages === undefined
        ? Layer.empty
        : Layer.succeed(SyntheticGmailMessages, messages),
    ),
  );
  return (subject: string, url: string) =>
    Effect.runPromise(
      SyntheticGoogle.use((google) =>
        google.gmail({ subject, url, body: null }),
      ).pipe(Effect.provide(layer)),
    );
}
const messageURL = (id: string, format: string, headers: readonly string[]) =>
  `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}?format=${format}${headers
    .map((header) => `&metadataHeaders=${header}`)
    .join('')}`;

describe('the synthetic Gmail mailbox answers as Gmail does', () => {
  const ask = gmail({
    attached: { html: '<p>Attached body</p>', disposition: attachment },
    inline: { text: 'Inline body', disposition: 'inline' },
    absent: { text: 'Ordinary body' },
  });
  const read = async (
    id: string,
    headers: readonly string[],
    format = 'metadata',
  ) => {
    const { body } = await ask(
      'synthetic-alternate-mailbox',
      messageURL(id, format, headers),
    );
    const { payload } = Schema.decodeSync(Message)(body);
    return {
      headers: Object.fromEntries(
        payload.headers.map(({ name, value }) => [name, value]),
      ),
      body: payload.body,
      text:
        payload.body === undefined
          ? undefined
          : Result.getOrThrow(Base64Url.decodeString(payload.body.data)),
    };
  };

  it('keeps both admission headers whatever the selectors order or case, without body bytes', async () => {
    /* oxlint-disable vitest/max-expects -- One fixture proves every selector form. */
    expect.hasAssertions();
    for (const selectors of [
      ['Content-Type', 'Content-Disposition'],
      ['Content-Disposition', 'Content-Type'],
      ['cOnTeNt-DiSpOsItIoN', 'CONTENT-TYPE', 'Content-Disposition'],
    ]) {
      await expect(read('attached', selectors)).resolves.toStrictEqual({
        headers: {
          'Content-Type': 'text/html; charset=UTF-8',
          'Content-Disposition': attachment,
        },
        body: undefined,
        text: undefined,
      });
    }
    await expect(read('attached', ['Content-Type'])).resolves.toMatchObject({
      headers: { 'Content-Type': 'text/html; charset=UTF-8' },
    });
    await expect(
      read('attached', ['Content-Disposition']),
    ).resolves.toStrictEqual({
      headers: { 'Content-Disposition': attachment },
      body: undefined,
      text: undefined,
    });
    await expect(
      read('inline', ['Content-Type', 'Content-Disposition']),
    ).resolves.toMatchObject({
      headers: {
        'Content-Type': 'text/plain; charset=UTF-8',
        'Content-Disposition': 'inline',
      },
    });
    await expect(
      read('absent', ['Content-Type', 'Content-Disposition']),
    ).resolves.toStrictEqual({
      headers: { 'Content-Type': 'text/plain; charset=UTF-8' },
      body: undefined,
      text: undefined,
    });
  });

  it('serves the full single part, and refuses missing messages and other identities', async () => {
    expect.hasAssertions();
    for (const selectors of [[], ['Content-Type', 'Content-Disposition']]) {
      const full = await read('attached', selectors, 'full');
      expect({
        headers: full.headers,
        size: full.body?.size,
        text: full.text,
      }).toStrictEqual({
        headers: {
          'Content-Type': 'text/html; charset=UTF-8',
          'Content-Disposition': attachment,
        },
        size: '<p>Attached body</p>'.length,
        text: '<p>Attached body</p>',
      });
    }
    await expect(
      ask(
        'synthetic-alternate-mailbox',
        messageURL('missing', 'metadata', ['Content-Type']),
      ),
    ).resolves.toMatchObject({ status: 404 });
    await expect(
      ask(
        'synthetic-product-subject',
        messageURL('attached', 'metadata', ['Content-Type']),
      ),
    ).resolves.toMatchObject({ status: 401 });
  });

  it('keeps the packaged mailbox and its two list pages when no test mailbox is injected', async () => {
    expect.hasAssertions();
    const packaged = gmail();
    const page = async (query: string) => {
      const { body } = await packaged(
        'synthetic-alternate-mailbox',
        `https://gmail.googleapis.com/gmail/v1/users/me/messages${query}`,
      );
      const { messages, nextPageToken } = Schema.decodeSync(Page)(body);
      return { ids: messages.map(({ id }) => id), nextPageToken };
    };
    await expect(page('?format=metadata')).resolves.toStrictEqual({
      ids: ['19a0c0ffee000001', '19a0c0ffee000002'],
      nextPageToken: '2',
    });
    await expect(page('?format=metadata&pageToken=2')).resolves.toStrictEqual({
      ids: ['19a0c0ffee000003'],
      nextPageToken: undefined,
    });
  });
});

describe('the synthetic backend keeps its state across launches', () => {
  it('learns on relaunch that another device removed this one, which then waits as a new device', async () => {
    /* oxlint-disable vitest/max-expects -- One journey spans the removal and the new sign-in. */
    expect.hasAssertions();
    const storage = { state: null };
    const first = launch('registration-revoked', storage);
    const connected = await first('convex.connect', {
      identity,
      deviceIdentifier: 'installation-1',
    });
    expect(decoded(Receipt, connected)).toStrictEqual({
      trustedDeviceId: 'synthetic-device-installation-1',
    });
    const product = decoded(Schema.Unknown, connected);
    const initialized = await first('convex.call', {
      path: 'productSync:initialize',
      args: {
        encryptedPayload: {
          algorithm: 'AES-GCM-256',
          ciphertextBase64: 'AA==',
          keyVersion: 1,
          nonceBase64: 'AA==',
          schemaVersion: 3,
          tagBase64: 'AA==',
        },
        recoveryVerifier: 'verifier',
        deviceEncryptionPublicKey: deviceKey,
      },
      identity,
      product,
    });
    expect(decoded(Exchange, initialized).body).toStrictEqual({
      status: 'success',
      value: { initialized: true },
    });

    const relaunched = launch('registration-revoked', storage);
    await expect(
      relaunched('convex.connect', {
        identity,
        deviceIdentifier: 'installation-1',
      }),
    ).resolves.toStrictEqual({ code: 'revoked' });
    expect(
      decoded(
        Schema.Unknown,
        await relaunched('convex.deviceRevoked', { product }),
      ),
    ).toStrictEqual({ revoked: true });
    expect(
      decoded(
        Receipt,
        await relaunched('convex.connect', {
          identity,
          deviceIdentifier: 'installation-2',
        }),
      ),
    ).toStrictEqual({
      trustedDeviceId: 'synthetic-pending-installation-2',
      pending: true,
    });
  });

  it('admits a Pending Device that presents the Recovery Key proof for the lost device account', async () => {
    /* oxlint-disable vitest/max-expects -- One recovery spans request, proof, admission and readback. */
    expect.hasAssertions();
    const ask = launch('registration-recovery', { state: null });
    const connected = await ask('convex.connect', {
      identity,
      deviceIdentifier: 'installation-1',
    });
    expect(decoded(Receipt, connected).pending).toBe(true);
    const product = decoded(Schema.Unknown, connected);
    const call = async (
      path: string,
      args: Readonly<Record<string, unknown>>,
    ) =>
      decoded(
        Exchange,
        await ask('convex.call', { path, args, identity, product }),
      ).body.value;
    await expect(
      call('productSyncEnrollment:request', {
        enrollmentPublicKey: deviceKey,
        deviceEncryptionPublicKey: deviceKey,
      }),
    ).resolves.toStrictEqual({ expiresAt: 1_788_400_000_000 });
    await expect(
      call('productSyncEnrollment:status', {}),
    ).resolves.toStrictEqual({ state: 'pending' });
    await expect(
      call('productSyncEnrollment:recover', {
        recoveryProof: 'not-the-proof',
        deviceEncryptionPublicKey: deviceKey,
      }),
    ).resolves.toBeNull();
    // The proof native code derives from the fixed Recovery Key the journey types.
    await expect(
      call('productSyncEnrollment:recover', {
        recoveryProof:
          '98ea35e4d381b7eb87ed90ed99820f1d835fc943c45ac694a27780fa0ec5b794',
        deviceEncryptionPublicKey: deviceKey,
      }),
    ).resolves.toMatchObject({ schemaVersion: 3, keyVersion: 1 });
    await expect(
      call('productSyncEnrollment:complete', {
        keyVersion: 1,
        deviceEncryptionPublicKey: deviceKey,
      }),
    ).resolves.toStrictEqual({
      admitted: true,
      trustedDeviceId: 'synthetic-device-installation-1',
    });
    await expect(
      call('productSync:listEncryptedPayloadsForTrustedDevice', {
        payloadIdentifierPrefix: 'mailbox.',
      }),
    ).resolves.toMatchObject({
      page: [{ payloadIdentifier: 'mailbox.4522f315d883760cd42fe8fd1d8bef94' }],
    });
  });

  it('refuses a seam it does not know, as native reports an unavailable service', async () => {
    expect.hasAssertions();
    const ask = launch('registration-declined', { state: null });
    await expect(ask('google.unknown', {})).resolves.toStrictEqual({
      code: 'unavailable',
    });
    await expect(
      ask('google.signIn', { mail: true, hint: 'other@example.invalid' }),
    ).resolves.toMatchObject({ reply: expect.any(String) });
  });
});
