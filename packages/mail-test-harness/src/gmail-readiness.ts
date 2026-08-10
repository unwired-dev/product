import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const defaultReadinessPath = fileURLToPath(
  new URL(
    '../../../docs/gmail-provider-test-tenant-readiness.json',
    import.meta.url,
  ),
);
const controlGroups = {
  oauth: ['audience_internal', 'scopes_match_client'],
  operations: [
    'administrative_owner_recorded',
    'mfa_recorded',
    'recovery_recorded',
    'lifecycle_recorded',
    'cost_owner_recorded',
  ],
  secrets: ['approved_system_only', 'repository_exposure_reviewed'],
  tenant: ['project_controlled', 'synthetic_only', 'at_least_two_test_users'],
} as const;

export interface GmailTenantReadiness {
  authorizerRole: string | null;
  kind: 'gmail-provider-test-tenant-readiness';
  ready: boolean;
  schemaVersion: 1;
  status: 'awaiting_operator_attestation' | 'ready';
  unmetControls: string[];
  verifiedAt: string | null;
}

export async function inspectGmailTenantReadiness(
  readinessPath = defaultReadinessPath,
): Promise<GmailTenantReadiness> {
  const contents = await readFile(readinessPath, 'utf8');
  let value: unknown = null;
  try {
    value = JSON.parse(contents);
  } catch {
    throw new Error('Gmail Provider Test Tenant readiness JSON is malformed.');
  }
  return parseReadiness(value);
}

export async function requireGmailTenantReadiness(
  readinessPath = defaultReadinessPath,
): Promise<GmailTenantReadiness> {
  const readiness = await inspectGmailTenantReadiness(readinessPath);
  if (!readiness.ready) {
    throw new Error(
      `Gmail Provider Test Tenant is not ready: ${readiness.unmetControls.join(', ')}.`,
    );
  }
  return readiness;
}

function parseReadiness(value: unknown): GmailTenantReadiness {
  assertRecord(value, 'readiness record');
  assertExactKeys(value, 'readiness record', [
    'automation',
    'oauth',
    'operations',
    'schema_version',
    'secrets',
    'status',
    'tenant',
    'verified_at',
  ]);
  if (value.schema_version !== 1) {
    throw new Error('Readiness schema_version must be 1.');
  }
  const status = parseStatus(value.status);
  const verifiedAt = parseVerifiedAt(value.verified_at);
  assertRecord(value.automation, 'automation');
  assertExactKeys(value.automation, 'automation', ['authorizer_role']);
  const authorizerRole = parseAuthorizerRole(value.automation.authorizer_role);
  const unmetControls = [
    ...(status === 'ready' ? [] : ['status']),
    ...(verifiedAt === null ? ['verified_at'] : []),
    ...parseControlGroups(value),
    ...(authorizerRole === null ? ['automation.authorizer_role'] : []),
  ];

  return {
    authorizerRole,
    kind: 'gmail-provider-test-tenant-readiness',
    ready: unmetControls.length === 0,
    schemaVersion: 1,
    status,
    unmetControls,
    verifiedAt,
  };
}

function parseControlGroups(value: Record<string, unknown>): string[] {
  const unmetControls: string[] = [];
  for (const [groupName, controls] of Object.entries(controlGroups)) {
    const group = value[groupName];
    assertRecord(group, groupName);
    assertExactKeys(group, groupName, controls);
    for (const control of controls) {
      const controlValue = group[control];
      if (controlValue !== null && typeof controlValue !== 'boolean') {
        throw new Error(`${groupName}.${control} must be Boolean or null.`);
      }
      if (controlValue !== true) {
        unmetControls.push(`${groupName}.${control}`);
      }
    }
  }
  return unmetControls;
}

function parseStatus(value: unknown): GmailTenantReadiness['status'] {
  if (value !== 'awaiting_operator_attestation' && value !== 'ready') {
    throw new Error('Readiness status is invalid.');
  }
  return value;
}

function parseVerifiedAt(value: unknown): string | null {
  if (value === null) {
    return null;
  }
  if (
    typeof value !== 'string' ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/u.test(value) ||
    Number.isNaN(Date.parse(value)) ||
    new Date(value).toISOString() !== value.replace('Z', '.000Z')
  ) {
    throw new Error('verified_at must be an ISO 8601 UTC timestamp or null.');
  }
  return value;
}

function parseAuthorizerRole(value: unknown): string | null {
  if (value === null) {
    return null;
  }
  if (typeof value !== 'string' || !/^[a-z][a-z0-9-]{2,63}$/u.test(value)) {
    throw new Error(
      'automation.authorizer_role must be a non-identifying lowercase role slug or null.',
    );
  }
  return value;
}

function assertRecord(
  value: unknown,
  field: string,
): asserts value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${field} must be an object.`);
  }
}

function assertExactKeys(
  value: Record<string, unknown>,
  field: string,
  expectedKeys: readonly string[],
): void {
  const actual = Object.keys(value).toSorted();
  const expected = expectedKeys.toSorted();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new Error(`${field} must contain exactly: ${expected.join(', ')}.`);
  }
}
