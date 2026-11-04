import { radius, spacing } from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

import { textStyles } from './theme.ts';

export const styles = StyleSheet.create({
  assistance: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xl },
  // The reader's content gap already separates the body from the message header.
  body: { gap: spacing.l },
  paragraph: { ...textStyles.reading.body },
  secondary: { ...textStyles.body },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xl },
  attachments: {
    gap: spacing.s,
    paddingTop: spacing.l,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  attachmentList: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  attachment: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.s,
    maxWidth: '100%',
    paddingHorizontal: spacing.m,
    paddingVertical: spacing.s,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  attachmentText: { flexShrink: 1, gap: 2 },
  attachmentName: { ...textStyles.bodyEmphasized },
  link: { textDecorationLine: 'underline' },
  linkControl: {
    borderWidth: 2,
    borderRadius: radius.control,
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.s,
  },
  rich: { width: '100%' },
  hidden: { opacity: 0 },
  fill: { flex: 1 },
});
