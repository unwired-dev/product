// Links a person may choose to open from a message, and the warnings shown before they do.
// Inspection is local: no lookup, persistence or logging of the destination.

const schemes = /^(?:https?:\/\/|mailto:|tel:)[^\s\p{Cc}]+$/iu;

// A destination the person may open: web, mail and telephone addresses only.
export const vettedHref = (raw: string) => {
  const href = raw.trim();
  return schemes.test(href) ? href : undefined;
};

// Scheme, user information and host of a web address; React Native has no complete URL parser.
const webAddress =
  /^(?<scheme>https?):\/\/(?<authority>[^/?#]*)(?<path>[^?#]*)(?<query>\?[^#]*)?/iu;

interface ParsedAddress {
  readonly scheme: string;
  readonly credentials: boolean;
  readonly host: string;
  readonly query: string;
}

const parse = (address: string): ParsedAddress | undefined => {
  // Positional captures: Hermes leaves `groups` unset on some named-group results.
  const [, scheme, authority = '', , query = ''] =
    webAddress.exec(address.trim()) ?? [];
  if (scheme === undefined) {
    return undefined;
  }
  const at = authority.lastIndexOf('@');
  const hostPort = authority.slice(at + 1);
  const host = (
    hostPort.startsWith('[')
      ? hostPort.slice(0, hostPort.indexOf(']') + 1)
      : hostPort.replace(/:\d*$/u, '')
  )
    .toLowerCase()
    .replace(/\.$/u, '');
  return { scheme: scheme.toLowerCase(), credentials: at !== -1, host, query };
};

const site = (host: string) => host.replace(/^www\./u, '');

const looksLikeAddress =
  /^\s*(?:https?:\/\/)?(?:[\p{L}\p{N}-]+\.)+[\p{L}]{2,}(?:[/:?#]\S*)?\s*$/iu;

const numericHost =
  /^(?:\[[\da-f:.]+\]|(?:0x[\da-f]+|\d+)(?:\.(?:0x[\da-f]+|\d+)){0,3})$/iu;

const directionControls = /[‎‏‪-‮⁦-⁩]/u;

const decoded = (value: string) => {
  try {
    return decodeURIComponent(value.replaceAll('+', ' '));
  } catch {
    return value;
  }
};

// Another site named in the query string, as redirect links do.
const forwardsElsewhere = (address: ParsedAddress) =>
  address.query
    .slice(1)
    .split('&')
    .map((pair) => decoded(pair.slice(pair.indexOf('=') + 1)))
    .some((value) => {
      const target = parse(value);
      return (
        target !== undefined &&
        target.host !== '' &&
        site(target.host) !== site(address.host)
      );
    });

export const linkWarnings = {
  text: 'The link text shows a different address.',
  insecure: 'The link text shows a secure address, but the link is not secure.',
  international: 'The address uses characters that can imitate other letters.',
  numeric: 'The address is a numeric IP address.',
  credentials: 'The address contains a user name or password.',
  direction: 'The address contains hidden text-direction characters.',
  forwards: 'The address forwards to another site.',
} as const;

// Reasons for caution about a link, given the text it was shown with. An empty list never means
// the destination is safe; it only means none of these signals were found.
export function inspectLink(
  href: string,
  text: string,
): ReadonlyArray<(typeof linkWarnings)[keyof typeof linkWarnings]> {
  const reasons: Array<(typeof linkWarnings)[keyof typeof linkWarnings]> = [];
  if (directionControls.test(decoded(href)) || directionControls.test(text)) {
    reasons.push(linkWarnings.direction);
  }
  const address = parse(href);
  if (address === undefined) {
    return reasons;
  }
  const shown = looksLikeAddress.test(text)
    ? parse(/^\s*https?:\/\//iu.test(text) ? text : `https://${text.trim()}`)
    : undefined;
  if (shown !== undefined && site(shown.host) !== site(address.host)) {
    reasons.push(linkWarnings.text);
  }
  if (/^\s*https:\/\//iu.test(text) && address.scheme === 'http') {
    reasons.push(linkWarnings.insecure);
  }
  const host = decoded(address.host);
  if (/[^\p{ASCII}]/u.test(host) || /(?:^|\.)xn--/u.test(host)) {
    reasons.push(linkWarnings.international);
  }
  if (numericHost.test(host)) {
    reasons.push(linkWarnings.numeric);
  }
  if (address.credentials) {
    reasons.push(linkWarnings.credentials);
  }
  if (forwardsElsewhere(address)) {
    reasons.push(linkWarnings.forwards);
  }
  return reasons;
}

// App-owned destinations keep WebKit URL normalization from losing visible link text.
export const messageLinkHref = (index: number) =>
  `about:blank#unwired-link-${index}`;

export function messageLinkAt<Link>(links: readonly Link[], url: string) {
  const match = /^about:blank#unwired-link-(?<index>0|[1-9]\d*)$/u.exec(url);
  return match === null ? undefined : links[Number(match[1])];
}
