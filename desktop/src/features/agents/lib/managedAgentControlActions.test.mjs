import assert from "node:assert/strict";
import test from "node:test";

import {
  startManagedAgentWithRules,
  respawnManagedAgentWithRules,
} from "./managedAgentControlActions.ts";

function agent(overrides = {}) {
  return {
    pubkey: "deadbeef".repeat(8),
    name: "Mesh Agent",
    personaId: null,
    relayUrl: "ws://localhost:3000",
    acpCommand: "buzz-acp",
    agentCommand: "goose",
    agentArgs: [],
    mcpCommand: "",
    turnTimeoutSeconds: 320,
    idleTimeoutSeconds: null,
    maxTurnDurationSeconds: null,
    parallelism: 1,
    systemPrompt: null,
    model: "hf://demo/model.gguf",
    envVars: {},
    status: "stopped",
    pid: null,
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
    lastStartedAt: null,
    lastStoppedAt: null,
    lastExitCode: null,
    lastError: null,
    logPath: null,
    startOnAppLaunch: false,
    backend: { type: "local" },
    backendAgentId: null,
    respondTo: "owner-only",
    respondToAllowlist: [],
    ...overrides,
  };
}

test("relay-mesh agents delegate start to the backend preflight", async () => {
  const meshAgent = agent({
    envVars: {
      BUZZ_AGENT_PROVIDER: "openai",
      OPENAI_COMPAT_BASE_URL: "http://127.0.0.1:9337/v1/",
    },
  });

  let calledWith = null;
  await startManagedAgentWithRules({
    agent: meshAgent,
    startManagedAgent: async (pubkey) => {
      calledWith = pubkey;
    },
  });
  assert.equal(calledWith, meshAgent.pubkey);

  // Backend preflight failures (e.g. no live serve target) propagate as-is.
  await assert.rejects(
    startManagedAgentWithRules({
      agent: meshAgent,
      startManagedAgent: async () => {
        throw new Error("no live serve target is available for this model");
      },
    }),
    /no live serve target/,
  );
});

test("ordinary local agents still start normally", async () => {
  let calledWith = null;
  await startManagedAgentWithRules({
    agent: agent(),
    startManagedAgent: async (pubkey) => {
      calledWith = pubkey;
    },
  });
  assert.equal(calledWith, "deadbeef".repeat(8));
});

// --- respawnManagedAgentWithRules: stop→clear→start boundary tests -----------

test("test_respawn_stop_success_start_failure_onStopped_still_fires", async () => {
  // Prove: onStopped fires at the stop-success boundary even when start later
  // throws.  This is the key discriminator: on round-1 code the clear only
  // ran after the full respawn, so a failed start left the badge intact.
  const runningAgent = agent({ status: "running" });
  let onStoppedFired = false;

  await assert.rejects(
    respawnManagedAgentWithRules({
      agent: runningAgent,
      stopManagedAgent: async () => {
        /* stop succeeds */
      },
      startManagedAgent: async () => {
        throw new Error("start failed");
      },
      onStopped: () => {
        onStoppedFired = true;
      },
    }),
    /start failed/,
  );

  assert.ok(
    onStoppedFired,
    "onStopped must fire at stop-success boundary even when start subsequently fails",
  );
});

test("test_respawn_stop_failure_onStopped_not_called", async () => {
  // Prove: onStopped does NOT fire when stop itself throws.  Clearing on a
  // failed stop would remove a badge that is still legitimately active.
  const runningAgent = agent({ status: "running" });
  let onStoppedFired = false;

  await assert.rejects(
    respawnManagedAgentWithRules({
      agent: runningAgent,
      stopManagedAgent: async () => {
        throw new Error("stop failed");
      },
      startManagedAgent: async () => {
        /* should not be reached */
      },
      onStopped: () => {
        onStoppedFired = true;
      },
    }),
    /stop failed/,
  );

  assert.ok(
    !onStoppedFired,
    "onStopped must NOT fire when stop itself fails — badge is still active",
  );
});

