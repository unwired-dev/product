// Undo and redo over whole editor states. Typing extends the current step until a word ends;
// every other change is its own step.
export type History<T> = Readonly<{
  past: readonly T[];
  present: T;
  future: readonly T[];
  typing: boolean;
}>;

const historyLimit = 100;

export const historyOf = <T>(present: T): History<T> => ({
  past: [],
  present,
  future: [],
  typing: false,
});

export function record<T>(
  history: History<T>,
  next: T,
  typing = false,
): History<T> {
  return {
    past:
      typing && history.typing
        ? history.past
        : [...history.past, history.present].slice(-historyLimit),
    present: next,
    future: [],
    typing,
  };
}

export function undo<T>(history: History<T>): History<T> {
  const previous = history.past.at(-1);
  return previous === undefined
    ? history
    : {
        past: history.past.slice(0, -1),
        present: previous,
        future: [history.present, ...history.future],
        typing: false,
      };
}

export function redo<T>(history: History<T>): History<T> {
  const [next, ...future] = history.future;
  return next === undefined
    ? history
    : {
        past: [...history.past, history.present],
        present: next,
        future,
        typing: false,
      };
}
