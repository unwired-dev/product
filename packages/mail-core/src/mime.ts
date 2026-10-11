import * as Base64 from 'effect/encoding/Base64';
import * as Base64Url from 'effect/encoding/Base64Url';
import * as Result from 'effect/Result';

import type { GmailPart } from './message-body.ts';

// A raw RFC 5322 message as the MIME tree the reader already presents for Gmail: each part with
// its own headers, and each leaf with its transfer-decoded bytes as base64url. Charsets are decoded
// later, per part, by the reader. Bounds match the reader's: a tree deeper or wider than these is
// refused rather than walked.
const limits = { depth: 32, parts: 10_000, headerBytes: 256 * 1024 };

// One byte per character, so structure is found without decoding any charset.
const binary = (bytes: Readonly<Uint8Array>) => {
  let text = '';
  for (let index = 0; index < bytes.length; index += 0x80_00) {
    text += String.fromCodePoint(...bytes.subarray(index, index + 0x80_00));
  }
  return text;
};
const bytesOf = (text: string) =>
  Uint8Array.from(text, (character) => character.codePointAt(0) ?? 0);

// Header text is UTF-8 where it is not ASCII (RFC 6532); anything else keeps its bytes as Latin-1.
const headerText = (text: string) => {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytesOf(text));
  } catch {
    return text;
  }
};

const split = (entity: string) => {
  const end = /\r?\n\r?\n/u.exec(entity);
  const head = end === null ? entity : entity.slice(0, end.index);
  const body = end === null ? '' : entity.slice(end.index + end[0].length);
  const headers =
    head.length > limits.headerBytes
      ? []
      : head
          .split(/\r?\n(?![ \t])/u)
          .filter((line) => line.includes(':'))
          .map((line) => {
            const colon = line.indexOf(':');
            return {
              name: line.slice(0, colon).trim(),
              value: headerText(
                line
                  .slice(colon + 1)
                  .replaceAll(/\r?\n/gu, '')
                  .trim(),
              ),
            };
          });
  return { headers, body, size: head.length };
};

const valueOf = (
  headers: ReadonlyArray<Readonly<{ name: string; value: string }>>,
  name: string,
) => headers.find((header) => header.name.toLowerCase() === name)?.value;

// A parameter of a structured header, quoted or not; the reader re-reads headers strictly.
const parameter = (value: string | undefined, name: string) => {
  const match = new RegExp(
    `;\\s*${name}\\s*=\\s*(?:"((?:[^"\\\\]|\\\\.)*)"|([^;\\s]+))`,
    'iu',
  ).exec(value ?? '');
  return match === null
    ? undefined
    : (match[1]?.replaceAll(/\\(?<escaped>.)/gu, '$<escaped>') ?? match[2]);
};

const mediaType = (value: string | undefined) =>
  /^\s*(?<type>[^;\s]+)/u.exec(value ?? '')?.[1]?.toLowerCase() ?? 'text/plain';

const quotedPrintable = (text: string) =>
  text
    .replaceAll(/[ \t]+(?=\r?\n)/gu, '')
    .replaceAll(/[=]\r?\n/gu, '')
    .replaceAll(/[=](?<hex>[\dA-Fa-f]{2})/gu, (_, hex: string) =>
      String.fromCodePoint(Number.parseInt(hex, 16)),
    );

// Line breaks and other characters outside the alphabet are skipped; data that still cannot be
// decoded reads as empty, which the reader reports as an unreadable part.
const base64 = (text: string) => {
  const clean = text.replaceAll(/[^\d+/A-Za-z]/gu, '');
  const bytes = Base64.decode(
    clean.padEnd(Math.ceil(clean.length / 4) * 4, '='),
  );
  return Result.isSuccess(bytes) ? binary(bytes.success) : '';
};

const decoded = (body: string, encoding = '') => {
  switch (encoding.trim().toLowerCase()) {
    case 'base64': {
      return base64(body);
    }
    case 'quoted-printable': {
      return quotedPrintable(body);
    }
    default: {
      return body;
    }
  }
};

// The body parts between a multipart entity's delimiter lines; the preamble and epilogue are not
// content, and a missing close delimiter ends the last part at the end of the entity.
function* multipartBodies(body: string, boundary: string) {
  const delimiter = `--${boundary}`;
  let start: number | undefined = undefined;
  for (const match of body.matchAll(/[^\n]*(?:\n|$)/gu)) {
    const [line] = match;
    const trimmed = line.replace(/[ \t]*\r?\n$/u, '');
    if (trimmed === delimiter || trimmed === `${delimiter}--`) {
      if (start !== undefined) {
        // The line break before a delimiter belongs to the delimiter.
        yield body.slice(start, match.index).replace(/\r?\n$/u, '');
      }
      if (trimmed !== delimiter) {
        return;
      }
      start = match.index + line.length;
    }
  }
  if (start !== undefined) {
    yield body.slice(start);
  }
}

// A leaf part: its transfer-decoded bytes as base64url.
const leaf = (
  headers: ReadonlyArray<Readonly<{ name: string; value: string }>>,
  body: string,
) => {
  const content = decoded(body, valueOf(headers, 'content-transfer-encoding'));
  return { size: content.length, data: Base64Url.encode(bytesOf(content)) };
};

const describe = (
  headers: ReadonlyArray<Readonly<{ name: string; value: string }>>,
) => {
  const contentType = valueOf(headers, 'content-type');
  const mimeType = mediaType(contentType);
  const filename =
    parameter(valueOf(headers, 'content-disposition'), 'filename') ??
    parameter(contentType, 'name') ??
    '';
  return {
    mimeType,
    filename,
    boundary: mimeType.startsWith('multipart/')
      ? parameter(contentType, 'boundary')
      : undefined,
  };
};

export function parseMime(raw: Readonly<Uint8Array>): GmailPart | undefined {
  let parts = 0;
  let exceeded = false;
  const parse = (entity: string, depth: number): GmailPart => {
    parts += 1;
    exceeded ||= depth > limits.depth || parts > limits.parts;
    if (exceeded) {
      return {};
    }
    const { headers, body, size } = split(entity);
    exceeded ||= size > limits.headerBytes;
    if (exceeded) {
      return {};
    }
    const { mimeType, filename, boundary } = describe(headers);
    if (boundary !== undefined) {
      const children: GmailPart[] = [];
      for (const part of multipartBodies(body, boundary)) {
        children.push(parse(part, depth + 1));
        if (exceeded) {
          break;
        }
      }
      return {
        mimeType,
        filename,
        headers,
        body: { size: 0 },
        parts: children,
      };
    }
    return { mimeType, filename, headers, body: leaf(headers, body) };
  };
  const tree = parse(binary(raw), 0);
  return exceeded ? undefined : tree;
}
