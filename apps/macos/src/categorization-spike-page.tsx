import type { TurboModule } from 'react-native';

import { radius, spacing } from '@private-email/mail-core/theme';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ScrollView,
  StyleSheet,
  TurboModuleRegistry,
  View,
} from 'react-native';

import type {
  CatalogValue,
  ClassificationValue,
  ProgressValue,
  ResultValue,
} from './categorization-spike-client.ts';

import {
  decodeCatalog,
  decodeProgress,
  decodeResult,
  failureText,
  median,
  unavailable,
} from './categorization-spike-client.ts';
import { PopUp } from './composer-controls.tsx';
import { Button, Notice } from './design.tsx';
import { Label } from './label.tsx';
import { SettingsGroup, SettingsRow } from './settings.tsx';
import { textStyles, usePalette } from './theme.ts';

// Spike #831, compiled only into the `categorization-spike` Mock Mail Session build: classifies
// bundled public and synthetic samples with the frozen DeBERTa candidates through Core ML on this
// Mac. It reads no mailbox, changes no assignment and has no server fallback. Its research copy
// stays English and outside the localization catalogs because the page never ships.

interface SpikeModule extends TurboModule {
  readonly catalog: () => Promise<string>;
  readonly classify: (request: string, body: string) => Promise<string>;
  readonly benchmark: (request: string, body: string) => Promise<string>;
  readonly golden: (request: string, body: string) => Promise<string>;
  readonly computePlan: (request: string, body: string) => Promise<string>;
  readonly progress: (request: string) => Promise<unknown>;
  readonly cancel: (request: string) => Promise<void>;
  readonly release: () => Promise<unknown>;
}

const units = [
  ['all', 'CPU, GPU and Neural Engine'],
  ['cpuAndGPU', 'CPU and GPU'],
  ['cpuAndNeuralEngine', 'CPU and Neural Engine'],
  ['cpuOnly', 'CPU only'],
] as const;
type Unit = (typeof units)[number][0];
// The six Custom Categories with golden outputs (custom_report.py GOLDEN_CATEGORIES).
const goldenCategories = [
  'online-purchases',
  'flights-booked',
  'statements',
  'kids-school',
  'event-invitations',
  'family-friends',
];
const categoryCounts = [6, 5, 20, 50] as const;
type CategoryCount = (typeof categoryCounts)[number];
const rounds = 3;
// All Mac windows share this runtime, so identities survive page remounts too.
let requests = 0;
const styles = StyleSheet.create({
  content: {
    paddingHorizontal: 40,
    paddingTop: 72,
    paddingBottom: 96,
    gap: 10,
  },
  actions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.s },
  progress: { gap: spacing.s, padding: spacing.m, borderRadius: radius.card },
  track: { height: 4, borderRadius: 2, overflow: 'hidden' },
  bar: { height: 4 },
  start: { alignSelf: 'flex-start' },
  // Long choices truncate inside the pop-up instead of squeezing the row's title.
  pick: { flexShrink: 1, maxWidth: 220 },
});

type Kind = 'classify' | 'benchmark' | 'golden' | 'plan';
type Busy = Readonly<{ request: string; kind: Kind }>;
type Choice = readonly [string, string];
type Selection = Readonly<{
  run: string;
  precision: 'fp16' | 'int8';
  unit: Unit;
  message: string;
  count: CategoryCount;
}>;

const ms = (value: number) => `${value.toFixed(value < 10 ? 1 : 0)} ms`;

const probability = (value: number) => value.toFixed(value < 0.01 ? 3 : 2);
const candidateName = (run: string) => {
  const model = run.includes('mdeberta')
    ? 'mDeBERTa v3 Base'
    : 'DeBERTa v3 XSmall';
  return run.includes('adapted')
    ? `Custom · adapted ${model}`
    : `System · ${model}`;
};
const categoryName = (catalog: CatalogValue, language: string, id: string) => {
  const found = catalog.categories.find((each) => each.id === id);
  if (found === undefined) {
    return id;
  }
  return (language === 'cs' ? found.cs : found.en).name;
};

