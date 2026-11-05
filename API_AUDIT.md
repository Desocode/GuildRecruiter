# GuildRecruiter: API audit against the Forever UI source

Date 2026-11-05. Branch `forever`, on top of `520c586`. Line numbers in the
"used at" column are lines of the working-tree `GuildRecruiter.lua`, after the
fixes below.

**Reference.** The community mirror of Blizzard's Forever UI source,
`/home/deso/wow-addons/reference/wow-ui-source-forever` (branch `forever`, commit
`eac30af`, "1.60.1 (70790)"). I only read it. Reference paths below are relative
to `Interface/AddOns/`. "Docs" means `Blizzard_APIDocumentationGenerated/`.

**What the reference can and cannot prove.** It holds the Blizzard UI Lua/XML and
the generated API docs: names, argument and return lists, event payloads, and
some restriction flags. It does **not** hold `GlobalStrings.lua` (no `ERR_*` or
`WHO_*` text anywhere in the tree), the game data (icons, class lists, level
cap) or the server's behaviour. The docs don't prove restrictions either.
`C_GuildInfo.Invite` has no restriction flag in GuildInfoDocumentation.lua:170-178,
yet the client forbids it for addons.

**Forever is game type `camelot`.** The tocs load `[Family]` (= `Mainline`)
files plus `[Game]` (= `Camelot`) overrides marked `[AllowLoadGameType camelot]`,
and they drop files marked `[ExcludeLoadGameType camelot]`. The evidence that
camelot is Forever: `Blizzard_GlueParent/Mainline/GlueParent.lua:193-194`
(`WOW_PROJECT_CAMELOT`), the `*_Camelot` constant tables in the docs (for example
LevelConstantsDocumentation.lua:6), the `_Camelot.toc` client suffix in
REQUIREMENTS §2, and this mirror's branch. So for every frame I checked the
Camelot file first. **That is where two of the four mismatches come from:** Forever
replaces some Mainline frames.

## Summary

| Verdict | Count |
|---|---|
| OK | 70 |
| MISMATCH-fixed | 4 |
| UNVERIFIED | 8 |

These are table rows in §2. One more row is `UnitAffectingCombat`, which the
addon does not use. §3 lists 9 open questions that only the client or the
server can settle. Some of them belong to rows marked OK, where the call
shape is proven but its runtime behaviour is not.

The 4 mismatches, all fixed inside GR_Compat (plus small edits at its call sites):

1. **Who window frame.** The code muted, and hid, `FriendsFrame`. On Forever
   FriendsFrame is not the Who window. The Who window is `LFGWhoListFrame` in
   `LFGParentFrame`. Fixed in `GR_Compat.WhoPanel`, plus new
   `GR_Compat.MuteWhoWindow` and `GR_Compat.HideWhoWindow`.
2. **The /who reply routing gets reset.** Forever's Who list calls
   `C_FriendList.SetWhoToUi(false)` whenever it closes. The code set the routing
   only once, at Start. Fixed: `GR_Compat.SendWho` sets it again before every query.
3. **Chat filter API.** On Forever `ChatFrame_AddMessageEventFilter` exists only
   as a deprecation alias behind a CVar, and the fallback `ChatFrame_OnEvent` does
   not exist at all. Fixed: `GR_Compat.FilterSystemChat` uses
   `ChatFrameUtil.AddMessageEventFilter`.
4. **The player's own name.** On Forever `UnitName("player")` is only the first
   name. Fixed: new `GR_Compat.MyName` (`GetUnitName("player")`), used by the four
   "is this me?" checks.

Two small items from the brief:

