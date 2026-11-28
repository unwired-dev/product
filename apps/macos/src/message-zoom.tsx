import type { Dispatch, ReactNode, SetStateAction } from 'react';

import { messageZooms } from '@private-email/mail-core/message-body';
import { spacing } from '@private-email/mail-core/theme';
import { createContext, use, useEffect, useRef, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import type { PopUpItem } from './composer-controls.tsx';

import { useMenuCommand } from './command-palette.tsx';
import { Button, Popover } from './design.tsx';
import { Label } from './label.tsx';
import { useLocalization } from './localization.ts';
import { Row } from './new-label.tsx';
import { setMessageZoom, useMessageZoom } from './reading.ts';
import { textStyles, usePalette } from './theme.ts';

// Zooming one message, the Mac M2 frame: a 300pt panel with a 20pt inset and 10pt rhythm.
const styles = StyleSheet.create({
  panel: { width: 300, gap: 10, padding: 20 },
  group: { borderRadius: 10, borderCurve: 'continuous', overflow: 'hidden' },
  line: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  buttons: { alignItems: 'flex-end', paddingTop: spacing.xs },
});

// The Message zoom levels, as the reader's setting holds them.
const levels: readonly number[] = messageZooms;
type Zoom = number;
type Own = Readonly<{ id: string; zoom: Zoom }> | undefined;

// The open message's own zoom, kept until it closes, and whether the reader shows formatted mail,
// the only kind a zoom changes.
const OneMessageZoom = createContext<
  | Readonly<{
      id: string;
      own: Own;
      setOwn: Dispatch<SetStateAction<Own>>;
      formatted: boolean;
      setFormatted: (formatted: boolean) => void;
    }>
  | undefined
>(undefined);

// Holds the zoom of message `id` for a reader. Opening another message drops it, so that message
// opens at the stored Message zoom.
export function MessageZoomScope({
  id,
  children,
}: {
  readonly id: string;
  readonly children: ReactNode;
}) {
  const [own, setOwn] = useState<Own>();
  const [formatted, setFormatted] = useState(false);
  if (own !== undefined && own.id !== id) {
    setOwn(undefined);
  }
  return (
    <OneMessageZoom value={{ id, own, setOwn, formatted, setFormatted }}>
      <Keys />
      {children}
    </OneMessageZoom>
  );
}

// The zoom the reader draws: the message's own, otherwise the stored Message zoom.
export function useShownZoom() {
  const stored = useMessageZoom();
  const reader = use(OneMessageZoom);
  return reader?.own?.zoom ?? stored;
}

// Tells the reader's zoom control that formatted mail is shown, while `shown`.
export function useShowsFormatted(shown: boolean) {
  const setFormatted = use(OneMessageZoom)?.setFormatted;
  useEffect(() => {
    if (!shown || setFormatted === undefined) {
      return undefined;
    }
    setFormatted(true);
    return () => {
      setFormatted(false);
    };
  }, [shown, setFormatted]);
}

// The zoom steps: to a neighbouring Message zoom level, stopping at 50% and 300%, or to 100%.
const steps = (zoom: Zoom) => ({
  in: levels[levels.indexOf(zoom) + 1],
  out: levels[levels.indexOf(zoom) - 1],
  actual: 100,
});

// View › Zoom In (Command-+), Zoom Out (Command-−) and Actual Size (Command-0) zoom the open message.
function Keys() {
  const reader = use(OneMessageZoom);
  const zoom = useShownZoom();
  useMenuCommand('zoom', (direction) => {
    const to =
      direction === 'in' || direction === 'out' || direction === 'actual'
        ? steps(zoom)[direction]
        : undefined;
    if (reader?.formatted === true && to !== undefined) {
      reader.setOwn({ id: reader.id, zoom: to });
    }
  });
  return null;
}

// More's Message Zoom…, dimmed while the message is not formatted mail, and the panel it opens
// below More: the message's zoom, Zoom In, Zoom Out, Actual Size and Use … for All Messages.
export function useZoomMenu(): {
  readonly items: readonly PopUpItem[];
  readonly panel: ReactNode;
} {
  const { t } = useLocalization();
  const colors = usePalette();
  const reader = use(OneMessageZoom);
  const zoom = useShownZoom();
  const stored = useMessageZoom();
  // Each opening is its own popover, so the last one's close, arriving late, cannot close it.
  const [opening, setOpening] = useState<number>();
  const counted = useRef(0);
  if (reader === undefined) {
    return { items: [], panel: null };
  }
  const to = steps(zoom);
  const choose = (next: Zoom | undefined) => {
    if (next !== undefined) {
      reader.setOwn({ id: reader.id, zoom: next });
    }
  };
  const row = (
    [label, key]: readonly [string, string],
    next: Zoom | undefined,
    first = false,
  ) => (
    <Row
      label={label}
      separated={!first}
      disabled={next === undefined || next === zoom}
      onPress={() => {
        choose(next);
      }}>
      <View style={styles.line}>
        <Text style={[textStyles.body, { color: colors.textPrimary }]}>
          {label}
        </Text>
        <Text style={[textStyles.body, { color: colors.textSecondary }]}>
          {key}
        </Text>
      </View>
    </Row>
  );
  return {
    items: [
      {
        key: `${reader.id}\nzoom`,
        title: t('reading.zoomMenu'),
        subtitle: t('reading.percent', { value: zoom }),
        symbol: 'plus.magnifyingglass',
        disabled: !reader.formatted,
        run: () => {
          counted.current += 1;
          setOpening(counted.current);
        },
      },
    ],
    panel: (
      <Popover
        key={opening}
        below
        title={t('reading.zoomMenu')}
        shown={opening !== undefined && reader.formatted}
        onClose={() => {
          setOpening(undefined);
        }}>
        <View style={styles.panel}>
          <Label
            accessibilityRole="header"
            style={[
              textStyles.title3Emphasized,
              { color: colors.textPrimary },
            ]}>
            {t('reading.zoomTitle', { value: zoom })}
          </Label>
          <Label
            style={[textStyles.subheadline, { color: colors.textSecondary }]}>
            {t('reading.zoomResets')}
          </Label>
          <View style={[styles.group, { backgroundColor: colors.fillQuiet }]}>
            {row([t('reading.zoomIn'), '⌘+'], to.in, true)}
            {row([t('reading.zoomOut'), '⌘−'], to.out)}
            {row([t('reading.actualSize'), '⌘0'], to.actual)}
          </View>
          <View style={styles.buttons}>
            <Button
              label={t('reading.zoomAll', { value: zoom })}
              disabled={zoom === stored}
              onPress={() => {
                setMessageZoom(zoom);
              }}
            />
          </View>
        </View>
      </Popover>
    ),
  };
}
