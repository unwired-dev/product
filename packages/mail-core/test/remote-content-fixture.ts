import { deflateSync } from 'node:zlib';

import type { GmailInbox, MessageBodyState } from '../src/gmail-inbox.ts';

const ascii = (text: string) => [...Buffer.from(text, 'latin1')];
const u32 = (value: number) => {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32BE(value);
  return [...bytes];
};
/* oxlint-disable no-bitwise -- PNG fixtures require their binary CRC. */
const crc32 = (bytes: readonly number[]) => {
  let crc = 4_294_967_295;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) === 0 ? 0 : 3_988_292_384);
    }
  }
  return (crc ^ 4_294_967_295) >>> 0;
};
/* oxlint-enable no-bitwise */
const chunk = (type: string, data: readonly number[]) => {
  const content = [...ascii(type), ...data];
  return [...u32(data.length), ...content, ...u32(crc32(content))];
};
export const png = (width: number, height: number) =>
  Buffer.from([
    ...ascii('\u0089PNG\r\n\u001A\n'),
    ...chunk('IHDR', [...u32(width), ...u32(height), 8, 6, 0, 0, 0]),
    // oxlint-disable-next-line node/no-sync -- Small controlled PNG fixtures are prepared synchronously in tests.
    ...chunk('IDAT', [...deflateSync(Buffer.alloc((width * 4 + 1) * height))]),
    ...chunk('IEND', []),
  ]).toString('base64');

export const remote = (state: MessageBodyState | undefined) => {
  if (state?.kind !== 'ready' || state.presentation.rich === undefined) {
    throw new Error(`Expected a rich body, received ${state?.kind}`);
  }
  return state.presentation.rich;
};

// Opens a message in one reader, as the reader view does.
export const open = async (inbox: Readonly<GmailInbox>, id: string) => {
  const reader = Symbol('reader');
  const release = inbox.retainMessage(id, reader);
  await inbox.readMessage(id);
  return {
    reader,
    release,
    shown: () => remote(inbox.messageBody(id, reader)),
  };
};

// Synchronize with observable paused transfers, independent of scheduler turn counts.
export const waitForFetches = (active: () => number, count: number) =>
  vi.waitFor(() => {
    expect(active()).toBe(count);
  });
