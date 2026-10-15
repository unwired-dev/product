import { ok } from 'node:assert/strict';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
import { createMockMailSession } from '@private-email/mail-core/testing/mock-session';
import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { Animated } from 'react-native';

import { ComposerLayoutContext } from '../src/composer.tsx';
import { AssistanceContext } from '../src/message-summary.tsx';
import { App, registration } from './evaluation-app.tsx';
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

  it.each([
    {
      size: 'compact',
      menus: [
        ['Close', 'Save Draft', 'Close'],
        ['Add files', 'Attach File', 'Add files'],
        ['Writing tools', 'Rewrite the message body', 'Writing tools'],
        ['Format', 'Close Format', 'Close Format'],
      ],
    },
    {
      size: 'regular',
      menus: [
        ['Close', 'Save Draft', 'Close'],
        ['Writing tools', 'Rewrite the message body', 'Writing tools'],
      ],
    },
  ] as const)(
    'keeps dismissed $size panels mounted, hidden and untouchable until their exit ends',
    async ({ size, menus }) => {
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
        const menu = menus.at(-1);
        ok(menu, 'Expected a menu');
        const [trigger, action] = menu;
        await press(trigger);
        await press('Close', false);
        expectRetiringControl(action);
        await motion.finish();
        expect(
          screen.queryByRole('button', {
            name: action,
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