// The request body for one bridge call: the golden categories when they are selected, otherwise
// the first `count` Custom Categories.
const requestBody = (selection: Selection & Readonly<{ custom: boolean }>) => {
  const categories =
    selection.custom && selection.count === 6
      ? { categories: goldenCategories }
      : { categoryCount: selection.custom ? selection.count : 0 };
  return JSON.stringify({
    run: selection.run,
    precision: selection.precision,
    units: selection.unit,
    message: selection.message,
    rounds,
    ...categories,
  });
};

const pause = (seconds: number) =>
  // oxlint-disable-next-line promise/avoid-new -- Hold each state long enough to capture it.
  new Promise<void>((resolve) => {
    setTimeout(resolve, seconds * 1000);
  });

type Autorun = Readonly<{
  start: (kind: Kind, picked: Selection) => Promise<void>;
  cancel: () => void;
  dismiss: () => void;
}>;

const systemSmall = 'deberta-xsmall-body256';
const systemBase = 'deberta-mdeberta-body512';
const customSmall = 'xsmall-zs-adapted-body256-description';
const customBase = 'mdeberta-nli-adapted-body256-description';

// The design states in order: a System result, an Uncategorized Custom result, a benchmark that
// Cancel stops, and a benchmark that dismissal stops.
async function autorunStates(catalog: CatalogValue, actions: Autorun) {
  const message =
    catalog.messages.find((each) => each.subject === 'Your change fee receipt')
      ?.id ?? '';
  const base: Selection = {
    run: systemSmall,
    precision: 'fp16',
    unit: 'all',
    message,
    count: 6,
  };
  await actions.start('classify', base);
  await pause(15);
  await actions.start('classify', {
    ...base,
    run: customSmall,
    precision: 'int8',
    unit: 'cpuAndNeuralEngine',
  });
  await pause(15);
  const cancelled = actions.start('benchmark', {
    ...base,
    run: customBase,
    count: 20,
  });
  await pause(20);
  actions.cancel();
  await cancelled;
  await pause(15);
  void actions.start('benchmark', { ...base, run: customBase, count: 50 });
  await pause(20);
  actions.dismiss();
}

// Every candidate and precision: golden outputs, a classification and benchmarks (Custom
// Category counts 5, 20 and 50), compute plans, then the compute-unit comparison.
async function autorunMatrix(catalog: CatalogValue, actions: Autorun) {
  const base: Selection = {
    run: systemSmall,
    precision: 'fp16',
    unit: 'all',
    message: catalog.messages[0]?.id ?? '',
    count: 6,
  };
  for (const run of [systemSmall, systemBase, customSmall, customBase]) {
    const counts: CategoryCount[] = run.includes('adapted') ? [5, 20, 50] : [6];
    for (const precision of ['fp16', 'int8'] as const) {
      const picked = { ...base, run, precision };
      await actions.start('golden', picked);
      await actions.start('classify', picked);
      for (const count of counts) {
        await actions.start('benchmark', { ...picked, count });
      }
    }
    for (const unit of ['all', 'cpuAndNeuralEngine'] as const) {
      await actions.start('plan', { ...base, run, unit });
    }
  }
  for (const unit of ['cpuOnly', 'cpuAndGPU', 'cpuAndNeuralEngine'] as const) {
    await actions.start('benchmark', { ...base, unit });
  }
}

const call = (module: SpikeModule, kind: Kind) =>
  ({
    classify: module.classify,
    benchmark: module.benchmark,
    golden: module.golden,
    plan: module.computePlan,
  })[kind];

export function CategorizationSpike() {
  const native = useMemo(
    () => TurboModuleRegistry.get<SpikeModule>('UnwiredCategorizationSpike'),
    [],
  );
  const [catalog, setCatalog] = useState<
    CatalogValue | 'loading' | 'unavailable'
  >(native === null ? 'unavailable' : 'loading');

  useEffect(() => {
    if (native === null) {
      return undefined;
    }
    const load = async () => {
      try {
        const decoded = decodeCatalog(await native.catalog());
        setCatalog(
          decoded !== undefined && decoded.candidates.length > 0
            ? decoded
            : 'unavailable',
        );
      } catch {
        setCatalog('unavailable');
      }
    };
    void load();
    return undefined;
  }, [native]);
  const [dismissed, setDismissed] = useState(false);

  if (catalog === 'loading') {
    return null;
  }
  let page = null;
  if (catalog === 'unavailable' || native === null) {
    page = <Unavailable />;
  } else if (!dismissed) {
    page = (
      <Spike
        catalog={catalog}
        module={native}
        onDismiss={() => {
          setDismissed(true);
        }}
      />
    );
  }
  return (
    <ScrollView contentContainerStyle={styles.content}>
      <Header />
      {page}
    </ScrollView>
  );
}

