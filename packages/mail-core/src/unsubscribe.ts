// A received message's standards-based unsubscribe mechanism (ADR 0044), read only from its list
// headers, never from body prose. Nothing here leaves the device.

import type { BodyDocument } from './message-body.ts';

import { recipientsOf } from './drafts.ts';

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

// An HTTPS address without user information; React Native has no complete URL parser.
const oneClickUrl = /^https:\/\/[^/?#@\s\p{Cc}]+(?:[/?#][^\s\p{Cc}]*)?$/iu;
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

// The bracketed URIs of a List-Unsubscribe header, in order; whitespace inside one is ignored.
const urisOf = (header: string) =>
  [...header.matchAll(/<(?<uri>[^<>]*)>/gu)].map(([, uri = '']) =>
    uri.replaceAll(/\s/gu, ''),
  );

const mailtoOf = (uri: string) => {
  // Positional captures: Hermes leaves `groups` unset on some named-group results.
  const [, rawAddress = '', query = ''] = mailtoUrl.exec(uri) ?? [];
  const address = decoded(rawAddress);
  if (address === undefined || !addressPattern.test(address)) {
    return undefined;
  }
  // Only the subject and body are kept: other fields, such as cc, would add recipients.
  const fields: { subject?: string; body?: string } = {};
  for (const field of query.split('&')) {
    const [name = '', value = ''] = field.split('=', 2);
    const key = name.toLowerCase();
    const text = decoded(value);
    if (text === undefined) {
      return undefined;
    }
    if ((key === 'subject' || key === 'body') && text !== '') {
      fields[key] = text;
    }
  }
  return { address, ...fields };
};

// The List-Id's display phrase before its bracketed identifier, else the sender's name or address.
const listOf = (headers: NonNullable<BodyDocument['headers']>) => {
  const listId = headers.listId ?? '';
  const phrase = listId.slice(0, Math.max(listId.indexOf('<'), 0)).trim();
  const unquoted =
    /^"(?<text>.*)"$/su
      .exec(phrase)?.[1]
      ?.replaceAll(/\\(?<char>.)/gsu, '$1') ?? phrase;
  const [sender] = recipientsOf(headers.from ?? '');
  return unquoted === '' ? (sender?.name ?? sender?.address) : unquoted;
};

// The message's unsubscribe offer, or undefined when its headers name no usable mechanism.
export function unsubscribeOf(
  document: Pick<BodyDocument, 'headers'> | undefined,
): UnsubscribeOffer | undefined {
  const headers = document?.headers;
  const list = headers === undefined ? undefined : listOf(headers);
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
