import type { MailAssistanceEnablementStore } from '@private-email/mail-core/assistance-enablement';

import { mailAssistanceEnabled } from '@private-email/mail-core/assistance-enablement';
import { defaultProfile } from '@private-email/mail-core/registration';
import { createContext, use, useCallback, useLayoutEffect } from 'react';

export const MailAssistanceProfileContext = createContext(defaultProfile);

export const MailAssistanceContext = createContext<
  MailAssistanceEnablementStore | undefined
>(undefined);

// Mounted request owners retire synchronously when enablement changes, before React hides them.
// The live predicate also refuses queued native input between the Off event and that commit.
// `permits` is the consent the owner needs, Mail Assistance Enablement by default.
export function useMailAssistanceLifetime(
  retire: () => void,
  permits = mailAssistanceEnabled,
) {
  const store = use(MailAssistanceContext);
  const profile = use(MailAssistanceProfileContext);
  const owner = store?.getSnapshot()?.owner ?? undefined;
  const enabled = useCallback(
    () => store === undefined || permits(store.getSnapshot(), owner, profile),
    [store, owner, profile, permits],
  );
  useLayoutEffect(() => {
    const check = () => {
      if (!enabled()) {
        retire();
      }
    };
    const unsubscribe = store?.subscribe(check);
    check();
    return unsubscribe;
  }, [store, enabled, retire]);
  return enabled;
}
