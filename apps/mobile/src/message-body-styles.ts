import { spacing } from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

export const styles = StyleSheet.create({
  body: { gap: spacing.medium, marginTop: spacing.large },
  paragraph: { fontSize: 17, lineHeight: 28 },
  secondary: { fontSize: 14, lineHeight: 21 },
  confirm: {
    gap: spacing.small,
    padding: spacing.medium,
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
  },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.large },
  attachments: {
    gap: spacing.small,
    paddingTop: spacing.medium,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  attachment: { gap: 2 },
  attachmentName: { fontSize: 15, fontWeight: '600' },
  link: { textDecorationLine: 'underline' },
  linkControl: {
    borderWidth: 2,
    borderRadius: 4,
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: spacing.small,
  },
  notice: { gap: spacing.small },
  rich: { width: '100%', backgroundColor: '#FFFFFF' },
  hidden: { opacity: 0 },
  fill: { flex: 1 },
  bar: {
    paddingHorizontal: spacing.large,
    paddingVertical: spacing.medium,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
});
