import assert from "node:assert/strict";
import test from "node:test";

import { buildMentionCandidates } from "./buildMentionCandidates.ts";

const MEMBER_PUBKEY = "a".repeat(64);
const AGENT_PUBKEY = "b".repeat(64);
const ARCHIVED_PUBKEY = "c".repeat(64);
const SEARCHED_PUBKEY = "d".repeat(64);

function input(overrides = {}) {
  return {
    activeAgentPubkeys: new Set(),
    activePersonaById: new Map(),
    activePersonas: [],
    canSearchGlobalUsers: false,
    currentPubkey: null,
    isArchived: () => false,
    managedAgentDirectoryReady: true,
    managedAgentNamesByPubkey: new Map(),
    managedAgentPersonaIds: new Set(),
    managedAgentPersonaIdsByPubkey: new Map(),
    managedAgents: [],
    memberPubkeys: new Set(),
    members: [],
    mentionChannelId: null,
    mentionableAgentPubkeys: new Set(),
    personaNameByPubkey: new Map(),
    profiles: undefined,
    relayAgentDirectoryReady: true,
    relayAgentNamesByPubkey: new Map(),
    relayAgents: [],
    userSearchResults: [],
    ...overrides,
  };
}

test("a roster entry and its relay agent record coalesce into one candidate", () => {
  const candidates = buildMentionCandidates(
    input({
      members: [
        { pubkey: AGENT_PUBKEY, displayName: null, isAgent: true, role: "bot" },
      ],
      mentionableAgentPubkeys: new Set([AGENT_PUBKEY]),
      relayAgents: [
        {
          pubkey: AGENT_PUBKEY,
          name: "Scout",
          ownerPubkey: null,
          status: "online",
        },
      ],
    }),
  );

  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].pubkey, AGENT_PUBKEY);
  // The roster contributes membership, the directory contributes the name.
  assert.equal(candidates[0].isMember, true);
  assert.equal(candidates[0].displayName, "Scout");
  assert.equal(candidates[0].isActiveAgent, true);
});

test("archived identities never become candidates", () => {
  const candidates = buildMentionCandidates(
    input({
      isArchived: (pubkey) => pubkey === ARCHIVED_PUBKEY,
      members: [
        { pubkey: MEMBER_PUBKEY, displayName: "Ada", isAgent: false },
        { pubkey: ARCHIVED_PUBKEY, displayName: "Gone", isAgent: false },
      ],
    }),
  );

  assert.deepEqual(
    candidates.map((candidate) => candidate.pubkey),
    [MEMBER_PUBKEY],
  );
});

test("an agent outside the mentionable set is hidden once its directory is ready", () => {
  const relayAgents = [
    { pubkey: AGENT_PUBKEY, name: "Scout", ownerPubkey: null, status: "away" },
  ];

  assert.deepEqual(buildMentionCandidates(input({ relayAgents })), []);
  assert.equal(
    buildMentionCandidates(
      input({ mentionableAgentPubkeys: new Set([AGENT_PUBKEY]), relayAgents }),
    ).length,
    1,
  );
});

test("active personas join unless a managed agent already carries them", () => {
  const activePersonas = [
    { id: "planner", displayName: "Planner", avatarUrl: null, isActive: true },
  ];

  const standalone = buildMentionCandidates(input({ activePersonas }));
  assert.equal(standalone.length, 1);
  assert.equal(standalone[0].kind, "persona");
  assert.equal(standalone[0].personaId, "planner");

  assert.deepEqual(
    buildMentionCandidates(
      input({ activePersonas, managedAgentPersonaIds: new Set(["planner"]) }),
    ),
    [],
  );
});

test("remote-origin personas never offer a launcher candidate", () => {
  // A definition synced from another device: selecting a launcher would mint
  // a NEW local identity while the real agent already answers elsewhere.
  const activePersonas = [
    { id: "planner", displayName: "Planner", avatarUrl: null, isActive: true },
    {
      id: "remote",
      displayName: "Remote",
      avatarUrl: null,
      isActive: true,
      remoteOrigin: true,
    },
  ];

  const candidates = buildMentionCandidates(input({ activePersonas }));
  assert.deepEqual(
    candidates.map((candidate) => candidate.personaId),
    ["planner"],
  );
});

test("a persona whose only instance runs elsewhere offers no launcher candidate", () => {
  // The incident this pins: a definition authored locally (or synced before
  // `remoteOrigin` existed) carries no marker, yet its agent already answers
  // from another device. Selecting a launcher candidate IS the mint — there is
  // no confirmation step on this path — so the relay-derived `ownedPersonaIds`
  // has to gate candidacy on its own.
  //
  // Deliberately isolated from the `remoteOrigin` half: `elsewhere` sets no
  // marker, so removing the `ownedPersonaIds` term fails THIS test while
  // "remote-origin personas never offer a launcher candidate" still passes,
  // and removing the `remoteOrigin` term fails that one while this passes.
  const activePersonas = [
    { id: "planner", displayName: "Planner", avatarUrl: null, isActive: true },
    {
      id: "elsewhere",
      displayName: "Elsewhere",
      avatarUrl: null,
      isActive: true,
    },
  ];

  const candidates = buildMentionCandidates(
    input({ activePersonas, ownedPersonaIds: new Set(["elsewhere"]) }),
  );
  assert.deepEqual(
    candidates.map((candidate) => candidate.personaId),
    ["planner"],
  );
});

