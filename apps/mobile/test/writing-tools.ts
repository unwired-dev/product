import { act, screen } from '@testing-library/react-native';
import * as Predicate from 'effect/Predicate';

interface WritingToolsMenu {
  readonly sections: ReadonlyArray<{
    readonly items: ReadonlyArray<{
      readonly id: string;
      readonly title: string;
      readonly symbol: string;
      readonly accessibilityLabel?: string;
      readonly disabled?: boolean;
    }>;
  }>;
  readonly onSelect: (event: {
    readonly nativeEvent: { readonly id: string };
  }) => void;
}

// Rendered host props are untyped; the native menu button always carries both.
const isMenu = (props: unknown): props is WritingToolsMenu =>
  Predicate.hasProperty(props, 'sections') &&
  Predicate.hasProperty(props, 'onSelect');

const menu = (label = 'Writing tools') => {
  const props: unknown = screen.queryByLabelText(label)?.props;
  return isMenu(props) ? props : undefined;
};

// A native menu's groups, in order, as each item's title, symbol and whether it is disabled.
export const menuGroups = (label = 'Writing tools') =>
  menu(label)?.sections.map(({ items }) =>
    items.map(({ title, symbol, disabled }) => [title, symbol, disabled]),
  );

export const writingToolGroups = () => menuGroups();

// The composer's Writing tools item with this spoken name, if the menu offers it now.
export const writingTool = (name: string) =>
  menu()
    ?.sections.flatMap(({ items }) => items)
    .find(({ accessibilityLabel }) => accessibilityLabel === name);

// The item's choice, delivered as the system menu does. Retaining it models a choice that arrives
// after the composer changed.
export const writingToolChoice = (name: string) => {
  const item = writingTool(name);
  const onSelect = menu()?.onSelect;
  if (item === undefined || onSelect === undefined) {
    throw new Error(`Expected ${name} in Writing tools`);
  }
  if (item.disabled === true) {
    throw new Error(`Expected ${name} to be enabled`);
  }
  return () => {
    onSelect({ nativeEvent: { id: item.id } });
  };
};

export const chooseWritingTool = async (name: string) => {
  await screen.findByLabelText('Writing tools');
  const choose = writingToolChoice(name);
  await act(async () => {
    choose();
  });
};

// The iPhone Add files menu's item with this title, chosen as the system menu does, if it offers one.
export const addFilesChoice = (title: string) => {
  const files = menu('Add files');
  const item = files?.sections
    .flatMap(({ items }) => items)
    .find((candidate) => candidate.title === title);
  return files === undefined || item === undefined
    ? undefined
    : () => {
        files.onSelect({ nativeEvent: { id: item.id } });
      };
};
