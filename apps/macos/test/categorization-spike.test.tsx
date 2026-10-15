import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { TurboModuleRegistry } from 'react-native';

import { CategorizationSpike } from '../src/categorization-spike-page.tsx';

const candidates = [
  {
    run: 'deberta-xsmall-body256',
    mode: 'system',
    maxLength: 256,
    precisions: ['fp16', 'int8'],
  },
];
const catalogWith = (
  offered: readonly object[],
  autorun: string | null = null,
) =>
  JSON.stringify({
    candidates: offered,
    messages: [
      {
        id: 'synthetic:en-overlap-orders-flights-2:4',
        language: 'en',
        subject: 'Your change fee receipt',
      },
    ],
    categories: [],
    host: { model: 'Mac16,10', os: 'Version 27.0.1' },
    evidence: '/tmp/categorization-spike.jsonl',
    autorun,
  });
const catalog = catalogWith(candidates);

const process = {
  peakFootprintMB: 412,
  energyMillijoules: 1200,
  thermalBefore: 'nominal',
  thermalAfter: 'nominal',
  mainThreadLagMs: { p50: 1, p95: 2, max: 3, samples: 9 },
};

const classified = JSON.stringify({
  loadMs: 1240,
  process,
  input:
    'From: Harbor Air <noreply@harborair.example>\nSubject: Your change fee receipt',
  classification: {
    message: 'synthetic:en-overlap-orders-flights-2:4',
    scores: [
      { category: 'Orders', probability: 0.41, threshold: 0.4, member: true },
      { category: 'Invites', probability: 0.04, threshold: 0.1, member: false },
      { category: 'Flights', probability: 0.88, threshold: 0.15, member: true },
    ],
    categories: ['Orders', 'Flights'],
    tokens: [62],
    passes: 1,
    milliseconds: [12.6],
  },
});

type Deferred = Readonly<{
  resolve: (text: string) => void;
  reject: (error: unknown) => void;
}>;

// A scripted native module: each classification waits until the test settles it.
function scriptedSpike(catalogText = catalog) {
  const pending = new Map<string, Deferred>();
  const module = {
    catalog: jest.fn(() => Promise.resolve(catalogText)),
    classify: jest.fn(
      (request: string, _body: string) =>
        // oxlint-disable-next-line promise/avoid-new -- Hold the native answer until the test settles it.
        new Promise<string>((resolve, reject) => {
          pending.set(request, { resolve, reject });
        }),
    ),
    benchmark: jest.fn(() => Promise.resolve('')),
    golden: jest.fn(
      (request: string, _body: string) =>
        // oxlint-disable-next-line promise/avoid-new -- Hold the unattended native action across dismissal.
        new Promise<string>((resolve, reject) => {
          pending.set(request, { resolve, reject });
        }),
    ),
    computePlan: jest.fn(() => Promise.resolve('')),
    progress: jest.fn(() => Promise.resolve(null)),
    cancel: jest.fn((request: string) => {
      pending.get(request)?.reject({ code: 'cancelled' });
      return Promise.resolve();
    }),
    release: jest.fn(() => Promise.resolve(null)),
    getConstants: () => ({}),
  };
  return { module, pending };
}

async function renderWith(module: object | null) {
  const original = TurboModuleRegistry.get.bind(TurboModuleRegistry);
  const get = jest
    .spyOn(TurboModuleRegistry, 'get')
    .mockImplementation((name: string) =>
      name === 'UnwiredCategorizationSpike' ? module : original(name),
    );
  const view = await render(<CategorizationSpike />);
  await act(async () => {
    await Promise.resolve();
  });
  get.mockRestore();
  return view;
}

function requestAt(pending: ReadonlyMap<string, Deferred>, index: number) {
  const request = [...pending.keys()][index];
  if (request === undefined) {
    throw new Error('The action did not start a native request');
  }
  return request;
}

async function settle(
  pending: ReadonlyMap<string, Deferred>,
  request: string,
  text: string,
) {
  await act(async () => {
    pending.get(request)?.resolve(text);
    await Promise.resolve();
  });
}

