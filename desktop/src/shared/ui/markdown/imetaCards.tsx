import * as React from "react";
import { useAppContentAvailable } from "@/shared/lib/appContent";
import {
  type FileCardImetaEntry,
  resolveAppCard,
  resolveFileCard,
} from "../markdownFileCard";
import { AppCard } from "./AppCard";
import { FileCard } from "./FileCard";
import type { ImetaLookup } from "./types";

/**
 * Resolve an imeta-backed link into its card: a sandboxed HTML app (preview +
 * Run, only when the relay advertises an app door) or a generic download
 * card. Media links render as `img` and never reach here. Call it
 * unconditionally — it reads the app-content availability hook.
 */
export function useImetaCard(
  entry: FileCardImetaEntry | undefined,
  href: string | undefined,
  label: string,
  sharedBy: string | undefined,
): React.ReactElement | null {
  const appContentAvailable = useAppContentAvailable();
  const app = resolveAppCard(entry, href, label, appContentAvailable);
  if (app) {
    return (
      <AppCard
        downloadHref={app.downloadHref}
        filename={app.filename}
        previewDark={app.previewDark}
        previewLight={app.previewLight}
        sha256={app.sha256}
        sharedBy={sharedBy}
        size={app.size}
      />
    );
  }
  const file = resolveFileCard(entry, href, label);
  if (file) {
    return (
      <FileCard href={file.href} filename={file.filename} size={file.size} />
    );
  }
  return null;
}

/**
 * True when a paragraph's children include a link that renders as an app card
 * (a block-level `<div>`), so `MarkdownParagraph` can emit `<div>` instead of
 * `<p>` and avoid invalid `<p><div>` nesting. Availability is irrelevant
 * here: when the relay has no app door the link degrades to an inline
 * FileCard, which is fine inside a `<div>` too.
 */
export function paragraphHasAppCard(
  children: React.ReactNode[],
  imetaByUrl: ImetaLookup | undefined,
): boolean {
  return children.some((child) => {
    if (!React.isValidElement<{ href?: string }>(child)) return false;
    const href = child.props.href;
    if (typeof href !== "string") return false;
    return resolveAppCard(imetaByUrl?.get(href), href, "", true) !== null;
  });
}
