/* oxlint-disable node/no-sync -- This test-only line protocol decodes bounded replies before dispatching its Promise. */
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

import type { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';

import * as Config from 'effect/Config';
import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import { onTestFinished } from 'vitest';

type Gmail = ReturnType<typeof createSyntheticGmail>;
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

// The ordinary suite stays credential-free. The explicit Mac runner supplies a signed native
// process, substituting only persistence while Gmail responses remain controlled.
// oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- The controlled provider is a live mutable test service.
export const withNativeHistory = (gmail: Readonly<Gmail>): Gmail => {
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
  const native: Gmail['native'] = {
    ...gmail.native,
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
  };
  return { ...gmail, native };
};