test("test_respawn_onStopped_fires_before_start_resolves", async () => {
  // Prove: onStopped fires strictly between stop resolution and start
  // invocation.  A clear that fires after start begins can tombstone genuine
  // new turns from the freshly spawned process.
  const runningAgent = agent({ status: "running" });
  const events = [];

  await respawnManagedAgentWithRules({
    agent: runningAgent,
    stopManagedAgent: async () => {
      events.push("stop");
    },
    startManagedAgent: async () => {
      events.push("start");
    },
    onStopped: () => {
      events.push("onStopped");
    },
  });

  assert.deepEqual(
    events,
    ["stop", "onStopped", "start"],
    "onStopped must fire after stop resolves and before start is called",
  );
});

// ── cross-machine duplicate guard ───────────────────────────────────────────
//
// The backend reports `runningElsewhere` instead of erroring, so a start that
// spawned nothing still resolves. These tests pin who gets to override that.

test("an explicit Start asks before adding a second harness", async () => {
  const calls = [];
  let asked = false;

  await startManagedAgentWithRules({
    agent: agent(),
    startManagedAgent: async (input) => {
      const intent = typeof input === "string" ? undefined : input.intent;
      calls.push(intent);
      // The first (implicit) attempt reports the agent is already live.
      return intent === "explicit" ? {} : { startOutcome: "runningElsewhere" };
    },
    confirmRunningElsewhere: () => {
      asked = true;
      return true;
    },
  });

  assert.ok(asked, "the user must see the duplicate-reply consequence");
  assert.deepEqual(calls, [undefined, "explicit"]);
});

test("declining the confirmation leaves no second harness", async () => {
  const calls = [];

  await startManagedAgentWithRules({
    agent: agent(),
    startManagedAgent: async (input) => {
      calls.push(typeof input === "string" ? undefined : input.intent);
      return { startOutcome: "runningElsewhere" };
    },
    confirmRunningElsewhere: () => false,
  });

  assert.deepEqual(calls, [undefined], "no retry after the user declines");
});

test("a normal start never prompts", async () => {
  let asked = false;

  await startManagedAgentWithRules({
    agent: agent(),
    startManagedAgent: async () => ({ startOutcome: "startedLocal" }),
    confirmRunningElsewhere: () => {
      asked = true;
      return true;
    },
  });

  assert.equal(asked, false);
});

test("respawn bypasses the guard only after killing a live local child", async () => {
  const calls = [];
  let stopped = false;

  await respawnManagedAgentWithRules({
    agent: agent({ status: "running" }),
    stopManagedAgent: async () => {
      stopped = true;
    },
    startManagedAgent: async (input) => {
      calls.push(typeof input === "string" ? undefined : input.intent);
      return {};
    },
  });

  assert.ok(stopped);
  assert.deepEqual(
    calls,
    ["afterLocalStop"],
    "our own just-killed harness may still show as online in Redis",
  );
});

test("respawn of a stopped agent goes through the confirmation instead", async () => {
  // Nothing local was killed, so an `online` reading belongs to another
  // device — bypassing the guard here would recreate the duplicate.
  const calls = [];
  let stopped = false;
  let asked = false;

  await respawnManagedAgentWithRules({
    agent: agent({ status: "stopped" }),
    stopManagedAgent: async () => {
      stopped = true;
    },
    startManagedAgent: async (input) => {
      const intent = typeof input === "string" ? undefined : input.intent;
      calls.push(intent);
      return intent === "explicit" ? {} : { startOutcome: "runningElsewhere" };
    },
    confirmRunningElsewhere: () => {
      asked = true;
      return true;
    },
  });

  assert.equal(stopped, false, "there was no live local child to stop");
  assert.ok(asked, "the user decides, not an automatic bypass");
  assert.deepEqual(calls, [undefined, "explicit"]);
});
