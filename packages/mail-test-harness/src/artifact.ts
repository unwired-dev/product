import { createHash } from 'node:crypto';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

export const GREENMAIL_VERSION = '2.1.12';
const GREENMAIL_SHA256 =
  'f4ab352a5401ef62b2ad9ea0472cb6df0d1d71ab98129bad783343c816a264fb';
const GREENMAIL_URL = `https://repo.maven.apache.org/maven2/com/icegreen/greenmail-standalone/${GREENMAIL_VERSION}/greenmail-standalone-${GREENMAIL_VERSION}.jar`;

export interface ArtifactOptions {
  cacheDirectory?: string;
  expectedSHA256?: string;
  fetcher?: typeof fetch;
  url?: string;
}

export class ArtifactVerificationError extends Error {
  public override name = 'ArtifactVerificationError';
}

function digest(contents: Uint8Array): string {
  return createHash('sha256').update(contents).digest('hex');
}

export async function resolveGreenMailArtifact(
  options: Readonly<ArtifactOptions> = {},
): Promise<string> {
  const expectedSHA256 = options.expectedSHA256 ?? GREENMAIL_SHA256;
  const cacheDirectory =
    options.cacheDirectory ??
    path.join(homedir(), '.cache', 'unwired-mail-test');
  const artifactPath = path.join(
    cacheDirectory,
    `greenmail-standalone-${GREENMAIL_VERSION}.jar`,
  );

  try {
    const cached = await readFile(artifactPath);
    if (digest(cached) !== expectedSHA256) {
      throw new ArtifactVerificationError(
        'The cached GreenMail artifact failed checksum verification.',
      );
    }
    return artifactPath;
  } catch (error) {
    if (error instanceof ArtifactVerificationError) {
      throw error;
    }
    if (!isMissingFileError(error)) {
      throw error;
    }
  }

  await mkdir(path.dirname(artifactPath), { recursive: true });
  const temporaryPath = `${artifactPath}.${process.pid}.download`;
  try {
    const response = await (options.fetcher ?? fetch)(
      options.url ?? GREENMAIL_URL,
    );
    if (!response.ok) {
      throw new Error(
        `GreenMail download failed with HTTP ${response.status}.`,
      );
    }
    const contents = new Uint8Array(await response.arrayBuffer());
    if (digest(contents) !== expectedSHA256) {
      throw new ArtifactVerificationError(
        'The downloaded GreenMail artifact failed checksum verification.',
      );
    }
    await writeFile(temporaryPath, contents, { mode: 0o600 });
    await rename(temporaryPath, artifactPath);
    return artifactPath;
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

function isMissingFileError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && 'code' in error && error.code === 'ENOENT';
}
