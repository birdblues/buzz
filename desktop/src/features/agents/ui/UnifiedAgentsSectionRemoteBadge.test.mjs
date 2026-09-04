/**
 * A persona definition that first reached this device via inbound sync
 * (`remoteOrigin`) renders a small cloud provenance marker in the card's
 * top-left corner AND loses the avatar Start affordance — starting it here
 * would mint a NEW local identity for an agent that already answers from the
 * device that created it (the backend refuses the create regardless; the UI
 * just removes the invitation). Locally created definitions keep their Start
 * control and show no cloud; a card backed by a local instance shows no cloud
 * either (the instance was deliberately set up here).
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
let TooltipProvider;
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
    // Presence availability is read for every card; personas with no instance
    // have no pubkey to look up, so unknown is the honest fixture value.
    getAvailability: () => undefined,
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
    personaIdsOwnedElsewhere: new Set(),
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
      createElement(
        TooltipProvider,
        null,
        createElement(UnifiedAgentsSection, props),
      ),
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
  ({ TooltipProvider } = await import("@/shared/ui/tooltip.tsx"));
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

test("remote-origin definition card shows the cloud and no Start affordance", async () => {
  installIpc();

  await act(async () => {
    renderSection(
      baseProps({
        // URL avatar fixture: the no-badge frame must render the URL branch
        // too, not just the initials fallback.
        personas: [
          persona({ remoteOrigin: true, avatarUrl: "https://x/a.png" }),
        ],
      }),
    );
  });

  const cloud = screen.getByTestId("persona-remote-origin-persona-1");
  // Shares `OtherSetupAgentMarker`'s wording with the pubkey-scoped marker.
  assert.equal(cloud.getAttribute("aria-label"), "Not managed on this device");
  assert.equal(
    screen.queryByTestId("persona-runtime-start-persona-1"),
    null,
    "remote definition must not offer a Start control",
  );
});

test("locally created definition card keeps Start and has no cloud", async () => {
  installIpc();

  await act(async () => {
    renderSection(baseProps({ personas: [persona()] }));
  });

  assert.equal(screen.queryByTestId("persona-remote-origin-persona-1"), null);
  assert.ok(
    screen.getByTestId("persona-runtime-start-persona-1"),
    "local definition keeps its Start control",
  );
});

test("relay-confirmed remote instance hides Start on an unmarked definition", async () => {
  // The incident: a definition authored locally (or synced before
  // `remoteOrigin` existed) carries no marker, yet its agent is already set up
  // on another device. Pressing Start would mint a SECOND identity and the
  // agent would answer every mention twice.
  //
  // Deliberately isolated from the `remoteOrigin` half — this persona sets no
  // marker, so dropping the `personaIdsOwnedElsewhere` term fails THIS test
  // while "remote-origin definition card shows the cloud and no Start
  // affordance" still passes, and vice versa.
  installIpc();

  await act(async () => {
    renderSection(
      baseProps({
        personas: [persona()],
        personaIdsOwnedElsewhere: new Set(["persona-1"]),
      }),
    );
  });

  assert.equal(
    screen.queryByTestId("persona-runtime-start-persona-1"),
    null,
    "a definition owned on another device must not offer Start",
  );
  assert.ok(
    screen.getByTestId("persona-remote-origin-persona-1"),
    "the card explains why with the same marker remoteOrigin uses",
  );
});

test("instance-backed card suppresses the cloud", async () => {
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
