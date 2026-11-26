import * as Option from 'effect/Option';
import * as Schema from 'effect/Schema';

import { windowHost } from './settings-window-client.ts';

// `Testing` builds only: the typing journey's probe in the Draft editor page (#2962). After each
// change of the editor's text or marks it notes the change, as the app's text view probe does:
// the text and each UTF-16 unit's marks as a digit, bold 1 + italic 2 + underline 4. The next
// animation frame then notes its start, and a task queued from it notes the end of that frame's
// rendering update. Times are on the page's clock, in milliseconds since 1970; the page sends
// its notes once the frame has rendered, so sending them adds no work before it.
const probe = String.raw`(() => {
  const clock = () => performance.timeOrigin + performance.now();
  const notes = [];
  let text = '';
  let marks = '';
  let framing = false;
  const shown = (root) => {
    let shownText = '';
    let shownMarks = '';
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
      let mark = 0;
      for (let parent = node.parentElement; parent !== root; parent = parent.parentElement) {
        mark |= { STRONG: 1, EM: 2, U: 4 }[parent.tagName] ?? 0;
      }
      shownText += node.data;
      shownMarks += String(mark).repeat(node.data.length);
    }
    return [shownText, shownMarks];
  };
  // An edit that lands after a frame's animation frame callback waits for the next frame.
  const draw = () => {
    framing = true;
    requestAnimationFrame((frame) => {
      const shownNotes = notes.length;
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        const sent = notes.splice(0, shownNotes);
        sent.push({ event: 'text-drawn', epoch: clock(), frameEpoch: performance.timeOrigin + frame });
        window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'probe', notes: sent }));
        framing = false;
        if (notes.length > 0) draw();
      };
      channel.port2.postMessage(0);
    });
  };
  new MutationObserver(() => {
    const root = document.querySelector('.ProseMirror');
    if (root === null) return;
    const epoch = clock();
    const [nextText, nextMarks] = shown(root);
    if (nextText === text && nextMarks === marks) return;
    text = nextText;
    marks = nextMarks;
    notes.push({ event: 'text-edit', epoch, text, marks });
    if (!framing) draw();
  }).observe(document, { subtree: true, childList: true, characterData: true });
})();`;

const NoteSchema = Schema.Union([
  Schema.Struct({
    event: Schema.Literal('text-edit'),
    epoch: Schema.Finite,
    text: Schema.String,
    marks: Schema.String,
  }),
  Schema.Struct({
    event: Schema.Literal('text-drawn'),
    epoch: Schema.Finite,
    frameEpoch: Schema.Finite,
  }),
]);
const ProbeSchema = Schema.fromJsonString(
  Schema.Struct({
    type: Schema.Literal('probe'),
    notes: Schema.Array(NoteSchema),
  }),
);

// The probe to inject before the page's script, where the host records its notes.
export const pageTypingProbe = () =>
  windowHost()?.recordPageProbe === undefined ? '' : probe;

// Records the probe's notes from a page message; any other message records nothing.
export const recordPageProbe = (message: string) => {
  const record = windowHost()?.recordPageProbe;
  if (record === undefined) {
    return;
  }
  const decoded = Schema.decodeOption(ProbeSchema)(message);
  if (Option.isSome(decoded)) {
    for (const note of decoded.value.notes) {
      record(note);
    }
  }
};
