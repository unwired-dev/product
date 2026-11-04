import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
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
  // iPad presents account setup as the frames' centred glass sheet over the dimmed window.
  padSheet: {
    width: 575,
    maxWidth: '100%',
    gap: spacing.l * ipadListScale,
    paddingTop: 28 * ipadListScale,
    paddingHorizontal: 28 * ipadListScale,
    paddingBottom: 24 * ipadListScale,
    borderRadius: radius.ipadSheet,
    borderCurve: 'continuous',
  },
  padSheetTitle: {
    fontSize: 17 * ipadListScale,
    lineHeight: 22 * ipadListScale,
  },
  padSheetText: { ...typography.ipadList.body },
  // The Settings page's fixed title row.
  accountHeader: {
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.m,
  },
  // The iPad frames center the title and command input 29.5pt below the status bar and start the
  // cards, whose edges they share, 64pt below it.
  padAccountHeader: {
    paddingLeft: 28,
    paddingRight: 32,
    paddingTop: 29.5 - 22,
    paddingBottom: 64 - 29.5 - 22 - spacing.s,
  },
  accountHeading: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.m,
    minHeight: 44,
  },
  // A 44pt control, the 20pt native busy indicator and its spacing balance both sides.
  phoneHeaderSlot: {
    width: 44 + 20 + spacing.s,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
  },
  phoneAccessory: { justifyContent: 'flex-end' },
  // The iPad Settings frames draw the command input 300pt wide.
  accountCommands: { width: 300 },
  padTitle: { ...typography.ipadList.title3Emphasized },
  centered: { textAlign: 'center' },
  grow: { flex: 1 },
  title: { ...textStyles.largeTitle },
  heading: { ...textStyles.headline },
  text: { ...textStyles.body },
  removalText: { ...textStyles.footnote },
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
    textAlign: 'center',
    padding: 16,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  // iPhone's brand Recovery Key well, as its frame draws it.
  brandRecoveryKey: {
    fontSize: 22,
    lineHeight: 28,
    fontWeight: '500',
    fontFamily: 'System',
    letterSpacing: 1.76,
    textAlign: 'left',
    paddingHorizontal: 20,
    paddingVertical: 18,
    borderWidth: 1,
    borderRadius: 20,
  },
  // A device approval code, large enough to compare at a glance with the other device.
  code: {
    fontSize: 28,
    lineHeight: 34,
    fontWeight: '600',
    fontFamily: 'Menlo',
    fontVariant: ['tabular-nums'],
    letterSpacing: 2,
    textAlign: 'center',
    padding: 12,
    borderRadius: radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  input: {
    ...textStyles.body,
    padding: 12,
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  device: { gap: 8 },
  // A warning beside its message, or a pending action after its busy indicator.
  inline: { flexDirection: 'row', alignItems: 'center', gap: spacing.s },
});
