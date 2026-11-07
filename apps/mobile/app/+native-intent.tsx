import { leaveComposerForLink } from '../src/mailbox.tsx';

// A link delivered while the app runs leaves an open composer the way any other destination does;
// a composer that cannot finish stays open and the link is dropped.
export async function redirectSystemPath({
  path,
  initial,
}: Readonly<{ path: string; initial: boolean }>) {
  return initial || (await leaveComposerForLink()) ? path : null;
}
