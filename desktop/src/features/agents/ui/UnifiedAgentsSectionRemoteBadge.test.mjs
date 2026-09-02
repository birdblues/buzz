/**
 * A persona definition that first reached this device via inbound sync
 * (`remoteOrigin`) renders a "From another device" badge on its
 * definition-only card — the cue that Start would mint a NEW local identity
 * for an agent that already answers from the device that created it. The
 * badge must NOT appear on locally created definitions, nor on cards backed
 * by a local instance (the card then represents the instance, which was
 * deliberately set up here).
 */

import assert from "node:assert/strict";
import { after, afterEach, before, test } from "node:test";

import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost",
});

const clients = [];

let act;
let cleanup;
let render;
let screen;
let createElement;
let QueryClient;
let QueryClientProvider;
let UnifiedAgentsSection;

const ipcHandlers = new Map();

const SELF_PK = "c".repeat(64);
const AGENT_PK = "b".repeat(64);

function persona(overrides = {}) {
  return {
    id: "persona-1",
    displayName: "Fizz Prime",
    avatarUrl: null,
    model: null,
    isBuiltIn: false,
    sourceTeam: null,
    ...overrides,
  };
}

function baseProps(overrides = {}) {
  return {
    defaultModel: "gpt-x",
    actionErrorMessage: null,
    actionNoticeMessage: null,
    agents: [],
    agentsError: null,
    isActionPending: false,
    isAgentsLoading: false,
    restartingAgentPubkey: null,
    startingAgentPubkey: null,
    startingPersonaIds: new Set(),
    onOpenAgentProfile: () => {},
    onOpenPersonaProfile: () => {},
    onRestartAgent: () => {},
    onStartAgent: () => {},
    onStartPersona: () => {},
    personas: [],
    personasError: null,
    personaFeedbackErrorMessage: null,
    personaFeedbackNoticeMessage: null,
    isPersonasLoading: false,
    isPersonasPending: false,
    onOpenCatalog: () => {},
    onDuplicatePersona: () => {},
    onEditPersona: () => {},
    onSharePersona: () => {},
    onDeactivatePersona: () => {},
    onDeletePersona: () => {},
    ...overrides,
  };
}

function renderSection(props) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 } },
  });
  clients.push(client);
  return render(
    createElement(
      QueryClientProvider,
      { client },
      createElement(UnifiedAgentsSection, props),
    ),
  );
}

before(async () => {
  Object.assign(globalThis, {
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    window: dom.window,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: dom.window.navigator,
    writable: true,
  });
  dom.window.matchMedia = () => ({
    matches: true,
    addEventListener() {},
    removeEventListener() {},
  });
  dom.window.__TAURI_INTERNALS__ = {
    invoke: (cmd, args) => {
      const handler = ipcHandlers.get(cmd);
      if (handler) return handler(args);
      return Promise.reject(new Error(`unmocked Tauri command: ${cmd}`));
    },
    transformCallback: () => Math.random(),
  };

  ({ act, cleanup, render, screen } = await import("@testing-library/react"));
  ({ createElement } = await import("react"));
  ({ QueryClient, QueryClientProvider } = await import(
    "@tanstack/react-query"
  ));
  ({ UnifiedAgentsSection } = await import("./UnifiedAgentsSection.tsx"));
});

afterEach(() => {
  cleanup?.();
  for (const client of clients.splice(0)) {
    client.cancelQueries();
    client.clear();
  }
  ipcHandlers.clear();
});

after(() => dom.window.close());

function installIpc() {
  ipcHandlers.set("get_identity", () =>
    Promise.resolve({ pubkey: SELF_PK, display_name: "Me" }),
  );
  ipcHandlers.set("list_archived_identities", () => new Promise(() => {}));
  ipcHandlers.set("get_user_profile", () =>
    Promise.resolve({
      pubkey: AGENT_PK,
      display_name: null,
      avatar_url: null,
      about: null,
      nip05_handle: null,
      owner_pubkey: null,
    }),
  );
}

test("remote-origin definition card shows the From-another-device badge", async () => {
  installIpc();

  await act(async () => {
    renderSection(baseProps({ personas: [persona({ remoteOrigin: true })] }));
  });

  const badge = screen.getByTestId("persona-remote-origin-persona-1");
  assert.equal(badge.textContent, "From another device");
});

test("locally created definition card has no remote badge", async () => {
  installIpc();

  await act(async () => {
    renderSection(baseProps({ personas: [persona()] }));
  });

  assert.equal(screen.queryByTestId("persona-remote-origin-persona-1"), null);
});

test("instance-backed card suppresses the remote badge", async () => {
  installIpc();

  await act(async () => {
    renderSection(
      baseProps({
        personas: [persona({ remoteOrigin: true })],
        agents: [
          {
            pubkey: AGENT_PK,
            name: "Instance",
            personaId: "persona-1",
            status: "stopped",
            model: null,
            modelSource: "global",
            lastError: null,
            lastErrorCode: null,
            needsRestart: false,
            personaOrphaned: false,
          },
        ],
      }),
    );
  });

  assert.equal(screen.queryByTestId("persona-remote-origin-persona-1"), null);
});
