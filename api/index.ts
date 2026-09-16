// The Atelier API: functions shaped like Hammerspoon 2 modules that do not
// exist yet. Each one uses `hs.*` where HS2 can do the job and the providers
// process where it cannot. The process starts on first use or explicitly, and
// any pipe failure stops it and tells every listener.
import {type ApplicationAPI, createApplication} from "./application.ts";
import type {HS} from "./hs.ts";
import {type Hello, Pipe} from "./pipe.ts";
import {createSpaces, type SpacesAPI} from "./spaces.ts";
import {createWindow, type WindowAPI} from "./window.ts";

export interface ProvidersAPI {
  start(): Promise<Hello>;
  stop(): void;
  readonly running: boolean;
  /** Registers a listener for pipe failures; returns the function that removes it. */
  onFailure(listener: (error: Error) => void): () => void;
}

export interface AtelierAPI {
  spaces: SpacesAPI;
  application: ApplicationAPI;
  /** Native window actions of the frontmost app, read and pressed through `hs.ax`. */
  window: WindowAPI;
  providers: ProvidersAPI;
}

export interface APIOptions {
  /** Path of the atelier-providers executable. */
  providers: string;
  arguments?: string[];
}

export function createAPI(hs: HS, options: APIOptions): AtelierAPI {
  const listeners = new Set<(error: Error) => void>();
  const pipe = new Pipe(
    hs,
    options.providers,
    (error) => {
      for (const listener of [...listeners]) listener(error);
    },
    options.arguments,
  );
  let starting: Promise<Hello> | null = null;
  const start = () => {
    if (!starting) {
      starting = pipe.start().finally(() => {
        starting = null;
      });
    }
    return starting;
  };
  const request = async (command: string, args?: object) => {
    if (!pipe.task) await start();
    return pipe.request(command, args);
  };
  return {
    spaces: createSpaces(request),
    application: createApplication(request),
    window: createWindow(hs),
    providers: {
      start,
      stop: () => pipe.stop(),
      get running() {
        return pipe.running;
      },
      onFailure(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    },
  };
}
