import assert from 'node:assert/strict';

import type { BodyDocument } from '@private-email/mail-core/message-body';
import type { RegistrationSnapshot } from '@private-email/mail-core/registration';
import type {
  NativeUnsubscribe,
  NativeUnsubscribeRequests,
} from '@private-email/mail-core/unsubscribe';

import { createImapInbox } from '@private-email/mail-core/imap-inbox';
import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';
import { createSyntheticImap } from '@private-email/mail-core/testing/imap-mailbox';
import {
  createUnsubscribe,
  requestUnsubscribe,
  unsubscribeOf,
  unsubscribeOfferReturnsAfter,
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
  identity: 'newsletter.alza.example',
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
      identity: 'newsletter.alza.example',
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
      identity: 'newsletter.alza.example',
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
      identity: 'newsletter.alza.example',
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
      identity: 'club.example',
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
      identity: 'club.example',
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

  it('identifies the list only by its List-Id identifier', () => {
    expect.hasAssertions();
    const listUnsubscribe = '<mailto:leave@club.example>';
    const identityOf = (headers: NonNullable<BodyDocument['headers']>) =>
      offerOf({ listUnsubscribe, from: 'team@club.example', ...headers })
        ?.identity;

    expect(identityOf({ listId: 'Club <Weekly.Club.Example>' })).toBe(
      'weekly.club.example',
    );
    expect(identityOf({ listId: 'Club <weekly.\r\n club.example>' })).toBe(
      'weekly.club.example',
    );
    // Lists that share a sender are told apart only by their List-Id.
    expect(identityOf({})).toBeUndefined();
    for (const listId of [
      'Club <https://club.example/u/42>',
      'Club <club>',
      'Club <week(note)ly.club.example>',
      'Club <weekly club.example>',
      'club.example',
    ]) {
      expect(identityOf({ listId })).toBeUndefined();
    }
  });

  it('names the list by its List-Id phrase, else by the sender', () => {
    expect.hasAssertions();
    const listUnsubscribe = '<mailto:leave@club.example>';
    const listOf = (headers: NonNullable<BodyDocument['headers']>) =>
      offerOf({ listUnsubscribe, ...headers })?.list;

    expect(
      listOf({ listId: String.raw`"Club \"Weekly\"" <club.example>` }),
    ).toBe('Club "Weekly"');
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
        identity: 'newsletter.alza.example',
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

// 8 Nov 2026, as the approved Sent state dates the request.
const sentOn = Date.UTC(2026, 10, 8, 9);

// Native storage as the store sees it: one document for the signed-in account, replaced only from
// the revision read, and a one-click endpoint that answers `state.outcome`.
const storage = () => {
  const state: {
    account: string;
    outcome: string;
    revision: number;
    owner?: string;
    document?: string;
    // The next commit's rejection code, as when storage refuses a write.
    refuse?: string;
    // Runs while the request awaits its answer, as another sign-in would.
    pending?: () => void;
  } = { account: 'account-1', outcome: 'sent', revision: 0 };
  const native: NativeUnsubscribe & NativeUnsubscribeRequests = {
    requestUnsubscribe: async () => {
      state.pending?.();
      return { outcome: state.outcome };
    },
    openUnsubscribeRequests: async () => ({
      owner: state.account,
      revision: state.revision,
      document: state.owner === state.account ? state.document : null,
    }),
    commitUnsubscribeRequests: async (owner, expectedRevision, document) => {
      const code = state.refuse;
      if (code !== undefined) {
        throw Object.assign(new Error(code), { code });
      }
      Object.assign(state, { revision: expectedRevision + 1, owner, document });
      return { owner, revision: state.revision };
    },
  };
  const registration = {
    getSnapshot: () => ({
      snapshot: {
        kind: 'connected',
        productAccountId: state.account,
        signInProvider: 'google',
        mailboxes: '[]',
      } satisfies RegistrationSnapshot,
      busy: false,
      failed: false,
    }),
  };
  return {
    state,
    native,
    relaunch: () => createUnsubscribe(native, registration),
  };
};

describe('sent unsubscribe requests', () => {
  const oneClickOffer = {
    kind: 'one-click',
    list: 'Alza.cz',
    identity: 'newsletter.alza.example',
    url: 'https://alza.example/u/42',
  } as const;

  const sent = {
    profile: 'work',
    identity: 'newsletter.alza.example',
    list: 'Alza.cz',
    sentAt: sentOn,
  };
  const later = (days: number) => sentOn + days * 86_400_000;

  it('dates a sent request for its Profile only, without the URI', async () => {
    expect.hasAssertions();
    const { state, relaunch } = storage();
    await expect(
      relaunch().request('work', oneClickOffer, () => sentOn),
    ).resolves.toBe('sent');
    const unsubscribe = relaunch();

    await expect(
      unsubscribe.sentRequest('work', oneClickOffer, later(3)),
    ).resolves.toStrictEqual(sent);
    await expect(
      unsubscribe.sentRequest('home', oneClickOffer, later(3)),
    ).resolves.toBeUndefined();
    await expect(
      unsubscribe.sentRequest(
        'work',
        { ...oneClickOffer, identity: 'club.example' },
        later(3),
      ),
    ).resolves.toBeUndefined();
    // The record names the list, never how to leave it.
    expect(state.document).toBe(JSON.stringify({ requests: [sent] }));
  });

  it('offers Unsubscribe again after 14 days, and dates a new request', async () => {
    expect.hasAssertions();
    const { state, relaunch } = storage();
    const unsubscribe = relaunch();
    await unsubscribe.request('work', oneClickOffer, () => sentOn);

    await expect(
      unsubscribe.sentRequest(
        'work',
        oneClickOffer,
        sentOn + unsubscribeOfferReturnsAfter,
      ),
    ).resolves.toStrictEqual(sent);
    await expect(
      unsubscribe.sentRequest('work', oneClickOffer, later(15)),
    ).resolves.toBeUndefined();
    // Sending again replaces the Profile's earlier request for the list.
    await unsubscribe.request('work', oneClickOffer, () => later(15));
    await expect(
      unsubscribe.sentRequest('work', oneClickOffer, later(16)),
    ).resolves.toStrictEqual({ ...sent, sentAt: later(15) });
    expect(state.document).toBe(
      JSON.stringify({ requests: [{ ...sent, sentAt: later(15) }] }),
    );
  });

  it('records nothing for an offer without a List-Id, or after another sign-in', async () => {
    expect.hasAssertions();
    const { state, relaunch } = storage();
    const unsubscribe = relaunch();
    const { identity: _, ...withoutIdentity } = oneClickOffer;
    await expect(
      unsubscribe.request('work', withoutIdentity, () => sentOn),
    ).resolves.toBe('sent');
    await expect(
      unsubscribe.sentRequest('work', withoutIdentity, sentOn),
    ).resolves.toBeUndefined();

    // The answer arrives after another Product Account signed in: neither account records it.
    state.pending = () => {
      state.account = 'account-2';
    };
    await expect(
      unsubscribe.request('work', oneClickOffer, () => sentOn),
    ).resolves.toBe('sent');
    expect(state.document).toBeUndefined();
  });

  it('records nothing that could show a false Sent state', async () => {
    expect.hasAssertions();
    const { state, relaunch } = storage();
    const unsubscribe = relaunch();
    for (const outcome of ['failed', 'uncertain']) {
      state.outcome = outcome;
      await expect(
        unsubscribe.request('work', oneClickOffer, () => sentOn),
      ).resolves.toBe(outcome);
    }
    expect(state.document).toBeUndefined();

    // A write storage refuses leaves the outcome as it was and records nothing.
    state.outcome = 'sent';
    state.refuse = 'locked';
    await expect(
      unsubscribe.request('work', oneClickOffer, () => sentOn),
    ).resolves.toBe('sent');
    await expect(
      unsubscribe.sentRequest('work', oneClickOffer, sentOn),
    ).resolves.toBeUndefined();

    // A record storage cannot read, or another account's, reads as not sent.
    state.refuse = undefined;
    await unsubscribe.request('work', oneClickOffer, () => sentOn);
    state.document = '{"requests":[{"profile":"work"}]}';
    await expect(
      unsubscribe.sentRequest('work', oneClickOffer, sentOn),
    ).resolves.toBeUndefined();
    await unsubscribe.request('work', oneClickOffer, () => sentOn);
    state.account = 'account-2';
    await expect(
      unsubscribe.sentRequest('work', oneClickOffer, sentOn),
    ).resolves.toBeUndefined();
  });
});
