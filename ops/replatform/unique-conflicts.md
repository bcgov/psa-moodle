# Unique-key conflicts in a return (replatform runbook RB08)

Legacy compares text with `utf8mb4_unicode_ci`, which ignores case and accents: `cafe`, `Café` and `CAFÉ` are equal.
The new stack's Postgres treats them as different. So two values the new site accepted can collide in one of legacy's
unique indexes, and the reverse conversion stops with, for example:

    Duplicate entry '1-rp-synthetic-café' for key 'tag_tagnam_uix'

(proven on a local copy, 2026-11-25). The stop is safe: `moodle_bailout` is discarded and nothing reached legacy.

## Find conflicts before a return

    ops/replatform/reverse-precheck.sh <postgres container or pod>

It reports each unique index with colliding keys, never the values. It runs daily through every bail-out window, so a
conflict is resolved long before a return is needed.

## Resolve one

Every resolution is an **owner decision**, recorded in the window log. List the rows involved on the new stack, by id,
in the private folder only. Then choose one of:

1. **Rename** the newer value so it no longer collides, for example a tag `café` becomes `café (2)`. Moodle's own UI is
   the preferred way, because it keeps related records consistent.
2. **Merge** duplicates where Moodle supports it (tags can be combined in Site administration → Appearance → Manage tags).
3. **Accept the loss** of the newer value in the return, if the owner decides it doesn't matter.

Re-run the precheck: it must report no collisions before the reverse conversion runs again.
