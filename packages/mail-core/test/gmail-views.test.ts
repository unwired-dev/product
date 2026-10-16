import type { GmailInboxState, GmailView } from '../src/gmail-inbox.ts';

import { allMail, gmailAction } from '../src/gmail-actions.ts';
import { createGmailInbox } from '../src/gmail-inbox.ts';
import { createSyntheticGmail } from '../src/testing/gmail-mailbox.ts';

// The views a mailbox keeps besides its Inbox.
const cachedViews = 8;
// The newest messages each view keeps.
const cacheLimit = 200;

const ready = (state: GmailInboxState) => {
  if (state.kind !== 'ready') {
    throw new Error(`Expected a ready Inbox, received ${state.kind}`);
  }
  return state;
};

const view = (
  inbox: ReturnType<typeof createGmailInbox>,
  label: string,
): GmailView => {
  const found = ready(inbox.getSnapshot()).views?.find(
    (entry) => entry.label === label,
  );
  if (found === undefined) {
    throw new Error(`View ${label} is not open`);
  }
  return found;
};

const ids = (messages: ReadonlyArray<Readonly<{ id: string }>>) =>
  messages.map(({ id }) => id);

const first = <A>(messages: readonly A[]): A => {
  const [message] = messages;
  if (message === undefined) {
    throw new Error('Expected a listed message');
  }
  return message;
};

// Gmail answers a listing of any view but the Inbox with a server error while `failing` says so.
const failingViews = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
  failing: () => boolean,
): ReturnType<typeof createSyntheticGmail>['native'] => ({
  ...native,
  gmailRequest: (path, query, mailbox) =>
    failing() &&
    path === 'messages' &&
    query.some(([name, value]) => name === 'labelIds' && value !== 'INBOX')
      ? Promise.resolve({ status: 503, body: '{}' })
      : native.gmailRequest(path, query, mailbox),
});

// Gmail answers history with a server error while `failing` says so.
const failingHistory = (
  native: ReturnType<typeof createSyntheticGmail>['native'],
  failing: () => boolean,
): ReturnType<typeof createSyntheticGmail>['native'] => ({
  ...native,
  gmailRequest: (path, query, mailbox) =>
    failing() && path === 'history'
      ? Promise.resolve({ status: 503, body: '{}' })
      : native.gmailRequest(path, query, mailbox),
});

const viewListings = (gmail: ReturnType<typeof createSyntheticGmail>) =>
  gmail.requests.filter(
    ({ path, query }) =>
      path === 'messages' && query.get('labelIds') !== 'INBOX',
  );

// The second label page fails once after a new message arrives and history can observe it.
const interruptedView = (
  gmail: ReturnType<typeof createSyntheticGmail>,
  travel: string,
) => {
  let arrived: string | undefined = undefined;
  const native: typeof gmail.native = {
    ...gmail.native,
    gmailRequest: (path, query, mailbox) => {
      if (
        arrived === undefined &&
        path === 'messages' &&
        query.some(
          ([name, value]) => name === 'labelIds' && value === travel,
        ) &&
        query.some(([name]) => name === 'pageToken')
      ) {
        arrived = gmail.deliver({ subject: 'Arrived during interruption' });
        gmail.setLabel(arrived, travel, true);
        return Promise.resolve({ status: 503, body: '{}' });
      }
      return gmail.native.gmailRequest(path, query, mailbox);
    },
  };
  return { native, arrived: () => arrived };
};

// An interrupted label listing observes an arrival while another full view needs a refill.
const interruptedRefill = (
  gmail: ReturnType<typeof createSyntheticGmail>,
  {
    travel,
    receipts,
    receipt,
  }: Readonly<{
    travel: string;
    receipts: string;
    receipt: string;
  }>,
) => {
  let failing = false;
  let arrived: string | undefined = undefined;
  const native: typeof gmail.native = {
    ...gmail.native,
    gmailRequest: (path, query, mailbox) => {
      const label = query.find(([name]) => name === 'labelIds')?.[1];
      if (failing && path === 'messages') {
        if (label === travel && query.some(([name]) => name === 'pageToken')) {
          if (arrived === undefined) {
            arrived = gmail.deliver({ subject: 'Arrived during interruption' });
            gmail.setLabel(arrived, travel, true);
            gmail.setLabel(receipt, receipts, false);
          }
          return Promise.resolve({ status: 503, body: '{}' });
        }
        if (arrived !== undefined && label === receipts) {
          return Promise.resolve({ status: 503, body: '{}' });
        }
      }
      return gmail.native.gmailRequest(path, query, mailbox);
    },
  };
  return {
    native,
    arrived: () => arrived,
    interrupt: () => {
      failing = true;
    },
    resume: () => {
      failing = false;
    },
  };
};

