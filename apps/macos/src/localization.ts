import {
  createLocalization,
  createMessageDateFormat,
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

export function useMessageDateFormat(detail = false) {
  const { settings } = useLocalization();
  return useMemo(
    () => createMessageDateFormat(settings.locale, detail),
    [settings.locale, detail],
  );
}
