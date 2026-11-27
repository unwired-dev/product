import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';

// Outlook's automatic replies, read when the connection holds `MailboxSettings.Read` (#3050).
const automaticRepliesPath = '/v1.0/me/mailboxSettings/automaticRepliesSetting';

const repliesInbox = () => {
  const graph = createSyntheticGraph();
  const answers: unknown[] = [];
  const requests: string[] = [];
  const inbox = createInboxStore(
    {
      ...graph.native,
      graphRequest: (url, owner) => {
        if (new URL(url).pathname !== automaticRepliesPath) {
          return graph.native.graphRequest(url, owner);
        }
        requests.push(url);
        const answer = answers.shift();
        return answer instanceof Error
          ? Promise.reject(answer)
          : Promise.resolve(answer);
      },
    },
    { provider: 'microsoft-graph' },
  );
  return { inbox, answers, requests };
};

const answer = (body: unknown, status = 200) => ({
  status,
  body: JSON.stringify(body),
});

describe("reading a Microsoft mailbox's automatic replies", () => {
  it('reads the automatic replies as Graph stores them', async () => {
    expect.hasAssertions();
    const { inbox, answers, requests } = repliesInbox();
    await inbox.load();
    const scheduled = {
      status: 'scheduled',
      externalAudience: 'contactsOnly',
      internalReplyMessage: '<p>Back on Monday.</p>',
      externalReplyMessage: 'Back on Monday.',
      scheduledStartDateTime: {
        dateTime: '2026-11-30T07:00:00.0000000',
        timeZone: 'UTC',
      },
      scheduledEndDateTime: {
        dateTime: '2026-12-07T07:00:00.0000000',
        timeZone: 'Pacific Standard Time',
      },
    };
    answers.push(
      answer({
        '@odata.context': 'https://graph.microsoft.com/v1.0/$metadata',
        ...scheduled,
      }),
      answer({ status: 'disabled', externalAudience: 'none' }),
      answer({ status: 'alwaysEnabled', internalReplyMessage: '' }),
    );

    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'found',
      automaticReplies: scheduled,
    });
    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'found',
      automaticReplies: { status: 'disabled', externalAudience: 'none' },
    });
    // Graph leaves out what is not set, and nothing is filled in for it.
    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'found',
      automaticReplies: { status: 'alwaysEnabled', internalReplyMessage: '' },
    });
    expect(requests).toStrictEqual(
      Array.from(
        { length: 3 },
        () => `https://graph.microsoft.com${automaticRepliesPath}`,
      ),
    );
  });

  it('says why Graph could not answer, and asks for mail again only when mail is refused', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { inbox, answers } = repliesInbox();
    await inbox.load();
    answers.push(
      answer({ status: 'sometimes' }),
      answer({ status: 'scheduled', scheduledStartDateTime: '2026-11-30' }),
      answer({ externalAudience: 'all' }),
      answer({}, 503),
      new Error('The request never left this device.'),
      answer({}, 404),
      answer({}, 500),
    );
    for (const reason of [
      'offline',
      'offline',
      'offline',
      'offline',
      'offline',
      'failed',
      'offline',
    ]) {
      await expect(inbox.outOfOffice()).resolves.toStrictEqual({
        kind: 'unavailable',
        reason,
      });
    }
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });

    // A grant without MailboxSettings is refused with 403; mail itself still works.
    answers.push(answer({ error: { code: 'ErrorAccessDenied' } }, 403));
    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'permission',
    });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });

    // Graph rejecting the token is the mail grant failing, as for any other read.
    answers.push(answer({}, 401));
    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'authentication',
    });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });
  });

  it('reads nothing before the Inbox opens', async () => {
    expect.hasAssertions();
    const { inbox, requests } = repliesInbox();
    await expect(inbox.outOfOffice()).resolves.toBeUndefined();
    expect(requests).toHaveLength(0);
  });

  it('drops an answer or a refusal that arrives after the Inbox closed', async () => {
    expect.hasAssertions();
    const { inbox, answers, requests } = repliesInbox();
    for (const late of [answer({ status: 'alwaysEnabled' }), answer({}, 403)]) {
      await inbox.load();
      const { promise, resolve } = Promise.withResolvers<unknown>();
      answers.push(promise);
      const reading = inbox.outOfOffice();
      inbox.forget();
      resolve(late);
      await expect(reading).resolves.toBeUndefined();
    }
    expect(requests).toHaveLength(2);
  });
});
