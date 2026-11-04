# GuildRecruiter for WoW: Forever — user requirements document

Status: DRAFT, 2026-11-04. Branch: `forever`.
Base: `main` at 0b77160 (v3.21). The uncommitted v3.22 edits (name-corpus
`dataset` + `/gr dataset`) live only on the Octowow / F: disk copies and are NOT
in this repo yet; see "Open decisions".

## 1. Goal

A version of Guild Rawcruiter that loads and works on the WoW: Forever client,
with the same user-facing behaviour as the vanilla 1.12 / Turtle WoW build:
paced `/who` sweeps of guildless players, then invite and/or whisper contact,
with stats, profiles, A/B variants and guild sync.

Non-goal: changing recruiting behaviour. A port, not a redesign. The 1.12 build
stays on `main` and keeps working; Forever is a separate target.

## 2. Platform facts (from community sources, checked 2026-11-04)

Sources: wowforeverguides.com/addons/developers (checked Sep 28, updated Oct 13,
2026), kami-labs.fr/en/addons-wow-forever, warcraft.wiki.gg TOC format.
These are beta-era fan pages, NOT Blizzard documentation. Re-verify in game.

| Fact | Detail |
|---|---|
| Interface number | `## Interface: 16001` for Forever (Classic Era is 11509) |
| Client family | Midnight/Retail-style client; Classic addons do not load as-is |
| API surface | Blizzard reportedly: shares Mainline UI architecture, most 12.1.5 APIs |
| Lua | modified Lua 5.1; `goto`, `//`, bitwise ops, `_ENV` banned; no file I/O |
| TOC naming | folder name must equal TOC file name; per-client suffix e.g. `_Camelot.toc` |
| Beta install path | `World of Warcraft\_classic_beta_\Interface\AddOns\<Name>\` (may change) |
| Removed globals (seen) | `GetSpellInfo`, `GetItemInfo` etc. -> `C_Spell.*`, `C_Item.*` |
| Event handlers | `function(self, event, ...)`; guides never use `this` / `arg1` |
| Taint | combat lockdown; blocked protected calls can fail with NO Lua error, `pcall` won't catch |
| Secret values | some unit data may be secret; guard with `issecretvalue`. Unknown for /who rows |
| Combat log | closed to addons (GuildRecruiter does not use it) |
| `WOW_PROJECT_ID` | 1 on one beta build, 18 on another: do not branch on it |
| SavedVariables | reported not restored on an early beta build; reportedly fixed later |

## 3. Unverified — must be settled before porting (blockers)

None of the sources cover these. Each needs the wiki pages
(Patch_12.0.0/API_changes, Secret_Values) or an in-game probe.

1. Does `SendWho` / `C_FriendList.SendWho` exist, and what are its throttle and
   hardware-event rules? Same for `GetNumWhoResults` / `GetWhoInfo`
   (`C_FriendList.GetWhoInfo` returns a table on Mainline) and `SetWhoToUI`.
2. Are `GuildInvite` / `GuildInviteByName` (`C_GuildInfo.Invite` on Mainline)
   callable from addon code, and do they need a hardware event?
3. Is `SendChatMessage(..., "WHISPER", ...)` (`C_ChatInfo.SendChatMessage`)
   unrestricted for addon-initiated whispers?
4. Are `/who` result fields (name, guild, level, class) secret values?
5. Do `string.gfind`, `table.getn`, `getglobal/setglobal` and `SetBackdrop`
   (needs `BackdropTemplate` on Mainline) exist?
6. What exact chat strings does the Forever server emit for guild join/decline,
   throttle ("too many / too quickly") and who results (`CHAT_MSG_SYSTEM`)?

In-game probe (needs the client):
`/dump select(4, GetBuildInfo())` then
`/run print(C_FriendList and C_FriendList.SendWho, SendWho, GuildInvite, C_GuildInfo and C_GuildInfo.Invite, string.gfind, table.getn, BackdropTemplateMixin)`

## 4. Functional requirements

Keep everything in the current feature set unless a blocker above forbids it.
Priority: P0 loads and sweeps; P1 contacts; P2 the rest.

| ID | Pri | Requirement |
|---|---|---|
| F1 | P0 | Loads with no Lua error on the Forever client; TOC `## Interface: 16001`, SavedVariables `GuildRecruiter_Settings` unchanged so settings carry over |
| F2 | P0 | `/gr` slash commands and the minimap button work |
| F3 | P0 | Settings / Lists / Stats window opens, all tabs, no taint |
| F4 | P0 | `/who` sweep: level-band widen/narrow, class split, cap detection (~49), pacing, timeout/retry |
| F5 | P1 | Contact modes `invite`, `whisper`, `whisperinvite` with reply policy `notno`/`yesonly`/`any` and editable yes/no word lists |
| F6 | P1 | Only contact guildless players; re-invite cooldown; blacklist; class filter; level range; session cap |
| F7 | P1 | Safety options: jitter, auto-backoff on throttle message, pause in combat / instances |
| F8 | P2 | Stats (invited/whispered/joined/declined, per-day) from join/decline messages |
| F9 | P2 | Profiles, A/B variants B/C/D |
| F10 | P2 | Guild sync (dedup + sweep split) over addon messages (`C_ChatInfo.SendAddonMessage` on Mainline) |
| F11 | P2 | Auto-scan loop with rest between sweeps |
| F12 | P3 | Name-corpus `dataset` + `/gr dataset` (v3.22), if adopted |

