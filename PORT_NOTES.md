# GuildRecruiter: WoW: Forever port notes

Version `4.0.0-forever.1`, branch `forever`, based on `1023a66` (the v3.22 source
plus REQUIREMENTS.md). Status: **ported and checked offline only. Not run on a
Forever client.** The port is committed locally as `e824243`. The key-press
mode (§1.9) sits on top of it and is **not committed**.

Port (`e824243` vs `1023a66`, `git diff --numstat`): GuildRecruiter.lua +526 / -252,
GuildRecruiter.toc +3 / -3, README.txt +42 / -0.
Key-press mode (working tree vs `e824243`): GuildRecruiter.lua +453 / -93,
README.txt +44 / -7, PORT_NOTES.md, and a new Bindings.xml (9 lines). The .toc is
unchanged: the client loads Bindings.xml by itself. All files are LF with no CR
bytes, and GuildRecruiter.lua is still pure ASCII.

Line counts below are lines of the 1.12 source (HEAD), counted with a tokenizer, so
words in comments and strings are not counted.

## 1. Changes by category

### 1.1 Lua 5.0 to Lua 5.1 language

| Change | Lines | Notes |
|---|---|---|
| `table.getn(x)` to `#x` | 54 lines (55 calls) | Every operand is a table: NEGATIVES, AFFIRM_DEFAULTS, abVariants, the queues, the option-order lists, and so on. One needed parentheses: `#(s.abVariants or {})`. No `n` field is used anywhere, so 5.0 `getn` and 5.1 `#` give the same result. |
| `for k in tbl do` to `for k in pairs(tbl) do` | 25 lines | **Not in REQUIREMENTS §5.** Lua 5.0 let you iterate a table directly. In 5.1 this is a runtime error ("attempt to call a table value"), so every one of these loops would have broken: history pruning, reply judging, lists, stats, profiles, tabs and slash listings. The iteration order (`next`) is unchanged. |
| `string.gfind` to `string.gmatch` | 1 line | `/gr class` parsing. |
| Main-chunk `...` | 1 new line | `local ADDON_NAME = (...) or "GuildRecruiter"`. Used by the ADDON_LOADED check. |

### 1.2 Handler model: the `this`, `event` and `argN` globals become parameters

| Change | Lines | Notes |
|---|---|---|
| `this` to `self` or an explicit parameter | 41 lines with `this` as code; 29 of them `this.`/`this:` | The extra 12 pass `this` as an argument (`OpenDD(this, ...)`, `WeightTip(this)`) or assign it (the old `RunChatCommand`, which wrote the global `this`). |
| `arg1`, `arg2`, `arg4` to handler parameters | 17 lines | OnClick `(self, button)`, OnUpdate `(self, elapsed)`, OnEvent `(self, event, ...)`. |
| `event` global to a parameter | 7 lines | `GR_OnEvent(event, ...)`. The dispatcher is `function(self, event, ...) pcall(GR_OnEvent, event, ...)`. |
| SetScript handler signatures | 40 handlers | OnClick `(self)` x10 and `(self, button)` x4; OnUpdate `(self, elapsed)` x5 and `(btn, elapsed)` x1; OnEnter x4; OnEnterPressed x3; OnEscapePressed x4; OnDragStart/OnDragStop x4; OnLeave, OnTextChanged, OnValueChanged, OnVerticalScroll and OnEvent x1 each. The remaining 26 handlers have no parameters because they use none (checked, see §3). |
| `OnAddonMessage()` to `OnAddonMessage(prefix, text, channel, sender)` | 1 | CHAT_MSG_ADDON payload order. |
| `GR_OnUpdate()` to `GR_OnUpdate(e)` | 2 | `e` is the elapsed time; 1.12 read it from `arg1`. |
| `getglobal(name.."Text")` to `GR_Compat.SetChildText` | 4 lines | Uses `_G[...]` and falls back to the template's parentKey (`.Text`, `.Low`, `.High`, `.text`). nil-safe. No `setglobal` existed. |

### 1.3 Widget and FrameXML API

| Change | Lines | Notes |
|---|---|---|
| Backdrop frames | 9 lines | 4 `CreateFrame` calls to `GR_Compat.BackdropFrame` (adds `BackdropTemplate` when `BackdropTemplateMixin` exists), 4 `:SetBackdrop` to `GR_Compat.SetBackdrop`, 1 `:SetBackdropColor` to `GR_Compat.SetBackdropColor`. Without the template the frame is still built, just without a border. |
| `Texture:SetTexture(r,g,b,a)` to `GR_Compat.ColorTexture` | 2 lines | Section-header underline and progress-bar background. Uses `SetColorTexture` when present (7.0+). |
| `EditBox:SetFont(path, 12)` to `SetFont(path, 12, "")` | 1 line | Wiki: since 10.0.0 `flags` is no longer optional except on FontStrings. The message editor is an EditBox, so the 2-argument call would error. |
| FauxScrollFrame (Lists tab) | 4 lines | Create, OnVerticalScroll, GetOffset and Update now go through `GR_Compat.FauxScrollFrame/FauxScrollOnVertical/FauxScrollOffset/FauxScrollUpdate`. Mainline signature: `(self, offset, itemHeight, fn)`. The template was deprecated in 10.1.0 ("will be removed in a future patch"). If it is missing, the list builds unscrolled and shows only the first 13 rows. |
| `OptionsSliderTemplate` | 1 line | Goes through `GR_Compat.TemplateFrame`; the template was deprecated in 10.0.0. If it is missing, the slider is created without the template: it has no thumb and no caption. The numeric box next to it still sets the same value. |

