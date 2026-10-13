import type { Command } from '@private-email/mail-core/commands';

import {
  createCommandRegistry,
  createPaletteHint,
  matchCommands,
  mergeCommands,
  offeredCommand,
  orderCommands,
} from '@private-email/mail-core/commands';

const command = (
  details: Pick<Command, 'id' | 'section' | 'title'> & Partial<Command>,
): Command => ({ icon: 'circle', ...details });

const commands = [
  command({
    id: 'inbox',
    section: 'navigation',
    title: 'Inbox',
    keywords: 'home mail',
  }),
  command({
    id: 'compose',
    section: 'app',
    title: 'New Message',
    keywords: 'compose write',
  }),
  command({ id: 'unread', section: 'selection', title: 'Mark as unread' }),
  command({
    id: 'archive',
    section: 'selection',
    title: 'Archive',
    keywords: 'file away',
  }),
  command({
    id: 'move',
    section: 'selection',
    title: 'Move to…',
    keywords: 'folder label',
  }),
  command({ id: 'reply', section: 'selection', title: 'Reply' }),
  command({
    id: 'search',
    section: 'app',
    title: 'Search Mail',
    keywords: 'find',
  }),
];

const titles = (query: string) =>
  matchCommands(query, orderCommands(commands)).map(({ title }) => title);

describe('command palette matching', () => {
  it('lists contextual actions, then app actions, then destinations, each in the fixed order', () => {
    expect.hasAssertions();
    expect(orderCommands(commands).map(({ title }) => title)).toStrictEqual([
      'Reply',
      'Archive',
      'Move to…',
      'Mark as unread',
      'New Message',
      'Search Mail',
      'Inbox',
    ]);
  });

  it('matches from the start of a name word, fuzzily, without reordering', () => {
    expect.hasAssertions();
    expect(titles('arch')).toStrictEqual(['Archive']);
    expect(titles('mv')).toStrictEqual(['Move to…']);
    expect(titles('MAIL')).toStrictEqual(['Search Mail', 'Inbox']);
    expect(titles('mark unread')).toStrictEqual(['Mark as unread']);
    expect(titles('zzz')).toStrictEqual([]);
  });

  it('matches common synonyms and keeps every command for a blank query', () => {
    expect.hasAssertions();
    expect(titles('folder')).toStrictEqual(['Move to…']);
    expect(titles('compose')).toStrictEqual(['New Message']);
    expect(titles('   ')).toHaveLength(commands.length);
  });

  it('ignores accents in the query and the command', () => {
    expect.hasAssertions();
    expect(
      matchCommands('presunout', [{ title: 'Přesunout do…' }]),
    ).toHaveLength(1);
  });
});

describe('command palette targets', () => {
  const placeholder = command({
    id: 'archive',
    section: 'selection',
    title: 'Archive',
    disabled: 'Select a conversation',
  });
  const offered = (id: string) =>
    command({
      id: 'archive',
      section: 'selection',
      title: 'Archive',
      target: { id, subject: 'Saturday' },
    });

  it('lists the offered command over its disabled placeholder, in the placeholder order', () => {
    expect.hasAssertions();
    const reply = command({
      id: 'reply',
      section: 'selection',
      title: 'Reply',
    });
    expect(
      mergeCommands([placeholder, reply, offered('inbox-1\nm1')]),
    ).toStrictEqual([offered('inbox-1\nm1'), reply]);
    expect(mergeCommands([offered('inbox-1\nm1'), placeholder])).toStrictEqual([
      offered('inbox-1\nm1'),
    ]);
  });

  it('never offers a snapshotted command for another message after its own left', () => {
    expect.hasAssertions();
    const registry = createCommandRegistry();
    const opened = offered('inbox-1\nm1');
    const reader = Symbol('reader');
    const unregister = registry.register(reader, [opened]);
    expect(offeredCommand(registry.getSnapshot(), opened)).toStrictEqual(
      opened,
    );
    // The reader now shows another message: the same command names a different target.
    unregister();
    registry.register(reader, [offered('inbox-1\nm2'), placeholder]);
    expect(offeredCommand(registry.getSnapshot(), opened)).toBeUndefined();
    // The reader closed: only the disabled placeholder remains.
    registry.register(reader, [placeholder]);
    expect(offeredCommand(registry.getSnapshot(), opened)).toBeUndefined();
  });

  it('notifies subscribers as owners register and leave', () => {
    expect.hasAssertions();
    const registry = createCommandRegistry();
    const seen: number[] = [];
    const unsubscribe = registry.subscribe(() => {
      seen.push(registry.getSnapshot().length);
    });
    const unregister = registry.register(Symbol('inbox'), [
      command({ id: 'search', section: 'app', title: 'Search Mail' }),
    ]);
    unregister();
    unsubscribe();
    registry.register(Symbol('inbox'), [placeholder]);
    expect(seen).toStrictEqual([1, 0]);
  });
});

describe('command palette hint preference', () => {
  it('is due once loaded until dismissed, and hidden when the saved preference is unreadable', async () => {
    expect.hasAssertions();
    const saved: string[] = [];
    let value: string | null = null;
    const hint = createPaletteHint({
      preference: () => Promise.resolve({ value }),
      setPreference: (key, next) => {
        saved.push(key);
        value = next;
        return Promise.resolve({});
      },
    });
    const seen: boolean[] = [];
    hint.subscribe(() => {
      seen.push(hint.getSnapshot());
    });
    await hint.load();
    expect(hint.getSnapshot()).toBe(true);
    await hint.dismiss();
    await hint.dismiss();
    expect(seen).toStrictEqual([true, false]);
    expect(saved).toStrictEqual(['command-palette-hint']);
    await hint.load();
    expect(hint.getSnapshot()).toBe(false);
    const malformed = createPaletteHint({
      preference: () => Promise.resolve({ value: 7 }),
      setPreference: () => Promise.reject(new Error('unavailable')),
    });
    await malformed.load();
    expect(malformed.getSnapshot()).toBe(false);
  });
});
