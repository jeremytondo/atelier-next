// The companion's entry point into the runtime. One versioned envelope in,
// one out, over a loopback HTTP request to stock `hs.httpserver`. The table of
// allowed actions is explicit and small; nothing here reaches the command
// registry or user commands by name, and a session that is not running
// refuses rather than resuming.
//
// The pinned Hammerspoon 2 build listens on every interface whatever
// interface it is asked for, so every request must carry the secret the
// session wrote to its state directory, which only this user can read. A
// browser cannot add that header without a preflight the server refuses.
import type {HS} from "../api/hs.ts";
import {stateDirectory} from "./state.ts";

export const dispatchVersion = 1;
/** The port the session serves `POST /dispatch` on while it runs. */
export const dispatchPort = 47820;
export const dispatchPath = "/dispatch";

/** What the companion reads to reach the session: written at start, removed at stop. */
export interface Credentials {
  version: number;
  port: number;
  secret: string;
}

export const credentialsPath = (hs: HS): string => stateDirectory(hs) + "/companion.json";

/** A fresh secret for one session. `Math.random` is the runtime's only random
 *  source; JavaScriptCore seeds it from the system and nothing outside this
 *  context ever sees its output, which is what a bearer token needs. */
export function newSecret(): string {
  let secret = "";
  while (secret.length < 64) secret += Math.floor(Math.random() * 16).toString(16);
  return secret;
}

export interface DispatchRequest {
  version: number;
  action: string;
  parameters?: Record<string, unknown>;
}

export type DispatchResponse =
  | {version: number; ok: true; result: unknown}
  | {version: number; ok: false; error: string};

/** One allowed action: runs synchronously and returns a JSON-serialisable result, or throws. */
export type DispatchAction = (parameters: Record<string, unknown>) => unknown;
export type DispatchTable = Record<string, DispatchAction>;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);

const refuse = (error: string): DispatchResponse => ({version: dispatchVersion, ok: false, error});

/** Answers a request against `table`; `refusal` names why the session cannot act now, or null. */
export function dispatch(
  request: unknown,
  table: DispatchTable,
  refusal: () => string | null,
): DispatchResponse {
  if (!isRecord(request)) return refuse("Request must be an object");
  if (request.version !== dispatchVersion)
    return refuse(
      "Unsupported dispatch version " + String(request.version) + "; expected " + dispatchVersion,
    );
  if (typeof request.action !== "string" || !request.action)
    return refuse("Request needs an action");
  const parameters = request.parameters === undefined ? {} : request.parameters;
  if (!isRecord(parameters)) return refuse("parameters must be an object");
  const action = Object.hasOwn(table, request.action) ? table[request.action] : undefined;
  if (!action) return refuse("Unknown action: " + request.action);
  const reason = refusal();
  if (reason) return refuse(reason);
  try {
    return {version: dispatchVersion, ok: true, result: action(parameters) ?? null};
  } catch (error) {
    return refuse(error instanceof Error ? error.message : String(error));
  }
}

export interface HTTPResponse {
  status: number;
  body: string;
  headers: Record<string, string>;
}

/** Whether two strings match, taking the same time for any two of one length. */
function sameSecret(offered: string, secret: string): boolean {
  if (offered.length !== secret.length) return false;
  let difference = 0;
  for (let i = 0; i < offered.length; i++)
    difference |= offered.charCodeAt(i) ^ secret.charCodeAt(i);
  return difference === 0;
}

/** Answers one HTTP request: the envelope is the JSON body of a POST to the
 *  path, sent with the session's secret as a bearer token. `handle` sees only
 *  authorised requests; anything else is answered without it. */
export function serve(
  method: string,
  path: string,
  headers: Record<string, string>,
  body: string,
  secret: string,
  handle: (request: unknown) => DispatchResponse,
): HTTPResponse {
  const json = (status: number, value: unknown): HTTPResponse => ({
    status,
    body: JSON.stringify(value),
    headers: {"Content-Type": "application/json"},
  });
  if (path !== dispatchPath) return json(404, refuse("Not found"));
  if (method !== "POST") return json(405, refuse("Use POST"));
  const offered = Object.entries(headers).find(([name]) => name.toLowerCase() === "authorization");
  if (!offered || !sameSecret(String(offered[1]), "Bearer " + secret))
    return json(401, refuse("Unauthorized"));
  let request: unknown;
  try {
    request = JSON.parse(body);
  } catch (_) {
    return json(400, refuse("Request body must be JSON"));
  }
  const response = handle(request);
  return json(response.ok ? 200 : 400, response);
}
