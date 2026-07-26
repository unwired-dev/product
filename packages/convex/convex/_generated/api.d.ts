/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as apns from "../apns.js";
import type * as crons from "../crons.js";
import type * as gmailPushPayload from "../gmailPushPayload.js";
import type * as gmailRouting from "../gmailRouting.js";
import type * as health from "../health.js";
import type * as http from "../http.js";
import type * as productAccount from "../productAccount.js";
import type * as productAccountAuth from "../productAccountAuth.js";
import type * as productSync from "../productSync.js";
import type * as pushRelay from "../pushRelay.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  apns: typeof apns;
  crons: typeof crons;
  gmailPushPayload: typeof gmailPushPayload;
  gmailRouting: typeof gmailRouting;
  health: typeof health;
  http: typeof http;
  productAccount: typeof productAccount;
  productAccountAuth: typeof productAccountAuth;
  productSync: typeof productSync;
  pushRelay: typeof pushRelay;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
