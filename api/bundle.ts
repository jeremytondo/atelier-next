// Where Atelier's native code lives: `Atelier.app`, the companion the cask
// installs beside Hammerspoon 2. Its second executable is the providers
// binary. The cask's application folder is checked first, then Launch
// Services; there is no fallback to a bare executable.
import type {HS} from "./hs.ts";

export const bundleIdentifier = "com.elevenideas.Atelier";
export const applicationPath = "/Applications/Atelier.app";
const providersExecutable = "/Contents/MacOS/atelier-providers";

/** The installed providers executable; throws when the bundle is missing. */
export function providersPath(hs: HS): string {
  const candidates = [applicationPath];
  const registered = hs.application.pathForBundleID(bundleIdentifier);
  if (registered && registered !== applicationPath) candidates.push(registered);
  for (const bundle of candidates) {
    const path = bundle + providersExecutable;
    if (hs.fs.isFile(path)) return path;
  }
  throw new Error(
    "Atelier.app is not installed at " +
      applicationPath +
      "; reinstall with: brew reinstall --cask jeremytondo/atelier/atelier",
  );
}
