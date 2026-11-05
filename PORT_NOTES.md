# GuildRecruiter: WoW: Forever port notes

Version `4.0.0-forever.2`, branch `forever`, based on `1023a66` (the v3.22 source
plus REQUIREMENTS.md). Status: **ported and checked offline; a few player tests
on a Forever client** (§1.10, §1.11). Committed: the port `e824243`, key-press
mode (§1.9) `716a33b`, the secure button and the copy box (§1.10) `dccd448` to
`520c586`, the API audit `0c17add`, automatic whispers and the Ready list
(§1.11) `1856b3e`, then the clipboard, the "Rawcruiter" chat tab, the Free
Trial detection / `C_GuildInfo.Invite` post-hook and the chat tidy-up
(`5755cd5` to `94ef08a`). **Not committed:** the guide window (§1.12), on top
of `94ef08a`.

Port (`e824243` vs `1023a66`, `git diff --numstat`): GuildRecruiter.lua +526 / -252,
GuildRecruiter.toc +3 / -3, README.txt +42 / -0.
Key-press mode (`716a33b` vs `e824243`): GuildRecruiter.lua +453 / -93,
README.txt +44 / -7, PORT_NOTES.md, and a new Bindings.xml (9 lines). The .toc is
unchanged: the client loads Bindings.xml by itself.
Secure button to API audit (`0c17add` vs `716a33b`): GuildRecruiter.lua +496 / -113,
README.txt +49 / -17, Bindings.xml +9 / -6, API_AUDIT.md (new), PORT_NOTES.md.
Automatic whispers + Ready list (working tree vs `0c17add`): GuildRecruiter.lua
+669 / -142, README.txt +104 / -70, PORT_NOTES.md. The .toc and Bindings.xml are
unchanged. All files are LF with no CR bytes, and GuildRecruiter.lua is still
pure ASCII.
Guide window (working tree vs `94ef08a`, §1.12): GuildRecruiterGuide.lua (new,
992 lines), GuildRecruiter.lua +79 / -26, GuildRecruiter.toc +1, README.txt +34,
.github/workflows/package.yml +14, PORT_NOTES.md. Both .lua files are ASCII,
LF, 0 CR bytes.

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

- `VERSION = "4.0.0-forever.2"`, and the header comment says it is the Forever port (3 lines).
- TOC: `## Interface: 16001`, `## Version: 4.0.0-forever.2`, and Notes now say "WoW: Forever port, beta". Title, SavedVariables (`GuildRecruiter_Settings`), file list and folder name are unchanged.
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
- (Superseded by §1.11: the timer now sends the first whisper of
  `whisperinvite` mode too, and a yes-reply goes to the Ready list without a press.)

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

**Superseded for invites by §1.11** (and by commits `540234d` to `520c586`): the
secure `/ginvite` macro was refused in game, so the button no longer sets any
secure action; an invite step only prompts (copy box + chat link) and the player
invites. The rest of this section (the button, the binding, the click edge,
combat rules) is still current.

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

### 1.11 Automatic whispers, the Ready list, and honest invite counts

**Facts from a real Forever client that this builds on.** `C_FriendList.SendWho`
works from a key press. A guild invite from addon code is forbidden in every
form tried: `C_GuildInfo.Invite`, a secure `/ginvite` macro, `/ginvite` typed
into the chat box by the addon, and (new) the Invite Member box filled by addon
code: `SetItemRef` called from addon code DID put the name into the box, but the
player's Accept then raised `ADDON_ACTION_FORBIDDEN` (function `Invite()`). Only
the player's own typing / paste into Blizzard's Guild > Invite Member popup
(`StaticPopup` `ADD_GUILDMEMBER`) works, and while that popup is open a
shift-click on a player link **in the chat frame** fills it
(`Blizzard_UIPanels_Game/Mainline/ItemRefHandlers.lua:24-28`, Blizzard's own chat
code). Whispers through `C_ChatInfo.SendChatMessage(..., "WHISPER", ...)` are
documented as not hardware-restricted (not yet seen in game).

**Rule (kept as a hard constraint):** addon code never calls `SetItemRef`, never
touches the Invite Member popup or any other Blizzard frame, never touches the
chat edit box, and never calls an invite function. The panel therefore only
re-prints the player link into `DEFAULT_CHAT_FRAME` (the same `AddMessage` every
chat line uses), and the player shift-clicks it there. (A likely mechanism for
the refusal, not proven: the popup's edit box has a SecureText aspect,
`editBox:SetSecureText(...)` in `Blizzard_StaticPopup_Game/GameDialog.lua:255`,
which the reference does not explain.)

**The flow in `whisperinvite` mode** (line numbers: working-tree GuildRecruiter.lua).
The only presses are one Next per /who and the player's own invite per yes.

| Step | What happens | Where |
|---|---|---|
| 1. Scan | Next press -> `SecurePreClick` / `/gr next` -> `NextPress` -> `SendNextWho` -> `GR_Compat.SendWho` | 2162-2183, 1273, 232 |
| 2. Queue | `ProcessWho`: guildless, not blacklisted, class/level filter, not in cooldown, not already on the Ready list -> `contactQueue` | 1287, 1319 |
| 3. Whisper (timer) | `GR_OnUpdate` -> `Drain`: cap check first (1705), then pacing + `SendsBlocked`; `DealHead` (contact time) -> `TimerMay` -> `ContactHead` -> `Contact` whisperinvite branch: `SendWhisper`, `whispered[name]`, history (cooldown) + guild broadcast. `TimerContactModes` now holds `whisperinvite` | 80, 1704-1729, 1667, 1194 |
| 4. Next /who | `NextStep` holds the /who while the queue still holds timer whispers ("Whispering (N)"); a press is needed only when the queue is empty and a /who is due | 2079, 2110, 2130 |
| 5. Reply "yes" | CHAT_MSG_WHISPER -> `ShortName` -> `GR_Compat.FindKey(whispered, sender)` -> `ShouldInvite` (notno / yesonly / any, word lists) -> `GuildRecruiter_ReadyAdd(key, "reply", v)`: saved entry, chat line with the player link, `GR_Compat.Alert()` (sound + flash), panel shown with "New: Name" in its title. No press, no invite | 1535-1553, 2428, 204 |
| 6. Player invites | Ready panel row: name -> `ReadyClick` -> `GR_Compat.PrintLink` (chat line; player shift-clicks it there); [Copy] -> `GR_Compat.ShowCopyBox`; [Copy next] = oldest name. Player presses Accept in Invite Member | 2500, 409, 419, 2481-2490 |
| 7. Counted | [Done] -> `GuildRecruiter_ReadyDone(name, "done")`; or CHAT_MSG_SYSTEM join / decline -> `GR_Compat.PlainName` -> `ReadyDone(name, "joined"/"declined")`, then the old join/decline tally via `FindKey(history)`; or the Lists tab "Ready to invite" view (confirm) -> `ReadyDone(name, "removed")` | 2448, 1504-1533, 2668-2693, 2829 |

