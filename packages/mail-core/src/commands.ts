// Finding, ordering and offering Command Palette commands: contextual actions first, then
// app-wide actions, then destinations, in a fixed order that typing only narrows. The registry
// holds what the mounted screens offer now; a palette snapshots it when opening and rechecks it
// before running, so a command never acts on a message other than the one it was opened for.
import type { Translate } from '@private-email/localization';

import * as Arr from 'effect/Array';
import * as Effect from 'effect/Effect';
import * as Option from 'effect/Option';
import * as Order from 'effect/Order';
import * as Schema from 'effect/Schema';
import * as Semaphore from 'effect/Semaphore';

import type { ResponseKind } from './responses.ts';

import { rejectionDiagnostic, runLogged } from './diagnostics.ts';

export type CommandSection = 'selection' | 'app' | 'navigation';

// Every command the palette can list, in the fixed order within each section.
const commandOrder = [
  'reply',
  'replyAll',
  'forward',
  'archive',
  'trash',
  'move',
  'star',
  'unstar',
  'read',
  'unread',
  'spam',
  'compose',
  'search',
  'inbox',
  'account',
] as const;

export type CommandId = (typeof commandOrder)[number];

export interface SearchableCommand {
  readonly title: string;
  // Common synonyms, space separated, that also match the command.
  readonly keywords?: string | undefined;
}

// The message a contextual command acts on. The palette fixes it when opening; a command that
// later names another message never runs in its place.
export interface CommandTarget {
  readonly id: string;
  readonly subject: string;
}

// A destination a command needs first, such as the folder a message moves to.
export interface CommandChoice extends SearchableCommand {
  readonly id: string;
  // The SF Symbol shown beside the title; a folder unless the choice says otherwise.
  readonly icon?: string | undefined;
  // Why the choice cannot be taken, such as the message's current folder.
  readonly disabled?: string | undefined;
  readonly run: () => void;
}

export interface Command extends SearchableCommand {
  readonly id: CommandId;
  readonly section: CommandSection;
  // The SF Symbol shown beside the title.
  readonly icon: string;
  readonly target?: CommandTarget | undefined;
  // Why the command cannot run now; it stays listed.
  readonly disabled?: string | undefined;
  readonly run?: (() => void | Promise<void>) | undefined;
  // The choices the command needs first, with what choosing one does.
  readonly choices?: readonly CommandChoice[] | undefined;
  readonly choosing?: string | undefined;
  // What the input's chip says while choosing, when the title's ellipsis would not fit.
  readonly chip?: string | undefined;
}

const sectionOrder: Record<CommandSection, number> = {
  selection: 0,
  app: 1,
  navigation: 2,
};

const byPlace = Order.combine(
  Order.mapInput(
    Order.Number,
    (command: Command) => sectionOrder[command.section],
  ),
  Order.mapInput(Order.Number, (command: Command) =>
    commandOrder.indexOf(command.id),
  ),
);

/**
 * Orders commands for an empty query: contextual actions, then app actions,
 * then destinations, each in the palette's fixed order.
 *
 * @param {readonly Command[]} commands The commands as their owners offered
 *   them.
 * @returns {Command[]} The same commands, grouped by section and ordered.
 */
export const orderCommands = (commands: readonly Command[]) =>
  Arr.sort(commands, byPlace);

const words = (text: string) =>
  text
    .normalize('NFD')
    .replaceAll(/\p{M}/gu, '')
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((word) => word !== '');

// Each query word starts one word of the command's name or synonyms and continues as a
// subsequence of it, so "arch" finds Archive but not Search.
const subsequence = (query: string, word: string) => {
  const [first] = query;
  if (first === undefined || !word.startsWith(first)) {
    return false;
  }
  let at = 0;
  for (const character of word) {
    if (character === query[at]) {
      at += 1;
    }
  }
  return at === query.length;
};

