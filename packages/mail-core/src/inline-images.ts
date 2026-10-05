/* oxlint-disable no-bitwise, unicorn/number-literal-case, typescript/prefer-readonly-parameter-types -- Image headers are binary fields read from byte arrays; the formatter lowercases hexadecimal literals. */

// Validation of MIME Inline Image bytes before an app-generated `data:` source shows them. Only
// complete, single-frame PNG, JPEG, GIF and WebP images within the reviewed bounds are admitted.

export const inlineImageLimits = {
  bytesPerImage: 5 * 1024 * 1024,
  attempts: 20,
  admitted: 20,
  aggregateBytes: 20 * 1024 * 1024,
  axis: 8192,
  pixelsPerImage: 16 * 1024 * 1024,
  aggregatePixels: 32 * 1024 * 1024,
} as const;

export interface ImageFacts {
  readonly mimeType: 'image/png' | 'image/jpeg' | 'image/gif' | 'image/webp';
  readonly width: number;
  readonly height: number;
}

const ascii = (bytes: Uint8Array, at: number, length: number) =>
  String.fromCodePoint(...bytes.subarray(at, at + length));

const u16be = (bytes: Uint8Array, at: number) =>
  ((bytes[at] ?? 0) << 8) | (bytes[at + 1] ?? 0);
const u16le = (bytes: Uint8Array, at: number) =>
  (bytes[at] ?? 0) | ((bytes[at + 1] ?? 0) << 8);
const u24le = (bytes: Uint8Array, at: number) =>
  u16le(bytes, at) | ((bytes[at + 2] ?? 0) << 16);
const u32be = (bytes: Uint8Array, at: number) =>
  u16be(bytes, at) * 65_536 + u16be(bytes, at + 2);
const u32le = (bytes: Uint8Array, at: number) =>
  u16le(bytes, at) + u16le(bytes, at + 2) * 65_536;

// PNG chunk integrity and required image data; a header and trailer alone are not an image.
const crc32 = (bytes: Uint8Array, from: number, to: number) => {
  let crc = 0xff_ff_ff_ff;
  for (let at = from; at < to; at += 1) {
    crc ^= bytes[at] ?? 0;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ ((crc & 1) === 0 ? 0 : 0xed_b8_83_20);
    }
  }
  return (crc ^ 0xff_ff_ff_ff) >>> 0;
};

const pngChunk = (bytes: Uint8Array, at: number) => {
  const length = u32be(bytes, at);
  const end = at + 12 + length;
  return end <= bytes.length &&
    crc32(bytes, at + 4, end - 4) === u32be(bytes, end - 4)
    ? { at, type: ascii(bytes, at + 4, 4), length, end }
    : undefined;
};

interface PngRead {
  facts: ImageFacts | undefined;
  imageData: boolean;
}

const pngHeader = (
  bytes: Uint8Array,
  at: number,
  length: number,
): ImageFacts | undefined =>
  at === 8 && length === 13
    ? {
        mimeType: 'image/png',
        width: u32be(bytes, at + 8),
        height: u32be(bytes, at + 12),
      }
    : undefined;

const readPngChunk = (
  bytes: Uint8Array,
  chunk: NonNullable<ReturnType<typeof pngChunk>>,
  read: PngRead,
) => {
  if (chunk.type === 'IHDR') {
    read.facts = pngHeader(bytes, chunk.at, chunk.length);
    return read.facts !== undefined;
  }
  if (read.facts === undefined || chunk.type === 'acTL') {
    return false;
  }
  if (chunk.type === 'IDAT') {
    read.imageData ||= chunk.length > 0;
  }
  return true;
};

const pngEnd = (
  bytes: Uint8Array,
  chunk: NonNullable<ReturnType<typeof pngChunk>>,
  read: PngRead,
) =>
  chunk.end === bytes.length && chunk.length === 0 && read.imageData
    ? read.facts
    : undefined;

function png(bytes: Uint8Array): ImageFacts | undefined {
  if (ascii(bytes, 0, 8) !== '\u0089PNG\r\n\u001A\n') {
    return undefined;
  }
  let at = 8;
  const read: PngRead = { facts: undefined, imageData: false };
  while (at + 12 <= bytes.length) {
    const chunk = pngChunk(bytes, at);
    if (chunk === undefined) {
      return undefined;
    }
    if (chunk.type === 'IEND') {
      return pngEnd(bytes, chunk, read);
    }
    if (!readPngChunk(bytes, chunk, read)) {
      return undefined;
    }
    at = chunk.end;
  }
  return undefined;
}

const startOfFrame = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

const nextJpegMarker = (bytes: Uint8Array, from: number) => {
  let at = from;
  while (at < bytes.length) {
    if (bytes[at] === 0xff) {
      const next = bytes[at + 1];
      if (next === 0 || (next !== undefined && next >= 0xd0 && next <= 0xd7)) {
        at += 2;
      } else {
        return at;
      }
    } else {
      at += 1;
    }
  }
  return at;
};

