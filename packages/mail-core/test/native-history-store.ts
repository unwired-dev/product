/* oxlint-disable node/no-sync -- This test-only line protocol decodes bounded replies before dispatching its Promise. */
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

import type { NativeGmailMailbox } from '@private-email/mail-core/gmail-inbox';

import * as Config from 'effect/Config';
import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import { onTestFinished } from 'vitest';

type Stored = Pick<
  NativeGmailMailbox,
  | 'openMailbox'
  | 'commitMailbox'
  | 'openMailboxSegment'
  | 'openMessageBody'
  | 'commitMessageBody'
  | 'listMessageBodies'
  | 'retainMessageBodies'
>;
const json = Schema.fromJsonString(Schema.Unknown);
const encode = Schema.encodeSync(json);
const decode = Schema.decodeUnknownSync(json);
const replySchema = Schema.Record(Schema.String, Schema.Unknown);
const replyOf = Schema.decodeUnknownSync(replySchema);
const scopeOf = Schema.decodeUnknownSync(
  Schema.Struct({
    address: Schema.String,
    generation: Schema.String,
    owner: Schema.String,
  }),
);
const storedOf = Schema.decodeUnknownSync(
  Schema.Struct({
    revision: Schema.Int,
    address: Schema.String,
    document: Schema.NullOr(Schema.String),
  }),
);
const committedOf = Schema.decodeUnknownSync(
  Schema.Struct({
    revision: Schema.Int,
    address: Schema.String,
    document: Schema.String,
  }),
);
const segmentOf = Schema.decodeUnknownSync(
  Schema.Struct({ document: Schema.NullOr(Schema.String) }),
);
const admittedOf = Schema.decodeUnknownSync(
  Schema.Struct({ admitted: Schema.Boolean }),
);
const storedBodiesOf = Schema.decodeUnknownSync(
  Schema.Struct({
    stored: Schema.Array(Schema.String),
    excluded: Schema.Array(Schema.String),
  }),
);

// The ordinary suite stays credential-free. The explicit Mac runner supplies a signed native
// process, substituting only persistence while Gmail or Graph responses remain controlled.
export const withNativeHistory = <T extends Readonly<{ native: Stored }>>(
  gmail: T,
): T => {
  const executable = Effect.runSync(
    Config.String('UNWIRED_HISTORY_STORE_EXECUTABLE').pipe(
      Config.withDefault(''),
    ),
  );
  if (executable === '') {
    return gmail;
  }
  const child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  const pending: Array<ReturnType<typeof Promise.withResolvers<unknown>>> = [];
  const lines = createInterface({ input: child.stdout });
  lines.on('line', (line) => {
    const waiting = pending.shift();
    try {
      const reply = replyOf(decode(line));
      if ('code' in reply) {
        waiting?.reject(
          Object.assign(new Error('Native history storage refused'), reply),
        );
      } else {
        waiting?.resolve(reply);
      }
    } catch (error) {
      waiting?.reject(error);
    }
  });
  const exited = Promise.withResolvers<undefined>();
  let failure: Readonly<Error> | undefined = undefined;
  const failed = (error: Readonly<Error>) => {
    failure = error;
    for (const waiting of pending.splice(0)) {
      waiting.reject(error);
    }
    exited.reject(error);
  };
  child.on('error', failed);
  child.stdin.on('error', failed);
  // stdout can still contain the final reply when exit fires; close waits for its drain.
  child.on('close', (code) => {
    if (code === 0 && pending.length === 0) {
      exited.resolve(undefined);
    } else {
      failed(new Error(`Native history process exited ${code}`));
    }
  });
  // Observe early process errors while test cleanup still owns and checks the final result.
  // oxlint-disable-next-line promise/prefer-await-to-then -- Register rejection observation before a process can exit; cleanup awaits it.
  void exited.promise.catch(() => undefined);
  onTestFinished(async () => {
    child.stdin.end();
    await exited.promise;
    lines.close();
  });
  const call = (command: unknown) => {
    const result = Promise.withResolvers<unknown>();
    if (failure !== undefined) {
      result.reject(failure);
      return result.promise;
    }
    pending.push(result);
    child.stdin.write(`${encode(command)}\n`);
    return result.promise;
  };
  const persistence: Stored = {
    openMailbox: async () => {
      const scope = scopeOf(await gmail.native.openMailbox());
      return {
        ...storedOf(await call({ operation: 'open', address: scope.address })),
        ...scope,
      };
    },
    commitMailbox: async (...[scope, revision, document, history]) => {
      const saved = committedOf(
        await call({
          operation: 'commit',
          address: scope.address,
          revision,
          document,
          history,
        }),
      );
      // Keep the synthetic body's revision fence aligned with the real metadata commit. All
      // metadata/segment reads above and below use the native vault's durable answer.
      const mirrored = scopeOf(
        await gmail.native.commitMailbox(scope, revision, document, history),
      );
      return { ...saved, ...mirrored };
    },
    openMailboxSegment: async (scope, name) =>
      segmentOf(
        await call({ operation: 'segment', address: scope.address, name }),
      ),
    // Body calls pass through the synthetic store first, keeping its injected failures and
    // ownership checks, then answer from the native Bounded Encrypted Body Cache.
    openMessageBody: async (scope, id) => {
      await gmail.native.openMessageBody(scope, id);
      return segmentOf(
        await call({ operation: 'body', address: scope.address, id }),
      );
    },
    commitMessageBody: async (scope, id, admission) => {
      if (
        !admittedOf(await gmail.native.commitMessageBody(scope, id, admission))
          .admitted
      ) {
        return { admitted: false };
      }
      return admittedOf(
        await call({
          operation: 'commit-body',
          address: scope.address,
          id,
          document: admission.document,
          tier: admission.tier,
          protectedIds: admission.protectedIds,
          revision: admission.expectedRevision,
        }),
      );
    },
    listMessageBodies: async (scope, ids) => {
      await gmail.native.listMessageBodies(scope, ids);
      const { stored, excluded } = storedBodiesOf(
        await call({ operation: 'list-bodies', address: scope.address, ids }),
      );
      return { stored: [...stored], excluded: [...excluded] };
    },
    retainMessageBodies: async (scope, ids, protectedIds) => {
      await gmail.native.retainMessageBodies(scope, ids, protectedIds);
      await call({
        operation: 'retain-bodies',
        address: scope.address,
        revision: scope.revision,
        ids,
        protectedIds,
      });
      return null;
    },
  };
  return { ...gmail, native: { ...gmail.native, ...persistence } };
};