**Ready list.** `GuildRecruiter_Settings.ready = { [name] = { t = time(), kind, v } }`
(seed-once in `Defaults`, line 864), so it survives /reload and logout. `kind` is
`reply`, `invite` (invite mode), `blast` (Invite all) or `one` (a single invite).
New settings, also seed-once: `readyAlert` (true), `readyTTL` (30 minutes),
`readyPos` (written when the panel is dragged). No existing SavedVariable was
renamed. The panel `GuildRecruiterReadyPanel` (2507) is a plain frame parented
to UIParent: not secure, not in the main window, draggable, clamped, newest
first, 8 rows plus "+N more", each row = name (a link-styled button; tooltip
"Click to print in chat, then shift-click it there"), age, [Copy], [Done]. It
auto-shows on every new name, hides itself when the list is empty, and shows at
load if names are still waiting (`ReadyLoad`, called at 1490). Expired entries
(older than `readyTTL`) are dropped by `ReadyPrune` with one chat line and
nothing counted. The minimap tooltip (3926), `/gr status` (4011), the Next
button (`[N ready]`) and the Lists tab run strip show the count.

**Invite bookkeeping (counted only in `GuildRecruiter_ReadyDone`, 2448).** No
invite is counted when a prompt is shown. `ReadyDone` does, by kind: `reply`:
`stats.invited`, tally "invited", history time refreshed with the variant that
whispered (the whisper already counted the contact, the cooldown, the broadcast
and the A/B "contacted"); `invite`: `stats.invited`, tally, `RecordHandled`
(history + broadcast) and A/B "contacted"; `blast`: `stats.invited`, tally,
history, broadcast; `one`: `GuildRecruiter_InvitedOne`. The candidate entry is
removed then too (a prompt keeps it until Done). Triggers: [Done]; the join or
decline system message naming a listed player (a decline also proves the invite
was sent); the player removing the name in the Lists tab's Ready view (it asks
first). For an invite-mode prompt `stats.contacted` still counts at the prompt,
because it is the run's step count (session cap, "N of M" progress); the run-end
and Stop lines now say "Prompted" there. The timer-loop path (no
`C_FriendList.SendWho`) counts at the invite call, as before.

**Invite mode, Invite all and single invites (key-press mode)** keep their press
step, but the press now only prompts: copy box + chat link + the name on the
Ready list (`Contact` 1197-1210, `ContactHead` 1667-1694, `NextPress` "one", 2173-2177).

**Review fixes in the same change.**
- (a) A pending reply no longer starves a due /who: replies need no press at
  all (step 5), so `NextStep` has no "reply" step. For a press contact step that
  is still pacing (`inviteTimer > 0`) and a /who that is due, `NextStep` returns
  whichever is ready first, the contact on a tie (2130).
- (b) A blocked /who: `GuildRecruiter_PauseBlocked` (2049) checks whether the
  last restricted call was our SendWho, 0 s ago (the block events are
  synchronous). Then, before pausing, it sets `awaiting = false`, `whoTimeout =
  0`, gives back the query (`stats.queries - 1`) and puts a class sub-query back
  at the front of `pending` (a sweep slice is rebuilt from the unchanged `lo`),
  so no timeout runs and no retry is burned.
- (c) The session cap: `Drain` checks `CapReached()` before the pacing and the
  `SendsBlocked()` hold (1705), so a capped run ends and its queue is cleared
  even in combat, in an instance or under throttle; `NextStep` reports "session
  cap reached -- the run is ending".
- (d) No A/B roll from polling: `NextStep` (called by the button label every
  0.2 s, tooltips, `/gr status`) uses the read-only `GuildRecruiter_HeadMode`
  (1614): the dealt variant's mode, the live mode when A/B is off, or nil (not
  dealt yet: treated as a timer whisper, Drain deals it when due). `DealHead`
  is called only from `Drain` (the head is due) and `ContactHead`. The deal is
  cleared on Stop (1910), Abort (1464), the cap drop and `/gr reset`.

**Names with a space ("First Surname")**, at every step: the /who row name is
`fullName` through `ShortName`; the whisper target is that string (Blizzard's
own Forever Who list passes `info.fullName` on, WhoList.lua:107, 110); a reply
is matched with `GR_Compat.FindKey`, which also tries "First-Surname" (whispers
accept both forms, ChatFrameEditBox.lua:84-85); the link is
`|Hplayer:First Surname|h[First Surname]|h`, and Blizzard's `HandlePlayerLink`
takes the name as the first ":" field (`string.split(":", options)`,
ItemRefHandlers.lua:1-8), so the space survives into the box; the copy box holds
the full name; join/decline names go through `PlainName` (link or plain text,
spaces kept) and `FindKey`. The surname separator is a space
(`SlashCommands.lua:1163-1164`).

**New commands and settings.** `/gr ready` (show/hide the panel), `/gr alert
on|off` (`readyAlert`, default on), `/gr set readyttl <minutes>` (1-1440, default
30). The Lists tab has a "Ready to invite" view (the dropdown popup now has 7
slots). No pacing default changed; no slash command was renamed.

**Whisper safety.** Default pacing is unchanged (invite delay 1 s, jitter off).
Timer whispers obey `Pace`, the throttle backoff, the combat / instance hold and
the session cap. The whisper text is the player's own message (`%p`, `%g`). A
name is whispered at most once per re-invite cooldown: history is written when
the whisper goes out, peers get the `INV` broadcast, `seen` covers the run, and
names on the Ready list are skipped by the scan. Nothing evades the server
throttle or chat spam detection.

**Alert.** `GR_Compat.Alert` (204): `C_Sound.PlaySound` (else the `PlaySound`
global, which Forever defines as `C_Sound.PlaySound`,
`Blizzard_SharedXML/Mainline/Sound.lua:3`) with `SOUNDKIT.READY_CHECK` (8960,
`Mainline/SoundKitConstants.lua:85`, loaded as `[Family]` on Forever), then
`FlashClientIcon()` (`ClientDocumentation.lua:10`; Blizzard's ready check does
the same pair, `Blizzard_FrameXML/Mainline/ReadyCheck.lua:71-72`). Both under
`pcall` and feature-detected. `PlaySoundFile` is not in the Forever docs and is
not used.

### 1.12 The guide window (GuildRecruiterGuide.lua)

Goal (the player's words): "someone can pick this up and roll intuitively". One
plain window, `GuildRecruiterGuide`, in a new file listed in the .toc after
GuildRecruiter.lua. Opened by `/gr` (bare), `/gr guide`, a left-click on the
minimap button (shift-left-click opens the old settings window), and by itself
at login (`PLAYER_ENTERING_WORLD`, once per session) until the player ticks
"Don't show again". `/gr help` still lists the commands. The file reaches
`GR_Compat` through the addon's private table (`ns.Compat`, set in the main
file; a global `GuildRecruiter_Compat` only if the client passes no table).
Everything in it is a global `GuildRecruiter_Guide*` function or a field on our
own frames, so the main file's locals (171) and upvalues are untouched.

**Layout.** 380 x 500, default top-right (`TOPRIGHT -16, -200`) so it stays
clear of Blizzard's Guild window (`CommunitiesFrame`, 814 px wide in the left
panel area, Invite Member at its bottom-right: `CommunitiesFrame.xml:303-306,
582-585`) and of the chat (bottom-left); draggable, position saved in
`guidePos`. Strata HIGH. Two views and a footer:

