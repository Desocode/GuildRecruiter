# GuildRecruiter: WoW: Forever port notes

Version `4.0.0-forever.1`, branch `forever`, based on `1023a66` (the v3.22 source
plus REQUIREMENTS.md). Status: **ported and checked offline; one player
screenshot from a Forever client so far** (§1.10). The port is committed locally
as `e824243`, the key-press mode (§1.9) as `716a33b`. The secure invite button
(§1.10) sits on top of `716a33b` and is **not committed**.

Port (`e824243` vs `1023a66`, `git diff --numstat`): GuildRecruiter.lua +526 / -252,
GuildRecruiter.toc +3 / -3, README.txt +42 / -0.
Key-press mode (`716a33b` vs `e824243`): GuildRecruiter.lua +453 / -93,
README.txt +44 / -7, PORT_NOTES.md, and a new Bindings.xml (9 lines). The .toc is
unchanged: the client loads Bindings.xml by itself.
Secure invite button (working tree vs `716a33b`, `git diff --numstat`):
GuildRecruiter.lua +342 / -95, README.txt +49 / -17, Bindings.xml +9 / -6, and
PORT_NOTES.md. The .toc is unchanged. All files are LF with no CR bytes, and
GuildRecruiter.lua is still pure ASCII.

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
| GuildInvite | Key-press mode: `SetSecureInvite` (the `/ginvite` macro on the secure Next button, §1.10); never a direct call. Timer-loop client: `C_GuildInfo.Invite(name)` for "auto", or when the chosen method's function is missing | Timer-loop client: `GuildInviteByName`, `GuildInvite`, then `/ginvite` (the 1.12 order) |
| SetSecureInvite / SecureClear / InCombat | sets / empties `type`+`macrotext` on the secure button; only inside its PreClick and never in combat lockdown (`InCombatLockdown`) | — |
| InviteApiName / ApiSummary | names the call actually in use ("/ginvite on the secure Next button" in key-press mode) | — |
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

**Superseded for invites by §1.10.** This section describes `716a33b`. On a
Forever client, its direct `C_GuildInfo.Invite` call was refused with
ADDON_ACTION_FORBIDDEN, so invites now go through a secure button. The /who
half, the step order, the pacing and the timer's role are unchanged. Where the
two sections differ (entry points, the invite call, the Lists-tab Next button,
`/gr invite`, the gate), §1.10 is current.

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

### 1.10 Guild invites through one secure button

