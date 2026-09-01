import assert from "node:assert/strict";
import test from "node:test";

import {
  buildMentionNameTags,
  formatMessageSendError,
  getErrorMessage,
  mergeMentionRecipients,
  pubkeysLiveElsewhere,
} from "./useMentionSendFlow.helpers.ts";

test("formatMessageSendError preserves the publication failure", () => {
  assert.equal(
    formatMessageSendError(new Error("relay rejected voice note")),
    "Message failed to send: relay rejected voice note",
  );
});

test("getErrorMessage preserves Tauri string errors", () => {
  assert.equal(
    getErrorMessage(
      "relay returned 415 Unsupported Media Type",
      "Unknown error",
    ),
    "relay returned 415 Unsupported Media Type",
  );
  assert.equal(
    getErrorMessage({ message: "upload rejected" }, "Unknown error"),
    "upload rejected",
  );
  assert.equal(getErrorMessage({}, "Unknown error"), "Unknown error");
});

test("address-locked agents join explicit mentions without duplicating recipients", () => {
  const explicit = ["A".repeat(64), "b".repeat(64)];
  const locked = ["a".repeat(64), "C".repeat(64)];

  assert.deepEqual(mergeMentionRecipients(explicit, locked), [
    "a".repeat(64),
    "b".repeat(64),
    "c".repeat(64),
  ]);
});

// `pubkeysLiveElsewhere` decides whether a mention starts a LOCAL harness for
// an agent that is already answering from another machine. It must stay in
// lockstep with the Rust `presence_start_decision`: getting it wrong either
// resurrects the duplicate-reply bug or stops agents from starting at all.

test("online and away both count as live, so no second harness is started", () => {
  const online = "a".repeat(64);
  const away = "b".repeat(64);

  const live = pubkeysLiveElsewhere({ [online]: "online", [away]: "away" });

  assert.ok(live.has(online));
  assert.ok(
    live.has(away),
    "the harness never publishes away, so an away " +
      "reading means another session holds this identity",
  );
});

test("offline does not suppress a local start", () => {
  const pubkey = "c".repeat(64);
  assert.equal(
    pubkeysLiveElsewhere({ [pubkey]: "offline" }).has(pubkey),
    false,
  );
});

test("a pubkey the relay said nothing about is unknown, not offline", () => {
  // get_presence returns a sparse map. Absent must fail OPEN — a relay error
  // or a Redis outage must never make every agent unstartable.
  const pubkey = "d".repeat(64);
  assert.equal(pubkeysLiveElsewhere({}).has(pubkey), false);
});

test("an empty presence map suppresses nothing", () => {
  assert.equal(pubkeysLiveElsewhere({}).size, 0);
});

test("live pubkeys are normalized so mixed-case lookups match", () => {
  const upper = "E".repeat(64);
  assert.ok(pubkeysLiveElsewhere({ [upper]: "online" }).has("e".repeat(64)));
});

test("buildMentionNameTags records one send-time name per pubkey", () => {
  const refs = [
    { displayName: "살짝데친문어", pubkey: "A".repeat(64), isAgent: true },
    { displayName: "문어", pubkey: "a".repeat(64), isAgent: true },
    { displayName: "  ", pubkey: "b".repeat(64), isAgent: false },
  ];

  assert.deepEqual(buildMentionNameTags(refs), [
    ["mention", "a".repeat(64), "살짝데친문어"],
  ]);
});
