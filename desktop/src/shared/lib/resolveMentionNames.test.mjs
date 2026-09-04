import assert from "node:assert/strict";
import test from "node:test";

import {
  resolveMentionNames,
  resolveMentionProps,
  resolveMentionPubkeysByName,
} from "./resolveMentionNames.ts";

const PUBKEY = "a".repeat(64);
const OTHER_PUBKEY = "b".repeat(64);

function profile(overrides = {}) {
  return {
    displayName: null,
    name: null,
    avatarUrl: null,
    nip05Handle: null,
    ownerPubkey: null,
    ...overrides,
  };
}

test("returns undefined without tags or profiles", () => {
  const profiles = { [PUBKEY]: profile({ displayName: "alice" }) };
  assert.deepEqual(resolveMentionProps(undefined, profiles), {
    mentionNames: undefined,
    mentionPubkeysByName: undefined,
  });
  assert.deepEqual(resolveMentionProps([["p", PUBKEY]], undefined), {
    mentionNames: undefined,
    mentionPubkeysByName: undefined,
  });
});

test("resolves the display name alias from p tags", () => {
  const tags = [["p", PUBKEY]];
  const profiles = { [PUBKEY]: profile({ displayName: "Alice" }) };

  const { mentionNames, mentionPubkeysByName } = resolveMentionProps(
    tags,
    profiles,
  );
  assert.deepEqual(mentionNames, ["Alice"]);
  assert.deepEqual(mentionPubkeysByName, { alice: PUBKEY });
});

test("resolves the kind-0 name alias when it differs from the display name", () => {
  // The rename / agent-send case: the message text says "@tyler" (kind-0
  // name) while the profile's display name is "Tyler Durden". Both aliases
  // must render as chips AND resolve to the pubkey.
  const tags = [["p", PUBKEY]];
  const profiles = {
    [PUBKEY]: profile({ displayName: "Tyler Durden", name: "tyler" }),
  };

  const { mentionNames, mentionPubkeysByName } = resolveMentionProps(
    tags,
    profiles,
  );
  assert.deepEqual(mentionNames, ["Tyler Durden", "tyler"]);
  assert.deepEqual(mentionPubkeysByName, {
    "tyler durden": PUBKEY,
    tyler: PUBKEY,
  });
});

test("resolves the NIP-05 local part alias", () => {
  const tags = [["p", PUBKEY]];
  const profiles = {
    [PUBKEY]: profile({
      displayName: "Tyler Durden",
      nip05Handle: "tyler@buzz.example",
    }),
  };

  const { mentionNames, mentionPubkeysByName } = resolveMentionProps(
    tags,
    profiles,
  );
  assert.deepEqual(mentionNames, ["Tyler Durden", "tyler"]);
  assert.equal(mentionPubkeysByName?.tyler, PUBKEY);
});

test("skips the NIP-05 root identifier and blank aliases", () => {
  const tags = [
    ["p", PUBKEY],
    ["p", OTHER_PUBKEY],
  ];
  const profiles = {
    [PUBKEY]: profile({ displayName: "  ", name: "", nip05Handle: "_@root" }),
    [OTHER_PUBKEY]: profile({ displayName: "bob" }),
  };

  const { mentionNames, mentionPubkeysByName } = resolveMentionProps(
    tags,
    profiles,
  );
  assert.deepEqual(mentionNames, ["bob"]);
  assert.deepEqual(mentionPubkeysByName, { bob: OTHER_PUBKEY });
});

test("includes aliases from mention reference tags", () => {
  const tags = [["mention", PUBKEY]];
  const profiles = { [PUBKEY]: profile({ displayName: "alice" }) };

  assert.deepEqual(resolveMentionNames(tags, profiles), ["alice"]);
  assert.deepEqual(resolveMentionPubkeysByName(tags, profiles), {
    alice: PUBKEY,
  });
});

test("every rendered name resolves to a pubkey (outputs stay in sync)", () => {
  const tags = [
    ["p", PUBKEY],
    ["p", OTHER_PUBKEY],
  ];
  const profiles = {
    [PUBKEY]: profile({
      displayName: "Tyler Durden",
      name: "tyler",
      nip05Handle: "td@buzz.example",
    }),
    [OTHER_PUBKEY]: profile({ displayName: "bob", name: "bobby" }),
  };

  const { mentionNames, mentionPubkeysByName } = resolveMentionProps(
    tags,
    profiles,
  );
  for (const name of mentionNames ?? []) {
    assert.ok(
      mentionPubkeysByName?.[name.toLowerCase()],
      `alias "${name}" renders as a chip but does not resolve to a pubkey`,
    );
  }
});

test("uppercases in tag pubkeys are normalized", () => {
  const tags = [["p", PUBKEY.toUpperCase()]];
  const profiles = { [PUBKEY]: profile({ displayName: "alice" }) };

  assert.deepEqual(resolveMentionPubkeysByName(tags, profiles), {
    alice: PUBKEY,
  });
});

test("keeps the send-time name from a mention tag after a rename", () => {
  // The message body says "@살짝데친문어" but the profile has since been
  // renamed to 문어 — without the tag's send-time name the chip degrades
  // to plain text.
  const tags = [
    ["p", PUBKEY],
    ["mention", PUBKEY, "살짝데친문어"],
  ];
  const profiles = { [PUBKEY]: profile({ displayName: "문어" }) };

  const { mentionNames, mentionPubkeysByName } = resolveMentionProps(
    tags,
    profiles,
  );

  assert.ok(mentionNames.includes("문어"));
  assert.ok(mentionNames.includes("살짝데친문어"));
  assert.equal(mentionPubkeysByName["살짝데친문어"], PUBKEY);
  assert.equal(mentionPubkeysByName["문어"], PUBKEY);
});

test("a p tag's third element is a relay URL, never a name alias", () => {
  const tags = [["p", PUBKEY, "wss://relay.example"]];
  const profiles = { [PUBKEY]: profile({ displayName: "Alice" }) };

  const { mentionNames } = resolveMentionProps(tags, profiles);

  assert.deepEqual(mentionNames, ["Alice"]);
});

test("send-time name never overrides a current alias owner", () => {
  // OTHER renamed to "alice" while a stale mention tag still claims "alice"
  // for PUBKEY — the current profile alias must win the name→pubkey map.
  const tags = [
    ["p", OTHER_PUBKEY],
    ["mention", PUBKEY, "alice"],
  ];
  const profiles = {
    [OTHER_PUBKEY]: profile({ displayName: "alice" }),
    [PUBKEY]: profile({ displayName: "bob" }),
  };

  const { mentionPubkeysByName } = resolveMentionProps(tags, profiles);

  assert.equal(mentionPubkeysByName.alice, OTHER_PUBKEY);
});

test("the agent-address provenance marker is never treated as a name", () => {
  const tags = [["mention", PUBKEY, "agent-address"]];
  const profiles = { [PUBKEY]: profile({ displayName: "Pollen" }) };

  const { mentionNames, mentionPubkeysByName } = resolveMentionProps(
    tags,
    profiles,
  );

  assert.deepEqual(mentionNames, ["Pollen"]);
  assert.equal(mentionPubkeysByName["agent-address"], undefined);
});
