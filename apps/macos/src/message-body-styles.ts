import { radius, spacing } from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

import { textStyles } from './theme.ts';

export const styles = StyleSheet.create({
  assistance: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xl },
  body: { gap: spacing.l, marginTop: spacing.xl },
  paragraph: { ...textStyles.reading.body },
  secondary: { ...textStyles.body },
  confirm: {
    gap: spacing.s,
    padding: spacing.l,
    borderRadius: radius.card,
    borderWidth: StyleSheet.hairlineWidth,
  },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xl },
  attachments: {
    gap: spacing.s,
    paddingTop: spacing.l,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  attachment: { gap: 2 },
  attachmentName: { ...textStyles.bodyEmphasized },
  link: { textDecorationLine: 'underline' },
  linkControl: {
    borderWidth: 2,
    borderRadius: radius.control,
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.s,
  },
  rich: { width: '100%', backgroundColor: '#FFFFFF' },
  hidden: { opacity: 0 },
  fill: { flex: 1 },
  bar: {
    paddingHorizontal: spacing.xl,
    paddingVertical: spacing.l,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
});