test("omitting ownedPersonaIds keeps every launcher candidate", () => {
  // The parameter is optional so existing callers are unchanged; the empty
  // default must not suppress anything. Guards against a default that
  // accidentally filters (e.g. an inverted check).
  const activePersonas = [
    { id: "planner", displayName: "Planner", avatarUrl: null, isActive: true },
    { id: "second", displayName: "Second", avatarUrl: null, isActive: true },
  ];

  const candidates = buildMentionCandidates(input({ activePersonas }));
  assert.deepEqual(
    candidates.map((candidate) => candidate.personaId),
    ["planner", "second"],
  );
});

test("global search results join only while global search is enabled", () => {
  const userSearchResults = [
    {
      pubkey: SEARCHED_PUBKEY,
      displayName: "Dana",
      isAgent: false,
      nip05Handle: null,
      ownerPubkey: null,
    },
  ];

  assert.deepEqual(buildMentionCandidates(input({ userSearchResults })), []);

  const searched = buildMentionCandidates(
    input({ canSearchGlobalUsers: true, userSearchResults }),
  );
  assert.equal(searched.length, 1);
  assert.equal(searched[0].displayName, "Dana");
  assert.equal(searched[0].isGlobalSearchResult, true);
});

test("policy-only discovery stays selectable without claiming active presence", () => {
  const [candidate] = buildMentionCandidates(
    input({
      mentionableAgentPubkeys: new Set([AGENT_PUBKEY]),
      relayAgents: [
        {
          pubkey: AGENT_PUBKEY,
          name: "Scout",
          ownerPubkey: MEMBER_PUBKEY,
          status: "unknown",
        },
      ],
    }),
  );
  assert.equal(candidate.pubkey, AGENT_PUBKEY);
  assert.equal(candidate.isActiveAgent, false);
  assert.equal(candidate.ownerPubkey, MEMBER_PUBKEY);
});

for (const locallyManaged of [true, false]) {
  test(`roster candidate preserves exact local management: ${locallyManaged}`, () => {
    const [candidate] = buildMentionCandidates(
      input({
        members: [{ pubkey: AGENT_PUBKEY, displayName: "Scout", role: "bot" }],
        managedAgentNamesByPubkey: new Map(
          locallyManaged ? [[AGENT_PUBKEY, "Scout"]] : [],
        ),
        managedAgents: locallyManaged
          ? [{ pubkey: AGENT_PUBKEY, name: "Scout", status: "deployed" }]
          : [],
        mentionableAgentPubkeys: new Set([AGENT_PUBKEY]),
      }),
    );
    assert.equal(candidate.isMember, true);
    assert.equal(Boolean(candidate.isManagedAgent), locallyManaged);
  });
}

// ── definition link from the relay directory ────────────────────────────────
//
// An agent that runs on another of the owner's devices is known here only
// through the relay directory. Its kind:30177 projection carries the
// definition id, and that link is what lets a team mention address the
// running instance instead of minting a duplicate one locally.

const VIEWER_PUBKEY = "e".repeat(64);
const STRANGER_PUBKEY = "f".repeat(64);

test("an owned relay agent contributes its definition link", () => {
  const candidates = buildMentionCandidates(
    input({
      currentPubkey: VIEWER_PUBKEY,
      mentionableAgentPubkeys: new Set([AGENT_PUBKEY]),
      relayAgents: [
        {
          pubkey: AGENT_PUBKEY,
          name: "Scout",
          ownerPubkey: VIEWER_PUBKEY,
          personaId: "persona-1",
          status: "online",
          channelIds: [],
        },
      ],
    }),
  );

  const scout = candidates.find(
    (candidate) => candidate.pubkey === AGENT_PUBKEY,
  );
  assert.equal(scout?.personaId, "persona-1");
});

test("another owner's relay agent never contributes a definition link", () => {
  // Builtin definition ids are identical across owners, so trusting this link
  // unowned would let a stranger's agent stand in for one of our team members.
  const candidates = buildMentionCandidates(
    input({
      currentPubkey: VIEWER_PUBKEY,
      mentionableAgentPubkeys: new Set([AGENT_PUBKEY]),
      relayAgents: [
        {
          pubkey: AGENT_PUBKEY,
          name: "Stranger's Fizz",
          ownerPubkey: STRANGER_PUBKEY,
          personaId: "builtin:fizz",
          status: "online",
          channelIds: [],
        },
      ],
    }),
  );

  const stranger = candidates.find(
    (candidate) => candidate.pubkey === AGENT_PUBKEY,
  );
  assert.equal(stranger?.personaId, undefined);
});

test("a definition link needs a known viewer to be trusted", () => {
  const candidates = buildMentionCandidates(
    input({
      currentPubkey: null,
      mentionableAgentPubkeys: new Set([AGENT_PUBKEY]),
      relayAgents: [
        {
          pubkey: AGENT_PUBKEY,
          name: "Scout",
          ownerPubkey: VIEWER_PUBKEY,
          personaId: "persona-1",
          status: "online",
          channelIds: [],
        },
      ],
    }),
  );

  const scout = candidates.find(
    (candidate) => candidate.pubkey === AGENT_PUBKEY,
  );
  assert.equal(scout?.personaId, undefined);
});
