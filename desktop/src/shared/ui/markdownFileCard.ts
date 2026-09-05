import { rewriteRelayUrl } from "@/shared/lib/mediaUrl";

/** Minimal shape of an imeta entry as consumed by the markdown renderer. */
export type FileCardImetaEntry = {
  m?: string;
  size?: number;
  filename?: string;
  /** SHA-256 of the attachment bytes (from imeta `x` field). */
  x?: string;
  /** Optional thumbnail URL (from imeta `thumb` field). */
  thumb?: string;
  /** Fork-local theme previews for `text/html` apps. */
  previewLight?: string;
  previewDark?: string;
};

/**
 * A sandboxed HTML app resolved from an imeta entry. The card shows a static
 * preview and a **Run** action that opens the app in the auxiliary drawer;
 * the HTML itself never renders inside the message.
 */
export type ResolvedAppCard = {
  /** SHA-256 hex from imeta `x` — the app door is addressed by hash only. */
  sha256: string;
  filename: string;
  size?: number;
  /** Relay URL of the HTML blob, for the Download action. */
  downloadHref: string;
  /** Proxy-rewritten preview URLs, when the sender attached them. */
  previewLight?: string;
  previewDark?: string;
};

export type ResolvedFileCard = {
  href: string;
  filename: string;
  size?: number;
};

/**
 * A snapshot candidate resolved from an imeta entry.  The card shows both
 * an **Import** and a **Download** action.
 *
 * `snapshotKind` is discriminated so `.agent.*` and `.team.*` attachments
 * can share the same routing path without mixing agent-only assumptions.
 */
export type ResolvedSnapshotCard = {
  /** Sender-provided display label, with a filename-derived fallback. */
  displayName: string;
  href: string;
  filename: string;
  size?: number;
  /** SHA-256 hex from the imeta `x` field — required for verified fetch. */
  sha256: string;
  /** Discriminant for the snapshot kind. */
  snapshotKind: "agent" | "team";
  /**
   * Optional thumbnail URL for the card icon. PNG snapshots use the
   * attachment URL because the PNG body is the avatar card image. JSON
   * snapshots have no thumbnail and use the generic icon.
   */
  thumb?: string;
};

function snapshotDisplayName(filename: string, childText: string): string {
  const label = childText.trim();
  const labelIsSnapshotFilename = /\.agent\.(?:json|png)$/i.test(label);
  if (label && !labelIsSnapshotFilename) return label;

  const filenameStem = filename
    .replace(/\.agent\.(?:json|png)$/i, "")
    .replace(/[-_]+/g, " ")
    .trim();
  if (!filenameStem) return "Agent";

  return filenameStem
    .split(/\s+/)
    .map((word) => `${word.charAt(0).toUpperCase()}${word.slice(1)}`)
    .join(" ");
}

/**
 * Classify a markdown link as a snapshot candidate.
 *
 * A link is a candidate when:
 * - The filename ends with `.agent.json` or `.agent.png` (exact suffix, case-
 *   insensitive, after extracting from the URL if imeta has no filename).
 * - For `.agent.png`, the MIME must be `image/png` or absent (upload MIME is
 *   authoritative only for PNG because generic JSON often arrives as
 *   `application/octet-stream`).
 * - The imeta entry carries a non-empty `x` (SHA-256) field — required for
 *   the verified bounded fetch; without it the card cannot enable Import.
 *
 * Returns `null` to fall through to generic FileCard handling.
 */
export function resolveSnapshotCard(
  entry: FileCardImetaEntry | undefined,
  href: string | undefined,
  childText: string,
): ResolvedSnapshotCard | null {
  if (!href || !entry) return null;

  const filename =
    entry.filename || childText.trim() || (href.split("/").pop() ?? "");

  if (!filename) return null;

  const lower = filename.toLowerCase();
  const isJson = lower.endsWith(".agent.json");
  const isPng = lower.endsWith(".agent.png");
  const isTeamJson = lower.endsWith(".team.json");
  const isTeamPng = lower.endsWith(".team.png");

  if (!isJson && !isPng && !isTeamJson && !isTeamPng) return null;

  const isAnyPng = isPng || isTeamPng;

  // For PNG: MIME must be image/png when present; other MIMEs are inconsistent.
  if (isAnyPng && entry.m && entry.m !== "image/png") return null;

  // SHA-256 is required for the bounded verified fetch.
  const sha256 = entry.x?.trim();
  if (sha256?.length !== 64) return null;

  const snapshotKind: "agent" | "team" = isJson || isPng ? "agent" : "team";

  return {
    displayName: snapshotDisplayName(filename, childText),
    href,
    filename,
    size: entry.size,
    sha256,
    snapshotKind,
    // Agent PNG snapshots carry the avatar card image. Team PNG snapshots use
    // a transport placeholder, so render the team icon instead of that image.
    thumb: isPng ? rewriteRelayUrl(href) : undefined,
  };
}

/**
 * Classify a markdown link as a sandboxed HTML app.
 *
 * A link qualifies when its imeta entry is `text/html`, carries a 64-hex `x`
 * hash (the app door is addressed by hash, so unverifiable content is never
 * runnable), and the active relay advertises an app-content door
 * (`appContentAvailable`). Otherwise it falls through to the generic
 * download card — HTML stays an inert download exactly as before.
 */
export function resolveAppCard(
  entry: FileCardImetaEntry | undefined,
  href: string | undefined,
  childText: string,
  appContentAvailable: boolean,
): ResolvedAppCard | null {
  if (!appContentAvailable || !href || !entry) return null;
  if (entry.m !== "text/html") return null;
  const sha256 = entry.x?.trim().toLowerCase();
  if (!sha256 || !/^[0-9a-f]{64}$/.test(sha256)) return null;
  const filename =
    entry.filename || childText.trim() || href.split("/").pop() || "app.html";
  const preview = (url: string | undefined) =>
    url && /^https?:\/\//.test(url) ? rewriteRelayUrl(url) : undefined;
  return {
    sha256,
    filename,
    size: entry.size,
    downloadHref: href,
    previewLight: preview(entry.previewLight),
    previewDark: preview(entry.previewDark),
  };
}

/**
 * Decide whether a markdown link should render as a generic-file download
 * card. A link qualifies when its href matches an imeta entry whose MIME is
 * neither image nor video (media goes through the `img` renderer instead).
 *
 * Pure — extracted from `markdown.tsx` so the FileCard decision (the riskiest
 * part of the generic-file rendering path) is unit-testable without mounting
 * React. Returns the resolved card props, or `null` to fall through to normal
 * link handling.
 */
export function resolveFileCard(
  entry: FileCardImetaEntry | undefined,
  href: string | undefined,
  childText: string,
): ResolvedFileCard | null {
  if (
    !href ||
    !entry?.m ||
    entry.m.startsWith("image/") ||
    entry.m.startsWith("video/")
  ) {
    return null;
  }
  const filename =
    entry.filename || childText.trim() || href.split("/").pop() || "file";
  return { href: rewriteRelayUrl(href), filename, size: entry.size };
}
