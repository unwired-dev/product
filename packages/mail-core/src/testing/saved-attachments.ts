import * as Base64Url from 'effect/encoding/Base64Url';
import * as Result from 'effect/Result';

import type { NativeAttachments } from '../attachment-downloads.ts';

const rejection = (code: string) =>
  Promise.reject(Object.assign(new Error(`Synthetic ${code}`), { code }));

// The Downloaded Attachments native code holds for one synthetic connection, by opaque file name,
// and the system presentations requested for them. `current` says whether a caller's mailbox
// generation is still the open one.
export function createSyntheticAttachments(
  current: (
    owner: Readonly<{ address: string; generation: string }>,
  ) => boolean,
) {
  const savedFiles = new Map<string, { name: string; bytes: Uint8Array }>();
  const presentations: Array<{ name: string; action: string }> = [];
  const saveFailures: string[] = [];
  const presentFailures: string[] = [];
  let nextFile = 0;
  const native: NativeAttachments = {
    // Native code decodes the data again and refuses bytes that differ from the declared size.
    saveAttachment: (owner, { name, data, size }) => {
      const code = saveFailures.shift();
      if (code !== undefined) {
        return rejection(code);
      }
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      const bytes = Base64Url.decode(data);
      if (Result.isFailure(bytes) || bytes.success.length !== size) {
        return rejection('unavailable');
      }
      nextFile += 1;
      const file = `00000000-0000-4000-8000-${String(nextFile).padStart(12, '0')}`;
      savedFiles.set(file, { name, bytes: bytes.success });
      return Promise.resolve({ file });
    },
    discardAttachment: (_owner, file) => {
      savedFiles.delete(file);
      return Promise.resolve(null);
    },
    presentAttachment: (owner, file, action) => {
      const saved = savedFiles.get(file);
      if (!current(owner)) {
        return rejection('mailbox-invalidated');
      }
      if (saved === undefined) {
        return rejection('attachment-missing');
      }
      const code = presentFailures.shift();
      if (code !== undefined) {
        return rejection(code);
      }
      presentations.push({ name: saved.name, action });
      return Promise.resolve(null);
    },
  };
  return {
    native,
    // Attachment files saved for this connection, with the name and bytes each was saved with.
    savedFiles,
    presentations,
    failSave: (code: string) => {
      saveFailures.push(code);
    },
    // The system cannot show the next presentation, as without a window or presenter.
    failPresent: (code: string) => {
      presentFailures.push(code);
    },
  };
}
