import { act, fireEvent, render, screen } from '@testing-library/react-native';
import { TurboModuleRegistry } from 'react-native';

import { CategorizationSpike } from '../src/categorization-spike-page.tsx';

const catalog = JSON.stringify({
  candidates: [
    {
      run: 'deberta-xsmall-body256',
      mode: 'system',
      maxLength: 256,
      precisions: ['fp16', 'int8'],
    },
  ],
  messages: [
    {
      id: 'synthetic:en-overlap-orders-flights-2:4',
      language: 'en',
      subject: 'Your change fee receipt',
    },
  ],
  categories: [],
  host: { model: 'iPhone18,2', os: 'Version 27.0.1' },
  evidence: '/tmp/categorization-spike.jsonl',
  autorun: null,
});

const classified = JSON.stringify({
  loadMs: 1240,
  process: {
    peakFootprintMB: 412,
    energyMillijoules: 1200,
    thermalBefore: 'nominal',
    thermalAfter: 'nominal',
    mainThreadLagMs: { p50: 1, p95: 2, max: 3, samples: 9 },
  },
  input: 'Subject: Your change fee receipt',
  classification: {
    message: 'synthetic:en-overlap-orders-flights-2:4',
    scores: [
      { category: 'Orders', probability: 0.41, threshold: 0.4, member: true },
      { category: 'Invites', probability: 0.04, threshold: 0.1, member: false },
    ],
    categories: ['Orders'],
    tokens: [62],
    passes: 1,
    milliseconds: [12.6],
  },
});

// A native module whose classification and benchmark wait until the test answers it.
function scriptedSpike() {
  const answers = new Map<string, (text: string) => void>();
  const held = (request: string, _body: string) =>
    // oxlint-disable-next-line promise/avoid-new -- Hold the native answer until the test settles it.
    new Promise<string>((resolve) => {
      answers.set(request, resolve);
    });
  const module = {
    catalog: jest.fn(() => Promise.resolve(catalog)),
    classify: jest.fn(held),
    benchmark: jest.fn(held),
    golden: jest.fn(() => Promise.resolve('')),
    computePlan: jest.fn(() => Promise.resolve('')),
    progress: jest.fn(() => Promise.resolve(null)),
    cancel: jest.fn(() => Promise.resolve()),
    release: jest.fn(() => Promise.resolve(null)),
    getConstants: () => ({}),
  };
  return { module, answers };
}

async function renderWith(module: object | null) {
  const original = TurboModuleRegistry.get.bind(TurboModuleRegistry);
  jest
    .spyOn(TurboModuleRegistry, 'get')
    .mockImplementation((name: string) =>
      name === 'UnwiredCategorizationSpike' ? module : original(name),
    );
  const view = await render(<CategorizationSpike compact />);
  await act(async () => {
    await Promise.resolve();
  });
  return view;
}

describe('iPhone and iPad categorization spike page', () => {
  it('stays unavailable, without any fallback, when the build has no models', async () => {
    expect.hasAssertions();
    await renderWith(null);
    expect(screen.getByText('No exported models in this build')).toBeVisible();
    expect(
      screen.getByText(/stays unavailable on this iPhone; it has no server/u),
    ).toBeVisible();
    expect(screen.queryByText('Classify')).toBeNull();
  });

  it('shows the scores and memberships, and leaving cancels and releases the model', async () => {
    expect.hasAssertions();
    const { module, answers } = scriptedSpike();
    const view = await renderWith(module);
    await fireEvent.press(screen.getByText('Classify'));
    const [classify] = answers.values();
    await act(async () => {
      classify?.(classified);
      await Promise.resolve();
    });
    expect(screen.getByText('Result · Orders')).toBeVisible();
    expect(screen.getByText('Above threshold 0.40')).toBeVisible();
    expect(screen.getByText('Below threshold 0.10')).toBeVisible();

    await fireEvent.press(screen.getByText('Benchmark'));
    const [, benchmark] = answers.keys();
    await view.unmount();
    expect(module.cancel).toHaveBeenCalledWith(benchmark);
    // oxlint-disable-next-line vitest/prefer-called-once -- Jest has no toHaveBeenCalledOnce matcher.
    expect(module.release).toHaveBeenCalledTimes(1);
  });
});
