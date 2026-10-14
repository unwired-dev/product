import type { Translate } from '@private-email/localization';

import type { Command, CommandId, CommandTarget } from './commands.ts';

import { mergeCommands } from './commands.ts';

// A context menu's items as the hosts' native menu views receive them: each action gets an ID
// that stays stable across live updates, so a displayed item never runs another action.
export type MenuAction = () => void | Promise<void>;

// A context menu item: an action, or a submenu of further items.
export type MenuItem = Readonly<{
  title: string;
  symbol: string;
  destructive?: boolean;
}> &
  (Readonly<{ run: MenuAction }> | Readonly<{ items: readonly MenuItem[] }>);

// A group of items set apart by separators; a palette shows them side by side on iPhone and iPad.
export type MenuSection = Readonly<{
  palette?: boolean;
  items: readonly MenuItem[];
}>;

export type NativeMenuItem = Readonly<{
  id: string;
  title: string;
  symbol: string;
  destructive?: boolean | undefined;
  items?: readonly NativeMenuItem[];
}>;

// Carry action IDs across live menu updates, without retaining retired callbacks.
export const menuState = (
  sections: readonly MenuSection[],
  previous?: Readonly<{
    ids: ReadonlyMap<MenuAction, string>;
    nextId: number;
  }>,
) => {
  const runs = new Map<string, MenuAction>();
  const ids = new Map<MenuAction, string>();
  let { nextId } = previous ?? { nextId: 0 };
  const native = (item: MenuItem): NativeMenuItem => {
    const { title, symbol, destructive } = item;
    if ('run' in item) {
      let id = ids.get(item.run) ?? previous?.ids.get(item.run);
      if (id === undefined) {
        id = String(nextId);
        nextId += 1;
      }
      ids.set(item.run, id);
      runs.set(id, item.run);
      return { id, title, symbol, destructive };
    }
    return {
      id: '',
      title,
      symbol,
      items: item.items.map(native),
    };
  };
  return {
    source: sections,
    sections: sections
      .filter(({ items }) => items.length > 0)
      .map(({ palette, items }) => ({ palette, items: items.map(native) })),
    runs,
    ids,
    nextId,
  };
};

// The enabled commands the mounted screens offer for one message now.
export const messageCommands = (
  commands: readonly Command[],
  target: CommandTarget,
) =>
  mergeCommands(commands).filter(
    (command) =>
      command.target?.id === target.id && command.disabled === undefined,
  );

// The enabled commands for the open message, in the reader menu's fixed groups.
export const messageContextMenu = (
  t: Translate,
  commands: readonly Command[],
): readonly MenuSection[] => {
  const items = (
    entries: ReadonlyArray<readonly [CommandId, string, string]>,
  ): MenuItem[] =>
    entries.flatMap(([id, title, symbol]): MenuItem[] => {
      const command = commands.find((each) => each.id === id);
      if (command === undefined) {
        return [];
      }
      const { choices = [], run } = command;
      const enabled = choices.filter((choice) => choice.disabled === undefined);
      if (enabled.length > 0) {
        return [
          {
            title,
            symbol,
            items: enabled.map((choice) => ({
              title: choice.title,
              symbol: choice.icon ?? 'folder',
              run: choice.run,
            })),
          },
        ];
      }
      return run === undefined
        ? []
        : [
            {
              title,
              symbol,
              destructive: id === 'trash',
              run,
            },
          ];
    });
  return [
    {
      palette: true,
      items: items([
        ['reply', t('contextMenu.reply'), 'arrowshape.turn.up.left'],
        ['replyAll', t('contextMenu.replyAll'), 'arrowshape.turn.up.left.2'],
        ['forward', t('contextMenu.forward'), 'arrowshape.turn.up.right'],
      ]),
    },
    {
      items: items([
        ['read', t('contextMenu.read'), 'envelope.open'],
        ['unread', t('contextMenu.unread'), 'envelope.badge'],
        ['star', t('contextMenu.star'), 'flag'],
        ['unstar', t('contextMenu.unstar'), 'flag.slash'],
      ]),
    },
    {
      items: items([
        ['move', t('contextMenu.moveMessage'), 'folder'],
        ['trash', t('contextMenu.trashMessage'), 'trash'],
      ]),
    },
  ];
};

// The row's supported organizing actions, with Delete last and Spam omitted.
export const rowContextMenu = (
  t: Translate,
  actions: ReadonlyArray<Readonly<{ name: string; run: MenuAction }>>,
): readonly MenuSection[] => {
  const menuItems = (
    entries: ReadonlyArray<readonly [string, string, string]>,
  ): MenuItem[] =>
    entries.flatMap(([name, title, symbol]) => {
      const action = actions.find((each) => each.name === name);
      return action === undefined
        ? []
        : [
            {
              title,
              symbol,
              destructive: name === 'trash',
              run: action.run,
            },
          ];
    });
  return [
    {
      items: menuItems([['archive', t('contextMenu.archive'), 'archivebox']]),
    },
    {
      items: menuItems([
        ['star', t('contextMenu.star'), 'flag'],
        ['unstar', t('contextMenu.unstar'), 'flag.slash'],
        ['read', t('contextMenu.read'), 'envelope.open'],
        ['unread', t('contextMenu.unread'), 'envelope.badge'],
      ]),
    },
    { items: menuItems([['trash', t('contextMenu.trash'), 'trash']]) },
  ];
};
