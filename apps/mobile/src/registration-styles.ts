import { radius, spacing, typography } from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

import { textStyles } from './theme.ts';

export const registrationStyles = StyleSheet.create({
  page: { flex: 1 },
  scroll: {
    flexGrow: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 32,
  },
  content: { maxWidth: 420, width: '100%', gap: 20 },
  // The Settings page's fixed title row.
  accountHeader: {
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.m,
  },
  accountHeading: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 44,
  },
  back: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 22,
  },
  // A 44pt control, the 20pt native busy indicator and its spacing balance both sides.
  phoneHeaderSlot: {
    width: 44 + 20 + spacing.s,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
  },
  phoneAccessory: { justifyContent: 'flex-end' },
  padTitle: { ...typography.ipadList.title3Emphasized },
  centered: { textAlign: 'center' },
  grow: { flex: 1 },
  title: { ...textStyles.largeTitle },
  heading: { ...textStyles.headline },
  text: { ...textStyles.body },
  button: {
    padding: 16,
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  recoveryKey: {
    ...textStyles.body,
    fontFamily: 'Menlo',
    fontVariant: ['tabular-nums'],
  },
  input: {
    ...textStyles.body,
    padding: 12,
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  device: { gap: 8 },
});
