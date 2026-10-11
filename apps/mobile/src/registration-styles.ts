import { StyleSheet } from 'react-native';

export const registrationStyles = StyleSheet.create({
  page: { flex: 1 },
  scroll: {
    flexGrow: 1,
    justifyContent: 'center',
    alignItems: 'center',
    padding: 32,
  },
  content: { maxWidth: 420, width: '100%', gap: 20 },
  title: { fontSize: 28, fontWeight: '600' },
  heading: { fontSize: 20, fontWeight: '600' },
  text: { fontSize: 17, lineHeight: 25 },
  button: {
    padding: 16,
    borderWidth: 1,
    borderRadius: 12,
    borderCurve: 'continuous',
  },
  recoveryKey: {
    fontSize: 19,
    lineHeight: 30,
    fontFamily: 'Menlo',
    fontVariant: ['tabular-nums'],
  },
  input: {
    fontSize: 17,
    padding: 12,
    borderWidth: 1,
    borderRadius: 10,
    borderCurve: 'continuous',
  },
  device: { gap: 8 },
});
