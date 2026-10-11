# Design — Rocket.Chat → gochatserver migration

Implements `REQUIREMENTS.md`. All new code in the **gochatserver** repo.

## Code placement (gochatserver)

| Path | What |
|---|---|
| `internal/migrate/archive.go` | mongodump archive stream reader + BSON doc dispatch |
| `internal/migrate/rocketchat.go` | collection → table mapping + SQL |
| `internal/cli/commands.go` | new top-level cobra command `rcmigrate` (existing `migrate` = goose, untouched) |
| `internal/pwd/pwd.go` | accept legacy `bcrypt$` hashes |
| `internal/service` auth path | rehash-on-login for bcrypt users |
| `internal/storage/storage.go` | add `PutObject(ctx, key, mime, r io.Reader, size)` to the S3 impl (server-side upload; presign-only today) |

Deps: `go.mongodb.org/mongo-driver/v2` (bson decode only — no server/client), `golang.org/x/crypto/bcrypt` (same x/crypto module already fetched for argon2). `github.com/google/uuid` already present.

## CLI contract

```
chatserver rcmigrate --archive <file> [--dry-run] [--skip-files]
```

- `DATABASE_URL`, `S3_*` env — same config as the server (`internal/config`).
- Precondition: users table empty **or** watermark `app_config['migrate.rc']` exists; otherwise refuse (protects non-empty DBs).
- Output: JSON summary to stdout (counts per collection, skipped counts, watermark) + JSON file `--report` optional.

## Archive format (verified against the real file)

Stream of `[int32 LE length][BSON doc]`… First doc = tool metadata. Then alternating **collection-metadata docs** (fields `db`, `collection`, indexes info, no `_id`) and **data docs** (`_id`). Parser:

```go
for {
    size := readInt32LE(); doc := readBytes(size); bson.Unmarshal
    if doc.collection != nil && doc._id == nil → switch current ns
    else → dispatch(current ns)  // data doc
}
```

Collections used: `users`, `rocketchat_room`, `rocketchat_subscription`, `rocketchat_message`, `rocketchat_uploads.{files,chunks}`, `rocketchat_avatars.{files,chunks}`. Everything else (`_trash`, oauth, livechat_*, cron, settings, …) ignored.

Two passes: pass 1 records byte offsets of `chunks` docs per `files_id` (needed for random access, keeps memory bounded); pass 2 dispatches data docs and uploads files by seeking to their chunks.

## Identity — deterministic UUIDv5 (delta-safe)

`uuid.NewV5(<ns uuid>, rc_id)`; separate fixed namespaces per kind: users, rooms, messages, attachments, subs. Re-runs upsert the same rows — no ID map table, no watermark ambiguity for IDs.

## Pipeline (single pass 2, in dependency order)

