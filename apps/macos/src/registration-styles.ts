import { radius } from '@private-email/mail-core/theme';
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
  title: { ...textStyles.largeTitle },
  heading: { ...textStyles.title3Emphasized },
  text: { ...textStyles.body },
  button: {
    padding: 16,
    borderWidth: 1,
    borderRadius: radius.control,
    borderCurve: 'continuous',
  },
  recoveryKey: {
    ...textStyles.reading.body,
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
