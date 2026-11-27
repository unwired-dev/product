import type { ReactNode } from 'react';

import { spacing } from '@private-email/mail-core/theme';
import {
  use,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { AccessibilityInfo, Platform, StyleSheet, View } from 'react-native';

import type { SaveOutcome } from './message-body.tsx';

import { Action } from './action.tsx';
import { Notice, Toast } from './design.tsx';
import { WindowBarContext } from './inbox-bar.tsx';
import { useLocalization } from './localization.ts';
import { openLink } from './message-body.tsx';
import { usePalette } from './theme.ts';

const compact = Platform.OS === 'ios' && !Platform.isPad;

const styles = StyleSheet.create({
  toast: {
    position: 'absolute',
    left: spacing.l,
    right: spacing.l,
    alignItems: 'center',
  },
  // Beneath the iPhone reader's subject, above its scrolling content.
  notice: { paddingHorizontal: spacing.l, paddingTop: spacing.s },
});

// How long a saved copy's toast stays.
const savedToastDuration = 6000;

// The reader's latest Save to Files outcome and the way to start a save that reports one. A saved
// copy's toast leaves on its own; a failure stays until the next outcome. Both are announced. Each
// belongs to one uninterrupted visit to a readable message: another message, a lock or closing
// the reader drops it, and a save started in an earlier visit reports nothing.
export function useSaveOutcome(message: string, readable: boolean) {
  const { t } = useLocalization();
  const visit = useMemo(
    () => (readable ? { message } : undefined),
    [message, readable],
  );
  const [shown, setShown] =
    useState<
      Readonly<{ outcome: SaveOutcome; visit: object; open: boolean }>
    >();
  const current =
    visit !== undefined && shown?.visit === visit ? shown : undefined;
  const showing = useRef<object>(undefined);
  useLayoutEffect(() => {
    showing.current = visit;
    return () => {
      showing.current = undefined;
    };
  }, [visit]);
  useEffect(() => {
    if (current?.outcome.kind !== 'saved' || !current.open) {
      return;
    }
    const timer = setTimeout(() => {
      setShown((last) => last && { ...last, open: false });
    }, savedToastDuration);
    return () => {
      clearTimeout(timer);
    };
  }, [current]);
  const start = () => {
    const started = visit;
    return (outcome: SaveOutcome) => {
      if (started === undefined || showing.current !== started) {
        return;
      }
      setShown({ outcome, visit: started, open: true });
      AccessibilityInfo.announceForAccessibility(
        outcome.kind === 'saved'
          ? t('attachment.savedNamed', outcome.copy)
          : t('attachment.saveFailed', { name: outcome.name }),
      );
    };
  };
  return { shown: current, start };
}

type Shown = ReturnType<typeof useSaveOutcome>['shown'];

// The iPhone reader's failure, beneath its subject, where it stays in view while the content
// scrolls.
export function SaveFailedNotice({ shown }: { readonly shown: Shown }) {
  const colors = usePalette();
  const { t } = useLocalization();
  if (!compact || shown?.outcome.kind !== 'failed') {
    return null;
  }
  const { name, retry } = shown.outcome;
  return (
    <View style={styles.notice}>
      <Notice
        icon="exclamationmark.triangle"
        iconColor={colors.statusWarning}
        message={t('attachment.saveFailed', { name })}
        // A long file name leaves the reader room; VoiceOver reads it in full.
        messageLines={3}
        detail={t('attachment.saveFailedDetail')}
        messageRole="alert">
        <Action
          label={t('attachment.saveToFiles')}
          accessibilityLabel={t('attachment.saveToFilesLabel', { name })}
          onPress={retry}
        />
      </Notice>
    </View>
  );
}

// The toast for a saved copy, with Show to find it in Files, and on iPad for a failure too: above
// the iPhone reader's toolbar at `bottom`, or with the window bar's notices on iPad. `other` is
// another reader toast, such as an Unsubscribe request's Undo Send, shown in its place otherwise.
export function SaveOutcomeToast({
  shown,
  bottom,
  other = null,
}: {
  readonly shown: Shown;
  readonly bottom: number;
  readonly other?: ReactNode;
}) {
  const { t } = useLocalization();
  const windowBar = use(WindowBarContext);
  // The words outlast the toast so it can fade out.
  const [said, setSaid] = useState(shown);
  if (shown !== undefined && shown !== said) {
    setSaid(shown);
  }
  let toast: ReactNode = null;
  if (said?.outcome.kind === 'saved') {
    const { copy } = said.outcome;
    toast = (
      <Toast
        open={shown?.open === true}
        symbol="square.and.arrow.down"
        message={
          compact
            ? t('attachment.saved', copy)
            : t('attachment.savedNamed', copy)
        }
        detail={compact ? copy.name : undefined}
        action={t('attachment.show')}
        accessibilityLabel={t('attachment.showLabel', copy)}
        onAction={() => {
          void openLink(copy.show);
        }}
      />
    );
  } else if (said?.outcome.kind === 'failed' && !compact) {
    const { name, retry } = said.outcome;
    toast = (
      <Toast
        open={shown?.open === true}
        symbol="exclamationmark.triangle.fill"
        message={t('attachment.saveFailed', { name })}
        detail={t('attachment.saveFailedDetail')}
        action={t('attachment.saveToFiles')}
        accessibilityLabel={t('attachment.saveToFilesLabel', { name })}
        onAction={retry}
      />
    );
  }
  toast ??= other;
  useLayoutEffect(() => {
    windowBar?.showReaderNotice(toast);
  });
  useLayoutEffect(
    () => () => {
      windowBar?.showReaderNotice(null);
    },
    [windowBar],
  );
  return windowBar === undefined && toast !== null ? (
    <View
      pointerEvents="box-none"
      style={[styles.toast, { bottom }]}>
      {toast}
    </View>
  ) : null;
}
