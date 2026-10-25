// The AppKit alert sheets `UnwiredAlert` shows, as it received them, until a test answers one or
// its asker withdraws it.
type Question = Readonly<{
  title: string;
  detail: string;
  buttons: readonly string[];
  cancel?: number;
  destructive?: number;
  symbol?: Readonly<{ name: string; color: unknown }>;
  passage?: string;
  field?: string;
}>;

type Sheet = Question & {
  readonly request: number;
  readonly answer: (choice: unknown) => void;
  text: string;
};

// Each window's open sheet, the latest last.
let shown: readonly Sheet[] = [];

export const unwiredAlert = {
  show: (_anchor: number, request: number, question: Question) =>
    // oxlint-disable-next-line promise/avoid-new -- The sheet answers once the test chooses.
    new Promise<unknown>((resolve) => {
      shown = [
        ...shown,
        {
          ...question,
          request,
          text: '',
          answer: (choice) => {
            shown = shown.filter((sheet) => sheet.request !== request);
            resolve(choice);
          },
        },
      ];
    }),
  retire: (request: number) => {
    shown.find((sheet) => sheet.request === request)?.answer(null);
  },
};

// Every open sheet's question as asked, the latest last.
export const sheetsShown = () =>
  shown.map(
    ({ request: _request, answer: _answer, text: _text, ...question }) =>
      question,
  );

// The latest open sheet's question, or undefined.
export const sheetShown = () => sheetsShown().at(-1);

// Edits the current native field without choosing a button.
export const enterSheetText = (text: string) => {
  const sheet = shown.at(-1);
  if (sheet?.field === undefined) {
    throw new Error('Expected an open sheet with a text field');
  }
  sheet.text = text;
};

// Clicks a button of the latest open sheet by its title, after typing `text` into its field.
export const chooseSheetButton = (title: string, text?: string) => {
  const sheet = shown.at(-1);
  const index = sheet?.buttons.indexOf(title) ?? -1;
  if (sheet === undefined || index === -1) {
    throw new Error(`Expected an open sheet with ${title}`);
  }
  sheet.answer(
    sheet.field === undefined ? index : { index, text: text ?? sheet.text },
  );
};
