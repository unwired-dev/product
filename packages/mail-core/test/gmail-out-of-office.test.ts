import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';

// Gmail's vacation responder, read with the existing Gmail grant (#3039).
const vacationInbox = () => {
  const gmail = createSyntheticGmail();
  const answers: unknown[] = [];
  const requests: unknown[] = [];
  const inbox = createInboxStore({
    ...gmail.native,
    gmailRequest: (path, query, owner) => {
      if (path !== 'settings/vacation') {
        return gmail.native.gmailRequest(path, query, owner);
      }
      requests.push(query);
      const answer = answers.shift();
      return answer instanceof Error
        ? Promise.reject(answer)
        : Promise.resolve(answer);
    },
  });
  return { gmail, inbox, answers, requests };
};

const answer = (body: unknown, status = 200) => ({
  status,
  body: JSON.stringify(body),
});

describe("reading a Gmail mailbox's Out of Office", () => {
  it('reads the vacation responder as Gmail stores it, on or off', async () => {
    expect.hasAssertions();
    const { inbox, answers, requests } = vacationInbox();
    await inbox.load();
    const on = {
      enableAutoReply: true,
      responseSubject: 'Away until Nov 30',
      responseBodyPlainText: 'Thanks for your note.',
      responseBodyHtml: '<p>Thanks for your note.</p>',
      restrictToContacts: false,
      restrictToDomain: true,
      startTime: '1795392000000',
      endTime: '1795824000000',
    };
    answers.push(answer(on), answer({ enableAutoReply: false }), answer({}));

    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'found',
      vacation: on,
    });
    // Gmail leaves out what is off or empty, and nothing is filled in for it.
    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'found',
      vacation: { enableAutoReply: false },
    });
    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'found',
      vacation: {},
    });
    expect(requests).toStrictEqual([[], [], []]);
  });

  it('says why Gmail could not answer, and a refused grant asks for Gmail again', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { inbox, answers } = vacationInbox();
    await inbox.load();
    answers.push(
      answer({ enableAutoReply: 'yes' }),
      answer({ startTime: 'tomorrow' }),
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
      'failed',
      'offline',
    ]) {
      await expect(inbox.outOfOffice()).resolves.toStrictEqual({
        kind: 'unavailable',
        reason,
      });
    }
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });

    answers.push(answer({}, 401));
    await expect(inbox.outOfOffice()).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'authentication',
    });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });
  });

  it('reads nothing before the Inbox opens or for Microsoft mail', async () => {
    expect.hasAssertions();
    const { inbox, requests } = vacationInbox();
    await expect(inbox.outOfOffice()).resolves.toBeUndefined();
    expect(requests).toHaveLength(0);

    const graph = createSyntheticGraph();
    const microsoft = createInboxStore(graph.native, {
      provider: 'microsoft-graph',
    });
    await microsoft.load();
    await expect(microsoft.outOfOffice()).resolves.toBeUndefined();
  });

  it('drops an answer or a refusal that arrives after the Inbox closed', async () => {
    expect.hasAssertions();
    const { inbox, answers, requests } = vacationInbox();
    // Native code refuses an answer for a mailbox replaced meanwhile, as it does for search.
    for (const late of [answer({ enableAutoReply: true }), answer({}, 404)]) {
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
