import { createHash } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

import {
  ArtifactVerificationError,
  GREENMAIL_VERSION,
  resolveGreenMailArtifact,
} from '../src/artifact.ts';

describe('greenmail artifact resolution', () => {
  it('stores a download only after its SHA-256 checksum passes', async () => {
    expect.assertions(2);
    const cacheDirectory = await mkdtemp(
      path.join(tmpdir(), 'mail-test-artifact-'),
    );
    const contents = Buffer.from('verified-artifact');
    const expectedSHA256 = createHash('sha256').update(contents).digest('hex');
    try {
      const artifact = await resolveGreenMailArtifact({
        cacheDirectory,
        expectedSHA256,
        fetcher: async () => new Response(contents),
        url: 'https://example.invalid/greenmail.jar',
      });

      expect(artifact).toBe(
        path.join(
          cacheDirectory,
          `greenmail-standalone-${GREENMAIL_VERSION}.jar`,
        ),
      );
      await expect(readFile(artifact)).resolves.toStrictEqual(contents);
    } finally {
      await rm(cacheDirectory, { force: true, recursive: true });
    }
  });

  it('refuses a download whose checksum does not match', async () => {
    expect.assertions(2);
    const cacheDirectory = await mkdtemp(
      path.join(tmpdir(), 'mail-test-artifact-'),
    );
    try {
      await expect(
        resolveGreenMailArtifact({
          cacheDirectory,
          expectedSHA256: '0'.repeat(64),
          fetcher: async () => new Response('tampered'),
          url: 'https://example.invalid/greenmail.jar',
        }),
      ).rejects.toBeInstanceOf(ArtifactVerificationError);
      await expect(readdir(cacheDirectory)).resolves.toStrictEqual([]);
    } finally {
      await rm(cacheDirectory, { force: true, recursive: true });
    }
  });

  it('honors caller cancellation without caching an artifact', async () => {
    expect.assertions(3);
    const cacheDirectory = await mkdtemp(
      path.join(tmpdir(), 'mail-test-artifact-'),
    );
    const abortController = new AbortController();
    abortController.abort();
    try {
      await expect(
        resolveGreenMailArtifact({
          cacheDirectory,
          fetcher: async (_input, init) => {
            expect(init?.signal?.aborted).toBe(true);
            throw init?.signal?.reason;
          },
          signal: abortController.signal,
          url: 'https://example.invalid/greenmail.jar',
        }),
      ).rejects.toBe(abortController.signal.reason);
      await expect(readdir(cacheDirectory)).resolves.toStrictEqual([]);
    } finally {
      await rm(cacheDirectory, { force: true, recursive: true });
    }
  });

  it('refuses a cached artifact whose checksum no longer matches', async () => {
    expect.assertions(1);
    const cacheDirectory = await mkdtemp(
      path.join(tmpdir(), 'mail-test-artifact-'),
    );
    const artifactPath = path.join(
      cacheDirectory,
      `greenmail-standalone-${GREENMAIL_VERSION}.jar`,
    );
    try {
      await writeFile(artifactPath, 'tampered');
      await expect(
        resolveGreenMailArtifact({
          cacheDirectory,
          expectedSHA256: '0'.repeat(64),
        }),
      ).rejects.toBeInstanceOf(ArtifactVerificationError);
    } finally {
      await rm(cacheDirectory, { force: true, recursive: true });
    }
  });
});
