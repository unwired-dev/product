import type {
  CatalogValue,
  ClassificationValue,
  Kind,
  ProgressValue,
  ResultValue,
  Selection,
  SpikeModule,
  SpikeState,
} from '@private-email/mail-core/testing/categorization-spike';
import type { ComponentProps } from 'react';
import type { TurboModule } from 'react-native';

import {
  Button,
  Form,
  Host,
  Label,
  LabeledContent,
  Picker,
  ProgressView,
  Section,
  Text as SwiftText,
  VStack,
} from '@expo/ui/swift-ui';
import {
  disabled,
  foregroundStyle,
  listRowBackground,
  monospacedDigit,
  scrollContentBackground,
  tag,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import {
  autorun,
  categoryCounts,
  categoryName,
  decodeProgress,
  loadCatalog,
  median,
  ms,
  probability,
  rounds,
  spikeSession,
  units,
} from '@private-email/mail-core/testing/categorization-spike';
import { spacing } from '@private-email/mail-core/theme';
import { useCallback, useEffect, useState } from 'react';
import {
  Platform,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  useWindowDimensions,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-screens/experimental';

import { NavigationChrome } from './design.tsx';
import { barInset } from './inbox-styles.ts';
import { textStyles, usePalette } from './theme.ts';

// Spike #830, compiled only into the `categorization-spike` Mock Mail Session build: the iPhone and
// iPad page for the frozen DeBERTa candidates, through the session the Mac page shares.

const styles = StyleSheet.create({
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    minHeight: 40,
    paddingHorizontal: spacing.l,
    paddingVertical: spacing.xs,
  },
  barTitle: { position: 'absolute', alignItems: 'center' },
  title: { ...textStyles.headline },
  regularTitle: { ...textStyles.reading.subject },
  form: { flex: 1 },
});

type Choice = readonly [string, string];
const secondary = foregroundStyle({ type: 'hierarchical', style: 'secondary' });
const device = Platform.OS === 'ios' && Platform.isPad ? 'iPad' : 'iPhone';
const capitalized = (text: string) =>
  `${text.charAt(0).toUpperCase()}${text.slice(1)}`;
const candidateName = (run: string, maxLength: number) => {
  const model = run.includes('mdeberta') ? 'mDeBERTa' : 'XSmall';
  const mode = run.includes('adapted') ? 'Custom' : 'System';
  return `${mode} · ${model} · ${maxLength} tokens`;
};

export function CategorizationSpike({
  compact,
}: {
  readonly compact: boolean;
}) {
  const colors = usePalette();
  const { width } = useWindowDimensions();
  const native = TurboModuleRegistry.get<SpikeModule & TurboModule>(
    'UnwiredCategorizationSpike',
  );
  const [catalog, setCatalog] = useState<CatalogValue | 'loading' | undefined>(
    'loading',
  );
  const [dismissed, setDismissed] = useState(false);
  useEffect(() => {
    const load = async () => {
      setCatalog(await loadCatalog(native));
    };
    void load();
  }, [native]);
  const dismiss = useCallback(() => {
    setDismissed(true);
  }, []);
  if (catalog === 'loading') {
    return null;
  }
  let page = null;
  if (catalog === undefined || native === null) {
    page = (
      <Group
        footer={
          <SwiftText>
            {`Export the frozen candidates, then rebuild the categorization-spike scenario. Categorization stays unavailable on this ${device}; it has no server fallback.`}
          </SwiftText>
        }>
        <Label
          title="No exported models in this build"
          systemImage="exclamationmark.triangle.fill"
        />
      </Group>
    );
  } else if (!dismissed) {
    page = (
      <Spike
        module={native}
        catalog={catalog}
        onDismiss={dismiss}
      />
    );
  }
  const title = (
    // The bar takes one native view as its title, so layout must not flatten this one away.
    <View
      collapsable={false}
      style={
        compact ? [styles.barTitle, { width: width - 2 * barInset }] : undefined
      }>
      <Text
        accessibilityRole="header"
        numberOfLines={1}
        style={[
          compact ? styles.title : styles.regularTitle,
          { color: colors.textPrimary },
        ]}>
        Categorization Spike
      </Text>
    </View>
  );
  // On iPhone the title sits in the navigation bar that keeps the system Back; the page starts
  // beneath it, like the reader.
  return (
    <SafeAreaView
      edges={{ top: true, bottom: true, left: true, right: true }}
      style={[styles.form, { backgroundColor: colors.surfaceContent }]}>
      {compact ? (
        <NavigationChrome
          testID="system-back"
          backLabel="All Inboxes"
          surface={colors.surfaceContent}>
          {title}
        </NavigationChrome>
      ) : (
        <View style={styles.header}>{title}</View>
      )}
      <Host style={styles.form}>
        <Form
          modifiers={[
            tint(colors.accentInk),
            scrollContentBackground('hidden'),
          ]}>
          <Group
            footer={
              <SwiftText>
                {`Research build: classifies bundled public and synthetic samples with the frozen DeBERTa candidates on this ${device}. It never reads your mail or contacts a server.`}
              </SwiftText>
            }>
            {null}
          </Group>
          {page}
        </Form>
      </Host>
    </SafeAreaView>
  );
}

// A form section whose rows sit on the lighter fill over the page's content surface.
function Group(props: ComponentProps<typeof Section>) {
  const colors = usePalette();
  return (
    <Section
      {...props}
      modifiers={[listRowBackground(colors.surfaceBubble)]}
    />
  );
}

const measurementRows = (result: ResultValue): Choice[] => {
  const rows: Choice[] = [];
  const { classification, passMs, golden, plan, process } = result;
  if (classification !== undefined) {
    rows.push(
      [
        'First Load',
        result.loadMs === undefined ? 'Already loaded' : ms(result.loadMs),
      ],
      ['Model Pass', ms(median(classification.milliseconds))],
      ['Model Passes', String(classification.passes)],
    );
  }
  if (passMs !== undefined) {
    rows.push(
      ['Model Pass', `${ms(passMs.p50)} at p50 · ${ms(passMs.p95)} at p95`],
      [
        'Throughput',
        `${(result.messagesPerSecond ?? 0).toFixed(1)} messages a second`,
      ],
    );
  }
  if (golden !== undefined) {
    rows.push(
      ['Golden Outputs', `${golden.checked} checked`],
      ['Token Mismatches', String(golden.tokenMismatches.length)],
      ['Decision Changes', String(golden.decisionChanges.length)],
      ['Largest Difference', probability(golden.maxAbsProbabilityDifference)],
    );
  }
  if (plan !== undefined) {
    const devices = Object.entries(plan.preferred).map(
      ([unit, ops]) => `${unit} ${ops}`,
    );
    const fallbacks = Object.entries(plan.withoutNeuralEngine).map(
      ([op, n]) => `${op} ${n}`,
    );
    rows.push(
      ['Planned Devices', devices.join(' · ')],
      [
        'Without Neural Engine',
        fallbacks.length === 0 ? 'None' : fallbacks.join(' · '),
      ],
    );
  }
  rows.push(
    ['Peak Memory', `${Math.round(process.peakFootprintMB)} MB`],
    ['Main-Thread Delay', `${ms(process.mainThreadLagMs.p95)} at p95`],
    ['CPU Energy', `${(process.energyMillijoules / 1000).toFixed(2)} J`],
    [
      'Thermal State',
      process.thermalBefore === process.thermalAfter
        ? capitalized(process.thermalAfter)
        : `${capitalized(process.thermalBefore)} to ${capitalized(process.thermalAfter)}`,
    ],
  );
  return rows;
};

function Spike({
  module,
  catalog,
  onDismiss,
}: {
  readonly module: SpikeModule;
  readonly catalog: CatalogValue;
  readonly onDismiss: () => void;
}) {
  const [state, setState] = useState<SpikeState>();
  // oxlint-disable-next-line react/hook-use-state -- The page keeps one session until it unmounts.
  const [session] = useState(() =>
    spikeSession({ module, catalog, device, onChange: setState }),
  );
  const { selection, busy, result, failure } = state ?? session.initial;
  // Leaving the page cancels the running request and releases the model.
  useEffect(() => {
    autorun(catalog, session, onDismiss);
    return () => {
      session.close();
    };
  }, [catalog, onDismiss, session]);
  const candidate = catalog.candidates.find(
    (each) => each.run === selection.run,
  );
  const custom = candidate?.mode === 'custom';
  const language =
    catalog.messages.find((each) => each.id === selection.message)?.language ??
    'en';
  const start = (kind: Kind) => {
    void session.start(kind, selection);
  };
  return (
    <>
      <Setup
        catalog={catalog}
        selection={selection}
        custom={custom}
        locked={busy !== undefined}
        onChange={(next) => {
          session.choose(next);
        }}
      />
      {busy?.kind === 'benchmark' ? (
        <BenchmarkProgress
          module={module}
          request={busy.request}
          samples={catalog.messages.length}
          onCancel={() => {
            session.cancel();
          }}
        />
      ) : (
        <Group>
          <Button
            label="Classify"
            onPress={() => {
              start('classify');
            }}
            modifiers={[disabled(busy !== undefined)]}
          />
          <Button
            label="Benchmark"
            onPress={() => {
              start('benchmark');
            }}
            modifiers={[disabled(busy !== undefined)]}
          />
          <Button
            label="Check Golden Outputs"
            onPress={() => {
              start('golden');
            }}
            modifiers={[disabled(busy !== undefined)]}
          />
          <Button
            label="Compute Plan"
            onPress={() => {
              start('plan');
            }}
            modifiers={[disabled(busy !== undefined)]}
          />
          {busy === undefined ? null : (
            <Button
              label="Cancel"
              onPress={() => {
                session.cancel();
              }}
            />
          )}
        </Group>
      )}
      {failure === undefined ? null : (
        <Group>
          <Label
            title={failure}
            systemImage="exclamationmark.triangle.fill"
          />
        </Group>
      )}
      {result === undefined ? null : (
        <>
          {result.classification === undefined ? null : (
            <Scores
              catalog={catalog}
              language={language}
              maxLength={candidate?.maxLength ?? 0}
              input={result.input ?? ''}
              classification={result.classification}
              custom={custom}
            />
          )}
          <Group
            title="Measurements"
            footer={
              <SwiftText>
                {`${catalog.host.model} · ${catalog.host.os} · evidence ${catalog.evidence}`}
              </SwiftText>
            }>
            {measurementRows(result).map(([title, value]) => (
              <LabeledContent
                key={title}
                label={title}>
                <SwiftText modifiers={[monospacedDigit()]}>{value}</SwiftText>
              </LabeledContent>
            ))}
          </Group>
        </>
      )}
    </>
  );
}

function Pick({
  label,
  value,
  choices,
  locked,
  onChange,
}: {
  readonly label: string;
  readonly value: string;
  readonly choices: readonly Choice[];
  readonly locked: boolean;
  readonly onChange: (value: string) => void;
}) {
  return (
    <Picker
      label={label}
      selection={value}
      onSelectionChange={onChange}
      modifiers={[disabled(locked)]}>
      {choices.map(([id, title]) => (
        <SwiftText
          key={id}
          modifiers={[tag(id)]}>
          {title}
        </SwiftText>
      ))}
    </Picker>
  );
}

function Setup({
  catalog,
  selection,
  custom,
  locked,
  onChange,
}: {
  readonly catalog: CatalogValue;
  readonly selection: Selection;
  readonly custom: boolean;
  readonly locked: boolean;
  readonly onChange: (selection: Selection) => void;
}) {
  const candidates: Choice[] = catalog.candidates.map((each) => [
    each.run,
    candidateName(each.run, each.maxLength),
  ]);
  const precisions: Choice[] = (
    catalog.candidates.find((each) => each.run === selection.run)?.precisions ??
    []
  ).map((each) => [each, each.toUpperCase()]);
  const samples: Choice[] = catalog.messages.map((each) => [
    each.id,
    `${each.subject} · ${each.language === 'cs' ? 'Czech' : 'English'}`,
  ]);
  const counts: Choice[] = categoryCounts.map((count) => [
    String(count),
    count === 6 ? '6 golden categories' : `${count} categories`,
  ]);
  return (
    <Group title="Setup">
      <Pick
        label="Candidate"
        value={selection.run}
        choices={candidates}
        locked={locked}
        onChange={(run) => {
          onChange({ ...selection, run });
        }}
      />
      <Pick
        label="Precision"
        value={selection.precision}
        choices={precisions}
        locked={locked}
        onChange={(precision) => {
          onChange({
            ...selection,
            precision: precision === 'int8' ? 'int8' : 'fp16',
          });
        }}
      />
      <Pick
        label="Compute Units"
        value={selection.unit}
        choices={units}
        locked={locked}
        onChange={(unit) => {
          onChange({
            ...selection,
            unit: units.find(([id]) => id === unit)?.[0] ?? 'all',
          });
        }}
      />
      <Pick
        label="Sample"
        value={selection.message}
        choices={samples}
        locked={locked}
        onChange={(message) => {
          onChange({ ...selection, message });
        }}
      />
      {custom ? (
        <Pick
          label="Custom Categories"
          value={String(selection.count)}
          choices={counts}
          locked={locked}
          onChange={(count) => {
            onChange({
              ...selection,
              count: categoryCounts.find((each) => String(each) === count) ?? 6,
            });
          }}
        />
      ) : null}
    </Group>
  );
}

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
  return (
    <Group
      title={`Benchmark · ${rounds} rounds of ${samples} samples`}
      footer={
        <SwiftText>
          Leaving this page cancels the benchmark and discards its partial
          results.
        </SwiftText>
      }>
      <VStack
        alignment="leading"
        spacing={spacing.s}>
        <SwiftText modifiers={[monospacedDigit()]}>
          {progress === null
            ? 'Loading the model…'
            : `Sample ${progress.done} of ${progress.total}`}
        </SwiftText>
        <ProgressView
          value={progress === null ? 0 : progress.done / progress.total}
        />
      </VStack>
      <Button
        label="Cancel"
        onPress={onCancel}
      />
    </Group>
  );
}

