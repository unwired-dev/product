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
const catalogWith = (offered: readonly object[]) =>
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
    autorun: null,
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
    golden: jest.fn(() => Promise.resolve('')),
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
    await settle(pending, 'classify-1', classified);
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
    await settle(pending, 'classify-1', '{"scores": "not a result"}');
    expect(screen.queryByText(/RESULT/u)).toBeNull();
    expect(screen.getByText(/could not run on this Mac/u)).toBeVisible();
  });

  it('cancels a running request without showing a partial result', async () => {
    expect.hasAssertions();
    const { module, pending } = scriptedSpike();
    await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    await fireEvent.press(screen.getByText('Cancel'));
    await settle(pending, 'classify-1', classified);
    expect(module.cancel).toHaveBeenCalledWith('classify-1');
    expect(
      screen.getByText(/Cancelled before the next model pass/u),
    ).toBeVisible();
    expect(screen.queryByText(/RESULT/u)).toBeNull();
  });

  it('cancels the running request and releases the model on dismissal', async () => {
    expect.hasAssertions();
    const { module } = scriptedSpike();
    const view = await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    await view.unmount();
    expect(module.cancel).toHaveBeenLastCalledWith('classify-1');
    // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
    expect(module.release).toHaveBeenCalledTimes(1);
  });
});
