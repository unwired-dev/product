import { ok } from 'node:assert/strict';

import { act, screen } from '@testing-library/react-native';
import * as Predicate from 'effect/Predicate';

interface SendMenu {
  readonly sections: ReadonlyArray<{
    readonly items: ReadonlyArray<{
      readonly id: string;
      readonly title: string;
      readonly subtitle?: string;
      readonly disabled?: boolean;
    }>;
  }>;
  readonly onSelect: (event: { nativeEvent: { id: string } }) => void;
}

// Rendered host props are untyped; the native context menu always carries both.
const isSendMenu = (props: unknown): props is SendMenu =>
  Predicate.hasProperty(props, 'sections') &&
  Predicate.hasProperty(props, 'onSelect');

// The item titled `title` in Send's menu, as a long press opens it, and choosing it.
export const sendMenuItem = (title: string) => {
  let menu = screen.getByRole('button', { name: 'Send' }).parent;
  while (menu !== null && menu.type !== 'UnwiredContextMenu') {
    menu = menu.parent;
  }
  const props: unknown = menu?.props;
  ok(isSendMenu(props));
  const item = props.sections
    .flatMap(({ items }) => items)
    .find((candidate) => candidate.title === title);
  ok(item !== undefined);
  const { onSelect } = props;
  return {
    ...item,
    choose: async () => {
      await act(async () => {
        onSelect({ nativeEvent: { id: item.id } });
      });
    },
  };
};

// Chooses Remind Me to Send… from Send's menu.
export const remindFromSendMenu = async () => {
  const item = sendMenuItem('Remind Me to Send…');
  ok(item.subtitle === 'Keep it as a draft and remind me');
  await item.choose();
};
