import type { AlertButton, AlertType } from 'react-native';

// React Native macOS implements this public API but omits its TypeScript declaration.
declare module 'react-native' {
  interface AlertStatic {
    promptMacOS: (
      ...args: readonly [
        title: string,
        message?: string,
        callbackOrButtons?:
          | ((text: string) => void)
          | ReadonlyArray<Readonly<AlertButton>>,
        type?: AlertType,
        defaultInputs?: ReadonlyArray<
          Readonly<{
            default?: string;
            placeholder?: string;
          }>
        >,
        modal?: boolean,
        critical?: boolean,
      ]
    ) => void;
  }
}
