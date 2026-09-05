import assert from "node:assert/strict";
import test from "node:test";

import { forumPostPreview } from "./forumPreview.ts";

const SHA = "0".repeat(64);
const APP_URL = `https://relay.example/media/${SHA}.html`;
const IMAGE_URL = "https://relay.example/media/photo.png";
const imetaByUrl = new Map([
  [APP_URL, {}],
  [IMAGE_URL, {}],
]);
const long = "a".repeat(250);
const clippedLong = `${"a".repeat(200)}...`;

test("short prose is returned unchanged", () => {
  assert.equal(forumPostPreview("Hello forum", imetaByUrl), "Hello forum");
});

test("long prose is clipped with an ellipsis", () => {
  assert.equal(forumPostPreview(long, imetaByUrl), clippedLong);
});

test("a trailing attachment line survives the clip", () => {
  assert.equal(
    forumPostPreview(`${long}\n[app.html](${APP_URL})`, imetaByUrl),
    `${clippedLong}\n\n[app.html](${APP_URL})`,
  );
});

test("several trailing attachments and blank lines are kept in order", () => {
  assert.equal(
    forumPostPreview(
      `Look\n\n![photo](${IMAGE_URL})\n\n[app.html](${APP_URL})\n`,
      imetaByUrl,
    ),
    `Look\n\n![photo](${IMAGE_URL})\n[app.html](${APP_URL})`,
  );
});

test("a link without an imeta tag is ordinary prose", () => {
  assert.equal(
    forumPostPreview(`${long}\n[docs](https://example.com/docs)`, imetaByUrl),
    clippedLong,
  );
});

test("an attachment link in the middle of the prose is not lifted", () => {
  const content = `[app.html](${APP_URL})\n${"b".repeat(250)}`;
  assert.equal(
    forumPostPreview(content, imetaByUrl),
    `${content.slice(0, 200)}...`,
  );
});

test("a post that is only an attachment keeps it", () => {
  assert.equal(
    forumPostPreview(`[app.html](${APP_URL})`, imetaByUrl),
    `[app.html](${APP_URL})`,
  );
});

test("without imeta nothing is treated as an attachment", () => {
  assert.equal(
    forumPostPreview(`${long}\n[app.html](${APP_URL})`, new Map()),
    clippedLong,
  );
});
