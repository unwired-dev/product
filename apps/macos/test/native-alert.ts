// The AppKit alert sheet `UnwiredAlert` shows, as it received it, until a test answers it or its
// asker withdraws it.
let shown:
  | {
      readonly request: number;
      readonly title: string;
      readonly detail: string;
      readonly buttons: readonly string[];
      readonly answer: (index: number | null) => void;
    }
  | undefined = undefined;

export const unwiredAlert = {
  show: (
    _anchor: number,
    request: number,
    {
      title,
      detail,
      buttons,
    }: Readonly<{ title: string; detail: string; buttons: readonly string[] }>,
  ) =>
    // oxlint-disable-next-line promise/avoid-new -- The sheet answers once the test chooses.
    new Promise<number | null>((resolve) => {
      shown = {
        request,
        title,
        detail,
        buttons,
        answer: (index) => {
          shown = undefined;
          resolve(index);
        },
      };
    }),
  retire: (request: number) => {
    if (shown?.request === request) {
      shown.answer(null);
    }
  },
};

// The open sheet's question and buttons, or undefined.
export const sheetShown = () =>
  shown === undefined
    ? undefined
    : { title: shown.title, detail: shown.detail, buttons: shown.buttons };

// Clicks a button of the open sheet by its title; Escape answers the last one.
export const chooseSheetButton = (title: string) => {
  const index = shown?.buttons.indexOf(title) ?? -1;
  if (shown === undefined || index === -1) {
    throw new Error(`Expected an open sheet with ${title}`);
  }
  shown.answer(index);
};
