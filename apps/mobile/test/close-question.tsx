import type { ReactNode } from 'react';

import { Pressable, Text, View } from 'react-native';

type Answer = 'delete' | 'save' | 'cancel';

// The system action sheet Close asks in, as its answers' buttons beside Close while it is open.
export function NativeCloseQuestion({
  open,
  deleteLabel,
  saveLabel,
  cancelLabel,
  onAnswer,
  children,
}: {
  readonly open: boolean;
  readonly deleteLabel: string;
  readonly saveLabel: string;
  readonly cancelLabel: string;
  readonly onAnswer: (event: { nativeEvent: { answer: Answer } }) => void;
  readonly children: ReactNode;
}) {
  const answers: ReadonlyArray<readonly [Answer, string]> = [
    ['delete', deleteLabel],
    ['save', saveLabel],
    ['cancel', cancelLabel],
  ];
  return (
    <View>
      {children}
      {open
        ? answers.map(([answer, label]) => (
            <Pressable
              key={answer}
              accessibilityRole="button"
              onPress={() => {
                onAnswer({ nativeEvent: { answer } });
              }}>
              <Text>{label}</Text>
            </Pressable>
          ))
        : null}
    </View>
  );
}
