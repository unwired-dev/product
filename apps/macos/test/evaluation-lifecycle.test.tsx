import { ok } from 'node:assert/strict';

import type { TurboModule } from 'react-native';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from '@testing-library/react-native';
import {
  Animated,
  DeviceEventEmitter,
  TurboModuleRegistry,
  View,
} from 'react-native';

import type { useComposerNavigation } from '../src/mailbox.tsx';

import {
  CommandPaletteProvider,
  useCloseGuard,
} from '../src/command-palette.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { App, alex, registration } from './evaluation-app.tsx';
import { press, simulatedPage } from './evaluation-page.ts';

// What a `registration-draft-editor` build substitutes; the page itself runs only in WebKit.
// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('@private-email/draft-editor/page', () => ({
  editorPage: '<!doctype html><title>Tiptap evaluation page</title>',
}));

// Hold animation completion so dismissal can be checked before its visual exit ends.
function holdMenuMotion() {
  const completions = new Set<
    NonNullable<Parameters<ReturnType<typeof Animated.timing>['start']>[0]>
  >();
  const timing = jest.spyOn(Animated, 'timing').mockImplementation(() => {
    let finish: Parameters<ReturnType<typeof Animated.timing>['start']>[0] =
      undefined;
    return {
      start: (complete) => {
        finish = complete;
        if (complete !== undefined) {
          completions.add(complete);
        }
      },
      stop: () => {
        if (finish !== undefined) {
          completions.delete(finish);
          finish({ finished: false });
        }
      },
      reset: () => undefined,
    };
  });
  return {
    restore: () => timing.mockRestore(),
    finish: async () => {
      await act(() => {
        for (const complete of completions) {
          complete({ finished: true });
        }
        completions.clear();
      });
    },
  };
}

// The closing panel still paints, but native input and accessibility no longer reach it.
function expectRetiringControl(name: string) {
  expect(screen.queryByRole('button', { name })).toBeNull();
  const retained = screen.getByRole('button', {
    name,
    includeHiddenElements: true,
  });
  expect(retained).toBeOnTheScreen();
  let boundary = retained.parent;
  while (
    boundary !== null &&
    boundary.props.accessibilityElementsHidden !== true
  ) {
    boundary = boundary.parent;
  }
  expect(boundary?.props.pointerEvents).toBe('none');
}

// Substitute only the native menu boundary; other native lookups keep their host behavior.
const commandModule = (menu: TurboModule) => {
  const get = TurboModuleRegistry.get.bind(TurboModuleRegistry);
  return jest
    .spyOn(TurboModuleRegistry, 'get')
    .mockImplementation((name) =>
      name === 'UnwiredCommands' ? menu : get(name),
    );
};

function CloseGuardProbe({
  leave,
}: {
  readonly leave: () => Promise<boolean>;
}) {
  useCloseGuard(leave);
  return null;
}

