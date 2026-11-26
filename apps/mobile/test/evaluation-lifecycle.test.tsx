import { ok } from 'node:assert/strict';

import {
  createDrafts,
  draftOf,
  draftsOf,
} from '@private-email/mail-core/drafts';
import {
  createSyntheticDrafts,
  createSyntheticProductSync,
} from '@private-email/mail-core/testing/drafts';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react-native';
import { Animated } from 'react-native';

import type { useComposerNavigation } from '../src/mailbox.tsx';

import { ComposerLayoutContext } from '../src/composer.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { alex, App, registration } from './evaluation-app.tsx';
import { press, simulatedPage } from './evaluation-page.ts';

// oxlint-disable-next-line vitest/prefer-import-in-mock -- Jest requires a module name, not a dynamic import.
jest.mock('react-native-screens/experimental', () => ({
  SafeAreaView: jest.requireActual('react-native').View,
}));
// oxlint-disable-next-line vitest/prefer-import-in-mock -- The Inbox's keyboard avoidance reads the inset; the host has none here.
jest.mock('react-native-safe-area-context', () => ({
  useSafeAreaInsets: () => ({ top: 0, left: 0, right: 0, bottom: 0 }),
}));
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

describe('evaluation composer lifetime', () => {
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

  it('journals unsaved edits and restores them in the page (#2944)', async () => {
    expect.hasAssertions();
    const storage = createSyntheticDrafts(() => 'synthetic-product-account');
    const drafts = createDrafts(storage.native, registration);
    const first = await render(<App drafts={drafts} />);
    await press('New Message');
    await fireEvent.changeText(
      screen.getByLabelText('Subject'),
      'Unsaved plan',
    );
    await simulatedPage().typed('Typed before the app ended');
    // A few seconds after the edits, the editor journals them without storing the Draft.
    await waitFor(
      () => {
        expect(storage.recoveryRecords().size).toBe(1);
      },
      { timeout: 4000 },
    );
    // The app ends without Close.
    await first.unmount();
    const reopened = createDrafts(storage.native, registration);
    await reopened.load();
    const records = await reopened.recovered();
    ok(records, 'Expected storage to read the recovery records');
    const [record] = records;
    ok(record?.base, 'Expected a recovery record with its stored version');
    expect(record.base.subject).toBe('');
    // Restore, as the launch's offer answers it, opens the page on the recovered edits.
    reopened.take(record.version.id);
    await render(
      <App
        drafts={reopened}
        restore={{ version: record.version, base: record.base }}
      />,
    );
    expect(
      screen.getByTestId('message-webview').props
        .injectedJavaScriptBeforeContentLoaded,
    ).toContain('"spans":[{"text":"Typed before the app ended"}]');
    expect(screen.getByLabelText('Subject')).toHaveProp(
      'value',
      'Unsaved plan',
    );
    // Close asks to save them, and Save Draft stores them and removes the record.
    await simulatedPage().report({});
    await press('Close');
    await press('Save Draft');
    await waitFor(() => {
      expect(storage.recoveryRecords().size).toBe(0);
    });
    expect(draftsOf(reopened.getSnapshot())).toMatchObject([
      {
        subject: 'Unsaved plan',
        body: [
          {
            kind: 'paragraph',
            spans: [{ text: 'Typed before the app ended' }],
          },
        ],
      },
    ]);
  }, 15_000);

  it('saves a restored page into its copy when Product Sync moves the Draft (#2944)', async () => {
    expect.hasAssertions();
    const account = () => 'synthetic-product-account';
    const server = createSyntheticProductSync();
    const here = createSyntheticDrafts(account, { server, device: 'here' });
    const there = createSyntheticDrafts(account, { server, device: 'there' });
    ok(here.sync);
    ok(there.sync);
    const options = { native: here.sync, delay: 60_000 };
    const phone = createDrafts(here.native, registration, options);
    const remote = createDrafts(there.native, registration, {
      native: there.sync,
      delay: 60_000,
    });
    await phone.load();
    const id = await phone.create({
      id: alex,
      address: 'alex@example.invalid',
    });
    ok(id);
    await phone.sync();
    await remote.load();
    await remote.sync();
    const before = draftOf(phone.getSnapshot(), id);
    const remoteBefore = draftOf(remote.getSnapshot(), id);
    ok(before);
    ok(remoteBefore);
    // Another device changes the Draft while this one, offline, stores and journals its own edits.
    await remote.update({ ...remoteBefore, subject: 'Remote' }, remoteBefore);
    await remote.sync();
    server.setReachable(false);
    await phone.update({ ...before, subject: 'Stored locally' }, before);
    const base = draftOf(phone.getSnapshot(), id);
    ok(base);
    expect(
      await phone.journal({ ...base, subject: 'Recovered edit' }, base),
    ).toBe(true);
    const reopened = createDrafts(here.native, registration, options);
    await reopened.load();
    await reopened.sync();
    const [recovered] = (await reopened.recovered()) ?? [];
    ok(recovered?.base);
    reopened.take(id);
    await render(
      <App
        drafts={reopened}
        restore={{ version: recovered.version, base: recovered.base }}
      />,
    );
    // Product Sync moves the stored version to a conflicting copy, and the restored page follows it.
    server.setReachable(true);
    await act(async () => {
      await reopened.sync();
    });
    const copy = draftsOf(reopened.getSnapshot()).find(
      (draft) => draft.subject === 'Stored locally',
    );
    ok(copy?.conflict);
    await press('Close');
    await press('Save Draft');
    await waitFor(() => {
      expect(screen.queryByTestId('message-webview')).toBeNull();
    });
    expect(
      draftsOf(reopened.getSnapshot()).map((draft) => ({
        id: draft.id,
        subject: draft.subject,
      })),
    ).toStrictEqual(
      expect.arrayContaining([
        { id: copy.id, subject: 'Recovered edit' },
        { id, subject: 'Remote' },
      ]),
    );
    expect(draftsOf(reopened.getSnapshot())).toHaveLength(2);
  }, 15_000);

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
    await press('Keep Editing');
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
    await press('Save Draft');
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
    await press('Save Draft');
    await screen.findByText(/This Draft could not be saved/u);
    storage.setLocked(false);
    await other.update({ ...before, subject: 'Other writer' }, before);
    storage.hold();
    await press('Close');
    await press('Delete Draft');
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
    await press('Save Draft');
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

  it.each([
    {
      size: 'compact',
      menus: [
        ['Close', 'Save Draft', 'Keep Editing'],
        ['Format', 'Close Format', 'Close Format'],
      ],
      // The Format panel stays open as the header finishes.
      finishing: { opens: ['Format'], control: 'Close Format' },
    },
    {
      size: 'regular',
      menus: [['Close', 'Save Draft', 'Keep Editing']],
      finishing: { opens: [], control: 'Italic' },
    },
  ] as const)(
    'keeps dismissed $size panels mounted, hidden and untouchable until their exit ends',
    async ({ size, menus, finishing }) => {
      expect.hasAssertions();
      const motion = holdMenuMotion();
      try {
        const mock = createMockMailSession('open-read-relaunch');
        const storage = createSyntheticDrafts(
          () => 'synthetic-product-account',
        );
        await render(
          <ComposerLayoutContext value={{ size, avoidKeyboard: false, top: 0 }}>
            <AssistanceContext value={mock.assistance}>
              <App drafts={createDrafts(storage.native, registration)} />
            </AssistanceContext>
          </ComposerLayoutContext>,
        );
        await press('New Message');
        const page = simulatedPage();
        await page.typed('A changed message');
        for (const [trigger, action, dismiss] of menus) {
          await press(trigger);
          expect(
            screen.getByRole('button', { name: action }),
          ).toBeOnTheScreen();
          await press(dismiss);
          expectRetiringControl(action);
          await motion.finish();
          expect(
            screen.queryByRole('button', {
              name: action,
              includeHiddenElements: true,
            }),
          ).toBeNull();
        }
        // Header finishing must retain the containing controls as well as the panel itself.
        for (const trigger of finishing.opens) {
          await press(trigger);
        }
        await press('Close', false);
        expectRetiringControl(finishing.control);
        await motion.finish();
        expect(
          screen.queryByRole('button', {
            name: finishing.control,
            includeHiddenElements: true,
          }),
        ).toBeNull();
        await page.report({ frozen: true });
        expect(
          screen.getByRole('button', { name: 'Save Draft' }),
        ).toBeOnTheScreen();
      } finally {
        motion.restore();
      }
    },
  );
});
