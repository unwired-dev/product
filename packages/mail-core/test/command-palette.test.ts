import {
  commandChoices,
  commandHintSeen,
  commandKey,
  createCommandPalette,
  matchingCommands,
} from '../src/command-palette.ts';

describe('a window command palette', () => {
  it('keeps the captured mailbox target and rejects a replacement with the same provider message ID', () => {
    expect.hasAssertions();
    const palette = createCommandPalette('Unavailable');
    const owner = {};
    const command = {
      id: 'archive',
      label: 'Archive',
      group: 'selection' as const,
      target: 'personal/123',
      onRun: () => false,
    };
    palette.register(owner, [command]);
    palette.open();
    palette.register(owner, [{ ...command, target: 'work/123' }]);
    expect(palette.getSnapshot().commands[0]).toMatchObject({
      target: 'personal/123',
      disabled: 'Unavailable',
    });
    palette.close();
    palette.open();
    expect(palette.getSnapshot().commands[0]).toMatchObject({
      target: 'work/123',
    });
  });

  it('refreshes availability without redirecting an open command to another screen owner', () => {
    expect.hasAssertions();
    const palette = createCommandPalette('Unavailable');
    const owner = {};
    const command = {
      id: 'reply',
      label: 'Reply',
      group: 'selection' as const,
      target: 'mail/message',
      onRun: () => false,
    };
    palette.register(owner, [command]);
    palette.open();
    palette.register(owner, [{ ...command, disabled: 'Storage locked' }]);
    expect(palette.getSnapshot().commands[0]?.disabled).toBe('Storage locked');
    palette.register({}, [command]);
    expect(palette.getSnapshot().commands[0]?.disabled).toBe('Unavailable');
    palette.remove(owner);
    expect(palette.getSnapshot().commands[0]?.disabled).toBe('Unavailable');
  });

  it('publishes each closed snapshot with its dismissal or retirement reason', () => {
    expect.hasAssertions();
    const palette = createCommandPalette('Unavailable');
    const owner = {};
    palette.register(owner, [
      {
        id: 'compose',
        label: 'Compose',
        group: 'app',
        onRun: () => false,
      },
    ]);
    const presentations: ReturnType<typeof palette.getSnapshot>[] = [];
    const unsubscribe = palette.subscribe(() => {
      presentations.push(palette.getSnapshot());
    });
    palette.open();
    palette.close('dismissed');
    palette.open();
    palette.close();
    palette.open();
    palette.remove(owner);
    unsubscribe();
    expect(
      presentations.map(({ open, presentation }) => ({ open, presentation })),
    ).toStrictEqual([
      { open: true, presentation: 'open' },
      { open: false, presentation: 'dismissed' },
      { open: true, presentation: 'open' },
      { open: false, presentation: 'retired' },
      { open: true, presentation: 'open' },
      { open: false, presentation: 'retired' },
    ]);
  });

  it('orders contextual actions first and matches abbreviations and synonyms without personalizing', () => {
    expect.hasAssertions();
    const palette = createCommandPalette('Unavailable');
    palette.register({}, [
      {
        id: 'settings',
        label: 'Open Settings',
        keywords: 'preferences',
        group: 'navigation',
        onRun: () => false,
      },
      {
        id: 'archive',
        label: 'Archive',
        group: 'selection',
        onRun: () => false,
      },
    ]);
    expect(palette.getSnapshot().commands.map(({ id }) => id)).toStrictEqual([
      'archive',
      'settings',
    ]);
    expect(
      matchingCommands(palette.getSnapshot().commands, 'pref').map(
        ({ id }) => id,
      ),
    ).toStrictEqual(['settings']);
    expect(
      matchingCommands(palette.getSnapshot().commands, 'opst').map(
        ({ id }) => id,
      ),
    ).toStrictEqual(['settings']);
  });
});

describe('native command palette input', () => {
  it('ignores malformed key events and treats only a native true hint flag as seen', () => {
    expect.hasAssertions();
    expect([
      commandKey({ key: 'open' }),
      commandKey({ key: 'delete' }),
      commandKey('open'),
    ]).toStrictEqual(['open', undefined, undefined]);
    expect([
      commandHintSeen(true),
      commandHintSeen('true'),
      commandHintSeen(undefined),
    ]).toStrictEqual([true, false, false]);
  });

  it('keeps nested choices unavailable when their captured parent is disabled or removed', () => {
    expect.hasAssertions();
    const child = {
      id: 'folder',
      label: 'Folder',
      group: 'selection' as const,
      onRun: () => false,
    };
    const command = {
      id: 'move',
      label: 'Move',
      group: 'selection' as const,
      disabled: 'Target removed',
      choices: [child],
    };
    expect(commandChoices([command], ['move'], 'Unavailable')).toStrictEqual({
      commands: [child],
      disabled: 'Target removed',
    });
    expect(commandChoices([], ['move'], 'Unavailable')).toStrictEqual({
      commands: [],
      disabled: 'Unavailable',
    });
  });
});
