-- ── Per-community workspace name (NIP-11 `name`) ─────────────────────────────
-- Fork feature. Set by relay admins/owners via the kind:9033 workspace-profile
-- command (a `name` tag next to upstream's `icon` tag) and served to clients
-- as the `name` field of the community's NIP-11 relay information document,
-- so every client shows the same community name instead of one it derived
-- from the relay host. Upstream's desktop keeps its locally chosen label and
-- ignores this field.
--
-- Additive migration, same shape as 0003_community_icon: `communities` is an
-- operator-global registry table (no community_id column by design); this
-- adds a per-row presentation attribute, not tenant data. Length and
-- single-line constraints are enforced at the 9033 write path, not here.
--
-- Fork note: if upstream lands its own 0045, renumber this file (and the
-- assertion in crates/buzz-db/src/runtime/migration.rs) before merging.

ALTER TABLE communities ADD COLUMN name TEXT;