describe('categorization spike page', () => {
  it('shows the unavailable state, without any fallback, when the build has no models', async () => {
    expect.hasAssertions();
    await renderWith(null);
    expect(screen.getByText(/No exported models in this build/u)).toBeVisible();
    expect(screen.queryByText('Classify')).toBeNull();
    await renderWith(scriptedSpike(catalogWith([])).module);
    expect(screen.getByText(/No exported models in this build/u)).toBeVisible();
    expect(screen.queryByText('Classify')).toBeNull();
  });

  it('sends the selected candidate and shows decoded scores and memberships', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike();
    await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    expect(module.classify.mock.calls[0]?.[1]).toBe(
      '{"run":"deberta-xsmall-body256","precision":"fp16","units":"all","message":"synthetic:en-overlap-orders-flights-2:4","rounds":3,"categoryCount":0}',
    );
    await settle(pending, requestAt(pending, 0), classified);
    expect(screen.getByText('RESULT · ORDERS AND FLIGHTS')).toBeVisible();
    expect(screen.getByLabelText('Member, 0.41, threshold 0.4')).toBeVisible();
    expect(
      screen.getByLabelText('Not a member, 0.04, threshold 0.1'),
    ).toBeVisible();
  });

  it('fails closed on a malformed native result', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike();
    await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    await settle(pending, requestAt(pending, 0), '{"scores": "not a result"}');
    expect(screen.queryByText(/RESULT/u)).toBeNull();
    expect(screen.getByText(/could not run on this Mac/u)).toBeVisible();
  });

  it('cancels a running request without showing a partial result', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike();
    await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    await fireEvent.press(screen.getByText('Cancel'));
    await settle(pending, requestAt(pending, 0), classified);
    expect(module.cancel).toHaveBeenCalledWith([...pending.keys()][0]);
    expect(
      screen.getByText(/Cancelled before the next model pass/u),
    ).toBeVisible();
    expect(screen.queryByText(/RESULT/u)).toBeNull();
  });

  it('cancels the running request and releases the model on dismissal', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike();
    const view = await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    await view.unmount();
    expect(module.cancel).toHaveBeenLastCalledWith([...pending.keys()][0]);
    // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
    expect(module.release).toHaveBeenCalledTimes(1);
  });

  it('retires the displayed result when a selector changes', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike();
    await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    await settle(pending, requestAt(pending, 0), classified);
    expect(screen.getByText('RESULT · ORDERS AND FLIGHTS')).toBeVisible();
    await fireEvent.press(screen.getByRole('button', { name: 'Precision' }));
    await fireEvent.press(screen.getByText('INT8'));
    expect(screen.queryByText('RESULT · ORDERS AND FLIGHTS')).toBeNull();
  });

  it('rejects a result that won the native race with Cancel', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike();
    module.cancel.mockResolvedValue(undefined);
    await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    await fireEvent.press(screen.getByText('Cancel'));
    await settle(pending, requestAt(pending, 0), classified);
    expect(screen.queryByText('RESULT · ORDERS AND FLIGHTS')).toBeNull();
    expect(
      screen.getByText(/Cancelled before the next model pass/u),
    ).toBeVisible();
  });

  it('keeps requests distinct across windows and page remounts', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike();
    const first = await renderWith(module);
    await fireEvent.press(first.getByText('Classify'));
    const oldRequest = requestAt(pending, 0);
    const second = await renderWith(module);
    await fireEvent.press(second.getByText('Classify'));
    await first.unmount();
    expect(module.cancel).toHaveBeenLastCalledWith(oldRequest);
    const otherRequest = requestAt(pending, 1);
    expect(otherRequest).not.toBe(oldRequest);
    await settle(pending, otherRequest, classified);
    expect(second.getByText('RESULT · ORDERS AND FLIGHTS')).toBeVisible();
    const reopened = await renderWith(module);
    await fireEvent.press(reopened.getByText('Classify'));
    expect(new Set(pending.keys()).size).toBe(3);
  });

  it('does not continue an unattended matrix after dismissal', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike(
      catalogWith(candidates, 'matrix'),
    );
    module.cancel.mockResolvedValue(undefined);
    const view = await renderWith(module);
    expect(module.golden).toHaveBeenCalledWith(
      expect.any(String),
      expect.any(String),
    );
    await view.unmount();
    await settle(pending, requestAt(pending, 0), classified);
    expect(module.classify).not.toHaveBeenCalled();
    expect(module.benchmark).not.toHaveBeenCalled();
    expect(module.computePlan).not.toHaveBeenCalled();
  });
});