function Spike({
  catalog,
  module,
  onDismiss,
}: {
  readonly catalog: CatalogValue;
  readonly module: SpikeModule;
  // Unmounts the page as closing the window would; only the unattended run uses it.
  readonly onDismiss: () => void;
}) {
  const colors = usePalette();
  const [selection, setSelection] = useState<Selection>({
    run: catalog.candidates[0]?.run ?? '',
    precision: 'fp16',
    unit: 'all',
    message: catalog.messages[0]?.id ?? '',
    count: 6,
  });
  const [busy, setBusy] = useState<Busy>();
  const [result, setResult] = useState<ResultValue>();
  const [failure, setFailure] = useState<string>();
  const current = useRef<string>(undefined);
  const mounted = useRef(true);
  const cancelled = useRef<string>(undefined);
  const candidate = catalog.candidates.find(
    (each) => each.run === selection.run,
  );
  const sample = catalog.messages.find((each) => each.id === selection.message);

  // Dismissal stops the running request before its next model pass and releases the model.
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      const request = current.current;
      current.current = undefined;
      if (request !== undefined) {
        void module.cancel(request);
      }
      void module.release();
    };
  }, [module]);

  const cancel = useCallback(() => {
    const request = current.current;
    if (request !== undefined) {
      cancelled.current = request;
      void module.cancel(request);
      void module.release();
    }
  }, [module]);

  const start = useCallback(
    async (kind: Kind, picked: Selection) => {
      if (!mounted.current) {
        return;
      }
      setSelection(picked);
      requests += 1;
      const request = `${kind}-${requests}`;
      current.current = request;
      setBusy({ request, kind });
      setFailure(undefined);
      setResult(undefined);
      const body = requestBody({
        ...picked,
        custom:
          catalog.candidates.find((each) => each.run === picked.run)?.mode ===
          'custom',
      });
      let text: string | undefined = undefined;
      try {
        text = await call(module, kind)(request, body);
      } catch (error) {
        if (current.current === request) {
          setFailure(failureText(error));
        }
      }
      if (current.current !== request) {
        return;
      }
      current.current = undefined;
      setBusy(undefined);
      if (cancelled.current === request) {
        setFailure(failureText({ code: 'cancelled' }));
        return;
      }
      if (text !== undefined) {
        const decoded = decodeResult(text);
        if (decoded === undefined) {
          setFailure(unavailable);
        } else {
          setResult(decoded);
        }
      }
    },
    [catalog, module],
  );

  // An unattended run, selected at launch for hosts without UI automation, through the same
  // actions as the buttons. It starts once; later renders only refresh the effect's inputs.
  const autorunStarted = useRef(false);
  useEffect(() => {
    if (autorunStarted.current || catalog.autorun === null) {
      return;
    }
    autorunStarted.current = true;
    const actions: Autorun = {
      start,
      cancel,
      dismiss: () => {
        if (mounted.current) {
          onDismiss();
        }
      },
    };
    void (catalog.autorun === 'states'
      ? autorunStates(catalog, actions)
      : autorunMatrix(catalog, actions));
  }, [cancel, catalog, onDismiss, start]);

  return (
    <>
      <Setup
        selection={selection}
        onChange={(picked) => {
          setSelection(picked);
          setResult(undefined);
          setFailure(undefined);
        }}
        catalog={catalog}
        disabled={busy !== undefined}
      />
      {busy?.kind === 'benchmark' ? (
        <BenchmarkProgress
          module={module}
          request={busy.request}
          samples={catalog.messages.length}
          onCancel={cancel}
        />
      ) : (
        <Actions
          busy={busy}
          onStart={(kind) => {
            void start(kind, selection);
          }}
          onCancel={cancel}
        />
      )}
      {failure === undefined ? null : (
        <Notice
          icon="exclamationmark.triangle.fill"
          iconColor={colors.statusWarning}
          message={failure}
          messageRole="alert"
        />
      )}
      {result === undefined || sample === undefined ? null : (
        <Outcome
          catalog={catalog}
          language={sample.language}
          maxLength={candidate?.maxLength ?? 0}
          result={result}
        />
      )}
    </>
  );
}