/**
 * Narrows commands or choices to those matching a query, keeping their order.
 *
 * @param {string} query What the person typed; blank keeps every command.
 * @param {readonly C[]} commands The commands in their listed order.
 * @returns {C[]} The commands whose name or synonyms match every query word.
 */
export const matchCommands = <C extends SearchableCommand>(
  query: string,
  commands: readonly C[],
) => {
  const typed = words(query);
  if (typed.length === 0) {
    return [...commands];
  }
  return commands.filter((command) => {
    const names = words(`${command.title} ${command.keywords ?? ''}`);
    return typed.every((word) => names.some((name) => subsequence(word, name)));
  });
};

/**
 * Keeps one command per id: the one that can run over a disabled placeholder,
 * the latest otherwise.
 *
 * @param {readonly Command[]} commands The commands every owner offers, in
 *   order.
 * @returns {Command[]} One command per id.
 */
export const mergeCommands = (commands: readonly Command[]) => {
  const byId = new Map<CommandId, Command>();
  for (const command of commands) {
    const known = byId.get(command.id);
    if (
      known === undefined ||
      known.disabled !== undefined ||
      command.disabled === undefined
    ) {
      byId.set(command.id, command);
    }
  }
  return [...byId.values()];
};

/**
 * Finds a snapshotted command as its owner offers it now, when it still names
 * the same message and can run.
 *
 * @param {readonly Command[]} live What the mounted screens offer now.
 * @param {Command} opened The command as the palette listed it.
 * @returns {Command | undefined} The live command, or undefined once its
 *   message left.
 */
export const offeredCommand = (live: readonly Command[], opened: Command) => {
  const found = mergeCommands(live).find(({ id }) => id === opened.id);
  return found !== undefined &&
    found.target?.id === opened.target?.id &&
    found.disabled === undefined
    ? found
    : undefined;
};

/**
 * The commands the mounted screens can run now, by the component that owns each
 * set; a store for the host's palette.
 *
 * @returns {object} The registry's subscription, snapshot and registration.
 */
export const createCommandRegistry = () => {
  const owners = new Map<symbol, readonly Command[]>();
  const listeners = new Set<() => void>();
  let snapshot: readonly Command[] = [];
  const notify = () => {
    snapshot = [...owners.values()].flat();
    for (const listener of listeners) {
      listener();
    }
  };
  return {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    getSnapshot: () => snapshot,
    register: (owner: symbol, commands: readonly Command[]) => {
      owners.set(owner, commands);
      notify();
      return () => {
        owners.delete(owner);
        notify();
      };
    },
  };
};

export type CommandRegistry = ReturnType<typeof createCommandRegistry>;

// Gmail message IDs are unique only within their mailbox.
export const commandTarget = (
  mailbox: string | undefined,
  message: Readonly<{ id: string; subject: string }>,
): CommandTarget => ({
  id: `${mailbox}\n${message.id}`,
  subject: message.subject,
});

const icons: Record<CommandId, string> = {
  reply: 'arrowshape.turn.up.left',
  replyAll: 'arrowshape.turn.up.left.2',
  forward: 'arrowshape.turn.up.right',
  archive: 'archivebox',
  trash: 'trash',
  move: 'folder',
  star: 'star',
  unstar: 'star.slash',
  read: 'envelope.open',
  unread: 'envelope.badge',
  spam: 'xmark.bin',
  compose: 'square.and.pencil',
  search: 'magnifyingglass',
  inbox: 'tray',
  account: 'gearshape',
};

const command = (
  t: Translate,
  details: Omit<Command, 'icon' | 'keywords'>,
): Command => ({
  ...details,
  icon: icons[details.id],
  keywords: t(`commands.keywords.${details.id}`),
});

/**
 * The contextual commands that stay listed, disabled with a reason, until a
 * message offers them.
 *
 * @param {Translate} t The current translation.
 * @param {object} placeholder The message they name, if the reader shows one,
 *   and the reason.
 * @returns {readonly Command[]} Reply, Forward, Archive and Move to…, disabled.
 */