const jpegLength = (bytes: Uint8Array, at: number) => {
  const length = u16be(bytes, at);
  return length >= 2 && at + length <= bytes.length ? length : undefined;
};

const jpegSegment = (bytes: Uint8Array, from: number) => {
  if (bytes[from] !== 0xff) {
    return undefined;
  }
  let at = from + 1;
  while (bytes[at] === 0xff) {
    at += 1;
  }
  const marker = bytes[at];
  if (marker === undefined) {
    return undefined;
  }
  at += 1;
  if (marker === 0xd9) {
    return { marker, at, length: 0, next: at };
  }
  const length = jpegLength(bytes, at);
  return length === undefined
    ? undefined
    : { marker, at, length, next: at + length };
};

interface JpegRead {
  facts: ImageFacts | undefined;
  scanned: boolean;
}

const jpegFrame = (
  bytes: Uint8Array,
  segment: NonNullable<ReturnType<typeof jpegSegment>>,
  read: JpegRead,
): ImageFacts | undefined =>
  read.facts === undefined && segment.length >= 8
    ? {
        mimeType: 'image/jpeg',
        width: u16be(bytes, segment.at + 5),
        height: u16be(bytes, segment.at + 3),
      }
    : undefined;

const jpegScan = (
  bytes: Uint8Array,
  segment: NonNullable<ReturnType<typeof jpegSegment>>,
  read: JpegRead,
) => {
  if (read.facts === undefined || segment.length < 6) {
    return undefined;
  }
  read.scanned = true;
  return nextJpegMarker(bytes, segment.next);
};

const readJpegSegment = (
  bytes: Uint8Array,
  segment: NonNullable<ReturnType<typeof jpegSegment>>,
  read: JpegRead,
) => {
  if (startOfFrame.has(segment.marker)) {
    read.facts = jpegFrame(bytes, segment, read);
    return read.facts === undefined ? undefined : segment.next;
  }
  return segment.marker === 0xda
    ? jpegScan(bytes, segment, read)
    : segment.next;
};

const jpegEnd = (bytes: Uint8Array, at: number, read: JpegRead) =>
  read.scanned && at === bytes.length ? read.facts : undefined;

// Walk every JPEG segment and scan through entropy data to the final end-of-image marker.
function jpeg(bytes: Uint8Array): ImageFacts | undefined {
  if (u16be(bytes, 0) !== 0xff_d8) {
    return undefined;
  }
  let at = 2;
  const read: JpegRead = { facts: undefined, scanned: false };
  while (at < bytes.length) {
    const segment = jpegSegment(bytes, at);
    if (segment === undefined) {
      return undefined;
    }
    if (segment.marker === 0xd9) {
      return jpegEnd(bytes, segment.next, read);
    }
    const next = readJpegSegment(bytes, segment, read);
    if (next === undefined) {
      return undefined;
    }
    at = next;
  }
  return undefined;
}

// Skips a run of GIF data sub-blocks, returning the offset after the terminator.
const subBlocks = (bytes: Uint8Array, from: number) => {
  let at = from;
  while (at < bytes.length && bytes[at] !== 0) {
    at += 1 + (bytes[at] ?? 0);
  }
  return at + 1;
};

const colorTable = (flags: number) =>
  (flags & 0x80) === 0 ? 0 : 3 * 2 ** ((flags & 0x07) + 1);

// One GIF block after the header: the offset after it and whether it is an image.
const gifBlock = (bytes: Uint8Array, at: number) => {
  if (at + 2 >= bytes.length) {
    return undefined;
  }
  if (bytes[at] === 0x21) {
    return { next: subBlocks(bytes, at + 2), frames: 0 };
  }
  return bytes[at] === 0x2c &&
    at + 11 <= bytes.length &&
    u16le(bytes, at + 1) + u16le(bytes, at + 5) <= u16le(bytes, 6) &&
    u16le(bytes, at + 3) + u16le(bytes, at + 7) <= u16le(bytes, 8)
    ? {
        next: subBlocks(bytes, at + 11 + colorTable(bytes[at + 9] ?? 0)),
        frames: 1,
      }
    : undefined;
};

// Image descriptors up to the trailer, which must end the data.
const gifFrames = (bytes: Uint8Array) => {
  let at = 13 + colorTable(bytes[10] ?? 0);
  let frames = 0;
  while (at < bytes.length && bytes[at] !== 0x3b) {
    const block = gifBlock(bytes, at);
    if (block === undefined) {
      return undefined;
    }
    at = block.next;
    frames += block.frames;
  }
  return at + 1 === bytes.length ? frames : undefined;
};

