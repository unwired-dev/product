import type { Translate } from '@private-email/localization';

import {
  savedPreference,
  savePreference,
} from '@private-email/mail-core/commands';
import { radius, spacing } from '@private-email/mail-core/theme';
import * as Effect from 'effect/Effect';
import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import { AccessibilityInfo, StyleSheet, Text, View } from 'react-native';

import type { SaveOutcome } from './message-body.tsx';

import { Toast } from './design.tsx';
import { native } from './host.ts';
import { useReaderToast } from './inbox-bar.tsx';
import { useLocalization } from './localization.ts';
import { useReaderTop } from './message-body.tsx';
import { windowHost } from './settings-window-client.ts';
import { textStyles, usePalette } from './theme.ts';

const styles = StyleSheet.create({
  failed: {
    gap: spacing.xs,
    padding: spacing.m,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
});

type Failed = Extract<SaveOutcome, { kind: 'failed' }>;

// Names the folder the person chose when known, otherwise the file.
const failedTitle = (t: Translate, { name, folder }: Failed) =>
  folder === undefined
    ? t('attachment.saveFailed', { name })
    : t('attachment.saveFailedIn', { folder });

// How long a saved copy's toast stays.
const savedToastDuration = 6000;

// The reader's latest Save As… outcome and the way to start a save that reports one. A saved
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
          : failedTitle(t, outcome),
      );
    };
  };
  return { shown: current, start };
}

type Shown = ReturnType<typeof useSaveOutcome>['shown'];
// The failure beneath the reader's header, until the next outcome. Save As… stays in the
// attachment's menu to try again.
export function SaveFailedNotice({ shown }: { readonly shown: Shown }) {
  const colors = usePalette();
  const { t } = useLocalization();
  const top = useReaderTop();
  const failed = shown?.outcome.kind === 'failed' ? shown : undefined;
  // The menu that started the save may be far down a long message.
  useEffect(() => {
    if (failed !== undefined) {
      top?.();
    }
  }, [failed, top]);
  if (shown?.outcome.kind !== 'failed') {
    return null;
  }
  const title = failedTitle(t, shown.outcome);
  const detail = t('attachment.saveFailedDetail');
  return (
    // React Native macOS exposes plain Text to accessibility only through an accessible parent.
    <View
      accessible
      accessibilityLabel={`${title} ${detail}`}
      accessibilityRole="alert"
      style={[styles.failed, { backgroundColor: colors.onDeviceSurface }]}>
      <Text
        style={[textStyles.caption1Emphasized, { color: colors.onDeviceInk }]}>
        {title}
      </Text>
      <Text style={[textStyles.body, { color: colors.textPrimary }]}>
        {detail}
      </Text>
    </View>
  );
}

// A saved copy's toast, with Show in Finder, among the floating bar's notices.
export function SaveOutcomeToast({ shown }: { readonly shown: Shown }) {
  const { t } = useLocalization();
  // The words outlast the toast so it can fade out.
  const [said, setSaid] = useState(shown);
  if (shown !== undefined && shown !== said) {
    setSaid(shown);
  }
  let toast = null;
  if (said?.outcome.kind === 'saved') {
    const { copy } = said.outcome;
    toast = (
      <Toast
        open={shown?.open === true}
        symbol="square.and.arrow.down"
        message={t('attachment.savedNamed', copy)}
        action={t('attachment.showInFinder')}
        actionLabel={t('attachment.showInFinderLabel', copy)}
        onAction={() => {
          windowHost()?.showInFinder(copy.show);
        }}
      />
    );
  }
  return useReaderToast(toast, shown?.open === true);
}

// The Profiles on this Mac that save received attachments to Downloads, by preference key, and
// the keys already read. Saving one there with Save As… remembers Downloads for the Profile, in
// this Mac's preferences only; it is never synchronized.
const remembered = new Set<string>();
const read = new Set<string>();
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
const publish = (key: string) => {
  remembered.add(key);
  for (const listener of listeners) {
    listener();
  }
};

// Whether the signed-in Product Account's Profile saves received attachments to Downloads on this
// Mac, and how a copy saved there remembers it; none before an account is signed in.
export function useRememberedDownloads(
  signedIn: Readonly<{ account: string }> | undefined,
  profile: string,
) {
  const key =
    signedIn === undefined
      ? undefined
      : `attachment-save-folder:${signedIn.account}:${profile}`;
  const saves = useSyncExternalStore(
    subscribe,
    () => key !== undefined && remembered.has(key),
  );
  useEffect(() => {
    if (key === undefined || read.has(key)) {
      return;
    }
    read.add(key);
    void (async () => {
      const value = await Effect.runPromise(savedPreference(native(), key));
      if (value === 'downloads' && !remembered.has(key)) {
        publish(key);
      }
    })();
  }, [key]);
  return useMemo(
    () =>
      key === undefined
        ? undefined
        : {
            remembered: saves,
            remember: () => {
              if (!remembered.has(key)) {
                publish(key);
                void Effect.runPromise(
                  savePreference(native(), key, 'downloads'),
                );
              }
            },
          },
    [key, saves],
  );
}
