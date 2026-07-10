# Public API Assessment — can Civitai's public REST API replace the internal tRPC API?

*Research date: 2026-07-08. Civitai source at commit `411977f2` (same day). All live probes run against
production `civitai.com` with curl. No Diffusely source was modified.*

## Headline findings

1. **The stored API key is invalid, and that invalidates the premise that "API keys don't exempt" the
   tRPC gate.** `defaults read AchatesSoftware.Diffusely civitai_api_key` returns a 13-character,
   non-hex string. It fails authentication everywhere: `/api/v1/me` → 401, and
   `collection.getAllUser` with Referer + key → `UNAUTHORIZED` (auth failure, not the gate message).
   In the source, the gate commit (`60024caae2`, 2026-05-18, "gate tRPC on Origin/Referer host") *itself*
   added the Bearer exemption: `acceptableOrigin = !isProd || isBearerAuth || isAllowedOriginRequest(req)`
   (`src/server/createContext.ts:33`), where `isBearerAuth` is set whenever a Bearer token successfully
   resolves to an ApiKey row (`src/server/auth/bearer-token.ts` — plain legacy API keys qualify, not just
   OAuth tokens). The commit message is explicit: the gate is a **CSRF fix** (cookie auth), and
   "Bearer/API-key auth bypasses since it carries no cookies."
   **VERIFIED 2026-07-08 after key rotation:** with a fresh 32-char key, tRPC works with Bearer only —
   `image.getInfinite` and `collection.getAllUser` both return 200 with **no Referer header**. The
   Referer spoof is unnecessary for every request that carries the key; the "fragile spoof" concern
   shrinks to the anonymous (keyless) browsing case only. One nuance: authenticated tRPC on civitai.com
   still clamps `browsingLevel` to PG/PG-13 (items came back at level 2) — the domain cap is separate
   from the gate, and the public API remains the only uncapped path on `.com`.

2. **The public API is not gated, not meaningfully rate-limited, and — surprisingly — not NSFW-capped
   by domain.** Live: anonymous `GET /api/v1/images?browsingLevel=31` on `civitai.com` returns X/XXX
   content, while tRPC `image.getInfinite` with `browsingLevel=31` on the same domain clamps to PG even
   with Referer. Migrating image feeds to the public API would remove the need for the civitai.red
   domain toggle *for image/video feeds* (post feeds would still be tRPC and still capped).

3. **Full migration is impossible.** There is no public endpoint for posts, collections, reactions,
   votable tags, or the follow graph — confirmed by exhaustive enumeration of `src/pages/api/v1/`.
   The realistic ceiling is a hybrid.

4. **Civitai's direction of travel is friendly to credentialed third-party use.** Recent commits:
   ToS rework explicitly permitting authorized API/MCP access with your own credentials within rate
   limits (`fbc82d6a10`, 2026-06-15), OAuth server + scoped tokens (`055e54f6e6`), provenance tagging on
   API writes, new public v1 endpoints being added. Nothing suggests the public read API will be gated
   or the Bearer exemption removed.

---

## 1. Inventory — every tRPC procedure Diffusely calls

All calls are built in [CivitaiService.swift](Diffusely/Services/Networking/CivitaiService.swift).
"Decoded" lists only the fields the app actually consumes, not the full server schema.