1. **users** — skip type `app` (0 messages). `username` lower/normalize to `^[a-z0-9_.-]{1,64}$`, `>64` truncate, collisions get `-2` suffix. Tombstone users for deleted RC `_id`s referenced by messages (username from `message.u.username`, else `deleted-<id-prefix>`) → `enabled=false`. bcrypt: `password_hash = "bcrypt$" + rc_password.bcrypt`. `created_at` = RC `createdAt`, `last_seen_at` = `lastLogin`.
2. **rooms** — t:c→public, t:p→private, t:d→direct (`usernames` len 2) / group_direct (>2). Skip `t:'l'` + `prid` rooms. `name` NULL for direct; `topic`→`description`; creator = lowest-sorted participant. All upserted every run (≤27 rows).
3. **room_members** — from subscriptions (owner → role `admin`) + DM pairs. `last_read_message_id` = nearest message ≤ subscription `ls`.
4. **contacts** — both directions per DM room.
5. **messages** — skip `t != null` (system + nav junk). Filter `ts > watermark` (delta). id = uuidv5(MSG_NS, _id). `reply_to` ← `tmid`. deleted→`deleted_at` (none exist today, behavior for delta). `edits[]`→`message_revisions` (editor = author, `created_at` = edit ts). `reactions{emoji:usernames[]}`→`message_reactions` (created_at = message ts), mapped via username→uuidv5. `mentions[{_id,username}]`→`message_mentions` (skip @all). Quote attachments → markdown blockquote appended to body; oEmbed previews dropped. Batch upsert 500/doc batch, `ON CONFLICT (id) DO NOTHING` (immutable).
6. **pinned** — newest `pinned:true` message per room → `rooms.pinned_message_id`.
7. **files** — for each `uploads.files` doc (`uploadDate > watermark`): assemble chunks by offset, `PutObject` to S3 with storage key `att/<uuidv5(ATT_NS,file_id)>/<filename>`, `INSERT ... ON CONFLICT DO NOTHING` into `attachments` (`status='ready'`, mime from `type`, dims from message's `image_dimensions`), link `message_attachments` via `message.file._id`. Missing-file attachment rows are skipped with a count. `--skip-files` = metadata only, no S3.
8. **avatars** — `rocketchat_avatars.files` (7): same ingest; mapping to user resolved from the files doc's key (RC keys avatar files by user id — verified at implementation from one sample doc; fallback: `filename` = username). Sets `users.avatar_attachment_id`.
9. **watermark** — after successful run: `app_config['migrate.rc']` = `{message_ts_max, upload_ts_max}`. Fail mid-run keeps old watermark; reruns are correct because IDs are deterministic.
10. **report** — users/rooms/members/collings/messages/reactions/mentions/revisions/files/avatars counts + skip counts.

## Target code changes (small, reviewable)

- `pwd.Verify`: prefix split. `bcrypt$<bcryptstr>` → `bcrypt.CompareHashAndPassword(hash, sha256hex(password))` (Rocket.Chat/Meteor scheme: bcrypt over the *hex digest string*). Constant-time compare is bcrypt's internal property; the argon2 path keeps `subtle`. Crafted-hash DoS guard already applies to argon2; bcrypt has its own 72-byte truncation — no new attack surface.
- Service auth: after successful `Verify` on a `bcrypt$` hash, `Hash()` argon2id + update `users.password_hash` (single call site where login verifies).
- `storage.S3.PutObject`: thin `client.PutObject` wrapper. Not added to the `service.Storage` interface (only migrate uses server-side upload).

## Tests

1. **Fixture archive**: Go test builds a synthetic mongodump archive (bson-encoded docs: 2 users, 1 room, 1 DM, 3 messages, 1 file+2 chunks, 1 edit, 1 reaction) → `--dry-run` counts only, then run against `TEST_DATABASE_URL` → all counts; **run twice → identical counts** (idempotency); append newer message doc → delta run imports exactly 1 more.
2. **pwd**: `argon2id$` roundtrip (existing) + new `bcrypt$` verify with a known bcrypt hash of `sha256hex("pw")` → true; wrong pw → false; argon2id rejection of non-argon2 prefix stays.
3. **Integration login**: migrated user authenticates; second login uses argon2id (password_hash rewritten).
4. Empty-DB precondition refusal test.

## Skipped (ponytail)

- ID map table / watermark tables — uuidv5 + `app_config` covers both.
- Livechat/omnichannel, integrations, custom emoji, settings — per requirements, no data worth moving (verified counts).
- Checkpointing mid-run — reruns are idempotent, that *is* the resume.
- `--verify`/SHA-256 re-check of uploaded objects — S3 upload errors surface on their own; add only if uploads prove flaky.

## Delta semantics + 2FA (added 2026-10-07)

- Delta watermark: `message_ts_max` advances **only on runs that imported files**; `--skip-files` sets `files_pending` and leaves message/avatar cursors untouched so the next full run redoes those messages with attachments.
- Sidecar: `migrate_rc_users` (goose 002) preserves 2FA enrollment (TOTP plaintext secret + hashed backup codes, email-2FA) per migrated user for the future 2FA feature; tokens/password material stripped.

## Verified source shapes (from the real archive)

- `rocketchat_uploads` (bare) = Uploads metadata: `_id, name, size, type, rid, userId, etag, complete, uploadedAt`; `.files`/`.chunks` = GridFS payload with only standard GridFS fields (`length/chunkSize/uploadDate/filename(=id)/contentType`). Message linkage only via `message.file._id`; 282 of 975 files have no referencing message (orphans, skipped).
- `rocketchat_avatars` (bare) = avatar versions with `userId`; newest `uploadedAt` per user wins (rocket.cat kept 3 versions). Avatar gridfs `_id` is a fresh ObjectId — user link only via the bare doc.
- Passwords: `services.password.bcrypt` = raw bcrypt string; TOTP: `services.totp.{enabled, secret(base32 plaintext), hashedBackup[]}`; n8n carries `services.email2fa.enabled`.
- Edits: `editedAt` set on 378 messages but `edits[]` histories are absent in this dataset (0 revisions). `mentions` = `{_id, username, name}`; reactions = `{":emoji:": {usernames[]}}`.
- Archive stream: 4-byte magic, BSON docs self-length-prefixed; collection switches via metadata docs (`db`+`collection`, no `_id`); `0xFFFFFFFF` section sentinels.