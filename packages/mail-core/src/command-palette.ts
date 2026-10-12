import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

export type PaletteCommand = Readonly<{
  id: string;
  label: string;
  keywords?: string;
  shortcut?: string;
  group: 'selection' | 'app' | 'navigation';
  target?: string;
  disabled?: string | undefined;
}> &
  (
    | Readonly<{
        onRun:
          | (() => void)
          | (() => boolean | undefined | Promise<boolean | undefined>);
        choices?: never;
      }>
    | Readonly<{ choices: readonly PaletteCommand[]; onRun?: never }>
  );

type Entry = Readonly<{ owner: object; command: PaletteCommand }>;
const order = ['selection', 'app', 'navigation'] as const;

export function matchingCommands(
  commands: readonly PaletteCommand[],
  query: string,
) {
  const words = query.toLocaleLowerCase().trim().split(/\s+/u);
  return commands.filter(({ label, keywords = '' }) => {
    const text = `${label} ${keywords}`.toLocaleLowerCase();
    return words.every((word) => {
      let position = 0;
      for (const letter of word) {
        const next = text.indexOf(letter, position);
        if (next === -1) {
          return false;
        }
        position = next + 1;
      }
      return true;
    });
  });
}

// A window owns its catalog. Open palettes retain identity, while availability stays live.
export function createCommandPalette(initialUnavailable: string) {
  let unavailable = initialUnavailable;
  const groups = new Map<object, readonly PaletteCommand[]>();
  const listeners = new Set<() => void>();
  let captured: readonly Entry[] | undefined = undefined;
  let closedPresentation: 'dismissed' | 'retired' = 'retired';
  let snapshot: Readonly<{
    open: boolean;
    presentation: 'open' | 'dismissed' | 'retired';
    commands: readonly PaletteCommand[];
  }> = {
    open: false,
    presentation: 'retired',
    commands: [],
  };
  const entries = () => {
    const commands = new Map<string, Entry>();
    for (const [owner, group] of groups) {
      for (const command of group) {
        const previous = commands.get(command.id);
        if (
          previous === undefined ||
          command.target !== undefined ||
          previous.command.target === undefined
        ) {
          commands.set(command.id, { owner, command });
        }
      }
    }
    return order.flatMap((group) =>
      [...commands.values()].filter(({ command }) => command.group === group),
    );
  };
  const publish = () => {
    const current = entries();
    const commands =
      captured === undefined
        ? current.map(({ command }) => command)
        : captured.map((entry) => {
            const updated = current.find(
              ({ owner, command }) =>
                owner === entry.owner &&
                command.id === entry.command.id &&
                command.target === entry.command.target,
            );
            return (
              updated?.command ?? { ...entry.command, disabled: unavailable }
            );
          });
    snapshot = {
      open: captured !== undefined,
      presentation: captured === undefined ? closedPresentation : 'open',
      commands,
    };
    for (const listener of listeners) {
      listener();
    }
  };
  return {
    setUnavailable: (reason: string) => {
      unavailable = reason;
      publish();
    },
    getSnapshot: () => snapshot,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    register: (owner: object, commands: readonly PaletteCommand[]) => {
      groups.set(owner, commands);
      publish();
    },
    remove: (owner: object) => {
      groups.delete(owner);
      if (groups.size === 0) {
        captured = undefined;
        closedPresentation = 'retired';
      }
      publish();
    },
    open: () => {
      if (captured !== undefined || groups.size === 0) {
        return;
      }
      captured = entries();
      publish();
    },
    close: (presentation: 'dismissed' | 'retired' = 'retired') => {
      closedPresentation = presentation;
      captured = undefined;
      publish();
    },
  };
}

const keySchema = Schema.Struct({
  key: Schema.Literals(['open', 'up', 'down', 'enter', 'escape']),
});

export function commandKey(event: unknown) {
  return Option.getOrUndefined(Schema.decodeUnknownOption(keySchema)(event))
    ?.key;
}

export const commandHintSeen = Schema.is(Schema.Literal(true));

export function commandChoices(
  commands: readonly PaletteCommand[],
  path: readonly string[],
  unavailable: string,
) {
  let choices = commands;
  let disabled: string | undefined = undefined;
  for (const id of path) {
    const parent = choices.find((command) => command.id === id);
    disabled ??=
      parent?.disabled ?? (parent === undefined ? unavailable : undefined);
    choices = parent?.choices ?? [];
  }
  return { commands: choices, disabled };
}
