import type * as React from "react";
import { useAppContentAvailable } from "@/shared/lib/appContent";
import {
  type FileCardImetaEntry,
  resolveAppCard,
  resolveFileCard,
} from "../markdownFileCard";
import { AppCard } from "./AppCard";
import { FileCard } from "./FileCard";

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