### 1.4 Who, invite, whisper, sync and chat call sites moved into GR_Compat

| Old call site (1.12) | Lines | Now |
|---|---|---|
| `SendWho(filter)` | 1 | `GR_Compat.SendWho` |
| `GetNumWhoResults()` | 1 | `GR_Compat.GetNumWhoResults` |
| `GetWhoInfo(i)` | 1 | `GR_Compat.GetWhoRow` |
| `pcall(SetWhoToUI, 0/1)` | 4 | `GR_Compat.SetWhoToUI(false/true)` (Abort, Drain end, ForceWhoToEvent, RestoreWho) |
| `FriendsFrame` (who-window suppression and hide) | 4 lines / 5 refs | `GR_Compat.WhoPanel()` |
| `DoGuildInvite` body + `RunChatCommand` | 16 + 16 | `GR_Compat.GuildInvite` / `GR_Compat.RunSlash`. `DoGuildInvite` is now a one-line wrapper. |
| `SendChatMessage(..., "WHISPER", ...)` | 2 | `GR_Compat.SendWhisper` |
| `SendAddonMessage(...)` | 1 | `GR_Compat.SendAddonMessage`, plus a new `GR_Compat.RegisterAddonPrefix(SYNC_PREFIX)` at load |
| `CanGuildInvite()` | 1 | `GR_Compat.CanGuildInvite` |
| Wrapping `ChatFrame_OnEvent` (quiet /who) | 18 | `GR_Compat.FilterSystemChat(fn)` (message-filter API) + `GR_Compat.IsWhoNoise` |
| Throttle string test | 2 | `GR_Compat.IsThrottleMsg` |
| Load message "Invite API: ..." | 4 | `GR_Compat.ApiSummary()`. Now names all three calls, e.g. `Invite API: C_GuildInfo.Invite (who: C_FriendList.SendWho, whisper: C_ChatInfo.SendChatMessage)` |

### 1.5 Event plumbing, names, secret values

| Change | Lines | Notes |
|---|---|---|
| Init on `ADDON_LOADED` (our folder name), `VARIABLES_LOADED` kept as fallback, run once | 5 | Mainline's documented point where SavedVariables are loaded. |
| `GR_Compat.ShortName` (Ambiguate "none") on the /who name, the whisper sender and the addon-message sender | 3 sites | Mainline sends "Name-Realm" in CHAT_MSG_WHISPER and CHAT_MSG_ADDON. Without this, the own-echo check fails (every recruiter would count itself twice in the band split), and replies never match the `whispered[name]` key. |
| Secret-value guards | 3 event sites + 6 inside GR_Compat | CHAT_MSG_SYSTEM, CHAT_MSG_WHISPER and CHAT_MSG_ADDON return early on a secret argument. Inside the layer: GetWhoRow (a secret name or guild skips the row; any other secret field reads as nil), GetNumWhoResults (secret or nil counts as 0), IsWhoNoise, FilterSystemChat, ShortName. `local issecret = issecretvalue or function() return false end`. |

### 1.6 Version and metadata

- `VERSION = "4.0.0-forever.1"`, and the header comment says it is the Forever port (3 lines).
- TOC: `## Interface: 16001`, `## Version: 4.0.0-forever.1`, and Notes now say "WoW: Forever port, beta". Title, SavedVariables (`GuildRecruiter_Settings`), file list and folder name are unchanged.
- README.txt: new "WoW: FOREVER BUILD" section at the top, including the REQUIREMENTS §3 probe. The 1.12 text is unchanged.

### 1.7 The compat layer itself

GuildRecruiter.lua lines 25 and 27-321: `ADDON_NAME`, a banner comment, and `GR_Compat`, which has 28 functions plus the local `HasTemplate`. Every choice is made by feature detection when the function is called (`if C_FriendList and C_FriendList.SendWho then ... elseif type(SendWho) == "function" then ...`). Nothing branches on `WOW_PROJECT_ID` or a build number.

