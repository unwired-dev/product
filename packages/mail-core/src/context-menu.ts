import type { Translate } from '@private-email/localization';

import type { Command, CommandId, CommandTarget } from './commands.ts';

import { mergeCommands } from './commands.ts';

// A context menu's items as the hosts' native menu views receive them. An action's key names what
// it does to which message or destination, so an open menu runs that action's latest callback after
// a live update, never another action, and nothing once the action is gone.
export type MenuAction = () => void | Promise<void>;

// A context menu item: an action, or a submenu of further items.
export type MenuItem = Readonly<{
  title: string;
  symbol: string;
  destructive?: boolean;
}> &
  (
    | Readonly<{ key: string; run: MenuAction }>
    | Readonly<{ items: readonly MenuItem[] }>
  );

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

// The native items, each action identified by its key, and the latest callback for each key.
export const menuState = (sections: readonly MenuSection[]) => {
  const runs = new Map<string, MenuAction>();
  const native = (item: MenuItem): NativeMenuItem => {
    const { title, symbol, destructive } = item;
    if ('run' in item) {
      runs.set(item.key, item.run);
      return { id: item.key, title, symbol, destructive };
    }
    return { id: '', title, symbol, items: item.items.map(native) };
  };
  return {
    sections: sections
      .filter(({ items }) => items.length > 0)
      .map(({ palette, items }) => ({ palette, items: items.map(native) })),
    runs,
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
  target: CommandTarget,
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
      const key = `${target.id}\n${id}`;
      const enabled = choices.filter((choice) => choice.disabled === undefined);
      if (enabled.length > 0) {
        return [
          {
            title,
            symbol,
            items: enabled.map((choice) => ({
              key: `${key}\n${choice.id}`,
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
              key,
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
        ['restore', t('contextMenu.restore'), 'tray.and.arrow.down'],
        ['move', t('contextMenu.moveMessage'), 'folder'],
        ['spam', t('gmailActions.label.spam'), 'xmark.bin'],
        ['trash', t('contextMenu.trashMessage'), 'trash'],
      ]),
    },
  ];
};

// The row's supported organizing actions, with Delete last and Spam omitted. Keys carry the
// listed message, so a recycled row never runs an action for the message it showed before.
export const rowContextMenu = (
  t: Translate,
  message: string,
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
              key: `${message}\n${name}`,
              title,
              symbol,
              destructive: name === 'trash',
              run: action.run,
            },
          ];
    });
  return [
    {
      items: menuItems([
        ['archive', t('contextMenu.archive'), 'archivebox'],
        ['restore', t('contextMenu.restore'), 'tray.and.arrow.down'],
      ]),
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