export const expectedCommands = (
  t: Translate,
  placeholder: Readonly<{
    target?: CommandTarget | undefined;
    disabled: string;
  }>,
): readonly Command[] =>
  (
    [
      ['reply', 'message.reply'],
      ['forward', 'message.forward'],
      ['archive', 'gmailActions.label.archive'],
      ['move', 'commands.move'],
    ] as const
  ).map(([id, title]) =>
    command(t, { id, section: 'selection', title: t(title), ...placeholder }),
  );

/**
 * Reply, Reply All and Forward for the open message.
 *
 * @param {Translate} t The current translation.
 * @param {CommandTarget} target The open message.
 * @param {object} reader The reader's response handler, and whether it is
 *   already starting a response; the commands are disabled then, as its buttons
 *   are.
 * @returns {readonly Command[]} The response commands.
 */
export const responseCommands = (
  t: Translate,
  target: CommandTarget,
  reader: Readonly<{
    start: (kind: ResponseKind) => Promise<void>;
    starting: boolean;
  }>,
): readonly Command[] =>
  (
    [
      ['reply', 'message.reply'],
      ['replyAll', 'message.replyAll'],
      ['forward', 'message.forward'],
    ] as const
  ).map(([kind, title]) =>
    command(t, {
      id: kind,
      section: 'selection',
      title: t(title),
      target,
      disabled: reader.starting ? t('commands.starting') : undefined,
      run: () => reader.start(kind),
    }),
  );

/**
 * The provider actions the reader's toolbar offers, as commands, plus Move to…,
 * which chooses its destination inside the palette before anything moves.
 *
 * @param {Translate} t The current translation.
 * @param {object} toolbar The open message; the toolbar's actions, as
 *   `quickActions` or `imapQuickActions` list them, with its handler for one of
 *   them; and the folders or labels the message can move to, none of which
 *   leaves Move to… out.
 * @returns {readonly Command[]} The organizing commands.
 */
export const organizeCommands = <A>(
  t: Translate,
  toolbar: Readonly<{
    target: CommandTarget;
    actions: ReadonlyArray<
      Readonly<{ name: CommandId; label: string; action: A }>
    >;
    act: (action: A) => void;
    destinations: readonly CommandChoice[];
  }>,
): readonly Command[] => [
  ...toolbar.actions.map(({ name, label, action }) =>
    command(t, {
      id: name,
      section: 'selection',
      title: label,
      target: toolbar.target,
      run: () => {
        toolbar.act(action);
      },
    }),
  ),
  ...(toolbar.destinations.length === 0
    ? []
    : [
        command(t, {
          id: 'move',
          section: 'selection',
          title: t('commands.move'),
          target: toolbar.target,
          choosing: t('commands.moveOne'),
          chip: t('commands.moveChip'),
          choices: toolbar.destinations,
        }),
      ]),
];

/**
 * The Inbox's app-wide and navigation commands, each offered while its control
 * is.
 *
 * @param {Translate} t The current translation.
 * @param {object} handlers What each command does, or undefined while it is
 *   unavailable: focusing the search field, leaving to the Inbox, and opening
 *   the Account.
 * @returns {readonly Command[]} The commands the Inbox offers now.
 */
export const inboxCommands = (
  t: Translate,
  handlers: Readonly<{
    search?: (() => void | Promise<void>) | undefined;
    inbox?: (() => void | Promise<void>) | undefined;
    account?: (() => void) | undefined;
  }>,
): readonly Command[] => [
  ...(handlers.search === undefined
    ? []
    : [
        command(t, {
          id: 'search',
          section: 'app',
          title: t('commands.search'),
          run: handlers.search,
        }),
      ]),
  ...(handlers.inbox === undefined
    ? []
    : [
        command(t, {
          id: 'inbox',
          section: 'navigation',
          title: t('commands.inbox'),
          run: handlers.inbox,
        }),
      ]),
  ...(handlers.account === undefined
    ? []
    : [
        command(t, {
          id: 'account',
          section: 'navigation',
          title: t('inbox.account'),
          run: handlers.account,
        }),
      ]),
];

