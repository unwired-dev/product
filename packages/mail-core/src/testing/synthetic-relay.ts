import * as Context from 'effect/Context';
import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';

// The selected scenario and this launch of the app, which every synthetic layer answers for.
export class SyntheticScenario extends Context.Service<
  SyntheticScenario,
  { readonly scenario: string; readonly launch: string }
>()('@private-email/mail-core/testing/SyntheticScenario') {}

// What the real provider or backend would refuse with, by its fixed code.
export class SyntheticRefusal extends Schema.TaggedError<SyntheticRefusal>()(
  'SyntheticRefusal',
  { code: Schema.String },
) {}
export const refuse = (code: string) =>
  Effect.fail(new SyntheticRefusal({ code }));

const Json = Schema.fromJsonString(Schema.Unknown);

// An HTTP exchange's reply as native returns it: HTTP failures are replies, not refusals.
export interface Reply {
  readonly status: number;
  readonly body: string;
}
export const reply = (status: number, body: unknown) =>
  Schema.encodeEffect(Json)(body).pipe(
    Effect.map((text): Reply => ({ status, body: text })),
  );

// A request URL's decoded path, its segments and query items. Hermes' URL has no search
// parameters.
export interface RequestURL {
  readonly path: string;
  readonly segments: readonly string[];
  readonly search: string;
  readonly query: ReadonlyArray<readonly [string, string]>;
  // The first value of a query item, as Foundation's query items would give it.
  readonly item: (name: string) => string | undefined;
}
export function requestURL(url: string): RequestURL {
  const separator = url.indexOf('?');
  const location = separator === -1 ? url : url.slice(0, separator);
  const search = separator === -1 ? '' : url.slice(separator + 1);
  const path = decodeURIComponent(location.replace(/^[a-z]+:\/\/[^/]+/u, ''));
  const query = search
    .split('&')
    .filter((item) => item !== '')
    .map((item) => {
      const equals = item.indexOf('=');
      return [
        decodeURIComponent(equals === -1 ? item : item.slice(0, equals)),
        equals === -1 ? '' : decodeURIComponent(item.slice(equals + 1)),
      ] as const;
    });
  return {
    path,
    segments: path.split('/').filter((segment) => segment !== ''),
    search,
    query,
    item: (name: string) => query.find(([key]) => key === name)?.[1],
  };
}
