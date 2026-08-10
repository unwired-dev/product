import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  loadCategorizationFixtures,
  loadIncrementalArrivalScenario,
} from '../src/scenario.ts';

const categorizationRoot = fileURLToPath(
  new URL('../scenarios/categorization/', import.meta.url),
);
const incrementalArrivalRoot = fileURLToPath(
  new URL('../scenarios/incremental-arrival/', import.meta.url),
);

describe('categorization scenario corpus', () => {
  it('loads one synthetic fixture for every expected visible outcome', async () => {
    expect.assertions(4);
    const runId = '00000000-0000-0000-0000-000000000001';

    const fixtures = await loadCategorizationFixtures(
      runId,
      new Date('2026-08-10T00:00:00Z'),
    );

    expect(
      fixtures.map(({ expectedCategory, id }) => ({ expectedCategory, id })),
    ).toStrictEqual([
      { expectedCategory: 'People', id: 'people' },
      { expectedCategory: 'Orders', id: 'orders' },
      {
        expectedCategory: 'Newsletters & Promotions',
        id: 'newsletters-promotions',
      },
      { expectedCategory: 'Invites', id: 'invites' },
      { expectedCategory: 'Flights', id: 'flights' },
      { expectedCategory: null, id: 'ambiguous' },
    ]);
    expect(
      fixtures.every((fixture) =>
        fixture.rawMessage.includes(fixture.messageId),
      ),
    ).toBe(true);
    expect(
      fixtures.every((fixture) => !fixture.rawMessage.includes('{{')),
    ).toBe(true);
    expect(
      fixtures.every((fixture) =>
        [...fixture.rawMessage.matchAll(/@[a-z0-9.-]+/giu)].every(
          ([domain]) => domain.toLowerCase() === '@synthetic.invalid',
        ),
      ),
    ).toBe(true);
  });

  it.each([
    {
      expected: 'id people is duplicated',
      mutate: async (root: string) => {
        await replaceManifest(root, '"id": "orders"', '"id": "people"');
      },
      name: 'duplicate fixture ids',
    },
    {
      expected: 'must cover five System Categories',
      mutate: async (root: string) => {
        await replaceManifest(
          root,
          '"expectedCategory": "Orders"',
          '"expectedCategory": "People"',
        );
      },
      name: 'duplicate expected outcomes',
    },
    {
      expected: 'must reference one local .eml file',
      mutate: async (root: string) => {
        await replaceManifest(root, '"people.eml"', '"../outside.eml"');
      },
      name: 'escaped fixture paths',
    },
    {
      expected: 'must reference one local .eml file',
      mutate: async (root: string) => {
        await replaceManifest(root, '"people.eml"', '"people.txt"');
      },
      name: 'non-eml fixture paths',
    },
    {
      expected: 'has an unresolved placeholder',
      mutate: async (root: string) => {
        const fixturePath = path.join(root, 'people.eml');
        const fixture = await readFile(fixturePath, 'utf8');
        await writeFile(fixturePath, `${fixture}\n{{UNKNOWN}}\n`);
      },
      name: 'unresolved placeholders',
    },
    {
      expected: 'may contain only synthetic.invalid identities',
      mutate: async (root: string) => {
        const fixturePath = path.join(root, 'people.eml');
        const fixture = await readFile(fixturePath, 'utf8');
        await writeFile(
          fixturePath,
          fixture.replace('@synthetic.invalid', '@example.com'),
        );
      },
      name: 'non-synthetic identities',
    },
  ])('rejects $name', async ({ expected, mutate }) => {
    expect.assertions(1);
    const root = await mkdtemp(path.join(tmpdir(), 'categorization-scenario-'));
    try {
      await cp(categorizationRoot, root, { recursive: true });
      await mutate(root);

      await expect(
        loadCategorizationFixtures(
          '00000000-0000-0000-0000-000000000001',
          new Date('2026-08-10T00:00:00Z'),
          root,
        ),
      ).rejects.toThrow(expected);
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });
});

describe('incremental-arrival scenario corpus', () => {
  it('loads staged synthetic fixtures and explicit provider differences', async () => {
    expect.assertions(5);
    const scenario = await loadIncrementalArrivalScenario(
      '00000000-0000-0000-0000-000000000001',
      new Date('2026-08-10T00:00:00Z'),
    );

    expect(
      scenario.fixtures.map(({ id, replyTo, stage }) => ({
        id,
        replyTo,
        stage,
      })),
    ).toStrictEqual([
      {
        id: 'initial-conversation',
        replyTo: undefined,
        stage: 'initial',
      },
      { id: 'new-after-sync', replyTo: undefined, stage: 'incremental' },
      {
        id: 'conversation-reply',
        replyTo: 'initial-conversation',
        stage: 'incremental',
      },
    ]);
    expect(scenario.preservedState).toStrictEqual({
      fixtureId: 'initial-conversation',
      flags: [String.raw`\Flagged`, String.raw`\Seen`],
      mailbox: 'INBOX',
    });
    expect(scenario.providerDifferences).toStrictEqual({
      gmail: {
        arrival: 'history-or-push',
        injection: 'gmail-api',
        observation: 'gmail-api',
      },
      greenmail: {
        arrival: 'manual-refresh',
        injection: 'smtp',
        observation: 'imap',
      },
    });
    expect(
      scenario.fixtures[2]?.rawMessage.includes(
        'References: <00000000-0000-0000-0000-000000000001.initial-conversation@synthetic.invalid>',
      ),
    ).toBe(true);
    expect(
      scenario.fixtures.every((fixture) => !fixture.rawMessage.includes('{{')),
    ).toBe(true);
  });

  it.each([
    {
      expected: 'provider differences must declare GreenMail and Gmail',
      mutate: async (root: string) => {
        await replaceManifest(
          root,
          '"arrival": "history-or-push"',
          '"arrival": "manual-refresh"',
        );
      },
      name: 'implicit provider behavior',
    },
    {
      expected: 'must reference one local .eml file',
      mutate: async (root: string) => {
        await replaceManifest(
          root,
          '"initial-conversation.eml"',
          '"../outside.eml"',
        );
      },
      name: 'escaped fixture paths',
    },
    {
      expected: 'may contain only synthetic.invalid identities',
      mutate: async (root: string) => {
        const fixturePath = path.join(root, 'new-after-sync.eml');
        const fixture = await readFile(fixturePath, 'utf8');
        await writeFile(
          fixturePath,
          fixture.replace('@synthetic.invalid', '@example.com'),
        );
      },
      name: 'non-synthetic identities',
    },
  ])('rejects $name', async ({ expected, mutate }) => {
    expect.assertions(1);
    const root = await mkdtemp(
      path.join(tmpdir(), 'incremental-arrival-scenario-'),
    );
    try {
      await cp(incrementalArrivalRoot, root, { recursive: true });
      await mutate(root);

      await expect(
        loadIncrementalArrivalScenario(
          '00000000-0000-0000-0000-000000000001',
          new Date('2026-08-10T00:00:00Z'),
          root,
        ),
      ).rejects.toThrow(expected);
    } finally {
      await rm(root, { force: true, recursive: true });
    }
  });
});

async function replaceManifest(
  root: string,
  search: string,
  replacement: string,
): Promise<void> {
  const manifestPath = path.join(root, 'manifest.json');
  const manifest = await readFile(manifestPath, 'utf8');
  if (!manifest.includes(search)) {
    throw new Error(`Missing manifest fixture: ${search}`);
  }
  await writeFile(manifestPath, manifest.replace(search, replacement));
}
