export type GmailMinimalPushMetadata = Readonly<{
  emailAddress: string;
  historyId: string;
}>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function decodeGmailPushEnvelope(
  envelope: unknown,
): GmailMinimalPushMetadata {
  if (!isRecord(envelope) || !isRecord(envelope.message)) {
    throw new Error('Gmail push data required');
  }
  if (typeof envelope.message.data !== 'string') {
    throw new TypeError('Gmail push data required');
  }

  const base64 = envelope.message.data
    .replaceAll('-', '+')
    .replaceAll('_', '/')
    .padEnd(Math.ceil(envelope.message.data.length / 4) * 4, '=');
  const decoded: unknown = JSON.parse(atob(base64));
  if (
    !isRecord(decoded) ||
    typeof decoded.emailAddress !== 'string' ||
    decoded.emailAddress.length === 0 ||
    typeof decoded.historyId !== 'string' ||
    decoded.historyId.length === 0
  ) {
    throw new Error('Invalid Gmail push metadata');
  }

  return {
    emailAddress: decoded.emailAddress,
    historyId: decoded.historyId,
  };
}

export function gmailWakeupPayload(historyId: string): Readonly<{
  aps: Readonly<{ 'content-available': 1 }>;
  historyId: string;
  provider: 'gmail';
}> {
  return {
    aps: { 'content-available': 1 },
    historyId,
    provider: 'gmail',
  };
}