function Scores({
  catalog,
  language,
  maxLength,
  input,
  classification,
  custom,
}: {
  readonly catalog: CatalogValue;
  readonly language: string;
  readonly maxLength: number;
  readonly input: string;
  readonly classification: ClassificationValue;
  readonly custom: boolean;
}) {
  const decided = classification.categories.map((id) =>
    categoryName(catalog, language, id),
  );
  return (
    <>
      <Group
        title={`Input · ${classification.tokens[0] ?? 0} of ${maxLength} tokens`}>
        <SwiftText modifiers={[secondary]}>
          {input.replaceAll('\n', ' · ')}
        </SwiftText>
      </Group>
      <Group
        title={`Result · ${decided.length === 0 ? 'Uncategorized' : decided.join(' and ')}`}
        footer={
          decided.length === 0 ? (
            <SwiftText>
              {`No ${custom ? 'Custom Category' : 'category'} reached its threshold, so the spike abstains and the message stays uncategorized.`}
            </SwiftText>
          ) : undefined
        }>
        {classification.scores.map((score) => {
          const name = categoryName(catalog, language, score.category);
          const threshold = probability(score.threshold);
          return (
            <LabeledContent
              key={score.category}
              label={
                <VStack alignment="leading">
                  <SwiftText>{name}</SwiftText>
                  <SwiftText modifiers={[secondary]}>
                    {`${score.member ? 'Above' : 'Below'} threshold ${threshold}`}
                  </SwiftText>
                </VStack>
              }>
              <SwiftText modifiers={[monospacedDigit()]}>
                {probability(score.probability)}
              </SwiftText>
            </LabeledContent>
          );
        })}
      </Group>
    </>
  );
}
