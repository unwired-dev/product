import type { NativeGmailMailboxes } from '@private-email/mail-core/mailboxes';

import {
  createSyntheticGmail,
  syntheticConnections,
} from '@private-email/mail-core/testing/gmail-mailbox';
import { syntheticMailboxes } from '@private-email/mail-core/testing/registration-session';
import { createSyntheticVault } from '@private-email/mail-core/testing/registration-vault';
import { TurboModuleRegistry } from 'react-native';

import { gmailMailboxes, registration } from '../src/registration.ts';

const required = <Value,>(value: Value | undefined): Value => {
  if (value === undefined) {
    throw new Error('Expected a host Inbox attachment');
  }
  return value;
};

function legacySignalSurface() {
  const original = Object.getOwnPropertyDescriptor(
    AbortSignal.prototype,
    'throwIfAborted',
  );
  Object.defineProperty(AbortSignal.prototype, 'throwIfAborted', {
    value: undefined,
    configurable: true,
  });
  return () => {
    if (original === undefined) {
      Reflect.deleteProperty(AbortSignal.prototype, 'throwIfAborted');
    } else {
      Object.defineProperty(AbortSignal.prototype, 'throwIfAborted', original);
    }
  };
}

function holdAttachment(base: NativeGmailMailboxes) {
  let started: () => void = () => undefined;
  // oxlint-disable-next-line promise/avoid-new -- Observe the native request before cancellation.
  const downloading = new Promise<void>((resolve) => {
    started = resolve;
  });
  let rejectRead: () => void = () => undefined;
  let hold = true;
  const transport: NativeGmailMailboxes = {
    ...base,
    gmailRequest: (path, query, scope) => {
      if (hold && path.includes('/attachments/')) {
        started();
        // oxlint-disable-next-line promise/avoid-new -- Hold the external boundary until cancellation.
        return new Promise((_resolve, reject) => {
          rejectRead = () => {
            reject(new Error('cancelled'));
          };
        });
      }
      return base.gmailRequest(path, query, scope);
    },
  };
  return {
    transport,
    downloading,
    cancel: () => {
      rejectRead();
    },
    retry: () => {
      hold = false;
    },
  };
}

// Real host adapter and stores; only the native module/provider boundary is synthetic.
describe('attachment transfer cancellation bridge', () => {
  it('downloads, interrupts and retries with the installed hosts AbortSignal surface', async () => {
    expect.hasAssertions();
    const gmail = createSyntheticGmail();
    const id = gmail.deliver({ content: { text: 'Notes attached.' } });
    const { vault } = createSyntheticVault();
    const base = syntheticConnections({
      [syntheticMailboxes['alex@example.invalid']]: gmail,
    });
    const { transport, downloading, cancel, retry } = holdAttachment(base);
    const bridge = {
      ...vault,
      ...transport,
      getConstants: () => ({}),
      cancelGmailRequest: jest.fn(cancel),
    };
    const module = jest
      .spyOn(TurboModuleRegistry, 'getEnforcing')
      .mockReturnValue(bridge);
    // Installed React Native uses abort-controller v3, which lacks throwIfAborted.
    const restoreSignal = legacySignalSurface();
    let close: () => void = () => undefined;
    try {
      await registration.register('google');
      await gmailMailboxes.load();
      const inbox = required(gmailMailboxes.getSnapshot()[0]?.inbox);
      close = inbox.retainMessage(id);
      await inbox.readMessage(id);
      const locator = required(inbox.messageAttachments(id)?.[0]?.locator);
      const pending = inbox.downloadAttachment(id, locator);
      await downloading;
      expect(inbox.messageAttachments(id)?.[0]?.state.kind).toBe('downloading');
      inbox.cancelAttachment(id, locator);
      await pending;
      expect(bridge.cancelGmailRequest).toHaveBeenCalledWith(
        expect.any(String),
      );
      expect(gmail.savedFiles.size).toBe(0);
      retry();
      await inbox.downloadAttachment(id, locator);
      expect(inbox.messageAttachments(id)?.[0]?.state.kind).toBe('downloaded');
    } finally {
      close();
      restoreSignal();
      module.mockRestore();
    }
  });
});