function Header() {
  const colors = usePalette();
  return (
    <>
      <Label
        accessibilityRole="header"
        style={[textStyles.reading.subject, { color: colors.textPrimary }]}>
        Categorization spike
      </Label>
      <Label style={[textStyles.subheadline, { color: colors.textSecondary }]}>
        Research build: classifies bundled public and synthetic samples with the
        frozen DeBERTa candidates on this Mac. It never reads your mail or
        contacts a server.
      </Label>
    </>
  );
}

function Unavailable() {
  const colors = usePalette();
  return (
    <Notice
      icon="exclamationmark.triangle.fill"
      iconColor={colors.statusWarning}
      message="No exported models in this build. Export the frozen candidates with tools/deberta-mac-spike/export.py, then rebuild the categorization-spike scenario. Categorization stays unavailable; it has no server fallback."
    />
  );
}

// One Settings row whose pop-up chooses among `choices`, each a value and its visible name.
function Pick({
  label,
  choices,
  value,
  disabled,
  onChoose,
}: {
  readonly label: string;
  readonly choices: readonly Choice[];
  readonly value: string;
  readonly disabled: boolean;
  readonly onChoose: (choice: string) => void;
}) {
  return (
    <SettingsRow title={label}>
      <View style={styles.pick}>
        <PopUp
          label={choices.find(([choice]) => choice === value)?.[1] ?? ''}
          accessibilityLabel={label}
          disabled={disabled}
          items={choices.map(([choice, name]) => ({
            key: choice,
            title: name,
            checked: choice === value,
            run: () => {
              onChoose(choice);
            },
          }))}
        />
      </View>
    </SettingsRow>
  );
}

function Setup({
  onChange,
  catalog,
  disabled,
  selection,
}: {
  readonly onChange: (selection: Selection) => void;
  readonly catalog: CatalogValue;
  readonly disabled: boolean;
  readonly selection: Selection;
}) {
  const { run, precision, unit, message, count } = selection;
  const candidates: Choice[] = catalog.candidates.map((each) => [
    each.run,
    `${candidateName(each.run)} · ${each.maxLength} tokens`,
  ]);
  const candidate = catalog.candidates.find((each) => each.run === run);
  const precisions: Choice[] = (candidate?.precisions ?? []).map((each) => [
    each,
    each.toUpperCase(),
  ]);
  const samples: Choice[] = catalog.messages.map((each) => [
    each.id,
    `${each.subject} · ${each.language === 'cs' ? 'Czech' : 'English'}`,
  ]);
  const counts: Choice[] = categoryCounts.map((each) => [
    String(each),
    each === 6 ? '6 golden categories' : `${each} categories`,
  ]);
  return (
    <SettingsGroup>
      <Pick
        label="Candidate"
        choices={candidates}
        value={run}
        disabled={disabled}
        onChoose={(choice) => {
          onChange({ ...selection, run: choice });
        }}
      />
      <Pick
        label="Precision"
        choices={precisions}
        value={precision}
        disabled={disabled}
        onChoose={(choice) => {
          onChange({
            ...selection,
            precision: choice === 'int8' ? 'int8' : 'fp16',
          });
        }}
      />
      <Pick
        label="Compute units"
        choices={units}
        value={unit}
        disabled={disabled}
        onChoose={(choice) => {
          onChange({
            ...selection,
            unit: units.find(([each]) => each === choice)?.[0] ?? 'all',
          });
        }}
      />
      <Pick
        label="Sample"
        choices={samples}
        value={message}
        disabled={disabled}
        onChoose={(choice) => {
          onChange({ ...selection, message: choice });
        }}
      />
      {candidate?.mode === 'custom' ? (
        <Pick
          label="Custom Categories"
          choices={counts}
          value={String(count)}
          disabled={disabled}
          onChoose={(choice) => {
            onChange({
              ...selection,
              count:
                categoryCounts.find((each) => String(each) === choice) ?? 6,
            });
          }}
        />
      ) : null}
    </SettingsGroup>
  );
}

