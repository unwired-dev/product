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

// Text that reads as a web address: with a scheme, or a bare domain whose final label is letters
// or punycode (xn--), an IPv4 address or a bracketed IPv6 address.
const looksLikeAddress =
  /^\s*(?:https?:\/\/\S+|(?:(?:[\p{L}\p{N}-]+\.)+(?:[\p{L}]{2,}|xn--[\da-z-]+)|\d{1,3}(?:\.\d{1,3}){3}|\[[\da-f:.]+\])(?:[/:?#]\S*)?)\s*$/iu;

const numericHost =
  /^(?:\[[\da-f:.]+\]|(?:0x[\da-f]*|\d+)(?:\.(?:0x[\da-f]*|\d+)){0,3})$/iu;

const directionControls = /[‎‏‪-‮⁦-⁩]/u;

const decoded = (value: string, query = false) => {
  try {
    return decodeURIComponent(query ? value.replaceAll('+', ' ') : value);
  } catch {
    return value;
  }
};

// Comparison keys only: React Native's URL implementation does not normalize IP hosts.
const ipv4Key = (host: string) => {
  if (!numericHost.test(host) || host.startsWith('[')) {
    return undefined;
  }
  const words = host.split('.').map((word) => {
    let radix = 10;
    if (/^0x/iu.test(word)) {
      radix = 16;
    } else if (/^0\d/u.test(word)) {
      radix = 8;
    }
    const digits = radix === 16 ? word.slice(2) : word;
    if (radix === 8 && /[89]/u.test(digits)) {
      return Number.NaN;
    }
    return digits === '' ? 0 : Number.parseInt(digits, radix);
  });
  const last = words.pop();
  if (
    last === undefined ||
    !Number.isFinite(last) ||
    last >= 256 ** (4 - words.length) ||
    words.some((word) => !Number.isFinite(word) || word > 255)
  ) {
    return undefined;
  }
  return words.reduce(
    (key, word, index) => key + word * 256 ** (3 - index),
    last,
  );
};

// An embedded IPv4 tail uses four decimal octets, without compact or radix forms.
const ipv6HexTail = (content: string) => {
  if (content.includes('.')) {
    const at = content.lastIndexOf(':');
    const octets = content.slice(at + 1).split('.');
    if (
      octets.length !== 4 ||
      octets.some(
        (word) => !/^(?:0|[1-9]\d{0,2})$/u.test(word) || Number(word) > 255,
      )
    ) {
      return undefined;
    }
    const [a = 0, b = 0, c = 0, d = 0] = octets.map(Number);
    return `${content.slice(0, at + 1)}${(a * 256 + b).toString(16)}:${(c * 256 + d).toString(16)}`;
  }
  return content;
};

const ipv6Key = (host: string) => {
  if (!/^\[[\da-f:.]+\]$/iu.test(host)) {
    return undefined;
  }
  const content = ipv6HexTail(host.slice(1, -1));
  if (content === undefined) {
    return undefined;
  }
  const halves = content
    .split('::')
    .map((half) => (half === '' ? [] : half.split(':')));
  if (halves.length > 2) {
    return undefined;
  }
  const [left = [], right = []] = halves;
  const count = left.length + right.length;
  if (
    (halves.length === 1 ? count !== 8 : count >= 8) ||
    [...left, ...right].some((word) => !/^[\da-f]{1,4}$/iu.test(word))
  ) {
    return undefined;
  }
  return [...left, ...Array.from({ length: 8 - count }, () => '0'), ...right]
    .map((word) => Number.parseInt(word, 16).toString(16))
    .join(':');
};

const comparisonHost = (host: string) => {
  const normalized = decoded(host).toLowerCase().replace(/\.$/u, '');
  const ip = ipv4Key(normalized) ?? ipv6Key(normalized);
  return ip === undefined ? site(normalized) : `ip:${ip}`;
};

// Another site named in the query string, as redirect links do.
const forwardsElsewhere = (address: ParsedAddress) =>
  address.query
    .slice(1)
    .split('&')
    .map((pair) => decoded(pair.slice(pair.indexOf('=') + 1), true))
    .some((value) => {
      const target = parse(value);
      return (
        target !== undefined &&
        target.host !== '' &&
        comparisonHost(target.host) !== comparisonHost(address.host)
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
  if (
    shown !== undefined &&
    shown.host !== '' &&
    comparisonHost(shown.host) !== comparisonHost(address.host)
  ) {
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
