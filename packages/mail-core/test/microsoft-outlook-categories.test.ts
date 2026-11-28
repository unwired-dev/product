import { createInboxStore } from '@private-email/mail-core/inbox-store';
import { createSyntheticGmail } from '@private-email/mail-core/testing/gmail-mailbox';
import { createSyntheticGraph } from '@private-email/mail-core/testing/graph-mailbox';

// Outlook's category list, read when the connection holds `MailboxSettings.Read` (#3091).
const categoriesPath = '/v1.0/me/outlook/masterCategories';

const categoriesInbox = () => {
  const graph = createSyntheticGraph();
  const answers: unknown[] = [];
  const requests: string[] = [];
  const inbox = createInboxStore(
    {
      ...graph.native,
      graphRequest: (url, owner) => {
        if (new URL(url).pathname !== categoriesPath) {
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

describe("reading a Microsoft mailbox's Outlook category list", () => {
  it('reads each category with its colour preset as Graph stores them', async () => {
    expect.hasAssertions();
    const { inbox, answers, requests } = categoriesInbox();
    await inbox.load();
    answers.push(
      answer({
        '@odata.context': 'https://graph.microsoft.com/v1.0/$metadata',
        value: [
          {
            id: '5a9a6aa8-b65f-4357-b1f9-60c6bf6330d8',
            displayName: 'Red category',
            color: 'preset0',
          },
          { displayName: 'Receipts', color: 'preset24' },
          // Graph's own table spells the constants with a capital letter.
          { displayName: 'Travel', color: 'None' },
          { displayName: 'Family', color: 'Preset7' },
        ],
      }),
      answer({ value: [] }),
    );

    await expect(inbox.outlookCategories()).resolves.toStrictEqual({
      kind: 'found',
      categories: [
        { displayName: 'Red category', color: 'preset0' },
        { displayName: 'Receipts', color: 'preset24' },
        { displayName: 'Travel', color: 'none' },
        { displayName: 'Family', color: 'preset7' },
      ],
    });
    await expect(inbox.outlookCategories()).resolves.toStrictEqual({
      kind: 'found',
      categories: [],
    });
    expect(requests).toStrictEqual(
      Array.from(
        { length: 2 },
        () => `https://graph.microsoft.com${categoriesPath}`,
      ),
    );
  });

  it('says why Graph could not answer, and asks for mail again only when mail is refused', async () => {
    expect.hasAssertions();
    vi.spyOn(console, 'error').mockReturnValue();
    const { inbox, answers } = categoriesInbox();
    await inbox.load();
    answers.push(
      answer({ value: [{ displayName: 'Red category', color: 'preset25' }] }),
      answer({ value: [{ displayName: 'Red category' }] }),
      answer({ value: [{ color: 'preset0' }] }),
      answer({ categories: [] }),
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
      'offline',
      'failed',
      'offline',
    ]) {
      await expect(inbox.outlookCategories()).resolves.toStrictEqual({
        kind: 'unavailable',
        reason,
      });
    }
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });

    // A grant without MailboxSettings is refused with 403; mail itself still works.
    answers.push(answer({ error: { code: 'ErrorAccessDenied' } }, 403));
    await expect(inbox.outlookCategories()).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'permission',
    });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'current' });

    // Graph rejecting the token is the mail grant failing, as for any other read.
    answers.push(answer({}, 401));
    await expect(inbox.outlookCategories()).resolves.toStrictEqual({
      kind: 'unavailable',
      reason: 'authentication',
    });
    expect(inbox.getSnapshot()).toMatchObject({ sync: 'authentication' });
  });

  it('reads nothing before the Inbox opens, or for a Gmail mailbox', async () => {
    expect.hasAssertions();
    const { inbox, requests } = categoriesInbox();
    await expect(inbox.outlookCategories()).resolves.toBeUndefined();
    expect(requests).toHaveLength(0);

    const gmail = createInboxStore(createSyntheticGmail().native);
    await gmail.load();
    await expect(gmail.outlookCategories()).resolves.toBeUndefined();
  });

  it('drops an answer or a refusal that arrives after the Inbox closed', async () => {
    expect.hasAssertions();
    const { inbox, answers, requests } = categoriesInbox();
    for (const late of [answer({ value: [] }), answer({}, 403)]) {
      await inbox.load();
      const { promise, resolve } = Promise.withResolvers<unknown>();
      answers.push(promise);
      const reading = inbox.outlookCategories();
      inbox.forget();
      resolve(late);
      await expect(reading).resolves.toBeUndefined();
    }
    expect(requests).toHaveLength(2);
  });
});
