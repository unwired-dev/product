import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  inspectGmailTenantReadiness,
  requireGmailTenantReadiness,
} from '../src/gmail-readiness.ts';

const checkedInReadinessPath = fileURLToPath(
  new URL(
    '../../../docs/gmail-provider-test-tenant-readiness.json',
    import.meta.url,
  ),
);

describe('gmail Provider Test Tenant readiness', () => {
  it('keeps the checked-in record structurally valid but unauthorized', async () => {
    expect.assertions(3);

    const readiness = await inspectGmailTenantReadiness(checkedInReadinessPath);

    expect(readiness).toMatchObject({
      authorizerRole: null,
      ready: false,
      schemaVersion: 1,
      status: 'awaiting_operator_attestation',
      verifiedAt: null,
    });
    expect(readiness.unmetControls).toContain('tenant.synthetic_only');
    expect(readiness.unmetControls).toContain('automation.authorizer_role');
  });

  it('authorizes a complete redacted operator attestation', async () => {
    expect.assertions(1);

    const fixture = await writeReadinessRecord(readyRecord());
    try {
      await expect(
        requireGmailTenantReadiness(fixture.path),
      ).resolves.toMatchObject({
        authorizerRole: 'provider-compatibility-authorizer',
        ready: true,
        status: 'ready',
        unmetControls: [],
        verifiedAt: '2026-08-10T15:00:00Z',
      });
    } finally {
      await fixture.remove();
    }
  });

  it('fails closed when an attested control is false', async () => {
    expect.assertions(2);
    const record = readyRecord();
    record.tenant.synthetic_only = false;

    const fixture = await writeReadinessRecord(record);
    try {
      const readiness = await inspectGmailTenantReadiness(fixture.path);

      expect(readiness).toMatchObject({ ready: false });
      await expect(requireGmailTenantReadiness(fixture.path)).rejects.toThrow(
        'tenant.synthetic_only',
      );
    } finally {
      await fixture.remove();
    }
  });

  it.each([
    {
      expected: 'readiness record must contain exactly',
      mutate: (record: ReadinessRecord) => {
        Object.assign(record, { tenant_domain: 'forbidden.example' });
      },
      name: 'unknown fields',
    },
    {
      expected: 'tenant must contain exactly',
      mutate: (record: ReadinessRecord) => {
        delete record.tenant.project_controlled;
      },
      name: 'missing controls',
    },
    {
      expected: 'verified_at must be an ISO 8601 UTC timestamp',
      mutate: (record: ReadinessRecord) => {
        record.verified_at = '2026-08-10T15:00:00+02:00';
      },
      name: 'non-UTC timestamps',
    },
    {
      expected: 'Readiness status is invalid',
      mutate: (record: ReadinessRecord) => {
        record.status = 'ready-for-review';
      },
      name: 'unknown status values',
    },
    {
      expected: 'oauth.audience_internal must be Boolean or null',
      mutate: (record: ReadinessRecord) => {
        record.oauth.audience_internal = 'yes';
      },
      name: 'non-Boolean controls',
    },
    {
      expected: 'non-identifying lowercase role slug',
      mutate: (record: ReadinessRecord) => {
        record.automation.authorizer_role = 'operator@example.com';
      },
      name: 'identifying authorizers',
    },
  ])('rejects $name', async ({ expected, mutate }) => {
    expect.assertions(1);
    const record = readyRecord();
    mutate(record);

    const fixture = await writeReadinessRecord(record);
    try {
      await expect(inspectGmailTenantReadiness(fixture.path)).rejects.toThrow(
        expected,
      );
    } finally {
      await fixture.remove();
    }
  });

  it('rejects malformed JSON', async () => {
    expect.assertions(1);

    const fixture = await writeReadinessContents('{');
    try {
      await expect(inspectGmailTenantReadiness(fixture.path)).rejects.toThrow(
        'readiness JSON is malformed',
      );
    } finally {
      await fixture.remove();
    }
  });
});

interface ReadinessRecord {
  automation: { authorizer_role: string | null };
  oauth: Record<string, unknown>;
  operations: Record<string, unknown>;
  schema_version: number;
  secrets: Record<string, unknown>;
  status: string;
  tenant: Record<string, unknown>;
  verified_at: string | null;
  [key: string]: unknown;
}

function readyRecord(): ReadinessRecord {
  return {
    automation: {
      authorizer_role: 'provider-compatibility-authorizer',
    },
    oauth: {
      audience_internal: true,
      scopes_match_client: true,
    },
    operations: {
      administrative_owner_recorded: true,
      cost_owner_recorded: true,
      lifecycle_recorded: true,
      mfa_recorded: true,
      recovery_recorded: true,
    },
    schema_version: 1,
    secrets: {
      approved_system_only: true,
      repository_exposure_reviewed: true,
    },
    status: 'ready',
    tenant: {
      at_least_two_test_users: true,
      project_controlled: true,
      synthetic_only: true,
    },
    verified_at: '2026-08-10T15:00:00Z',
  };
}

interface ReadinessFixture {
  path: string;
  remove: () => Promise<void>;
}

async function writeReadinessRecord(
  value: ReadinessRecord,
): Promise<ReadinessFixture> {
  return writeReadinessContents(JSON.stringify(value));
}

async function writeReadinessContents(
  contents: string,
): Promise<ReadinessFixture> {
  const root = await mkdtemp(path.join(tmpdir(), 'gmail-tenant-readiness-'));
  const readinessPath = path.join(root, 'readiness.json');
  await writeFile(readinessPath, contents);
  return {
    path: readinessPath,
    remove: async () => {
      await rm(root, { force: true, recursive: true });
    },
  };
}
