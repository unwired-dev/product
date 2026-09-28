import type { Message } from '@private-email/mail-core';
import type { ReactNode } from 'react';

import { listInbox, MockMailbox } from '@private-email/mail-core';
import * as Effect from 'effect/Effect';
import * as ManagedRuntime from 'effect/ManagedRuntime';
import { createContext, useContext, useEffect, useState } from 'react';

type InboxState =
  | { readonly kind: 'loading' }
  | { readonly kind: 'failed' }
  | { readonly kind: 'ready'; readonly messages: readonly Message[] };

const InboxContext = createContext<InboxState>({ kind: 'loading' });

export function InboxProvider({ children }: { readonly children: ReactNode }) {
  const [state, setState] = useState<InboxState>({ kind: 'loading' });

  useEffect(() => {
    const runtime = ManagedRuntime.make(MockMailbox);
    runtime.runFork(
      listInbox.pipe(
        Effect.matchCause({
          onFailure: () => {
            setState({ kind: 'failed' });
          },
          onSuccess: (messages) => {
            setState({ kind: 'ready', messages });
          },
        }),
      ),
    );
    return () => {
      void runtime.dispose();
    };
  }, []);

  return <InboxContext value={state}>{children}</InboxContext>;
}

export function useInbox() {
  return useContext(InboxContext);
}
