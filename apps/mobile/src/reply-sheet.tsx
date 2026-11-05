import type { ResponseKind } from '@private-email/mail-core/responses';

import { BottomSheet, Group, Host, RNHostView } from '@expo/ui/swift-ui';
import {
  presentationBackground,
  presentationDetents,
} from '@expo/ui/swift-ui/modifiers';
import { radius, spacing } from '@private-email/mail-core/theme';
import {
  createContext,
  Fragment,
  use,
  useLayoutEffect,
  useRef,
  useState,
} from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  useWindowDimensions,
  View,
} from 'react-native';

import { GlassGroup, Monogram, SFSymbol } from './design.tsx';
import { useLocalization } from './localization.ts';
import { textStyles, useAppearance, usePalette } from './theme.ts';

// One of the Thread's organizing actions, as the iPhone Reply sheet lists it: Archive joins the
// response tiles; the rest are rows grouped by what they change.
export type ThreadAction = Readonly<{
  name: string;
  label: string;
  icon: string;
  group: 'tile' | 'state' | 'place';
  run: () => void;
}>;

// The reader toolbar offers its organizing actions to the iPhone Reply sheet, and leaves out More
// while the sheet is offered.
export const ThreadActionsContext = createContext<
  | Readonly<{
      actions: readonly ThreadAction[];
      offered: (offered: boolean) => void;
    }>
  | undefined
>(undefined);
const responseIcons = {
  reply: 'arrowshape.turn.up.left.fill',
  replyAll: 'arrowshape.turn.up.left.2.fill',
  forward: 'arrowshape.turn.up.right.fill',
} as const;

// The frames' 19×16pt arrows, 23×16pt Reply All and 18×16pt Archive: each glyph's point size
// for that ink, and the icon frame it centres in. Reply All's frame is the taller one.
const tileIcons: Readonly<Record<string, { size: number; slot: number }>> = {
  [responseIcons.reply]: { size: 18.15, slot: 19.8375 },
  [responseIcons.replyAll]: { size: 17.9, slot: 22.1375 },
  [responseIcons.forward]: { size: 18.15, slot: 19.8375 },
  'archivebox.fill': { size: 18.3, slot: 19.8375 },
};
const tileIcon = { size: 18.15, slot: 19.8375 };

// The inset sheet's margin to the window edge.
const sheetMargin = 8;

const styles = StyleSheet.create({
  // The sheet's empty host sits beside Reply in the toolbar group without taking a gap.
  host: { position: 'absolute' },
  // The frames' 18pt insets, 14pt between the sheet's parts and 10pt between its tiles.
  replyContent: {
    gap: 14,
    paddingHorizontal: 18,
    paddingVertical: 18,
  },
  replyHeader: { flexDirection: 'row', alignItems: 'center', gap: spacing.m },
  replyFrom: { flex: 1, gap: 1 },
  replySender: { ...textStyles.headline },
  // Close is the frames' 44pt glass control, centred in the 48pt header.
  replyCloseGlass: {
    alignSelf: 'center',
    padding: 0,
    borderRadius: 22,
    backgroundColor: 'transparent',
  },
  replyClose: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  // Each tile hugs its icon frame and label, so Reply All's taller frame does not stretch the rest.
  replyTiles: { flexDirection: 'row', alignItems: 'flex-start', gap: 10 },
  replyTile: {
    flex: 1,
    gap: 6,
    paddingHorizontal: spacing.xs,
    paddingVertical: 14,
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
    alignItems: 'center',
  },
  replyIcon: { alignItems: 'center', justifyContent: 'center' },
  replyLabel: { ...textStyles.subheadline, textAlign: 'center' },
  actionGroup: {
    overflow: 'hidden',
    borderRadius: radius.insetGroup,
    borderCurve: 'continuous',
  },
  actionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 50,
    paddingHorizontal: 18,
    paddingVertical: 14,
    borderRadius: radius.insetGroup,
  },
  actionLabel: { ...textStyles.body, flex: 1 },
  // Hairlines span the group.
  actionSeparator: { height: StyleSheet.hairlineWidth },
  secondary: { ...textStyles.subheadline },
});

