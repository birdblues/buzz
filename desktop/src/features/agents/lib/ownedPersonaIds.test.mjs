import assert from "node:assert/strict";
import test from "node:test";

import {
  collectOwnedPersonaIds,
  localManagedAgentPersonaIds,
  personaStartBlockReason,
} from "./ownedPersonaIds.ts";

const VIEWER = "a".repeat(64);
const OTHER_OWNER = "b".repeat(64);
const AGENT_PUBKEY = "c".repeat(64);

function relayAgent(overrides = {}) {
  return {
    pubkey: AGENT_PUBKEY,
    personaId: "planner",
    ownerPubkey: VIEWER,
    ...overrides,
  };
}

function collect(overrides = {}) {
  return collectOwnedPersonaIds({
    currentPubkey: VIEWER,
    isArchived: () => false,
    managedAgentPersonaIds: [],
    relayAgents: [],
    ...overrides,
  });
}

test("a relay instance owned by the viewer marks its definition owned", () => {
  assert.deepEqual([...collect({ relayAgents: [relayAgent()] })], ["planner"]);
});

test("another owner's relay instance never marks the definition owned", () => {
  // Builtin definition ids are identical across owners, so persona id alone
  // cannot establish ownership. Dropping the `ownerPubkey` comparison makes
  // every owner's builtin suppress ours — this is the test that catches it.
  assert.deepEqual(
    [...collect({ relayAgents: [relayAgent({ ownerPubkey: OTHER_OWNER })] })],
    [],
  );
});

test("an archived relay instance does not mark the definition owned", () => {
  // Archived means retired, not running. Suppressing on it would make an
  // archive-only definition permanently unusable with no way back.
  assert.deepEqual(
    [...collect({ relayAgents: [relayAgent()], isArchived: () => true })],
    [],
  );
});

test("an unknown viewer trusts nothing from the relay", () => {
  assert.deepEqual(
    [...collect({ currentPubkey: null, relayAgents: [relayAgent()] })],
    [],
  );
});

test("owner comparison ignores hex case", () => {
  assert.deepEqual(
    [
      ...collect({
        currentPubkey: VIEWER.toUpperCase(),
        relayAgents: [relayAgent()],
      }),
    ],
    ["planner"],
  );
});

test("a relay entry with no definition link contributes nothing", () => {
  assert.deepEqual(
    [...collect({ relayAgents: [relayAgent({ personaId: null })] })],
    [],
  );
});

test("local instances seed the set even with no relay directory", () => {
  // Fail-open: an unloaded or failed directory leaves only the local half, so
  // every affordance behaves exactly as it did before this signal existed.
  assert.deepEqual(
    [
      ...collect({
        managedAgentPersonaIds: ["local-only"],
        relayAgents: undefined,
      }),
    ],
    ["local-only"],
  );
});

test("localManagedAgentPersonaIds keeps only linked instances", () => {
  assert.deepEqual(
    [
      ...localManagedAgentPersonaIds([
        { personaId: "planner" },
        { personaId: null },
        { personaId: undefined },
        { personaId: "writer" },
      ]),
    ],
    ["planner", "writer"],
  );
  assert.deepEqual([...localManagedAgentPersonaIds(undefined)], []);
});

// Pure predicate, so pin the whole input space rather than a sample.
for (const remoteOrigin of [true, false, undefined]) {
  for (const ownedElsewhere of [true, false]) {
    const shouldBlock = remoteOrigin === true || ownedElsewhere;
    test(`start block: remoteOrigin=${String(remoteOrigin)} ownedElsewhere=${ownedElsewhere} blocks=${shouldBlock}`, () => {
      const reason = personaStartBlockReason(
        { displayName: "Planner", id: "planner", remoteOrigin },
        new Set(ownedElsewhere ? ["planner"] : []),
      );
      if (shouldBlock) {
        assert.match(reason ?? "", /already set up on another device/);
      } else {
        assert.equal(reason, undefined);
      }
    });
  }
}

test("a definition owned only locally is never blocked", () => {
  // The gate takes ids owned ELSEWHERE. Passing the union that includes local
  // instances would refuse a definition whose Start resumes its own instance.
  assert.equal(
    personaStartBlockReason(
      { displayName: "Planner", id: "planner" },
      new Set(),
    ),
    undefined,
  );
});