- *Setup* (first run until Finish): three cards with a tick each in the top
  row, Back / Next (Finish on card 3; a card left as it is just keeps its
  setting).
  1. "How should we reach people?" -- [Whisper first (recommended)] =
     `mode=whisperinvite, inviteDelay=5, jitter=true, sessionCap=30,
     replyMode=notno`; [Direct] = `mode=invite`. Presets only
     (`GuildRecruiter_GuideApproach`); the tick is `guideCards.approach`.
  2. "What should the whisper say?" -- three templates (Short = the existing
     default `NEW_WHISPER`, Friendly, Dungeons & raids; `%p`/`%g`, all well
     under 255 and capped by `WhisperBody` anyway), [Write your own...] opens
     the existing editor (`GuildRecruiter_EditMessage`), and a live preview
     through `GuildRecruiter_WhisperPreview` = `WhisperBody("Sam", msg)` with the
     player's real guild name. Tick: `guideCards.message`.
  3. "Where do the names show up?" -- no tab: [Create the Rawcruiter chat tab]
     (`GR_Compat.MakeChatTab`, i.e. `/gr chattab`), then [Reload now]
     (`C_UI.Reload`, else `ReloadUI`, under `pcall`; it also sets `guideDone`).
     Tab found and not made just now: [I already made it] (= Finish). The tick
     is live: `GR_Compat.ListFrame() ~= nil`. Skipped: the live guide's step 3
     becomes "Find the name in your chat" with a [Print] button.
- *Live guide*: "WHAT TO DO NOW", ONE headline, one sub line, one warning line
  (combat, or the player's own trial account), ONE big button (Start / Next /
  Resume, from `GuildRecruiter_GuideState`) with small [Pause] [Stop] beside it
  while a run is armed. Below: "INVITE THE PEOPLE WHO SAID YES" -- either
  "Nobody has said yes yet." (or "Invited Bob. Nobody else is waiting.") or
  the four numbered steps with ticks, the first unticked one highlighted with
  a gold ">", then "Waiting (3), longest first: Bob 2m, ..." and [List] (the
  old Ready panel with Copy and Done). Then "YOUR SETTINGS": Approach (one
  button that switches the two presets), Levels (two number boxes, same
  setters as the Settings tab: `GuildRecruiter_SetMinLevel/SetMaxLevel`),
  Message (preview + [Change], which opens card 2 alone with a Done button),
  and the "Today:" strip (whispered, said yes, invited, free trial skipped,
  from today's tally bucket).
- *Footer*: [Setup] (cards again), [Advanced...] (the existing
  Settings/Lists/Stats window, `GuildRecruiter_GotoSettings`), and the "Don't
  show again" check (`guideSeen`). Every button, box and check has a one-line
  tooltip (`frame.tip`, `GuildRecruiter_GuideTip`).

**What to do now** (`GuildRecruiter_GuideState`, read-only: it calls
`GuildRecruiter_NextStep`, `GuildRecruiter_RunState`, `GuildRecruiter_ReadyCount`,
`IsInGuild`, `GetGuildInfo`, `CanGuildInvite`, `IsTrialAccount`,
`IsVeteranTrialAccount`, `InCombatLockdown`; none of them changes anything and
NextStep never deals the A/B variant). In this order:

| State | Headline | Big button |
|---|---|---|
| `not IsInGuild()` | Join a guild first | Start, disabled |
| guild data loaded, mode not whisper-only, `CanGuildInvite()` false | Your rank can't invite people -- ask an officer | Start, disabled |
| not running, a single invite set (`act == "one"`) | Press Next for that player's name | the Next press |
| not running | Press Start | Start -> `GuildRecruiter_StartRun` = `Start()` |
| paused by a block report (`GR_Compat.pausedByBlock`) | Paused: the game blocked the /who search (or a whisper / an invite / an action, from `GR_Compat.blockLine`) | Resume -> `GuildRecruiter_TogglePause` |
| paused by the player | Paused | Resume |
| `act == "who"`, rest / awaiting / wait / due | Resting Ns ... / Searching -- waiting for the game's answer / Next search in Ns / Press Next to search for players | "Next: search" (enabled only when due) |
| `act == "contact"` (Direct) | Press Next for the next player to invite (or Next name in Ns, or In combat ...) | "Next: Invite Bob" |
| `short` "Whispering (N)" | Whispering 12 players -- nothing to do | disabled |
| `short` "Held: ..." | On hold: in combat | disabled |
| "Cap reached" / "Sweep done" / waiting | Reached your limit of 30 for this run / Search finished -- waiting for replies / Waiting for replies -- nothing to do | disabled |
| any of the above with N > 0 on the Ready list | N people said yes -- invite them below (when every waiting entry is a reply; with Direct prompts on the list: N people waiting for your invite -- see below). The run state moves to the sub line, "Meanwhile: ..." | unchanged |

**The press reuses the existing code** (`GuildRecruiter_GuidePress`): Start ->
`Start()`; Resume -> `GuildRecruiter_TogglePause`; Next -> exactly the secure
Next button's PreClick code `GuildRecruiter_SecurePreClick(btn, ...)` when the
click came through the guide's secure twin, or `GuildRecruiter_Next()` (= typed
`/gr next`) when it came through the plain stand-in button (in combat). No
press logic is duplicated, and the state is re-read at the click.

**Read-only detectors** for the four invite steps (`GuildRecruiter_GuideSteps`,
polled every 0.2 s while the window is shown):

| Step | Done when (all reads) | Secure button / fallback hint |
|---|---|---|
| 1 Open the Guild window | `CommunitiesFrame:IsShown()` (or a `GuildFrame:IsShown()`), or the invite box is already open | [Open] = `GuildRecruiterGuideOpenGuild`; hint "(or press J)" from `GetBindingKey("TOGGLEGUILDTAB")` (Bindings_Camelot.xml:1244), else "(Guild button on your bar)" |
| 2 Click Invite Member | `StaticPopup_Visible("ADD_GUILDMEMBER")` or `("ADD_GUILDMEMBER_WITH_FINDER_LINK")` (StaticPopup.lua:179, a `securecallfunction` read) | none: the button is `CommunitiesFrame.InviteButton`, a parentKey with no global name. Text: "Click Invite Member (bottom of the Guild window)" |
| 3 Switch to the Rawcruiter tab | `GR_Compat.ListFrame():IsVisible()` (docked and selected, or floating) | [Show] = `GuildRecruiterGuideShowTab`; hint "Switch your chat to the Rawcruiter tab". No tab: "Find the name in your chat" + a plain [Print] (prints up to 5 waiting names with `GR_Compat.PrintLink`, one line each) |
| 4 Shift-click a name, press Accept | `GR_Compat.lastInvite` set by the `C_GuildInfo.Invite` post-hook (`GR_Compat.OnInviteSent`) within the last 8 s; shows "Invited Bob" or "Bob is a Free Trial account -- skipped" | none. With the Guild Finder box open: "Type the name (this box ignores shift-click), press Accept" |

**Secure buttons** (all three `SecureActionButtonTemplate,UIPanelButtonTemplate`,
parented AND anchored to UIParent only, strata HIGH, level = guide + 20,
`RegisterForClicks("LeftButtonUp")`, `useOnKeyDown=false`). The guide window
stays a plain frame: each secure button is laid over a plain placeholder slot
at the slot's screen position (`GuildRecruiter_GuidePlace`, the same
UIParent-units sum as `GuildRecruiter_PlaceNext`); anchoring or parenting it to
the window would make the window protected (ScriptRegion_IsProtected, §1.10).