- (a) `/gr black add|remove <name>` needed **no change**. Its pattern is already
  `^(%a+)%s*(.*)$` (line 3629), so the name is the rest of the line ("first
  surname", lower-cased like every blacklist key). The client trims the line
  before it calls the slash handler: `hash_SlashCmdList[command](strtrim(msg),
  self)` (`Blizzard_ChatFrameBase/Shared/ChatFrameEditBox.lua:269-271`). The
  pattern the brief quoted, `^(%a+)%s+(%S+)$`, belongs to `/gr set` (line 3650),
  whose value is one word on purpose. `noword` and `yesword` use the same
  rest-of-line pattern as `black`.
- (b) The Next button now shows the whole step text in its "ready in" form, for
  example "Invite First Surname ready in 2s" (line 1968). Before, it took
  `string.match(short, "^%S+")`, which is only the verb: "Invite ready in 2s".

## 1. Mismatches fixed (evidence and change)

### 1.1 Who window: LFGWhoListFrame, not FriendsFrame

- `Blizzard_FriendsFrame/Blizzard_FriendsFrame.toc` loads `[Game]\FriendsFrame.lua
  [AllowLoadGameType camelot]` and excludes the Mainline file on camelot.
  `Blizzard_FriendsFrame/Camelot/FriendsFrame.lua:287-311` (`FriendsFrame_OnLoad`)
  registers no `WHO_LIST_UPDATE`. Mainline's does (`Mainline/FriendsFrame.lua:297`),
  and Mainline's `WhoList_Update` ends in `ShowUIPanel(FriendsFrame)` (`:1104`).
- The Forever Who list is `LFGWhoListFrame`
  (`Blizzard_GroupFinder_VanillaStyle/Mainline/WhoList.xml:89`, parent
  `LFGParentFrame`). It registers the event (`WhoList.lua:199`) and handles it
  (`:211`). `UpdateWhoList` ends with `PanelTemplates_SetTab(LFGParentFrame, 3);
  ShowUIPanel(LFGParentFrame)` (`:274-275`). The frame is shown only while the
  Who tab is selected (`Blizzard_LFGVanilla_ParentFrame.lua:22`).
- That addon is `LoadOnDemand: 1` and `Secure: 1`
  (`Blizzard_GroupFinder_VanillaStyle.toc:4,6`). It is loaded by
  `Blizzard_LFGUtil/Camelot/LFGUtil.lua:1-5` when the group finder style is
  Vanilla.
- What the old code did on Forever: muting FriendsFrame did nothing, so the
  LFG window still popped on every reply. Each reply also set `hideSoon`, so
  `HideUIPanel(FriendsFrame)` closed the player's **Friends list** whenever it
  was open. And `SuppressWho(false)` *registered* `WHO_LIST_UPDATE` on Forever's
  FriendsFrame, which Blizzard never does.
- Fix (lines 236-280, 722-737, 1619):
  - `GR_Compat.WhoPanel()` returns `LFGWhoListFrame, LFGParentFrame` when it
    exists, else `FriendsFrame, FriendsFrame`.
  - `GR_Compat.MuteWhoWindow(on)` unregisters the event only on a frame that
    has it registered (`Frame:IsEventRegistered`, Docs
    SimpleFrameAPIDocumentation.lua:740-756). Restore re-registers exactly that
    frame.
  - `GR_Compat.HideWhoWindow()` closes the window only if the frame is
    showing and is the real Who frame.
  - `SuppressWho` keeps its flag and setting logic and calls MuteWhoWindow.
- On 1.12 and Mainline the behaviour is unchanged: FriendsFrame registers
  the event, so it is the frame that gets muted and hidden.

### 1.2 /who routing is reset when Forever's Who list closes

- `LFGWhoListMixin:OnShow` calls `C_FriendList.SetWhoToUi(true)`, and `:OnHide`
  calls `SetWhoToUi(false)` (`Blizzard_GroupFinder_VanillaStyle/Mainline/WhoList.lua:249-255`).
- The code called `SetWhoToUi(true)` once, at Start (`ForceWhoToEvent`). If the
  player opened and closed the Who tab during a run, later replies would go to
  chat with no `WHO_LIST_UPDATE`, so every /who would time out and be retried.
- Fix (lines 166-177): `GR_Compat.SendWho` calls `GR_Compat.SetWhoToUI(true)`
  right before each `C_FriendList.SendWho`. It is the same call ForceWhoToEvent
  makes. Pacing is unchanged.

### 1.3 Chat message filter: ChatFrameUtil.AddMessageEventFilter

- `Blizzard_DeprecatedChatInfo/Deprecated_ChatFrame.lua:4` returns early unless
  the CVar `loadDeprecationFallbacks` is on. Only then does `:51` define
  `ChatFrame_AddMessageEventFilter = ChatFrameUtil.AddMessageEventFilter`.
- The real function is `ChatFrameUtil.AddMessageEventFilter(event, callback)`
  (`Blizzard_ChatFrameBase/Shared/ChatFrameFilters.lua:202-205`). The callback
  is called as `(chatFrame, event, ...)`, and a true first return drops the line
  (`:138-170`). The callback is called only when the arguments are readable,
  `canaccessvalue(...)` (`:114-118`).
- `ChatFrame_OnEvent`, the code's fallback, is defined nowhere in the Forever
  UI. So with the CVar off, the quiet-/who filter silently did nothing.
- Fix (lines 497-523): prefer `ChatFrameUtil.AddMessageEventFilter`, then the
  global, then the old wrap. The callback is unchanged; its contract already
  matched.

### 1.4 The player's own name on Forever

- `Blizzard_FrameXMLUtil/Blizzard_FrameXMLUtil.toc:58-59` loads
  `Camelot\NameUtil.lua` on camelot. There `local name, surname = UnitName(unit)`
  is used, and the full name is `name..Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR..surname`
  (`Camelot/NameUtil.lua:4-11, 23-29`). So `UnitName("player")`'s first return is
  only the first name. (The docs still list the returns as `(unitName,
  unitServer)`, UnitDocumentation.lua:2489-2504. Blizzard's own Forever code
  reads them as name and surname.)
- Blizzard's Forever Who list finds the player's own row with
  `info.fullName == GetUnitName("player")`
  (`Blizzard_GroupFinder_VanillaStyle/Mainline/WhoList.lua:94`).
  `GetUnitName(unit, showSurname)` is `NameUtil.FormatUnitNameForDisplay`
  (`Blizzard_UnitFrame/Mainline/UnitFrame.lua:1094-1096`, loaded on camelot as
  `[Family]\UnitFrame.lua`, toc line 26).
- Effect of the old code for a player with a surname: `name == me` failed for
  the own /who row, and `sender == me` failed for the addon's own guild-sync
  echo. The recruiter then counted itself as a peer ("First Surname" next to
  "First"), and the band split cut the level range into one share too many.
  The share assigned to the phantom peer was never swept.
- Fix (lines 144-160, 927, 948, 970, 1193): `GR_Compat.MyName()` returns
  `GetUnitName("player")` when that is a non-empty, non-secret string, else
  `UnitName("player")`. `ActiveNames`, `RecomputeBand`, `OnAddonMessage` and
  `ProcessWho` use it. Without a surname it returns the same value as before.

## 2. Full audit table

### 2.1 /who (C_FriendList)

| API | Used at | Reference finding | Verdict |
|---|---|---|---|
| `C_FriendList.SendWho(filter, origin)` | 165-184 | Docs FriendListDocumentation.lua:330-342: `(filter cstring, origin number nilable, filters SendWhoFilters nilable)`, `HasRestrictions = true`. Works from a key press in game. | OK |
| `Enum.SocialWhoOrigin.Social` | 176 | Docs SocialConstantsDocumentation.lua:6-16, Social = 1. Blizzard's own Who list sends Social (WhoList.lua:178, 189); `/who` sends Chat (`Blizzard_ChatFrameBase/Shared/SlashCommands.lua:1116`). | OK |
| `C_FriendList.GetNumWhoResults()` | 188-199 (read at 1194) | FriendListDocumentation.lua:171-180: returns `(numWhos, totalNumWhos)`. The code reads the first, the rows actually returned. Precondition `RequiresFriendList`, FailureMode ReturnNothing (:705-708), so it may return nothing; the nil check covers that. | OK |
| `C_FriendList.GetWhoInfo(i)` -> WhoInfo | 206-224 | FriendListDocumentation.lua:202-215 (`MayReturnNothing`). WhoInfo :685-697: `fullName, fullGuildName, level, raceStr, classStr, area` (+ filename, gender, timerunningSeasonID). Field names match. `fullGuildName` is non-nilable, so a guildless player has "". | OK |
| `C_FriendList.SetWhoToUi(bool)` | 228-234 | FriendListDocumentation.lua:395-404 (`whoToUi bool`). | OK |
| SetWhoToUi reset by Blizzard's Who list | 166-174 | WhoList.lua:249-255 (OnShow true, OnHide false). See §1.2. | MISMATCH-fixed |
| `WHO_LIST_UPDATE` | 1461 (handler 1394) | FriendListDocumentation.lua:639-643: no payload, SynchronousEvent. | OK |
| Who window frame (was `FriendsFrame`) | 236-280, 722-737, 1619 | See §1.1. | MISMATCH-fixed |
| /who row cap (`CAP_HINT = 49`) | 598 | `MAX_WHOS_FROM_SERVER = 50` (WhoList.lua:4; Mainline/FriendsFrame.lua:11). CAP_HINT is only an upper bound and the real cap is learned, so the sweep can only over-subdivide. Unchanged. | OK |
| /who secret status | 206-224 | GetWhoInfo / GetNumWhoResults carry no secret-return flag (FriendListDocumentation.lua:171-215 has only `SecretArguments`). Compare UnitName's `SecretWhenUnitNameIdentityRestricted` (UnitDocumentation.lua:2491). The guards are kept. | OK |
| 1.12 globals `SendWho`, `GetNumWhoResults`, `GetWhoInfo`, `SetWhoToUI` | 180-181, 192-193, 213-214, 231-232 | Defined nowhere in the Forever UI or its Deprecated_* shims. Reached only when `C_FriendList` is absent, so never on Forever. | OK |
| /who filter text `lo-hi c-"Class"` | 1126-1132 | The `WHO_TAG_*` strings are GlobalStrings (not in the mirror). Blizzard's Forever Who list filters by class through the `SendWhoFilters` table (WhoList.lua:178; `GetWhoFilters`), not text. The server's text parser is not in the reference. | UNVERIFIED |

### 2.2 Events

| Event | Used at | Reference finding | Verdict |
|---|---|---|---|
| `ADDON_LOADED` | 1459, 1384-1393 | Docs AddOnsDocumentation.lua:389-398: `(addOnName, containsBindings)`. | OK |
| `VARIABLES_LOADED` | 1460 | Docs SystemDocumentation.lua:260-264. | OK |
| `CHAT_MSG_SYSTEM` | 1463, 1399-1427 | Docs ChatInfoDocumentation.lua:2452-2477: `text` first; `SecretInChatMessagingLockdown = true`, so the issecret guard is needed. | OK |
| `CHAT_MSG_WHISPER` | 1464, 1428-1444 | ChatInfoDocumentation.lua:2592-2617: `(text, playerName, ...)`; `SecretInChatMessagingLockdown = true`. | OK |
| `CHAT_MSG_ADDON` | 1462, 1398, 966-991 | ChatInfoDocumentation.lua:801-817: `(prefix, text, channel, sender, target, zoneChannelID, localID, name, instanceID)`. No secret flag. | OK |
| `PLAYER_REGEN_DISABLED` / `_ENABLED` | 1465-1466 | Docs UnitDocumentation.lua:3885-3895: no payload. | OK |
| `ADDON_ACTION_BLOCKED` / `_FORBIDDEN` | 111-114, 120-133, 1445-1447 | Docs RestrictedActionsDocumentation.lua:75-95 name the payload `(isTainted, function)`. But Blizzard's own handlers treat the first argument as the **addon name**: `StaticPopup_Show("ADDON_ACTION_FORBIDDEN", arg1, nil, arg1)` (`Blizzard_Game/Shared/EventImplementation.lua:90-91`), whose OnAccept is `C_AddOns.DisableAddOn(data)` (`Blizzard_StaticPopup_Game/GameDialogDefs.lua:718-723`); `AddonTooltip_ActionBlocked(arg1)` (`Blizzard_Game/Mainline/EventImplementation.lua:375-377`). The in-game report matched our folder name. | OK |

### 2.3 Chat, whisper, addon messages, slash commands

| API | Used at | Reference finding | Verdict |
|---|---|---|---|
| `C_ChatInfo.SendChatMessage(text, "WHISPER", nil, target)` | 438-446 | Docs ChatInfoDocumentation.lua:564-576: `(message, chatType, languageID, target)`; `HasRestrictions = true`, `RestrictedForMacroChatMessages = true`. Blizzard's `/r` uses the same shape (SlashCommands.lua:886). Signature matches; what the restriction covers is not in the docs (§3). | OK |
| `SendChatMessage` global (fallback) | 441-442 | Deprecation alias only when the CVar is on (`Blizzard_DeprecatedChatInfo/Deprecated_ChatInfo.lua:4, 8-10`). C_ChatInfo is tried first. | OK |
| `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` | 461-467, 1468 | ChatInfoDocumentation.lua:469-482; returns `RegisterAddonMessagePrefixResult` (ChatConstantsDocumentation.lua:133-145). The result is ignored, as before. | OK |
| `C_ChatInfo.SendAddonMessage(prefix, text, "GUILD")` | 469-477 | ChatInfoDocumentation.lua:516-530: `(prefix, message, chatType, target)`, `SecretArguments = "NotAllowed"`; returns `SendAddonMessageResult` (ChatConstantsDocumentation.lua:147-167: AddonMessageThrottle 3, NotInGuild 10, AddOnMessageLockdown 11, ...). The result is ignored. | OK |
| `RegisterAddonMessagePrefix` / `SendAddonMessage` globals | 465, 473 | Not defined in the Forever UI. Fallback only. | OK |
| `ChatFrame_AddMessageEventFilter` | 508-521 | See §1.3. | MISMATCH-fixed |
| `ChatFrame_OnEvent` (fallback wrap) | 516-521 | Not defined anywhere in the tree. The fallback is type-checked, so it is skipped. | OK |
| `DEFAULT_CHAT_FRAME:AddMessage` | 333, 709 | `DEFAULT_CHAT_FRAME = ChatFrame1` (`Blizzard_ChatFrameBase/Shared/ChatFrameUtil.lua:19`). | OK |
| `ChatEdit_SendText`, `ChatFrameEditBox`, `.editBox` (`RunSlash`) | 421-435 | `ChatEdit_SendText` exists only as the CVar-gated alias (Deprecated_ChatFrame.lua:124); `ChatFrameEditBox` is not defined. Reached only on timer-loop clients, never on Forever. | OK |
| `SlashCmdList["GUILDRECRUITER"]` + `SLASH_GUILDRECRUITER1` | 3494-3495 | `_G.SlashCmdList = {}` (`Blizzard_ChatFrameBase/Shared/SlashCommandsRegistry.lua:16`); imported by `_G["SLASH_"..k..i]` (ChatFrameUtil.lua:808-832); called with the trimmed text (ChatFrameEditBox.lua:269-271). No Blizzard `/gr`. | OK |
| `Ambiguate(name, "none")` | 140 | Docs PlayerScriptDocumentation.lua:22-35 `(fullName, context)`; Blizzard uses context "none" (`Blizzard_AutoComplete/AutoComplete.lua:440`). | OK |
| Self name `UnitName("player")` | 927, 948, 970, 1193 (via MyName) | See §1.4. | MISMATCH-fixed |
| `GetUnitName("player")` (new) | 154-160 | `Blizzard_UnitFrame/Mainline/UnitFrame.lua:1094-1096`; used the same way at WhoList.lua:94. | OK |

### 2.4 Guild

| API | Used at | Reference finding | Verdict |
|---|---|---|---|
| `IsInGuild()` | 920, 943, 1623, 1733, ... | Docs PlayerScriptDocumentation.lua:1324-1330 (bool). | OK |
| `GetGuildInfo("player")` | 1007 | Not in the docs. Blizzard calls it the same way, first return = guild name (`Blizzard_UIPanels_Game/Mainline/TabardFrame.lua:91`, `Blizzard_FrameXML/InstanceDifficulty.lua:219`). | OK |
| `CanGuildInvite()` | 413-416, 1716 | Not in the docs. Blizzard's Forever UI calls it: `Blizzard_UnitPopup/Mainline/UnitPopupButtons.lua:327` (loaded on camelot, `Blizzard_UnitPopup.toc` `[Family]\UnitPopupButtons.lua [AllowLoadGameType standard, camelot]`) and `Blizzard_Communities/CommunitiesMemberList.lua:144`. | OK |
| `C_GuildInfo.Invite(name)` | 292 (ResolveInvite only) | Docs GuildInfoDocumentation.lua:170-178, with no restriction flag, yet forbidden for addons in game. Blizzard's own callers: ADD_GUILDMEMBER (§4) and `/ginvite` (SlashCommands.lua:1083-1092). Addon code never calls it on Forever. | OK |
| `GuildInvite` / `GuildInviteByName` | 289-295 | `GuildInvite = C_GuildInfo.Invite` only behind the CVar (`Blizzard_DeprecatedGuildScript/Deprecated_GuildScript.lua:4, 9`); `GuildInviteByName` is not defined. Timer-loop path only. | OK |
| Player menu has no "Invite to Guild" | (player test) | Camelot player menus (`Blizzard_UnitPopup/Camelot/UnitPopupMenus.lua:1-130`) have no guild-invite entry. `UnitPopupGuildInviteButtonMixin` (Mainline/UnitPopupButtons.lua:304-328, `CanShow = CanGuildInvite()`) appears only in the community-list menus. This matches the player's test. | OK |
| `ERR_GUILD_JOIN_S` / `ERR_GUILD_DECLINE_S` | 893-894 (matched at 1411, 1420) | GlobalStrings.lua is not in the mirror; neither name appears anywhere in the tree. The code builds its patterns from the client's own strings at run time, with enUS fallbacks. Whether the name in the message is plain, linked, or has a surname or realm is unknown. | UNVERIFIED |
| Throttle text (`IsThrottleMsg`: "too quickly", "too many", "wait"+"invit") | 491-495, 1403 | No throttle wording in the mirror (`ERR_CHAT_THROTTLED`, `ERR_GUILD_*` absent; only `ERR_GENERIC_THROTTLE` is referenced, at `Blizzard_AuctionHouseUI/Shared/Blizzard_AuctionHouseSellFrame.lua:488`). | UNVERIFIED |
| /who summary text (`IsWhoNoise`: "Players Total", "There are N", "No players") | 482-488 | `WHO_FRAME_TOTAL_TEMPLATE` is used (WhoList.lua:264), but its text is in GlobalStrings (absent). | UNVERIFIED |

The brief also named `ERR_GUILD_DECLINE_AUTO_S`, `ERR_GUILD_INVITE_S`,
`ERR_GUILD_PLAYER_NOT_FOUND_S` and `ERR_CHAT_THROTTLED`. The addon matches none
of them, and none appears in the mirror.

### 2.5 Unit, state, time, secrets

| API | Used at | Reference finding | Verdict |
|---|---|---|---|
| `InCombatLockdown()` | 66 | Docs RestrictedActionsDocumentation.lua:45-53 (bool). | OK |
| `IsInInstance()` | 1343-1344 | Docs InstanceDocumentation.lua:170-178: `(isInInstance bool, instanceType)`. The code treats a true first return as "inside". | OK |
| `UnitFactionGroup("player")` | 1725 | Docs UnitDocumentation.lua:1207-1221 (factionGroupTag). | OK |
| `UnitAffectingCombat` | not used | Combat comes from PLAYER_REGEN_* plus `InCombatLockdown`. | (not used) |
| `GetTime()` | 95, 130, 696, ... | Docs SystemTimeDocumentation.lua:57-63. | OK |
| `time()`, `date("%Y%m%d")` | 747, 834, ... | Blizzard uses both (`Blizzard_FriendsFrame/Mainline/FriendsFrame.lua:1716`; `Blizzard_HousingDashboard/Blizzard_HousingDashboardCollection.lua:96`). | OK |
| `issecretvalue`, `issecrettable` | 42-43 | Docs FrameScriptDocumentation.lua:270-302 (bool). | OK |
| Faction class lists, level range 1-60 | 1723-1730, 752-753 | Game data, not in the UI source. | UNVERIFIED |

### 2.6 Frames, templates, widget methods

| API | Used at | Reference finding | Verdict |
|---|---|---|---|
| `BackdropTemplate` / `BackdropTemplateMixin` | 528-530 | `Blizzard_SharedXML/Backdrop.xml:5`, `Backdrop.lua:142` (toc :177). | OK |
| `:SetBackdrop`, `:SetBackdropColor` | 531-536 | Backdrop.lua:336, 406. | OK |
| `Texture:SetColorTexture(r,g,b,a)` | 539-541 | Docs SimpleTextureBaseAPIDocumentation.lua:403-415. | OK |
| `C_XMLUtil.GetTemplateInfo(name)` | 545-548 | Docs XMLUtilDocumentation.lua:11-25 (`MayReturnNothing`, hence the `~= nil` test). | OK |
| `OptionsSliderTemplate` and its Text/Low/High | 2480-2486 | Still defined: `Blizzard_FrameXML/DeprecatedTemplates.xml:37` (toc :45). It inherits `UISliderTemplateWithLabels`, whose children are `$parentText/Low/High` with parentKeys Text/Low/High (`Blizzard_SharedXML/Mainline/SharedUIPanelTemplates.xml:345-358`). | OK |
| `FauxScrollFrameTemplate` | 562 | `Blizzard_SharedXML/SecureScrollTemplates.xml:158` (toc :185). | OK |
| `FauxScrollFrame_Update`, `_GetOffset`, `_OnVerticalScroll` | 569-579 | SecureScrollTemplates.lua:158, 236, 227-234. `(self, value, itemHeight, updateFunction)`, then `updateFunction(self)`. | OK |
| `UICheckButtonTemplate` caption | 2498-2501 | `Blizzard_SharedXML/Shared/Button/CheckButtonTemplates.xml:50-61` (`$parentText`, parentKey Text). | OK |
| `UIPanelButtonTemplate` | 2085, 2289, ... | SharedUIPanelTemplates.xml:315. | OK |
| `InputBoxTemplate` | 2335, 2487, 2510, 3012 | `Blizzard_SharedXML/Shared/InputBox/InputBoxTemplates.xml:70`. | OK |
| `UIPanelCloseButton` | 3333 | SharedUIPanelTemplates.xml:148. | OK |
| `SecureActionButtonTemplate` (Next button) | 2085 | `Blizzard_FrameXML/SecureTemplates.xml:4`. | OK |
| `EditBox:SetFont(path, 12, "")` | 2777 | Docs SimpleEditBoxAPIDocumentation.lua:677-693: `flags` is **not** nilable for an EditBox, so the 3-argument call is required (a FontString's flags are nilable, SimpleFontStringAPIDocumentation.lua:500-511). The `TBFFlags` type is not defined in the mirror, so whether "" is accepted is not shown. | OK |
| Font objects `GameFontNormal`, `GameFontNormalSmall`, `GameFontHighlight`, `GameFontHighlightSmall`, `GameFontDisableSmall`, `ChatFontNormal` | 357, 364, ... | `Blizzard_Fonts_Shared/Shared/FontStyles.xml:50, 56, 62, 92, 112`; `Fonts.xml:1373`. Blizzard uses them as globals (`SetFontObject(ChatFontNormal)`, `Blizzard_ChatFrameBase/Mainline/ChatFrameOverrides.lua:4`). | OK |
| `Frame:RegisterEvent` / `UnregisterEvent` / `IsEventRegistered` | 257-270, 1459-1468 | Docs SimpleFrameAPIDocumentation.lua:1019-1034, 1598-1613, 740-756. | OK |
| `Button:RegisterForClicks` | 2090, 2315, 3200, 3233, 3429 | Docs SimpleButtonAPIDocumentation.lua:271-279: `IsProtectedFunction = true`. Called on unprotected frames, and on the secure button only in MakeNext, out of combat. | OK |
| `EditBox:HighlightText()` (copy box) | 377 | SimpleEditBoxAPIDocumentation.lua:435-443 (defaults 0, -1, so the whole text). | OK |
| All other widget methods used (SetPoint, SetWidth/Height, Show/Hide, IsShown/IsVisible, SetScript/GetScript, GetName, CreateTexture/FontString, SetText/GetText, SetFontObject, SetMaxLetters, SetNumeric, SetAutoFocus, SetFocus/ClearFocus, SetCursorPosition, SetMultiLine, SetTextInsets, SetJustifyH/V, SetTextColor, SetTexture, SetBlendMode, SetAlpha, SetStatusBarTexture/Color, SetMinMaxValues, SetValue/GetValue, SetValueStep, SetChecked/GetChecked, Enable/Disable, LockHighlight/UnlockHighlight, SetClampedToScreen, SetFrameStrata/Level, SetMovable, EnableMouse, RegisterForDrag, StartMoving/StopMovingOrSizing, SetAttribute/GetAttribute, GetEffectiveScale, GetCenter, GetBottom, ClearAllPoints, SetAllPoints) | throughout | Every one is in a `Docs/Simple*APIDocumentation.lua` file (checked by name). | OK |
| `GameTooltip` (SetOwner, SetText, AddLine with r,g,b,wrap, Show, Hide) | 1064, 2058, 2913, 3395, ... | `Blizzard_GameTooltip/Mainline/GameTooltip.xml:249`. Blizzard makes the same calls (`Blizzard_FrameXML/InstanceDifficulty.lua:191`, `Blizzard_AdventureMap/AM_QuestOfferDataProvider.lua:168-169`). There is no GameTooltip widget doc in the mirror. | OK |
| `StaticPopupDialogs[...] = {...}` (addon dialog) | 631-636 | A plain global table, `StaticPopupDialogs = {}` (`Blizzard_StaticPopup/StaticPopup.lua:21`); Blizzard's own addons add to it the same way, and `StaticPopup_AddDefinition` (:28) is only a helper. `whileDead` :363, `timeout`/`hideOnEscape` :408-409. OnAccept is called as `(dialog, data, data2)` and OnCancel as `(dialog, data, "clicked")` (:730-745). `text = "%s"` goes through `SetFormattedText(text, text_arg1)` (`Blizzard_StaticPopup_Game/GameDialog.lua:120-125`). | OK |
| `StaticPopup_Show(which, text_arg1)` | 639 | StaticPopup.lua:309. No `StaticPopup_ShowDialog` exists. | OK |
| `UISpecialFrames` (Escape closes) | 2757, 3328 | `Blizzard_UIParentPanelManager/Shared/UIParentPanelManager.lua:21`. | OK |
| `HideUIPanel(frame)` | 279 | UIParentPanelManager.lua:905. | OK |
| `Minimap`, `UIParent` | 3393-3426, 344, 2085, ... | `<Minimap name="Minimap">` at `Blizzard_Minimap/Mainline/Minimap.xml:56` (toc :30 `[Family]\Minimap.xml`). | OK |
| `GetCursorPosition()` | 3450 | Docs InputDocumentation.lua:30-37. | OK |
| Texture paths (DialogBox Background/Border, Tooltip Border, ChatFrameBackground, QuestTitleHighlight, ScrollBar ScrollDownButton, TargetingFrame StatusBar, MiniMap-TrackingBorder) | 349-350, 2311, 2661-2662, 2674, 2693, 2751-2752, 2767-2768, 2886, 3318-3319, 3438 | Every one is also used by Blizzard UI files in the tree (for example `Blizzard_SharedXML/Backdrop.lua:134`, `Blizzard_FrameXML/ItemDisplay.xml:84`). | OK |
| `Interface\Icons\INV_Scroll_03` (minimap icon) | 3434 | Icons are game data; not referenced in the UI source. | UNVERIFIED |

### 2.7 Key bindings

| Item | Used at | Reference finding | Verdict |
|---|---|---|---|
| CLICK binding name `CLICK GuildRecruiterNextButton:LeftButton` | Bindings.xml:10; 61, 101 | Blizzard looks up the same form: `GetBindingKey("CLICK "..self:GetName()..":LeftButton")` (`Blizzard_ActionBar/Shared/ActionButton.lua:499`). | OK |
| Label `_G["BINDING_NAME_"..name]` | 597 | `GetBindingName`: `envTable["BINDING_NAME_"..binding]` (`Blizzard_SharedXML/BindingUtil.lua:142-147`, `envTable = GetCurrentEnvironment()` :1); used by the Key Bindings page (`Blizzard_SettingsDefinitions_Frame/Keybindings.lua:203`). | OK |
| `GetBindingKey(action)` | 101 | Blizzard usage ActionButton.lua:499. Not in the docs. | OK |
| `header="GUILDRECRUITER"` and `BINDING_HEADER_GUILDRECRUITER` | Bindings.xml:10; 596 | Blizzard's own Bindings.xml use `category=` (`Blizzard_GroupFinder_VanillaStyle/Bindings.xml:2`). The Settings page groups entries by category (`Keybindings.lua:242-246`; entries without one go to `BINDING_HEADER_OTHER`) and draws every `HEADER*` entry as a blank spacer (`:248-249`). So the "Guild Rawcruiter" header text is probably not shown, and where the entry lands is not proven. | UNVERIFIED |
| `runOnUp="true"` on a CLICK binding | Bindings.xml:10 | Blizzard uses `runOnUp="true"` only on script bindings (`Blizzard_GamepadActionBars/Bindings.xml:8`); no CLICK example in the tree. | UNVERIFIED |

### 2.8 Lua environment

| Name | Used at | Reference finding | Verdict |
|---|---|---|---|
| `string.*` (find, sub, lower, gsub, len, format, match, gmatch), `table.*` (sort, concat), `math.*` (floor, ceil, rad, deg, cos, sin, atan2), `tinsert`, `tremove`, `random`, `pairs`, `type`, `tostring`, `tonumber`, `pcall`, `error`, `_G` | throughout | All used by Blizzard UI code in this tree, for example `math.atan2` (`Blizzard_CharacterCreate/Camelot/Blizzard_CharacterCreate.lua:2430`), `tinsert` (WhoList.lua:301), `tremove` (`Blizzard_GroupFinder/Shared/LFGFrame.lua:1057`), `random` (`Blizzard_Calendar/Mainline/Blizzard_Calendar.lua:1217`), `string.gmatch` (`Blizzard_AuraContainer/Blizzard_AuraButton.lua:13`). | OK |
| 1.12 aliases `strfind`, `strsub`, `strlower`, `getn`, `format`, `floor`, `mod` | not used | Blizzard still uses them (`strfind` `Blizzard_GlueParent/Mainline/GlueParent.lua:326`; `getn` `Blizzard_RaidUI/Mainline/Blizzard_RaidUI.lua:33, 125`; `mod` LFGFrame.lua:1278), so they exist, but the port uses none. | OK |

## 3. Still unverified (needs the client or the server)

1. GlobalStrings text: `ERR_GUILD_JOIN_S`, `ERR_GUILD_DECLINE_S`, the server's
   throttle wording, the /who summary lines, and whether names in those system
   messages are plain, linked, or carry a surname or realm.
2. The `/who` text filter `c-"Class"` on the Forever server (Blizzard's Who
   list uses the `SendWhoFilters` table instead).
3. What `HasRestrictions` on `C_ChatInfo.SendChatMessage` covers for an
   addon WHISPER (the docs don't say; the wiki says only SAY, YELL and CHANNEL,
   and on Forever also EMOTE, need a hardware event).
4. `Ambiguate` and the exact sender / `fullName` form for surname names (is
   the separator a space, and does `GetUnitName("player")` equal the
   Ambiguated sender?). `CHARACTERNAME_SURNAME_SEPARATOR` is not in the docs.
   `ChatFrameEditBox.lua:84-85` says whispers accept both "FirstName-SecondName"
   and "FirstName SecondName" when regional unique names are on.
5. Bindings.xml: where the entry appears in the Key Bindings page, and
   whether `runOnUp` applies to a CLICK binding.
6. The `""` value for `EditBox:SetFont` flags (`TBFFlags` is not defined in
   the mirror).
7. Game data: class lists per faction, the 1-60 range, the minimap icon.
8. `SecretArguments = "AllowedWhenUntainted"` on `issecretvalue` /
   `issecrettable` (FrameScriptDocumentation.lua:270-302): the mirror does not
   define what the flag means for addon (tainted) callers.
9. `Frame:UnregisterEvent` on `LFGWhoListFrame`, a frame of a `Secure: 1`
   addon. The docs mark Register/UnregisterEvent `AddsForbiddenAspects =
   EventRegistrations` (SimpleFrameAPIDocumentation.lua:1019-1034, 1598-1613),
   and what that does is not described. The old code did the same to
   FriendsFrame on Mainline. If Blizzard's Who list misbehaves after a run,
   `/gr hide` turns the muting off.

## 4. The ADD_GUILDMEMBER paste path, as the Blizzard code reads it

Entry point: the guild window's **Invite Member** button
(`Blizzard_Communities/CommunitiesFrame.xml:582`, `CommunitiesInviteButtonTemplate`,
`CommunitiesInvitationFrame.xml:130-132`). That calls
`CommunitiesInviteButton_OnClick` (`CommunitiesInvitationFrame.lua:111-117`), then
`CommunitiesUtil.OpenInviteDialog(clubId, streamId)`
(`Blizzard_FrameXMLUtil/CommunitiesUtil.lua:240-251`). For a guild club, that opens
`StaticPopup_Show("ADD_GUILDMEMBER", nil, nil, {clubId = clubId})`, or
`ADD_GUILDMEMBER_WITH_FINDER_LINK` when the guild has an active finder listing.
The only other caller is the community-list right-click entry
(UnitPopupButtons.lua:310-323), shown only when `CanGuildInvite()`.

The dialog (`Blizzard_StaticPopup_Game/Mainline/GameDialogDefs.lua:936-1000`,
not overridden by the 5-line Camelot file):

- `hasEditBox = 1`, `maxLetters = 48` (:943). This is applied with
  `editBox:SetMaxLetters(48)` (`GameDialog.lua:248-251`), so longer pasted text
  is cut at 48 letters.
- `OnShow` focuses the edit box (:948) and reads `C_Club.GetClubInfo(data.clubId)`
  (:962). The dialog therefore needs the clubId that only the Blizzard entry
  points pass.
- **Accept button:** `C_GuildInfo.Invite(dialog:GetEditBox():GetText())` (:944-946).
  **Enter key:** `EditBoxOnEnterPressed` (:985-993). Empty text calls
  `ChatFrameUtil.OpenChat("")` and invites nobody; any other text calls
  `C_GuildInfo.Invite(invitee)` and closes the dialog.
- **The text is passed raw.** No `strtrim`, no Ambiguate, no realm handling and
  no word splitting happen in Lua. "First Surname" reaches `C_GuildInfo.Invite`
  as one string, space included. So does any leading or trailing space or
  invisible character that gets pasted. Our copy box holds exactly the name and
  selects all of it, so a Ctrl+C / Ctrl+V copy carries nothing extra.
- **Autocomplete runs on the box.** It uses `C_AutoComplete.GetAutoCompleteResults`
  with `GUILD_INVITE` = `ONLINE_NOT_IN_GUILD` (`Blizzard_AutoComplete/AutoComplete.lua:39-41, 97`),
  and `addHighlightedText = true` (`GameDialog.xml:210-214`).
  - Enter goes to `AutoCompleteEditBox_OnEnterPressed` first (`Blizzard_StaticPopup/SharedTemplates.lua:44-57`).
    If the suggestion list is open with an entry selected, that Enter only fills
    in the entry, as `Ambiguate(name, "none")` (`AutoComplete.lua:358-365, 437-460`).
    It takes a second Enter to invite.
  - Typed characters can append a highlighted completion (`AutoCompleteEditBox_OnChar`
    and `AddHighlightedText`, :392-418). Whether a paste triggers OnChar is not
    shown.
  - Text with a "-" makes autocomplete offer realm names (:205-226).
- Closing the dialog clears the text (:977).
- `exclusive = 1` (:997): opening it closes other exclusive popups.

**Surprising:** Blizzard has a no-clipboard way in. While ADD_GUILDMEMBER is
open, **shift-clicking a player link in chat writes that name into the dialog's
edit box** (`Blizzard_UIPanels_Game/Mainline/ItemRefHandlers.lua:24-28`, with
`StaticPopup_Visible("ADD_GUILDMEMBER")` and `_G[staticPopup.."EditBox"]:SetText(name)`;
loaded on camelot as `[Family]\ItemRefHandlers.lua`). So if the addon printed each
candidate as a `|Hplayer:...|h` link, the player could open Invite Member and
shift-click the link instead of Ctrl+C / Esc / Ctrl+V. The link is printed by the
addon and the name is written by Blizzard's own code. I did not change the copy
box (out of scope); this is a suggestion to test.

Typed `/ginvite <name>` (SlashCommands.lua:1083-1092): the client trims the
text (ChatFrameEditBox.lua:239-240, 271). An empty name uses
`GetUnitName("target", true)`, a name longer than `MaxCharacterNameBytes`
(= `FULLNAME_MAX_CHAR`, ChatConstantsDocumentation.lua:216) gives
`ERR_NAME_TOO_LONG2`, and anything else goes to `C_GuildInfo.Invite(msg)`.

## 5. Checks

Lua checker (`lua51check.py`, Lua 5.1 grammar and scope):

| | HEAD `520c586` | working tree |
|---|---|---|
| Syntax | OK (271 functions) | OK (274 functions) |
| Max upvalues (limit 60) | 31 (slash handler) | 31 (slash handler) |
| Main-chunk locals (limit 200) | 171 | 171 |
| Generic-for over a non-call | 0 | 0 |

New global reads: `ChatFrameUtil`, `GetUnitName`, `LFGWhoListFrame` and
`LFGParentFrame`, all inside GR_Compat. No new global writes. `file`:
GuildRecruiter.lua is ASCII text, LF, with 0 CR bytes.
