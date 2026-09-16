import assert from "node:assert/strict";
import {test} from "node:test";
import {
  chord,
  describe,
  describeSequence,
  eventChord,
  sequence,
  sequenceIdentity,
} from "../defaults/keys.ts";

test("chords normalize modifier names, order, and key aliases into one identity", () => {
  assert.equal(chord("command-option-minus").identity, chord("alt-cmd--").identity);
  assert.equal(chord("Ctrl-Option-Cmd-R").identity, "ctrl+alt+cmd:r");
  assert.deepEqual(chord("cmd-option-left-bracket"), {
    mods: ["alt", "cmd"],
    key: "[",
    identity: "alt+cmd:[",
  });
  assert.equal(chord("fn-ctrl-f").identity, "fn+ctrl:f");
  assert.equal(chord("shift-backspace").key, "delete");
  for (const bad of ["nope", "cmd-", "cmd-cmd-a", "a", "cmd-ä", 1, null, "option-space-x"])
    assert.throws(() => chord(bad), /shortcut/, JSON.stringify(bad));
  assert.equal(chord("a", true).identity, ":a");
  assert.equal(chord("shift-left", true).identity, "shift:left");
});

test("sequences are chords without required modifiers, and events map onto them", () => {
  const chords = sequence(" w  a shift-left ");
  assert.equal(sequenceIdentity(chords), ":w :a shift:left");
  assert.throws(() => sequence(""), /sequence/);
  assert.throws(() => sequence("w cmd-"), /shortcut/);
  assert.equal(eventChord(["shift", "leftShift", "fn"], "left").identity, "fn+shift:left");
  assert.deepEqual(eventChord([], "["), chord("[", true));
  assert.equal(eventChord(["cmd", "alt"], "1").identity, chord("cmd-option-1").identity);
});

test("chords print the way macOS menus do", () => {
  assert.equal(describe(chord("cmd-option-1")), "⌥⌘1");
  assert.equal(describe(chord("ctrl-option-cmd-r")), "⌃⌥⌘R");
  assert.equal(describe(chord("fn-ctrl-shift-left")), "fn⌃⇧←");
  assert.equal(describe(chord("shift-left", true)), "⇧←");
  assert.equal(describe(chord("delete", true)), "⌫");
  assert.equal(describe(chord("f12", true)), "f12");
  assert.equal(describeSequence(sequence("w a q")), "W A Q");
});