| Button | Attributes | Set where (all out of combat only) |
|---|---|---|
| `GuildRecruiterGuideNext` (the big button) | `useOnKeyDown=false` only; NO action attribute ever. PreClick -> `GuildRecruiter_GuidePress(self, button, down, true)`; PostClick -> `GuildRecruiter_SecurePostClick` (empties nothing: there is nothing to empty) | `GuildRecruiter_GuideSecureButton`, once, from `GuildRecruiter_GuideMakeSecure`, which returns if `InCombatLockdown()` |
| `GuildRecruiterGuideOpenGuild` | `type="click"`, `clickbutton=GuildMicroButton` | `GuildRecruiter_GuideSync`, which returns at once if `InCombatLockdown()`; set again only if the reference changed |
| `GuildRecruiterGuideShowTab` | `type="click"`, `clickbutton=_G["ChatFrame"..N.."Tab"]`, N = the chat frame `GR_Compat.ListFrame()` returns | same |

`type="click"` is the template's own `SECURE_ACTIONS.click`
(`Blizzard_FrameXML/SecureTemplates.lua:557-564`): `delegate:Click(button)`
after the same `HasAccessConstraints` / `ScriptedInput` checks that a `/click`
macro makes (`SlashCommands.lua:726-743`), without the macro parser or the
restricted `C_Macro.RunMacroText` (UIMacrosDocumentation.lua:41-43). If it
does not work in game, `type="macro"`, `macrotext="/click GuildMicroButton"`
is the drop-in alternative. `GuildMicroButton` exists on Forever: the
Mainline XML loads as `[Family]` (`Blizzard_MicroMenu.toc`;
`Mainline/MainMenuBarMicroButtons.xml:229`) and the Camelot container lists it
(`Camelot/MicroMenuContainerOverrides.lua:11`); its OnClick is
`ToggleGuildFrame()` (`MainMenuBarMicroButtons.lua:1310-1318` ->
`Blizzard_Game/Mainline/Game.lua:1-26` -> `ToggleCommunitiesFrame`). The chat
tab's OnClick is `FCF_Tab_OnClick` (FloatingChatFrame.lua:1697-1735), which
writes `SELECTED_CHAT_FRAME` -- the reason it must run from Blizzard's secure
code and never from ours.

Combat: `PLAYER_REGEN_DISABLED` (just before lockdown) hides all three
(`GuildRecruiter_GuideSecureHide`); `GuildRecruiter_GuideSync` does nothing in
lockdown; `PLAYER_REGEN_ENABLED` re-syncs. In combat the plain big button
(`GuildRecruiterGuide.live.primary`) stands in, and the steps keep their hints;
the warning line says "In combat: the Open and Show buttons come back when it
ends." The secure buttons are also hidden while the window is dragged, closed
or on the setup view. The OnUpdate path reaches them only through
`GuildRecruiter_GuideSync`, i.e. never in lockdown.

**Changes in GuildRecruiter.lua** (no recruiting logic, pacing default,
SavedVariables name or invite counting changed):
- `ns.Compat = GR_Compat` (private table; global fallback), before `VERSION`.
- `GR_Compat.OnInviteSent`: `GR_Compat.lastInvite = p` (read by step 4).
  `GR_Compat.OnTrialError`: `p.trial = true` and `GR_Compat.Tally("trial")`
  (`GR_Compat.Tally = TallyBump`, set after TallyBump). Counts only.
- `GuildRecruiter_ReadyAdd`: `TallyBump("yes")` for a new yes-reply (a count
  only). Instead of popping the Ready panel it calls
  `GuildRecruiter_GuideNotify(name)`, which opens the live guide and returns
  true unless "Don't show again" is ticked; then `GuildRecruiter_ReadyRefresh()`
  still redraws the Rawcruiter tab. Otherwise the panel pops as before.
  `GuildRecruiter_ReadyLoad` the same. The guide's tick calls
  `GuildRecruiter_ReadyRefresh` once a second (expiry + the tab), as the
  panel's own OnUpdate did.
- `Pause`: `GR_Compat.pausedByBlock = quiet` (the quiet form is used only by
  the block report). `GuildRecruiter_PauseBlocked`: `GR_Compat.blockLine = line`.
- New read-only / wrapper globals: `GuildRecruiter_RunState`,
  `GuildRecruiter_StartRun`, `GuildRecruiter_SetMinLevel/SetMaxLevel`,
  `GuildRecruiter_WhisperPreview`, `GuildRecruiter_TodayTally`.
- Slash: `""` and `guide` -> `GuildRecruiter_GuideToggle`; help mentions the
  guide and `chattab`; the load line says "/gr opens the guide, /gr help lists
  commands." Minimap: left-click = guide, shift-left-click = settings.
- Labels (plain words): `MODE_LABEL` invite "Invite only" -> "Direct",
  whisperinvite "Whisper, invite on reply" -> "Whisper first" (whisper stays
  "Whisper only"; used in chat lines, the Settings and A/B dropdowns; `/gr set
  mode` keys unchanged). Settings tab: "Mode:" -> "Contact style:", "Reply:" ->
  "How they reply:", "Invite/contact delay (s)" -> "Delay between whispers (s)",
  "/who delay (s)" -> "Delay between searches (s)", "Random delays
  (anti-detection)" -> "Random delays", "Session cap (0=off)" -> "Max per run
  (0=off)"; the Method label and dropdown are hidden in key-press mode (the
  setting is kept); the three dropdowns moved from x 352 / 186 wide to x 380 /
  160 wide to fit the longer labels; the mode notes use the new words.

**New saved fields** (seed-once in `GuildRecruiter_GuideSeed`, called by every
guide entry point): `guideSeen` (false), `guideDone` (false), `guideCards` ({}),
plus `guidePos` (written only when the window is dragged). New keys inside the
existing tally: `yes`, `trial` (per day and in totals; the Stats tab reads named
fields only, so it ignores them).

**Chat output.** The guide adds no chat lines of its own except one line, once
per session, if the guide itself errors ("guide window error (recruiting is not
affected): ..."). [Print] prints one existing prompt line per name. Everything
else is the existing one-line output of Start, Next, MakeChatTab, ReadyPrune.

**Escape** does not close the guide: adding it to `UISpecialFrames` writes into
a Blizzard table that the Escape handler walks, and that is not worth any risk
to the invite flow. The close button, `/gr` and the minimap button close it.

## 2. Still unverified

There was no game client and no Lua interpreter. The facts from a real
Forever client are only those listed in §1.10, §2.2 and the commits after
`dccd448`.

On 2026-11-05 every Blizzard API, event, template and global the addon uses
was checked against the Forever UI source (the mirror at
`../reference/wow-ui-source-forever`, 1.60.1 build 70790). The results are in
**API_AUDIT.md**. Items that source proves are moved out of these lists into
§2.3. Four mismatches found there are fixed in GR_Compat (§2.3, first list).

Wiki facts come from the pages listed in §4. The wiki is fan-maintained.

