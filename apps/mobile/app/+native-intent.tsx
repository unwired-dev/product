import { leaveComposerForLink } from '../src/mailbox.tsx';

// A link delivered while the app runs leaves an open composer the way any other destination does;
// a composer that cannot finish stays open and the link is dropped. The launch link stays
// synchronous so the navigation container does not suspend.
export function redirectSystemPath({
  path,
  initial,
}: Readonly<{ path: string; initial: boolean }>) {
  return initial
    ? path
    : leaveComposerForLink().then((left) => (left ? path : null));
}
