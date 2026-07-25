const gmailRoutingKeyVersion = 1;

function configuredRoutingKey(): string {
  // oxlint-disable-next-line node/no-process-env -- The deployment owns this backend-only routing secret.
  const key = process.env.GMAIL_ROUTING_KEY;
  if (key === undefined || key.length === 0) {
    throw new Error('Gmail routing is not configured');
  }
  return key;
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

export async function gmailRoutingDigest(
  canonicalEmailAddress: string,
): Promise<Readonly<{ digest: string; keyVersion: number }>> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(configuredRoutingKey()),
    { hash: 'SHA-256', name: 'HMAC' },
    false,
    ['sign'],
  );
  const digest = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(
      `${String(gmailRoutingKeyVersion)}\0${canonicalEmailAddress}`,
    ),
  );
  return {
    digest: `${String(gmailRoutingKeyVersion)}:${base64Url(digest)}`,
    keyVersion: gmailRoutingKeyVersion,
  };
}