| Function | Modern API (tried first) | Fallback |
|---|---|---|
| SendWho | `C_FriendList.SendWho(filter, Enum.SocialWhoOrigin.Social)` | `SendWho(filter)`, else `error()` |
| GetNumWhoResults | `C_FriendList.GetNumWhoResults()` | `GetNumWhoResults()`, else `error()` |
| GetWhoRow | `C_FriendList.GetWhoInfo(i)`: table fullName/fullGuildName/level/raceStr/classStr/area, mapped to the 1.12 order | `GetWhoInfo(i)`, else `error()` |
| SetWhoToUI | `C_FriendList.SetWhoToUi(bool)` | `SetWhoToUI(1/0)`; both under `pcall` as before |
| WhoPanel | — | `FriendsFrame` |
| GuildInvite | `C_GuildInfo.Invite(name)` for "auto", or when the chosen method's function is missing | `GuildInviteByName`, `GuildInvite`, then `/ginvite` (the 1.12 order) |
| InviteApiName / ApiSummary | names the call actually in use | — |
| CanGuildInvite | `CanGuildInvite()` | no API = allowed (as in 1.12) |
| RunSlash | `ChatEdit_SendText(eb, 0)` | the edit box's own OnEnterPressed handler, called with `eb` |
| SendWhisper | `C_ChatInfo.SendChatMessage(text, "WHISPER", nil, target)` | `SendChatMessage`, else `error()` |
| RegisterAddonPrefix | `C_ChatInfo.RegisterAddonMessagePrefix` | `RegisterAddonMessagePrefix`, else nothing (1.12 needs no registration) |
| SendAddonMessage | `C_ChatInfo.SendAddonMessage` | `SendAddonMessage`, else `error()` |
| IsWhoNoise / IsThrottleMsg | — | the 1.12 enUS strings, verbatim |
| FilterSystemChat | `ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", ...)` | wrap `ChatFrame_OnEvent` with the `(self, event, ...)` signature |
| BackdropFrame / SetBackdrop / SetBackdropColor | `BackdropTemplate` | a plain frame; the call is skipped if the method is missing |
| ColorTexture | `SetColorTexture` | `SetTexture(r,g,b,a)` |
| TemplateFrame (+ HasTemplate) | `C_XMLUtil.GetTemplateInfo(t) ~= nil` | create without the template |
| FauxScrollFrame / FauxScrollOffset / FauxScrollUpdate / FauxScrollOnVertical | the FrameXML FauxScrollFrame_* functions | unscrolled list (offset 0, Update does nothing) |
| SetChildText | `_G[name..suffix]` | parentKey `.Text` / `.text` |
| IsSecret / ShortName | `issecretvalue`, `issecrettable`, `Ambiguate(name, "none")` | always false / name unchanged |

When neither the modern nor the old API exists, the function raises an `error()`. That reaches the existing `pcall`, so the run stops with "Stopped on error: no /who API on this client ...". In 1.12 the same case gave a bare "attempt to call a nil value".

**Timers:** there is no timer compat function. The 1.12 source calls no timer API: all pacing runs off the one OnUpdate loop (`elapsed`) plus `GetTime()`, and both work the same on Mainline. REQUIREMENTS §5 says "keep" for the OnUpdate timers. Wrapping `C_Timer.After` would have meant adding a function nothing calls.

### 1.8 Behaviour differences you can see (all deliberate, all small)

- The load line names the who and whisper calls as well as the invite call.
- A secret /who row or chat message is skipped silently.
- A nil or secret /who count is treated as 0 rows instead of raising an error.
- A CHAT_MSG_ADDON with no sender is ignored. In 1.12 a "HI" with no sender raised "table index is nil".
- A missing core API gives a named error instead of "attempt to call a nil value".
- Pacing, defaults, saved-variable names, slash commands, the sweep algorithm, the A/B logic and the message formats are unchanged.

### 1.9 Key-press mode: one /who or one invite per hardware event

The wiki marks `C_FriendList.SendWho` and `C_GuildInfo.Invite` `#hwevent`, and the
community Forever recruiters (Olympus Forever Guild Recruiter, ForeverRecruiter,
Fast Guild Invite, GRIP) all send one /who or one invite per key press or click.
The 1.12 run loop sent both from the OnUpdate timer, so it now waits for a press.

**The switch.** `GR_Compat.RequiresHardwareEvent`, set once at load by feature
detection: `true` when `C_FriendList and C_FriendList.SendWho` exists. When it is
`false` (a client with only the old globals) every code path below is the 1.12
one, step for step. This was not too invasive: the 1.12 branches are the old
code moved into functions, and the new branches sit next to them.

**What a press does** (`GuildRecruiter_NextStep` decides, `GuildRecruiter_NextPress` acts):
at most one restricted call, in this order:
1. the ready-to-invite list (`replyQueue`: whisper replies that passed the reply
   rule) -> `C_GuildInfo.Invite`;
2. the head of the contact queue, if its contact is not a plain whisper ->
   `C_GuildInfo.Invite` (invite mode, Invite all), or the first whisper of
   whisper-then-invite mode;
3. otherwise the next /who of the sweep -> `C_FriendList.SendWho`.

