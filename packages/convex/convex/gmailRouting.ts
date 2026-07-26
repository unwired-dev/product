type GmailRoutingKey = Readonly<{ key: string; version: number }>;

function environmentValue(name: string): string | undefined {
  // oxlint-disable-next-line node/no-process-env -- The deployment owns these backend-only routing secrets.
  const value = process.env[name];
  return value === undefined || value.length === 0 ? undefined : value;
}

function routingKeyVersion(name: string, fallback?: number): number {
  const value = environmentValue(name);
  const version = value === undefined ? fallback : Number(value);
  if (version === undefined || !Number.isSafeInteger(version) || version < 1) {
    throw new Error('Gmail routing key version is invalid');
  }
  return version;
}

function currentRoutingKey(): GmailRoutingKey {
  const key = environmentValue('GMAIL_ROUTING_KEY');
  if (key === undefined) {
    throw new Error('Gmail routing is not configured');
  }
  return {
    key,
    version: routingKeyVersion('GMAIL_ROUTING_KEY_VERSION', 1),
  };
}

function previousRoutingKey(): GmailRoutingKey | null {
  const key = environmentValue('GMAIL_ROUTING_PREVIOUS_KEY');
  const versionValue = environmentValue('GMAIL_ROUTING_PREVIOUS_KEY_VERSION');
  if (key === undefined && versionValue === undefined) {
    return null;
  }
  if (key === undefined || versionValue === undefined) {
    throw new Error('Previous Gmail routing key is not configured completely');
  }
  return {
    key,
    version: routingKeyVersion('GMAIL_ROUTING_PREVIOUS_KEY_VERSION'),
  };
}

function base64Url(data: ArrayBuffer): string {
  const bytes = new Uint8Array(data);
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCodePoint(byte);
  }
  return btoa(binary)
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');
}

async function identityBindingDigest(
  productAccountId: string,
  providerAccountIdentifier: string,
  routingKey: GmailRoutingKey,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(routingKey.key),
    { hash: 'SHA-256', name: 'HMAC' },
    false,
    ['sign'],
  );
  const digest = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(
      `${String(routingKey.version)}\0identity-binding\0${productAccountId}\0${providerAccountIdentifier}`,
    ),
  );
  return `${String(routingKey.version)}:${base64Url(digest)}`;
}

export async function gmailIdentityBindingDigests(
  productAccountId: string,
  providerAccountIdentifier: string,
): Promise<readonly string[]> {
  const current = currentRoutingKey();
  const previous = previousRoutingKey();
  return Promise.all(
    [current, ...(previous === null ? [] : [previous])].map((key) =>
      identityBindingDigest(productAccountId, providerAccountIdentifier, key),
    ),
  );
}

async function routingDigest(
  canonicalEmailAddress: string,
  routingKey: GmailRoutingKey,
): Promise<Readonly<{ digest: string; keyVersion: number }>> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(routingKey.key),
    { hash: 'SHA-256', name: 'HMAC' },
    false,
    ['sign'],
  );
  const digest = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(
      `${String(routingKey.version)}\0${canonicalEmailAddress}`,
    ),
  );
  return {
    digest: `${String(routingKey.version)}:${base64Url(digest)}`,
    keyVersion: routingKey.version,
  };
}

export async function gmailRoutingDigest(
  canonicalEmailAddress: string,
): Promise<Readonly<{ digest: string; keyVersion: number }>> {
  return routingDigest(canonicalEmailAddress, currentRoutingKey());
}

export async function gmailRoutingDigests(
  canonicalEmailAddress: string,
): Promise<ReadonlyArray<Readonly<{ digest: string; keyVersion: number }>>> {
  const current = currentRoutingKey();
  const previous = previousRoutingKey();
  if (previous?.version === current.version) {
    throw new Error('Gmail routing key versions must be distinct');
  }
  return Promise.all(
    [current, ...(previous === null ? [] : [previous])].map((key) =>
      routingDigest(canonicalEmailAddress, key),
    ),
  );
}
