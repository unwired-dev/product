import * as Effect from 'effect/Effect';

import type { NativeGmailMailbox } from '../gmail-inbox.ts';

const ignore = () => undefined;

// Remote Message Content is cached per mailbox address, message and exact source.
const remoteKey = (
  owner: string,
  { id, url }: Readonly<{ id: string; url: string }>,
) => `${owner}\n${id}\n${url}`;

const rejection = (code: string) =>
  Promise.reject(Object.assign(new Error('Synthetic failure'), { code }));

// A controlled remote-image boundary, independently owned by each synthetic mailbox.
export function createSyntheticRemoteContent(
  current: (
    scope: Readonly<{ address: string; generation: string }>,
  ) => boolean,
  address: () => string,
) {
  // A controlled image server for Remote Message Content: each source answers standard base64
  // bytes or a native rejection code. Fetches wait while the server is paused.
  const remoteServer = new Map<
    string,
    Readonly<{ data: string }> | Readonly<{ code: string }>
  >();
  const remoteCache = new Map<string, string>();
  const remoteFetches: string[] = [];
  const remoteCommits: Array<ReadonlyArray<readonly [string, string, string]>> =
    [];
  const remoteSessions = new Map<string, AbortController>();
  let remoteInFlight = 0;
  let remoteMostInFlight = 0;
  let remotePaused:
    | Readonly<{ promise: Promise<void>; resume: () => void }>
    | undefined = undefined;
  const native = {
    openRemoteContent: (owner, resource) =>
      current(owner)
        ? Promise.resolve({
            data: remoteCache.get(remoteKey(owner.address, resource)) ?? null,
          })
        : rejection('mailbox-invalidated'),
    fetchRemoteContent: async (owner, url, request) => {
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      const session =
        remoteSessions.get(request.session) ?? new AbortController();
      remoteSessions.set(request.session, session);
      if (session.signal.aborted) {
        return rejection('refused');
      }
      remoteFetches.push(url);
      remoteInFlight += 1;
      remoteMostInFlight = Math.max(remoteMostInFlight, remoteInFlight);
      try {
        await Effect.runPromise(
          Effect.race(
            Effect.promise(() => remotePaused?.promise ?? Promise.resolve()),
            Effect.callback<undefined>((resume) => {
              const stop = () => {
                session.signal.removeEventListener('abort', stop);
                resume(Effect.undefined);
              };
              session.signal.addEventListener('abort', stop, { once: true });
              if (session.signal.aborted) {
                stop();
              }
              return Effect.sync(() => {
                session.signal.removeEventListener('abort', stop);
              });
            }),
          ),
        );
      } finally {
        remoteInFlight -= 1;
      }
      if (session.signal.aborted) {
        return rejection('refused');
      }
      const answer = remoteServer.get(url) ?? { code: 'unavailable' };
      return 'code' in answer ? rejection(answer.code) : { data: answer.data };
    },
    cancelRemoteContent: (_owner, session, finished) => {
      remoteSessions.get(session)?.abort();
      if (!finished) {
        remoteSessions.delete(session);
      }
      return Promise.resolve({});
    },
    commitRemoteContent: (owner, resource, admission) => {
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      remoteCommits.push(admission.protected);
      remoteCache.set(remoteKey(owner.address, resource), admission.data);
      return Promise.resolve({ admitted: true });
    },
  } satisfies Pick<
    NativeGmailMailbox,
    | 'openRemoteContent'
    | 'fetchRemoteContent'
    | 'cancelRemoteContent'
    | 'commitRemoteContent'
  >;

  return {
    native,
    controls: {
      // Remote Message Content: the controlled server's answers, the sources fetched in order, the
      // protected resources each cache commit named, and the most fetches in flight at once.
      serveRemote: (
        url: string,
        answer: Readonly<{ data: string }> | Readonly<{ code: string }>,
      ) => {
        remoteServer.set(url, answer);
      },
      remoteFetches,
      remoteCommits,
      remoteCached: (id: string, url: string) =>
        remoteCache.has(remoteKey(address(), { id, url })),
      remoteInFlight: () => remoteInFlight,
      mostRemoteInFlight: () => remoteMostInFlight,
      pauseRemote: () => {
        let resume: () => void = ignore;
        // oxlint-disable-next-line promise/avoid-new -- The controlled server holds fetches until the test resumes it.
        const promise = new Promise<void>((resolve) => {
          resume = resolve;
        });
        remotePaused = { promise, resume };
      },
      resumeRemote: () => {
        remotePaused?.resume();
        remotePaused = undefined;
      },
    },
  };
}
