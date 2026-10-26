import { act, screen } from '@testing-library/react-native';
import * as Predicate from 'effect/Predicate';

interface TargetMenu {
  readonly sections: ReadonlyArray<{
    readonly items: ReadonlyArray<{
      readonly id: string;
      readonly title: string;
    }>;
  }>;
  readonly onSelect: (event: { nativeEvent: { id: string } }) => void;
}

// Rendered host props are untyped; the native menu button always carries both.
const isTargetMenu = (props: unknown): props is TargetMenu =>
  Predicate.hasProperty(props, 'sections') &&
  Predicate.hasProperty(props, 'onSelect');

// The rendered target-language menu's choice of one language, delivered as the system menu does.
// Retaining it models a choice that arrives after its panel changed.
export const targetChoice = async (language: string) => {
  const menu = await screen.findByLabelText('Translate into');
  const props: unknown = menu.props;
  if (!isTargetMenu(props)) {
    throw new Error('Expected the target-language menu');
  }
  const item = props.sections
    .flatMap(({ items }) => items)
    .find(({ title }) => title === language);
  if (item === undefined) {
    throw new Error(`Expected ${language} in the target-language menu`);
  }
  const { onSelect } = props;
  return () => {
    onSelect({ nativeEvent: { id: item.id } });
  };
};

export const translateInto = async (language: string) => {
  const choose = await targetChoice(language);
  await act(() => {
    choose();
  });
};
