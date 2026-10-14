import { radius, spacing } from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

import { textStyles } from './theme.ts';

// The Mac list: a 340pt column with a left-aligned title, 6pt row margins and 13pt rows under
// centered day dividers.
export const styles = StyleSheet.create({
  fill: { flex: 1 },
  headingRow: { flexDirection: 'row', alignItems: 'flex-start' },
  heading: {
    flex: 1,
    gap: 1,
    paddingHorizontal: 14,
    paddingTop: spacing.l,
    paddingBottom: 10,
  },
  title: { ...textStyles.title3Emphasized },
  subtitle: { flexDirection: 'row' },
  subtitleText: { ...textStyles.subheadline, flexShrink: 1 },
  // Rows scroll under the floating bar.
  list: {
    paddingHorizontal: 6,
    paddingBottom: 56,
    flexGrow: 1,
  },
  listFooter: { flexGrow: 1 },
  // The 2pt focus ring sits inside the design's 8/9/22/12pt row insets.
  row: {
    paddingTop: 6,
    paddingBottom: 7,
    paddingLeft: 20,
    paddingRight: 10,
    gap: 1,
    borderWidth: 2,
    borderRadius: radius.row,
    borderCurve: 'continuous',
  },
  separator: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: StyleSheet.hairlineWidth,
  },
  rowHeading: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  sender: { ...textStyles.body, flex: 1 },
  date: { ...textStyles.subheadline, flexShrink: 1 },
  subject: { ...textStyles.body },
  unread: {
    position: 'absolute',
    left: 6,
    top: 11,
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  preview: { ...textStyles.body },
  divider: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingTop: 14,
    paddingBottom: spacing.s,
    paddingHorizontal: 10,
  },
  dividerLine: { flex: 1, height: StyleSheet.hairlineWidth },
  dividerLabel: { ...textStyles.subheadline, fontWeight: '600' },
  skeleton: {
    gap: spacing.s,
    paddingTop: spacing.m,
    paddingBottom: 14,
    paddingLeft: 22,
    paddingRight: spacing.m,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  skeletonBar: { height: 9, borderRadius: 4.5 },
  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    paddingHorizontal: spacing.xl,
  },
  emptyIcon: { marginBottom: spacing.m },
  emptyTitle: { ...textStyles.title3Emphasized },
  emptyText: { ...textStyles.body, textAlign: 'center' },
  notices: { gap: spacing.s, paddingHorizontal: 14 },
  footer: { ...textStyles.subheadline, padding: spacing.xl },
  notice: { ...textStyles.body, padding: spacing.xl },
  mailbox: { ...textStyles.subheadline },
});
