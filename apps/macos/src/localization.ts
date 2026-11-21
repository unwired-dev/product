import {
  createLocalization,
  createMessageDateFormat,
  createMessageDateFormats,
} from '@private-email/localization';
import { useMemo, useSyncExternalStore } from 'react';
import { useTranslation } from 'react-i18next';

import { languageStorage } from './language-storage.ts';

export const localization = createLocalization(
  languageStorage.initial,
  languageStorage,
);
async function refresh() {
  try {
    await localization.refresh();
  } catch {
    // Keep the last language and retry on the next activation.
  }
}
languageStorage.subscribe(() => {
  void refresh();
});

export function useLocalization() {
  const settings = useSyncExternalStore(
    localization.subscribe,
    localization.getSnapshot,
  );
  const { t } = useTranslation('translation', { i18n: localization.i18n });
  return { t, settings };
}

// How the interface names when a message arrived, on the device's clocks: a time today, a weekday
// this week, a month before that, and a message header's date.
export function useMessageDateFormats() {
  const { settings } = useLocalization();
  return useMemo(
    () => createMessageDateFormats(settings.locale, settings.timeZone),
    [settings.locale, settings.timeZone],
  );
}

// The full UTC received date a response quotes when the message has no Date header.
export function useMessageDateFormat() {
  const { settings } = useLocalization();
  return useMemo(
    () => createMessageDateFormat(settings.locale),
    [settings.locale],
  );
}
