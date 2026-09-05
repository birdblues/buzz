import assert from "node:assert/strict";
import test from "node:test";

import {
  HARNESS_EXIT_TOAST_WINDOW_MS,
  createHarnessExitHandler,
  harnessExitAction,
  harnessExitToastCopy,
} from "./harnessExitNotice.ts";

const PUBKEY = "a".repeat(64);

// The exact shape Rust serde emits for a reaped pair — copied from the
// `reap_records_the_verdict_…` assertions in `reaper_tests.rs`, not invented
// here. `exitCause` is a bare snake_case string; the internal verdict enum
// never reaches the wire.
function crashEvent(overrides = {}) {
  return {
    pubkey: PUBKEY,
    relayUrl: "wss://relay.example",
    localSetup: true,
    lifecycle: "stopped",
    pid: null,
    error: "Error: relay connect error: connection reset by peer",
    logPath: "/logs/x.log",
    exitCause: "crash",
    ...overrides,
  };
}

// A live-runtime status (start/stop/observer frames) carries no exitCause.
function liveEvent() {
  return {
    pubkey: PUBKEY,
    relayUrl: "wss://relay.example",
    localSetup: true,
    lifecycle: "ready",
    pid: 123,
    error: null,
    logPath: null,
  };
}

test("statuses without exitCause are ignored", () => {
  assert.equal(harnessExitAction(liveEvent(), "wss://relay.example"), "ignore");
});

test("only a crash in the active community notifies", () => {
  assert.equal(
    harnessExitAction(crashEvent(), "wss://relay.example"),
    "notify",
  );
  assert.equal(
    harnessExitAction(
      crashEvent({ exitCause: "intentional" }),
      "wss://relay.example",
    ),
    "refresh",
  );
  assert.equal(
    harnessExitAction(
      crashEvent({ exitCause: "unknown" }),
      "wss://relay.example",
    ),
    "refresh",
  );
});

test("the community fence compares canonical relay URLs, not raw strings", () => {
  // Backend keys are canonical (`ws://127.0.0.1:3000`); a stored community
  // URL may say `ws://localhost:3000/`. Raw comparison would suppress the
  // toast for the community actually on screen.
  assert.equal(
    harnessExitAction(
      crashEvent({ relayUrl: "ws://127.0.0.1:3000" }),
      "ws://localhost:3000/",
    ),
    "notify",
  );
  assert.equal(
    harnessExitAction(crashEvent(), "wss://elsewhere.example"),
    "refresh",
  );
  assert.equal(harnessExitAction(crashEvent(), null), "refresh");
});

test("toast copy names one agent with its cause, or counts many", () => {
  assert.equal(
    harnessExitToastCopy([
      { name: "Scout", error: "Error: relay connect error: x" },
    ]),
    "Scout stopped unexpectedly: Error: relay connect error: x",
  );
  assert.equal(
    harnessExitToastCopy([{ name: "Scout", error: null }]),
    "Scout stopped unexpectedly.",
  );
  assert.equal(
    harnessExitToastCopy([
      { name: "A", error: "x" },
      { name: "B", error: null },
    ]),
    "2 agents stopped unexpectedly: A, B. Open Agents for details.",
  );
});

function fakeDeps(overrides = {}) {
  const calls = { cleared: [], invalidated: 0, toasts: [], timers: [] };
  const deps = {
    activeRelayUrl: () => "wss://relay.example",
    agentName: (pubkey) => (pubkey === PUBKEY ? "Scout" : null),
    clearActiveTurns: (pubkey, relayUrl) =>
      calls.cleared.push([pubkey, relayUrl]),
    invalidate: () => {
      calls.invalidated += 1;
    },
    toast: (copy) => calls.toasts.push(copy),
    schedule: (fn, ms) => calls.timers.push({ fn, ms }),
    ...overrides,
  };
  return { deps, calls };
}

test("a crash clears the working badge, refreshes, and toasts once per window", () => {
  const { deps, calls } = fakeDeps();
  const handler = createHarnessExitHandler(deps);

  assert.equal(handler.handle(crashEvent()), "notify");
  assert.equal(
    handler.handle(crashEvent({ pubkey: "b".repeat(64), error: null })),
    "notify",
  );

  assert.deepEqual(calls.cleared, [
    [PUBKEY, "wss://relay.example"],
    ["b".repeat(64), "wss://relay.example"],
  ]);
  assert.equal(calls.invalidated, 2);
  assert.equal(calls.timers.length, 1, "one timer per window, not per crash");
  assert.equal(calls.timers[0].ms, HARNESS_EXIT_TOAST_WINDOW_MS);
  assert.deepEqual(calls.toasts, [], "nothing until the window closes");

  calls.timers[0].fn();
  assert.deepEqual(calls.toasts, [
    "2 agents stopped unexpectedly: Scout, bbbbbbbb…bbbb. Open Agents for details.",
  ]);
});

test("intentional and unknown exits refresh and clear the badge but never toast", () => {
  const { deps, calls } = fakeDeps();
  const handler = createHarnessExitHandler(deps);
  assert.equal(
    handler.handle(crashEvent({ exitCause: "intentional" })),
    "refresh",
  );
  assert.equal(handler.handle(crashEvent({ exitCause: "unknown" })), "refresh");
  assert.equal(calls.cleared.length, 2);
  assert.equal(calls.invalidated, 2);
  assert.equal(calls.timers.length, 0);
});

test("a crash in another community refreshes without a toast", () => {
  const { deps, calls } = fakeDeps({
    activeRelayUrl: () => "wss://other.example",
  });
  const handler = createHarnessExitHandler(deps);
  assert.equal(handler.handle(crashEvent()), "refresh");
  assert.equal(calls.timers.length, 0);
});

test("live statuses touch nothing", () => {
  const { deps, calls } = fakeDeps();
  const handler = createHarnessExitHandler(deps);
  assert.equal(handler.handle(liveEvent()), "ignore");
  assert.equal(calls.cleared.length, 0);
  assert.equal(calls.invalidated, 0);
});

test("dispose drops a pending toast", () => {
  const { deps, calls } = fakeDeps();
  const handler = createHarnessExitHandler(deps);
  handler.handle(crashEvent());
  handler.dispose();
  calls.timers[0].fn();
  assert.deepEqual(calls.toasts, []);
});