function Actions({
  busy,
  onStart,
  onCancel,
}: {
  readonly busy: Busy | undefined;
  readonly onStart: (kind: Kind) => void;
  readonly onCancel: (request: string) => void;
}) {
  return (
    <View style={styles.actions}>
      <Button
        fill="accent"
        label="Classify"
        disabled={busy !== undefined}
        onPress={() => {
          onStart('classify');
        }}
      />
      <Button
        label="Benchmark"
        disabled={busy !== undefined}
        onPress={() => {
          onStart('benchmark');
        }}
      />
      <Button
        label="Check Golden Outputs"
        disabled={busy !== undefined}
        onPress={() => {
          onStart('golden');
        }}
      />
      <Button
        label="Compute Plan"
        disabled={busy !== undefined}
        onPress={() => {
          onStart('plan');
        }}
      />
      {busy === undefined ? null : (
        <Button
          label="Cancel"
          onPress={() => {
            onCancel(busy.request);
          }}
        />
      )}
    </View>
  );
}

// A running benchmark's samples done so far, polled from the bridge, with Cancel.
function BenchmarkProgress({
  module,
  request,
  samples,
  onCancel,
}: {
  readonly module: SpikeModule;
  readonly request: string;
  readonly samples: number;
  readonly onCancel: () => void;
}) {
  const colors = usePalette();
  const [progress, setProgress] = useState<ProgressValue>(null);
  useEffect(() => {
    const poll = async () => {
      const decoded = decodeProgress(await module.progress(request));
      if (decoded !== undefined && decoded !== null) {
        setProgress(decoded);
      }
    };
    const timer = setInterval(() => {
      void poll();
    }, 250);
    return () => {
      clearInterval(timer);
    };
  }, [module, request]);
  const done = progress === null ? 0 : progress.done / progress.total;
  return (
    <>
      <SectionLabel
        text={`BENCHMARK · ${rounds} ROUNDS OF ${samples} SAMPLES`}
      />
      <View style={[styles.progress, { backgroundColor: colors.fillQuiet }]}>
        <Label style={[textStyles.body, { color: colors.textPrimary }]}>
          {progress === null
            ? 'Loading the model…'
            : `Sample ${progress.done} of ${progress.total}`}
        </Label>
        <View style={[styles.track, { backgroundColor: colors.fillTrack }]}>
          <View
            style={[
              styles.bar,
              { backgroundColor: colors.accentFill, width: `${100 * done}%` },
            ]}
          />
        </View>
        <View style={styles.start}>
          <Button
            label="Cancel"
            onPress={onCancel}
          />
        </View>
      </View>
    </>
  );
}

function Outcome({
  catalog,
  language,
  maxLength,
  result,
}: {
  readonly catalog: CatalogValue;
  readonly language: string;
  readonly maxLength: number;
  readonly result: ResultValue;
}) {
  const colors = usePalette();
  return (
    <>
      {result.input === undefined ||
      result.classification === undefined ? null : (
        <Scores
          catalog={catalog}
          language={language}
          maxLength={maxLength}
          input={result.input}
          classification={result.classification}
        />
      )}
      <Measurements result={result} />
      <Label style={[textStyles.subheadline, { color: colors.textSecondary }]}>
        {`${catalog.host.model} · ${catalog.host.os} · evidence ${catalog.evidence}`}
      </Label>
    </>
  );
}

