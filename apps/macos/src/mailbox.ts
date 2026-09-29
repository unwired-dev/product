import type { Message } from '@private-email/mail-core';

import { listInbox, MockMailbox } from '@private-email/mail-core';
import * as ManagedRuntime from 'effect/ManagedRuntime';
import { useEffect, useState } from 'react';

type InboxState =
  | { readonly kind: 'loading' }
  | { readonly kind: 'failed' }
  | { readonly kind: 'ready'; readonly messages: readonly Message[] };

// One runtime per JavaScript application, retained when every window unmounts.
const runtime = ManagedRuntime.make(MockMailbox);
const inbox = runtime.runPromise(listInbox);

export function useInbox() {
  const [state, setState] = useState<InboxState>({ kind: 'loading' });
  useEffect(() => {
    let mounted = true;
    async function load() {
      try {
        const messages = await inbox;
        if (mounted) {
          setState({ kind: 'ready', messages });
        }
      } catch {
        if (mounted) {
          setState({ kind: 'failed' });
        }
      }
    }
    void load();
    return () => {
      mounted = false;
    };
  }, []);
  return state;
}
