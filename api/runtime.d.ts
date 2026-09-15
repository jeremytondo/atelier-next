// Hammerspoon 2 evaluates every installed file through a CommonJS wrapper, so
// these globals exist at runtime; the upstream declarations do not mention them.
// Only the package entry point uses them, so tests run under Node never see them.
declare const __dirname: string;
declare function require(id: string): unknown;