describe('evaluation composer lifetime', () => {
  it('refuses a rejected native close and permits a later close attempt', async () => {
    expect.hasAssertions();
    const menu: TurboModule &
      Readonly<{
        addListener: () => void;
        removeListeners: () => void;
        guardClose: ReturnType<typeof jest.fn>;
        finishClose: ReturnType<typeof jest.fn>;
      }> = {
      addListener: () => undefined,
      removeListeners: () => undefined,
      guardClose: jest.fn(),
      finishClose: jest.fn(),
    };
    const registry = commandModule(menu);
    try {
      const leave = jest
        .fn<Promise<boolean>, []>()
        .mockRejectedValueOnce(new Error('Synthetic close failure'))
        .mockResolvedValue(true);
      await render(
        <CommandPaletteProvider windowId="rejected-close">
          <CloseGuardProbe leave={leave} />
        </CommandPaletteProvider>,
      );
      await act(async () => {
        DeviceEventEmitter.emit('windowShouldClose', {
          window: 'inbox-window-rejected-close',
        });
      });
      await waitFor(() => {
        expect(menu.finishClose).toHaveBeenLastCalledWith(
          'inbox-window-rejected-close',
          false,
        );
      });
      await act(async () => {
        DeviceEventEmitter.emit('windowShouldClose', {
          window: 'inbox-window-rejected-close',
        });
      });
      await waitFor(() => {
        expect(menu.finishClose.mock.calls).toStrictEqual([
          ['inbox-window-rejected-close', false],
          ['inbox-window-rejected-close', true],
        ]);
      });
    } finally {
      registry.mockRestore();
    }
  });

  it('answers navigation at once when Close fails without asking', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const navigation: {
      current: ReturnType<typeof useComposerNavigation> | undefined;
    } = { current: undefined };
    await render(
      <App
        drafts={drafts}
        onNavigation={(value) => {
          navigation.current = value;
        }}
      />,
    );
    await press('New Message');
    await simulatedPage().report({});
    ok(navigation.current, 'Expected navigation');
    const leaving = navigation.current.leave;
    let allowed: boolean | undefined = undefined;
    await act(async () => {
      void leaving().then((result) => {
        allowed = result;
        return result;
      });
    });
    // The page stops before acknowledging the freeze, so Close neither finishes nor asks.
    await act(async () => {
      screen.getByTestId('message-webview').props.onError();
    });
    await waitFor(() => {
      expect({ allowed }).toStrictEqual({ allowed: false });
    });
    // A later Close finishes without running the abandoned navigation.
    allowed = undefined;
    await press('Close');
    await waitFor(() => {
      expect(screen.queryByText(/evaluation editor stopped/u)).toBeNull();
    });
    expect(allowed).toBeUndefined();
  });

  it('continues pending navigation after the current Draft is saved', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const navigation: {
      current: ReturnType<typeof useComposerNavigation> | undefined;
    } = { current: undefined };
    await render(
      <App
        drafts={drafts}
        onNavigation={(value) => {
          navigation.current = value;
        }}
      />,
    );
    await press('New Message');
    await simulatedPage().typed('Keep this Draft');
    ok(navigation.current, 'Expected navigation');
    const leaving = navigation.current.leave;
    let allowed: boolean | undefined = undefined;
    await act(async () => {
      void leaving().then((result) => {
        allowed = result;
        return result;
      });
    });
    expect(allowed).toBeUndefined();
    await simulatedPage().report({ frozen: true });
    await press('Cancel');
    await waitFor(() => {
      expect({ allowed }).toStrictEqual({ allowed: false });
    });
    allowed = undefined;
    await act(async () => {
      void leaving().then((result) => {
        allowed = result;
        return result;
      });
    });
    await simulatedPage().report({ frozen: true });
    await press('Save');
    await waitFor(() => {
      expect(allowed).toBe(true);
    });
    expect(screen.queryByTestId('message-webview')).toBeNull();
  });

  it('finishes deleting its conflict copy after the composer unmounts', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const app = await render(<App drafts={drafts} />);
    await press('New Message');
    const [before] = draftsOf(drafts.getSnapshot());
    ok(before, 'Expected the created Draft');
    const other = createDrafts(storage.native, registration);
    await other.load();
    await simulatedPage().report({});
    await fireEvent.changeText(screen.getByLabelText('Subject'), 'Discard me');
    storage.setLocked(true);
    await press('Close');
    await press('Save');
    await screen.findByText(/This Draft could not be saved/u);
    storage.setLocked(false);
    await other.update({ ...before, subject: 'Other writer' }, before);
    storage.hold();
    await press('Close');
    await press('Don’t Save');
    await app.unmount();
    await act(async () => {
      storage.release();
      await drafts.save();
    });
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    expect(draftsOf(reopened.getSnapshot())).toMatchObject([
      { id: before.id, subject: 'Other writer' },
    ]);
  });

  it('stores nothing from an open editor once another Product Account opens', async () => {
    expect.hasAssertions();
    let productAccount = 'synthetic-product-account';
    const listeners = new Set<() => void>();
    let snapshot = registration.getSnapshot();
    const session = {
      getSnapshot: () => snapshot,
      subscribe: (listener: () => void) => {
        listeners.add(listener);
        return () => {
          listeners.delete(listener);
        };
      },
    };
    const storage = createSyntheticDrafts(() => productAccount);
    const drafts = createDrafts(storage.native, session);
    await render(<App drafts={drafts} />);
    await press('New Message');
    const [created] = draftsOf(drafts.getSnapshot());
    ok(created, 'Expected the created Draft');
    await simulatedPage().typed('Written before the account changed');
    // Another Product Account signs in on this device while the editor is open.
    productAccount = 'next-product-account';
    snapshot = {
      ...snapshot,
      snapshot: { ...snapshot.snapshot, productAccountId: productAccount },
    };
    await act(async () => {
      for (const listener of listeners) {
        listener();
      }
      await drafts.load();
    });
    await press('Close');
    await press('Save');
    // The editor's version belongs to neither account's storage now.
    expect(screen.queryByTestId('message-webview')).toBeNull();
    const next = createDrafts(storage.native, session);
    await next.load();
    expect(draftsOf(next.getSnapshot())).toStrictEqual([]);
    productAccount = 'synthetic-product-account';
    const previous = createDrafts(storage.native, registration);
    await previous.load();
    expect(draftsOf(previous.getSnapshot())).toStrictEqual([created]);
  });

  const later = [
    { kind: 'paragraph', spans: [{ text: 'Window B, later' }] },
  ] as const;
  const windowA = [
    { kind: 'paragraph', spans: [{ text: 'Window A' }] },
  ] as const;

  it.each([
    {
      choice: 'Save',
      kept: (original: string, copy: string) => ({
        [original]: windowA,
        [copy]: later,
      }),
    },
    {
      choice: 'Don’t Save',
      kept: (original: string) => ({ [original]: windowA }),
    },
  ] as const)(
    'moves a stale window and its mounted page to a conflicting copy, then chooses $choice there',
    async ({ choice, kept }) => {
      expect.hasAssertions();
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const drafts = createDrafts(storage.native, registration);
      await drafts.load();
      const id = await drafts.create({
        id: alex,
        address: 'alex@example.invalid',
      });
      ok(id, 'Expected a Draft');
      // Two windows of the app share its Draft store and open the same Draft.
      await render(
        <>
          <View testID="window-a">
            <App drafts={drafts} />
          </View>
          <View testID="window-b">
            <App drafts={drafts} />
          </View>
        </>,
      );
      const inWindow = (name: string) => within(screen.getByTestId(name));
      const pageOf = (name: string) =>
        simulatedPage(() => inWindow(name).getByTestId('message-webview'));
      // Each finishing choice waits for that window's page to acknowledge its last edit.
      const finish = async (name: string, ...buttons: readonly string[]) => {
        for (const button of buttons) {
          const control = await inWindow(name).findByRole('button', {
            name: button,
          });
          await act(async () => {
            await fireEvent.press(control);
          });
          await pageOf(name).report({ frozen: true });
        }
      };
      for (const name of ['window-a', 'window-b']) {
        const row = await inWindow(name).findByRole('button', {
          name: /^Draft\./u,
        });
        await act(async () => {
          await fireEvent.press(row);
        });
      }
      await pageOf('window-a').typed('Window A');
      await finish('window-a', 'Close', 'Save');
      expect(inWindow('window-a').queryByTestId('message-webview')).toBeNull();
      // Window B still edits the version it opened; its save keeps it as a conflicting copy.
      const stale = pageOf('window-b');
      await stale.typed('Window B');
      const page = inWindow('window-b').getByTestId('message-webview');
      storage.setLocked(true);
      await finish('window-b', 'Close', 'Save');
      await inWindow('window-b').findByText(/This Draft could not be saved/u);
      const copy = draftsOf(drafts.getSnapshot()).find(
        (draft) => draft.id !== id,
      );
      ok(copy, 'Expected the conflicting copy');
      expect(copy).toMatchObject({
        conflict: true,
        body: [{ kind: 'paragraph', spans: [{ text: 'Window B' }] }],
      });
      // The same page now edits the copy; the page/store integration checks Undo and Redo.
      expect(inWindow('window-b').getByTestId('message-webview')).toBe(page);
      await stale.report({ document: later });
      storage.setLocked(false);
      await finish('window-b', 'Close', choice);
      expect(inWindow('window-b').queryByTestId('message-webview')).toBeNull();
      const reopened = createDrafts(storage.native, registration);
      await reopened.load();
      const stored = draftsOf(reopened.getSnapshot()).map((draft) => [
        draft.id,
        draft.body,
      ]);
      expect(Object.fromEntries(stored)).toStrictEqual(kept(id, copy.id));
    },
  );

  it('keeps a cancelled save sheet hidden and untouchable until its exit ends', async () => {
    expect.hasAssertions();
    const motion = holdMenuMotion();
    try {
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const mock = createMockMailSession('open-read-relaunch');
      await render(
        <AssistanceContext value={mock.assistance}>
          <App drafts={createDrafts(storage.native, registration)} />
        </AssistanceContext>,
      );
      await press('New Message');
      const page = simulatedPage();
      await page.typed('A changed message');
      await press('Close');
      await press('Cancel');
      expect(screen.getByRole('button', { name: 'Send' })).toBeOnTheScreen();
      expectRetiringControl('Save');
      await motion.finish();
      expect(
        screen.queryByRole('button', {
          name: 'Save',
          includeHiddenElements: true,
        }),
      ).toBeNull();
      await press('Close');
      expect(screen.getByRole('button', { name: 'Save' })).toBeOnTheScreen();
      await press('Cancel');
      await press('Writing tools');
      await press('Close', false);
      expectRetiringControl('Rewrite the message body');
      await motion.finish();
      expect(
        screen.queryByRole('button', {
          name: 'Rewrite the message body',
          includeHiddenElements: true,
        }),
      ).toBeNull();
      await page.report({ frozen: true });
      expect(screen.getByRole('button', { name: 'Save' })).toBeOnTheScreen();
    } finally {
      motion.restore();
    }
  });

  it('asks before Command-W closes a window with unsaved edits', async () => {
    expect.hasAssertions();
    // Substitute only the native menu boundary that Command-W and Quit reach.
    const menu: TurboModule &
      Readonly<{
        addListener: () => void;
        removeListeners: () => void;
        saveFocus: () => void;
        restoreFocus: () => void;
        guardClose: ReturnType<typeof jest.fn>;
        finishClose: ReturnType<typeof jest.fn>;
      }> = {
      addListener: () => undefined,
      removeListeners: () => undefined,
      saveFocus: () => undefined,
      restoreFocus: () => undefined,
      guardClose: jest.fn(),
      finishClose: jest.fn(),
    };
    const registry = commandModule(menu);
    try {
      const storage = createSyntheticDrafts(() => 'synthetic-product-account');
      const drafts = createDrafts(storage.native, registration);
      await render(<App drafts={drafts} />);
      await press('New Message');
      await simulatedPage().typed('Keep this Draft');
      expect(menu.guardClose).toHaveBeenLastCalledWith('inbox-window-', true);
      const closeWindow = async () => {
        await act(async () => {
          DeviceEventEmitter.emit('windowShouldClose', {
            window: 'inbox-window-',
          });
        });
      };
      await act(async () => {
        DeviceEventEmitter.emit('windowShouldClose', {
          window: 'inbox-window-other',
        });
      });
      expect({
        save: screen.queryByRole('button', { name: 'Save' }),
        answers: menu.finishClose.mock.calls,
      }).toStrictEqual({ save: null, answers: [] });
      // The window stays open while the save question is answered.
      await closeWindow();
      await simulatedPage().report({ frozen: true });
      // A repeated native request (including Quit during Command-W) keeps the same choice.
      await closeWindow();
      expect(menu.finishClose).not.toHaveBeenCalled();
      await press('Cancel');
      await waitFor(() => {
        expect(menu.finishClose).toHaveBeenLastCalledWith(
          'inbox-window-',
          false,
        );
      });
      menu.finishClose.mockClear();
      await closeWindow();
      await simulatedPage().report({ frozen: true });
      storage.setLocked(true);
      await press('Save');
      await waitFor(() => {
        expect(menu.finishClose).toHaveBeenLastCalledWith(
          'inbox-window-',
          false,
        );
      });
      storage.setLocked(false);
      menu.finishClose.mockClear();
      await closeWindow();
      await simulatedPage().report({ frozen: true });
      await press('Save');
      await waitFor(() => {
        expect(menu.finishClose).toHaveBeenCalledWith('inbox-window-', true);
      });
      expect(draftsOf(drafts.getSnapshot())[0]?.body).toStrictEqual([
        { kind: 'paragraph', spans: [{ text: 'Keep this Draft' }] },
      ]);
      expect(menu.guardClose).toHaveBeenLastCalledWith('inbox-window-', false);
    } finally {
      registry.mockRestore();
    }
  });
});