If the step's gap has not run out yet (invite delay or /who delay, each with
jitter if on; server-throttle backoff; the /who reply still awaited), the press
fires nothing and chat says `Next: wait Ns (...)`. Contacts held by combat or an
instance do not hold the /who, as in 1.12, where only the throttle backoff held
the sweep.

**Entry points** (all key or click handlers, all calling `GuildRecruiter_Next()`):
- the key binding `GUILDRECRUITER_NEXT` in **Bindings.xml** (header
  `GUILDRECRUITER`; labels from the globals `BINDING_HEADER_GUILDRECRUITER` =
  "Guild Rawcruiter" and `BINDING_NAME_GUILDRECRUITER_NEXT` = "Next: send one /who
  or one invite", set in GuildRecruiter.lua). No default key; fires on key down;
- the floating **Next** button (`GuildRecruiterNextButton`), anchored under the
  minimap button, shown while a run is armed; it hides itself when the run ends;
- a **Next (N)** button on the Lists-tab run strip, left of Stop;
- `/gr next` (typed, or from a macro).

`GuildRecruiter_Next` -> `GR_Compat.Press(GuildRecruiter_NextPress)` -> `pcall` ->
the restricted call. Everything runs in the same call stack: no `C_Timer`, no
OnUpdate hop, no coroutine. `pcall` is a synchronous call. It is there so that an
error still ends in "Stopped on error" and the press flag is always cleared.

**What the timer still does:** /who timeout and retry (`WHO_TIMEOUT`,
`WHO_RETRIES`), reading /who results, judging whisper replies, auto-backoff,
whispers in `whisper` mode (`GR_Compat.TimerContactModes = { whisper = true }`),
the session cap, the auto-rescan rest, ending a swept band (`FinishSweep`, which
sends no /who), and ending the run. It never calls SendWho or an invite.

**Gate.** `GR_Compat.SendWho` and `GR_Compat.GuildInvite` (every invite method,
including `/ginvite` typed from code) call `GR_Compat.CheckPress(label)` first.
In key-press mode, reaching them outside a `GR_Compat.Press` raises an error, so
the run stops with "Stopped on error: C_FriendList.SendWho needs a key press or
click ... reached from a timer or event". That replaces a silent client block.
`GuildRecruiter_InviteOne` (left-click on a candidate, `/gr invite <name>`)
wraps its single invite in `GR_Compat.Press` too.

**Detect and degrade.** `GR_Compat.WatchBlocked(f)` registers
`ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN` (under `pcall`). When one names
this addon (`GR_Compat.BlockedLine`, payload `(addonName, function)`), the run
pauses quietly and prints one line, e.g. `The client blocked C_FriendList.SendWho()
(ADDON_ACTION_BLOCKED); our last restricted call was C_FriendList.SendWho 0.0s ago
-- run paused (/gr resume to try again, /gr stop to end).` The same applies on
a timer-loop client.

**Behaviour the player will notice (key-press mode only):**
- `/gr start` (and minimap right-click) says "Armed (...)" and how to press Next;
  it sends nothing.
- A yes-reply prints "<name> replied -- ready to invite (N waiting). Press Next."
  It is never invited from the CHAT_MSG_WHISPER handler. The button shows `[N]`.
- The button text shows the next step and its gap: "Next: send /who",
  "/who ready in 2s", "Invite Bob", "Whisper ready in 1s", "Waiting for /who",
  "Rescan in 40s", "Held: in combat".
- Contacts made by a press end with " -- N queued" / " -- N more ready to invite".
  On Invite all / Send they end with " -- N left, click again" / " -- that was the last one".
- Lists tab: the Invite-all confirm text says each click on Next sends one invite.
- Auto-rescan: each new sweep prints "sweep N ... is ready -- press Next to start it".
- `/gr status` adds a "Next: ..." line; `/gr help` lists `next`; the load line ends
  with "Key-press mode: ...". The minimap tooltip shows the next step.
- In `whisperinvite` mode every first whisper costs a press (the design said the
  timer may whisper in `whisper` mode). To let the timer send those as well, add
  `whisperinvite = true` to `GR_Compat.TimerContactModes`. The reply invite still
  needs a press either way.

**Small internal changes that also touch the timer-loop path, same behaviour:**
- `Contact(name, v)` now takes the A/B variant. `GuildRecruiter_DealHead` deals it
  once per queue head and remembers it, so the button can say "Invite" or
  "Whisper" before the press. On the timer path it deals at contact time, as
  `PickVariant` inside `Contact` did. Invite all still deals nothing. In key-press
  mode the deal happens when a name reaches the head of the queue, so an A/B edit
  made while that name waits there does not change its deal.
- `SendNextWho` is split into `FinishSweep` (band done, no /who) and the send.
  `NextQuery(peek)` can answer "is a slice left?" without moving the cursor.
- `SendsBlocked()` returns the reason string ("in combat", ...) instead of `true`.
- `Pause(quiet)`: the quiet form is used only by the block report.
- `GR_Compat.GuildInvite` resolves the call through `GR_Compat.ResolveInvite`
  (the same fallback order as before), so the gate can name it.
- An error inside `/gr invite` / candidate left-click is re-raised after the press
  flag is cleared.

## 2. Still unverified

There was no game client and no Lua interpreter. Everything below is untested.
Wiki facts come from the pages listed in §4. The wiki is fan-maintained, and its
per-function flavour tables say an API *exists* on Forever 1.60.1 (build 69913).
They do not say a restriction applies per flavour.

| # | Blocker (REQUIREMENTS §3) | Isolated in | What the wiki says / what is still open |
|---|---|---|---|
| 1 | Do SendWho / C_FriendList.SendWho, GetNumWhoResults / GetWhoInfo and SetWhoToUI exist, and what are their throttle and hardware-event rules? | `GR_Compat.SendWho` (gated by `GR_Compat.CheckPress`), `GR_Compat.GetNumWhoResults`, `GR_Compat.GetWhoRow`, `GR_Compat.SetWhoToUI` (+ `GR_Compat.WhoPanel`); mode switch `GR_Compat.RequiresHardwareEvent` | All four `C_FriendList` calls are listed for Forever 1.60.1. **SendWho is marked `#hwevent` (needs a key or mouse press, since 8.2.5)** and is throttled server-side ("queries are not guaranteed to generate a response"). **Handled by key-press mode (§1.9): one /who per press.** Still open: whether Forever actually enforces `#hwevent` here, and what a violation does (the wiki page doesn't say whether it errors, fails silently or fires ADDON_ACTION_BLOCKED; a silent drop would show up as a /who timeout and retry). The origin argument was added in 10.2.0; the code passes `Enum.SocialWhoOrigin.Social` (1), which is my choice and unverified. The wiki says GetNumWhoResults "never seem[s] to go over 50". SetWhoToUi(true) sends every reply to WHO_LIST_UPDATE and FriendsFrame. Whether FriendsFrame is the frame that registers WHO_LIST_UPDATE on Forever (needed for Who-window suppression) is unknown. |
| 2 | Are GuildInvite / GuildInviteByName / C_GuildInfo.Invite callable from addon code, and do they need a hardware event? | `GR_Compat.GuildInvite` (gated by `GR_Compat.CheckPress`), `GR_Compat.ResolveInvite`, `GR_Compat.CanGuildInvite`, `GR_Compat.RunSlash` (method "chat"), `GR_Compat.InviteApiName` | `C_GuildInfo.Invite(name)` is listed for Forever 1.60.1 and **marked `#hwevent`**. **Handled by key-press mode (§1.9): one invite per press, including reply invites, Invite all and Send.** Still open: whether a key binding, a typed `/gr next` and a plain `UIPanelButtonTemplate` click all count as the hardware event (they do on Mainline as far as I know, and the community recruiters work per key press, but I have not seen it on Forever). Also open: whether the "chat" method (`/ginvite` sent from code) works at all. Whether `CanGuildInvite` still exists on Forever is unknown (the call is feature-detected; if it's missing, invites are allowed, as in 1.12). |
| 3 | Is a WHISPER via SendChatMessage / C_ChatInfo.SendChatMessage unrestricted for addon code? | `GR_Compat.SendWhisper` | The wiki marks only SAY, YELL and CHANNEL as hardware-event; WHISPER is not. The global `SendChatMessage` was deprecated in 11.2.0, and the 11.2.0 change list shows it as removed. `C_ChatInfo.SendChatMessage` is listed for Forever. The Forever 1.60.1 changes add a hardware-event requirement for EMOTE only (not used here). Behaviour under "chat messaging lockdown" (encounters, challenge mode, PvP) is unknown; the default "pause in instances" setting avoids most of it. Key-press mode relies on this row: `whisper`-mode contacts still go out from the timer (`GR_Compat.TimerContactModes`). If WHISPER turns out to need a press too, set that table to `{}` and every contact will wait for Next. |
| 4 | Are /who result fields secret values? | `GR_Compat.IsSecret`, `GR_Compat.GetWhoRow`, `GR_Compat.GetNumWhoResults` (also used by the guards in `GR_OnEvent` and `OnAddonMessage`, and by `GR_Compat.FilterSystemChat` and `GR_Compat.IsWhoNoise`) | The Secret_Values page does not mention /who or guild data. UnitName is secret only for non-player units in combat. Chat events can carry secrets while SecretInChatMessagingLockdown is active. The 1.60.1 notes say Midnight's addon restrictions, including secrets, apply on Forever. If /who levels did come back secret, every reply would look "foreign" (0 rows in band), and the sweep would run on timeouts and retries, finding nobody. |
| 5 | Do `string.gfind`, `table.getn`, `getglobal`/`setglobal` and `SetBackdrop` exist? | **No longer needed:** the port uses only Lua 5.1 natives (`#`, `string.gmatch`, `_G`, `pairs`, `select`). SetBackdrop goes through `GR_Compat.BackdropFrame` / `SetBackdrop` / `SetBackdropColor` | Still open: whether Forever's "modified Lua 5.1" keeps the standard 5.1 core. The fan sources list only `goto`, `//`, bitwise operators and `_ENV` as banned. The same question applies to the deprecated templates (`GR_Compat.TemplateFrame`, `GR_Compat.FauxScroll*`) and to `SetColorTexture` (`GR_Compat.ColorTexture`). |
| 6 | What exact chat strings does the Forever server send for guild join/decline, throttling and who results (CHAT_MSG_SYSTEM)? | `GR_Compat.IsThrottleMsg`, `GR_Compat.IsWhoNoise`. Join/decline stays where it was (`ToPattern`, `JOIN_PAT`/`DECLINE_PAT`), because it is already built from the client's own `ERR_GUILD_JOIN_S` / `ERR_GUILD_DECLINE_S` strings with an enUS fallback. | Nothing found on the wiki. Unknown: the wording of Forever's throttle message, and whether names in system messages are hyperlinked (`|Hplayer:...|h`) or plain. |

In-game probe (from REQUIREMENTS §3, also in README.txt):

```
/dump select(4, GetBuildInfo())
/run print(C_FriendList and C_FriendList.SendWho, SendWho, GuildInvite, C_GuildInfo and C_GuildInfo.Invite, string.gfind, table.getn, BackdropTemplateMixin)
```

The addon's own load line then shows which invite, /who and whisper calls GR_Compat picked.

### 2.1 Other unverified assumptions (outside the six blockers)

- **Events:** ADDON_LOADED's first argument is the folder name ("GuildRecruiter"), and VARIABLES_LOADED still fires. Unknown events make `RegisterEvent` error on Mainline. All eight registered events exist on Mainline 12.x as far as I know, but I have not checked them against a Forever event list.
- **Sender format:** that CHAT_MSG_WHISPER and CHAT_MSG_ADDON carry "Name-Realm", and the /who `fullName` carries "Name" or "Name-Realm". Ambiguate itself is listed for Forever 1.60.1, and its "none" context strips the realm for same-realm players.
- **`ChatFrame_AddMessageEventFilter`** on Forever: its wiki page lists no flavours. `ChatEdit_SendText` and `DEFAULT_CHAT_FRAME.editBox` have not been checked either.
- **Templates:** InputBoxTemplate, UICheckButtonTemplate (and its `$parentText`/`.text` caption), UIPanelButtonTemplate and UIPanelCloseButton are used directly. They are core Mainline templates and none is marked deprecated. OptionsSliderTemplate's children (`$parentText/Low/High` or `.Text/.Low/.High`) are unverified.
- **Lua environment globals** I assumed exist as in Mainline: `random`, `tinsert`, `tremove`, `date`, `time`, `math.atan2`, `HideUIPanel`, `IsInInstance`, `UnitFactionGroup`, `GetGuildInfo`, `StaticPopup_Show`, `UISpecialFrames`, `GetCursorPosition`.
- **Addon messages:** per the wiki, Forever trial and Veteran accounts cannot send addon messages, so guild sync fails silently for them. The per-prefix throttle is 10 messages, refilling at 1 per second. The result code is ignored, as before.
- **Game data left unchanged** (per "no behaviour change"): the hard-coded class lists per faction (`FactionLists`: no Horde paladins, no Alliance shamans) and the 1-60 level range. These are vanilla values; if Forever differs, they need updating.
- **Defaults:** the code's default contact mode is `invite`, but REQUIREMENTS N5 asks for `whisper` on first run. Left unchanged because the task said not to change defaults; this needs a decision.
- `METHOD_SHORT` still says "GuildInviteByName"/"GuildInvite". These are labels in a table nothing reads, so I left them.

### 2.2 Key-press mode: unverified (no client)

- **Hardware context through `pcall`:** I assume the client's "this script runs for
  a hardware event" state covers the whole synchronous call, including the
  `pcall` inside `GR_Compat.Press`. That is how Mainline works as far as I know.
  If it is wrong, every press is blocked; the block report (or a /who timeout)
  would show it at once.
- **Typed slash commands** (`/gr next`, `/gr invite`) run inside the Enter-key
  press. Same assumption.
- **ADDON_ACTION_BLOCKED / _FORBIDDEN:** the payload is `(addonName, function)`
  and both are synchronous (wiki; both are listed for Forever 1.60.1). It is
  unknown whether a `#hwevent` violation fires either of them, and in what
  format the `function` string comes (the example line in §1.9 is illustrative).
  The handler compares the first argument with the addon's folder name.
- **Bindings.xml:** the wiki documents `name`, `header`, `runOnUp` and `default`
  (no `category`). Where the entry shows up in Forever's Key Bindings window
  (an "AddOns" group or a "Guild Rawcruiter" header) is unverified. No default
  key is set, so nothing collides.
- **`GetBindingKey`** (shows the bound key in chat and tooltips) is
  feature-detected; without it the hints just leave the key out.
- **Floating button position:** anchored under the minimap button, wherever the
  player dragged it. On some minimap layouts it may overlap other UI.
- **Taint:** the Next button, the binding and `/gr next` are plain addon code
  calling non-protected `#hwevent` APIs. That needs no secure template on Mainline.
  If Forever made these calls protected instead, they would be blocked even with
  a press (shown by the block report).
- **Server throttle per press:** the community tools pace by hand, so the
  server's real minimum gap between /who queries is unknown. The /who delay
  default (3 s) is unchanged.
- **Lua 5.0 / real 1.12 clients:** the file is Lua 5.1 (`#`, `...` in the main
  chunk), so it cannot load on a 1.12 Lua 5.0 client at all. The timer-loop path
  (`RequiresHardwareEvent == false`) is for clients that run Lua 5.1 but lack
  `C_FriendList.SendWho`. The 1.12 build itself stays on `main`.

## 3. What could not be ported safely

1. **The automatic /who sweep and the automatic invites need hardware events (blockers 1 and 2). Addressed by key-press mode (§1.9).** The run now waits for a Next press for every /who and every invite: the F4 sweep, invite mode, reply invites, and Invite all / Send. Block reports pause the run. What it costs the player: one press per /who and per invite instead of an unattended run. In `whisper` mode only the /who needs a press. In `whisperinvite` mode the first whisper needs one too (see the end of §1.9). Not verified in game (§2.2).
2. **The "chat" invite method** (`/ginvite` through `ChatEdit_SendText`) runs a slash command from addon code. It falls under the same hardware-event rule as C_GuildInfo.Invite and may taint the chat edit box.
3. **The `ChatFrame_OnEvent` fallback** (used only if the message-filter API is missing) replaces a Blizzard global, which taints the chat frames on Mainline.

## 4. How this was checked (no client, no interpreter)

`lua`, `luac`, `luajit`, `lua5.1`, `lupa` and `luaparser` are not installed, so `luac -p` could not run. Instead:

- **A Lua 5.1 recursive-descent parser and scope resolver** written for this port (not committed; it lived in the session scratchpad). It applies the full 5.1 grammar, including `...` only inside vararg functions, `break` only inside loops, return/break as the last statement, and the "ambiguous syntax" rule. It counts upvalues and active locals per function, lists every global read and write, and flags generic-for loops over a non-call expression. To show it can fail, I ran it on 9 broken snippets; it rejected all of them, accepted a file of valid 5.1 constructs, and caught a 61-upvalue function. Its upvalue counts for the original file match the skill's `luacheck.py` (max 30).
- **Results, 1.12 source to port:** syntax OK to syntax OK. Implicit-table for loops 25 to 0. Max upvalues 30 to 30 (5.1 limit 60). Main-chunk locals 167 to 170 (limit 200). Globals read only by the original: `arg1 arg2 arg4 event getglobal this` (`this` was also written). Globals read only by the port: `Ambiguate BackdropTemplateMixin C_ChatInfo C_FriendList C_GuildInfo C_XMLUtil ChatFrame_AddMessageEventFilter Enum RegisterAddonMessagePrefix _G error issecrettable issecretvalue`. Every one of them is read only inside the compat layer (lines 37-321), which was checked per name with the parser.
- **grep** (whole file, code and comments): `getn` 54 to 0, `gfind` 1 to 0, `this.`/`this:` 29 to 0, `getglobal` 4 to 0, `SetTexture(<number>` 2 to 0, direct `:SetBackdrop` 5 to 0 outside the layer. The remaining `arg1` (2) and `ChatFrame_OnEvent` (1) hits outside the layer are in comments, and the remaining word "this" (26 hits) is English prose. Outside lines 37-321 there are no direct calls to SendWho, GetNumWhoResults, GetWhoInfo, SetWhoToUI/SetWhoToUi, GuildInvite, GuildInviteByName, C_GuildInfo, SendChatMessage, C_ChatInfo, SendAddonMessage, RegisterAddonMessagePrefix, CanGuildInvite, ChatEdit_SendText, ChatFrame_OnEvent, FriendsFrame, FauxScrollFrame_* or issecretvalue. The only hit is the METHOD_SHORT label strings.
- **Handler parameters:** any handler that used `self`, `button` or `elapsed` without declaring it would show up as a global read; none do. A negative test confirmed the checker reports exactly that case.
- `file` says ASCII text (LF) for all edited files before and after, with 0 CR bytes.

### 4.1 Key-press mode checks (same tools, plus a call graph)

- **Parser, `e824243` to the working tree:** syntax OK to syntax OK (227 to 256
  functions). Max upvalues 30 to 31: the slash handler, which now also reads
  GR_Compat. Start stays at 30, GR_OnUpdate goes 25 to 27, GR_OnEvent stays at 20
  (5.1 limit 60). Main-chunk locals 170 to 171 (`FinishSweep`; limit 200).
  Generic-for over a non-call: 0.
- **New global reads:** `GetBindingKey`, the frame names `GuildRecruiterMinimapButton`
  and `GuildRecruiterNextButton` (made by `CreateFrame`), and the new
  `GuildRecruiter_*` functions and `GuildRecruiter_dealt`. Every one of those is
  also written in the file. The new global writes are those plus the two
  `BINDING_*` labels.
- **Call graph** (a script on the same parser, kept in the session scratchpad
  and not committed). Its nodes are all functions; its edges are any reference to
  a function, call or value. Its roots are the anonymous `SetScript` handlers
  (8 OnUpdate, 1 OnEvent, 36 OnClick, ...) plus the two chat-filter callbacks. It
  lists every path from an OnUpdate, OnEvent or chat-filter root to
  `GR_Compat.SendWho` or `GR_Compat.GuildInvite`. There are 6 paths, all from the
  run loop's OnUpdate. They cross exactly four call edges, and each edge is behind
  a guard:
  - `SendNextWho()` in GR_OnUpdate, inside `if not GR_Compat.RequiresHardwareEvent`;
  - `GuildRecruiter_InviteReply()` in Drain, inside `#replyQueue > 0 and not hw`;
  - `GuildRecruiter_ContactHead()` in Drain, inside `elseif not hw`;
  - `GuildRecruiter_ContactHead()` in Drain, under `hw`, only if
    `GuildRecruiter_TimerMay(v)`. That function is false for Invite all and true
    only for mode `whisper` from the same `CfgOf(v)` that `Contact` reads, so
    `Contact` takes its whisper branch.

  No OnEvent or chat-filter root reaches either wrapper. The callers of the press
  path are `GuildRecruiter_Next`, which is called from the two Next buttons'
  OnClick, from `/gr next` and from Bindings.xml, and `GuildRecruiter_InviteOne`,
  which is called from a candidate row's OnClick and from `/gr invite`. As a
  negative test, I injected `GuildRecruiter_InviteReply(); SendNextWho()` into the
  CHAT_MSG_WHISPER branch of a scratch copy. The script then reported the two new
  OnEvent paths. The runtime gate (`GR_Compat.CheckPress`) backs up all four
  guards.
- **Bindings.xml:** it parses with `xml.etree` (root `Bindings`, one `Binding`
  with `name="GUILDRECRUITER_NEXT" header="GUILDRECRUITER"`, body
  `GuildRecruiter_Next()`). The name and header match the `BINDING_*` globals
  and the `GetBindingKey("GUILDRECRUITER_NEXT")` calls. The file is not listed in
  the .toc, per the wiki ("you should not list it"). The release workflow's
  rsync excludes only `.git`, `.github`, `*.md` and `README*`, so Bindings.xml
  ships in the zip.

### Wiki pages used (warcraft.wiki.gg, read 2026-11-04)

- API_C_FriendList.SendWho, API_C_FriendList.GetWhoInfo, API_C_FriendList.GetNumWhoResults, API_C_FriendList.SetWhoToUi
- API_C_GuildInfo.Invite
- API_C_ChatInfo.SendChatMessage, API_SendChatMessage, Patch_11.2.0/API_changes
- API_C_ChatInfo.SendAddonMessage, API_C_ChatInfo.RegisterAddonMessagePrefix
- API_ChatFrame_AddMessageEventFilter
- Secret_Values, Patch_12.0.0/API_changes
- Patch_1.60.1/API_changes (the Forever change list: "WoW Forever shares Mainline WoW's UI architecture, including the vast majority of APIs available in 12.1.5"; EMOTE now needs a hardware event; trial accounts can't send addon messages; Midnight's restrictions, including secrets, apply)
- API_Ambiguate, API_FontInstance_SetFont, API_C_XMLUtil.GetTemplateInfo
- For key-press mode: Bindings.xml (attributes, `BINDING_HEADER_`/`BINDING_NAME_`, auto-loaded), ADDON_ACTION_BLOCKED and ADDON_ACTION_FORBIDDEN (payload, synchronous, Forever 1.60.1 listed), API_C_FriendList.SendWho re-read (silent on what a violation does)
- Patch_10.1.0/API_changes (FauxScrollFrameTemplate deprecated), Patch_10.0.0/API_changes (OptionsSliderTemplate deprecated; via search summary)

Not confirmed on the wiki (my own Mainline knowledge, so unverified): the BackdropTemplate requirement (9.0), SetColorTexture (7.0), the Mainline `FauxScrollFrame_OnVerticalScroll(self, offset, itemHeight, fn)` signature, and the handler argument lists for OnClick, OnUpdate, OnEvent and the rest.
