import { act } from '@testing-library/react-native';

interface Item {
  readonly id: string;
  readonly title: string;
  readonly checked?: boolean;
  readonly disabled?: boolean;
  readonly destructive?: boolean;
}

// The AppKit menu `UnwiredMenu` is tracking, as it received it, until a test answers it.
let tracking:
  | {
      readonly items: readonly Item[];
      readonly answer: (id: string | null) => void;
    }
  | undefined = undefined;

const answer = async (id: string | null) => {
  await act(async () => {
    tracking?.answer(id);
  });
};

export const unwiredMenu = {
  show: (
    _anchor: number,
    sections: ReadonlyArray<{ readonly items: readonly Item[] }>,
  ) =>
    // oxlint-disable-next-line promise/avoid-new -- The menu answers once the test chooses.
    new Promise<string | null>((resolve) => {
      tracking = {
        items: sections.flatMap(({ items }) => items),
        answer: (id) => {
          tracking = undefined;
          resolve(id);
        },
      };
    }),
};

// The open menu's items.
export const menuItems = () => {
  if (tracking === undefined) {
    throw new Error('Expected an open menu');
  }
  return tracking.items;
};

// Chooses an enabled item by its title, as a click or Return would.
export const chooseMenuItem = async (title: string) => {
  const item = menuItems().find((each) => each.title === title);
  if (item === undefined || item.disabled === true) {
    throw new Error(`Expected an enabled menu item ${title}`);
  }
  await answer(item.id);
};

// Escape or a click outside the menu.
export const dismissMenu = async () => {
  menuItems();
  await answer(null);
};