Dropped or changed because the platform differs: "faction-locked /who" and
"invite API auto-detect" text in the README must be re-derived from the probe.

## 5. Port work, sized from the 1.12 source (2658 lines)

Counts of lines using each old-style construct in `GuildRecruiter.lua`:

| Construct | Lines | Port direction |
|---|---|---|
| `table.getn` / `getn` | 54 | `#t` |
| `this` / `this:` | 29 | `self` / explicit frame upvalue |
| `arg1`… in handlers | 14 | handler parameters / varargs |
| `OnUpdate` timers | 17 | keep, or `C_Timer.After` where event-free |
| `SetBackdrop` | 5 | `BackdropTemplate` |
| `GuildInvite*` | 19 | `C_GuildInfo.Invite` (verify, blocker 2) |
| `SendWho`/`GetWhoInfo`/`GetNumWhoResults` | 3 | `C_FriendList.*` (verify, blocker 1) |
| `SetWhoToUI` | 4 | verify it exists |
| `string.gfind` | 1 | `string.gmatch` |
| `CreateFrame` | 55 | add `BackdropTemplate` where a backdrop is used |
| `FriendsFrame` refs | 5 | re-check Who UI frame names |
| `getglobal/setglobal` | 4 | `_G[...]` |
| `CHAT_MSG_SYSTEM` | 4 | re-check wording (blocker 6) |

## 6. Non-functional requirements

- N1. No taint and no "Interface action failed because of an AddOn" counter
  increments during normal use (check after a run, restart rather than /reload).
- N2. One codebase if practical: shared logic, thin compatibility layer
  (`GR.compat`) for who/invite/whisper/timer/backdrop calls, selected by
  feature detection (`if C_FriendList then`), NOT by `WOW_PROJECT_ID`.
- N3. SavedVariables survive logout and restart (retest; early beta bug).
- N4. A runtime error stops the run cleanly with "Stopped on error" (existing).
- N5. Default contact mode on first run stays the least intrusive one
  available (whisper); blind mass invites remain opt-in, as the README warns
  they break many servers' rules. Check WoW: Forever's policy before enabling.
- N6. Retest everything per beta/live build and record the build number
  (`1.60.1.70338` was the last seen on the guide).

## 7. Acceptance criteria

1. Fresh install on Forever: no Lua errors on login, `/gr config` opens.
2. `/gr start` sweeps at least one level band, prints counts, respects pacing.
3. `whisper` mode whispers one guildless test target; `invite` mode invites one.
4. A completed run leaves the "action failed" counter unchanged.
5. Settings persist across logout and a full client restart.
6. `main` (1.12 build) still passes the same manual run.

## 8. Open decisions

1. Do the uncommitted v3.22 edits (dataset collector) go in? Recommend: commit
   them to `main` first (LF line endings; the disk copies are CRLF), then branch.
2. Single codebase with a compat layer, or a separate Forever file set?
   Recommend: compat layer if blockers 1–3 turn out to match Mainline.
3. Is the live Forever build different from the beta the guides describe?
   Launch was announced for Nov 4, 2026, so re-check before trusting section 2.
