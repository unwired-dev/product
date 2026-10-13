import { radius, spacing } from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

import { textStyles } from './theme.ts';

export const styles = StyleSheet.create({
  fill: { flex: 1 },
  heading: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    padding: spacing.xl,
    paddingBottom: spacing.l,
  },
  headingText: { flex: 1 },
  title: { ...textStyles.largeTitle },
  subtitle: { ...textStyles.subheadline, marginTop: 4 },
  // Rows scroll under the floating bar.
  list: { paddingHorizontal: spacing.s, paddingBottom: 72, gap: 4 },
  row: {
    minHeight: 116,
    padding: 14,
    borderWidth: 2,
    borderRadius: radius.row,
    borderCurve: 'continuous',
  },
  rowHeading: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: spacing.s,
  },
  sender: { ...textStyles.headline, flex: 1 },
  date: { ...textStyles.footnote },
  subjectLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 5,
  },
  subject: { ...textStyles.subheadline, flex: 1 },
  unread: { width: 6, height: 6, borderRadius: 3 },
  preview: { ...textStyles.subheadline, marginTop: 5 },
  footer: { ...textStyles.footnote, padding: spacing.xl },
  notice: { ...textStyles.body, padding: spacing.xl },
  mailbox: { ...textStyles.footnote, marginTop: 5 },
});
