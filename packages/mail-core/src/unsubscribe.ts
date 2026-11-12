// A received message's standards-based unsubscribe mechanism (ADR 0044), read only from its list
// headers, never from body prose. Nothing here leaves the device.

import type { BodyDocument } from './message-body.ts';

import { withoutComments } from './message-body.ts';

// What a message offers for leaving its mailing list: an RFC 8058 one-click HTTPS request, or else
// an RFC 2369 mailto message to one address. `list` names the list for the person.
export type UnsubscribeOffer =
  | Readonly<{ kind: 'one-click'; list: string; url: string }>
  | Readonly<{
      kind: 'mailto';
      list: string;
      address: string;
      subject?: string;
      body?: string;
    }>;

// An HTTPS address whose authority is a host name or bracketed IP address and an optional port;
// React Native has no complete URL parser.
const oneClickUrl =
  /^https:\/\/(?:[a-z\d-]+(?:\.[a-z\d-]+)*|\[[\da-f:.]+\])(?::\d{1,5})?(?:[/?#][^\s\p{Cc}]*)?$/iu;
// One address, then optional header fields.
const mailtoUrl = /^mailto:(?<address>[^?,]+)(?:\?(?<query>.*))?$/iu;
const addressPattern =
  /^[^\s@<>()[\]\\,;:"]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]{2,}$/u;

const decoded = (value: string) => {
  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
};

// How many comments the text between URIs opens, less those it closes; escapes are not delimiters.
const nesting = (text: string) => {
  const plain = text.replaceAll(/\\./gsu, '');
  return plain.split('(').length - plain.split(')').length;
};

// The bracketed URIs of a List-Unsubscribe header, in order. Brackets inside a comment are not
// URIs, and whitespace inside one is ignored.
const urisOf = (header: string) => {
  let depth = 0;
  // Splitting on a capture group alternates the text between URIs with the URIs themselves.
  return header.split(/(?<uri><[^<>]*>)/u).flatMap((part, index) => {
    if (index % 2 === 0) {
      depth = Math.max(depth + nesting(part), 0);
      return [];
    }
    return depth === 0 ? [part.slice(1, -1).replaceAll(/\s/gu, '')] : [];
  });
};

// The subject and body a mailto query names, or undefined when a field does not decode. Other
// fields, such as cc, are left out: they would add recipients.
const fieldsOf = (query: string) => {
  const fields: { subject?: string; body?: string } = {};
  for (const field of query.split('&')) {
    const [name = '', value = ''] = field.split('=', 2);
    const key = decoded(name)?.toLowerCase();
    const text = decoded(value);
    if (key === undefined || text === undefined) {
      return undefined;
    }
    if ((key === 'subject' || key === 'body') && text !== '') {
      fields[key] = text;
    }
  }
  return fields;
};

const mailtoOf = (uri: string) => {
  // Positional captures: Hermes leaves `groups` unset on some named-group results.
  const [, rawAddress = '', query = ''] = mailtoUrl.exec(uri) ?? [];
  const address = decoded(rawAddress);
  const fields = fieldsOf(query);
  return address === undefined ||
    !addressPattern.test(address) ||
    fields === undefined
    ? undefined
    : { address, ...fields };
};

// A header's display phrase before its last bracketed part, unquoted.
const phraseOf = (header: string) => {
  const phrase = header.slice(0, Math.max(header.lastIndexOf('<'), 0)).trim();
  return (
    /^"(?<text>.*)"$/su
      .exec(phrase)?.[1]
      ?.replaceAll(/\\(?<char>.)/gsu, '$1') ?? phrase
  );
};

// The List-Id's phrase, else the sender's display name or address. Each read is linear in the
// sender-controlled header.
const listOf = (headers: NonNullable<BodyDocument['headers']>) => {
  const list = phraseOf(withoutComments(headers.listId ?? '', ' '));
  const from = withoutComments(headers.from ?? '', ' ');
  const sender = phraseOf(from);
  const address = from
    .slice(from.lastIndexOf('<') + 1)
    .replace(/>.*$/su, '')
    .trim();
  if (list !== '' || sender !== '') {
    return list === '' ? sender : list;
  }
  return addressPattern.test(address) ? address : undefined;
};

// The message's unsubscribe offer, or undefined when its headers name no usable mechanism.
export function unsubscribeOf(
  document: Pick<BodyDocument, 'headers'> | undefined,
): UnsubscribeOffer | undefined {
  const headers = document?.headers;
  const list =
    headers?.listUnsubscribe === undefined ? undefined : listOf(headers);
  if (headers?.listUnsubscribe === undefined || list === undefined) {
    return undefined;
  }
  const uris = urisOf(headers.listUnsubscribe);
  const oneClick =
    headers.listUnsubscribePost?.trim() === 'List-Unsubscribe=One-Click'
      ? uris.find((uri) => oneClickUrl.test(uri))
      : undefined;
  if (oneClick !== undefined) {
    return { kind: 'one-click', list, url: oneClick };
  }
  for (const uri of uris) {
    const mailto = mailtoOf(uri);
    if (mailto !== undefined) {
      return { kind: 'mailto', list, ...mailto };
    }
  }
  return undefined;
}
