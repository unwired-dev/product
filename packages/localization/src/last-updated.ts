import type { TFunction } from 'i18next';

const minute = 60_000;

// How long ago the shown Inboxes were last brought up to date: the oldest of their latest
// completed synchronizations, as ISO instants. Undefined before any completed.
export function lastUpdated(
  // oxlint-disable-next-line typescript/prefer-readonly-parameter-types -- i18next's translation function is mutable; this only calls it.
  t: TFunction,
  synchronizedAt: readonly string[],
  now: number,
) {
  if (synchronizedAt.length === 0) {
    return undefined;
  }
  const oldest = Math.min(...synchronizedAt.map((at) => Date.parse(at)));
  const minutes = Math.floor((now - oldest) / minute);
  if (minutes < 1) {
    return t('inbox.updatedJustNow');
  }
  if (minutes < 60) {
    return t('inbox.updatedMinutes', { count: minutes });
  }
  const hours = Math.floor(minutes / 60);
  return hours < 24
    ? t('inbox.updatedHours', { count: hours })
    : t('inbox.updatedDays', { count: Math.floor(hours / 24) });
}