describe('browsing Gmail views other than the Inbox', () => {
  /* oxlint-disable vitest/max-expects -- Each journey proves one view's path end to end. */
  it('lists labels, All Mail, Spam and Trash and keeps them current through history and relaunch', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const flight = gmail.deliver({ subject: 'Flight to Zagreb' });
    const hotel = gmail.deliver({ subject: 'Hotel booking' });
    const lunch = gmail.deliver({ subject: 'Lunch' });
    const offer = gmail.deliver({ subject: 'Winning offer' });
    gmail.setLabel(flight, travel, true);
    gmail.setLabel(hotel, travel, true);
    gmail.archive(hotel);
    gmail.setLabel(offer, 'SPAM', true);
    gmail.setLabel(offer, 'INBOX', false);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    expect(ids(ready(inbox.getSnapshot()).messages)).toStrictEqual([
      lunch,
      flight,
    ]);

    await inbox.openView(travel);
    expect(view(inbox, travel)).toMatchObject({ status: 'current' });
    // An archived message keeps its label.
    expect(ids(view(inbox, travel).messages)).toStrictEqual([hotel, flight]);
    await inbox.readMessage(hotel);
    expect(inbox.messageBody(hotel)?.kind).toBe('ready');
    await inbox.openView(allMail);
    expect(ids(view(inbox, allMail).messages)).toStrictEqual([
      lunch,
      hotel,
      flight,
    ]);
    await inbox.openView('SPAM');
    expect(ids(view(inbox, 'SPAM').messages)).toStrictEqual([offer]);
    // The All Mail listing asked Gmail for every message outside Spam and Trash.
    expect(
      viewListings(gmail).map(({ query }) => query.get('labelIds')),
    ).toStrictEqual([travel, null, 'SPAM']);
    // The most recently opened view comes first.
    expect(
      ready(inbox.getSnapshot()).views?.map(({ label }) => label),
    ).toStrictEqual(['SPAM', allMail, travel]);

    // Changes made in Gmail reach every cached view through the mailbox's history.
    gmail.setLabel(lunch, travel, true);
    gmail.setLabel(flight, 'TRASH', true);
    gmail.setLabel(flight, 'INBOX', false);
    const listed = viewListings(gmail).length;
    const relaunched = createGmailInbox(gmail.native);
    await relaunched.load();
    expect(ids(view(relaunched, travel).messages)).toStrictEqual([
      lunch,
      hotel,
    ]);
    expect(ids(view(relaunched, allMail).messages)).toStrictEqual([
      lunch,
      hotel,
    ]);
    expect(ids(ready(relaunched.getSnapshot()).messages)).toStrictEqual([
      lunch,
    ]);
    // Relaunch read history only; no view was listed again.
    expect(viewListings(gmail)).toHaveLength(listed);
    await relaunched.readMessage(hotel);
    expect(relaunched.messageBody(hotel)?.kind).toBe('ready');

    // Trash lists the trashed message; moving it back shows it in the Inbox and its label at once.
    await relaunched.openView('TRASH');
    const trashed = first(view(relaunched, 'TRASH').messages);
    expect(trashed.id).toBe(flight);
    const restoring = relaunched.organize(
      trashed,
      gmailAction.restore('TRASH'),
    );
    expect(view(relaunched, 'TRASH').messages).toStrictEqual([]);
    expect(ids(ready(relaunched.getSnapshot()).messages)).toContain(flight);
    expect(ids(view(relaunched, travel).messages)).toContain(flight);
    await restoring;
    expect(gmail.modifies.at(-1)).toStrictEqual({
      id: flight,
      add: ['INBOX'],
      remove: ['TRASH'],
    });
    expect(gmail.labelsOf(flight)).toContain('INBOX');
    expect(gmail.labelsOf(flight)).not.toContain('TRASH');
    expect(ids(view(relaunched, travel).messages)).toContain(flight);
  });

  it('moves a message out of the label it was shown in, keeping its other labels', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const receipts = gmail.createLabel('Receipts');
    const archive = gmail.createLabel('Archive 2026');
    const receipt = gmail.deliver({ subject: 'Your receipt' });
    gmail.setLabel(receipt, receipts, true);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await inbox.openView(receipts);
    await inbox.organize(
      first(view(inbox, receipts).messages),
      gmailAction.move(archive, receipts),
    );
    expect(gmail.modifies.at(-1)).toStrictEqual({
      id: receipt,
      add: [archive],
      remove: [receipts],
    });
    expect(view(inbox, receipts).messages).toStrictEqual([]);
    // The message stays in the Inbox, now under its new label.
    expect(ready(inbox.getSnapshot()).messages).toContainEqual(
      expect.objectContaining({ id: receipt }),
    );
    expect(gmail.labelsOf(receipt)).toStrictEqual(
      expect.arrayContaining(['INBOX', archive]),
    );
  });

  it('keeps history changes when an interrupted label listing resumes after relaunch', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    for (let index = 0; index < 51; index += 1) {
      const id = gmail.deliver({ subject: `Flight ${index}` });
      gmail.setLabel(id, travel, true);
    }
    const interrupted = interruptedView(gmail, travel);
    const { native } = interrupted;
    const inbox = createGmailInbox(native);
    await inbox.load();
    await inbox.openView(travel);
    expect(view(inbox, travel).status).toBe('failed');
    expect(ids(view(inbox, travel).messages)).toContain(interrupted.arrived());

    const relaunched = createGmailInbox(native);
    await relaunched.load();
    expect(view(relaunched, travel).status).toBe('current');
    expect(ids(view(relaunched, travel).messages)).toContain(
      interrupted.arrived(),
    );
    expect(view(relaunched, travel).messages).toHaveLength(52);
  });

  it('keeps a message visible when moving it to its current label', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const id = gmail.deliver({ subject: 'Flight' });
    gmail.setLabel(id, travel, true);
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await inbox.openView(travel);
    const moving = inbox.organize(
      first(view(inbox, travel).messages),
      gmailAction.move(travel, travel),
    );
    expect(ids(view(inbox, travel).messages)).toContain(id);
    await moving;
    expect(ids(view(inbox, travel).messages)).toContain(id);
    expect(gmail.modifies.at(-1)).toMatchObject({ add: [travel], remove: [] });
  });

  it('replays the earliest history when two interrupted view listings resume after relaunch', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const receipts = gmail.createLabel('Receipts');
    const receiptIds = Array.from({ length: 200 }, (_, index) => {
      const id = gmail.deliver({ subject: `Receipt ${index}` });
      gmail.setLabel(id, receipts, true);
      return id;
    });
    for (let index = 0; index < 51; index += 1) {
      const id = gmail.deliver({ subject: `Flight ${index}` });
      gmail.setLabel(id, travel, true);
    }
    const interrupted = interruptedRefill(gmail, {
      travel,
      receipts,
      receipt: first(receiptIds),
    });
    const { native } = interrupted;
    const inbox = createGmailInbox(native);
    await inbox.load();
    await inbox.openView(receipts);
    interrupted.interrupt();
    await inbox.openView(travel);
    expect(view(inbox, travel).status).toBe('failed');
    expect(view(inbox, receipts).status).toBe('failed');
    expect(ids(view(inbox, travel).messages)).toContain(interrupted.arrived());
    inbox.forget();

    interrupted.resume();
    const relaunched = createGmailInbox(native);
    await relaunched.load();
    expect(view(relaunched, travel).status).toBe('current');
    expect(view(relaunched, receipts).status).toBe('current');
    expect(ids(view(relaunched, travel).messages)).toContain(
      interrupted.arrived(),
    );
    expect(view(relaunched, travel).messages).toHaveLength(52);
    await relaunched.load();
    expect(ids(view(relaunched, travel).messages)).toContain(
      interrupted.arrived(),
    );
  });

  it('keeps a view whose read fails with its saved messages, and drops a label Gmail removed', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const travel = gmail.createLabel('Travel');
    const projects = gmail.createLabel('Projects');
    const flight = gmail.deliver({ subject: 'Flight' });
    gmail.setLabel(flight, travel, true);
    let failing = false;
    const inbox = createGmailInbox(failingViews(gmail.native, () => failing));
    await inbox.load();
    failing = true;
    await inbox.openView(projects);
    // The view that could not be read says so; the Inbox stays current.
    expect(view(inbox, projects)).toStrictEqual({
      label: projects,
      messages: [],
      status: 'failed',
      limited: true,
    });
    expect(ready(inbox.getSnapshot()).sync).toBe('current');

    failing = false;
    await inbox.openView(travel);
    failing = true;
    // A full listing again after an expired history fails; the saved messages stay visible.
    gmail.expireHistory();
    gmail.deliver({ subject: 'After the gap' });
    await inbox.load();
    expect(view(inbox, travel)).toMatchObject({ status: 'failed' });
    expect(ids(view(inbox, travel).messages)).toStrictEqual([flight]);
    failing = false;
    await inbox.load();
    expect(view(inbox, travel)).toMatchObject({ status: 'current' });

    gmail.deleteLabel(travel);
    await inbox.load();
    expect(
      ready(inbox.getSnapshot()).views?.map(({ label }) => label),
    ).toStrictEqual([projects]);
    // A label Gmail does not list opens nothing.
    await inbox.openView(travel);
    expect(
      ready(inbox.getSnapshot()).views?.map(({ label }) => label),
    ).toStrictEqual([projects]);
  });

  it('protects concurrent window views and releases only the closing window lease', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const labels = Array.from({ length: cachedViews + 1 }, (_, index) =>
      gmail.createLabel(`Window ${index}`),
    );
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const releases = labels.map((label) => inbox.retainView(label));
    try {
      for (const label of labels) {
        await inbox.openView(label);
      }
      expect(ready(inbox.getSnapshot()).views).toHaveLength(cachedViews + 1);
      const oldest = first(labels);
      const releaseShared = inbox.retainView(oldest);
      releases.push(releaseShared);
      first(releases)();
      await inbox.load();
      expect(ready(inbox.getSnapshot()).views).toHaveLength(cachedViews + 1);
      expect(view(inbox, oldest).status).toBe('current');
      releaseShared();
      await inbox.load();
      expect(ready(inbox.getSnapshot()).views).toHaveLength(cachedViews);
      expect(
        ready(inbox.getSnapshot()).views?.map(({ label }) => label),
      ).not.toContain(oldest);
    } finally {
      for (const release of releases) {
        release();
      }
    }
  });

  it('keeps eight inactive views while a reader still holds a removed label', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const [removed = '', ...others] = Array.from(
      { length: cachedViews + 1 },
      (_, index) => gmail.createLabel(`Label ${index}`),
    );
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const release = inbox.retainView(removed);
    await inbox.openView(removed);
    gmail.deleteLabel(removed);
    await inbox.load();
    for (const label of others) {
      await inbox.openView(label);
    }
    await inbox.load();
    // The stale lease protects nothing, so all eight other views stay cached.
    expect(
      ready(inbox.getSnapshot()).views?.map(({ label }) => label),
    ).toHaveLength(cachedViews);
    release();
  });

  it('refills a full label when Gmail no longer has a message being organized', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const receipts = gmail.createLabel('Receipts');
    const messages = Array.from({ length: cacheLimit + 1 }, () => {
      const id = gmail.deliver();
      gmail.setLabel(id, receipts, true);
      gmail.archive(id);
      return id;
    });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    await inbox.openView(receipts);
    const selected = first(view(inbox, receipts).messages);
    gmail.remove(selected.id);
    await inbox.organize(selected, gmailAction.read);
    expect(view(inbox, receipts).status).toBe('current');
    expect(view(inbox, receipts).messages).toHaveLength(cacheLimit);
    expect(ids(view(inbox, receipts).messages)).toContain(first(messages));
    expect(ids(view(inbox, receipts).messages)).not.toContain(selected.id);
  });

  it('keeps a full Inbox bounded when a restored message joins it and history cannot be read', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: cacheLimit });
    const receipt = gmail.deliver({ subject: 'Old receipt' });
    gmail.setLabel(receipt, 'TRASH', true);
    gmail.setLabel(receipt, 'INBOX', false);
    let historyFails = false;
    const inbox = createGmailInbox(
      failingHistory(gmail.native, () => historyFails),
    );
    await inbox.load();
    await inbox.openView('TRASH');
    historyFails = true;
    await inbox.organize(
      first(view(inbox, 'TRASH').messages),
      gmailAction.restore('TRASH'),
    );
    // The restored message is newest; the oldest leaves rather than growing the cache.
    const { messages } = ready(inbox.getSnapshot());
    expect(messages).toHaveLength(cacheLimit);
    expect(messages[0]?.id).toBe(receipt);
  });

  it('keeps a bounded number of views and lists a full view again when one of its messages leaves', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail({ messages: 201 });
    const inbox = createGmailInbox(gmail.native);
    await inbox.load();
    const labels = Array.from({ length: cachedViews + 1 }, (_, index) =>
      gmail.createLabel(`Label ${index}`),
    );
    await inbox.load();
    for (const label of labels) {
      await inbox.openView(label);
    }
    const open = ready(inbox.getSnapshot()).views?.map(({ label }) => label);
    expect(open).toHaveLength(cachedViews);
    expect(open?.[0]).toBe(labels.at(-1));
    expect(open).not.toContain(labels[0]);

    await inbox.openView(allMail);
    expect(view(inbox, allMail).messages).toHaveLength(200);
    const newest = first(view(inbox, allMail).messages);
    gmail.setLabel(newest.id, 'TRASH', true);
    const listed = viewListings(gmail).length;
    await inbox.load();
    // The oldest message, which history never names, fills the place the trashed one left.
    expect(view(inbox, allMail).messages).toHaveLength(200);
    expect(ids(view(inbox, allMail).messages)).not.toContain(newest.id);
    expect(viewListings(gmail).length).toBeGreaterThan(listed);
  });
  /* oxlint-enable vitest/max-expects */
});