function Scores({
  catalog,
  language,
  maxLength,
  input,
  classification,
}: {
  readonly catalog: CatalogValue;
  readonly language: string;
  readonly maxLength: number;
  readonly input: string;
  readonly classification: ClassificationValue;
}) {
  const colors = usePalette();
  const decided = classification.categories.map((id) =>
    categoryName(catalog, language, id),
  );
  return (
    <>
      <SectionLabel
        text={`INPUT · ${classification.tokens[0] ?? 0} OF ${maxLength} TOKENS`}
      />
      <Label
        numberOfLines={4}
        style={[textStyles.subheadline, { color: colors.textSecondary }]}>
        {input.replaceAll('\n', ' · ')}
      </Label>
      <SectionLabel
        text={`RESULT · ${decided.length === 0 ? 'UNCATEGORIZED' : decided.join(' AND ').toUpperCase()}`}
      />
      {decided.length === 0 ? (
        <Label
          style={[textStyles.subheadline, { color: colors.textSecondary }]}>
          No category reaches its threshold, so the candidate abstains and the
          message stays uncategorized.
        </Label>
      ) : null}
      <SettingsGroup>
        {classification.scores.map((score) => (
          <SettingsRow
            key={score.category}
            {...(score.member ? { icon: 'checkmark' } : {})}
            title={categoryName(catalog, language, score.category)}>
            <View
              accessible
              accessibilityLabel={`${score.member ? 'Member' : 'Not a member'}, ${probability(score.probability)}, threshold ${score.threshold}`}>
              <Label
                style={[
                  textStyles.subheadline,
                  { color: colors.textSecondary },
                ]}>
                {`${probability(score.probability)} · threshold ${score.threshold}`}
              </Label>
            </View>
          </SettingsRow>
        ))}
      </SettingsGroup>
    </>
  );
}

// The rows a result reports, each only when that kind of run produced it.
const measurementRows = (result: ResultValue): Choice[] => {
  const rows: Choice[] = [];
  const { classification, passMs, golden, plan, process } = result;
  if (classification !== undefined) {
    const load =
      result.loadMs === undefined
        ? 'already loaded'
        : `${ms(result.loadMs)} load`;
    rows.push([
      'Model load and pass',
      `${load} · ${ms(median(classification.milliseconds))} per pass · ${classification.passes} passes`,
    ]);
  }
  if (passMs !== undefined) {
    rows.push([
      'Model pass',
      `${ms(passMs.p50)} at p50 · ${ms(passMs.p95)} at p95 · ${(result.messagesPerSecond ?? 0).toFixed(1)} messages a second`,
    ]);
  }
  if (golden !== undefined) {
    rows.push([
      'Golden outputs',
      `${golden.checked} checked · ${golden.tokenMismatches.length} token mismatches · ${golden.decisionChanges.length} decision changes · ${probability(golden.maxAbsProbabilityDifference)} largest difference`,
    ]);
  }
  if (plan !== undefined) {
    const devices = Object.entries(plan.preferred).map(
      ([device, ops]) => `${device} ${ops}`,
    );
    const fallbacks = Object.entries(plan.withoutNeuralEngine).map(
      ([op, n]) => `${op} ${n}`,
    );
    rows.push(
      ['Planned devices', devices.join(' · ')],
      [
        'Without Neural Engine support',
        fallbacks.length === 0 ? 'None' : fallbacks.join(' · '),
      ],
    );
  }
  rows.push(
    [
      'Peak memory and main thread delay',
      `${Math.round(process.peakFootprintMB)} MB · ${ms(process.mainThreadLagMs.p95)} at p95`,
    ],
    [
      'CPU energy and thermal state',
      `${(process.energyMillijoules / 1000).toFixed(2)} J · ${process.thermalBefore} to ${process.thermalAfter}`,
    ],
  );
  return rows;
};

function Measurements({ result }: { readonly result: ResultValue }) {
  const colors = usePalette();
  return (
    <SettingsGroup>
      {measurementRows(result).map(([title, value]) => (
        <SettingsRow
          key={title}
          title={title}>
          <Label style={[textStyles.body, { color: colors.textSecondary }]}>
            {value}
          </Label>
        </SettingsRow>
      ))}
    </SettingsGroup>
  );
}

function SectionLabel({ text }: { readonly text: string }) {
  const colors = usePalette();
  return (
    <Label
      style={[
        textStyles.subheadline,
        { fontWeight: '600', color: colors.textSecondary },
      ]}>
      {text}
    </Label>
  );
}
