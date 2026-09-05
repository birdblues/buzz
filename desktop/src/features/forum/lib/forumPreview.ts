/** Characters of prose a forum post card shows before clipping. */
export const FORUM_PREVIEW_MAX_CHARS = 200;

const ATTACHMENT_LINE_RE = /^\s*!?\[[^\]\n]*\]\(([^)\s]+)\)\s*$/;

/**
 * The body a forum post card renders: the prose clipped to `maxChars`, then
 * every trailing attachment line intact.
 *
 * Attachments are written as their own trailing markdown lines
 * (`[file.html](url)`, `![image](url)`) whose URL has an `imeta` tag. A plain
 * character cut lands inside those lines for any long post, leaving broken
 * markdown source in the card instead of the attachment card or image.
 * Clipping only the prose keeps the attachments renderable.
 */
export function forumPostPreview(
  content: string,
  imetaByUrl: ReadonlyMap<string, unknown>,
  maxChars = FORUM_PREVIEW_MAX_CHARS,
): string {
  const lines = content.split("\n");
  let end = lines.length;
  const trailing: string[] = [];
  while (end > 0) {
    const line = lines[end - 1] ?? "";
    if (line.trim() === "") {
      end -= 1;
      continue;
    }
    const match = ATTACHMENT_LINE_RE.exec(line);
    const url = match?.[1];
    if (url && imetaByUrl.has(url)) {
      trailing.unshift(line.trim());
      end -= 1;
      continue;
    }
    break;
  }
  const prose = lines.slice(0, end).join("\n").replace(/\s+$/, "");
  const clipped =
    prose.length > maxChars ? `${prose.slice(0, maxChars)}...` : prose;
  if (trailing.length === 0) return clipped;
  const attachments = trailing.join("\n");
  return clipped === "" ? attachments : `${clipped}\n\n${attachments}`;
}