// More than one image descriptor means more than one frame.
const gif = (bytes: Uint8Array): ImageFacts | undefined =>
  /^GIF8[79]a$/u.test(ascii(bytes, 0, 6)) && gifFrames(bytes) === 1
    ? { mimeType: 'image/gif', width: u16le(bytes, 6), height: u16le(bytes, 8) }
    : undefined;

const webpChunks: Readonly<
  Record<string, (bytes: Uint8Array) => ImageFacts | undefined>
> = {
  'VP8 ': (bytes) =>
    ascii(bytes, 23, 3) === '\u009D\u0001*'
      ? {
          mimeType: 'image/webp',
          width: u16le(bytes, 26) & 0x3f_ff,
          height: u16le(bytes, 28) & 0x3f_ff,
        }
      : undefined,
  VP8L: (bytes) => {
    const bits = u32le(bytes, 21);
    return bytes[20] === 0x2f
      ? {
          mimeType: 'image/webp',
          width: (bits & 0x3f_ff) + 1,
          height: ((bits >>> 14) & 0x3f_ff) + 1,
        }
      : undefined;
  },
  // The extended format's animation flag means more than one frame.
  VP8X: (bytes) =>
    ((bytes[20] ?? 0) & 0x02) === 0
      ? {
          mimeType: 'image/webp',
          width: u24le(bytes, 24) + 1,
          height: u24le(bytes, 27) + 1,
        }
      : undefined,
};

const webpFrame = (
  bytes: Uint8Array,
  at: number,
  chunk: Readonly<{ type: string; length: number }>,
) => {
  const { type, length } = chunk;
  const minimum = type === 'VP8 ' ? 10 : 5;
  if (type === 'VP8X' ? at !== 12 || length !== 10 : length < minimum) {
    return undefined;
  }
  return webpChunks[type]?.(bytes.subarray(at - 12));
};

const webpHeader = (bytes: Uint8Array) =>
  ascii(bytes, 0, 4) === 'RIFF' &&
  ascii(bytes, 8, 4) === 'WEBP' &&
  u32le(bytes, 4) + 8 === bytes.length;

const webpChunk = (bytes: Uint8Array, at: number) => {
  const type = ascii(bytes, at, 4);
  const length = u32le(bytes, at + 4);
  const end = at + 8 + length + (length % 2);
  return end <= bytes.length && type !== 'ANIM' && type !== 'ANMF'
    ? { at, type, length, end }
    : undefined;
};

interface WebpRead {
  facts: ImageFacts | undefined;
  frames: number;
}

const matchesWebpFrame = (
  expected: ImageFacts | undefined,
  frame: ImageFacts,
) =>
  expected === undefined ||
  (expected.width === frame.width && expected.height === frame.height);

const readWebpFrame = (
  bytes: Uint8Array,
  chunk: NonNullable<ReturnType<typeof webpChunk>>,
  read: WebpRead,
) => {
  // The header readers use fixed offsets relative to a chunk at offset 12.
  const frame = webpFrame(bytes, chunk.at, chunk);
  if (frame === undefined) {
    return false;
  }
  if (chunk.type !== 'VP8X' && !matchesWebpFrame(read.facts, frame)) {
    return false;
  }
  read.frames += chunk.type === 'VP8X' ? 0 : 1;
  read.facts = frame;
  return true;
};

const readWebpChunk = (bytes: Uint8Array, at: number, read: WebpRead) => {
  const chunk = webpChunk(bytes, at);
  if (chunk === undefined) {
    return undefined;
  }
  if (
    Object.hasOwn(webpChunks, chunk.type) &&
    !readWebpFrame(bytes, chunk, read)
  ) {
    return undefined;
  }
  return chunk.end;
};

// Validate every RIFF chunk and require a frame, including for an extended VP8X container.
const webp = (bytes: Uint8Array): ImageFacts | undefined => {
  if (!webpHeader(bytes)) {
    return undefined;
  }
  let at = 12;
  const read: WebpRead = { facts: undefined, frames: 0 };
  while (at + 8 <= bytes.length) {
    const next = readWebpChunk(bytes, at, read);
    if (next === undefined) {
      return undefined;
    }
    at = next;
  }
  return at === bytes.length && read.frames === 1 ? read.facts : undefined;
};

// The image's type and size when its bytes are a complete, single-frame supported image within
// the per-image bounds.
export function inspectImage(bytes: Uint8Array): ImageFacts | undefined {
  const facts = png(bytes) ?? jpeg(bytes) ?? gif(bytes) ?? webp(bytes);
  return facts !== undefined &&
    bytes.length <= inlineImageLimits.bytesPerImage &&
    facts.width >= 1 &&
    facts.height >= 1 &&
    facts.width <= inlineImageLimits.axis &&
    facts.height <= inlineImageLimits.axis &&
    facts.width * facts.height <= inlineImageLimits.pixelsPerImage
    ? facts
    : undefined;
}
