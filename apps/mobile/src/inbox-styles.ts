import {
  ipadListScale,
  radius,
  spacing,
  typography,
} from '@private-email/mail-core/theme';
import { Platform, StyleSheet } from 'react-native';

import { textStyles } from './theme.ts';

export const ipad = Platform.OS === 'ios' && Platform.isPad;
export const emptySymbolSize = ipad ? 36 * ipadListScale : 45;
const scale = ipad ? ipadListScale : 1;
const body = ipad ? typography.ipadList.body : textStyles.subheadline;
const subheadline = ipad
  ? typography.ipadList.subheadline
  : textStyles.subheadline;

// iPad keeps the scaled Mac list recipe in both orientations; iPhone uses its touch layout.
export const styles = StyleSheet.create({
  fill: { flex: 1 },
  heading: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.s,
    paddingHorizontal: ipad ? 14 * scale : spacing.l,
    paddingTop: ipad ? 10 * scale : spacing.xs,
    paddingBottom: ipad ? 10 * scale : spacing.m,
  },
  headingText: { flex: 1, alignItems: ipad ? 'flex-start' : 'center' },
  // iPad's command input takes its own row above the heading, as the frames place it, so the
  // heading's top padding is the gap beneath it.
  commands: {
    alignSelf: 'flex-start',
    marginLeft: 14 * scale,
    marginTop: spacing.l * scale,
  },
  title: {
    ...(ipad ? typography.ipadList.title3Emphasized : textStyles.headline),
  },
  subtitle: {
    flexDirection: 'row',
    justifyContent: ipad ? 'flex-start' : 'center',
  },
  subtitleText: {
    ...(ipad ? typography.ipadList.subheadline : textStyles.caption1),
    flexShrink: 1,
  },
  // Search's scope: two equal pill segments, the chosen one in the selected chip's graphite.
  segments: {
    flexDirection: 'row',
    gap: spacing.xs,
    marginHorizontal: spacing.l,
    marginTop: spacing.xs,
    marginBottom: spacing.s,
    padding: 2,
    // Pills are fully rounded.
    borderRadius: 20,
    borderCurve: 'continuous',
  },
  segment: {
    flex: 1,
    minHeight: 36,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.m,
    borderRadius: 18,
  },
  segmentLabel: {
    ...(ipad ? typography.ipadList.subheadline : textStyles.subheadline),
  },
  resultsHeader: {
    ...(ipad ? typography.ipadList.subheadline : textStyles.footnote),
    fontWeight: '600',
    paddingTop: spacing.s,
    paddingBottom: spacing.xs,
    paddingHorizontal: spacing.xs,
  },
  // Rows scroll under the floating bar.
  list: {
    paddingHorizontal: ipad ? 6 * scale : spacing.l,
    paddingBottom: 72,
    flexGrow: 1,
  },
  listFooter: { flexGrow: 1 },
  // The 2pt focus ring sits inside the design's 10/12/18pt row insets.
  row: {
    paddingTop: ipad ? 8 * scale - 2 : 8,
    paddingBottom: ipad ? 9 * scale - 2 : 10,
    paddingLeft: ipad ? 22 * scale - 2 : 16,
    paddingRight: ipad ? spacing.m * scale - 2 : 0,
    gap: ipad ? scale : 2,
    borderWidth: 2,
    borderRadius: radius.row * scale,
    borderCurve: 'continuous',
  },
  separator: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: StyleSheet.hairlineWidth,
  },
  rowHeading: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: ipad ? 4 * scale : 6,
  },
  sender: { ...(ipad ? body : textStyles.headline), flex: 1 },
  date: { ...subheadline, flexShrink: 1 },
  subject: { ...body },
  // A search's matched words.
  match: { fontWeight: '600' },
  unread: {
    position: 'absolute',
    left: ipad ? 8 * scale - 2 : 0,
    top: ipad ? 13 * scale - 2 : 15,
    width: ipad ? 8 * scale : 9,
    height: ipad ? 8 * scale : 9,
    borderRadius: ipad ? 4 * scale : 4.5,
  },
  preview: { ...body },
  divider: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10 * scale,
    paddingTop: ipad ? 14 * scale : spacing.l,
    paddingBottom: ipad ? spacing.s * scale : 10,
    paddingHorizontal: ipad ? 10 * scale : spacing.xs,
  },
  dividerLine: { flex: 1, height: StyleSheet.hairlineWidth },
  dividerLabel: {
    ...(ipad ? typography.ipadList.subheadline : textStyles.footnote),
    fontWeight: '600',
  },
  skeleton: {
    gap: ipad ? spacing.s * scale : 9,
    paddingTop: ipad ? spacing.m * scale : 14,
    paddingBottom: ipad ? 14 * scale : spacing.l,
    paddingLeft: ipad ? 22 * scale : 18,
    paddingRight: ipad ? spacing.m * scale : 0,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  skeletonBar: {
    height: ipad ? 9 * scale : 11,
    borderRadius: ipad ? 4.5 * scale : 5.5,
  },
  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6 * scale,
    paddingHorizontal: spacing.xl,
  },
  emptyIcon: { marginBottom: ipad ? spacing.m * scale : 14 },
  emptyTitle: {
    ...(ipad
      ? typography.ipadList.title3Emphasized
      : textStyles.title3Emphasized),
  },
  emptyText: { ...body, textAlign: 'center' },
  notices: { gap: spacing.s, paddingHorizontal: spacing.l },
  footer: { ...textStyles.footnote, padding: spacing.xl },
  notice: { ...textStyles.body, padding: spacing.xl },
  mailbox: { ...textStyles.footnote },
});
