import assert from "node:assert/strict";
import test from "node:test";

import {
  buildTeamMentionCandidates,
  formatTeamMention,
} from "./mentionCandidates.ts";

function persona(id, displayName, isActive = true) {
  return {
    id,
    displayName,
    avatarUrl: null,
    systemPrompt: `${displayName} prompt`,
    runtime: null,
    model: null,
    provider: null,
    namePool: [],
    isBuiltIn: false,
    isActive,
    envVars: {},
    respondTo: null,
    respondToAllowlist: [],
    parallelism: null,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
  };
}

function team(id, personaIds, overrides = {}) {
  return {
    id,
    name: "Launch Team",
    description: null,
    instructions: null,
    personaIds,
    isBuiltin: false,
    sourceDir: null,
    isSymlink: false,
    symlinkTarget: null,
    version: null,
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

function identity(personaId, displayName, overrides = {}) {
  return {
    kind: "identity",
    personaId,
    displayName,
    isAgent: true,
    isMember: false,
    ...overrides,
  };
}

test("team mentions preserve team order and prefer concrete managed agents", () => {
  const personas = [
    persona("planner", "Planner"),
    persona("builder", "Builder"),
    persona("reviewer", "Reviewer"),
  ];
  const candidates = [
    identity("builder", "Build Bot", {
      isManagedAgent: true,
      pubkey: "2".repeat(64),
    }),
    identity("planner", "Plan Bot", {
      isManagedAgent: true,
      pubkey: "1".repeat(64),
    }),
    identity("planner", "Planner in channel", {
      isMember: true,
      pubkey: "3".repeat(64),
    }),
  ];

  const [suggestion] = buildTeamMentionCandidates(
    [team("launch", ["planner", "builder", "reviewer"])],
    personas,
    candidates,
  );

  assert.equal(suggestion.kind, "team");
  assert.deepEqual(suggestion.teamMembers, [
    {
      displayName: "Planner in channel",
      kind: "identity",
      personaId: "planner",
      pubkey: "3".repeat(64),
    },
    {
      displayName: "Build Bot",
      kind: "identity",
      personaId: "builder",
      pubkey: "2".repeat(64),
    },
    {
      displayName: "Reviewer",
      kind: "persona",
      personaId: "reviewer",
    },
  ]);
  assert.equal(
    formatTeamMention(suggestion.displayName, suggestion.teamMembers),
    "Launch Team(@Planner in channel @Build Bot @Reviewer) ",
  );
});

test("only complete, owned teams with mentionable members are suggested", () => {
  const active = persona("active", "Active");
  const inactive = persona("inactive", "Inactive", false);
  const teams = [
    team("owned", ["active"]),
    team("builtin", ["active"], { isBuiltin: true }),
    team("missing", ["missing"]),
    team("inactive", ["inactive"]),
  ];

  assert.deepEqual(
    buildTeamMentionCandidates(teams, [active, inactive], []).map(
      (candidate) => candidate.teamId,
    ),
    ["owned"],
  );
});

test("teams with duplicate identity display names are not suggested", () => {
  const personas = [
    persona("builder-one", "First"),
    persona("builder-two", "Second"),
  ];
  const candidates = [
    identity("builder-one", "Builder", { pubkey: "1".repeat(64) }),
    identity("builder-two", "Builder", { pubkey: "2".repeat(64) }),
  ];

  assert.deepEqual(
    buildTeamMentionCandidates(
      [team("duplicate-identities", ["builder-one", "builder-two"])],
      personas,
      candidates,
    ),
    [],
  );
});

test("teams with identity and persona display-name collisions are not suggested", () => {
  const personas = [
    persona("managed-builder", "Managed Builder"),
    persona("persona-builder", "builder"),
  ];
  const candidates = [
    identity("managed-builder", "Builder", { pubkey: "1".repeat(64) }),
  ];

  assert.deepEqual(
    buildTeamMentionCandidates(
      [
        team("identity-persona-collision", [
          "managed-builder",
          "persona-builder",
        ]),
      ],
      personas,
      candidates,
    ),
    [],
  );
});

// ── members that run on another device ───────────────────────────────────────
//
// A definition synced from another device, or one whose only instance lives
// there, must resolve to the running agent — never to "create a copy here",
// which mints a duplicate identity that answers every message twice.

const VIEWER = "a".repeat(64);
const STRANGER = "b".repeat(64);
const REMOTE_AGENT = "c".repeat(64);

function remotePersona(id, displayName) {
  return { ...persona(id, displayName), remoteOrigin: true };
}

test("a synced definition resolves to the agent already running elsewhere", () => {
  const candidates = [
    identity("planner", "Planner", {
      pubkey: REMOTE_AGENT,
      ownerPubkey: VIEWER,
    }),
  ];

  const [teamCandidate] = buildTeamMentionCandidates(
    [team("team-1", ["planner"])],
    [remotePersona("planner", "Planner")],
    candidates,
    new Set(["planner"]),
    VIEWER,
  );

  assert.deepEqual(teamCandidate.teamMembers, [
    {
      displayName: "Planner",
      kind: "identity",
      personaId: "planner",
      pubkey: REMOTE_AGENT,
    },
  ]);
});

test("an owned instance outside this channel drops the team", () => {
  // Pins the owned-instance half on its own: this definition carries no
  // `remoteOrigin` marker, so only that set can refuse the mint.
  const teamCandidates = buildTeamMentionCandidates(
    [team("team-1", ["planner"])],
    [persona("planner", "Planner")],
    [],
    new Set(["planner"]),
    VIEWER,
  );

  assert.deepEqual(
    teamCandidates,
    [],
    "better to omit the team than to mint a duplicate on send",
  );
});

test("a locally authored definition whose only instance is elsewhere drops the team", () => {
  // No `remoteOrigin` marker here — the definition was authored on this
  // device — so only the owned-instance check prevents a duplicate mint.
  // Production always passes the standalone launcher candidate for such a
  // definition (it is only filtered out for `remoteOrigin` ones), and that
  // launcher matches by definition id, so the check has to survive it.
  const launcher = {
    kind: "persona",
    personaId: "planner",
    displayName: "Planner",
    isAgent: true,
    isMember: false,
  };

  const teamCandidates = buildTeamMentionCandidates(
    [team("team-1", ["planner"])],
    [persona("planner", "Planner")],
    [launcher],
    new Set(["planner"]),
    VIEWER,
  );

  assert.deepEqual(
    teamCandidates,
    [],
    "the launcher candidate must not smuggle the definition past the check",
  );
});

test("a synced definition drops the team even without an owned-instance record", () => {
  // Pins `remoteOrigin` on its own: the owned-instance set is empty here, so
  // removing either half of the check fails a different test.
  const teamCandidates = buildTeamMentionCandidates(
    [team("team-1", ["planner"])],
    [remotePersona("planner", "Planner")],
    [],
    new Set(),
    VIEWER,
  );

  assert.deepEqual(teamCandidates, []);
});

test("a definition with no instance anywhere still offers a persona member", () => {
  const [teamCandidate] = buildTeamMentionCandidates(
    [team("team-1", ["planner"])],
    [persona("planner", "Planner")],
    [],
    new Set(),
    VIEWER,
  );

  assert.deepEqual(teamCandidate.teamMembers, [
    { displayName: "Planner", kind: "persona", personaId: "planner" },
  ]);
});

test("another owner's identity is never adopted as a team member", () => {
  const candidates = [
    identity("builtin:fizz", "Fizz", {
      pubkey: REMOTE_AGENT,
      ownerPubkey: STRANGER,
    }),
  ];

  const teamCandidates = buildTeamMentionCandidates(
    [team("team-1", ["builtin:fizz"])],
    [remotePersona("builtin:fizz", "Fizz")],
    candidates,
    new Set(["builtin:fizz"]),
    VIEWER,
  );

  assert.deepEqual(
    teamCandidates,
    [],
    "the stranger's agent must not stand in for our definition",
  );
});