| # | Procedure | Params sent | Fields decoded |
|---|-----------|-------------|----------------|
| 1 | `image.getInfinite` (GET) | `limit`, `sort`, `types:[image\|video]`, `period`, `browsingLevel:31`, `cursor`; plus one of `collectionId` / `tags:[Int]` / `useIndex:true`+`username?` / `postId`+`include:[]` | per item: `id`, `url` (UUID), `width`, `height`, `nsfwLevel` (Int), `type`, `postId?`, `user{id,username,image}?`, `stats{like,laugh,heart,cry,comment,collected,tipped,dislike,view — all AllTime}?`, `thumbnailUrl?`, `publishedAt?`; envelope `nextCursor` (Int\|String) |
| 2 | `post.getInfinite` (GET) | `limit`, `sort`, `period`, `browsingLevel:31`, `collectionId?`, `cursor` (Int) | per item: `id`, `nsfwLevel`, `title?`, `imageCount`, `user`, `stats{cry,like,heart,laugh,comment,dislike}?`, `images[]?` (CivitaiImage), `publishedAt?`; `nextCursor` |
| 3 | `image.getGenerationData` (GET) | `id` | `type`, `meta{prompt,negativePrompt,cfgScale,steps,sampler,seed,clipSkip}?`, `resources[{modelId,modelName,modelType,versionId,versionName,strength}]?` |
| 4 | `tag.getVotableTags` (GET) | `id`, `type:"image"` | `[{id,name,type,nsfwLevel,score}]` — app sorts Moderation-type first, then by `score` |
| 5 | `image.get` (GET) | `id` | full `CivitaiImage` — exists solely so `LibraryDateBackfillService` can recover **`publishedAt`** |
| 6 | `post.get` (GET) | `id` | `id`, `nsfwLevel`, `title?`, `user`; images fetched separately via `image.getInfinite?postId=` |
| 7 | `collection.getAllUser` (GET, auth) | `{}` or `{type:"Image"\|"Post"}` | `[{id,name,description?,type?,imageCount?,image{id,url,nsfwLevel,width,height,hash}?,user?}]` |
| 8 | `collection.getById` (GET, auth) | `id` | `collection{...}` (same fields; used to enrich `type` missing from getAllUser) |
| 9 | `collection.upsert` (POST, auth) | `name`, `type`, `description?`, `read` | `id` |
| 10 | `collection.saveItem` (POST, auth) | `type`, `collections:[{collectionId}]`, `removeFromCollectionIds`, `imageId`\|`postId` | status only (2xx check) |
| 11 | `collection.getUserCollectionItemsByItem` (GET, auth) | `type`, `contributingOnly:true`, `imageId`\|`postId` | `[{collectionId}]` |
| 12 | `user.getFollowingUsers` (GET, auth) | `{}` | `[Int]` (followed user ids) — always against civitai.com |
| 13 | `user.toggleFollow` (POST, auth) | `targetUserId` | status only |
| 14 | `user.getById` (GET) | `id` | `id`, `username?`, `image?`, `deletedAt?` |