/**
 * New Message, while a mailbox can send.
 *
 * @param {Translate} t The current translation.
 * @param {Function} run What starting a new message does.
 * @returns {Command} The compose command.
 */
export const composeCommand = (t: Translate, run: () => void): Command =>
  command(t, {
    id: 'compose',
    section: 'app',
    title: t('drafts.newMessage'),
    run,
  });

/**
 * The heading over a section of listed commands.
 *
 * @param {Translate} t The current translation.
 * @param {CommandSection} section The section.
 * @param {string | undefined} subject The open message's subject, named over
 *   its commands.
 * @returns {string} The heading.
 */
export const sectionTitle = (
  t: Translate,
  section: CommandSection,
  subject: string | undefined,
) => {
  if (section === 'selection') {
    return subject === undefined
      ? t('commands.selection')
      : t('commands.selectionWith', { subject });
  }
  return t(section === 'app' ? 'commands.app' : 'commands.navigation');
};

// Small device-local interface preferences the native host keeps, such as a hint already shown.
export interface NativePreferences {
  // Resolves `{ value }`: the saved text, or null.
  readonly preference: (key: string) => Promise<unknown>;
  readonly setPreference: (key: string, value: string) => Promise<unknown>;
}

const hintKey = 'command-palette-hint';
const decodeSaved = Schema.decodeUnknownOption(
  Schema.Struct({ value: Schema.NullOr(Schema.String) }),
);

class PreferenceFailure extends Schema.TaggedError<PreferenceFailure>()(
  'PreferenceFailure',
  { cause: Schema.Defect() },
) {}

const call = (request: () => Promise<unknown>) =>
  Effect.tryPromise({
    try: request,
    catch: (cause) => new PreferenceFailure({ cause }),
  });

const logFailure =
  (message: string) =>
  ({ cause }: Readonly<{ cause: unknown }>) =>
    Effect.logError(message, rejectionDiagnostic(cause));

/**
 * The one-time hint that explains the iPhone gesture: due once loaded, until
 * dismissed or the palette first opens. A store for the host.
 *
 * @param {NativePreferences} native The device's saved preferences.
 * @returns {object} Whether the hint is due, its loading and its dismissal.
 */
export const createPaletteHint = (native: NativePreferences) => {
  const operations = Semaphore.makeUnsafe(1);
  let due = false;
  const listeners = new Set<() => void>();
  const publish = (next: boolean) => {
    if (next === due) {
      return;
    }
    due = next;
    for (const listener of listeners) {
      listener();
    }
  };
  return {
    getSnapshot: () => due,
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    // Due until the saved preference says it was seen. An unreadable or malformed preference
    // keeps it hidden.
    load: () =>
      runLogged(
        operations
          .withPermit(
            call(() => native.preference(hintKey)).pipe(
              Effect.map((reply) =>
                Option.match(decodeSaved(reply), {
                  onNone: () => false,
                  onSome: ({ value }) => value === null,
                }),
              ),
              Effect.catchTag('PreferenceFailure', (failure) =>
                logFailure(
                  'Command Palette hint preference could not be read:',
                )(failure).pipe(Effect.as(false)),
              ),
              Effect.tap((next) =>
                Effect.sync(() => {
                  publish(next);
                }),
              ),
            ),
          )
          .pipe(Effect.asVoid),
      ),
    dismiss: () =>
      runLogged(
        operations
          .withPermit(
            Effect.gen(function* () {
              if (!due) {
                return;
              }
              publish(false);
              yield* call(() => native.setPreference(hintKey, 'seen'));
            }),
          )
          .pipe(
            Effect.asVoid,
            Effect.catchTag(
              'PreferenceFailure',
              logFailure('Command Palette hint preference could not be saved:'),
            ),
          ),
      ),
  };
};

export type PaletteHintStore = ReturnType<typeof createPaletteHint>;
