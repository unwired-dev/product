import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';

// Outlook's automatic replies, read when the connection holds `MailboxSettings.Read` (#3050).
const automaticRepliesPath = '/v1.0/me/mailboxSettings/automaticRepliesSetting';

const repliesInbox = () => {
  const graph = createSyntheticGraph();
  const answers: unknown[] = [];
  const requests: string[] = [];
  const saveAnswers: unknown[] = [];
  const saves: unknown[] = [];
  const reply = (replies: unknown[]) => {
    const next = replies.shift();
    return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
  };
  const inbox = createInboxStore(
    {
      ...graph.native,
      graphRequest: (url, owner) => {
        if (new URL(url).pathname !== automaticRepliesPath) {
          return graph.native.graphRequest(url, owner);
        }
        requests.push(url);
        return reply(answers);
      },
      graphSaveAutomaticReplies: (automaticReplies) => {
        saves.push(automaticReplies);
        return reply(saveAnswers);
      },
    },
    { provider: 'microsoft-graph' },
  );
  return { inbox, answers, requests, saveAnswers, saves };
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
      // Graph's own example spells the values with a capital letter.
      answer({ status: 'Disabled', externalAudience: 'None' }),
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
      answer({
        status: 'scheduled',
        scheduledStartDateTime: { dateTime: 'tomorrow', timeZone: 'UTC' },
      }),
      answer({
        status: 'scheduled',
        scheduledEndDateTime: {
          dateTime: '2026-02-30T10:00:00',
          timeZone: 'UTC',
        },
      }),
      answer({}, 503),
      new Error('The request never left this device.'),
      answer({}, 404),
      answer({}, 410),
      answer({}, 500),
    );
    for (const reason of [
      'offline',
      'offline',
      'offline',
      'offline',
      'offline',
      'offline',
      'offline',
      'failed',
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

  it('saves no Gmail change', async () => {
    expect.hasAssertions();
    const { inbox, requests, saves } = repliesInbox();
    await inbox.load();
    await expect(
      inbox.saveOutOfOffice({ vacation: { enableAutoReply: true } }),
    ).resolves.toBeUndefined();
    expect(requests).toHaveLength(0);
    expect(saves).toHaveLength(0);
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

// Saving the automatic replies; the MailboxSettings.ReadWrite grant it needs is asked for later
// (#3124).
describe("saving a Microsoft mailbox's automatic replies", () => {
  const stored = {
    status: 'scheduled',
    externalAudience: 'all',
    internalReplyMessage: '<p>Away.</p>',
    externalReplyMessage: '<p>Away.</p>',
    scheduledStartDateTime: {
      dateTime: '2026-11-30T07:00:00.0000000',
      timeZone: 'UTC',
    },
    scheduledEndDateTime: {
      dateTime: '2026-12-07T07:00:00.0000000',
      timeZone: 'UTC',
    },
  } as const;
  const saved = (automaticRepliesSetting: unknown) =>
    answer({
      '@odata.context':
        'https://graph.microsoft.com/v1.0/$metadata#Me/mailboxSettings',
      automaticRepliesSetting,
    });

  it("sends only the named fields, and Graph's answer is what it saved", async () => {
    expect.hasAssertions();
    const { inbox, requests, saveAnswers, saves } = repliesInbox();
    await inbox.load();
    saveAnswers.push(saved({ ...stored, status: 'Scheduled' }));
    const change = {
      status: 'scheduled',
      scheduledStartDateTime: stored.scheduledStartDateTime,
      scheduledEndDateTime: stored.scheduledEndDateTime,
    } as const;

    await expect(
      inbox.saveOutOfOffice({ automaticReplies: change }),
    ).resolves.toStrictEqual({ kind: 'saved', automaticReplies: stored });
    // Graph keeps what it is not sent, so nothing is read first.
    expect(requests).toHaveLength(0);
    expect(saves).toStrictEqual([change]);
  });

  it('saves one change after another', async () => {
    expect.hasAssertions();
    const { inbox, saveAnswers, saves } = repliesInbox();
    await inbox.load();
    const first = Promise.withResolvers<unknown>();
    saveAnswers.push(first.promise, saved({ ...stored, status: 'disabled' }));
    const on = inbox.saveOutOfOffice({
      automaticReplies: { status: 'alwaysEnabled' },
    });
    const off = inbox.saveOutOfOffice({
      automaticReplies: { status: 'disabled' },
    });
    await vi.waitFor(() => {
      expect(saves).toHaveLength(1);
    });
    first.resolve(saved({ ...stored, status: 'alwaysEnabled' }));
    await expect(on).resolves.toMatchObject({
      automaticReplies: { status: 'alwaysEnabled' },
    });
    await expect(off).resolves.toMatchObject({
      automaticReplies: { status: 'disabled' },
    });
    expect(saves).toStrictEqual([
      { status: 'alwaysEnabled' },
      { status: 'disabled' },
    ]);
  });

  it('says why Graph did not save, and asks for mail again only when mail is refused', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { inbox, saveAnswers, saves } = repliesInbox();
    await inbox.load();
    saveAnswers.push(
      // A grant without MailboxSettings.ReadWrite; mail itself still works.
      answer({ error: { code: 'ErrorAccessDenied' } }, 403),
      // Graph refuses the values, as for an end before the start.
      answer({ error: { code: 'ErrorInvalidRequest' } }, 400),
      answer({}, 404),
      answer({}, 503),
      answer({}, 429),
      new Error('The request never left this device.'),
      saved({ status: 'sometimes' }),
      answer({
        '@odata.context': 'https://graph.microsoft.com/v1.0/$metadata',
      }),
    );
    for (const reason of [
      'permission',
      'failed',
      'failed',
      'offline',
      'offline',
      'offline',
      'offline',
      'offline',
    ]) {
      await expect(
        inbox.saveOutOfOffice({ automaticReplies: { status: 'disabled' } }),
      ).resolves.toStrictEqual({ kind: 'unavailable', reason });
    }
    expect(saves).toHaveLength(8);
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });

    saveAnswers.push(answer({}, 401));
    await expect(
      inbox.saveOutOfOffice({ automaticReplies: { status: 'disabled' } }),
    ).resolves.toStrictEqual({ kind: 'unavailable', reason: 'authentication' });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });
  });

  it('saves nothing before the Inbox opens, and drops an answer after it closed', async () => {
    expect.hasAssertions();
    const { inbox, saveAnswers, saves } = repliesInbox();
    await expect(
      inbox.saveOutOfOffice({ automaticReplies: { status: 'disabled' } }),
    ).resolves.toBeUndefined();
    expect(saves).toHaveLength(0);

    for (const [index, late] of [saved(stored), answer({}, 403)].entries()) {
      await inbox.load();
      const { promise, resolve } = Promise.withResolvers<unknown>();
      saveAnswers.push(promise);
      const saving = inbox.saveOutOfOffice({
        automaticReplies: { status: 'disabled' },
      });
      await vi.waitFor(() => {
        expect(saves).toHaveLength(index + 1);
      });
      inbox.forget();
      resolve(late);
      await expect(saving).resolves.toBeUndefined();
    }
  });

  it('sends no save that the Inbox closed before, while it waited', async () => {
    expect.hasAssertions();
    const { inbox, saveAnswers, saves } = repliesInbox();
    await inbox.load();
    const { promise, resolve } = Promise.withResolvers<unknown>();
    saveAnswers.push(promise);
    const first = inbox.saveOutOfOffice({
      automaticReplies: { status: 'alwaysEnabled' },
    });
    const queued = inbox.saveOutOfOffice({
      automaticReplies: { status: 'disabled' },
    });
    await vi.waitFor(() => {
      expect(saves).toHaveLength(1);
    });
    inbox.forget();
    resolve(saved(stored));
    await expect(first).resolves.toBeUndefined();
    await expect(queued).resolves.toBeUndefined();
    expect(saves).toHaveLength(1);
  });
});
