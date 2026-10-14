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