// Owns the Reply presentation while the reader owns response preparation.
export function ReplySheet({
  open,
  message,
  onResponse,
  onClose,
}: {
  readonly open: boolean;
  readonly message: Readonly<{ sender: string; subject: string }>;
  readonly onResponse: (kind: ResponseKind) => void;
  readonly onClose: () => void;
}) {
  const colors = usePalette();
  const appearance = useAppearance();
  const { t } = useLocalization();
  // iOS floats the sheet 8pt inside each edge of the iPhone window and draws its content scaled to
  // that width, so the content lays out at the drawn width and scales back up: the frames' sizes
  // are drawn as designed.
  const { width } = useWindowDimensions();
  const drawn = (width - 2 * sheetMargin) / width;
  // The sheet fits its content; taller content scrolls inside the tallest detent iOS allows.
  const [height, setHeight] = useState<number>();
  const pending = useRef<
    Readonly<{ message: typeof message; name: string }> | undefined
  >(undefined);
  const owner = useRef<typeof message | undefined>(undefined);
  useLayoutEffect(() => {
    owner.current = message;
    return () => {
      owner.current = undefined;
      pending.current = undefined;
    };
  }, [message]);
  const thread = use(ThreadActionsContext);
  const actions = thread?.actions ?? [];
  const offered = thread?.offered;
  useLayoutEffect(() => {
    if (offered === undefined) {
      return undefined;
    }
    offered(true);
    return () => {
      offered(false);
    };
  }, [offered]);
  const tiles = [
    ...(['reply', 'replyAll', 'forward'] as const).map((kind) => ({
      name: kind,
      label: t(`message.${kind}`),
      icon: responseIcons[kind],
      run: () => {
        onResponse(kind);
      },
    })),
    ...actions.filter(({ group }) => group === 'tile'),
  ];
  const groups = (['state', 'place'] as const)
    .map((group) => actions.filter((action) => action.group === group))
    .filter((group) => group.length > 0);
  const select = (name: string) => {
    if (!open || owner.current !== message || pending.current !== undefined) {
      return;
    }
    pending.current = { message, name };
    onClose();
  };
  return (
    <Host
      matchContents
      style={styles.host}>
      <BottomSheet
        isPresented={open}
        onIsPresentedChange={(presented) => {
          if (!presented) {
            onClose();
          }
        }}
        // A sibling Move sheet cannot present until the sheet finishes dismissing.
        onDismiss={() => {
          const selected = pending.current;
          pending.current = undefined;
          if (
            !open &&
            owner.current === message &&
            selected?.message === message
          ) {
            [...tiles, ...actions]
              .find(({ name }) => name === selected.name)
              ?.run();
          }
        }}>
        <Group
          modifiers={[
            presentationDetents(
              height === undefined ? ['medium'] : [{ height }],
            ),
            // The Dark frames draw the sheet as the glass panel surface; Light keeps the system's
            // sheet glass, which reads as the Light frames' #E8E8E8 over the dimmed reader.
            ...(appearance === 'dark'
              ? [presentationBackground(colors.surfacePanel)]
              : []),
          ]}>
          <RNHostView>
            <ScrollView>
              <View style={{ height }}>
                <View
                  onLayout={({ nativeEvent }) => {
                    setHeight(nativeEvent.layout.height / drawn);
                  }}
                  style={[
                    styles.replyContent,
                    {
                      width: `${drawn * 100}%`,
                      transformOrigin: 'top left',
                      transform: [{ scale: 1 / drawn }],
                    },
                  ]}>
                  <View style={styles.replyHeader}>
                    <Monogram
                      name={message.sender}
                      size={48}
                    />
                    <View style={styles.replyFrom}>
                      <Text
                        numberOfLines={1}
                        style={[
                          styles.replySender,
                          { color: colors.textPrimary },
                        ]}>
                        {message.sender}
                      </Text>
                      <Text
                        numberOfLines={1}
                        style={[
                          styles.secondary,
                          { color: colors.textSecondary },
                        ]}>
                        {message.subject}
                      </Text>
                    </View>
                    <GlassGroup style={styles.replyCloseGlass}>
                      <Pressable
                        accessibilityRole="button"
                        accessibilityLabel={t('message.closeResponses')}
                        onPress={onClose}
                        style={styles.replyClose}>
                        {/* The frames' 10×10pt cross. */}
                        <SFSymbol
                          name="xmark"
                          size={12.85}
                          color={colors.textPrimary}
                        />
                      </Pressable>
                    </GlassGroup>
                  </View>
                  <View style={styles.replyTiles}>
                    {tiles.map(({ name, label, icon }) => {
                      const { size, slot } = tileIcons[icon] ?? tileIcon;
                      return (
                        <Pressable
                          key={name}
                          accessibilityRole="button"
                          accessibilityLabel={label}
                          onPress={() => {
                            select(name);
                          }}
                          style={({ pressed }) => [
                            styles.replyTile,
                            {
                              backgroundColor: pressed
                                ? colors.accentSelectionSubtle
                                : colors.fillQuiet,
                            },
                          ]}>
                          <View style={[styles.replyIcon, { height: slot }]}>
                            <SFSymbol
                              name={icon}
                              size={size}
                              color={colors.textPrimary}
                            />
                          </View>
                          <Text
                            style={[
                              styles.replyLabel,
                              { color: colors.textPrimary },
                            ]}>
                            {label}
                          </Text>
                        </Pressable>
                      );
                    })}
                  </View>
                  {groups.map((group) => (
                    <View
                      key={group[0]?.group}
                      style={[
                        styles.actionGroup,
                        { backgroundColor: colors.fillQuiet },
                      ]}>
                      {group.map(({ name, label, icon }, index) => (
                        <Fragment key={name}>
                          {index === 0 ? null : (
                            <View
                              style={[
                                styles.actionSeparator,
                                { backgroundColor: colors.separator },
                              ]}
                            />
                          )}
                          <Pressable
                            accessibilityRole="button"
                            accessibilityLabel={label}
                            onPress={() => {
                              select(name);
                            }}
                            style={({ pressed }) => [
                              styles.actionRow,
                              {
                                backgroundColor: pressed
                                  ? colors.accentSelectionSubtle
                                  : 'transparent',
                              },
                            ]}>
                            <Text
                              style={[
                                styles.actionLabel,
                                { color: colors.textPrimary },
                              ]}>
                              {label}
                            </Text>
                            <SFSymbol
                              name={icon}
                              size={20}
                              color={colors.textPrimary}
                            />
                          </Pressable>
                        </Fragment>
                      ))}
                    </View>
                  ))}
                </View>
              </View>
            </ScrollView>
          </RNHostView>
        </Group>
      </BottomSheet>
    </Host>
  );
}