Feeds #1/#2 run against the user-selected domain (`civitai.com` / `civitai.red`); account operations
(#12/#13/#14) are pinned to `civitai.com`. The app sends `browsingLevel:31` always and relies on the
server's per-domain cap. The app does **not** currently call `reaction.toggle` — "reactions" in this
report means the per-image/post reaction *stats* decoded from feeds.

---

## 2. Public API capability map

### The public surface (source-confirmed, `src/pages/api/v1/`)

Relevant to Diffusely: `images/` (feed/search), `users/` (lookup by ids/query), `creators`
(username+avatar list, **no user id**), `tags` (model tags, not image tags), `models`,
`model-versions/`, `me` (auth check). Everything else is models/vault/partner/App-Blocks machinery.
**There is no public endpoint — none — for posts, collections, reactions, per-image votable tags,
generation data, or the follow graph.**

### Gating, auth, rate limits (source + live)

- **Not origin-gated.** v1 handlers hardcode `acceptableOrigin: true` (`createContext.ts:106`) and set
  `Access-Control-Allow-Origin: *`. The Origin/Referer gate is tRPC-only middleware
  (`src/server/trpc.ts:60-67`), and Bearer auth bypasses it (see headline #1).
- **Auth:** optional. Anonymous works for everything Diffusely would use. Live probe: anonymous
  `browsingLevel=31` returns X/XXX items — the official docs' claim that anonymous callers are capped
  to SFW is **not enforced in production** (region-restricted regions do get clamped).
- **Rate limits:** no per-IP/per-key limiter on v1 reads. What exists: page-based pagination hard cap
  (`page × limit ≤ 1000` → 429 — use cursors); a per-pod concurrency bulkhead of 20 concurrent heavy
  requests shared with the site's own feed (overflow → 503 + `Retry-After: 2`); Cloudflare edge caching
  (`s-maxage=300`) on public endpoints. Transient search-backend overload surfaces as retryable 503.
  Diffusely's existing 429/5xx backoff classifier maps onto this cleanly.

### `GET /api/v1/images` — the workhorse (all verified live)

Params: `limit` (0–200, default 100), `cursor` **or** `page`, `sort` (all six values incl. Most
Collected / Oldest / Random — verified), `period` (Day…AllTime), `browsingLevel` (raw bits — 31 works),
`nsfw` (legacy enum), `type=image|video` (verified video), `tags=<ids,comma>` (verified), `username`
(verified), `userId`, `postId` (verified), `imageId` (verified — single-image fetch), `modelId`,
`modelVersionId`, `baseModels`, `withMeta`, `flatMeta`, `withTags`, `requiringMeta`.
**No `collectionId` — and unknown params are silently ignored** (a `collectionId=` request returns the
global feed with HTTP 200, not an error).

Pagination: `metadata.nextCursor` (opaque, e.g. `"3|1782975342327"`) plus a ready-made
`metadata.nextPage` URL. Same infinite-scroll model the app already has; cursor stays stringly-typed.

Response per item, live:

```json
{ "id": 135601530,
  "url": "https://image.civitai.com/xG1nkqKTMzGDvpLrqFT7WA/<uuid>/original=true/<uuid>.mp4",
  "hash": "U4C…", "width": 2176, "height": 3840,
  "nsfwLevel": "X", "nsfw": true, "browsingLevel": 16,
  "type": "video", "createdAt": "2026-07-03T08:47:08.469Z", "postId": 29561180,
  "stats": { "cryCount": 1, "laughCount": 3, "likeCount": 216,
             "dislikeCount": 0, "heartCount": 185, "commentCount": 1 },
  "meta": null, "username": "VersatusMaximus13",
  "baseModel": "Wan Video 2.2 I2V-A14B", "modelVersionIds": [] }
```

Schema differences that matter to Diffusely's models:

| tRPC field the app decodes | Public API equivalent |
|---|---|
| `nsfwLevel` (Int bit) | **moved**: numeric value is in `browsingLevel`; `nsfwLevel` is now a legacy *string* (`None/Soft/Mature/X`). Decoder must remap. |
| `url` (bare UUID) | full CDN URL with `original=true`. `CivitaiImage.imageUUID` already extracts UUIDs from full URLs, so workable. |
| `user {id, username, image}` | **`username` string only.** No user id, no avatar. User id is needed for follow-from-feed; avatar for feed rows. Recoverable per-user via `/api/v1/users?query=` (verified: returns `id`, `username`, `avatarUrl` UUID) at the cost of extra requests + caching. |
| `stats` (9 counts) | **6 counts** — `collectedCount`, `viewCount`, `tippedAmount` are gone. `collectedCount` is persisted by the library (`PersistedImage`); views/tips are decoded but not displayed today. Sorting *by* Most Collected still works; you just can't show the number. |
| `publishedAt` | **absent** — only `createdAt`. This is the very field `image.get` is called for (library date backfill). `createdAt` is a close-but-not-identical proxy. |
| `thumbnailUrl` (video posters) | **absent** — app already has a CDN-construction fallback, and VideoPosterProvider does its own frame extraction, so low impact. |
| `nextCursor` Int\|String | always string; opaque. Fine. |
| tRPC batch envelope | plain `{items, metadata}` — simpler, but a second decoding path. |

`withMeta=true` (verified): returns raw generation meta — `prompt`, `sampler`, `steps`, `seed`,
`cfgScale`, plus `civitaiResources: [{type, modelVersionId}]`. It does **not** resolve model/version
*names* the way `image.getGenerationData` does; names would need `/api/v1/model-versions/{id}` lookups.
`negativePrompt`/`clipSkip` appear when present in the uploader's raw meta.

`withTags=true` (verified): plain `{id, name}` — no `type`, `score`, or `nsfwLevel`, so it cannot
reproduce the votable-tags UI (which orders Moderation tags first by score).

### Docs vs reality

developer.civitai.com documents `/api/v1/images` accurately except: it claims a per-item `userId`
(absent in both live responses and today's source) and claims anonymous SFW capping (not enforced).
No numeric rate limits are published anywhere in the docs.

---

## 3. Gap matrix

| Diffusely usage | Public API? | What you'd lose / need |
|---|---|---|
| Image feeds (sort/period/browsingLevel) | ✅ **Fully replaceable** | Losses: user id+avatar (username only), collected/view/tip counts, `publishedAt`, `thumbnailUrl`; `nsfwLevel` becomes `browsingLevel`. Gain: **no PG clamp on civitai.com** — full NSFW without the .red domain toggle. |
| Video feeds | ✅ Fully replaceable | `type=video` verified. Same losses as above. |
| Tag-filtered feeds | ✅ Fully replaceable | `tags=<ids>` verified; matches the DB path the app already uses. |
| User feeds | ✅ Fully replaceable | `username=` verified (app already filters by username). |
| Single image fetch (`image.get`) | ⚠️ Partial | `imageId=` verified — but returns `createdAt`, not `publishedAt`, and the backfill exists *for* `publishedAt`. Acceptable only if a ~few-seconds-to-minutes skew is tolerable. |
| Single post fetch (`post.get` + images) | ⚠️ Partial | Images: `postId=` verified. Post `title` and a proper user object: **no public source** (title is simply lost; user/nsfwLevel derivable from items). |
| Post feeds (`post.getInfinite`) | ❌ No public equivalent | No posts endpoint at all. Post-mode browsing and post-collection sync stay on tRPC. |
| Generation data | ⚠️ Partial | `withMeta=true` gives prompt/sampler/steps/seed/cfg + resource *version ids*; resolving names needs N extra `model-versions/{id}` calls. tRPC returns it resolved in one call. |
| Votable tags | ❌ No public equivalent | `withTags` lacks `type`/`score` needed for the moderation-first ordering. |
| Collections — list, contents, create, membership, save/remove | ❌ No public equivalent | Nothing under v1; `/api/v1/images` has no `collectionId` and silently ignores it (silent-wrong-data hazard if attempted). |
| Follow graph — following list, toggle | ❌ No public equivalent | tRPC only (`user.getFollowingUsers`, `user.toggleFollow`). |
| User lookup by id (`user.getById`) | ✅ Fully replaceable | `/api/v1/users?ids=<id>` verified: `{id, username, avatarUrl (UUID), avatarNsfw}`. Construct avatar URL from UUID. |
| Reaction stats on feed items | ⚠️ Partial | 6 of 9 counts (no collected/view/tips). |
| Reaction toggling (future) | ❌ No public equivalent | tRPC `reaction.toggle` only (not currently used by the app). |

**Bottom line: roughly the anonymous *image-browsing* half of the app is publicly replaceable; the
social/authenticated half (posts, collections, follows, votable tags) is not, at any price.**

---

## 4. Recommendation

### Step 0 — fix the API key ✅ done, verified

The original key on this machine was invalid (13 chars; failed `/api/v1/me`). After rotation
(2026-07-08), verified live: tRPC `image.getInfinite` and `collection.getAllUser` return **200 with
Bearer only, no Referer**. The stale comment in `makeRequest` ("a valid API key alone is still
rejected") should be corrected when the code is next touched: the gate is CSRF protection with a
deliberate, documented Bearer bypass — an *officially tolerated* path for exactly this kind of app.

### Options

**A. Full migration — not viable.** Posts, collections, follow graph, and votable tags have no public
equivalent. Ruled out on capability, before any schema cost.

**B. Stay as-is (tRPC everywhere), authenticated via Bearer, Referer kept as fallback — recommended
baseline.** With a valid key, every request the app makes is exempt from the gate by design. Keep the
same-host Referer header too (it's free, and covers keyless users). Rework: ~zero beyond fixing the
key and comments.
*Risk:* the tRPC API remains unofficial — schemas can change without notice (mitigated by the app's
tolerant optional decoding); Civitai could someday require auth on reads or narrow the Bearer
exemption, but every recent signal (CSRF-scoped gate commit, ToS explicitly permitting credentialed
API use, OAuth investment) points the other way. The Referer spoof remains the only leg for
*keyless* users, and that leg is genuinely fragile (a switch to strict `Origin`-only checking — already
preferred over Referer in `origin-helpers.ts` — or cookie-bound checks would break it).

**C. Hybrid — move image/video/tag/user feeds + single-image + user-by-id to `/api/v1`, keep tRPC
(Bearer) for posts, collections, follows, votable tags, generation data — recommended end state.**
What it buys, concretely:
- **Removes the civitai.red toggle for image feeds** — full-range `browsingLevel` on civitai.com,
  verified live, even anonymous. (Post feeds keep the toggle.)
- Anonymous browsing no longer depends on the Referer trick for the app's primary surface.
- An officially documented, CDN-cached, CORS-open endpoint for the highest-volume traffic.

What it costs (`CivitaiService` rework, moderate):
- A second, simpler response envelope (`{items, metadata}`) alongside the tRPC one.
- A mapping layer for `CivitaiImage`: `browsingLevel`→`nsfwLevel`, full-URL handling (already exists),
  `username`→`CivitaiUser` **without id/avatar** — feed UI and follow-from-feed need a
  username→id/avatar resolution path (`/api/v1/users?query=`, cached), or those affordances degrade.
- Accept trimmed stats (drop collected/view/tip display for public-fed items; `PersistedImage.collectedCount`
  would stop updating from feeds).
- Accept `createdAt` in place of `publishedAt` where public-fed (and keep `image.get` via tRPC for the
  library backfill, which is authenticated-adjacent anyway).
- Collection *contents* sync stays tRPC (no `collectionId` on the public endpoint — and note the
  silent-ignore hazard: never pass unsupported params, you get the global feed with a 200).

**Sequencing:** do B now (it's a key rotation plus comment updates), and treat C as an incremental
follow-up driven by the product win (NSFW-on-.com, keyless robustness), not by fear of the gate — 
starting with the plain browse feeds where user-id loss matters least.

### Risk table

| Option | Main risk | Blast radius if it fires |
|---|---|---|
| Stay-as-is w/ Referer only (today) | Allowlist moves to strict Origin / cookie binding | Every request breaks at once, incl. browsing |
| B: tRPC via Bearer | Bearer exemption narrowed (no signal of this) | Falls back to Referer; same as today |
| C: hybrid | Public schema drift (versioned, documented — low) | Image feeds only; social features unaffected |

### Verification appendix (probes run 2026-07-08)

- tRPC `image.getInfinite`, no Referer, no key → **401** "Please use the public API instead"; with
  invalid key → 401; with `Referer: https://civitai.com/` → 200.
- tRPC browsingLevel=31 on civitai.com (Referer, anon) → items all `nsfwLevel: 1` (PG clamp).
- `GET /api/v1/images?browsingLevel=31&type=video&sort=Most Collected&period=Week` (anon) → 200,
  X-level video items, `nextCursor` `"3|1782975342327"`.
- `?imageId=…` → single item. `?tags=4&withTags=true` → tag-filtered, tags `[{id,name}]`.
  `?username=…` → user-filtered. `?postId=…` → 14 items for the post. All six `sort` values → 200.
  `?collectionId=123` → 200 with the **global** feed (silently ignored).
- `withMeta=true&flatMeta=true` → meta with `prompt/sampler/steps/seed/cfgScale/civitaiResources`.
- `GET /api/v1/users?ids=4` → `{id, username, avatarUrl, avatarNsfw}`.
- `GET /api/v1/me` with the originally stored key → **401** (key invalid; 13 chars, non-hex).
- **After key rotation (same day):** `/api/v1/me` → 200; tRPC `image.getInfinite` Bearer-only,
  no Referer → 200 (items clamped to level 2 on civitai.com); `collection.getAllUser` Bearer-only,
  no Referer → 200 (5 collections). Bearer exemption confirmed in production.
