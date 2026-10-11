# Rocket.Chat → gochatserver Migration — Requirements

Source: `rocketchat-backup-2026-10-07_07-51-40.archive` — `mongodump --archive --db=rocketchat` (raw BSON, MongoDB 8.2.1, replica set rs0).

Target: `github.com/gochathub/gochatserver` — Go + PostgreSQL, S3-compatible attachments, OpenAPI/REST + WebSocket server.

## Decisions (from brainstorm, 2026-10-07)

1. **Tool**: Go CLI subcommand inside the gochatserver repo (e.g. `chatserver migrate rocketchat <archive>`). Reuses `internal/store`, `internal/storage`, `internal/pwd`. New dependency: `go.mongodb.org/mongo-driver` (BSON decoding only — no server).
2. **No Mongo container needed**: the tool parses the mongodump archive format directly from the file. (Docker Mongo 8.2 stays the fallback if BSON parsing proves brittle.)
3. **Cutover**: repeatable/delta mode. Tool re-runs against a fresh backup right before Rocket.Chat is retired; it imports only what's newer than the previous run. Rocket.Chat is decommissioned after the final run — no live sync.
4. **Passwords**: users keep them. `internal/pwd` gains a verify path for legacy `bcrypt(SHA-256(pw))` hashes (Rocket.Chat/Meteor scheme), marked with a `bcrypt$` prefix in `users.password_hash`, re-hashed to argon2id on successful login.
5. **In scope beyond core**: file attachments + user avatars; message edit history (`message_revisions`).
6. **Out of scope**: system messages (join/leave/name-change), custom emoji, integrations/webhooks/oAuth apps, livechat/omnichannel, roles/permissions settings, Rocket.Chat settings migration, sessions/oauth tokens. **2FA moved in-scope (2026-10-07 revision)**: TOTP enrollment (`secret`, `hashedBackup`) and email-2FA flags are preserved in a `migrate_rc_users` sidecar table for the future gochatserver 2FA feature.
7. **Discussions skipped**: the 2 `prid` rooms (9 messages, auto-generated names, dormant since 2020) and their messages are dropped.
8. **Livechat dropped**: 2 visitor rooms (12 nav-history messages) + the 4,277 livechat navigation history junk messages (4,265 with no room) are dropped.
9. **Special users** (verified against data):
   - `rocket.cat`: imported as disabled user `rocket-cat` (83 non-junk posts — MantisBT webhook content routed through it).
   - `MantisBT` + `n8n`: imported as disabled users (message authorship).
   - `clamav-integration.bot`, `jitsi.bot`, `oe-reminder.bot` (3 app users, 0 messages): skipped.
   - 2 deleted RC users referenced by 4 messages: tombstone disabled users, username recovered from the message's denormalized `u.username`.

## Data mapping

| Rocket.Chat | gochatserver | Notes |
|---|---|---|
| `users` (bcrypt pw) | `users` | username lowercased/normalized to `^[a-z0-9_.-]{1,64}$`; collisions appended numeric suffixes; email = first verified email, lowercased; roles: admin→admin, else user |
| `rocketchat_room` t:c / t:p / t:d | `rooms` public / private / direct (2 participants) / group_direct (>2) | `prid` discussion rooms dropped (decision 7) |
| direct room `usernames[]` | participant pair | creator = first username (stable order for re-runs) |
| `rocketchat_subscriptions` | `room_members` + read state | last-seen `ls` → `room_members.last_read_message_id`; owner→`admin` member role; `muted` → `muted_until` n/a (left null) |
| message author `rocket.cat` | skipped content | system-typed messages filtered out (t set); rooms with only system author still need a real `created_by` → admin fallback |
| `rocketchat_messages.msg` | `messages.body` (markdown) | quote-type attachments converted to markdown blockquotes in-body; oEmbed/link-preview attachments dropped |
| `ts` / `editedAt` | `created_at` / `edited_at` | original timestamps preserved |
| `edits[]` | `message_revisions` | per selected scope |
| `reactions{emoji: usernames[]}` | `message_reactions` | emoji text stored verbatim |
| `mentions[]` (@user) | `message_mentions` | @all/@here/@channel skipped (no per-room mention) |
| `tmid` (thread main) | `reply_to_message_id` | threads flatten to reply chains |
| deleted messages (`deletedAt`) | `deleted_at` tombstone | imported |
| `rocketchat_uploads` bare (name/rid/userId) + `.files`/`.chunks` GridFS | S3 upload + `attachments` | write `status='ready'` directly, bypass API size limits; only files referenced by imported messages (693); 282 orphans counted, not imported |
| per-user avatars | `users.avatar_attachment_id` | ADR-011 flow; RC keeps every version — newest per user wins |
| `services.totp` / `services.email2fa` | `migrate_rc_users` sidecar (goose 002) | TOTP plain secret preserved → authenticator apps survive cutover once target ships TOTP |
| DM participants | `contacts` (mutual rows) | one pair of rows per direct room, ADR-010 |

## Identity strategy (delta/idempotency)

- Stable IDs: derive uuidv5 from the Rocket.Chat `_id` under a fixed namespace (users, rooms, messages, attachments each get their own sub-namespace). Re-runs upsert, never duplicate.
- Progress watermark: highest source timestamp per collection recorded in `app_config`; a re-run imports only newer records.
- Rooms/users created in Rocket.Chat after an earlier run appear as upserts of missing records; edits happen only when the watermark advances.

## Non-functional

- **Idempotency**: full re-run against a migrated DB is a no-op for completed work; delta only for newer records.
- **No plaintext secrets**: password hashes copied verbatim (bcrypt only); no session/2FA/oauth export.
- **Bounded memory**: stream the archive BSON document-by-document; never load 595MB into RAM.
- **Report at the end**: counts per collection (users, rooms, messages, files, skipped) written to stdout and a JSON summary file.
- **Dry-run mode**: `--dry-run` parses and maps everything, writes nothing, prints the report.

## User stories / acceptance criteria

1. Admin runs the tool on a test DB against the archive; it reports N users, M rooms, K messages, F files without error.
2. A migrated user logs in with their old Rocket.Chat password; the server accepts the bcrypt fallback and re-stores argon2id.
3. Every message is queryable in the timeline with its original date order, including edits, reactions, replies, and read cursors.
4. Attachment messages render their files from S3 with original filenames and MIME types.
5. Re-running the tool against a newer backup imports only new users/rooms/messages/files and leaves earlier records untouched.
6. `--dry-run` writes nothing to the database or S3.

## Data profile (verified against the archive, 2026-10-07)

| Measure | Value |
|---|---|
| Rooms | 27 (22 private, 2 DMs, 1 public, 2 livechat) |
| Messages | 25,343 raw → **21,066 after junk/system filters** |
| Edits / edits history | 378 edited; `edits[]` present |
| Att. messages | 693 |
| Pinned | 2 → `rooms.pinned_message_id` also mapped |
| Mentions / reactions | 10 mention docs / 4 reaction docs |
| Users | 8 (see decision 9) |
| Uploads | 975 files, 361 MB; 7 avatars |
| Date range | 2019-01 → 2026-10 |

Confirmed non-issues in this dataset: no duplicate room names, no duplicate emails, no archived rooms, no deleted messages, no teams, no custom emoji entries, 2 marketplace integrations (out of scope).

## Open questions

- **S3 endpoint/bucket config** for the migration run — runtime env, needed at implementation time, not a spec blocker.
- **Target precondition**: migration run demands an empty target DB (admin bootstrap user only) — refuses to run otherwise; protects from double imports.