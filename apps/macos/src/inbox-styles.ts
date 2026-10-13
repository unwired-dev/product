import { radius, spacing } from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

import { textStyles } from './theme.ts';

export const styles = StyleSheet.create({
  fill: { flex: 1 },
  headingRow: { flexDirection: 'row', alignItems: 'flex-start' },
  heading: { flex: 1, padding: spacing.xl, paddingBottom: spacing.l },
  title: { ...textStyles.title3Emphasized },
  subtitle: { ...textStyles.subheadline, marginTop: 4 },
  // Rows scroll under the floating bar.
  list: { paddingHorizontal: spacing.s, paddingBottom: 56, gap: 4 },
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
  sender: { ...textStyles.bodyEmphasized, flex: 1 },
  date: { ...textStyles.subheadline },
  subjectLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 5,
  },
  subject: { ...textStyles.body, flex: 1 },
  unread: { width: 6, height: 6, borderRadius: 3 },
  preview: { ...textStyles.body, marginTop: 5 },
  footer: { ...textStyles.subheadline, padding: spacing.xl },
  notice: { ...textStyles.body, padding: spacing.xl },
  mailbox: { ...textStyles.subheadline, marginTop: 5 },
});
