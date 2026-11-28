import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';

// Gmail's vacation responder, read with the existing Gmail grant (#3039).
const vacationInbox = () => {
  const gmail = createSyntheticGmail();
  const answers: unknown[] = [];
  const requests: unknown[] = [];
  const saveAnswers: unknown[] = [];
  const saves: unknown[] = [];
  const reply = (replies: unknown[]) => {
    const next = replies.shift();
    return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
  };
  const inbox = createInboxStore({
    ...gmail.native,
    gmailRequest: (path, query, owner) => {
      if (path !== 'settings/vacation') {
        return gmail.native.gmailRequest(path, query, owner);
      }
      requests.push(query);
      return reply(answers);
    },
    gmailSaveVacation: (vacation) => {
      saves.push(vacation);
      return reply(saveAnswers);
    },
  });
  return { gmail, inbox, answers, requests, saveAnswers, saves };
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

  it('reads nothing before the Inbox opens', async () => {
    expect.hasAssertions();
    const { inbox, requests } = vacationInbox();
    await expect(inbox.outOfOffice()).resolves.toBeUndefined();
    expect(requests).toHaveLength(0);
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

// Saving the vacation responder; the settings grant it needs is asked for later (#3092).
describe("saving a Gmail mailbox's Out of Office", () => {
  it('saves the change over what Gmail stores now, keeping every field it does not name', async () => {
    expect.hasAssertions();
    const { inbox, answers, requests, saveAnswers, saves } = vacationInbox();
    await inbox.load();
    answers.push(
      answer({
        enableAutoReply: false,
        responseSubject: 'Away',
        responseBodyHtml: '<p>Away.</p>',
        restrictToDomain: true,
        startTime: '1795392000000',
        // A field Unwired does not read goes back as Gmail sent it.
        laterField: { kept: true },
      }),
    );
    const saved = {
      enableAutoReply: true,
      responseSubject: 'Back on Monday',
      responseBodyHtml: '<p>Away.</p>',
      startTime: '1795392000000',
    };
    saveAnswers.push(answer({ ...saved, laterField: { kept: true } }));

    await expect(
      inbox.saveOutOfOffice({
        enableAutoReply: true,
        responseSubject: 'Back on Monday',
        restrictToDomain: null,
        startTime: undefined,
      }),
    ).resolves.toStrictEqual({ kind: 'saved', vacation: saved });
    expect(requests).toStrictEqual([[]]);
    expect(saves).toStrictEqual([{ ...saved, laterField: { kept: true } }]);
  });

  it('answers permission when Gmail refuses the settings scope, and keeps the Inbox', async () => {
    expect.hasAssertions();
    const { inbox, answers, saveAnswers, saves } = vacationInbox();
    await inbox.load();
    answers.push(answer({}), answer({}));
    saveAnswers.push(
      answer(
        {
          error: {
            code: 403,
            message: 'Request had insufficient authentication scopes.',
            errors: [{ reason: 'insufficientPermissions' }],
          },
        },
        403,
      ),
      // A usage limit is a retry, not a missing scope.
      answer({ error: { errors: [{ reason: 'rateLimitExceeded' }] } }, 403),
    );
    await expect(
      inbox.saveOutOfOffice({ enableAutoReply: true }),
    ).resolves.toStrictEqual({ kind: 'unavailable', reason: 'permission' });
    await expect(
      inbox.saveOutOfOffice({ enableAutoReply: true }),
    ).resolves.toStrictEqual({ kind: 'unavailable', reason: 'offline' });
    expect(saves).toHaveLength(2);
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });
  });

  it('says why Gmail did not save, and a refused grant asks for Gmail again', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { inbox, answers, saveAnswers, saves } = vacationInbox();
    await inbox.load();
    // A read that fails sends no save.
    answers.push(answer([]), answer({}, 503), answer({}, 404));
    for (const reason of ['offline', 'offline', 'failed']) {
      await expect(
        inbox.saveOutOfOffice({ enableAutoReply: true }),
      ).resolves.toStrictEqual({ kind: 'unavailable', reason });
    }
    expect(saves).toHaveLength(0);

    answers.push(answer({}), answer({}), answer({}), answer({}));
    saveAnswers.push(
      // Gmail refuses the values, as for an end before the start.
      answer({}, 400),
      answer({}, 503),
      new Error('The request never left this device.'),
      answer({ enableAutoReply: 'yes' }),
    );
    for (const reason of ['failed', 'offline', 'offline', 'offline']) {
      await expect(
        inbox.saveOutOfOffice({ enableAutoReply: true }),
      ).resolves.toStrictEqual({ kind: 'unavailable', reason });
    }
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });

    answers.push(answer({}, 403));
    await expect(
      inbox.saveOutOfOffice({ enableAutoReply: true }),
    ).resolves.toStrictEqual({ kind: 'unavailable', reason: 'authentication' });
    expect(saves).toHaveLength(4);
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });
  });

  it('saves nothing before the Inbox opens, and drops an answer after it closed', async () => {
    expect.hasAssertions();
    const { inbox, answers, saveAnswers, saves } = vacationInbox();
    await expect(
      inbox.saveOutOfOffice({ enableAutoReply: true }),
    ).resolves.toBeUndefined();
    expect(saves).toHaveLength(0);

    await inbox.load();
    answers.push(answer({}));
    const { promise, resolve } = Promise.withResolvers<unknown>();
    saveAnswers.push(promise);
    const saving = inbox.saveOutOfOffice({ enableAutoReply: true });
    await vi.waitFor(() => {
      expect(saves).toHaveLength(1);
    });
    inbox.forget();
    resolve(answer({ enableAutoReply: true }));
    await expect(saving).resolves.toBeUndefined();
  });
});
