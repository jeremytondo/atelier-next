// `atelier.application` fills gaps in `hs.application`: resolving a configured
// reference to an app on disk, and launching without activation.
import type {Request} from "./spaces.ts";

export interface ResolvedApplication {
  bundleID: string;
  name: string;
  path: string;
}

export interface ApplicationAPI {
  /** Accepts a name with or without `.app`, a bundle ID, or an absolute or tilde path. */
  resolve(app: string): Promise<ResolvedApplication>;
  /** Launches or reopens the bundle at `path` without activating it. */
  launch(path: string): Promise<{pid: number}>;
}

export function createApplication(request: Request): ApplicationAPI {
  return {
    resolve: (app) => request("application.resolve", {app}) as Promise<ResolvedApplication>,
    launch: (path) => request("application.launch", {path}) as Promise<{pid: number}>,
  };
}
