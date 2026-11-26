import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { StyleSheet } from 'react-native';

import { textStyles } from './theme.ts';

export const styles = StyleSheet.create({
  assistance: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.xl },
  // The reader's content gap already separates the body from the message header.
  body: { gap: spacing.l },
  paragraph: { ...textStyles.reading.body },
  secondary: { ...textStyles.subheadline },
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
  attachmentName: { ...textStyles.subheadlineEmphasized },
  link: { textDecorationLine: 'underline' },
  linkControl: {
    borderRadius: radius.control,
    minHeight: 44,
    justifyContent: 'center',
    paddingHorizontal: 10,
  },
  rich: { width: '100%' },
  hidden: { opacity: 0 },
  fill: { flex: 1 },
  // The iPhone frame centres the indicator above its caption in the reader's empty space.
  loading: {
    flexGrow: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.xl + spacing.xs,
    paddingVertical: 2 * spacing.xl,
  },
  // The iPad frame: the caption, then still lines where the text will appear.
  downloading: { gap: 14 * ipadListScale },
  caption: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  captionText: { ...typography.ipadList.subheadline },
  placeholders: { gap: 13.3 },
  placeholder: { height: 12, borderRadius: 6 },
  // The Schedule Banner recipe, which the iPad frame draws at 1.15×.
  // The iPhone frames draw it 8pt from the screen's edges, wider than the reader's 24pt column.
  banner: {
    marginHorizontal: spacing.s - spacing.xxl,
    alignItems: 'flex-start',
    gap: spacing.xs,
    padding: spacing.m,
    borderRadius: radius.card,
    borderCurve: 'continuous',
  },
  padBanner: {
    alignItems: 'flex-start',
    gap: spacing.xs * ipadListScale,
    padding: spacing.m * ipadListScale,
    borderRadius: radius.card * ipadListScale,
    borderCurve: 'continuous',
  },
  // A banner's buttons, 8pt apart; their 44pt touch targets reach into its padding, so the
  // capsules keep the frame's rhythm.
  bannerActions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.s,
    marginVertical: -(44 - 28) / 2,
  },
  padBannerActions: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: spacing.s * ipadListScale,
    marginVertical: -(44 - 28 * ipadListScale) / 2,
  },
  // A system alert's anchor takes no room in the banner.
  alertAnchor: { position: 'absolute' },
  marker: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  bannerTitle: { ...textStyles.footnote, fontWeight: '500' },
  bannerText: { ...textStyles.footnote },
  padBannerTitle: { ...typography.ipadList.body, fontWeight: '500' },
  padBannerText: { ...typography.ipadList.body },
});
