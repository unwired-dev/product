import type { Drafts } from './drafts.ts';
import type { GmailInbox } from './gmail-inbox.ts';
import type { MailboxConnection } from './registration.ts';

import { profileOf, sendingMailboxes } from './drafts.ts';

// Navigation away from an open composer: the composer registers how it finishes (completing
// recipients and saving), and every other destination asks to leave first. One request runs at a
// time, and a composer that cannot finish, or fails to, stays open for a later attempt.
export interface ComposerNavigation {
  readonly register: (finish: () => Promise<boolean | 'failed'>) => () => void;
  readonly leave: (draft?: string) => Promise<boolean>;
  readonly leaveResult: (draft?: string) => Promise<boolean | 'failed'>;
  // Starts a Draft only after leaving, and returns it only if no later destination was chosen.
  readonly create: (
    drafts: Pick<Drafts, 'create' | 'abandon'>,
    mailbox: Pick<MailboxConnection, 'id' | 'address'>,
    preparation?: Readonly<{
      prepare?: (id: string) => Promise<boolean>;
      // Preparation before creation, within the initiating account and navigation lifetime.
      before?: () => Promise<boolean>;
    }>,
  ) => Promise<string | undefined>;
  readonly createResult: (
    ...args: Parameters<ComposerNavigation['create']>
  ) => Promise<
    | Readonly<{ kind: 'created'; id: string }>
    | Readonly<{ kind: 'failed' }>
    | undefined
  >;
  readonly attachReceived: (
    drafts: Pick<Drafts, 'create' | 'abandon' | 'attach'>,
    attachment: Readonly<{
      // The reader's Mailbox Connection, which the Downloaded Attachment is read through.
      mailbox: string;
      mailboxes: readonly MailboxConnection[];
      saved: Readonly<NonNullable<ReturnType<GmailInbox['attachmentFile']>>>;
    }>,
  ) => Promise<string | undefined>;
}

export function createComposerNavigation(): ComposerNavigation {
  let finish: (() => Promise<boolean | 'failed'>) | undefined = undefined;
  let pending = false;
  let navigations = 0;
  let selectedDraft: string | undefined = undefined;
  const leaveResult: ComposerNavigation['leaveResult'] = async (draft) => {
    if (pending) {
      return false;
    }
    pending = true;
    try {
      const allowed = (await finish?.()) ?? true;
      if (allowed === true) {
        navigations += 1;
        selectedDraft = draft;
      }
      return allowed;
    } catch {
      // A composer that failed to finish stays open; a later attempt can leave again.
      return 'failed';
    } finally {
      pending = false;
    }
  };
  const leave: ComposerNavigation['leave'] = async (draft) =>
    (await leaveResult(draft)) === true;
  const createResult: ComposerNavigation['createResult'] = async (
    drafts,
    mailbox,
    { prepare, before } = {},
  ) => {
    let turn = navigations;
    let failed = false;
    const id = await drafts.create(mailbox, async () => {
      const allowed = await leaveResult();
      failed = allowed === 'failed';
      turn = navigations;
      return (
        allowed === true && ((await before?.()) ?? true) && navigations === turn
      );
    });
    if (id === undefined) {
      return failed ? { kind: 'failed' } : undefined;
    }
    if (prepare !== undefined && !(await prepare(id))) {
      // An empty Draft nobody opened is removed; one that gained content is kept.
      if (selectedDraft !== id) {
        await drafts.abandon(id);
      }
      return undefined;
    }
    if (navigations === turn) {
      return { kind: 'created', id };
    }
    // Selecting the new row while creation waits already opened this Draft; it is not abandoned.
    // Locked storage keeps the removal for the next successful save.
    if (selectedDraft !== id) {
      await drafts.abandon(id);
    }
    return undefined;
  };
  const create: ComposerNavigation['create'] = async (...args) => {
    const result = await createResult(...args);
    return result?.kind === 'created' ? result.id : undefined;
  };
  return {
    leave,
    leaveResult,
    createResult,
    register: (next) => {
      finish = next;
      return () => {
        if (finish === next) {
          finish = undefined;
        }
      };
    },
    create,
    attachReceived: async (drafts, { mailbox, mailboxes, saved }) => {
      // The new Draft sends from the reader's Mail Profile, never moving the file into another.
      const senders = sendingMailboxes(
        mailboxes,
        profileOf(mailbox, mailboxes),
      );
      const sender = senders.find(({ id }) => id === mailbox) ?? senders[0];
      if (sender === undefined) {
        return undefined;
      }
      return create(drafts, sender, {
        prepare: (id) =>
          drafts.attach(id, [
            {
              name: saved.name,
              type: saved.type,
              source: {
                kind: 'received',
                mailbox: {
                  connection: mailbox,
                  address: saved.address,
                  generation: saved.generation,
                },
                file: saved.file,
              },
            },
          ]),
      });
    },
  };
}