**Evidence (a Forever client, player's screenshot).** Pressing Next sent a /who
(`C_FriendList.SendWho` worked from the key-press path; 48 candidates were
queued). The first invite printed `The client blocked send()
(ADDON_ACTION_FORBIDDEN); our last restricted call was C_GuildInfo.Invite 0.0s
ago -- run paused`. (`send()` is the local name the call went through:
`send(name)` in `GR_Compat.GuildInvite`.) So `C_GuildInfo.Invite` is forbidden
to addon code: it is protected, not just hardware-event gated, and a key
press does not unlock it. A Forever-beta addon README also calls `/ginvite`
and invite "Blizzard-only actions" and uses a secure macro button the player
clicks.

**Design.** One secure button, `GuildRecruiterNextButton`, made from
`SecureActionButtonTemplate,UIPanelButtonTemplate` (the floating Next button,
now secure). Its PreClick (insecure addon code that runs in the click's
hardware event before the template's secure OnClick) chooses the step with the
same `GuildRecruiter_NextStep` as before:
- **invite step** (ready reply, queue head in invite mode / Invite all, or a
  single invite set from the Lists tab or `/gr invite`), out of combat:
  `SetAttribute("type", "macro")` and `SetAttribute("macrotext", "/ginvite
  Name")`, then the same bookkeeping code as before (history, stats, tally,
  `inviteTimer` pacing, the guild-sync broadcast, candidate removal). The addon
  makes no invite call. The template's OnClick then runs the macro through
  `C_Macro.RunMacroText`, and Blizzard's `/ginvite` handler calls
  `C_GuildInfo.Invite`. PostClick empties the action again.
- **/who step**: the action stays empty and PreClick calls `SendNextWho` as
  before (the press that the screenshot showed working).
- **whisper or "wait Ns"**: the action stays empty and the step is handled as
  before.
- **invite step in combat lockdown**: no `SetAttribute` (not allowed). The press
  prints `Next: can't set the invite in combat -- press again when combat ends.`
  and does nothing else. The button text gets " (after combat)". With "Pause in
  combat" on (the default), `SendsBlocked` holds invites in combat anyway, so
  the press goes to the /who instead.

The code change is small: `GR_Compat.GuildInvite` in key-press mode calls
`GR_Compat.SetSecureInvite(name)` instead of the resolved invite function.
`SetSecureInvite` works only while `GR_Compat.secureClick` is set (PreClick) and
not in lockdown; anywhere else it raises a named error. `InviteReply`,
`ContactHead` and `Contact` are unchanged. `GuildRecruiter_NextStep` now also
returns `invite` (true for an invite step), and `GuildRecruiter_NextPress`
refuses an invite step without a secure click (typed `/gr next`) or in combat
before anything is dequeued.

**Secure-button map** (there is exactly one secure frame):

| Button | Invites | Name set by | Attributes, and where they are set |
|---|---|---|---|
| `GuildRecruiterNextButton` (UIParent child, anchored to UIParent under the minimap button) | during a run: the head of `replyQueue`, else the head of `contactQueue` when its contact is an invite (invite mode, Invite all, Send in invite mode); with no run: `GuildRecruiter_oneName` | `GR_Compat.SetSecureInvite(name)`, reached only from `GuildRecruiter_SecurePreClick` -> `GR_Compat.Press(GuildRecruiter_NextPress)` -> `DoGuildInvite` (via `InviteReply`, `ContactHead`/`Contact`, or the "one" step) | `useOnKeyDown=false`: `GuildRecruiter_MakeNext`, once, out of combat. `type="macro"`, `macrotext="/ginvite Name"`: `SetSecureInvite`, PreClick only, out of combat. `type=nil`, `macrotext=nil`: `GR_Compat.SecureClear` at the start of PreClick, after a PreClick error, in PostClick, and on PLAYER_REGEN_DISABLED; it does nothing in lockdown |

Routed to that one button:
- Bindings.xml: `<Binding name="CLICK GuildRecruiterNextButton:LeftButton"
  header="GUILDRECRUITER" runOnUp="true"/>`. The old `GUILDRECRUITER_NEXT`
  script binding is gone: a script binding is insecure, so it could never send
  the invite. A key bound to the old entry has to be bound again.
- A macro with `/click GuildRecruiterNextButton`.
- The Lists-tab Next button is **removed**: Invite all / Send arm the run, and
  each click on the floating button sends one invite. The strip says "N left,
  click Next by the minimap".
- A left-click on a candidate row, and `/gr invite <name>`, set
  `GuildRecruiter_oneName` and show the button ("Invite Bob"). The next click
  invites and records it (`GuildRecruiter_InvitedOne`, the old InviteOne
  bookkeeping). `/gr stop` with no run drops it (`GuildRecruiter_CancelOne`).
  Arming a run drops it too.
- Typed `/gr next` still does /who and whisper steps. For an invite step it
  prints how to send it (button, key, or a `/click` macro).

**Why no secure button in the main window.** warcraft.wiki.gg
(API ScriptRegion_IsProtected): anchoring or parenting a protected frame to
another frame makes that frame implicitly protected. A secure Lists-tab Next
button or secure candidate rows would protect the main window, so closing it,
switching tabs or Escape in combat would be blocked. For the same reason the
floating button is anchored to UIParent, not to the minimap button (which is
dragged with SetPoint). `GuildRecruiter_PlaceNext` puts it under the minimap
button's current screen position (minimap units scaled to UIParent units), out
of combat, and `MinimapUpdatePos` calls it again while the minimap button is
dragged. It is `SetClampedToScreen` and strata DIALOG (level 100), so it stays
clickable over the main window, which has no Next of its own now.

**Click edge (documented choice: the UP edge).** The Forever UI source
(Gethe/wow-ui-source, branch `forever`, 1.60.1 build 70790,
`Blizzard_FrameXML/SecureTemplates.lua`): `SecureActionButton_ShouldUseOnKeyDown`
reads the button's `useOnKeyDown` attribute and falls back to the
`ActionButtonUseKeyDown` CVar only when it is nil, and
`SecureActionButton_OnClick` acts only when `(down and useOnKeyDown) or (not
down and not useOnKeyDown)`. The button sets `useOnKeyDown = false`, so the
CVar doesn't matter, and the action fires on the up click. It is registered for
`LeftButtonUp` only, so PreClick and PostClick run on that same event (both
also return on `down`). Up, because `/click` (`Blizzard_ChatFrameBase/Shared/
SlashCommands.lua`) sends `down = StringToBoolean(down or "", false)`, an up
click unless told otherwise, and a mouse click finishes on the up edge. A key
on the CLICK binding therefore acts when it is released. `runOnUp="true"` is
there because the wiki says a binding without it fires only on press. Whether
that rule applies to CLICK bindings is unverified, so the attribute is set to
be safe. With LeftButtonUp the only registered event, a press event can't
double-fire.

**No OnClick script on the button.** `SetScript("OnClick")` would replace the
template's `SecureActionButton_OnClick`. The old floating button had one; it is
gone. PreClick and PostClick are anonymous wrappers that call the globals, so
the call graph sees them as roots.

**Combat lockdown rules kept.** Insecure code can't change a protected frame's
attributes, position, size, visibility or click registration in lockdown. Every
such call on the button is behind `GR_Compat.InCombat()` (`InCombatLockdown`):
`MakeNext` (creation and all setup; if the UI loads in combat, it is built on
PLAYER_REGEN_ENABLED), `PlaceNext`, `SyncNext` (Show/Hide), the button's own
OnUpdate (Hide), `SecureClear` and `SetSecureInvite`. `ShowNext` in combat only
updates the text, or prints `In combat: the Next button appears when combat
ends.` PLAYER_REGEN_DISABLED empties the action (the wiki says lockdown starts
after that event fires). PLAYER_REGEN_ENABLED re-syncs the button. The button's
text is still set in combat (`SetText`); I believe that is not a restricted
call (unverified, §2.2).

**Binding label.** Forever's `Blizzard_SharedXML/BindingUtil.lua`:
`GetBindingName(binding)` returns `envTable["BINDING_NAME_"..binding]`. For
this binding the global is `_G["BINDING_NAME_CLICK
GuildRecruiterNextButton:LeftButton"]`, with the space and the colon. A global
named `BINDING_NAME_CLICK_GuildRecruiterNextButton_LeftButton` would never be
read. warcraft.wiki.gg (Bindings.xml, Creating_key_bindings) states the
`_G["BINDING_NAME_" .. name]` rule but gives no CLICK example; API
SetBindingClick gives the command form `"CLICK " .. buttonName .. ":" ..
button`. The header label `BINDING_HEADER_GUILDRECRUITER` is unchanged.

**Block report.** `GR_Compat.BlockedLine` already paused the run and named the
event's second argument for both events (the screenshot is that line).
ADDON_ACTION_FORBIDDEN now has its own wording: `The client forbids <fn> for
addons (ADDON_ACTION_FORBIDDEN: Blizzard-only, a key press does not unlock it);
our last restricted call was ... -- run paused (...)`. `lastCall` for an invite
is now `/ginvite on GuildRecruiterNextButton`.

**Timer-loop clients** (no `C_FriendList.SendWho`): unchanged.
`GR_Compat.GuildInvite` keeps `ResolveInvite` -> `send(name)` (C_GuildInfo.Invite,
GuildInviteByName, GuildInvite, the /ginvite chat fallback) on that path only.
`GuildRecruiter_InviteOne` invites at once there, as before.

**Behaviour the player will notice (key-press mode):**
- Invites go out only from a click on Next, its key or a `/click
  GuildRecruiterNextButton` macro, and not in combat. `/gr next` and
  `/gr invite` explain instead of inviting.
- The Key Bindings entry is now "Next: one /who, whisper or guild invite"
  (under Guild Rawcruiter). The old entry's key is lost; bind again.
- Mouse and key act on release.
- The Lists tab has no Next button. Candidate left-click sets the name on Next
  ("Invite Bob"), and the next click invites. `/gr stop` drops it.
- Floating button: above the main window, clamped to the screen, follows a
  minimap-button drag. In combat it can't appear, hide or move until combat ends.
- Load line: `Invite API: /ginvite on the secure Next button (who: ..., whisper:
  ...). Key-press mode: each /who and invite waits for the Next button or its
  key (invites: not in combat)`.
- `/gr set method` has no effect in key-press mode (the setting is kept).

## 2. Still unverified

There was no game client and no Lua interpreter. Everything below is untested.
Wiki facts come from the pages listed in §4. The wiki is fan-maintained, and its
per-function flavour tables say an API *exists* on Forever 1.60.1 (build 69913).
They do not say a restriction applies per flavour.

| # | Blocker (REQUIREMENTS §3) | Isolated in | What the wiki says / what is still open |
|---|---|---|---|
| 1 | Do SendWho / C_FriendList.SendWho, GetNumWhoResults / GetWhoInfo and SetWhoToUI exist, and what are their throttle and hardware-event rules? | `GR_Compat.SendWho` (gated by `GR_Compat.CheckPress`), `GR_Compat.GetNumWhoResults`, `GR_Compat.GetWhoRow`, `GR_Compat.SetWhoToUI` (+ `GR_Compat.WhoPanel`); mode switch `GR_Compat.RequiresHardwareEvent` | All four `C_FriendList` calls are listed for Forever 1.60.1. **SendWho is marked `#hwevent` (needs a key or mouse press, since 8.2.5)** and is throttled server-side ("queries are not guaranteed to generate a response"). **Handled by key-press mode (§1.9): one /who per press.** Still open: whether Forever actually enforces `#hwevent` here, and what a violation does (the wiki page doesn't say whether it errors, fails silently or fires ADDON_ACTION_BLOCKED; a silent drop would show up as a /who timeout and retry). The origin argument was added in 10.2.0; the code passes `Enum.SocialWhoOrigin.Social` (1), which is my choice and unverified. The wiki says GetNumWhoResults "never seem[s] to go over 50". SetWhoToUi(true) sends every reply to WHO_LIST_UPDATE and FriendsFrame. Whether FriendsFrame is the frame that registers WHO_LIST_UPDATE on Forever (needed for Who-window suppression) is unknown. |
| 2 | Are GuildInvite / GuildInviteByName / C_GuildInfo.Invite callable from addon code, and do they need a hardware event? | Key-press mode: `GR_Compat.GuildInvite` -> `GR_Compat.SetSecureInvite` / `GR_Compat.SecureClear` on the secure `GuildRecruiterNextButton`. Timer-loop client: `GR_Compat.ResolveInvite`, `GR_Compat.RunSlash` (method "chat"). Both: `GR_Compat.CanGuildInvite`, `GR_Compat.InviteApiName` | **Answered in game: `C_GuildInfo.Invite` from addon code raised ADDON_ACTION_FORBIDDEN, even inside a key press** (§1.10). It is protected, not just `#hwevent`. **Handled by the secure button (§1.10): the client's own `/ginvite`, run as a secure macro, one per click, not in combat.** Still open: everything in §2.2 about the secure button. Whether `CanGuildInvite` still exists on Forever is unknown (the call is feature-detected; if it's missing, invites are allowed, as in 1.12). |
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

**Seen in game (one screenshot):** a key press on the old script binding sent
a /who through `GR_Compat.Press` -> `pcall` -> `C_FriendList.SendWho`, and the
results were read and queued. So the hardware context does cover the `pcall`,
at least for a key-down script binding. A direct `C_GuildInfo.Invite` was
FORBIDDEN (§1.10). Everything about the secure button is untested:

- **The secure macro `/ginvite Name` is untested.** It relies on the template's
  OnClick running `C_Macro.RunMacroText("/ginvite Name")` untainted, so that
  Blizzard's `/ginvite` handler may call `C_GuildInfo.Invite`. If Forever also
  forbids `/ginvite` from a secure macro, or the attributes set by addon code
  taint it, no invite goes out. It may then show up as ADDON_ACTION_FORBIDDEN
  naming this addon (the run pauses and says so), or as nothing at all (the
  bookkeeping would still record the invite).
- **Attributes set in PreClick apply to the same click.** This is the
  well-documented pattern (PreClick runs before the template's OnClick, and
  SecureActionButton_OnClick reads `type` and `macrotext` when it runs), but it
  is untested on Forever. If it did not hold, each click would run the
  previous click's macro; PostClick empties the action, so it would run
  nothing instead.
- **Up-edge dispatch of the CLICK key binding.** The action fires on the up
  click. That a CLICK binding sends an up click when the key is released, and
  that `runOnUp="true"` is accepted on a CLICK binding, are my Mainline
  knowledge, not checked. If the key does nothing, the mouse click and the
  `/click` macro should still work. Setting `useOnKeyDown` to true and
  registering `LeftButtonDown` would be the fallback, but then `/click` would
  need `/click GuildRecruiterNextButton LeftButton true`.
- **A key release, and a mouse up, as the hardware event for `SendWho`:** the
  /who now runs in the PreClick of an up click, not on key down as in the
  screenshot.
- **A CLICK binding on a hidden button:** I believe the binding and `/click`
  still click it (hidden secure buttons are a common pattern). The button is
  hidden when no run is armed, and then a press only says "not armed".
- **`SetText` on the secure button in combat** (the label updates every 0.2 s):
  assumed not to be a restricted call. If it were, ADDON_ACTION_BLOCKED would
  name this addon in combat and pause the run.
- **Forever's `SecureActionButtonTemplate` / `UIPanelButtonTemplate` combo:**
  read in the Forever UI source (neither defines a conflicting OnClick), not run.
- **Combat timing:** PLAYER_REGEN_DISABLED firing before lockdown (wiki) is what
  lets the action be emptied there. Between clicks it is empty anyway.
- **Hardware context through `pcall` for typed commands:** typed `/gr next` runs
  inside the Enter-key press. Same assumption as above, but for Enter in the
  chat box instead of a binding.
- **A macro that mixes `/gr invite Bob` and `/click GuildRecruiterNextButton`:**
  it should invite Bob in one press if the client clears taint between macro
  lines, as it does for `/run` + `/cast`. Not tested.
- **ADDON_ACTION_BLOCKED / _FORBIDDEN:** the payload is `(addonName, function)`
  and both are synchronous (wiki; both are listed for Forever 1.60.1). It is
  unknown whether a `#hwevent` violation fires either of them, and in what
  format the `function` string comes (the example line in §1.9 is illustrative).
  The handler compares the first argument with the addon's folder name.
- **Bindings.xml:** the wiki documents `name`, `header`, `runOnUp` and `default`
  (no `category`). Where the entry shows up in Forever's Key Bindings window
  (an "AddOns" group or a "Guild Rawcruiter" header) is unverified. No default
  key is set, so nothing collides. The entry is now the CLICK binding (§1.10);
  its label global name was read from Forever's BindingUtil.lua, not seen in
  the window.
- **`GetBindingKey`** (shows the bound key in chat and tooltips) is
  feature-detected; without it the hints just leave the key out.
- **Floating button position:** anchored under the minimap button, wherever the
  player dragged it. On some minimap layouts it may overlap other UI.
- **Taint:** `/gr next` and the PreClick are plain addon code calling the
  non-protected `#hwevent` SendWho. Invites were the protected case (shown by the
  block report in game) and now go through the secure button (§1.10).
- **Server throttle per press:** the community tools pace by hand, so the
  server's real minimum gap between /who queries is unknown. The /who delay
  default (3 s) is unchanged.
- **Lua 5.0 / real 1.12 clients:** the file is Lua 5.1 (`#`, `...` in the main
  chunk), so it cannot load on a 1.12 Lua 5.0 client at all. The timer-loop path
  (`RequiresHardwareEvent == false`) is for clients that run Lua 5.1 but lack
  `C_FriendList.SendWho`. The 1.12 build itself stays on `main`.

## 3. What could not be ported safely

1. **The automatic /who sweep and the automatic invites need hardware events (blockers 1 and 2). Addressed by key-press mode (§1.9) and the secure invite button (§1.10).** The run now waits for a Next press for every /who and every invite: the F4 sweep, invite mode, reply invites, and Invite all / Send. Block reports pause the run. What it costs the player: one press per /who and per invite instead of an unattended run, and no invites in combat. In `whisper` mode only the /who needs a press. In `whisperinvite` mode the first whisper needs one too (see the end of §1.9). The /who press is confirmed in game; the secure invite is not (§2.2).
2. **The "chat" invite method** (`/ginvite` through `ChatEdit_SendText`) runs a slash command from addon code. It is kept only for timer-loop clients. In key-press mode it is never used: `/ginvite` runs from the secure button's macro instead.
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

### 4.2 Secure invite button checks (same tools)

- **Parser, `716a33b` to the working tree:** syntax OK to syntax OK (256 to 266
  functions). Max upvalues 31 to 31 (the slash handler); Start 30, GR_OnUpdate
  27, GR_OnEvent 20, all unchanged (5.1 limit 60). Main-chunk locals 171 to 171
  (limit 200): the new code adds only globals and `GR_Compat` fields.
  Generic-for over a non-call: 0.
- **Globals:** new reads `InCombatLockdown` and the new `GuildRecruiter_*`
  functions plus `GuildRecruiter_oneName`; every one of those is also written in
  the file. `BINDING_NAME_GUILDRECRUITER_NEXT` is no longer written; the CLICK
  label is written through `_G[...]`.
- **Invite calls (grep, code lines):** `C_GuildInfo.Invite`, `GuildInviteByName`,
  `GuildInvite` and `GR_Compat.InviteByChat` / `RunSlash` appear only in
  `GR_Compat.ResolveInvite` / `InviteByChat` / `RunSlash` (which only return or
  run the function) and in the one call `send(name)` in `GR_Compat.GuildInvite`.
  That call comes after `if GR_Compat.RequiresHardwareEvent then
  GR_Compat.SetSecureInvite(name) return end`. `InviteApiName` returns before
  `ResolveInvite` in key-press mode. The only other hits are `CanGuildInvite`
  and the `METHOD_SHORT` labels.
- **Call graph, every root** (the script now also counts PreClick, PostClick and
  the slash handler as roots, and the sinks are `GR_Compat.SendWho`,
  `GR_Compat.SetSecureInvite`, `GR_Compat.ResolveInvite`, `InviteByChat` and
  `RunSlash`). The graph is branch-blind, so I also ran it on a copy
  specialised to key-press mode: the six code blocks that run only when
  `RequiresHardwareEvent` is false were cut, and each cut had to match exactly
  once. On that copy:
  - `ResolveInvite`, `InviteByChat`, `RunSlash`: no path from any root.
  - `GR_Compat.SendWho`: only from the PreClick root and the slash root
    (`/gr next`, kept on purpose for /who). No OnUpdate, OnEvent or
    chat-filter path. On the unspecialised file the extra path is the 1.12
    timer `SendNextWho()` inside `if not GR_Compat.RequiresHardwareEvent`.
  - `GR_Compat.SetSecureInvite`: from PreClick (the intended path). From
    `/gr next`, which `NextPress` stops at `inv and not GR_Compat.secureClick`
    before dequeuing. From the run timer through `Drain` ->
    `GuildRecruiter_ContactHead`, which in key-press mode runs only when
    `GuildRecruiter_TimerMay(v)` is true (a plain whisper, never Invite all),
    so `Contact` takes its whisper branch. That is the same guard as in §4.1.
    `SetSecureInvite` itself raises an error when `secureClick` is nil.
  - Negative test: injecting `GuildRecruiter_InviteReply(); SendNextWho()` into
    the CHAT_MSG_WHISPER branch of the specialised copy made the script report
    both new OnEvent paths.
- **SetAttribute audit:** there are exactly five `SetAttribute` calls:
  `useOnKeyDown` in `GuildRecruiter_MakeNext`, `type`/`macrotext` in
  `GR_Compat.SetSecureInvite`, and `type`/`macrotext` = nil in
  `GR_Compat.SecureClear`. Each function checks `GR_Compat.InCombat()` first
  and returns or raises an error when it is true. Event code reaches them only
  through `SecureClear` (PLAYER_REGEN_DISABLED) and `SyncNext` -> `MakeNext`
  (ADDON_LOADED, PLAYER_REGEN_ENABLED). No OnUpdate reaches `MakeNext` or
  `SecureClear`. The one timer path to `SetSecureInvite` is the TimerMay
  whisper path above, which errors before any `SetAttribute` anyway.
  Show, Hide, ClearAllPoints and SetPoint on the button are in `MakeNext`,
  `PlaceNext`, `SyncNext` and the button's OnUpdate (Hide), all behind the same
  check.
- **Bindings.xml** parses with `xml.etree`: root `Bindings`, one `Binding` with
  `name="CLICK GuildRecruiterNextButton:LeftButton" header="GUILDRECRUITER"
  runOnUp="true"` and no body. The name matches `GR_Compat.NEXT_BINDING`, which
  is used for the `GetBindingKey` lookups and the `_G` label.
- `file`: GuildRecruiter.lua ASCII text, all edited files LF, 0 CR bytes.

### Forever UI source read for §1.10 (Gethe/wow-ui-source, branch `forever`, 1.60.1 build 70790, read 2026-11-05)

- `Interface/AddOns/Blizzard_FrameXML/SecureTemplates.lua` (SECURE_ACTIONS.macro,
  `SecureActionButton_ShouldUseOnKeyDown`, `SecureActionButton_OnClick`,
  `SecureButton_GetModifiedAttribute`) and `SecureTemplates.xml`
  (`SecureActionButtonTemplate`: OnClick = `SecureActionButton_OnClick`)
- `Interface/AddOns/Blizzard_ChatFrameBase/Shared/SlashCommands.lua` (`/click`:
  default up click; `/ginvite`: `C_GuildInfo.Invite(msg)`)
- `Interface/AddOns/Blizzard_SharedXML/BindingUtil.lua` (`GetBindingName`:
  `envTable["BINDING_NAME_"..binding]`)
- `Interface/AddOns/Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml` and
  `SecureUIPanelTemplates.xml` (`UIPanelButtonTemplate` has no OnClick)

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
- For the secure button (read 2026-11-05): SecureActionButtonTemplate (`useOnKeyDown` overrides the ActionButtonUseKeyDown CVar; `type`=macro with `macrotext`, 255-character limit; example `useOnKeyDown=false` + `RegisterForClicks("AnyUp","AnyDown")`; create it outside combat), Bindings.xml and Creating_key_bindings (label `_G["BINDING_NAME_" .. name]`, `runOnUp`, a click binding "performs a :Click() on an existing Button widget, securely", no CLICK example), API_SetBindingClick (`SetBinding(key, "CLICK " .. buttonName .. ":" .. button)`, LeftButton default), API ScriptRegion_IsProtected (via search summary: anchoring or parenting to a protected frame makes a frame implicitly protected; lockdown starts after PLAYER_REGEN_DISABLED and ends before PLAYER_REGEN_ENABLED)

Not confirmed on the wiki (my own Mainline knowledge, so unverified): the BackdropTemplate requirement (9.0), SetColorTexture (7.0), the Mainline `FauxScrollFrame_OnVerticalScroll(self, offset, itemHeight, fn)` signature, and the handler argument lists for OnClick, OnUpdate, OnEvent and the rest.
