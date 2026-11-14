import { ok } from 'node:assert/strict';

import { act, screen } from '@testing-library/react-native';
import * as Predicate from 'effect/Predicate';

interface SystemMenu {
  readonly sections: ReadonlyArray<{
    readonly items: ReadonlyArray<{
      readonly id: string;
      readonly title: string;
      readonly accessibilityLabel?: string;
      readonly checked?: boolean;
    }>;
  }>;
  readonly onSelect: (event: { nativeEvent: { id: string } }) => void;
}

// Rendered host props are untyped; the native menu button always carries both.
const isSystemMenu = (props: unknown): props is SystemMenu =>
  Predicate.hasProperty(props, 'sections') &&
  Predicate.hasProperty(props, 'onSelect');

// The screen, or the part of it, holding the button.
type Scope = Pick<typeof screen, 'getByRole'>;

const menuOf = (button: string, scope: Scope) => {
  const props: unknown = scope.getByRole('button', { name: button }).props;
  ok(isSystemMenu(props));
  return props;
};

// The items of the system menu a button opens, as its native button receives them.
export const systemMenu = (button: string, scope: Scope = screen) =>
  menuOf(button, scope).sections.flatMap(({ items }) => items);

// Chooses an item, by its spoken name, from the menu as it is now, when the returned call runs.
export const queuedChoice = (
  button: string,
  item: string,
  scope: Scope = screen,
) => {
  const { onSelect } = menuOf(button, scope);
  const { id } =
    systemMenu(button, scope).find(
      ({ title, accessibilityLabel }) => (accessibilityLabel ?? title) === item,
    ) ?? {};
  ok(id !== undefined, `Expected ${item} in the ${button} menu`);
  return () => {
    onSelect({ nativeEvent: { id } });
  };
};

export const choose = async (
  button: string,
  item: string,
  scope: Scope = screen,
) => {
  const select = queuedChoice(button, item, scope);
  await act(async () => {
    select();
  });
};
