import assert from 'node:assert/strict';

import type { BodyDocument } from '@private-email/mail-core/message-body';

import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import {
  requestUnsubscribe,
  unsubscribeOf,
} from '@private-email/mail-core/unsubscribe';

import { present } from './draft-sync-fixture.ts';

const oneClick = {
  'List-Id': 'Alza.cz newsletter <newsletter.alza.example>',
  'List-Unsubscribe':
    '<mailto:leave@alza.example?subject=unsubscribe>, <https://alza.example/u/42>',
  'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
};
const offer = {
  kind: 'one-click',
  list: 'Alza.cz newsletter',
  url: 'https://alza.example/u/42',
};

const offerOf = (headers: NonNullable<BodyDocument['headers']>) =>
  unsubscribeOf({ headers });

describe('unsubscribe offers', () => {
  it('finds the one-click offer in a message opened from Gmail, Graph or IMAP', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const gmailId = gmail.deliver({ headers: oneClick });
    const gmailInbox = createInboxStore(gmail.native);

    const graph = createSyntheticGraph();
    const graphId = graph.deliver({
      headers: Object.entries(oneClick).map(([name, value]) => ({
        name,
        value,
      })),
    });
    const graphInbox = createInboxStore(graph.native, {
      provider: 'microsoft-graph',
    });

    const imap = createSyntheticImap();
    imap.deliver('INBOX', {
      subject: 'Deals',
      raw: [
        'From: Alza <news@alza.example>',
        ...Object.entries(oneClick).map(([name, value]) => `${name}: ${value}`),
        'Subject: Deals',
        'Content-Type: text/plain; charset=utf-8',
        '',
        'This week only.',
      ].join('\r\n'),
    });
    const imapInbox = createImapInbox(imap.native);
    await imapInbox.load();
    const imapState = imapInbox.getSnapshot();
    assert.equal(imapState.kind, 'ready');
    const [imapMessage] = imapState.messages;
    const imapId = present(imapMessage, 'the IMAP message').id;

    for (const [inbox, id] of [
      [gmailInbox, gmailId],
      [graphInbox, graphId],
      [imapInbox, imapId],
    ] as const) {
      await inbox.load();
      const close = inbox.retainMessage(id);
      await inbox.readMessage(id);
      expect(unsubscribeOf(inbox.responseSource(id))).toStrictEqual(offer);
      close();
    }
  });

  it('prefers one-click HTTPS, then mailto, and offers nothing else', () => {
    expect.hasAssertions();
    const listUnsubscribe = oneClick['List-Unsubscribe'];
    const mailto = {
      kind: 'mailto',
      list: 'Alza.cz newsletter',
      address: 'leave@alza.example',
      subject: 'unsubscribe',
    };
    const base = { listId: oneClick['List-Id'], listUnsubscribe };
    const oneClickPost = { listUnsubscribePost: 'List-Unsubscribe=One-Click' };

    expect(offerOf({ ...base, ...oneClickPost })).toStrictEqual(offer);
    // Without the RFC 8058 header the HTTPS link is only a page, which is not offered.
    expect(offerOf(base)).toStrictEqual(mailto);
    expect(
      offerOf({ ...base, listUnsubscribePost: 'List-Unsubscribe=Yes' }),
    ).toStrictEqual(mailto);
    expect(
      offerOf({
        listId: base.listId,
        listUnsubscribe: '<https://alza.example/page>',
      }),
    ).toBeUndefined();
    for (const url of [
      'http://alza.example/u/42',
      'https://user:secret@alza.example/u/42',
      'https://alza.example@elsewhere.example/u/42',
      'https://alza.example:bad/u/42',
      'https://[bad-host/u/42',
      'https://alza.example:99999/u/42',
      'https://alza.example:0/u/42',
      'https://[2001:db8::1]/u/42',
      'ftp://alza.example/u/42',
    ]) {
      expect(
        offerOf({
          ...oneClickPost,
          listId: base.listId,
          listUnsubscribe: `<mailto:leave@alza.example?subject=unsubscribe>, <${url}>`,
        }),
      ).toStrictEqual(mailto);
    }
  });

  it('offers nothing without a bracketed List-Unsubscribe URI', () => {
    expect.hasAssertions();
    const listId = oneClick['List-Id'];
    const listUnsubscribePost = oneClick['List-Unsubscribe-Post'];

    expect(
      offerOf({
        listId,
        listUnsubscribePost,
        listUnsubscribe: 'https://alza.example/u/42',
      }),
    ).toBeUndefined();
    expect(offerOf({ listId, listUnsubscribePost })).toBeUndefined();
    // A URI inside a comment is explanation, not the unsubscribe command.
    expect(
      offerOf({
        listId,
        listUnsubscribePost,
        listUnsubscribe:
          '<mailto:leave@alza.example> (Help: <https://alza.example/help>)',
      }),
    ).toStrictEqual({
      kind: 'mailto',
      list: 'Alza.cz newsletter',
      address: 'leave@alza.example',
    });
    // Parentheses inside a commented URI still open and close comments.
    expect(
      offerOf({
        listId,
        listUnsubscribePost,
        listUnsubscribe:
          '(help <https://alza.example/(details> here) <https://alza.example/faq>), <mailto:leave@alza.example>',
      }),
    ).toStrictEqual({
      kind: 'mailto',
      list: 'Alza.cz newsletter',
      address: 'leave@alza.example',
    });
    expect(unsubscribeOf(undefined)).toBeUndefined();
  });

  it('reads one mailto address with only its subject and body', () => {
    expect.hasAssertions();
    const listId = 'Club <club.example>';

    expect(
      offerOf({
        listId,
        listUnsubscribe:
          '<mailto:leave%2Bme@club.example?%73ubject=Stop%20please&cc=boss@club.example&BODY=bye>',
      }),
    ).toStrictEqual({
      kind: 'mailto',
      list: 'Club',
      address: 'leave+me@club.example',
      subject: 'Stop please',
      body: 'bye',
    });
    // Whitespace inside the brackets is ignored, as RFC 2369 asks.
    expect(
      offerOf({ listId, listUnsubscribe: '< mailto:leave@club.example >' }),
    ).toStrictEqual({
      kind: 'mailto',
      list: 'Club',
      address: 'leave@club.example',
    });
    for (const listUnsubscribe of [
      '<mailto:a@club.example,b@club.example>',
      '<mailto:not-an-address>',
      '<mailto:leave@club.example?subject=%E0>',
      'mailto:leave@club.example',
    ]) {
      expect(offerOf({ listId, listUnsubscribe })).toBeUndefined();
    }
  });

  it('names the list by its List-Id phrase, else by the sender', () => {
    expect.hasAssertions();
    const listUnsubscribe = '<mailto:leave@club.example>';
    const listOf = (headers: NonNullable<BodyDocument['headers']>) =>
      offerOf({ listUnsubscribe, ...headers })?.list;

    expect(listOf({ listId: '"Club \\"Weekly\\"" <club.example>' })).toBe(
      'Club "Weekly"',
    );
    expect(
      listOf({
        listId: '<club.example>',
        from: '"Club Team" <team@club.example>',
      }),
    ).toBe('Club Team');
    expect(listOf({ from: 'team@club.example (Club)' })).toBe(
      'team@club.example',
    );
    expect(listOf({})).toBeUndefined();
  });
});

describe('one-click unsubscribe requests', () => {
  it('reports the native outcome, and uncertain when the answer is unusable', async () => {
    expect.hasAssertions();
    const urls: string[] = [];
    const native = (answer: () => Promise<unknown>) => ({
      requestUnsubscribe: (url: string) => {
        urls.push(url);
        return answer();
      },
    });
    const send = (answer: () => Promise<unknown>) =>
      requestUnsubscribe(native(answer), {
        kind: 'one-click',
        list: 'Alza.cz newsletter',
        url: 'https://alza.example/u/42',
      });

    for (const outcome of ['sent', 'failed', 'uncertain']) {
      await expect(send(async () => ({ outcome }))).resolves.toBe(outcome);
    }
    // The request may have arrived before the bridge failed, so neither counts as failed.
    await expect(
      send(async () => {
        throw Object.assign(new Error('https://alza.example/u/42'), {
          code: 'unavailable',
        });
      }),
    ).resolves.toBe('uncertain');
    await expect(send(async () => ({ outcome: 'accepted' }))).resolves.toBe(
      'uncertain',
    );
    // One request per call: nothing is retried.
    expect(urls).toStrictEqual(
      Array.from({ length: 5 }, () => 'https://alza.example/u/42'),
    );
  });
});
