import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export type CategorizationCategory =
  | 'Flights'
  | 'Invites'
  | 'Newsletters & Promotions'
  | 'Orders'
  | 'People';

export interface CategorizationFixture {
  expectedCategory: CategorizationCategory | null;
  id: string;
  messageId: string;
  rawMessage: string;
}

interface CategorizationFixtureDefinition {
  expectedCategory: CategorizationCategory | null;
  file: string;
  id: string;
}

interface CategorizationManifest {
  fixtures: CategorizationFixtureDefinition[];
  schemaVersion: 1;
}

const categorizationRoot = fileURLToPath(
  new URL('../scenarios/categorization/', import.meta.url),
);
const supportedCategories: ReadonlySet<string> = new Set([
  'Flights',
  'Invites',
  'Newsletters & Promotions',
  'Orders',
  'People',
]);

export async function loadCategorizationFixtures(
  runId: string,
  date: Date,
  root = categorizationRoot,
): Promise<CategorizationFixture[]> {
  const resolvedRoot = path.resolve(root);
  const manifest = parseManifest(
    JSON.parse(
      await readFile(path.join(resolvedRoot, 'manifest.json'), 'utf8'),
    ),
  );
  const fixtureIds = new Set<string>();
  const fixtures: CategorizationFixture[] = [];
  for (const definition of manifest.fixtures) {
    if (fixtureIds.has(definition.id)) {
      throw new Error(
        `Categorization fixture id ${definition.id} is duplicated.`,
      );
    }
    fixtureIds.add(definition.id);
    const fixturePath = path.resolve(resolvedRoot, definition.file);
    if (
      path.dirname(fixturePath) !== resolvedRoot ||
      path.extname(fixturePath) !== '.eml'
    ) {
      throw new Error(
        `Categorization fixture ${definition.id} must reference one local .eml file.`,
      );
    }
    const messageId = `${runId}.${definition.id}@synthetic.invalid`;
    const template = await readFile(fixturePath, 'utf8');
    const rawMessage = template
      .replaceAll('{{DATE}}', date.toUTCString())
      .replaceAll('{{MESSAGE_ID}}', messageId);
    validateSyntheticMessage(definition.id, rawMessage);
    fixtures.push({
      expectedCategory: definition.expectedCategory,
      id: definition.id,
      messageId,
      rawMessage,
    });
  }
  return fixtures;
}

function parseManifest(value: unknown): CategorizationManifest {
  if (
    !isRecord(value) ||
    value.schemaVersion !== 1 ||
    !Array.isArray(value.fixtures)
  ) {
    throw new Error('Categorization scenario manifest is invalid.');
  }
  const fixtures = value.fixtures.map(
    (fixture): CategorizationFixtureDefinition => {
      if (
        !isRecord(fixture) ||
        typeof fixture.file !== 'string' ||
        typeof fixture.id !== 'string' ||
        !/^[a-z][a-z0-9-]*$/u.test(fixture.id) ||
        !(
          fixture.expectedCategory === null ||
          isCategorizationCategory(fixture.expectedCategory)
        )
      ) {
        throw new Error('Categorization fixture definition is invalid.');
      }
      return {
        expectedCategory: fixture.expectedCategory,
        file: fixture.file,
        id: fixture.id,
      };
    },
  );
  if (
    fixtures.length !== 6 ||
    new Set(fixtures.map((fixture) => fixture.expectedCategory)).size !== 6
  ) {
    throw new Error(
      'Categorization scenario must cover five System Categories and one uncategorized fixture.',
    );
  }
  return { fixtures, schemaVersion: 1 };
}

function validateSyntheticMessage(id: string, rawMessage: string): void {
  if (rawMessage.includes('{{')) {
    throw new Error(
      `Categorization fixture ${id} has an unresolved placeholder.`,
    );
  }
  const addresses = rawMessage.match(
    /[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+/giu,
  );
  if (
    addresses === null ||
    addresses.some(
      (address) => !address.toLowerCase().endsWith('@synthetic.invalid'),
    )
  ) {
    throw new Error(
      `Categorization fixture ${id} may contain only synthetic.invalid identities.`,
    );
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isCategorizationCategory(
  value: unknown,
): value is CategorizationCategory {
  return typeof value === 'string' && supportedCategories.has(value);
}
