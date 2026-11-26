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
  new MutationObserver(() => {
    const root = document.querySelector('.ProseMirror');
    if (root === null) return;
    const epoch = clock();
    const [nextText, nextMarks] = shown(root);
    if (nextText === text && nextMarks === marks) return;
    text = nextText;
    marks = nextMarks;
    notes.push({ event: 'text-edit', epoch, text, marks });
    if (framing) return;
    framing = true;
    requestAnimationFrame((frame) => {
      const channel = new MessageChannel();
      channel.port1.onmessage = () => {
        framing = false;
        notes.push({ event: 'text-drawn', epoch: clock(), frameEpoch: performance.timeOrigin + frame });
        window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'probe', notes: notes.splice(0) }));
      };
      channel.port2.postMessage(0);
    });
  }).observe(document, { subtree: true, childList: true, characterData: true });
})();`;

const NoteSchema = Schema.Struct({
  event: Schema.Literals(['text-edit', 'text-drawn']),
  epoch: Schema.Finite,
  frameEpoch: Schema.optionalKey(Schema.Finite),
  text: Schema.optionalKey(Schema.String),
  marks: Schema.optionalKey(Schema.String),
});
const ProbeSchema = Schema.fromJsonString(
  Schema.Struct({
    type: Schema.Literal('probe'),
    notes: Schema.Array(NoteSchema),
  }),
);

// The probe to inject before the page's script, where the host records its notes.
export const pageTypingProbe = () =>
  windowHost()?.recordPageProbe === undefined ? '' : probe;

// Records a page message that holds the probe's notes; false for any other message.
export const recordedPageProbe = (message: string) => {
  const record = windowHost()?.recordPageProbe;
  const decoded =
    record === undefined
      ? Option.none()
      : Schema.decodeOption(ProbeSchema)(message);
  if (Option.isNone(decoded)) {
    return false;
  }
  for (const note of decoded.value.notes) {
    record?.(note);
  }
  return true;
};
