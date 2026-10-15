import { ok } from 'node:assert/strict';

import { createDrafts, draftsOf } from '@private-email/mail-core/drafts';
import { createSyntheticDrafts } from '@private-email/mail-core/testing/drafts';
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

import { AssistanceContext } from '../src/message-summary.tsx';
import { App, registration } from './evaluation-app.tsx';
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
});