| # | Blocker (REQUIREMENTS §3) | Isolated in | What is still open |
|---|---|---|---|
| 1 | /who: throttle and hardware-event rules | `GR_Compat.SendWho` (gated by `GR_Compat.CheckPress`), `GR_Compat.GetNumWhoResults`, `GR_Compat.GetWhoRow`, `GR_Compat.SetWhoToUI`, `GR_Compat.WhoPanel` / `MuteWhoWindow` / `HideWhoWindow`; mode switch `GR_Compat.RequiresHardwareEvent` | The functions, arguments and fields are settled (§2.3), and a key press is known to send the /who. Still open: the server's real throttle, and what a `#hwevent` violation does (an error, a silent drop, or ADDON_ACTION_BLOCKED). A silent drop would show up as a /who timeout and retry. Also open: whether the server parses the text filter `c-"Class"` the same way (Blizzard's Forever Who list filters classes with the `SendWhoFilters` table instead). |
| 2 | Guild invites from addon code | Key-press mode: `GR_Compat.GuildInvite` -> `GR_Compat.SetSecureInvite` (the copy box, `GR_Compat.ShowCopyBox`). Timer-loop client: `GR_Compat.ResolveInvite`, `GR_Compat.RunSlash`. Both: `GR_Compat.CanGuildInvite` | **Answered in game:** `C_GuildInfo.Invite` is forbidden for addon code, from a key press, from a secure `/ginvite` macro, and from `/ginvite` typed into the chat box by the addon, and when the Invite Member box was filled by addon code (`SetItemRef`: the fill worked, the player's Accept was then FORBIDDEN, `Invite()`). The player invites through Blizzard's own Guild > Invite Member dialog, from the Ready list (§1.11); API_AUDIT.md §4 shows how that dialog uses the pasted text. Still open: whether `C_GuildInfo.Invite` accepts "First Surname" (with the space) as pasted or shift-clicked. |
| 3 | WHISPER from addon code | `GR_Compat.SendWhisper` | The signature is settled (§2.3). Still open: what the docs' `HasRestrictions = true` and `RestrictedForMacroChatMessages = true` on `C_ChatInfo.SendChatMessage` mean for an addon WHISPER. The wiki marks only SAY, YELL, CHANNEL and, on Forever, EMOTE as hardware-event. Behaviour under "chat messaging lockdown" (encounters, PvP) is also open. Key-press mode relies on this row: `whisper` and now `whisperinvite` contacts go out from the timer (`GR_Compat.TimerContactModes`, §1.11). **Not yet seen working in game.** If WHISPER turns out to need a press too (a block report naming `C_ChatInfo.SendChatMessage (whisper)`, or whispers that never arrive), set that table to `{}`: the whispers then become Next steps again. |
| 4 | Secret /who fields | `GR_Compat.IsSecret`, `GR_Compat.GetWhoRow`, `GR_Compat.GetNumWhoResults`, and the guards in `GR_OnEvent`, `OnAddonMessage`, `GR_Compat.FilterSystemChat`, `GR_Compat.IsWhoNoise` | Settled by the docs, not yet seen in game: the /who calls carry no secret-return flag. CHAT_MSG_SYSTEM and CHAT_MSG_WHISPER are `SecretInChatMessagingLockdown`; CHAT_MSG_ADDON is not. The guards stay. |
| 5 | Lua core, templates, backdrops | — | Settled (§2.3). |
| 6 | Server chat strings (join/decline, throttle, /who summary) | `GR_Compat.IsThrottleMsg`, `GR_Compat.IsWhoNoise`, `ToPattern` / `JOIN_PAT` / `DECLINE_PAT` (built from `ERR_GUILD_JOIN_S` / `ERR_GUILD_DECLINE_S` with an enUS fallback) | Still open. The mirror has no GlobalStrings.lua, so none of this text is in it. Also open: whether names in those messages are plain, linked (`|Hplayer:...|h`), or carry a surname or realm. §1.11 now relies on the join (and decline) message to count an invite for a Ready-list name: `GR_Compat.PlainName` accepts a link or plain text and keeps spaces, and `GR_Compat.FindKey` also tries the "First-Surname" form, but whether the Forever text matches `JOIN_PAT` at all, and in which name form, is unverified. If it doesn't, only [Done] counts. |

In-game probe (from REQUIREMENTS §3, also in README.txt):

```
/dump select(4, GetBuildInfo())
/run print(C_FriendList and C_FriendList.SendWho, SendWho, GuildInvite, C_GuildInfo and C_GuildInfo.Invite, string.gfind, table.getn, BackdropTemplateMixin)
```

The addon's own load line then shows which invite, /who and whisper calls GR_Compat picked.

### 2.1 Other unverified assumptions (outside the six blockers)

- **Sender and name format with surnames:** the exact form of the
  CHAT_MSG_WHISPER / CHAT_MSG_ADDON sender and of the /who `fullName` for a
  "First Surname" player. Does `Ambiguate(x, "none")` keep the surname? Does it
  equal `GetUnitName("player")`, which `GR_Compat.MyName` now uses? The
  separator constant `CHARACTERNAME_SURNAME_SEPARATOR` is not in the docs.
  Forever's whisper parser accepts both "FirstName-SecondName" and
  "FirstName SecondName" (`Blizzard_ChatFrameBase/Shared/ChatFrameEditBox.lua:84-85`).
- **Muting a Blizzard frame's event:** `MuteWhoWindow` unregisters
  WHO_LIST_UPDATE on `LFGWhoListFrame`, which belongs to a `## Secure: 1` addon.
  The docs mark Register/UnregisterEvent `AddsForbiddenAspects =
  EventRegistrations`, and the mirror doesn't say what that does. The 1.12 and
  Mainline code did the same to FriendsFrame. If Blizzard's Who list
  misbehaves after a run, `/gr hide` turns the muting off.
- **`issecretvalue` / `issecrettable` from addon code:** the docs flag them
  `SecretArguments = "AllowedWhenUntainted"`, and the mirror does not define
  what that means for a tainted caller.
- **`EditBox:SetFont(path, 12, "")`:** the 3-argument form is required (flags
  are not nilable for an EditBox). Whether `""` is a valid `TBFFlags` value is
  not in the mirror.
- **Addon messages:** per the wiki, Forever trial and Veteran accounts cannot
  send addon messages, so guild sync fails silently for them. The per-prefix
  throttle is 10 messages, refilling at 1 per second. The result code
  (`SendAddonMessageResult`, which includes NotInGuild and AddOnMessageLockdown)
  is ignored, as before.
- **Game data left unchanged** (per "no behaviour change"): the hard-coded
  class lists per faction (`FactionLists`: no Horde paladins, no Alliance
  shamans), the 1-60 level range and the minimap icon `INV_Scroll_03`. These
  are vanilla values; if Forever differs, they need updating. Forever's Who
  list caps a reply at `MAX_WHOS_FROM_SERVER = 50`; `CAP_HINT` (49) is only an
  upper bound and the real cap is learned, so this is safe.
- **Defaults:** the code's default contact mode is `invite`, but REQUIREMENTS N5
  asks for `whisper` on first run. Left unchanged because the task said not to
  change defaults; this needs a decision.
- `METHOD_SHORT` still says "GuildInviteByName"/"GuildInvite". These are labels
  in a table nothing reads, so I left them.

### 2.2 Key-press mode: unverified (no client)

**Seen in game:** a key press on the old script binding sent a /who through
`GR_Compat.Press` -> `pcall` -> `C_FriendList.SendWho`, and the results were
read and queued (48 candidates). So the hardware context does cover the
`pcall`, at least for a key-down script binding. A direct
`C_GuildInfo.Invite`, a secure `/ginvite` macro and `/ginvite` typed into the
chat box by the addon were all refused (row 2 above). Invites now go through
the copy box and Blizzard's Invite Member dialog. The secure button still
carries the /who and whisper steps, and its PreClick shows the copy box for an
invite step. Still untested:

- **Up-edge dispatch of the CLICK key binding.** The action fires on the up
  click. Blizzard uses `runOnUp="true"` only on script bindings in this
  source, never on a CLICK binding. So it is unverified that the attribute is
  accepted on a CLICK binding and that the release sends an up click. If the
  key does nothing, the mouse click and the `/click` macro should still work.
- **A key release, and a mouse up, as the hardware event for `SendWho`:** the
  /who now runs in the PreClick of an up click, not on key down as in the
  in-game test.
- **A CLICK binding on a hidden button:** I believe the binding and `/click`
  still click it. The button is hidden when no run is armed, and then a press
  only says "not armed".
- **`SetText` on the secure button in combat** (the label updates every 0.2 s):
  assumed not to be a restricted call. If it were, ADDON_ACTION_BLOCKED would
  name this addon in combat and pause the run.
- **Forever's `SecureActionButtonTemplate` / `UIPanelButtonTemplate` combo:**
  read in the Forever UI source (neither defines a conflicting OnClick), not run.
- **Combat timing:** PLAYER_REGEN_DISABLED fires before lockdown starts (wiki).
- **Hardware context through `pcall` for typed commands:** typed `/gr next`
  runs inside the Enter-key press. Same assumption as above, but for Enter in
  the chat box instead of a binding.
- **ADDON_ACTION_BLOCKED / _FORBIDDEN:** whether a `#hwevent` violation fires
  either of them. The payload itself is settled (§2.3).
- **Key Bindings page:** where the entry shows up. Blizzard's own Bindings.xml
  files use `category=`, not `header=`. Forever's Settings page groups bindings
  by category and draws every `HEADER*` entry as a blank spacer
  (`Blizzard_SettingsDefinitions_Frame/Keybindings.lua:242-249`). So the
  "Guild Rawcruiter" header text is probably not shown, and the in-game hint
  "Key Bindings > Guild Rawcruiter" may not match what the player sees. No
  default key is set, so nothing collides.
- **Floating button position:** anchored under the minimap button, wherever the
  player dragged it. On some minimap layouts it may overlap other UI.
- **Taint:** `/gr next` and the PreClick are plain addon code calling the
  `#hwevent` SendWho. Invites were the protected case, and the addon no longer
  makes or arms them.
- **Server throttle per press:** the community tools pace by hand, so the
  server's real minimum gap between /who queries is unknown. The /who delay
  default (3 s) is unchanged.
- **Lua 5.0 / real 1.12 clients:** the file is Lua 5.1 (`#`, `...` in the main
  chunk), so it cannot load on a 1.12 Lua 5.0 client at all. The timer-loop path
  (`RequiresHardwareEvent == false`) is for clients that run Lua 5.1 but lack
  `C_FriendList.SendWho`. The 1.12 build itself stays on `main`.

### 2.4 Automatic whispers and the Ready list: unverified (no client)

- **Whisper delivery from the timer** (`C_ChatInfo.SendChatMessage(..., "WHISPER",
  nil, "First Surname")`): documented as not hardware-restricted, never seen in
  game. Also open: whether the target must be "First Surname" or
  "First-Surname" (we pass the /who `fullName`, as Blizzard's own Who list does).
- **The reply sender form**: whether CHAT_MSG_WHISPER names a surnamed player
  "First Surname" or "First-Surname" (both are tried, `GR_Compat.FindKey`).
- **Sound and flash**: `C_Sound.PlaySound(SOUNDKIT.READY_CHECK)` and
  `FlashClientIcon()` exist in the Forever source and docs; not heard or seen.
  Both are under `pcall`, so a failure is silent.
- **Shift-click fill from the chat link**: Blizzard's `HandlePlayerLink` fills
  `ADD_GUILDMEMBER` (ItemRefHandlers.lua:24-28). Not tested with our printed link
  and a "First Surname" name. It does NOT fill the Guild Finder variant
  `ADD_GUILDMEMBER_WITH_FINDER_LINK` (opened when the guild has an active
  finder listing, CommunitiesUtil.lua:240-251): there [Copy] is the way. Whether
  the player's Accept after a chat-frame shift-click is allowed is also untested;
  it is Blizzard's own chat code running in the player's click, unlike the
  refused addon `SetItemRef`.
- **Done-on-join**: whether the Forever join text matches `JOIN_PAT` and names
  the player in a form `PlainName` + `FindKey` match (row 6 above). A join of
  someone another officer invited also counts as our invite if that name is on
  our Ready list.
- **Late replies**: `whispered` entries are still dropped after `WHISPER_WAIT`
  (120 s) while a run is running (unchanged), so a "yes" that comes later than
  that during a run is not caught (a run that ends by itself has dropped them
  all; after `/gr stop` the remaining ones still match until the next
  `/gr start`). Not changed here (it is a timing default).
- **Panel layout**: the instruction line, rows and buttons were sized by
  reasoning, not seen; long "First Surname" names may be cut at 180 px.

### 2.5 The guide window: unverified (no client)

Nothing in §1.12 has been seen in game. In particular:

- **The three secure buttons.** `type="click"` with `clickbutton` =
  `GuildMicroButton` (Open) or `ChatFrame<N>Tab` (Show), and the guide's own
  `GuildRecruiterGuideNext` (no action attribute; its PreClick runs the
  press). Read in the Forever source, never run. Open questions: whether the
  click opens the Guild window / selects the tab at all; whether a Guild window
  opened this way, or a tab selected this way, leaves the later Invite Member
  Accept untainted (the whole point; if Accept is refused after using [Open]
  or [Show], hide them and keep the hints); whether `GuildMicroButton` is shown
  and enabled on Forever (`Enum.GameRule.CommunitiesPanelDisabled`); whether a
  disabled or hidden micro button still takes `:Click()`. Fallback if "click"
  does nothing: `type="macro"`, `macrotext="/click GuildMicroButton"`. Every
  step also has its hint ("or press J", "Switch your chat to the Rawcruiter
  tab"), shown in combat and whenever the button is missing.
- **The guide's Next through its secure twin**, i.e. the /who sent from the
  PreClick of a second secure button (`GuildRecruiter_GuidePress` ->
  `GuildRecruiter_SecurePreClick`). Same code path as the minimap Next button,
  which was seen working from a key press; a mouse up-click on a different
  secure button was not tried. The plain stand-in (`GuildRecruiter_Next`, as
  typed `/gr next`) is used in combat.
- **Hiding at PLAYER_REGEN_DISABLED.** Relies on the wiki's "lockdown starts
  after this event" (as `SecureClear` already does). If a secure button is
  still shown when lockdown starts, it stays where it was until combat ends.
- **Layout and strata**: every position and width was reasoned, not seen.
  Default top-right spot vs action bars / quest tracker; whether 344 px of
  text fits each line (long "First Surname" names in "Waiting ..."); the
  secure buttons sit at level guide + 20 in HIGH strata, so another HIGH frame
  dragged over the guide (e.g. the Ready panel) would show them on top. The
  Settings tab's moved dropdowns (x 380, 160 wide) and new label widths.
- **Detectors**: `CommunitiesFrame:IsShown()` as "the Guild window is open"
  (a community page also counts); `StaticPopup_Visible` read from addon code
  (a `securecallfunction` wrapper, expected harmless); `IsVisible()` of the
  Rawcruiter chat frame as "its tab is selected"; `CanGuildInvite()` /
  `GetGuildInfo("player")` right after login; `IsTrialAccount` /
  `IsVeteranTrialAccount` on Forever.
- **Step 4** depends on the `C_GuildInfo.Invite` post-hook (confirmed by the
  player) and on a trial error arriving within 2.5 s (unchanged code).
- **C_UI.Reload from a button** (Reload now) and `FCF_OpenNewWindow` from a
  button click rather than a typed command (the same `GR_Compat.MakeChatTab`).

### 2.3 Settled by the Forever UI source (2026-11-05; evidence in API_AUDIT.md)

**Mismatches found and fixed in GR_Compat:**

- **Who window.** On Forever (game type `camelot`) FriendsFrame does not
  register WHO_LIST_UPDATE. The Who list is `LFGWhoListFrame` inside
  `LFGParentFrame` (load-on-demand Blizzard_GroupFinder_VanillaStyle). The old
  code muted nothing, closed the player's Friends list on every reply, and
  added a WHO_LIST_UPDATE registration to FriendsFrame on restore. Now handled
  by `GR_Compat.WhoPanel`, `MuteWhoWindow` and `HideWhoWindow`.
- **/who routing.** Forever's Who list calls `C_FriendList.SetWhoToUi(false)`
  whenever it closes. `GR_Compat.SendWho` now sets the routing again before
  every query.
- **Chat filter.** `ChatFrame_AddMessageEventFilter` exists only when the CVar
  `loadDeprecationFallbacks` is on, and `ChatFrame_OnEvent` does not exist.
  `GR_Compat.FilterSystemChat` now uses `ChatFrameUtil.AddMessageEventFilter`.
- **Own name.** On Forever `UnitName("player")` returns the first name and the
  surname separately. Blizzard's Forever Who list recognises the player with
  `fullName == GetUnitName("player")`. The new `GR_Compat.MyName` is used for
  the own /who row, the own guild-sync echo and the band split. Before, a
  player with a surname counted their own echo as a peer, and one share of the
  levels was never swept.

**Moved out of the lists above (proven, no change needed):**

- **C_FriendList:** `SendWho(filter, origin, filters)` with `HasRestrictions`.
  `GetNumWhoResults()` returns `(numWhos, totalNumWhos)`. `GetWhoInfo(i)`
  returns a WhoInfo table (fullName, fullGuildName, level, raceStr, classStr,
  area, ...) or nothing. `SetWhoToUi(bool)`. WHO_LIST_UPDATE has no payload.
  The origin `Enum.SocialWhoOrigin.Social` (1) is what Blizzard's own Who list
  sends. The 1.12 globals don't exist on Forever (fallback only).
- **Events:** all eight registered events plus the two block events exist,
  with the payload orders the code reads. ADDON_LOADED is `(addOnName,
  containsBindings)`. CHAT_MSG_ADDON is `(prefix, text, channel, sender, ...)`.
  ADDON_ACTION_BLOCKED / _FORBIDDEN: the docs call the first argument
  `isTainted`, but Blizzard's handler uses it as the addon name, and the
  in-game report matched ours.
- **C_ChatInfo:** `SendChatMessage(message, chatType, languageID, target)`,
  `SendAddonMessage(prefix, message, chatType, target)` -> result enum, and
  `RegisterAddonMessagePrefix(prefix)` -> result enum. The globals
  `SendChatMessage` and `GuildInvite` are deprecation aliases that exist only
  with the `loadDeprecationFallbacks` CVar. `GuildInviteByName`,
  `ChatFrameEditBox` and the 1.12 who globals don't exist. `ChatEdit_SendText`
  is CVar-gated. All of these are timer-loop-only paths.
- **Guild and state:** `CanGuildInvite`, `GetGuildInfo("player")`,
  `IsInGuild`, `InCombatLockdown`, `IsInInstance` (`bool, instanceType`),
  `UnitFactionGroup`, `Ambiguate(name, "none")`, `GetTime`, `time`, `date`,
  `issecretvalue`, `issecrettable`.
- **Templates and FrameXML:** `BackdropTemplate` / `BackdropTemplateMixin`
  (SetBackdrop, SetBackdropColor), `SetColorTexture`, `C_XMLUtil.GetTemplateInfo`
  (may return nothing).
  - `OptionsSliderTemplate` is still defined, in DeprecatedTemplates.xml, with
    `$parentText/Low/High`.
  - `FauxScrollFrameTemplate` and `FauxScrollFrame_Update/GetOffset/OnVerticalScroll(self,
    value, itemHeight, fn)` are in SecureScrollTemplates.
  - `UICheckButtonTemplate` (`$parentText`), `UIPanelButtonTemplate`,
    `InputBoxTemplate`, `UIPanelCloseButton`, `SecureActionButtonTemplate`.
  - Every font object used, every widget method used, `GameTooltip`,
    `UISpecialFrames`, `HideUIPanel`, `Minimap`, `GetCursorPosition`, and all
    texture paths except the icon.
- **StaticPopup:** `StaticPopupDialogs` is a plain global table that addons may
  add to, `StaticPopup_Show(which, text_arg1, ...)` is the current call (there
  is no `StaticPopup_ShowDialog`), and the fields used (`text "%s"`, button1/2,
  OnAccept, OnCancel, timeout, whileDead, hideOnEscape) are read the way the
  code expects.
- **Slash command:** `SlashCmdList` + `SLASH_GUILDRECRUITER1`. The handler gets
  the line already trimmed (`strtrim`), so `/gr black add First Surname` already
  stores "first surname".
- **Bindings:** the label rule `_G["BINDING_NAME_"..name]` (BindingUtil.lua),
  and the binding name `"CLICK <button>:LeftButton"`, the form Blizzard's own
  action buttons pass to `GetBindingKey`.
- **Lua environment:** every `string`, `table` and `math` function the port
  uses (including `string.gmatch` and `math.atan2`), plus `tinsert`, `tremove`
  and `random`, is used by Blizzard UI code in this source.
- **Superseded by the in-game results** (the code no longer does these):
  `/ginvite` as a secure macro; attributes set in PreClick applying to the same
  click; a macro that mixes `/gr invite` and `/click`.

## 3. What could not be ported safely

1. **The automatic /who sweep needs a hardware event, and automatic invites are impossible (blockers 1 and 2).** The /who waits for one Next press each (§1.9, confirmed in game). Guild invites cannot be sent by addon code at all on Forever (every form refused in game, §1.10, §1.11): the addon prompts, keeps the Ready list, and the player sends each invite in Blizzard's Guild > Invite Member box, then presses Done. What it costs the player in `whisperinvite` mode: one press per /who, and per "yes" reply: open Invite Member, shift-click the name in chat (or Copy + paste), Accept, Done. Whispers and reply handling run by themselves (§1.11; whisper delivery not yet seen in game). In invite mode each prompt still takes a press. Block reports pause the run.
2. **The "chat" invite method** (`/ginvite` through `ChatEdit_SendText`) runs a slash command from addon code. It is kept only for timer-loop clients. In key-press mode it is never used.
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

### 4.3 Automatic whispers and Ready list checks (same tools)

- **Parser, `0c17add` to the working tree:** syntax OK to syntax OK (274 to 308
  functions). Max upvalues 31 to 31 (the slash handler); Start 30,
  BuildSettingsPanel 28, GR_OnUpdate 27, GR_OnEvent 20, ProcessWho 19, all
  unchanged (5.1 limit 60). Main-chunk locals 171 to 171 (limit 200): the new
  code is global `GuildRecruiter_*` functions and `GR_Compat` fields only.
  Generic-for over a non-call: 0.
- **Globals:** new reads `C_Sound`, `PlaySound`, `SOUNDKIT`, `FlashClientIcon`
  (all in `GR_Compat.Alert`, feature-detected), `next` (Lua), the frame name
  `GuildRecruiterReadyPanel` (made by `CreateFrame`), and the new
  `GuildRecruiter_Ready*`, `GuildRecruiter_HeadMode` and
  `GuildRecruiter_TimerMode` functions, each of which is also written in the
  file. No global was removed.
- **Call graph, specialised to key-press mode** (the timer-loop-only blocks cut,
  each cut matching exactly once: the timer /who in GR_OnUpdate, the
  `ResolveInvite` send in `GR_Compat.GuildInvite`, the label in `InviteApiName`,
  the direct invite in `InviteOne`, and Drain's two `not hw` contact branches):
  - `GR_Compat.SendWho`: only from the secure Next button's PreClick and the
    slash handler (`/gr next`), both through `GuildRecruiter_NextPress` ->
    `SendNextWho`. No OnUpdate, OnEvent or chat-filter path.
  - `ResolveInvite`, `InviteByChat`, `RunSlash`: no path from any root.
  - `GuildRecruiter_DealHead` (the A/B roll): only from the run timer's
    `Drain` (when the head is due) and from `ContactHead` (PreClick, `/gr next`,
    Drain). The Next button's label OnUpdate, the tooltips and `/gr status`
    reach only the read-only `GuildRecruiter_HeadMode`.
  - `GR_Compat.ShowCopyBox` (it takes keyboard focus): from the Ready panel's
    [Copy] / [Copy next] OnClick and from a press's invite prompt
    (`SetSecureInvite`). No OnEvent path, so a reply never steals focus.
  - `GuildRecruiter_ReadyAdd`: from OnEvent (CHAT_MSG_WHISPER, the yes-reply),
    from the press (prompts) and from the timer only through `Contact`'s invite
    branch, which the timer never takes (`TimerMay` is true only for the whisper
    modes, false for Invite all).
  - Negative test: injecting `SendNextWho(); GuildRecruiter_DealHead()` into the
    CHAT_MSG_WHISPER branch of a scratch copy made the script report both new
    OnEvent paths.
- **grep (code lines, comments stripped):** `C_GuildInfo.Invite`,
  `GuildInviteByName` and `GuildInvite` appear only in `GR_Compat.ResolveInvite`;
  `ChatEdit_SendText` / `ChatFrameEditBox` / `.editBox` only in `GR_Compat.RunSlash`
  (both timer-loop only, unreachable in key-press mode per the call graph).
  `SetItemRef`, `StaticPopup_Visible`, `ChatFrame_OpenChat`, `OpenChat`,
  `InsertLink`, `SendTell` and any `StaticPopupN` / `ADD_GUILDMEMBER` frame: no
  code hits (comments only). The only `StaticPopup_Show` is the addon's own
  `GUILDRECRUITER_CONFIRM` dialog, as before.
- `file`: GuildRecruiter.lua and README.txt ASCII text, LF, 0 CR bytes.

### 4.4 Guide window checks (same tools)

- **Parser, `94ef08a` to the working tree.** GuildRecruiter.lua: syntax OK to
  syntax OK (323 to 329 functions); max upvalues 31 to 31 (the slash
  handler), Start 30, BuildSettingsPanel 28, GR_OnUpdate 27, GR_OnEvent 20,
  all unchanged (5.1 limit 60); main-chunk locals 171 to 171 (limit 200: the
  new code is globals and `GR_Compat` fields; the `ns` local lives in a `do`
  block). GuildRecruiterGuide.lua (new): syntax OK, 76 functions, max
  upvalues 5, main-chunk locals 21. Generic-for over a non-call: 0 in both.
- **Globals.** GuildRecruiter.lua new reads: `select` (Lua),
  `GuildRecruiter_GuideNotify`, `GuildRecruiter_GuideToggle` (both written by
  the guide file); new writes: the six wrapper/read-only globals of §1.12 and
  `GuildRecruiter_Compat` (only without a private table). No global was
  removed. The guide file reads, besides its own and the main file's globals,
  only: `C_UI`, `ReloadUI` (Reload now), `CommunitiesFrame`, `GuildFrame`
  (`:IsShown()` only), `StaticPopup_Visible` (call, read-only), `GuildMicroButton`
  and `_G["ChatFrame<N>Tab"]` (used only as the `clickbutton` value on OUR
  secure button), `IsInGuild`, `GetGuildInfo`, `IsTrialAccount`,
  `IsVeteranTrialAccount`, `GetTime`, `CreateFrame`, `UIParent` (parent and
  anchor of our own frames), `GameTooltip` (our tooltips), `DEFAULT_CHAT_FRAME`
  (the one error line), and Lua's own `string`, `table`, `math`, `pairs`,
  `pcall`, `tinsert`, `tonumber`, `tostring`, `type`. It writes no Blizzard
  global and no Blizzard frame.
- **Grep of the guide code (comments stripped).** No `SetItemRef`,
  `StaticPopup_Show`, `OnAccept`, `.Invite`, `GuildInvite`, `ginvite`,
  `ChatEdit_*`, `editBox`, `RunMacroText`, `macrotext`, `FCF_*`, `InsertLink`,
  `SendChatMessage`/`SendWho` calls (the two string hits are `BlockWhat`'s
  text matches), `HookScript`, `hooksecurefunc` or `UISpecialFrames`.
  `SetScript` is called only on frames this file creates. Exactly five
  `SetAttribute` calls, all on our secure buttons: `useOnKeyDown` in
  `GuildRecruiter_GuideSecureButton` (reached only from
  `GuildRecruiter_GuideMakeSecure`, which returns in lockdown) and
  `type`/`clickbutton` twice in `GuildRecruiter_GuideSync` (returns at once in
  lockdown).
- **Call graph** (`callgraph3.py`, branch-blind, run on `specialise.py`'s
  key-press copy of GuildRecruiter.lua concatenated with the guide file; all six
  cuts matched once). Sinks `GR_Compat.SendWho`, `SetSecureInvite`,
  `ResolveInvite`, `InviteByChat`, `RunSlash`:
  - `GR_Compat.SendWho`: only from the minimap Next button's PreClick, the
    guide's secure Next PreClick, the guide's plain big button's OnClick and
    the slash handler (`/gr next`). No OnUpdate, OnEvent, OnShow or
    chat-filter path.
  - `ResolveInvite`, `InviteByChat`, `RunSlash`: no path from any root.
  - `SetSecureInvite` (which now only prints the link): from the same press
    roots, plus the pre-existing run-timer `Drain -> ContactHead` whisper path
    (`TimerMay`, §4.2). The guide adds no timer or event path.
  - `GuildRecruiter_GuidePress` is referenced only by the guide's plain
    OnClick and secure PreClick. `GuildRecruiter_GuideSecureHide` only from the
    guide's OnEvent (PLAYER_REGEN_DISABLED). `GuildRecruiter_GuideSync` from
    the guide's drag/hide handlers and `GuildRecruiter_GuideRefresh` (OnShow,
    OnUpdate, OnEvent), always behind the lockdown check.
  - Negative test: calling `GuildRecruiter_GuidePress` from
    `GuildRecruiter_GuideTick` in a scratch copy made the script report two
    new OnUpdate paths to `GR_Compat.SendWho`.
- **Release zip.** The workflow's rsync already ships every file except
  `.git*`, `.github`, `*.md` and `README*`, so GuildRecruiterGuide.lua ships.
  A new step fails the job if any .lua/.xml the .toc lists, or Bindings.xml,
  is missing from the staged folder (simulated locally: passes; with the
  guide file removed it reports it). The YAML parses.
- `file`: GuildRecruiter.lua, GuildRecruiterGuide.lua and the .toc are ASCII
  text, LF, 0 CR bytes.

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
