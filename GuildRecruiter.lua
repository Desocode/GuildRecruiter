--[[ Guild Rawcruiter -- WoW: Forever port (Mainline-style API, Lua 5.1) of the
  vanilla 1.12 / Turtle WoW addon   (version: see .toc / VERSION below)
  BETA: untested in game. Every client call whose Forever behaviour is not yet
  verified goes through GR_Compat below; see PORT_NOTES.md.

  Scans online players with /who and sends paced guild contacts (invite and/or
  whisper) to players who are NOT already in a guild.

  Coverage: /who returns at most ~49 results per query and is server-throttled.
  We ADAPTIVELY SUBDIVIDE -- query a wide level band, and only if it comes back
  at the cap (truncated) do we narrow it (band -> halves -> single level -> by
  class). A slice under the cap was fully captured in one query.

  GUILD COORDINATION (addon messages over the GUILD channel):
    * dedup  -- every contact is broadcast so other recruiters skip that player;
               the re-invite cooldown becomes guild-wide.
    * split  -- active recruiters announce presence; the 1-60 sweep is divided
               evenly among them (deterministic by name) so they don't overlap.

  Slash: /gr  (see the bottom of the file, or type /gr help in-game)
]]--

GuildRecruiter_Settings = GuildRecruiter_Settings or {}

local ADDON_NAME = (...) or "GuildRecruiter"   -- the client passes the folder name to each file

-- ===========================================================================
-- WoW: Forever compatibility layer (GR_Compat)
-- ---------------------------------------------------------------------------
-- Every call whose behaviour on the Forever client is UNVERIFIED lives here and
-- nowhere else. Each function prefers the modern (Mainline-style) API when it is
-- present and falls back to the old 1.12 global otherwise. The choice is made by
-- FEATURE DETECTION at call time -- never by WOW_PROJECT_ID or a build number
-- (WOW_PROJECT_ID read 1 on one Forever beta build and 18 on another).
-- PORT_NOTES.md "Still unverified" maps each open blocker to its function here.
-- ===========================================================================
local GR_Compat = {}

-- Secret values (Mainline 12.x, reportedly active on Forever): tainted code may
-- not compare, index with, or do arithmetic on one. A secret is SKIPPED here,
-- never compared or concatenated. nil-safe on clients without the API.
local issecret    = issecretvalue  or function() return false end
local issecrettab = issecrettable  or function() return false end
GR_Compat.IsSecret = issecret

-- Hardware-event mode (blockers 1 + 2). The wiki marks C_FriendList.SendWho
-- #hwevent: it works only inside a handler the client runs for a key press or
-- mouse click, never from OnUpdate, C_Timer or an event. C_GuildInfo.Invite is
-- stricter: on a Forever client it raised ADDON_ACTION_FORBIDDEN from a key
-- press, so it is protected (Blizzard-only) and addon code never calls it here.
-- A secure /ginvite macro, /ginvite typed into the chat box by the addon, and
-- the Invite Member box filled by addon code (SetItemRef) were all refused on a
-- Forever client too. So the addon only PROMPTS (GR_Compat.SetSecureInvite:
-- copy box + a chat player link) and keeps the Ready list; the player invites
-- in Blizzard's Guild > Invite Member box.
-- ONE switch, set by feature detection at load: a client with
-- C_FriendList.SendWho is treated as needing a press for every /who and every
-- invite prompt (whispers still go out from the timer, TimerContactModes); a
-- client with only the old globals keeps the automatic timer loop and its old
-- invite calls.
GR_Compat.RequiresHardwareEvent = (C_FriendList and C_FriendList.SendWho) and true or false

-- the Bindings.xml CLICK binding on the secure Next button (also its key lookup)
GR_Compat.NEXT_BINDING = "CLICK GuildRecruiterNextButton:LeftButton"

-- combat lockdown: insecure code may not change a secure frame (its attributes,
-- show/hide, position or size) while it is on
function GR_Compat.InCombat()
  return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

-- contact modes the run timer may still send by itself in hardware-event mode:
-- a WHISPER is not hardware-restricted (wiki; Forever docs mark only
-- HasRestrictions on C_ChatInfo.SendChatMessage), so whisper contacts keep
-- going out on the invite delay, with the same pacing, jitter, backoff, combat /
-- instance hold and session cap as before. That includes the first whisper of
-- whisper-then-invite: the invite itself is never sent by the addon (it lands on
-- the Ready list for the player). Everything else waits for a press.
-- If whispers turn out to need a press too, set this table to {}.
GR_Compat.TimerContactModes = { whisper = true, whisperinvite = true }

-- GR_Compat.Press(fn, ...) runs fn for a key press or click, in the SAME call
-- stack (pcall is synchronous: no timer, no OnUpdate hop, no coroutine), and
-- returns pcall's ok, err. The restricted /who wrapper below (SendWho) calls
-- CheckPress first: in hardware-event mode, reaching it outside a Press is a
-- bug, and it stops the run with a named error instead of tripping the
-- client's "action blocked" counter. Invites have their own gate
-- (SetSecureInvite: only inside the secure button's PreClick).
GR_Compat.inPress = false
GR_Compat.secureClick = nil   -- the secure Next button, set only while its PreClick runs
function GR_Compat.Press(fn, ...)
  local outer = GR_Compat.inPress
  GR_Compat.inPress = true
  local ok, err = pcall(fn, ...)
  GR_Compat.inPress = outer
  return ok, err
end

function GR_Compat.CheckPress(label)
  if GR_Compat.RequiresHardwareEvent and not GR_Compat.inPress then
    error(label.." needs a key press or click on this client, but was reached from a timer or event", 0)
  end
  GR_Compat.lastCall, GR_Compat.lastCallAt = label, GetTime()   -- named if the client blocks it
end

-- the key bound to a Bindings.xml action, or nil
function GR_Compat.BindingKey(action)
  if type(GetBindingKey) == "function" then
    local k = GetBindingKey(action)
    if type(k) == "string" and k ~= "" then return k end
  end
  return nil
end

-- the client reports a blocked call with ADDON_ACTION_BLOCKED (protected call
-- from tainted code) or ADDON_ACTION_FORBIDDEN, payload (addonName, function);
-- both are synchronous events (wiki). Registered under pcall, so a client
-- without them just never fires them.
function GR_Compat.WatchBlocked(frame)
  pcall(frame.RegisterEvent, frame, "ADDON_ACTION_BLOCKED")
  pcall(frame.RegisterEvent, frame, "ADDON_ACTION_FORBIDDEN")
end

-- one chat line for a block report that names this addon, else nil. fn is the
-- event's second argument (the call the client refused). FORBIDDEN means a
-- Blizzard-only call, which no key press unlocks; BLOCKED means a protected
-- call from tainted code (e.g. a secure frame changed in combat).
function GR_Compat.BlockedLine(event, addon, fn)
  if issecret(addon) or issecret(fn) or addon ~= ADDON_NAME then return nil end
  -- a refused clipboard copy is harmless: note it so CopyName falls back to the
  -- copy box, and do not pause the run for it
  if type(fn) == "string" and string.find(fn, "Clipboard", 1, true) then
    GR_Compat.clipBlocked = true
    return nil
  end
  local line
  if event == "ADDON_ACTION_FORBIDDEN" then
    line = "|cffff4040The client forbids "..tostring(fn or "an action").." for addons|r (ADDON_ACTION_FORBIDDEN: Blizzard-only, a key press does not unlock it)"
  else
    line = "|cffff4040The client blocked "..tostring(fn or "an action").."|r ("..tostring(event)..")"
  end
  if GR_Compat.lastCall then
    line = line.."; our last restricted call was "..GR_Compat.lastCall
         ..string.format(" %.1fs ago", GetTime() - (GR_Compat.lastCallAt or 0))
  end
  return line
end

-- Mainline chat/addon events name players "Name-Realm"; 1.12 used a bare "Name".
-- Strip our own realm (Ambiguate "none") so history/seen/whisper keys match the
-- /who and guild-message names. Other realms keep their suffix.
function GR_Compat.ShortName(name)
  if type(name) ~= "string" or issecret(name) then return nil end
  if type(Ambiguate) == "function" then return Ambiguate(name, "none") end
  return name
end

-- the key under which tbl holds this player, or nil. Forever names are "First
-- Surname" (the surname separator is a space: SlashCommands.lua:1163-1164), but
-- whispers also accept "First-Surname" where regional unique names are on
-- (ChatFrameEditBox.lua:84-85) and links can carry a link separator instead
-- (C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator, ItemRefHandlers.lua:38).
-- Which form a whisper sender or a system message uses is unverified, so both
-- are tried: the name as given, then with its first space <-> hyphen swapped.
function GR_Compat.FindKey(tbl, name)
  if type(tbl) ~= "table" or type(name) ~= "string" or issecret(name) then return nil end
  if tbl[name] ~= nil then return name end
  local alt
  if string.find(name, " ", 1, true) then alt = string.gsub(name, " ", "-", 1)
  else alt = string.gsub(name, "-", " ", 1) end
  if alt ~= name and tbl[alt] ~= nil then return alt end
  return nil
end

-- a player name out of system-message text: a player link (|Hplayer:Name:...|h
-- [Name]|h) gives its first field; otherwise colour codes and [brackets] are
-- stripped. Spaces inside the name are kept. nil for empty or secret text.
function GR_Compat.PlainName(s)
  if type(s) ~= "string" or issecret(s) then return nil end
  local n = string.match(s, "|Hplayer:([^:|]+)")
  if not n then
    n = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    n = string.gsub(n, "|r", "")
    n = string.gsub(n, "^%[(.*)%]$", "%1")
  end
  n = string.gsub(n, "^%s+", "")
  n = string.gsub(n, "%s+$", "")
  if n == "" then return nil end
  return GR_Compat.ShortName(n)
end

-- a chat player link for a name ("First Surname" keeps its space: Blizzard's
-- HandlePlayerLink takes the name as the link's first ":" field,
-- Blizzard_UIPanels_Game/Mainline/ItemRefHandlers.lua:1-8). The addon only
-- PRINTS it into the chat frame; the player's shift-click on it there is handled
-- by Blizzard's own chat code, which fills an open Guild > Invite Member box
-- (ItemRefHandlers.lua:24-28). The addon never calls SetItemRef itself.
function GR_Compat.PlayerLink(name)
  if type(name) ~= "string" or string.find(name, "[|:%c]") then return tostring(name) end
  return "|cffffd100|Hplayer:"..name.."|h["..name.."]|h|r"
end

-- the reply alert: a stock sound and the taskbar flash, both feature-detected and
-- under pcall. Forever: PlaySound = C_Sound.PlaySound(soundKitID, ...)
-- (Blizzard_SharedXML/Mainline/Sound.lua:3; SoundDocumentation.lua:52-72),
-- SOUNDKIT.READY_CHECK = 8960 (Mainline/SoundKitConstants.lua:85, loaded as
-- [Family] on Forever), the sound Blizzard plays for a ready check together with
-- FlashClientIcon() (Blizzard_FrameXML/Mainline/ReadyCheck.lua:71-72;
-- ClientDocumentation.lua:10). There is no PlaySoundFile in the Forever docs.
function GR_Compat.Alert()
  local kit = (SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960
  local play = (C_Sound and C_Sound.PlaySound) or PlaySound
  if type(play) == "function" then pcall(play, kit) end
  if type(FlashClientIcon) == "function" then pcall(FlashClientIcon) end
end

-- the player's OWN name in the form /who and chat use, for the "is this me?"
-- checks (own /who row, own guild-sync echo, the band split). On Forever
-- UnitName("player") is only the first name: Blizzard's Forever NameUtil reads
-- its two returns as (name, surname) and builds the full name as
-- name..CHARACTERNAME_SURNAME_SEPARATOR..surname (reference Blizzard_FrameXMLUtil/
-- Camelot/NameUtil.lua:4-11), and Blizzard's own Forever Who list recognises
-- the player's row with info.fullName == GetUnitName("player")
-- (Blizzard_GroupFinder_VanillaStyle/Mainline/WhoList.lua:94; GetUnitName is
-- Blizzard_UnitFrame/Mainline/UnitFrame.lua:1094). Without a surname, or on a
-- client without GetUnitName, this is UnitName("player") as before.
function GR_Compat.MyName()
  if type(GetUnitName) == "function" then
    local n = GetUnitName("player")
    if type(n) == "string" and not issecret(n) and n ~= "" then return n end
  end
  return UnitName("player")
end

-- /who query (blocker 1). Mainline: C_FriendList.SendWho(filter, origin); the
-- origin argument arrived in 10.2.0, and the wiki marks the call #hwevent
-- (needs a key/mouse press) since 8.2.5. RESTRICTED: CheckPress first.
function GR_Compat.SendWho(filter)
  if C_FriendList and C_FriendList.SendWho then
    GR_Compat.CheckPress("C_FriendList.SendWho")
    -- re-route replies to WHO_LIST_UPDATE before EVERY query, not only at Start:
    -- on Forever the default Who list turns the routing off whenever it is
    -- closed (LFGWhoListMixin:OnHide -> C_FriendList.SetWhoToUi(false),
    -- reference Blizzard_GroupFinder_VanillaStyle/Mainline/WhoList.lua:253-254),
    -- after which replies would go to chat and every /who would time out.
    GR_Compat.SetWhoToUI(true)
    -- origin: Enum.SocialWhoOrigin.Social (= 1, SocialConstantsDocumentation.lua:14),
    -- the value Blizzard's own Who list sends (WhoList.lua:178, 189)
    local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social
    C_FriendList.SendWho(filter, origin)
  elseif type(SendWho) == "function" then
    GR_Compat.CheckPress("SendWho")
    SendWho(filter)
  else
    error("no /who API on this client (C_FriendList.SendWho / SendWho)")
  end
end

-- number of rows in the last /who reply (blocker 1). A missing ("ReturnNothing")
-- or secret count reads as 0 rows.
function GR_Compat.GetNumWhoResults()
  local n
  if C_FriendList and C_FriendList.GetNumWhoResults then
    n = C_FriendList.GetNumWhoResults()
  elseif type(GetNumWhoResults) == "function" then
    n = GetNumWhoResults()
  else
    error("no /who result API on this client (C_FriendList.GetNumWhoResults / GetNumWhoResults)")
  end
  if type(n) ~= "number" or issecret(n) then return 0 end
  return n
end

-- one /who row as the 1.12 tuple: name, guild, level, race, class, zone
-- (blockers 1 + 4). Mainline returns a WhoInfo table {fullName, fullGuildName,
-- level, raceStr, classStr, area}. A row whose name or guild is secret can't be
-- judged (guildless? already seen?) so it is skipped (nil name); any other
-- secret field reads as nil.
function GR_Compat.GetWhoRow(i)
  local name, guild, level, race, class, zone
  if C_FriendList and C_FriendList.GetWhoInfo then
    local info = C_FriendList.GetWhoInfo(i)
    if type(info) ~= "table" or issecrettab(info) then return nil end
    name, guild, level = info.fullName, info.fullGuildName, info.level
    race, class, zone  = info.raceStr, info.classStr, info.area
  elseif type(GetWhoInfo) == "function" then
    name, guild, level, race, class, zone = GetWhoInfo(i)
  else
    error("no /who row API on this client (C_FriendList.GetWhoInfo / GetWhoInfo)")
  end
  if issecret(name) or issecret(guild) then return nil end
  if issecret(level) then level = nil end
  if issecret(race)  then race  = nil end
  if issecret(class) then class = nil end
  if issecret(zone)  then zone  = nil end
  return GR_Compat.ShortName(name), guild, level, race, class, zone
end

-- route /who replies to WHO_LIST_UPDATE (true) or back to chat (false).
-- Mainline renamed it C_FriendList.SetWhoToUi (lower-case i) and takes a boolean.
function GR_Compat.SetWhoToUI(on)
  if C_FriendList and C_FriendList.SetWhoToUi then
    pcall(C_FriendList.SetWhoToUi, on and true or false)
  elseif type(SetWhoToUI) == "function" then
    pcall(SetWhoToUI, on and 1 or 0)
  end
end

-- the default-UI frame that pops the Who list on WHO_LIST_UPDATE, and the window
-- to close (1.12 and Mainline: FriendsFrame for both). nil turns hiding off.
-- Forever (game type "camelot") does NOT use FriendsFrame for /who: Blizzard_
-- FriendsFrame.toc loads Camelot\FriendsFrame.lua there, whose FriendsFrame_OnLoad
-- registers no WHO_LIST_UPDATE (reference Blizzard_FriendsFrame/Camelot/
-- FriendsFrame.lua:287-311). The Who list is LFGWhoListFrame (Blizzard_
-- GroupFinder_VanillaStyle/Mainline/WhoList.xml:89, parent LFGParentFrame): it
-- registers the event (WhoList.lua:199) and every update ends in
-- ShowUIPanel(LFGParentFrame) (WhoList.lua:274-275). That addon is load-on-
-- demand, so this is asked each time.
function GR_Compat.WhoPanel()
  if LFGWhoListFrame then return LFGWhoListFrame, LFGParentFrame end
  return FriendsFrame, FriendsFrame
end

-- stop (on) / restore (off) the Who window popping on WHO_LIST_UPDATE. Only the
-- frame that really had the event registered is unregistered, and restore
-- re-registers exactly that frame: re-registering a frame that never had it
-- (Forever's FriendsFrame, above) would add a registration Blizzard never made.
-- IsEventRegistered: Blizzard_APIDocumentationGenerated/SimpleFrameAPIDocumentation.lua:740.
GR_Compat.whoMuted = nil
function GR_Compat.MuteWhoWindow(on)
  if on then
    if GR_Compat.whoMuted then return end
    local wp = GR_Compat.WhoPanel()
    if wp and (not wp.IsEventRegistered or wp:IsEventRegistered("WHO_LIST_UPDATE")) then
      wp:UnregisterEvent("WHO_LIST_UPDATE")
      GR_Compat.whoMuted = wp
    end
  elseif GR_Compat.whoMuted then
    GR_Compat.whoMuted:RegisterEvent("WHO_LIST_UPDATE")
    GR_Compat.whoMuted = nil
  end
end

-- close the Who window if it is showing (Forever: only when the LFG frame is on
-- its Who tab, i.e. LFGWhoListFrame is shown, Blizzard_LFGVanilla_ParentFrame.lua:22).
-- A frame that neither we muted nor has WHO_LIST_UPDATE registered is not the
-- Who window (Forever's FriendsFrame is the Friends list), so it is left alone.
function GR_Compat.HideWhoWindow()
  local who, win = GR_Compat.WhoPanel()
  if not who or not win or not who:IsVisible() then return end
  if who ~= GR_Compat.whoMuted and who.IsEventRegistered and not who:IsEventRegistered("WHO_LIST_UPDATE") then return end
  HideUIPanel(win)
end

-- guild invite (blocker 2), TIMER-LOOP CLIENTS ONLY (no C_FriendList.SendWho).
-- method = the saved setting auto|byname|invite|chat. "auto" tries
-- C_GuildInfo.Invite(name) first, then the 1.12 order (GuildInviteByName,
-- GuildInvite, /ginvite). A chosen method whose function is missing falls back
-- to the "auto" order. Returns the call's name and the function that sends it.
-- In key-press mode GR_Compat.GuildInvite never reaches this (SetSecureInvite).
function GR_Compat.ResolveInvite(method)
  if method == "byname" and type(GuildInviteByName) == "function" then return "GuildInviteByName", GuildInviteByName end
  if method == "invite" and type(GuildInvite) == "function" then return "GuildInvite", GuildInvite end
  if method == "chat" then return "/ginvite", GR_Compat.InviteByChat end
  if C_GuildInfo and C_GuildInfo.Invite then return "C_GuildInfo.Invite", C_GuildInfo.Invite end
  if type(GuildInviteByName) == "function" then return "GuildInviteByName", GuildInviteByName end
  if type(GuildInvite) == "function" then return "GuildInvite", GuildInvite end
  return "/ginvite (chat fallback)", GR_Compat.InviteByChat
end
function GR_Compat.InviteByChat(name) GR_Compat.RunSlash("/ginvite "..name) end

-- Key-press mode invite. C_GuildInfo.Invite is protected (ADDON_ACTION_FORBIDDEN
-- seen on Forever), so addon code never calls it, nor GuildInviteByName,
-- GuildInvite or a /ginvite typed from code. Inside the secure Next button's
-- PreClick (GR_Compat.secureClick) this sets that button's action to the macro
-- "/ginvite <name>"; the template's secure OnClick runs it right after PreClick
-- returns, in the same click, and PostClick empties it again (SecureClear).
-- Reached anywhere else, or in combat lockdown, it raises an error: the press
-- code checks both before it gets here, so that would be a bug.
function GR_Compat.SetSecureInvite(name)
  local btn = GR_Compat.secureClick
  if not btn then
    error("a guild invite needs a click on the secure Next button (or its key, or /click GuildRecruiterNextButton) on this client, but was reached from "
      ..(GR_Compat.inPress and "a typed command" or "a timer or event"), 0)
  end
  if GR_Compat.InCombat() then error("can't set the invite in combat", 0) end
  -- Forever names are "First Surname" (one space), so spaces are allowed; only
  -- characters that could end or alter the macro line are refused.
  if type(name) ~= "string" or not string.find(name, "^[^%c/|]+$") or string.find(name, "^%s") or string.find(name, "%s$") then
    error("not a player name for /ginvite: "..tostring(name), 0)   -- no newlines/slashes/escapes in a macro line
  end
  -- Real Forever client results: a direct C_GuildInfo.Invite is FORBIDDEN, a secure
  -- /ginvite macro is refused ("macro script has been blocked ... Blizzard UI"), and
  -- typing "/ginvite <name>" into the chat box from addon code is ALSO forbidden
  -- (the addon touching the edit box taints the command the player then sends:
  -- "The client forbids Invite() for addons"). So the addon never sends the invite
  -- and never touches the chat box. It prints the name as a clickable player link;
  -- the PLAYER invites with Blizzard's own menu (right-click > Invite to Guild) or
  -- types the command by hand. Untested whether the menu entry works from a link.
  -- The right-click menu on that link did NOT offer Invite to Guild (player test), so
  -- the name goes in the addon's OWN copy box instead: Ctrl+C, Esc, then paste it
  -- into the Blizzard Guild > Invite Member box yourself. The addon never touches
  -- a Blizzard frame, so the invite stays a Blizzard-UI action.
  -- This is only the PROMPT: the caller puts the name on the Ready list, and the
  -- invite is counted when the player presses Done there (or the join/decline
  -- message names them), never here.
  -- (The old copy window is no longer opened here: the Ready panel is the one place
  -- to act on a name, and its [Copy] button puts the name on the clipboard.)
  GR_Compat.PrintLink(name)
end

-- Put a player name on the OS clipboard. Blizzard documents CopyToClipboard(text) in
-- the Os API as HasRestrictions = true, i.e. it probably needs the click that calls
-- it (Blizzard_APIDocumentationGenerated/OsDocumentation.lua). It touches no Blizzard
-- frame. If the client blocks it or the function is missing, the copy box is shown
-- instead. Returns true when the clipboard call ran without a block or error.
function GR_Compat.CopyName(name)
  GR_Compat.clipBlocked = false
  if type(CopyToClipboard) == "function" then
    local ok = pcall(CopyToClipboard, name)
    if ok and not GR_Compat.clipBlocked then
      if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff8000Rawcruiter:|r copied "..name
          .." -- paste with Ctrl+V into Guild > Invite Member (Shift-click Copy to see a copy box instead)")
      end
      return true
    end
  end
  GR_Compat.ShowCopyBox(name)
  return false
end

-- print the invite prompt line with the name as a player link, in the chat frame
-- (Blizzard's own link handler fills the open Invite Member box when the player
-- shift-clicks it there: Blizzard_UIPanels_Game/Mainline/ItemRefHandlers.lua:24-28,
-- StaticPopup_Visible("ADD_GUILDMEMBER")).
function GR_Compat.PrintLink(name)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff8000Rawcruiter:|r invite "..GR_Compat.PlayerLink(name)
      .." -- with Guild > Invite Member open, SHIFT-CLICK the name here in chat (or Copy + paste), then press Done in the Ready panel")
  end
end

-- THE READY LIST IN A REAL BLIZZARD CHAT TAB. Our own frames can't make a link that
-- fills Invite Member without tainting the invite, but a Blizzard chat window can:
-- its link click is Blizzard's own code. So the player makes one chat tab by hand
-- (right-click any chat tab > New Window > name it "Rawcruiter", leave every chat
-- type unticked) and this prints the waiting names there as player links, to
-- SHIFT-click. We only find that window and AddMessage into it (what every addon
-- does to print); we never create or configure a chat window (that would run
-- Blizzard's chat setup code from our tainted context).
GR_Compat.CHAT_TAB = "Rawcruiter"

-- the chat frame whose tab is named "Rawcruiter", or nil
function GR_Compat.ListFrame()
  local count = NUM_CHAT_WINDOWS or 10
  for i = 1, count do
    local nm
    if type(GetChatWindowInfo) == "function" then nm = GetChatWindowInfo(i) end
    if type(nm) ~= "string" or nm == "" then
      local tab = _G["ChatFrame"..i.."Tab"]
      nm = tab and tab.GetText and tab:GetText()
    end
    if type(nm) == "string" and not issecret(nm) and nm == GR_Compat.CHAT_TAB then
      return _G["ChatFrame"..i]
    end
  end
  return nil
end

-- redraw the list in that tab, only when the set of names (or the tab) changed.
-- names: newest first (GuildRecruiter_ReadyNames); r: the Ready table.
function GR_Compat.RenderList(names, r)
  local fr = GR_Compat.ListFrame()
  if not fr then
    if #names > 0 and not GR_Compat.tabWarned and DEFAULT_CHAT_FRAME then
      GR_Compat.tabWarned = true
      DEFAULT_CHAT_FRAME:AddMessage("|cffff8000Rawcruiter:|r for a clickable invite list, make a chat tab named \""
        ..GR_Compat.CHAT_TAB.."\": right-click any chat tab > New Window > name it "..GR_Compat.CHAT_TAB
        ..", then untick all message types. Names appear there to shift-click.")
    end
    return false
  end
  local sig = #names..":"..table.concat(names, "\1")
  if GR_Compat.listSig == sig and GR_Compat.listFrame == fr then return true end
  GR_Compat.listSig, GR_Compat.listFrame = sig, fr
  pcall(function()
    fr:Clear()
    if #names == 0 then
      fr:AddMessage("|cffff8000Rawcruiter:|r nobody is waiting for an invite.")
      return
    end
    fr:AddMessage("|cffff8000Rawcruiter: ready to invite ("..#names..")|r  Open Guild > Invite Member, SHIFT-click a name here, Accept, then press Done in the Ready panel.")
    for i = #names, 1, -1 do      -- oldest first: that is who has waited longest
      local e = r and r[names[i]]
      local when = (type(e) == "table" and e.t) and date("%H:%M", e.t) or "?"
      fr:AddMessage("   "..GR_Compat.PlayerLink(names[i]).."   |cff999999replied "..when.."|r")
    end
  end)
  return true
end

-- a small draggable box holding the name, selected, so the player can copy it
-- (Ctrl+C) and paste it into Blizzard's own invite box. Our own frame only.
-- While it has focus key bindings are suspended, so Esc (or Enter) closes it.
function GR_Compat.ShowCopyBox(name)
  local f = GuildRecruiterCopyBox
  if not f then
    f = GR_Compat.BackdropFrame("Frame", "GuildRecruiterCopyBox", UIParent)
    f:SetWidth(300)
    f:SetHeight(66)
    f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    f:SetFrameStrata("DIALOG")
    GR_Compat.SetBackdrop(f, { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOP", f, "TOP", 0, -10)
    f.label = label
    local eb = CreateFrame("EditBox", "GuildRecruiterCopyEdit", f)
    eb:SetWidth(270)
    eb:SetHeight(24)
    eb:SetPoint("BOTTOM", f, "BOTTOM", 0, 10)
    eb:SetFontObject(ChatFontNormal or GameFontHighlight)
    eb:SetAutoFocus(false)
    local bg = eb:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(eb)
    GR_Compat.ColorTexture(bg, 0, 0, 0, 0.6)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); f:Hide() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus(); f:Hide() end)
    -- Ctrl+C closes the box by itself (one key less). If the client never delivers
    -- OnKeyDown to an edit box this does nothing and Esc closes it as before.
    pcall(eb.SetScript, eb, "OnKeyDown", function(self, key)
      if key == "C" and IsControlKeyDown and IsControlKeyDown() then
        if C_Timer and C_Timer.After then
          C_Timer.After(0.15, function() self:ClearFocus(); f:Hide() end)
        end
      end
    end)
    f.edit = eb
  end
  f.label:SetText("Ctrl+C to copy (Esc closes), then Ctrl+V in Guild > Invite Member, Accept, Done")
  f.edit:SetText(name)
  f:Show()
  f.edit:SetFocus()
  f.edit:HighlightText()
end

-- empty the secure button's action. Between clicks it is always empty: PostClick
-- empties it, and so does PLAYER_REGEN_DISABLED (which fires just BEFORE
-- lockdown starts). In combat lockdown SetAttribute is not allowed, so this does
-- nothing then (there is nothing to empty).
function GR_Compat.SecureClear(btn)
  if not btn or GR_Compat.InCombat() then return end
  if btn:GetAttribute("type") ~= nil or btn:GetAttribute("macrotext") ~= nil then
    btn:SetAttribute("type", nil)
    btn:SetAttribute("macrotext", nil)
  end
end

-- the invite. Key-press mode: the secure macro above (never C_GuildInfo.Invite).
-- Timer-loop client (no C_FriendList.SendWho): the call ResolveInvite picks,
-- as before (CheckPress only records it there; it never blocks on that client).
function GR_Compat.GuildInvite(name, method)
  if GR_Compat.RequiresHardwareEvent then
    GR_Compat.SetSecureInvite(name)
    return
  end
  local label, send = GR_Compat.ResolveInvite(method)
  GR_Compat.CheckPress(label)
  send(name)
end

-- which call invites, for the load message
function GR_Compat.InviteApiName()
  if GR_Compat.RequiresHardwareEvent then return "/ginvite on the secure Next button" end
  local label = GR_Compat.ResolveInvite("auto")
  return label
end

-- invite permission (blocker 2). No API at all = unknown = allowed, as in 1.12.
function GR_Compat.CanGuildInvite()
  if type(CanGuildInvite) == "function" then return CanGuildInvite() and true or false end
  return true
end

-- run a slash command as if typed (the "chat" invite method). ChatEdit_SendText
-- is unverified on Forever's chat code; the fallback calls the edit box's own
-- Enter handler with self (Mainline handlers take self, 1.12 read `this`).
function GR_Compat.RunSlash(text)
  local eb = ChatFrameEditBox or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox)
  if not eb then return false end
  eb:SetText(text)
  if type(ChatEdit_SendText) == "function" then
    ChatEdit_SendText(eb, 0)
  else
    local handler = eb:GetScript("OnEnterPressed")
    if handler then handler(eb) end
  end
  eb:SetText("")
  return true
end

-- whisper (blocker 3). The SendChatMessage global was deprecated in 11.2.0 for
-- C_ChatInfo.SendChatMessage (same argument order). Per the wiki WHISPER is not
-- hardware-event restricted.
function GR_Compat.SendWhisper(text, target)
  -- recorded (not gated: whispers may come from the timer) so a block report can name it
  GR_Compat.lastCall, GR_Compat.lastCallAt = "C_ChatInfo.SendChatMessage (whisper)", GetTime()
  if C_ChatInfo and C_ChatInfo.SendChatMessage then
    C_ChatInfo.SendChatMessage(text, "WHISPER", nil, target)
  elseif type(SendChatMessage) == "function" then
    SendChatMessage(text, "WHISPER", nil, target)
  else
    error("no chat send API on this client (C_ChatInfo.SendChatMessage / SendChatMessage)")
  end
end

-- one line naming the who / invite / whisper calls in use, for the load message
function GR_Compat.ApiSummary()
  local who = (C_FriendList and C_FriendList.SendWho and "C_FriendList.SendWho")
           or (type(SendWho) == "function" and "SendWho") or "none"
  local wsp = (C_ChatInfo and C_ChatInfo.SendChatMessage and "C_ChatInfo.SendChatMessage")
           or (type(SendChatMessage) == "function" and "SendChatMessage") or "none"
  return "Invite API: "..GR_Compat.InviteApiName().." (who: "..who..", whisper: "..wsp..")"
      ..(GR_Compat.RequiresHardwareEvent and ". Key-press mode: each /who waits for the Next button or its key; whispers go out by themselves; you send each guild invite yourself from the Ready list (/gr ready)" or "")
end

-- guild sync. Mainline moved both calls to C_ChatInfo (8.0.1) and delivers
-- CHAT_MSG_ADDON only for a REGISTERED prefix (16 chars max); 1.12 needs no
-- registration. Registrations don't survive a /reload, so register at load.
function GR_Compat.RegisterAddonPrefix(prefix)
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(prefix)
  elseif type(RegisterAddonMessagePrefix) == "function" then
    RegisterAddonMessagePrefix(prefix)
  end
end

function GR_Compat.SendAddonMessage(prefix, text, channel)
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(prefix, text, channel)
  elseif type(SendAddonMessage) == "function" then
    SendAddonMessage(prefix, text, channel)
  else
    error("no addon-message API on this client (C_ChatInfo.SendAddonMessage / SendAddonMessage)")
  end
end

-- server chat wording (blocker 6): the 1.12 / enUS strings, kept verbatim.
-- Re-check the Forever server's CHAT_MSG_SYSTEM text in game.
-- the /who summary lines hidden while a run is active ("3 Players Total", ...)
function GR_Compat.IsWhoNoise(m)
  if type(m) ~= "string" or issecret(m) then return false end
  if string.find(m, "[Pp]layers? [Tt]otal") then return true end  -- "3 Players Total"
  if string.find(m, "^There are %d")          then return true end
  if string.find(m, "[Nn]o players")          then return true end  -- "No players found"
  return false
end

-- a server throttle message ("too many / too quickly"); m is lower-cased
function GR_Compat.IsThrottleMsg(m)
  if string.find(m, "too quickly") or string.find(m, "too many")
     or (string.find(m, "wait") and string.find(m, "invit")) then return true end
  return false
end

-- hide CHAT_MSG_SYSTEM lines for which hide(msg) is true. Mainline has the
-- message-filter API (2.4+); replacing ChatFrame_OnEvent (the 1.12 trick) taints
-- Mainline chat frames, so it is only the fallback, with the 3.0+ signature.
-- Forever: the filter API is ChatFrameUtil.AddMessageEventFilter(event, cb), cb
-- called as (chatFrame, event, ...) and a true first return drops the line
-- (reference Blizzard_ChatFrameBase/Shared/ChatFrameFilters.lua:202, 138-170).
-- The global ChatFrame_AddMessageEventFilter is only an alias that exists when
-- the CVar loadDeprecationFallbacks is on (Blizzard_DeprecatedChatInfo/
-- Deprecated_ChatFrame.lua:4, 51), and ChatFrame_OnEvent is not defined
-- anywhere in the Forever UI, so without this the quiet-/who filter silently
-- did nothing.
function GR_Compat.FilterSystemChat(hide)
  local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
  if type(addFilter) == "function" then
    addFilter("CHAT_MSG_SYSTEM", function(frame, ev, msg)
      if issecret(msg) then return false end
      return hide(msg) and true or false
    end)
  elseif type(ChatFrame_OnEvent) == "function" then
    local orig = ChatFrame_OnEvent
    ChatFrame_OnEvent = function(self, ev, ...)
      local msg = ...
      if ev == "CHAT_MSG_SYSTEM" and not issecret(msg) and hide(msg) then return end
      return orig(self, ev, ...)
    end
  end
end

-- frames that draw a backdrop. Mainline (9.0+) has SetBackdrop only through
-- BackdropTemplate; 1.12 frames have it natively. With neither, the frame still
-- works, just without its border/background.
function GR_Compat.BackdropFrame(kind, name, parent)
  return CreateFrame(kind, name, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
end
function GR_Compat.SetBackdrop(frame, backdrop)
  if frame.SetBackdrop then frame:SetBackdrop(backdrop) end
end
function GR_Compat.SetBackdropColor(frame, r, g, b, a)
  if frame.SetBackdropColor then frame:SetBackdropColor(r, g, b, a) end
end

-- a solid-colour texture: Texture:SetTexture(r, g, b, a) became SetColorTexture in 7.0
function GR_Compat.ColorTexture(tex, r, g, b, a)
  if tex.SetColorTexture then tex:SetColorTexture(r, g, b, a) else tex:SetTexture(r, g, b, a) end
end

-- does the client define this XML template? C_XMLUtil.GetTemplateInfo returns nil
-- for an unknown one. With no way to ask (1.12), assume the stock template exists.
local function HasTemplate(t)
  if C_XMLUtil and C_XMLUtil.GetTemplateInfo then return C_XMLUtil.GetTemplateInfo(t) ~= nil end
  return true
end

-- CreateFrame with a stock template that Mainline deprecated (OptionsSliderTemplate
-- in 10.0.0, FauxScrollFrameTemplate in 10.1.0 "will be removed in a future patch").
-- If the client lacks it the frame is made plain, so the window still opens; that
-- one control just loses its stock look. Returns the frame and whether it was templated.
function GR_Compat.TemplateFrame(kind, name, parent, template)
  if HasTemplate(template) then return CreateFrame(kind, name, parent, template), true end
  return CreateFrame(kind, name, parent), false
end

-- the Lists tab's faux scroll frame + its FrameXML helpers (same deprecated file).
-- Without them the list shows only its first rows instead of erroring.
function GR_Compat.FauxScrollFrame(name, parent)
  local sf, ok = GR_Compat.TemplateFrame("ScrollFrame", name, parent, "FauxScrollFrameTemplate")
  sf.grFaux = ok and type(FauxScrollFrame_Update) == "function"
          and type(FauxScrollFrame_GetOffset) == "function"
          and type(FauxScrollFrame_OnVerticalScroll) == "function"
  return sf
end
function GR_Compat.FauxScrollOffset(sf)
  if sf.grFaux then return FauxScrollFrame_GetOffset(sf) end
  return 0
end
function GR_Compat.FauxScrollUpdate(sf, n, shown, rowH)
  if sf.grFaux then FauxScrollFrame_Update(sf, n, shown, rowH) end
end
-- Mainline signature (self, offset, itemHeight, fn); 1.12's was (itemHeight, fn)
-- with this/arg1 globals
function GR_Compat.FauxScrollOnVertical(sf, offset, rowH, fn)
  if sf.grFaux then FauxScrollFrame_OnVerticalScroll(sf, offset, rowH, fn) end
end

-- set a stock template's caption FontString. 1.12 templates name it
-- "<frame><suffix>" (e.g. ...SliderText); Mainline ones also carry a parentKey
-- (.Text/.Low/.High, or .text on check buttons). nil-safe.
function GR_Compat.SetChildText(frame, suffix, text)
  local nm = frame:GetName()
  local fs = (nm and _G[nm..suffix]) or frame[suffix] or frame[string.lower(suffix)]
  if fs then fs:SetText(text) end
end

local VERSION    = "4.0.0-forever.1"

-- Key Bindings entry (Bindings.xml in this folder, loaded by the client): a
-- CLICK binding on the secure button GuildRecruiterNextButton. FrameXML labels
-- a binding with _G["BINDING_NAME_"..name] (GetBindingName in BindingUtil.lua),
-- and this name has a space and a colon in it, so it is set through _G.
BINDING_HEADER_GUILDRECRUITER = "Guild Rawcruiter"
_G["BINDING_NAME_"..GR_Compat.NEXT_BINDING] = "Next: one /who, whisper or guild invite"
local CAP_HINT   = 49      -- treat a query returning >= this many as truncated
local START_WIDTH = 10     -- initial level-band width to try
local WHO_TIMEOUT = 15     -- give up waiting on a /who reply after this many seconds (then retry)
local WHO_RETRIES = 3      -- re-send a band this many times on timeout before skipping past it
local SYNC_PREFIX = "GuildRec"
local PRESENCE_INTERVAL = 20  -- re-announce "I'm recruiting" this often (s)
local PRESENCE_TTL      = 60  -- forget a recruiter not heard from in this long
local WHISPER_WAIT      = 120 -- keep waiting this long for a whisper reply (s)
local BACKOFF_SECS      = 12  -- pause sends this long when the server throttles us

-- config-GUI slider ranges and option tables
local INVITE_MIN, INVITE_MAX = 1, 10
local WHO_MIN,    WHO_MAX    = 1, 15
local AUTO_MIN,   AUTO_MAX   = 5, 900   -- seconds to rest between auto-rescan cycles
local METHOD_ORDER = { "auto", "byname", "invite", "chat" }
local METHOD_LABEL = {
  auto   = "Auto (recommended)",
  byname = "Invite by name",
  invite = "Invite my target",
  chat   = "Use /ginvite command",
}
local MODE_ORDER = { "invite", "whisper", "whisperinvite" }
local MODE_LABEL = {
  invite        = "Invite only",
  whisper       = "Whisper only",
  whisperinvite = "Whisper, invite on reply",
}
-- shorter text for the compact config buttons (full labels above are for chat)
local METHOD_SHORT = { auto = "Auto", byname = "GuildInviteByName", invite = "GuildInvite", chat = "/ginvite" }
local MODE_SHORT   = { invite = "Invite only", whisper = "Whisper only", whisperinvite = "Whisper, then invite" }

-- one shared yes/cancel popup for destructive actions; GuildRecruiter_Confirm(msg, fn)
-- runs fn only if the player confirms.
StaticPopupDialogs["GUILDRECRUITER_CONFIRM"] = {
  text = "%s", button1 = "Yes", button2 = "Cancel",
  OnAccept = function() local f = GuildRecruiter_confirmFn; GuildRecruiter_confirmFn = nil; if f then f() end end,
  OnCancel = function() GuildRecruiter_confirmFn = nil end,
  timeout = 0, whileDead = 1, hideOnEscape = 1,
}
function GuildRecruiter_Confirm(msg, fn)
  GuildRecruiter_confirmFn = fn
  StaticPopup_Show("GUILDRECRUITER_CONFIRM", msg)
end

-- default whisper. Kept short and plain on purpose -- a one-line, low-pressure
-- ask reads as a person, not an ad, and fits the message box without scrolling.
-- Any earlier built-in default (OLD/LONG) is migrated forward; a message the
-- user actually customised is never touched.
local OLD_WHISPER  = "Hi %p! We're recruiting for %g -- whisper me back if you're interested and I'll send an invite. :)"
local LONG_WHISPER = "Hi %p! :) I'm recruiting for <%g>, a friendly and active guild that loves grouping up for quests, dungeons and raids. If you're after a guild, just whisper me back and I'll send an invite -- no pressure either way!"
local NEW_WHISPER  = "Hi %p! Want an invite to <%g>? Just whisper back. :)"

-- a reply matching any of these is treated as a refusal (no invite). Everything
-- else -- "sure", "y", "ok", "yea", typos, even a question -- counts as interest.
local NEGATIVES = {
  "no", "nope", "nah", "naw", "no thanks", "no thank you", "no thx", "nty",
  "not interested", "not now", "maybe later", "pass", "im good", "no im good",
  "leave me alone", "leave me", "stop", "go away", "not looking",
  "already in", "already in a guild", "have a guild", "got a guild",
  "busy", "fuck off", "piss off", "reported", "report",
}
-- whitelist used by the "yesonly" reply policy (invite only if a reply matches)
local AFFIRM_DEFAULTS = {
  "yes", "yeah", "yep", "yup", "ya", "yea", "yess", "yas", "y", "yes please",
  "sure", "ok", "okay", "kk", "alright", "aight", "of course", "ofc",
  "definitely", "absolutely", "sounds good", "why not", "go ahead", "go for it",
  "please", "pls", "plz", "im in", "count me in", "sign me up", "lets go",
  "do it", "send it", "invite me", "inv me", "add me", "invite", "inv",
  "for sure", "id love to", "love to", "happy to",
}
-- how a whisper reply is judged in whisper-then-invite mode
local REPLY_ORDER = { "notno", "yesonly", "any" }
local REPLY_LABEL = {
  notno   = "Unless they say no",   -- invite unless reply hits the refusal list
  yesonly = "Only on a yes word",   -- invite only if reply hits the yes list
  any     = "Any reply at all",     -- invite on any reply, no filtering
}
-- which settings a profile snapshots (history/blacklist/stats/negatives stay global)
local PROFILE_KEYS = {
  "inviteDelay", "whoDelay", "reinviteDays", "mode", "whisperMsg", "minLevel",
  "maxLevel", "sessionCap", "jitter", "skipCombat", "skipInstance", "guildSync",
  "quietWho", "inviteMethod", "replyMode", "classFilter",
}

local f = CreateFrame("Frame", "GuildRecruiterFrame")

-- run state
local running, scanning, awaiting, paused = false, false, false, false
local lo        = 1        -- next uncovered level in the sweep
local width     = START_WIDTH
local observedCap = 0      -- largest /who result count seen this run; the server's
                           -- real cap is learned, not assumed (see ProcessWho)
local myLo, myHi = 1, 60   -- my assigned slice of the level range (after split)
local pending   = {}       -- targeted class sub-queries for dense levels
local current   = nil      -- slice currently being queried
local contactQueue = {}    -- guildless names pending a contact
local replyQueue   = {}    -- names who replied to a whisper, pending an invite
local seen      = {}       -- names already handled this run
local whispered = {}       -- [name] = GetTime() we whispered (awaiting reply)
local recruiters = {}      -- [name] = GetTime() last presence ping (others)
local hideSoon  = false
local inCombat  = false
local classes   = {}       -- our faction's class names
local backoffUntil = 0
local presenceTimer = 0

local whoTimer, inviteTimer, whoTimeout = 0, 0, 0
local whoRetries = 0       -- consecutive timeouts on the current band before we give up on it
local stats = { contacted=0, invited=0, whispered=0, guilded=0, scanned=0, queries=0, dropped=0, cooldown=0, collected=0 }

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Rawcruiter|r: "..msg)
end

local function clamp(v, a, b)
  if v < a then return a elseif v > b then return b else return v end
end

local function CountTable(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Stop the default UI's Who panel from popping during a run. We unregister
-- WHO_LIST_UPDATE on the default Who list (GR_Compat.WhoPanel: FriendsFrame on
-- 1.12/Mainline, LFGWhoListFrame on Forever; our own frame still receives it) so
-- the window never opens at all -- no open-then-hide flicker. Restored when we stop.
local whoSuppressed = false
local function SuppressWho(on)
  if on then
    if not whoSuppressed and GuildRecruiter_Settings.hideWho then
      GR_Compat.MuteWhoWindow(true)   -- the frame is chosen in GR_Compat.WhoPanel
      whoSuppressed = true
    end
  elseif whoSuppressed then
    GR_Compat.MuteWhoWindow(false)
    whoSuppressed = false
  end
end

-- ---------------------------------------------------------------------------
-- Settings defaults
-- ---------------------------------------------------------------------------
local function Defaults()
  local s = GuildRecruiter_Settings
  if not s.inviteDelay  then s.inviteDelay  = 1 end    -- base seconds between contacts
  if not s.whoDelay     then s.whoDelay     = 3 end    -- base seconds between /who
  if not s.reinviteDays then s.reinviteDays = 14 end   -- 0 = never re-invite
  if not s.history      then s.history      = {} end   -- [name] = last contact time()
  if s.hideWho == nil   then s.hideWho      = true end
  if not s.inviteMethod then s.inviteMethod = "auto" end
  if not s.mode         then s.mode         = "invite" end  -- invite|whisper|whisperinvite
  if not s.whisperMsg or s.whisperMsg == OLD_WHISPER or s.whisperMsg == LONG_WHISPER then s.whisperMsg = NEW_WHISPER end
  if not s.minLevel     then s.minLevel     = 1 end
  if not s.maxLevel     then s.maxLevel     = 60 end
  if not s.classFilter  then s.classFilter  = nil end  -- nil = all classes; else set of lowercase names
  if not s.blacklist    then s.blacklist    = {} end   -- [lowername] = true
  if not s.sessionCap   then s.sessionCap   = 0 end    -- 0 = unlimited contacts per run
  if s.jitter == nil    then s.jitter       = false end
  if s.skipCombat == nil   then s.skipCombat   = true end
  if s.skipInstance == nil then s.skipInstance = true end
  if s.guildSync == nil    then s.guildSync    = true end
  if s.quietWho == nil     then s.quietWho     = true end  -- hide /who chat spam during a run
  if not s.replyMode then   -- how whisper replies are judged: notno|yesonly|any
    s.replyMode = (s.affirmOnly == false) and "any" or "notno"  -- migrate old affirmOnly
  end
  if not s.negatives then   -- editable refusal-word list ("notno" mode skips these)
    s.negatives = {}
    for i = 1, #NEGATIVES do s.negatives[NEGATIVES[i]] = true end
  end
  if not s.affirmatives then   -- editable yes-word list ("yesonly" mode requires these)
    s.affirmatives = {}
    for i = 1, #AFFIRM_DEFAULTS do s.affirmatives[AFFIRM_DEFAULTS[i]] = true end
  end
  if not s.profiles then s.profiles = {} end
  if not s.tally then s.tally = {} end
  if not s.tally.totals then s.tally.totals = { invited=0, whispered=0, joined=0, declined=0 } end
  if not s.tally.days   then s.tally.days   = {} end
  if not s.varStats then s.varStats = {} end   -- [profile] = {contacted,joined,declined}
  if s.abOn == nil  then s.abOn = false end     -- simultaneous A/B: deal each contact a variant
  if not s.abWeightA then s.abWeightA = 1 end   -- frequency weight of the control (variant A)
  if s.collectOnly == nil then s.collectOnly = false end  -- scan into a list instead of contacting
  if s.autoScan == nil then s.autoScan = false end         -- loop: after a scan sweep finishes, rest then sweep again
  if not s.autoScanDelay then s.autoScanDelay = 60 end     -- seconds to rest between auto-rescan cycles
  if s.debug == nil then s.debug = false end               -- print per-/who diagnostics during a scan
  if not s.ready then s.ready = {} end                     -- [name] = {t, kind, v}: waiting for the player's own guild invite (key-press mode; persists)
  if s.readyAlert == nil then s.readyAlert = true end      -- sound + taskbar flash when a reply lands on the Ready list
  if not s.readyTTL then s.readyTTL = 30 end               -- minutes a Ready entry waits before it expires (no invite recorded)
  if not s.candidates then s.candidates = {} end          -- [name] = {t, level, class}; persists across logout
  if not s.dataset then s.dataset = {} end                -- [name] = {race, class, level, t}; every player seen in /who, for name-corpus building (persists across logout)
  -- abVariants are the CHALLENGERS only (B/C/D). Variant A is always the live
  -- Settings tab (the control), so it is never stored here.
  if not s.abVariants then s.abVariants = {} end
  local chal, used = {}, {}                       -- max 3 challengers; names B/C/D, kept stable
  for i = 1, #s.abVariants do
    local v = s.abVariants[i]
    if type(v) == "string" then                   -- legacy: flagged-profile-name string -> table
      local p = s.profiles and s.profiles[v]
      v = { mode = p and p.mode, whisperMsg = p and p.whisperMsg,
            inviteMethod = p and p.inviteMethod, replyMode = p and p.replyMode }
    end
    -- "A" used to be a stored variant; it's the control now, so drop it. Keep an
    -- already-valid, unused B/C/D name as-is (so stats stay attached); only mint
    -- a new name for a bad/missing/duplicate one. Never reshuffle on load.
    if v.name ~= "A" and #chal < 3 then
      local nm = v.name
      if (nm ~= "B" and nm ~= "C" and nm ~= "D") or used[nm] then
        nm = nil
        for k = 1, 3 do local c = string.sub("BCD", k, k); if not used[c] then nm = c; break end end
      end
      v.name = nm; used[nm] = true
      tinsert(chal, v)
    end
  end
  s.abVariants = chal
  if not s.minimapAngle then s.minimapAngle = 210 end
  -- prune history past the cooldown so the saved table can't grow forever
  if s.reinviteDays > 0 then
    local cutoff = time() - s.reinviteDays * 86400
    for n, e in pairs(s.history) do
      local et = (type(e) == "table") and e.t or e   -- entries are {t,p} now; tolerate old numbers
      if (et or 0) < cutoff then s.history[n] = nil end
    end
  else
    -- reinviteDays == 0 ("never re-invite") skips time-pruning, so history grows
    -- forever. Cap the SavedVariables at ~1 year of entries to bound memory.
    local cutoff = time() - 365 * 86400
    for n, e in pairs(s.history) do
      local et = (type(e) == "table") and e.t or e
      if (et or 0) < cutoff then s.history[n] = nil end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Analytics tally (persisted: lifetime totals + per-day buckets)
-- ---------------------------------------------------------------------------
local function Today()
  if type(date) == "function" then return date("%Y%m%d") end
  return "alltime"
end

local function TallyBump(field)
  local t = GuildRecruiter_Settings.tally
  if not t then return end
  t.totals[field] = (t.totals[field] or 0) + 1
  local d = Today()
  if not t.days[d] then t.days[d] = { invited=0, whispered=0, joined=0, declined=0 } end
  t.days[d][field] = (t.days[d][field] or 0) + 1
end

-- ---------------------------------------------------------------------------
-- Affirmative-reply detection
-- ---------------------------------------------------------------------------
local function Normalize(s)
  s = string.lower(s or "")
  s = string.gsub(s, "'", "")            -- drop apostrophes so "i'm" == "im"
  s = string.gsub(s, "[^%a%d ]", " ")    -- other punctuation -> space
  s = " " .. s .. " "
  s = string.gsub(s, "%s+", " ")
  return s
end

-- Treat a whisper reply as interest UNLESS it's a clear refusal. Requiring an
-- exact "yes" missed "sure", "y", "ok", typos, etc., so we invert: any reply
-- that doesn't contain a negative phrase counts (they bothered to whisper back).
-- decide whether a whisper reply should trigger an invite, per the reply policy
local function ShouldInvite(reply, vname)
  local v = GuildRecruiter_VariantByName(vname)               -- the variant that contacted them
  local mode = (v and v.replyMode) or GuildRecruiter_Settings.replyMode or "notno"
  if mode == "any" then return true end
  local norm = Normalize(reply)
  if mode == "yesonly" then
    for phrase in pairs(GuildRecruiter_Settings.affirmatives or {}) do
      if string.find(norm, " " .. phrase .. " ", 1, true) then return true end
    end
    return false
  end
  -- "notno": invite unless a refusal word appears
  for phrase in pairs(GuildRecruiter_Settings.negatives or {}) do
    if string.find(norm, " " .. phrase .. " ", 1, true) then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Guild join / decline detection (locale-safe via the client's format strings)
-- ---------------------------------------------------------------------------
local function ToPattern(s)
  if not s then return nil end
  s = string.gsub(s, "%%s", "\001")                                   -- protect the name slot
  s = string.gsub(s, "([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")           -- escape magic chars
  s = string.gsub(s, "\001", "(.+)")                                  -- name slot -> capture
  return "^" .. s .. "$"
end
-- built from the client's format strings when present, with an enUS fallback so
-- detection still works if those globals are absent/renamed on this core
local JOIN_PAT    = ToPattern(ERR_GUILD_JOIN_S)    or "^(.+) has joined the guild"
local DECLINE_PAT = ToPattern(ERR_GUILD_DECLINE_S) or "^(.+) declines your guild invitation"

-- ---------------------------------------------------------------------------
-- Skip rules: recently contacted, blacklisted
-- ---------------------------------------------------------------------------
local function RecentlyInvited(name)
  local s = GuildRecruiter_Settings
  local e = s.history and s.history[name]
  if not e then return false end
  local days = s.reinviteDays
  if days <= 0 then return true end
  local t = (type(e) == "table") and e.t or e   -- {t,p} now; tolerate old numbers
  return (time() - (t or 0)) < days * 86400
end

local function Blacklisted(name)
  local bl = GuildRecruiter_Settings.blacklist
  return bl and bl[string.lower(name)] and true or false
end

-- ---------------------------------------------------------------------------
-- Guild coordination (addon messages over GUILD)
-- ---------------------------------------------------------------------------
local RecomputeBand  -- forward decl (defined below; used by the message handler)

local function Broadcast(payload)
  if GuildRecruiter_Settings.guildSync and IsInGuild() then
    GR_Compat.SendAddonMessage(SYNC_PREFIX, "V1 "..payload, "GUILD")
  end
end

-- names of all recruiters currently active (self when running, plus live peers)
local function ActiveNames()
  local me = GR_Compat.MyName()   -- full name: peers are keyed by their full sender name
  local names = {}
  if running then tinsert(names, me) end
  for n, _ in pairs(recruiters) do
    if n ~= me then tinsert(names, n) end
  end
  if #names == 0 then tinsert(names, me) end  -- always at least self
  table.sort(names)
  return names
end

-- divide [minLevel, maxLevel] evenly among the active recruiters; take my chunk
RecomputeBand = function()
  local s = GuildRecruiter_Settings
  local loL, hiL = s.minLevel, s.maxLevel
  if loL > hiL then loL, hiL = hiL, loL end   -- tolerate reversed saved bounds
  if not s.guildSync or not IsInGuild() then
    myLo, myHi = loL, hiL
  else
    local names = ActiveNames()
    local total = #names
    local me = GR_Compat.MyName()
    local idx = 1
    for i = 1, total do if names[i] == me then idx = i end end
    local span = hiL - loL + 1
    local per  = math.ceil(span / total)
    myLo = loL + (idx - 1) * per
    myHi = myLo + per - 1
    if myHi > hiL then myHi = hiL end
    if myLo > hiL then myLo = hiL + 1 end  -- nothing left for me
  end
  -- if my band grew while idle but the run is alive, resume the sweep -- but
  -- ONLY for a scan run. A send/invite-all run is running with scanning=false on
  -- purpose; without this guard Resume() (or a peer's HI/BYE) would flip it into
  -- a /who scan.
  if running and GuildRecruiter_runKind == "scan" and not scanning and lo <= myHi then scanning = true end
end

-- CHAT_MSG_ADDON payload: (prefix, text, channel, sender)
local function OnAddonMessage(prefix, text, channel, sender)
  local sec = GR_Compat.IsSecret
  if sec(prefix) or sec(text) or sec(sender) then return end   -- unreadable: skip, never compare
  if prefix ~= SYNC_PREFIX then return end
  local me = GR_Compat.MyName()                    -- Forever: "First Surname", like the sender
  sender = GR_Compat.ShortName(sender)             -- Mainline sends "Name-Realm"
  if not sender or sender == me then return end   -- ignore our own echo
  local _, _, ver, kind, rest = string.find(text or "", "^(%S+)%s+(%S+)%s*(.*)$")
  if ver ~= "V1" then return end
  if kind == "INV" then
    if rest and rest ~= "" then
      if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
      GuildRecruiter_Settings.history[rest] = { t = time(), p = "(remote)" }  -- guild-wide dedup
      seen[rest] = true
    end
  elseif kind == "HI" then
    local changed = (recruiters[sender] == nil)
    recruiters[sender] = GetTime()
    if changed then RecomputeBand() end
  elseif kind == "BYE" then
    if recruiters[sender] then
      recruiters[sender] = nil
      RecomputeBand()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Contacting: invite and/or whisper
-- ---------------------------------------------------------------------------
-- The invite call itself is chosen in GR_Compat.GuildInvite. Key-press mode:
-- "/ginvite name" set on the secure Next button during its PreClick (works only
-- there). Timer-loop client: C_GuildInfo.Invite where it exists, else
-- GuildInviteByName (Turtle's name-taking invite; bare GuildInvite() invites
-- your TARGET on some cores), else GuildInvite, else /ginvite.
local function DoGuildInvite(name, method)
  GR_Compat.GuildInvite(name, method or GuildRecruiter_Settings.inviteMethod or "auto")
end

local function WhisperBody(name, msg)
  msg = msg or GuildRecruiter_Settings.whisperMsg or ""
  local gname = GetGuildInfo("player") or "our guild"
  msg = string.gsub(msg, "%%p", name)
  msg = string.gsub(msg, "%%g", gname)
  -- hard cap: a chat message over 255 chars DISCONNECTS the client. Token expansion
  -- (%p/%g) can push an at-the-limit template over, so clamp after expansion.
  if string.len(msg) > 255 then msg = string.sub(msg, 1, 255) end
  return msg
end

-- global so contact/event code adds no upvalues; per-profile conversion counters
function GuildRecruiter_VarBump(profile, field)
  profile = profile or "(live)"
  local vs = GuildRecruiter_Settings.varStats
  if not vs then return end
  if not vs[profile] then vs[profile] = { contacted = 0, joined = 0, declined = 0 } end
  vs[profile][field] = (vs[profile][field] or 0) + 1
end

-- A/B model: variant "A" is the live Settings config (the control) and is NOT
-- stored; s.abVariants holds only the challengers (B/C/D). A/B is "active" once
-- it's switched on AND at least one challenger exists (so the pool is A + >=1).
function GuildRecruiter_ABActive()
  local s = GuildRecruiter_Settings
  return s.abOn and s.abVariants and #s.abVariants >= 1
end

-- deal a variant to a contact, weighted by each variant's frequency. nil =
-- control A (live). A's weight is s.abWeightA; each challenger has v.weight.
function GuildRecruiter_PickVariant()
  if not GuildRecruiter_ABActive() then return nil end
  local s = GuildRecruiter_Settings
  local av = s.abVariants
  local wA = s.abWeightA or 1
  local total = wA
  for i = 1, #av do total = total + (av[i].weight or 1) end
  local r = random(1, total)
  if r <= wA then return nil end        -- landed in the control's share
  r = r - wA
  for i = 1, #av do
    local w = av[i].weight or 1
    if r <= w then return av[i] end
    r = r - w
  end
  return nil
end

-- adjust a variant's frequency weight (variant=nil means the control A). Clamped
-- 1..9. GLOBAL so the A/B weight buttons add no upvalue to the panel builder.
function GuildRecruiter_BumpWeight(variant, delta)
  local s = GuildRecruiter_Settings
  if variant then variant.weight = clamp((variant.weight or 1) + delta, 1, 9)
  else s.abWeightA = clamp((s.abWeightA or 1) + delta, 1, 9) end
  GuildRecruiter_RefreshOpen()
end

-- tooltip for the A/B weight buttons (so right-click-to-decrement is discoverable)
function GuildRecruiter_WeightTip(btn)
  GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
  GameTooltip:SetText("Frequency weight")
  GameTooltip:AddLine("Left-click: +1     Right-click: -1", 1, 1, 1)
  GameTooltip:AddLine("Higher weight = dealt to a larger share of contacts.", 0.7, 0.7, 0.7, 1)
  GameTooltip:Show()
end

-- per-contact settings for a variant table (blank fields fall back to live)
function GuildRecruiter_CfgOf(v)
  local s = GuildRecruiter_Settings
  if not v then v = s end   -- nil variant -> live settings
  return {
    mode         = v.mode         or s.mode or "invite",
    whisperMsg   = v.whisperMsg   or s.whisperMsg,
    inviteMethod = v.inviteMethod or s.inviteMethod,
    replyMode    = v.replyMode    or s.replyMode or "notno",
  }
end

-- find a variant table by name (to credit a reply/join back to it)
function GuildRecruiter_VariantByName(nm)
  local av = GuildRecruiter_Settings.abVariants
  if nm and av then
    for i = 1, #av do if av[i].name == nm then return av[i] end end
  end
  return nil
end

local function RecordHandled(name, vname)
  if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
  GuildRecruiter_Settings.history[name] = { t = time(), p = vname }
  Broadcast("INV "..name)
end

-- perform the configured contact action for one name. v = the A/B variant dealt
-- to it (challenger table, or nil = control A); see GuildRecruiter_DealHead.
-- Returns true when the contact was only an invite PROMPT (key-press mode): the
-- name went to the Ready list and nothing is counted as invited until Done.
local function Contact(name, v)
  local cfg = GuildRecruiter_CfgOf(v)
  -- during an A/B test a nil pick is the control, credited as "A"; otherwise
  -- (A/B off) it's just the active profile, for sequential profile comparison.
  local vname = (v and v.name) or (GuildRecruiter_ABActive() and "A") or GuildRecruiter_Settings.activeProfile
  if cfg.mode == "whisper" then
    GR_Compat.SendWhisper(WhisperBody(name, cfg.whisperMsg), name)
    stats.whispered = stats.whispered + 1; TallyBump("whispered")
    RecordHandled(name, vname)
  elseif cfg.mode == "whisperinvite" then
    GR_Compat.SendWhisper(WhisperBody(name, cfg.whisperMsg), name)
    stats.whispered = stats.whispered + 1; TallyBump("whispered")
    whispered[name] = { t = GetTime(), v = vname }
    RecordHandled(name, vname)   -- the whisper is the contact: history = re-contact cooldown
  else
    DoGuildInvite(name, cfg.inviteMethod)
    if GR_Compat.RequiresHardwareEvent then
      -- key-press mode: that was only the prompt (copy box + chat link). Park the
      -- name on the Ready list; history, stats.invited, the tally and the A/B
      -- "contacted" count are recorded by GuildRecruiter_ReadyDone. contacted
      -- here is the run's step count (session cap, progress) only.
      GuildRecruiter_ReadyAdd(name, "invite", vname, true)
      stats.contacted = stats.contacted + 1
      return true
    end
    stats.invited = stats.invited + 1; TallyBump("invited")
    RecordHandled(name, vname)
  end
  stats.contacted = stats.contacted + 1
  GuildRecruiter_VarBump(vname, "contacted")
  return false
end

-- ---------------------------------------------------------------------------
-- Scan core (no race split; class is the finest subdivision)
-- ---------------------------------------------------------------------------
local function BuildFilter(s)
  local parts = {}
  if s.lo == s.hi then tinsert(parts, "" .. s.lo)
  else tinsert(parts, s.lo .. "-" .. s.hi) end
  if s.class then tinsert(parts, 'c-"' .. s.class .. '"') end
  return table.concat(parts, " ")
end

-- pick the next slice into `current`. peek = only say whether one is left
-- (no state change), for the key-press mode's timer and Next button.
local function NextQuery(peek)
  if #pending > 0 then
    if not peek then current = tremove(pending, 1) end
    return true
  end
  local start = (lo < myLo) and myLo or lo
  if peek then return start <= myHi and start <= 60 end
  lo = start
  if lo <= myHi and lo <= 60 then
    local hi = lo + width - 1
    if hi > myHi then hi = myHi end
    if hi > 60 then hi = 60 end
    current = { lo = lo, hi = hi, sweep = true }
    return true
  end
  return false
end

-- Sweep of my level band is done. Sends no /who. If auto-rescan is on (and this
-- is a scan run, not a send/blast), rest for autoScanDelay and then sweep again
-- instead of ending -- catches players who log in later. `seen` is kept across
-- cycles so a repeat sweep only acts on newly-appeared guildless players, and the
-- persistent re-invite cooldown still guards against re-contacting. We keep
-- scanning=true through the rest so the run stays alive (the drain-complete
-- branch won't fire) and contacts keep draining in parallel.
local function FinishSweep()
  if GuildRecruiter_runKind == "scan" and GuildRecruiter_Settings.autoScan then
    local gap = GuildRecruiter_Settings.autoScanDelay or 60
    GuildRecruiter_rescanWait = gap
    Print("Scan cycle done ("..stats.queries.." queries). Rescanning in "..math.floor(gap).."s. /gr stop to end.")
    return
  end
  scanning = false
  if GuildRecruiter_Settings.collectOnly then
    Print("Scan complete: "..stats.queries.." queries, collected "..stats.collected.." (list now "..CountTable(GuildRecruiter_Settings.candidates).."). Send from the Lists tab.")
  else
    Print("Scan complete: "..stats.queries.." queries, "..#contactQueue.." left to contact.")
  end
end

-- RESTRICTED (sends a /who). Callers: the 1.12 timer branch of GR_OnUpdate
-- (only when not GR_Compat.RequiresHardwareEvent) and GuildRecruiter_NextPress.
local function SendNextWho()
  if not NextQuery() then FinishSweep(); return end
  awaiting = true
  whoTimeout = WHO_TIMEOUT
  stats.queries = stats.queries + 1
  GR_Compat.SendWho(BuildFilter(current))
end

local function ClassAllowed(class)
  local cf = GuildRecruiter_Settings.classFilter
  if not cf then return true end
  return cf[string.lower(class or "")] and true or false
end

local function ProcessWho()
  local me = GR_Compat.MyName()   -- compared with the /who fullName (Blizzard: WhoList.lua:94)
  local num = GR_Compat.GetNumWhoResults()
  local inBand = 0
  for i = 1, num do
    -- 1.12 order: name, guild, level, race, class, zone (GR_Compat maps the
    -- Mainline WhoInfo table onto it and returns a nil name for a secret row)
    local name, guild, level, race, class = GR_Compat.GetWhoRow(i)
    if name then
      stats.scanned = stats.scanned + 1
      -- Name-corpus collector: record EVERY player seen in /who (guilded or not),
      -- keyed by name -> race/class/level/last-seen. Independent of the contact
      -- pipeline so it builds a full race+class-tagged dataset. All global-keyed,
      -- so it adds no upvalues to ProcessWho. (Gender is not available from /who.)
      if name ~= me and GuildRecruiter_Settings.dataset then
        local rec = GuildRecruiter_Settings.dataset[name] or {}
        rec.race  = race  or rec.race
        rec.class = class or rec.class
        rec.level = level or rec.level
        rec.t = time()
        GuildRecruiter_Settings.dataset[name] = rec
      end
      if current and level and level >= current.lo and level <= (current.hi or current.lo)
         and (not current.class or class == current.class) then inBand = inBand + 1 end
      if name == me or seen[name] then
        -- skip
      elseif guild and guild ~= "" then
        stats.guilded = stats.guilded + 1; seen[name] = true
      elseif Blacklisted(name) then
        seen[name] = true
      elseif not ClassAllowed(class) then
        seen[name] = true
      elseif RecentlyInvited(name) or GuildRecruiter_ReadyHas(name) then   -- cooldown, or already waiting on the Ready list
        stats.cooldown = stats.cooldown + 1; seen[name] = true
      else
        seen[name] = true
        if GuildRecruiter_Settings.collectOnly then        -- build a list now, contact later
          if not GuildRecruiter_Settings.candidates[name] then
            GuildRecruiter_Settings.candidates[name] = { t = time(), level = level, class = class }
            stats.collected = stats.collected + 1
          end
        else
          tinsert(contactQueue, name)
        end
      end
    end
  end

  -- Learn the server's real /who cap instead of assuming 49. The most rows the
  -- server has ever handed us is at-or-below its true cap, so a query that hits
  -- that ceiling is presumed truncated and gets subdivided. CAP_HINT is only an
  -- upper bound for the first few queries. This is coverage-safe: it can only
  -- over-subdivide (slower but complete), never miss people on a low-cap server.
  if num > observedCap then observedCap = num end
  local ceiling = (observedCap < CAP_HINT) and observedCap or CAP_HINT
  local capped = (num >= ceiling and num >= 5)
  local c = current
  local band = c and (c.lo..(c.hi and c.hi ~= c.lo and ("-"..c.hi) or "")..(c.class and (" c-"..c.class) or "")) or "?"

  -- CRITICAL: only the reply we're actively awaiting may move the sweep cursor.
  -- A reply that lands after we already timed out (or any stray WHO_LIST_UPDATE)
  -- still harvests players above -- that's safe, seen[] dedups -- but must NOT
  -- touch lo/width. Otherwise a late "1-10 capped" reply rewrites the cursor
  -- after the timeout already advanced it, and the sweep jumps forward in coarse
  -- bands (1-10 -> 11-15 -> ...) instead of subdividing, so anyone past the /who
  -- cap in a dense low-level band is never found.
  if not awaiting then
    if GuildRecruiter_Settings.debug then Print("who "..band.." results="..num.." (late/stray reply -- harvested only, cursor unchanged)") end
    return
  end

  -- band sanity: the player's own manual /who can land while we're awaiting and be
  -- mistaken for our reply (1.12 gives no query id). Our query filters server-side by
  -- band, so OUR reply's results all fit the band; if NONE do, it's foreign -- harvest
  -- only and keep awaiting our real reply (or let the timeout retry).
  if num > 0 and c and inBand == 0 then
    if GuildRecruiter_Settings.debug then Print("who "..band.." results="..num.." (none in band -- foreign /who? cursor unchanged)") end
    return
  end

  if GuildRecruiter_Settings.debug then
    Print("who "..band.."  results="..num.." cap~="..ceiling.." capped="..(capped and "Y" or "n"))
  end

  if c and c.sweep then
    if capped then
      if c.lo < c.hi then
        -- re-scan THIS band from its start at half width. Absolute positioning:
        -- we do NOT trust `lo`, which the timeout path may have advanced.
        lo = c.lo
        width = math.floor((c.hi - c.lo + 1) / 2)
        if width < 1 then width = 1 end
        if GuildRecruiter_Settings.debug then Print("  -> capped: subdividing to "..lo.."-"..(lo + width - 1)) end
      else
        for i = 1, #classes do
          tinsert(pending, { lo = c.lo, hi = c.lo, class = classes[i] })
        end
        lo = c.lo + 1; width = 1
        if GuildRecruiter_Settings.debug then Print("  -> lvl "..c.lo.." capped: splitting by class ("..#classes.." queries)") end
      end
    else
      lo = c.hi + 1
      if num < ceiling * 0.6 then width = math.floor(width * 1.7) + 1 end
      local remain = myHi - lo + 1
      if width > remain then width = remain end
      if width < 1 then width = 1 end
    end
  elseif c and capped then
    -- a single class at a single level is still capped -- take what we got
    stats.dropped = stats.dropped + 1
    if GuildRecruiter_Settings.debug then Print("  -> lvl "..c.lo.." c-"..(c.class or "?").." still capped; some dropped") end
  end

  awaiting = false
  whoRetries = 0
  whoTimer = GuildRecruiter_Settings.whoDelay
end

-- Re-arm the level-band sweep for another auto-rescan cycle. GLOBAL so it costs
-- GR_OnUpdate zero upvalues (Lua 5.0 caps them at 32/function). We reset the
-- sweep position but deliberately KEEP `seen` (and the learned observedCap and
-- cumulative stats) so a repeat cycle only picks up newly-arrived guildless
-- players rather than re-processing everyone.
function GuildRecruiter_RestartScanCycle()
  GuildRecruiter_rescanWait = 0
  scanning, awaiting = true, false
  current = nil
  pending = {}
  RecomputeBand()
  lo, width, whoRetries = myLo, START_WIDTH, 0
  whoTimer = 0
  stats.cycles = (stats.cycles or 0) + 1
  if GuildRecruiter_Settings.debug then Print("Auto-rescan: starting cycle "..stats.cycles.." on levels "..myLo.."-"..myHi..".") end
  -- key-press mode: the new sweep's first /who (like every /who) waits for Next
  if GR_Compat.RequiresHardwareEvent then Print("Auto-rescan: sweep "..stats.cycles.." of levels "..myLo.."-"..myHi.." is ready -- press Next to start it.") end
end

-- ---------------------------------------------------------------------------
-- Pacing helpers
-- ---------------------------------------------------------------------------
local function Pace(base)
  if GuildRecruiter_Settings.jitter then
    -- random(0,120)/100 is in [0,1.2]; gives a delay uniformly in [base, base*2.2]
    return base + (random(0, 120) / 100) * base
  end
  return base
end

local function InstanceBlocked()
  if not GuildRecruiter_Settings.skipInstance then return false end
  if type(IsInInstance) == "function" then
    local inside = IsInInstance()
    if inside and inside ~= 0 and inside ~= "none" then return true end
  end
  return false
end

-- can we send a contact/invite right now? false, or the reason (a string, so
-- it still reads as true) -- the Next button shows it
local function SendsBlocked()
  if GetTime() < backoffUntil then return "server throttle" end
  if GuildRecruiter_Settings.skipCombat and inCombat then return "in combat" end
  if InstanceBlocked() then return "in an instance" end
  return false
end

local function CapReached()
  local cap = GuildRecruiter_Settings.sessionCap
  return cap and cap > 0 and stats.contacted >= cap
end

-- ---------------------------------------------------------------------------
-- Error handling + abort
-- ---------------------------------------------------------------------------
local function Abort(reason)
  running, scanning, awaiting, paused = false, false, false, false
  GuildRecruiter_rescanWait = 0
  GuildRecruiter_dealt = nil    -- no stale A/B deal carried into the next run
  SuppressWho(false)
  GR_Compat.SetWhoToUI(false)   -- = RestoreWho (defined later; called directly to avoid a forward ref)
  Print("|cffff4040Stopped on error:|r "..tostring(reason))
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local InitMinimap  -- forward decl

-- Mainline hands the event payload to the handler as arguments (1.12 used the
-- globals event / arg1..argN), so GR_OnEvent(event, ...) receives exactly it.
local initDone = false
local function GR_OnEvent(event, ...)
  local a1, a2 = ...
  if event == "ADDON_LOADED" or event == "VARIABLES_LOADED" then
    -- ADDON_LOADED(our folder) = our SavedVariables are in. VARIABLES_LOADED (the
    -- 1.12 init event) is kept as a fallback. Init runs once.
    if initDone or (event == "ADDON_LOADED" and a1 ~= ADDON_NAME) then return end
    initDone = true
    GuildRecruiter_Settings = GuildRecruiter_Settings or {}
    Defaults()
    InitMinimap()
    GuildRecruiter_SyncNext()   -- key-press mode: build the secure Next button (hidden) out of combat
    Print("v"..VERSION.." loaded. "..GR_Compat.ApiSummary()..". /gr for commands, /gr config for settings.")
    GuildRecruiter_ReadyLoad()  -- names still waiting from before the reload: show the Ready panel
  elseif event == "WHO_LIST_UPDATE" and running then
    ProcessWho()
    if GuildRecruiter_Settings.hideWho then hideSoon = true end
  elseif event == "CHAT_MSG_ADDON" then
    OnAddonMessage(...)
  elseif event == "CHAT_MSG_SYSTEM" then
    if GR_Compat.IsSecret(a1) then return end   -- unreadable system text: skip, never compare
    local raw = a1 or ""
    local m = string.lower(raw)
    if GR_Compat.IsThrottleMsg(m) then
      backoffUntil = GetTime() + BACKOFF_SECS
      Print("|cffffcc00Server throttle detected -- pausing sends "..BACKOFF_SECS.."s.|r")
    end
    -- analytics: attribute a join to us only if we contacted them; declines of
    -- our invitation are always ours. The name may arrive as a player link or as
    -- "First Surname" / "First-Surname" (PlainName + FindKey, both unverified).
    -- A join or decline of someone on the Ready list proves the player's invite
    -- reached them, so that invite is counted first (GuildRecruiter_ReadyDone,
    -- which also writes the history the join attribution below reads).
    local hist = GuildRecruiter_Settings.history
    if JOIN_PAT then
      local _, _, jn = string.find(raw, JOIN_PAT)
      jn = jn and GR_Compat.PlainName(jn)
      if jn then GuildRecruiter_ReadyDone(jn, "joined") end
      local jk = jn and GR_Compat.FindKey(hist, jn)
      local e = jk and hist[jk]
      if e then
        TallyBump("joined")
        local p = (type(e) == "table") and e.p or nil
        if p ~= "(remote)" then GuildRecruiter_VarBump(p, "joined") end  -- a peer's contact isn't our variant
      end
    end
    if DECLINE_PAT then
      local _, _, dn = string.find(raw, DECLINE_PAT)
      dn = dn and GR_Compat.PlainName(dn)
      if dn then
        GuildRecruiter_ReadyDone(dn, "declined")
        TallyBump("declined")
        local dk = GR_Compat.FindKey(hist, dn)
        local e = dk and hist[dk]
        local p = (type(e) == "table") and e.p or nil
        if e and p ~= "(remote)" then GuildRecruiter_VarBump(p, "declined") end
      end
    end
  elseif event == "CHAT_MSG_WHISPER" then
    -- payload (text, sender, ...); a secret text or sender is skipped, never compared
    if GR_Compat.IsSecret(a1) or GR_Compat.IsSecret(a2) then return end
    local sender = GR_Compat.ShortName(a2)   -- Mainline sends "Name-Realm"
    local key = sender and GR_Compat.FindKey(whispered, sender)   -- "First Surname" or "First-Surname"
    local w = key and whispered[key]
    if w then
      if ShouldInvite(a1, w.v) then   -- judge with the variant that whispered them
        whispered[key] = nil
        if GR_Compat.RequiresHardwareEvent then
          -- key-press mode: straight onto the Ready list, with the alert. No press
          -- and no invite: the player invites from Blizzard's Invite Member box.
          GuildRecruiter_ReadyAdd(key, "reply", w.v)
        else
          tinsert(replyQueue, key)    -- timer-loop client: invite (paced) from Drain
        end
      end
      -- otherwise keep waiting -- a later, clearer "yes" still triggers it
    end
  elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    local line = GR_Compat.BlockedLine(event, a1, a2)   -- nil unless it names this addon
    if line then GuildRecruiter_PauseBlocked(line) end
  elseif event == "PLAYER_REGEN_DISABLED" then
    inCombat = true
    -- lockdown starts right AFTER this event: last chance to empty the secure
    -- button (it is already empty between clicks; SecureClear checks lockdown)
    GR_Compat.SecureClear(GuildRecruiterNextButton)
  elseif event == "PLAYER_REGEN_ENABLED" then
    inCombat = false
    GuildRecruiter_SyncNext()   -- lockdown is over: build / show / hide the secure Next button
  end
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("VARIABLES_LOADED")
f:RegisterEvent("WHO_LIST_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("CHAT_MSG_WHISPER")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
GR_Compat.WatchBlocked(f)                    -- ADDON_ACTION_BLOCKED / _FORBIDDEN: pause + say which call
GR_Compat.RegisterAddonPrefix(SYNC_PREFIX)   -- Mainline delivers CHAT_MSG_ADDON only for registered prefixes
f:SetScript("OnEvent", function(self, event, ...)
  local ok, err = pcall(GR_OnEvent, event, ...)
  if not ok then Abort(err) end
end)

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
local function HasOutstandingWhispers()
  for _, w in pairs(whispered) do
    if GetTime() - (w.t or 0) < WHISPER_WAIT then return true end
  end
  return false
end

-- Deal the A/B variant for the head of the contact queue ONCE and remember it,
-- so the press (or the timer) then sends exactly that. Returns name, variant
-- (nil = control A). Invite-all ("blast") ignores the variants, so it deals
-- nothing. It ROLLS (PickVariant), so only contact code calls it: Drain when the
-- head is due, and ContactHead. Never the Next button, tooltips or /gr status,
-- which use the read-only GuildRecruiter_HeadMode.
function GuildRecruiter_DealHead()
  local name = contactQueue[1]
  if not name or GuildRecruiter_runKind == "blast" then return name, nil end
  local d = GuildRecruiter_dealt
  if not d or d.name ~= name then
    d = { name = name, v = GuildRecruiter_PickVariant() }
    GuildRecruiter_dealt = d
  end
  return name, d.v
end

-- READ-ONLY: the head of the contact queue and its contact mode, without
-- dealing: "blast" for Invite all, the dealt variant's mode, the live mode when
-- A/B is off (nothing to roll), or nil = A/B on and not dealt yet (Drain deals
-- it when it is due).
function GuildRecruiter_HeadMode()
  local name = contactQueue[1]
  if not name then return nil, nil end
  if GuildRecruiter_runKind == "blast" then return name, "blast" end
  local d = GuildRecruiter_dealt
  if d and d.name == name then return name, GuildRecruiter_CfgOf(d.v).mode end
  if not GuildRecruiter_ABActive() then return name, GuildRecruiter_CfgOf(nil).mode end
  return name, nil
end

-- key-press mode: may the run timer send a contact of this mode by itself?
-- (GR_Compat.TimerContactModes: the whisper modes.) Invite prompts wait for a press.
function GuildRecruiter_TimerMode(mode)
  if not mode or mode == "blast" then return false end
  return GR_Compat.TimerContactModes[mode] and true or false
end
function GuildRecruiter_TimerMay(v)
  if GuildRecruiter_runKind == "blast" then return false end
  return GuildRecruiter_TimerMode(GuildRecruiter_CfgOf(v).mode)
end

-- " -- N left, click again" after a contact made by a press, else ""
function GuildRecruiter_LeftNote()
  if not GR_Compat.inPress then return "" end
  local left = #contactQueue + #replyQueue
  if GuildRecruiter_runKind == "blast" or GuildRecruiter_runKind == "send" then
    return (left > 0) and (" -- "..left.." left, click again") or " -- that was the last one"
  end
  if #replyQueue > 0 then return " -- "..#replyQueue.." more ready to invite" end
  return (left > 0) and (" -- "..left.." queued") or ""
end

-- RESTRICTED (guild invite), TIMER-LOOP CLIENTS ONLY: the first player on
-- replyQueue (replied yes to a whisperinvite whisper). Caller: GuildRecruiter_Drain,
-- only when not GR_Compat.RequiresHardwareEvent. In key-press mode a yes-reply
-- never enters replyQueue: it goes to the Ready list (GuildRecruiter_ReadyAdd).
function GuildRecruiter_InviteReply()
  local name = tremove(replyQueue, 1)
  DoGuildInvite(name)
  if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
  local pe = GuildRecruiter_Settings.history[name]   -- keep the profile that contacted them
  GuildRecruiter_Settings.history[name] = { t = time(), p = (type(pe) == "table") and pe.p or GuildRecruiter_Settings.activeProfile }
  stats.invited = stats.invited + 1
  TallyBump("invited")
  Print("Invited (replied) "..name.." ("..stats.invited..")"..GuildRecruiter_LeftNote())
  inviteTimer = Pace(GuildRecruiter_Settings.inviteDelay)
end

-- RESTRICTED when the head's contact is an invite: contact the head of the
-- queue with the variant DealHead dealt it. Callers: GuildRecruiter_Drain (1.12
-- timer; key-press mode only for TimerMay whispers) and GuildRecruiter_NextPress
-- (key-press mode: an invite PROMPT only from the secure button's PreClick; the
-- name goes to the Ready list and is counted as invited only on Done/join).
function GuildRecruiter_ContactHead()
  local name, v = GuildRecruiter_DealHead()
  tremove(contactQueue, 1)
  GuildRecruiter_dealt = nil
  local prompted = false
  if GuildRecruiter_runKind == "blast" then    -- invite-all: straight guild invite, fast
    DoGuildInvite(name)
    stats.contacted = stats.contacted + 1
    if GR_Compat.RequiresHardwareEvent then
      prompted = true                          -- only the prompt: Done records it
      GuildRecruiter_ReadyAdd(name, "blast", nil, true)
      Print("Invite prompt for "..name.." (on the Ready list)"..GuildRecruiter_LeftNote())
    else
      if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
      GuildRecruiter_Settings.history[name] = { t = time(), p = GuildRecruiter_Settings.activeProfile }
      Broadcast("INV "..name)                  -- share with peers (guild-wide dedup), like RecordHandled
      stats.invited = stats.invited + 1
      TallyBump("invited")
      Print("Invited "..name.." ("..stats.invited..")"..GuildRecruiter_LeftNote())
    end
  else
    prompted = Contact(name, v)
    if prompted then Print("Invite prompt for "..name.." (on the Ready list)"..GuildRecruiter_LeftNote())
    else Print("Contacted "..name.." ("..stats.contacted..")"..GuildRecruiter_LeftNote()) end
  end
  -- collected -> contacted; a prompt keeps its candidate entry until Done
  if not prompted and GuildRecruiter_Settings.candidates then GuildRecruiter_Settings.candidates[name] = nil end
  inviteTimer = (GuildRecruiter_runKind == "blast") and INVITE_MIN or Pace(GuildRecruiter_Settings.inviteDelay)
end

-- GLOBAL on purpose: extracting the contacting/draining block here keeps
-- GR_OnUpdate's upvalue count low.
-- Key-press mode (GR_Compat.RequiresHardwareEvent): this timer NEVER invites.
-- It paces and sends the TimerMay whispers (whisper and whisper-then-invite),
-- applies the session cap and ends the run; invite prompts wait for
-- GuildRecruiter_NextPress, and yes-replies go to the Ready list from the
-- CHAT_MSG_WHISPER handler (no queue, no press).
function GuildRecruiter_Drain(e)
  if #contactQueue > 0 and CapReached() then
    -- session cap hit with names still queued: end the run instead of hanging
    -- "Running" forever. Checked BEFORE the pacing and the combat / instance /
    -- throttle hold, so a held send can't keep a capped run (and its Next
    -- button, which also stops at the cap) frozen.
    Print("Session cap ("..GuildRecruiter_Settings.sessionCap..") reached -- dropping "..#contactQueue.." queued name(s).")
    contactQueue = {}
    GuildRecruiter_dealt = nil
    scanning = false
    GuildRecruiter_rescanWait = 0
  elseif #replyQueue > 0 or #contactQueue > 0 then
    -- contacting / inviting (paced; replies take priority)
    inviteTimer = inviteTimer - e
    if inviteTimer <= 0 and not SendsBlocked() then
      local hw = GR_Compat.RequiresHardwareEvent
      if #replyQueue > 0 and not hw then
        GuildRecruiter_InviteReply()
      elseif #contactQueue == 0 then
        -- (key-press mode never fills replyQueue; nothing to do)
      elseif not hw then
        GuildRecruiter_ContactHead()
      else
        local _, v = GuildRecruiter_DealHead()   -- the head is due: deal it now (contact time)
        if GuildRecruiter_TimerMay(v) then GuildRecruiter_ContactHead() end   -- a whisper
        -- else: an invite prompt; it waits for Next
      end
    end
  elseif not scanning then
    -- ANY outstanding whisper (incl. an A/B variant's whisperinvite when the global
    -- mode differs) keeps the run alive to catch late replies -- else those replies
    -- would arrive with running=false and the invites would be dropped
    if HasOutstandingWhispers() then
      -- keep waiting
    else
      running = false
      local kind = GuildRecruiter_runKind
      GuildRecruiter_runKind = nil
      SuppressWho(false)
      GR_Compat.SetWhoToUI(false)   -- restore manual /who to chat (RestoreWho is defined later in the file)
      Broadcast("BYE")
      if kind == "blast" or kind == "send" then
        -- key-press mode: an invite step is only a prompt (counted on Done), so say "prompted"
        local verb = (kind == "blast") and (GR_Compat.RequiresHardwareEvent and "Prompted " or "Invited ") or "Contacted "
        Print("Done. "..verb..stats.contacted.." of "..(GuildRecruiter_runTotal or stats.contacted)..". "..CountTable(GuildRecruiter_Settings.candidates).." candidate(s) remain.")
      elseif GuildRecruiter_Settings.collectOnly and stats.contacted == 0 then
        Print("Done collecting. List now has "..CountTable(GuildRecruiter_Settings.candidates).." candidate(s). Send them from the Lists tab.")
      else
        Print("Done. Contacted "..stats.contacted.." ("..stats.invited.." invited, "..stats.whispered.." whispered), skipped "..stats.guilded.." guilded, "..stats.queries.." queries.")
      end
    end
  end
end

-- e = seconds since the last frame (OnUpdate's elapsed argument; 1.12 put it in arg1)
local function GR_OnUpdate(e)
  if not running or paused then return end

  if hideSoon then
    hideSoon = false
    GR_Compat.HideWhoWindow()
  end

  -- presence ping + peer pruning
  if GuildRecruiter_Settings.guildSync and IsInGuild() then
    presenceTimer = presenceTimer - e
    if presenceTimer <= 0 then
      Broadcast("HI")
      presenceTimer = PRESENCE_INTERVAL
    end
  end
  local pruned = false
  for n, t in pairs(recruiters) do
    if GetTime() - t > PRESENCE_TTL then recruiters[n] = nil; pruned = true end
  end
  if pruned then RecomputeBand() end

  -- forget whisper targets who never replied
  for n, w in pairs(whispered) do
    if GetTime() - (w.t or 0) > WHISPER_WAIT then whispered[n] = nil end
  end

  -- scanning
  if scanning then
    if (GuildRecruiter_rescanWait or 0) > 0 then
      -- auto-rescan rest between cycles; when it elapses, re-arm the sweep.
      -- (globals => no upvalue cost to GR_OnUpdate.)
      GuildRecruiter_rescanWait = GuildRecruiter_rescanWait - e
      if GuildRecruiter_rescanWait <= 0 then GuildRecruiter_RestartScanCycle() end
    elseif awaiting then
      whoTimeout = whoTimeout - e
      if whoTimeout <= 0 then
        awaiting = false
        if current and current.sweep and whoRetries < WHO_RETRIES then
          -- slow / no reply: retry the SAME band. lo/width are left untouched so
          -- NextQuery rebuilds and re-sends it -- important on throttled servers
          -- where a dense band's reply can lag past the timeout.
          whoRetries = whoRetries + 1
          if GuildRecruiter_Settings.debug then Print("who "..current.lo..(current.hi ~= current.lo and ("-"..current.hi) or "").." no reply in "..WHO_TIMEOUT.."s -- retry "..whoRetries.."/"..WHO_RETRIES) end
        else
          whoRetries = 0
          if current and current.sweep then lo = current.hi + 1 end   -- give up; skip past it
          if GuildRecruiter_Settings.debug then Print("who timed out -- skipping ahead") end
        end
        whoTimer = GuildRecruiter_Settings.whoDelay
      end
    elseif GetTime() >= backoffUntil then
      whoTimer = whoTimer - e
      if whoTimer <= 0 then
        if not GR_Compat.RequiresHardwareEvent then
          SendNextWho()                           -- 1.12: the timer sends the /who
          whoTimer = Pace(GuildRecruiter_Settings.whoDelay)
        elseif not NextQuery(true) then
          -- key-press mode, band fully swept: no /who is needed, so end the
          -- sweep (or start the auto-rescan rest) without waiting for a press
          FinishSweep()
          whoTimer = Pace(GuildRecruiter_Settings.whoDelay)
        end
        -- key-press mode: otherwise the /who is due and waits for Next
      end
    end
  end

  -- contacting / draining is its own global function so GR_OnUpdate stays well
  -- under Lua 5.0's 32-upvalue limit (this block alone references ~15 locals).
  GuildRecruiter_Drain(e)
end

f:SetScript("OnUpdate", function(self, elapsed)
  local ok, err = pcall(GR_OnUpdate, elapsed)
  if not ok then Abort(err) end
end)

-- Quiet the /who chat spam during a run: drop the /who summary/result system
-- lines while we're scanning. GR_Compat.FilterSystemChat uses the chat message
-- filter API where it exists (1.12 had none, so it wrapped ChatFrame_OnEvent).
-- Our own CHAT_MSG_SYSTEM handler (on frame f) is separate and still fires, so
-- throttle-detection keeps working.
GR_Compat.FilterSystemChat(function(msg)
  return running and GuildRecruiter_Settings.quietWho and GR_Compat.IsWhoNoise(msg)
end)

-- ---------------------------------------------------------------------------
-- Run control
-- ---------------------------------------------------------------------------
local function ForceWhoToEvent()
  GR_Compat.SetWhoToUI(true)
end
-- undo ForceWhoToEvent when a run ends -- otherwise the player's own /who stays
-- routed to the UI (results stop printing to chat) until a /reload
local function RestoreWho()
  GR_Compat.SetWhoToUI(false)
end
-- an invite sent without permission fails SILENTLY while we still record + broadcast
-- the contact, poisoning the guild-wide re-invite cooldown -- so block invite runs early
local function CheckInvitePerms(mode)
  if mode == "whisper" then return true end          -- whisper-only runs send no invites
  if not GR_Compat.CanGuildInvite() then
    Print("|cffff4040You don't have guild-invite permission|r -- invites would fail silently. Ask an officer, or use whisper mode.")
    return false
  end
  return true
end

local function FactionLists()
  classes = {}
  if UnitFactionGroup("player") == "Horde" then
    classes = { "Warrior", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock", "Druid" }
  else
    classes = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Mage", "Warlock", "Druid" }
  end
end

local function Start()
  if not IsInGuild() then Print("You're not in a guild.") return end
  if running then Print("Already running. /gr stop to cancel"..(paused and ", /gr resume to continue." or ", /gr pause to pause.")) return end
  if not CheckInvitePerms(GuildRecruiter_Settings.mode) then return end
  ForceWhoToEvent()
  SuppressWho(true)
  FactionLists()
  running, scanning, awaiting, paused = true, true, false, false
  GuildRecruiter_rescanWait = 0
  GuildRecruiter_runKind = "scan"; GuildRecruiter_runTotal = 0
  current = nil
  pending, contactQueue, replyQueue, seen, whispered = {}, {}, {}, {}, {}
  whoTimer, inviteTimer, whoTimeout, presenceTimer = 0, 0, 0, 0
  stats = { contacted=0, invited=0, whispered=0, guilded=0, scanned=0, queries=0, dropped=0, cooldown=0, collected=0 }
  RecomputeBand()
  lo, width, observedCap, whoRetries = myLo, START_WIDTH, 0, 0
  if GuildRecruiter_Settings.guildSync and IsInGuild() then Broadcast("HI") end
  GuildRecruiter_dealt = nil
  -- key-press mode: Start only ARMS the run; each /who and invite waits for Next
  if not GuildRecruiter_Arm("Armed ("..(MODE_LABEL[GuildRecruiter_Settings.mode] or "?")..") on levels "..myLo.."-"..myHi..".") then
    Print("Started ("..(MODE_LABEL[GuildRecruiter_Settings.mode] or "?")..") on levels "..myLo.."-"..myHi..". /gr stop to cancel.")
  end
end

local function Stop()
  if not running then
    if not GuildRecruiter_CancelOne() then Print("Not running.") end   -- or drop a single invite set on Next
    return
  end
  local wasSend = (GuildRecruiter_runKind ~= "scan")
  running, scanning, awaiting, paused = false, false, false, false
  GuildRecruiter_rescanWait = 0
  GuildRecruiter_runKind = nil
  GuildRecruiter_dealt = nil    -- no stale A/B deal carried into the next run
  SuppressWho(false)
  RestoreWho()
  Broadcast("BYE")
  if wasSend then
    Print("Stopped. "..(GR_Compat.RequiresHardwareEvent and "Prompted / whispered " or "Invited ")..stats.contacted.." this run; "..CountTable(GuildRecruiter_Settings.candidates).." candidate(s) remain on the list.")
  else
    Print("Stopped. Contacted "..stats.contacted.." this run; "..#contactQueue.." still queued.")
  end
end

-- Drain the persistent candidate list (built by Collect-only scans) through the
-- contact pipeline -- no scanning. blast=true => guild-invite EVERYONE as fast as
-- the server safely allows (ignores Mode); blast=false => paced, respects Mode.
-- GLOBAL so the slash + Lists buttons reach it.
function GuildRecruiter_SendToCandidates(blast)
  if not IsInGuild() then Print("You're not in a guild.") return end
  if running then Print("Already running -- /gr stop first"..(paused and " (or resume)." or ".")) return end
  if not CheckInvitePerms(blast and "invite" or GuildRecruiter_Settings.mode) then return end
  Defaults()
  local s = GuildRecruiter_Settings
  local names = {}
  for n in pairs(s.candidates) do
    if not GuildRecruiter_ReadyHas(n) then tinsert(names, n) end   -- already waiting on the Ready list: skip
  end
  if #names == 0 then Print("No collected candidates"..(next(s.candidates) and " that aren't already on the Ready list (/gr ready)" or "")..". Turn on Collect (Settings) and scan first.") return end
  running, scanning, awaiting, paused = true, false, false, false
  GuildRecruiter_rescanWait = 0                          -- auto-rescan is scan-runs-only
  GuildRecruiter_runKind = blast and "blast" or "send"   -- fast invite-all vs paced send
  GuildRecruiter_runTotal = #names            -- for N-of-M progress
  current = nil
  pending, contactQueue, replyQueue, seen, whispered = {}, {}, {}, {}, {}
  whoTimer, inviteTimer, whoTimeout, presenceTimer = 0, 0, 0, 0
  stats = { contacted=0, invited=0, whispered=0, guilded=0, scanned=0, queries=0, dropped=0, cooldown=0, collected=0 }
  for i = 1, #names do tinsert(contactQueue, names[i]) end
  if s.guildSync and IsInGuild() then Broadcast("HI") end
  GuildRecruiter_dealt = nil
  -- key-press mode: arm only; every click on Next sends ONE invite
  if blast then
    if not GuildRecruiter_Arm("Armed invite-all for "..#names.." candidate(s): one invite per click.") then
      Print("Inviting all "..#names.." candidate(s) as fast as the server allows (auto-backs-off if throttled). /gr stop to cancel.")
    end
  else
    if not GuildRecruiter_Arm("Armed send to "..#names.." collected candidate(s) ("..(MODE_LABEL[s.mode] or "?").."); invites go one per click.") then
      Print("Sending to "..#names.." collected candidate(s) ("..(MODE_LABEL[s.mode] or "?").."). /gr stop to cancel.")
    end
  end
end

-- GLOBALS so the main-window header (shown on every tab) can show run state and
-- a Stop button without adding upvalues to BuildUI.
function GuildRecruiter_StopRun() Stop() end
function GuildRecruiter_HeaderTick(m, elapsed)
  m.htick = (m.htick or 0) - (elapsed or 0)
  if m.htick > 0 then return end
  m.htick = 0.3
  if running then
    local total = GuildRecruiter_runTotal or 0
    local prog = (total > 0) and ("  "..stats.contacted.."/"..total) or ("  "..stats.contacted.." sent")
    if paused then m.runStatus:SetText("|cffffcc00Paused|r"..prog)
    else m.runStatus:SetText("|cff40ff40Running|r"..prog) end
    m.pauseBtn:SetText(paused and "Resume" or "Pause")
    m.stopBtn:Show(); m.pauseBtn:Show()
  else
    m.runStatus:SetText(""); m.stopBtn:Hide(); m.pauseBtn:Hide()
  end
end

-- quiet = pause without the chat lines (the block report prints its own line)
local function Pause(quiet)
  if not running then if not quiet then Print("Not running.") end return end
  if paused then if not quiet then Print("Already paused. /gr resume to continue.") end return end
  paused = true
  if GuildRecruiter_runKind == "scan" then
    SuppressWho(false)  -- let manual /who work normally while paused
    Broadcast("BYE")    -- yield my band to others while paused
  end
  if not quiet then Print("Paused. "..#contactQueue.." left. /gr resume to continue.") end
end

local function Resume()
  if not running then Print("Not running -- use /gr start.") return end
  if not paused then Print("Not paused.") return end
  paused = false
  if GuildRecruiter_runKind == "scan" then
    -- only scan runs have a level band / who suppression to restore
    SuppressWho(true)
    RecomputeBand()
    if GuildRecruiter_Settings.guildSync and IsInGuild() then Broadcast("HI") end
  end
  Print("Resumed.")
end

-- GLOBAL so header / Lists play-pause buttons add no upvalues to their builders
function GuildRecruiter_TogglePause() if paused then Resume() else Pause() end end

-- ---------------------------------------------------------------------------
-- Key-press mode (GR_Compat.RequiresHardwareEvent): the Next action
-- ---------------------------------------------------------------------------
-- The client marks C_FriendList.SendWho #hwevent (a key press or click must
-- start it) and forbids C_GuildInfo.Invite to addon code in every form tried
-- (a direct call, a secure /ginvite macro, text typed into the chat box). So
-- the addon never invites: an "invite" step only PROMPTS (copy box + a chat
-- player link) and parks the name on the Ready list, and the player invites in
-- Blizzard's Guild > Invite Member box. Whispers go out from the timer.
-- One press does at most one step:
--   1. the head of the contact queue when its contact is an invite prompt
--      (invite mode, Invite all, a single invite), if its gap has run out
--   2. otherwise the next /who of the sweep -- but only once the queue holds no
--      whispers: those go out by themselves (GuildRecruiter_TimerMay), and the
--      next /who waits until they are all sent
--   3. otherwise the step that is ready soonest (a press too early says "wait Ns")
-- Whisper replies need no press at all: a yes goes straight to the Ready list.
-- With no run armed, a single invite set from the Lists tab or /gr invite
-- (GuildRecruiter_oneName) is the only step.
-- The pacing settings are minimum gaps: a press that comes too early only says
-- how long to wait.
--
-- Entry points:
--   * the SECURE button GuildRecruiterNextButton (SecureActionButtonTemplate):
--     a mouse click on it, the Bindings.xml CLICK binding on it, or a macro
--     with /click GuildRecruiterNextButton. Its PreClick
--     (GuildRecruiter_SecurePreClick) runs the step. It no longer sets any
--     secure action (the /ginvite macro was refused in game); it is kept as the
--     one press target, and its secure-click gate still guards invite prompts.
--   * typed /gr next (GuildRecruiter_Next): does /who and whisper steps and only
--     explains an invite-prompt step.
-- Either way the step runs in the same call stack (GR_Compat.Press -> pcall,
-- which is synchronous).
--
-- Click edge: the secure action fires on the click's UP edge, fixed by the
-- button's own attribute useOnKeyDown = false (SecureActionButton_OnClick in
-- the client's SecureTemplates.lua reads it before the ActionButtonUseKeyDown
-- CVar). The button is registered for LeftButtonUp only, so PreClick and
-- PostClick run on that same event (both also ignore a down event). Up, because
-- "/click GuildRecruiterNextButton" sends an up click by default and a mouse
-- click ends on the up edge; the key binding acts when the key is released.

-- the client reported a blocked call naming this addon (GR_Compat.BlockedLine)
function GuildRecruiter_PauseBlocked(line)
  -- the block came from our own /who (the event is synchronous, so it lands
  -- inside the press that sent it: lastCall is the /who, 0s ago)
  local whoBlocked = GR_Compat.lastCall and string.find(GR_Compat.lastCall, "SendWho", 1, true)
                     and (GetTime() - (GR_Compat.lastCallAt or 0)) < 1
  if running and not paused then
    if whoBlocked and awaiting then
      -- a refused /who never reached the server, so no reply is coming: stop
      -- waiting (no timeout, no retry burned) and give the query back. A sweep
      -- slice is rebuilt from `lo` (unchanged); a class sub-query was taken off
      -- `pending` by NextQuery, so it goes back to the front.
      awaiting = false
      whoTimeout = 0
      if stats.queries > 0 then stats.queries = stats.queries - 1 end
      if current and not current.sweep then tinsert(pending, 1, current) end
    end
    Pause(true)
    line = line.." -- run paused (/gr resume to try again, /gr stop to end)."
  end
  Print(line)
end

-- What the next press would do, without doing it (the press, the buttons and
-- /gr status all ask this, so they always agree). READ-ONLY: it never deals the
-- A/B variant (GuildRecruiter_HeadMode peeks; DealHead runs only at contact time).
--   action  "contact" | "who" | "one", or nil when a press can do nothing now
--   wait    seconds until that press may fire (0 = now)
--   info    what it would do / why not, for chat
--   short   the same for the button
--   invite  true when the step is an invite prompt (secure button only, not in combat)
function GuildRecruiter_NextStep()
  if not running then
    local one = GuildRecruiter_oneName   -- a single invite set from the Lists tab / /gr invite
    if one then return "one", 0, "invite prompt for "..one, "Invite "..one, true end
    return nil, 0, "not armed -- /gr start first", "Not armed"
  end
  if paused then return nil, 0, "paused -- /gr resume first", "Paused" end
  local blocked = SendsBlocked()
  local held = nil
  local cwait = (inviteTimer > 0) and inviteTimer or 0
  local c = nil   -- a press contact step that is not ready yet: { wait, info, short, invite }
  if #contactQueue > 0 then
    -- the cap ends the run (Drain drops the queue even while sends are held)
    if CapReached() then return nil, 0, "session cap reached -- the run is ending", "Cap reached" end
    local name, mode = GuildRecruiter_HeadMode()
    if mode and not GuildRecruiter_TimerMode(mode) then
      -- an invite prompt (or a whisper the timer may not send): it needs a press.
      -- Held prompts don't hold the /who: as in 1.12, only the throttle backoff
      -- holds the sweep.
      if blocked then
        held = "invite prompts held: "..blocked
        if not scanning then return nil, 0, held, "Held: "..blocked end
      else
        local verb = (mode == "whisper" or mode == "whisperinvite") and "Whisper" or "Invite"
        if cwait <= 0 then return "contact", 0, string.lower(verb).." "..name, verb.." "..name, verb == "Invite" end
        c = { cwait, string.lower(verb).." "..name, verb.." "..name, verb == "Invite" }
      end
    else
      -- whispers (or an A/B head that Drain deals when it is due) go out by
      -- themselves at the invite delay; the next /who waits until they are sent
      if blocked then return nil, 0, #contactQueue.." whisper(s) held: "..blocked, "Held: "..blocked end
      return nil, 0, #contactQueue.." whisper(s) going out by themselves; the next /who after that", "Whispering ("..#contactQueue..")"
    end
  end
  if scanning then
    local act, wait, info, short = "who", 0, "next /who", "/who"
    local rest = GuildRecruiter_rescanWait or 0
    if rest > 0 then
      wait, info, short = rest, "auto-rescan rest", "Rescan"
    elseif awaiting then
      -- never "ready" while a reply is awaited (the timeout clears awaiting)
      wait, info, short = (whoTimeout > 0) and whoTimeout or 1, "waiting for the /who reply", "Waiting for /who"
    elseif not NextQuery(true) then
      act, info, short = nil, held or "sweep finished", held and ("Held: "..blocked) or "Sweep done"
    else
      wait = backoffUntil - GetTime()
      if wait < 0 then wait = 0 end
      if whoTimer > 0 then wait = wait + whoTimer end
    end
    -- a waiting invite prompt never starves a due /who (and the reverse): the
    -- step that is ready first wins, the prompt on a tie
    if c and (not act or c[1] <= wait) then return "contact", c[1], c[2], c[3], c[4] end
    return act, wait, info, short
  end
  if c then return "contact", c[1], c[2], c[3], c[4] end
  return nil, 0, "waiting for whisper replies", "Waiting"
end

-- the Next button's text, e.g. "/who ready in 2s [3 ready]" ([n ready] = names
-- on the Ready list, waiting for your invite)
function GuildRecruiter_NextLabel()
  local act, wait, _, short, inv = GuildRecruiter_NextStep()
  local secs = math.ceil(wait or 0)
  local text = short
  if act == "who" then
    if awaiting then text = "Waiting for /who"
    elseif (GuildRecruiter_rescanWait or 0) > 0 then text = "Rescan in "..secs.."s"
    elseif secs > 0 then text = "/who ready in "..secs.."s"
    else text = "Next: send /who" end
  elseif act and secs > 0 then
    -- the whole step text ("Invite First Surname"): a Forever name has a space,
    -- and the first word alone was only the verb
    text = (short or "Next").." ready in "..secs.."s"
  end
  if inv and GR_Compat.InCombat() then text = text.." (after combat)" end
  local nr = GuildRecruiter_ReadyCount()
  if nr > 0 then text = text.." ["..nr.." ready]" end
  return text
end

-- runs INSIDE the hardware event (via GR_Compat.Press): at most one restricted
-- call (the /who). GR_Compat.secureClick is the secure button while its PreClick
-- runs, and nil for a typed /gr next, which therefore can't do an invite step.
function GuildRecruiter_NextPress()
  local act, wait, info, _, inv = GuildRecruiter_NextStep()
  if not act then Print("Next: "..info..".") return end
  if wait > 0 then Print("Next: wait "..math.ceil(wait).."s ("..info..").") return end
  if inv then
    if not GR_Compat.secureClick then
      Print("Next: "..info.." -- a typed command doesn't do invite steps. Click the Next button (under the minimap button), press its key, or use a macro with /click GuildRecruiterNextButton.")
      return
    end
    if GR_Compat.InCombat() then Print("Next: no invite prompts in combat -- press again when combat ends.") return end
  end
  if act == "one" then
    local name = GuildRecruiter_oneName
    GuildRecruiter_oneName = nil
    DoGuildInvite(name)                     -- the prompt only: copy box + chat link
    GuildRecruiter_ReadyAdd(name, "one", nil, true)   -- counted on Done (GuildRecruiter_InvitedOne)
  elseif act == "contact" then
    GuildRecruiter_ContactHead()            -- an invite prompt (to the Ready list), or a whisper
  else
    SendNextWho()                           -- C_FriendList.SendWho
    whoTimer = Pace(GuildRecruiter_Settings.whoDelay)
  end
end

-- typed /gr next. A typed command can't click the secure button, so this does
-- the /who and whisper steps and only explains an invite step (NextPress).
function GuildRecruiter_Next()
  if not GR_Compat.RequiresHardwareEvent then
    Print("Next isn't needed on this client: the run sends /who and invites by itself (/gr start).")
    return
  end
  local ok, err = GR_Compat.Press(GuildRecruiter_NextPress)
  if not ok then Abort(err) end
end

-- PreClick of the secure Next button: insecure addon code that runs in the
-- click's hardware event BEFORE the template's secure OnClick. An invite step
-- sets the /ginvite macro (out of combat only); a /who or whisper step runs
-- here. The button's action is empty when this starts (PostClick emptied it).
function GuildRecruiter_SecurePreClick(btn, button, down)
  if down then return end                   -- the secure action fires on the up edge
  GR_Compat.SecureClear(btn)                -- start empty (does nothing in combat: already empty)
  GR_Compat.secureClick = btn
  local ok, err = GR_Compat.Press(GuildRecruiter_NextPress)
  GR_Compat.secureClick = nil
  if not ok then
    GR_Compat.SecureClear(btn)              -- never run a half-made step
    Abort(err)
  end
end

-- PostClick: the secure action has run (or there was none). Empty it, so no
-- later click or key can fire a stale /ginvite.
function GuildRecruiter_SecurePostClick(btn, button, down)
  if down then return end
  GR_Compat.SecureClear(btn)
end

-- how to press Next, for chat
function GuildRecruiter_PressHint()
  local k = GR_Compat.BindingKey(GR_Compat.NEXT_BINDING)
  if k then return "press "..k.." or click Next (under the minimap button)" end
  return "click Next (under the minimap button), or bind a key under Key Bindings > Guild Rawcruiter"
end

-- key-press mode: announce the armed run and show the Next button. Returns
-- false on a timer-loop client, so the caller prints its 1.12 line instead.
function GuildRecruiter_Arm(text)
  if not GR_Compat.RequiresHardwareEvent then return false end
  GuildRecruiter_oneName = nil              -- a single invite set earlier gives way to the run
  local m = GuildRecruiter_Settings.mode
  if GuildRecruiter_runKind ~= "blast" and (m == "whisper" or m == "whisperinvite") then
    Print(text.." Each /who waits for you: "..GuildRecruiter_PressHint()
      ..". Whispers then go out by themselves"
      ..(m == "whisperinvite" and "; a yes-reply lands on the Ready list (/gr ready), where you invite them yourself" or "")
      ..". /gr stop to cancel.")
  else
    Print(text.." Each /who and each invite prompt waits for you: "..GuildRecruiter_PressHint()
      ..". A prompt puts the name on the Ready list (/gr ready); you send the invite in Guild > Invite Member and press Done. /gr stop to cancel.")
  end
  GuildRecruiter_ShowNext()
  return true
end

function GuildRecruiter_NextTip(btn)
  local _, _, info = GuildRecruiter_NextStep()
  GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMLEFT")
  GameTooltip:AddLine("Guild Rawcruiter: Next")
  GameTooltip:AddLine("Next: "..info, 1, 1, 1, 1)
  local nr = GuildRecruiter_ReadyCount()
  if nr > 0 then GameTooltip:AddLine(nr.." on the Ready list -- waiting for your invite (/gr ready)", 0.3, 1, 0.3) end
  GameTooltip:AddLine("One /who or invite prompt per click; whispers go out by themselves. The addon never sends a guild invite: you do, in Guild > Invite Member.", 0.7, 0.7, 0.7, 1)
  local k = GR_Compat.BindingKey(GR_Compat.NEXT_BINDING)
  GameTooltip:AddLine(k and ("Key: "..k) or "No key bound: Key Bindings > Guild Rawcruiter", 0.6, 0.8, 1, 1)
  GameTooltip:AddLine("In a macro: /click GuildRecruiterNextButton", 0.6, 0.8, 1, 1)
  GameTooltip:Show()
end

-- should the Next button be on screen? (a run is armed, or a single invite is set)
function GuildRecruiter_NextWanted()
  return (running or GuildRecruiter_oneName ~= nil) and true or false
end

-- THE secure button: SecureActionButtonTemplate, with the UIPanelButtonTemplate
-- look. Built once, out of combat (a secure frame's attributes, click
-- registration, size and position can't be set in lockdown); until then the
-- PLAYER_REGEN_ENABLED handler retries. Parented and anchored to UIParent only:
-- anchoring it to the minimap button (or parenting it to the main window) would
-- make that frame protected too, so moving or hiding it in combat would be
-- blocked. It has NO OnClick script: that would replace the template's secure
-- SecureActionButton_OnClick.
function GuildRecruiter_MakeNext()
  local b = GuildRecruiterNextButton
  if b or not GR_Compat.RequiresHardwareEvent or GR_Compat.InCombat() then return b end
  b = CreateFrame("Button", "GuildRecruiterNextButton", UIParent, "SecureActionButtonTemplate,UIPanelButtonTemplate")
  b:SetWidth(170); b:SetHeight(22)
  b:SetFrameStrata("DIALOG"); b:SetFrameLevel(100)   -- stays clickable over the main window
  b:SetClampedToScreen(true)
  b:SetAttribute("useOnKeyDown", false)   -- the secure action fires on the UP edge, whatever the CVar
  b:RegisterForClicks("LeftButtonUp")     -- so PreClick / PostClick run on that same edge
  b:SetScript("PreClick", function(self, button, down) GuildRecruiter_SecurePreClick(self, button, down) end)
  b:SetScript("PostClick", function(self, button, down) GuildRecruiter_SecurePostClick(self, button, down) end)
  b:SetScript("OnEnter", function(self) GuildRecruiter_NextTip(self) end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b.tick = 0
  b:SetScript("OnUpdate", function(self, elapsed)
    self.tick = self.tick - (elapsed or 0)
    if self.tick > 0 then return end
    self.tick = 0.2
    if not GuildRecruiter_NextWanted() then
      if not GR_Compat.InCombat() then self:Hide() end   -- a secure frame can't be hidden in combat
      return
    end
    local ok, text = pcall(GuildRecruiter_NextLabel)   -- label only; never sends anything
    self:SetText(ok and text or "Next")
  end)
  b:SetText("Next")
  b:Hide()
  return b
end

-- put the button under the minimap button, anchored to UIParent (see
-- MakeNext): the minimap button's screen spot in UIParent units. Out of combat only.
function GuildRecruiter_PlaceNext(b)
  if not b or GR_Compat.InCombat() then return end
  local mb = GuildRecruiterMinimapButton
  local x, bottom = nil, nil
  if mb then x = mb:GetCenter(); bottom = mb:GetBottom() end
  b:ClearAllPoints()
  if x and bottom then
    local k = mb:GetEffectiveScale() / UIParent:GetEffectiveScale()
    b:SetPoint("TOP", UIParent, "BOTTOMLEFT", x * k, bottom * k - 2)
  else
    b:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
end

-- build the button if needed and show or hide it to match NextWanted. Out of
-- combat only; the PLAYER_REGEN_ENABLED handler calls it again after combat.
function GuildRecruiter_SyncNext()
  if not GR_Compat.RequiresHardwareEvent or GR_Compat.InCombat() then return end
  local b = GuildRecruiter_MakeNext()
  if not b then return end
  if GuildRecruiter_NextWanted() then
    GuildRecruiter_PlaceNext(b)
    local ok, text = pcall(GuildRecruiter_NextLabel)
    b:SetText(ok and text or "Next")
    b:Show()
  else
    b:Hide()
  end
end

-- show the Next button now (a run armed, a single invite set). A secure frame
-- can't be shown in combat: then say so; SyncNext shows it when combat ends.
function GuildRecruiter_ShowNext()
  if not GR_Compat.RequiresHardwareEvent then return end
  local b = GuildRecruiterNextButton
  if GR_Compat.InCombat() then
    if b and b:IsShown() then b:SetText(GuildRecruiter_NextLabel())
    else Print("In combat: the Next button appears when combat ends.") end
    return
  end
  GuildRecruiter_SyncNext()
end

-- drop a single invite set on the Next button (/gr stop with no run armed)
function GuildRecruiter_CancelOne()
  local one = GuildRecruiter_oneName
  if not one then return false end
  GuildRecruiter_oneName = nil
  Print("Dropped the invite for "..one.." from the Next button.")
  GuildRecruiter_SyncNext()
  return true
end

-- ---------------------------------------------------------------------------
-- Ready list (key-press mode): names waiting for the PLAYER's own guild invite
-- ---------------------------------------------------------------------------
-- The addon never invites (C_GuildInfo.Invite is forbidden to addon code on
-- Forever). Whisper replies that pass the reply rule land here by themselves,
-- from the CHAT_MSG_WHISPER handler (no press), with a sound; every invite
-- prompt a press shows (invite mode, Invite all, a single invite) lands here
-- too. The player invites in Blizzard's Guild > Invite Member box and presses
-- Done. The invite is COUNTED (stats.invited, the tally, history / re-invite
-- cooldown, A/B attribution) only in GuildRecruiter_ReadyDone: Done, the
-- guild's join or decline message naming the player, or a removal from the
-- Lists tab's Ready view. An entry that waits longer than readyTTL minutes
-- expires and nothing is counted.
-- Saved as GuildRecruiter_Settings.ready = { [name] = { t = time(), kind, v } }:
--   kind  "reply" (said yes to a whisper; the whisper itself is already counted),
--         "invite" (invite mode), "blast" (Invite all), "one" (a single invite)
--   v     the A/B variant / profile name to credit (nil = the active profile)
-- Everything below is global or a GR_Compat field: no new main-chunk locals.
GR_Compat.READY_ROWS = 8

function GuildRecruiter_ReadyHas(name)
  local r = GuildRecruiter_Settings.ready
  return (r and GR_Compat.FindKey(r, name)) and true or false
end

function GuildRecruiter_ReadyCount()
  return CountTable(GuildRecruiter_Settings.ready or {})
end

-- the names, newest first
function GuildRecruiter_ReadyNames()
  local r = GuildRecruiter_Settings.ready or {}
  local names = {}
  for n in pairs(r) do tinsert(names, n) end
  table.sort(names, function(a, b)
    local ea, eb = r[a], r[b]
    local ta = (type(ea) == "table" and ea.t) or 0
    local tb = (type(eb) == "table" and eb.t) or 0
    if ta ~= tb then return ta > tb end
    return a < b
  end)
  return names
end

-- "45s", "12m", "2h" since t (a time() value)
function GuildRecruiter_ReadyAge(t)
  local s = time() - (t or time())
  if s < 0 then s = 0 end
  if s < 60 then return s.."s" end
  if s < 3600 then return math.floor(s / 60).."m" end
  return math.floor(s / 3600).."h"
end

-- drop entries older than readyTTL minutes (and any malformed one). Nothing is
-- counted for them: the player never pressed Done and no join was seen.
function GuildRecruiter_ReadyPrune()
  local s = GuildRecruiter_Settings
  local r = s.ready
  if not r then return 0 end
  local ttl = (s.readyTTL or 30) * 60
  local now, gone = time(), 0
  for n, e in pairs(r) do
    if type(e) ~= "table" or now - (e.t or 0) > ttl then r[n] = nil; gone = gone + 1 end
  end
  if gone > 0 then Print(gone.." name(s) left the Ready list after "..(s.readyTTL or 30).." min without an invite (nothing recorded).") end
  return gone
end

-- add a name (kind, v: see above). quiet = no sound (a press just showed the
-- prompt). A name already waiting keeps its first time and kind.
function GuildRecruiter_ReadyAdd(name, kind, v, quiet)
  local s = GuildRecruiter_Settings
  if type(name) ~= "string" or name == "" then return end
  if not s.ready then s.ready = {} end
  GuildRecruiter_ReadyPrune()
  if GR_Compat.FindKey(s.ready, name) then return end
  s.ready[name] = { t = time(), kind = kind, v = v }
  if kind == "reply" then
    -- the player link in this chat line is the shift-click target for an open
    -- Guild > Invite Member box (handled by Blizzard's own chat link code)
    Print(GR_Compat.PlayerLink(name).." replied -- ready to invite ("..GuildRecruiter_ReadyCount().." waiting). Open Guild > Invite Member and SHIFT-click the name, or use Copy in the Ready panel; then press Done.")
    if s.readyAlert and not quiet then GR_Compat.Alert() end
  end
  GuildRecruiter_ReadyShow(true, name)
  GuildRecruiter_ListRefresh()
end

-- the ONLY place key-press mode counts a guild invite. how: "done" (Done),
-- "joined" / "declined" (the guild's system message names them, so the invite
-- reached them), "removed" (Lists tab). Returns true if the name was listed.
function GuildRecruiter_ReadyDone(name, how)
  local s = GuildRecruiter_Settings
  local key = s.ready and GR_Compat.FindKey(s.ready, name)
  local e = key and s.ready[key]
  if not e then return false end
  s.ready[key] = nil
  if not s.history then s.history = {} end
  if e.kind == "one" then
    GuildRecruiter_InvitedOne(key)               -- history, candidate list, tally, chat line
  else
    stats.invited = stats.invited + 1
    TallyBump("invited")
    if e.kind == "invite" then
      RecordHandled(key, e.v)                    -- history (cooldown) + guild-wide dedup
      GuildRecruiter_VarBump(e.v, "contacted")   -- A/B: the prompt was not a contact, the invite is
    elseif e.kind == "blast" then
      s.history[key] = { t = time(), p = s.activeProfile }
      Broadcast("INV "..key)
    else
      -- "reply": the whisper already set the cooldown, broadcast and A/B
      -- "contacted"; refresh the time and keep the variant that whispered them
      local pe = s.history[key]
      s.history[key] = { t = time(), p = e.v or ((type(pe) == "table") and pe.p) or s.activeProfile }
    end
    if s.candidates then s.candidates[key] = nil end
    Print("Invite recorded: "..key..((how and how ~= "done") and (" ("..how..")") or "").." -- "..GuildRecruiter_ReadyCount().." still waiting.")
  end
  GuildRecruiter_ReadyRefresh()
  GuildRecruiter_ListRefresh()
  return true
end

-- [Copy]: the existing copy box, holding just the name
function GuildRecruiter_ReadyCopy(name)
  if not name then return end
  if IsShiftKeyDown and IsShiftKeyDown() then
    GR_Compat.ShowCopyBox(name)      -- Shift-click Copy: the box, for selecting by hand
  else
    GR_Compat.CopyName(name)         -- plain click: straight to the clipboard
  end
end

-- [Copy next]: the name that has waited longest
function GuildRecruiter_ReadyCopyNext()
  local names = GuildRecruiter_ReadyNames()
  local oldest = names[#names]
  if oldest then GuildRecruiter_ReadyCopy(oldest) else Print("Nobody is waiting for an invite.") end
end

-- a click on a name in the panel (any button, any modifier): print the name's
-- player link in the chat frame. The player shift-clicks it THERE, and
-- Blizzard's own chat link code fills the open Guild > Invite Member box
-- (Blizzard_UIPanels_Game/Mainline/ItemRefHandlers.lua:24-28).
-- RULE: addon code never calls SetItemRef and never touches the popup. Tested
-- on a real Forever client: SetItemRef called from addon code did fill the box,
-- but the player's Accept then raised ADDON_ACTION_FORBIDDEN (function
-- Invite()): the addon-run fill taints the popup and breaks the invite.
function GuildRecruiter_ReadyClick(name)
  if type(name) ~= "string" then return end
  GR_Compat.PrintLink(name)
end

-- build the panel once: addon-owned, plain (non-secure), parented to UIParent,
-- not part of the main window; draggable, position saved in readyPos
function GuildRecruiter_ReadyPanel()
  local p = GuildRecruiterReadyPanel
  if p then return p end
  p = GR_Compat.BackdropFrame("Frame", "GuildRecruiterReadyPanel", UIParent)
  p:SetWidth(360); p:SetHeight(120)
  p:SetFrameStrata("HIGH")
  p:SetClampedToScreen(true)
  GR_Compat.SetBackdrop(p, { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  p:SetMovable(true); p:EnableMouse(true); p:RegisterForDrag("LeftButton")
  p:SetScript("OnDragStart", function(self) self:StartMoving() end)
  p:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint(1)
    if point then GuildRecruiter_Settings.readyPos = { point, relPoint, x, y } end
  end)
  local pos = GuildRecruiter_Settings.readyPos
  if type(pos) == "table" and type(pos[1]) == "string" then
    p:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
  else
    p:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -200, -200)
  end
  p.title = p:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  p.title:SetPoint("TOPLEFT", 12, -10); p.title:SetPoint("RIGHT", p, "RIGHT", -30, 0); p.title:SetJustifyH("LEFT")
  local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() p:Hide() end)   -- our own frame only
  p.help = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  p.help:SetPoint("TOPLEFT", 12, -30); p.help:SetWidth(336); p.help:SetJustifyH("LEFT")
  p.help:SetText("Open Guild > Invite Member, click a name here, shift-click it in chat (or Copy + paste), then press Done.")
  p.nextBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  p.nextBtn:SetPoint("TOPLEFT", 10, -62); p.nextBtn:SetWidth(110); p.nextBtn:SetHeight(20); p.nextBtn:SetText("Copy next")
  p.nextBtn:SetScript("OnClick", function() GuildRecruiter_ReadyCopyNext() end)
  p.nextFS = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  p.nextFS:SetPoint("LEFT", p.nextBtn, "RIGHT", 8, 0); p.nextFS:SetWidth(220); p.nextFS:SetJustifyH("LEFT")
  p.rows = {}
  for i = 1, GR_Compat.READY_ROWS do
    local row = CreateFrame("Frame", nil, p)
    row:SetHeight(20)
    row:SetPoint("TOPLEFT", p, "TOPLEFT", 10, -88 - (i - 1) * 22)
    row:SetPoint("RIGHT", p, "RIGHT", -10, 0)
    local nb = CreateFrame("Button", nil, row)
    nb:SetPoint("LEFT", row, "LEFT", 0, 0); nb:SetWidth(180); nb:SetHeight(18)
    nb:RegisterForClicks("LeftButtonUp")
    nb.text = nb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    nb.text:SetAllPoints(nb); nb.text:SetJustifyH("LEFT")
    nb:SetScript("OnClick", function() GuildRecruiter_ReadyClick(row.pname) end)
    nb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Click to print in chat, then shift-click it there", 1, 1, 1, 1)
      GameTooltip:Show()
    end)
    nb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.nameBtn = nb
    row.age = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.age:SetPoint("LEFT", nb, "RIGHT", 4, 0); row.age:SetWidth(40); row.age:SetJustifyH("LEFT")
    local done = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    done:SetPoint("RIGHT", row, "RIGHT", 0, 0); done:SetWidth(52); done:SetHeight(18); done:SetText("Done")
    done:SetScript("OnClick", function() GuildRecruiter_ReadyDone(row.pname, "done") end)
    local copy = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    copy:SetPoint("RIGHT", done, "LEFT", -4, 0); copy:SetWidth(52); copy:SetHeight(18); copy:SetText("Copy")
    copy:SetScript("OnClick", function() GuildRecruiter_ReadyCopy(row.pname) end)
    row:Hide()
    p.rows[i] = row
  end
  p.more = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  p.more:SetJustifyH("LEFT")
  p.tick = 0
  p:SetScript("OnUpdate", function(self, elapsed)   -- ages + expiry, once a second while shown
    self.tick = self.tick - (elapsed or 0)
    if self.tick > 0 then return end
    self.tick = 1
    GuildRecruiter_ReadyRefresh()
  end)
  p:Hide()
  return p
end

-- redraw the panel (if built); it hides itself when the list is empty
function GuildRecruiter_ReadyRefresh()
  GuildRecruiter_ReadyPrune()
  GR_Compat.RenderList(GuildRecruiter_ReadyNames(), GuildRecruiter_Settings.ready)   -- the "Rawcruiter" chat tab, if the player made one
  local p = GuildRecruiterReadyPanel
  if not p then return end
  GuildRecruiter_ReadyPrune()
  local r = GuildRecruiter_Settings.ready or {}
  local names = GuildRecruiter_ReadyNames()
  local n = #names
  if n == 0 then p:Hide(); return end
  local title = "Ready to invite ("..n..")"
  if p.flashUntil and GetTime() < p.flashUntil and p.flashName and r[p.flashName] then
    title = "|cff40ff40New: "..p.flashName.."|r  --  "..title       -- the visible cue for a new name
  end
  p.title:SetText(title)
  p.nextFS:SetText("oldest: "..names[n].." ("..GuildRecruiter_ReadyAge(r[names[n]].t)..")")
  local shown = 0
  for i = 1, GR_Compat.READY_ROWS do
    local row = p.rows[i]
    local nm = names[i]
    if nm then
      row.pname = nm
      row.nameBtn.text:SetText(GR_Compat.PlayerLink(nm))
      row.age:SetText(GuildRecruiter_ReadyAge(r[nm].t))
      row:Show()
      shown = i
    else
      row.pname = nil
      row:Hide()
    end
  end
  local h = 96 + shown * 22
  if n > shown then
    p.more:ClearAllPoints()
    p.more:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -88 - shown * 22)
    p.more:SetText("+"..(n - shown).." more (Lists tab > Ready to invite)")
    p.more:Show()
    h = h + 14
  else
    p.more:Hide()
  end
  p:SetHeight(h)
end

-- show (or hide) the panel. newName = a name just added: the title flashes it
function GuildRecruiter_ReadyShow(on, newName)
  local p = GuildRecruiter_ReadyPanel()
  if newName then p.flashUntil = GetTime() + 8; p.flashName = newName end
  if on then p:Show(); GuildRecruiter_ReadyRefresh() else p:Hide() end
end

-- /gr ready
function GuildRecruiter_ReadyToggle()
  GuildRecruiter_ReadyPrune()
  local p = GuildRecruiterReadyPanel
  if p and p:IsShown() then p:Hide(); return end
  if GuildRecruiter_ReadyCount() == 0 then
    Print("Nobody is waiting for an invite. Names land on the Ready list when a whisper reply passes the reply rule (whisper-then-invite mode) or a Next press shows an invite prompt.")
    return
  end
  GuildRecruiter_ReadyShow(true)
end

-- at load: expire stale entries, and show the panel if anyone is still waiting
function GuildRecruiter_ReadyLoad()
  GuildRecruiter_ReadyPrune()
  local n = GuildRecruiter_ReadyCount()
  if n > 0 then
    Print(n.." name(s) still on the Ready list, waiting for your invite (/gr ready).")
    GuildRecruiter_ReadyShow(true)
  end
end

-- ---------------------------------------------------------------------------
-- List window: view/edit the contact queue, blacklist, and invite history
-- ---------------------------------------------------------------------------
local listFrame, listMode = nil, "queue"
local listData = {}
local NUM_ROWS, ROW_HEIGHT = 13, 18
local LIST_ORDER = { "ready", "candidates", "queue", "blacklist", "history", "negatives", "affirmatives" }
local LIST_TITLE = { ready = "Ready to invite", candidates = "Candidates (collected)", queue = "Queue (this run)", blacklist = "Blacklist",
  history = "Invite history", negatives = "Refusal words (no)", affirmatives = "Yes words (yesonly mode)" }

local function BuildListData()
  listData = {}
  if listMode == "ready" then
    listData = GuildRecruiter_ReadyNames()   -- newest first
  elseif listMode == "candidates" then
    for n in pairs(GuildRecruiter_Settings.candidates) do tinsert(listData, n) end
    table.sort(listData)
  elseif listMode == "queue" then
    for i = 1, #contactQueue do tinsert(listData, contactQueue[i]) end
  elseif listMode == "blacklist" then
    for n in pairs(GuildRecruiter_Settings.blacklist) do tinsert(listData, n) end
    table.sort(listData)
  elseif listMode == "negatives" then
    for n in pairs(GuildRecruiter_Settings.negatives) do tinsert(listData, n) end
  elseif listMode == "affirmatives" then
    for n in pairs(GuildRecruiter_Settings.affirmatives) do tinsert(listData, n) end
    table.sort(listData)
  else
    for n in pairs(GuildRecruiter_Settings.history) do tinsert(listData, n) end
    table.sort(listData)
  end
end

local function RemoveListItem(name)
  if listMode == "ready" then
    GuildRecruiter_ReadyDone(name, "removed")   -- the player took it off: the invite is recorded
  elseif listMode == "candidates" then
    GuildRecruiter_Settings.candidates[name] = nil
  elseif listMode == "queue" then
    for i = 1, #contactQueue do
      if contactQueue[i] == name then tremove(contactQueue, i); break end
    end
  elseif listMode == "blacklist" then
    GuildRecruiter_Settings.blacklist[name] = nil
  elseif listMode == "negatives" then
    GuildRecruiter_Settings.negatives[name] = nil
  elseif listMode == "affirmatives" then
    GuildRecruiter_Settings.affirmatives[name] = nil
  else
    GuildRecruiter_Settings.history[name] = nil
  end
end

local UpdateList  -- forward decl (handlers below capture it)
local LIST_HINT = "click a name to remove it (Blacklist / History ask first)"

-- GLOBAL (no upvalue cost to the panel): swap the Lists bottom row between the
-- idle launch buttons and a live run-control strip (progress + pause/resume/stop),
-- so an invite-all run is controllable right where it was launched.
-- invite a single candidate on demand (left-click in the Candidates view).
-- GLOBAL so the list-row handler adds no upvalues to BuildListsPanel.
-- Key-press mode: the invite itself is protected, and neither a list row nor a
-- typed command can run a secure action, so this only SETS the name on the
-- secure Next button (GuildRecruiter_oneName); the next click on that button
-- (or its key) sends /ginvite and GuildRecruiter_InvitedOne records it.
function GuildRecruiter_InviteOne(name)
  if not name then return end
  if not IsInGuild() then Print("You're not in a guild.") return end
  if running then Print("A run is active -- stop it first to invite individually.") return end
  if GR_Compat.RequiresHardwareEvent then
    GuildRecruiter_oneName = name
    GuildRecruiter_ShowNext()
    Print("Invite "..name..": click the Next button (under the minimap button) or press its key for the invite prompt; the name then waits on the Ready list until you invite it in Guild > Invite Member and press Done. /gr stop drops it.")
    return
  end
  -- timer-loop client: invite right away, as in 1.12
  local ok, err = GR_Compat.Press(DoGuildInvite, name)
  if not ok then error(err, 0) end
  GuildRecruiter_InvitedOne(name)
end

-- record a single invite (history, candidate list, tally). Key-press mode: run
-- by GuildRecruiter_ReadyDone (Done, or the join/decline message), never when
-- the prompt is shown. Timer-loop client: right after the invite call.
function GuildRecruiter_InvitedOne(name)
  if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
  GuildRecruiter_Settings.history[name] = { t = time(), p = GuildRecruiter_Settings.activeProfile }
  if GuildRecruiter_Settings.candidates then GuildRecruiter_Settings.candidates[name] = nil end
  TallyBump("invited")
  Print("Invited "..name..".")
  GuildRecruiter_ListRefresh()
end

function GuildRecruiter_ListControls(fr)
  if not fr or not fr.inviteBtn then return end
  if running then
    fr.inviteBtn:Hide(); fr.sendBtn:Hide()
    fr.lpauseBtn:Show(); fr.lstopBtn:Show()
    fr.lpauseBtn:SetText(paused and "Resume" or "Pause")
    local total = GuildRecruiter_runTotal or 0
    local verb = (GuildRecruiter_runKind == "blast" or GuildRecruiter_runKind == "send") and "Inviting" or "Working"
    local prog = (total > 0) and (stats.contacted.." of "..total) or (stats.contacted.." sent")
    -- key-press mode: one invite per click on the secure Next button (this tab
    -- has no Next of its own: a secure button in this window would lock the
    -- window in combat)
    local left = #contactQueue + #replyQueue
    if GR_Compat.RequiresHardwareEvent and not paused and left > 0 then
      local _, hm = GuildRecruiter_HeadMode()   -- read-only (no A/B roll)
      if hm == nil or GuildRecruiter_TimerMode(hm) then prog = prog.." -- "..left.." whisper(s) going out"
      else prog = prog.." -- "..left.." left, click Next by the minimap" end
    end
    local nr = GuildRecruiter_ReadyCount()
    if GR_Compat.RequiresHardwareEvent and nr > 0 then prog = prog.." | "..nr.." ready to invite" end
    fr.hint:SetText((paused and "|cffffcc00Paused|r -- " or ("|cff40ff40"..verb.."|r  "))..prog)
  else
    fr.lpauseBtn:Hide(); fr.lstopBtn:Hide()
    fr.inviteBtn:Show(); fr.sendBtn:Show()
    local cc = CountTable(GuildRecruiter_Settings.candidates or {})
    fr.inviteBtn:SetText("Invite all ("..cc..")")
    if cc > 0 then fr.inviteBtn:Enable(); fr.sendBtn:Enable() else fr.inviteBtn:Disable(); fr.sendBtn:Disable() end
    if listMode == "ready" then
      -- the Ready list: names waiting for YOUR invite in Guild > Invite Member
      fr.hint:SetText("waiting for your invite (/gr ready for the panel) -- click a name once invited: records it, like Done")
    else
      fr.hint:SetText(listMode == "candidates"
        and (GR_Compat.RequiresHardwareEvent and "left-click a name, then Next, for its invite prompt -- right-click to drop it"
             or "left-click a name to invite it -- right-click to drop it") or LIST_HINT)
    end
  end
end

local function BuildListsPanel(parent)
  local fr = CreateFrame("Frame", "GuildRecruiterList", parent)
  fr:SetAllPoints(parent)
  fr.rows = {}

  fr.cycle = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.cycle:SetPoint("TOP", 0, -38); fr.cycle:SetWidth(260); fr.cycle:SetHeight(22)
  fr.cycle:SetScript("OnClick", function(self)
    GuildRecruiter_OpenMenu(self, LIST_ORDER, LIST_TITLE, function(v) listMode = v; UpdateList() end)
  end)
  GuildRecruiter_DDArrow(fr.cycle)

  fr.hint = fr:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  fr.hint:SetPoint("TOP", 0, -62); fr.hint:SetText(LIST_HINT)

  local scroll = GR_Compat.FauxScrollFrame("GuildRecruiterListScroll", fr)
  scroll:SetPoint("TOPLEFT", 16, -78)
  scroll:SetPoint("BOTTOMRIGHT", -34, 52)
  scroll:SetScript("OnVerticalScroll", function(self, offset) GR_Compat.FauxScrollOnVertical(self, offset, ROW_HEIGHT, UpdateList) end)
  fr.scroll = scroll

  for i = 1, NUM_ROWS do
    local row = CreateFrame("Button", nil, fr)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
    local ht = row:CreateTexture(nil, "HIGHLIGHT")
    ht:SetAllPoints(row); ht:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    ht:SetBlendMode("ADD"); ht:SetAlpha(0.4)
    local t = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    t:SetPoint("LEFT", 6, 0); t:SetJustifyH("LEFT"); row.text = t
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
      if not self.pname then return end
      local nm = self.pname
      if listMode == "candidates" then
        if button == "RightButton" then RemoveListItem(nm)             -- drop a false positive
        else GuildRecruiter_InviteOne(nm) end                          -- left-click invites this one
        UpdateList()
      elseif listMode == "ready" then                                  -- records the invite: confirm
        GuildRecruiter_Confirm("Remove |cffffffff"..nm.."|r from the Ready list and record the invite (same as Done)?",
          function() RemoveListItem(nm); UpdateList() end)
      elseif listMode == "blacklist" or listMode == "history" then     -- persistent: confirm
        GuildRecruiter_Confirm("Remove |cffffffff"..nm.."|r from the "..(LIST_TITLE[listMode] or listMode).."?",
          function() RemoveListItem(nm); UpdateList() end)
      else
        RemoveListItem(nm); UpdateList()
      end
    end)
    row:Hide()
    fr.rows[i] = row
  end

  -- add-to-blacklist box
  local addEdit = CreateFrame("EditBox", "GuildRecruiterListAdd", fr, "InputBoxTemplate")
  addEdit:SetPoint("BOTTOMLEFT", 18, 20); addEdit:SetWidth(150); addEdit:SetHeight(20)
  addEdit:SetAutoFocus(false); addEdit:SetMaxLetters(40)
  local function doAdd()
    local n = addEdit:GetText()
    if n and n ~= "" then
      if listMode == "negatives" then
        GuildRecruiter_Settings.negatives[string.lower(n)] = true
      elseif listMode == "affirmatives" then
        GuildRecruiter_Settings.affirmatives[string.lower(n)] = true
      else
        GuildRecruiter_Settings.blacklist[string.lower(n)] = true
        listMode = "blacklist"
      end
      addEdit:SetText(""); UpdateList()
    end
  end
  local addBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  addBtn:SetPoint("LEFT", addEdit, "RIGHT", 8, 0); addBtn:SetWidth(92); addBtn:SetHeight(22)
  addBtn:SetText("Add"); addBtn:SetScript("OnClick", doAdd)
  addEdit:SetScript("OnEnterPressed", function(self) doAdd(); self:ClearFocus() end)
  addEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  -- act on the collected candidate list: Invite all (fast guild invites) or
  -- Send (paced, respects Mode -- e.g. a whisper campaign)
  fr.inviteBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.inviteBtn:SetPoint("BOTTOMRIGHT", -16, 18); fr.inviteBtn:SetWidth(160); fr.inviteBtn:SetHeight(22)
  fr.inviteBtn:SetScript("OnClick", function()
    local cnt = CountTable(GuildRecruiter_Settings.candidates)
    if cnt == 0 then Print("No collected candidates yet. Turn on Collect (Settings) and scan.") return end
    GuildRecruiter_Confirm(GR_Compat.RequiresHardwareEvent
      and ("Invite all "..cnt.." collected candidate(s)? This client needs a click per invite: each click on the Next button by the minimap (or its key) sends one, not in combat.")
      or ("Invite all "..cnt.." collected candidate(s) now? Guild invites go out as fast as the server allows."),
      function() GuildRecruiter_SendToCandidates(true) end)
  end)
  fr.sendBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.sendBtn:SetPoint("RIGHT", fr.inviteBtn, "LEFT", -8, 0); fr.sendBtn:SetWidth(104); fr.sendBtn:SetHeight(22); fr.sendBtn:SetText("Send (paced)")
  fr.sendBtn:SetScript("OnClick", function()
    local cnt = CountTable(GuildRecruiter_Settings.candidates)
    if cnt == 0 then Print("No collected candidates yet. Turn on Collect (Settings) and scan.") return end
    GuildRecruiter_Confirm("Send to "..cnt.." candidate(s) at your paced rate ("..(MODE_LABEL[GuildRecruiter_Settings.mode] or "?").. ")?",
      function() GuildRecruiter_SendToCandidates(false) end)
  end)
  -- run controls (swap in for the launch buttons while a run is active)
  fr.lpauseBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.lpauseBtn:SetPoint("BOTTOMRIGHT", -16, 18); fr.lpauseBtn:SetWidth(104); fr.lpauseBtn:SetHeight(22); fr.lpauseBtn:SetText("Pause")
  fr.lpauseBtn:SetScript("OnClick", function() GuildRecruiter_TogglePause() end)
  fr.lpauseBtn:Hide()
  fr.lstopBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.lstopBtn:SetPoint("RIGHT", fr.lpauseBtn, "LEFT", -8, 0); fr.lstopBtn:SetWidth(70); fr.lstopBtn:SetHeight(22); fr.lstopBtn:SetText("|cffff6060Stop|r")
  fr.lstopBtn:SetScript("OnClick", function() GuildRecruiter_StopRun() end)
  fr.lstopBtn:Hide()
  -- key-press mode: no Next button here. Invites need the one secure button
  -- (GuildRecruiterNextButton, by the minimap): a plain button can't run a
  -- secure action, and a secure one in this window would protect the window.
  -- keep the run strip / launch buttons live while this tab is shown
  fr.ltick = 0
  fr:SetScript("OnUpdate", function(self, elapsed)
    fr.ltick = fr.ltick - (elapsed or 0)
    if fr.ltick > 0 then return end
    fr.ltick = 0.3
    GuildRecruiter_ListControls(fr)
  end)

  listFrame = fr
  return fr
end

UpdateList = function()
  if not listFrame then return end
  BuildListData()
  local n = #listData
  local offset = GR_Compat.FauxScrollOffset(listFrame.scroll)
  for i = 1, NUM_ROWS do
    local idx = offset + i
    local row = listFrame.rows[i]
    if idx <= n then
      local nm = listData[idx]
      row.pname = nm
      local disp = nm
      if listMode == "ready" then
        local e = GuildRecruiter_Settings.ready and GuildRecruiter_Settings.ready[nm]
        if type(e) == "table" then
          disp = nm.."  |cff999999("..(e.kind == "reply" and "replied " or "prompted ")..GuildRecruiter_ReadyAge(e.t).." ago)|r"
        end
      elseif listMode == "history" then
        local e = GuildRecruiter_Settings.history[nm]
        if type(e) == "table" and e.p == "(remote)" then disp = nm.."  |cff7f9fffguild|r" end  -- shared by a guildmate
      elseif listMode == "candidates" then
        local c = GuildRecruiter_Settings.candidates[nm]
        if type(c) == "table" and c.level then disp = nm.."  |cff999999("..c.level..(c.class and (" "..c.class) or "")..")|r" end
      end
      row.text:SetText(disp); row:Show()
    else
      row.pname = nil; row:Hide()
    end
  end
  GR_Compat.FauxScrollUpdate(listFrame.scroll, n, NUM_ROWS, ROW_HEIGHT)
  listFrame.cycle:SetText("View: "..(LIST_TITLE[listMode] or listMode).."  ("..n..")")
  GuildRecruiter_ListControls(listFrame)   -- idle launch buttons vs live run strip
end

-- redraw the Lists tab if it is open (after a single invite from the Next button)
function GuildRecruiter_ListRefresh()
  if listFrame and listFrame:IsVisible() then UpdateList() end
end

-- ---------------------------------------------------------------------------
-- Config GUI
-- ---------------------------------------------------------------------------
local configFrame
local RefreshConfig, RefreshStats, RefreshABPanel  -- forward decls

-- level setters used by both the GUI boxes and slash: clamp to 1-60, drop any
-- fraction, and keep min <= max (raising the other bound if they cross)
local function SetMinLevel(v)
  local raw = tonumber(v)
  v = clamp(math.floor(raw or 1), 1, 60)
  if raw and raw ~= v then Print("Min level adjusted to "..v.." (allowed 1-60).") end
  GuildRecruiter_Settings.minLevel = v
  if GuildRecruiter_Settings.maxLevel < v then GuildRecruiter_Settings.maxLevel = v; Print("Max raised to "..v.." to keep min <= max.") end
  RecomputeBand(); RefreshConfig()
end
local function SetMaxLevel(v)
  local raw = tonumber(v)
  v = clamp(math.floor(raw or 60), 1, 60)
  if raw and raw ~= v then Print("Max level adjusted to "..v.." (allowed 1-60).") end
  GuildRecruiter_Settings.maxLevel = v
  if GuildRecruiter_Settings.minLevel > v then GuildRecruiter_Settings.minLevel = v; Print("Min lowered to "..v.." to keep min <= max.") end
  RecomputeBand(); RefreshConfig()
end

local function ApplyInvite(v) GuildRecruiter_Settings.inviteDelay = clamp(math.floor(v + 0.5), INVITE_MIN, INVITE_MAX); RefreshConfig() end
local function ApplyWho(v)    GuildRecruiter_Settings.whoDelay    = clamp(math.floor(v + 0.5), WHO_MIN, WHO_MAX); RefreshConfig() end

local function CycleMethod()
  local cur, idx = GuildRecruiter_Settings.inviteMethod or "auto", 1
  for i = 1, #METHOD_ORDER do if METHOD_ORDER[i] == cur then idx = i end end
  idx = idx + 1; if idx > #METHOD_ORDER then idx = 1 end
  GuildRecruiter_Settings.inviteMethod = METHOD_ORDER[idx]; RefreshConfig()
end

local function CycleMode()
  local cur, idx = GuildRecruiter_Settings.mode or "invite", 1
  for i = 1, #MODE_ORDER do if MODE_ORDER[i] == cur then idx = i end end
  idx = idx + 1; if idx > #MODE_ORDER then idx = 1 end
  GuildRecruiter_Settings.mode = MODE_ORDER[idx]; RefreshConfig()
end

local function MakeSlider(parent, prefix, label, alo, ahi, y, applyFn)
  local sl = GR_Compat.TemplateFrame("Slider", prefix.."Slider", parent, "OptionsSliderTemplate")
  sl:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y)
  sl:SetWidth(168); sl:SetHeight(16)
  sl:SetMinMaxValues(alo, ahi); sl:SetValueStep(1)
  GR_Compat.SetChildText(sl, "Text", label)   -- 1.12: _G[prefix.."SliderText"]
  GR_Compat.SetChildText(sl, "Low", alo)
  GR_Compat.SetChildText(sl, "High", ahi)
  local ed = CreateFrame("EditBox", prefix.."Edit", parent, "InputBoxTemplate")
  ed:SetPoint("LEFT", sl, "RIGHT", 26, 0)
  ed:SetWidth(38); ed:SetHeight(20)
  ed:SetAutoFocus(false); ed:SetNumeric(true); ed:SetMaxLetters(3)
  sl:SetScript("OnValueChanged", function(self) if not configFrame or not configFrame.updating then applyFn(self:GetValue()) end end)
  ed:SetScript("OnEnterPressed", function(self) local v = tonumber(self:GetText()); if v then applyFn(v) end; self:ClearFocus() end)
  ed:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return sl, ed
end

local function MakeCheck(parent, name, label, x, y, settingKey)
  local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  cb:SetWidth(22); cb:SetHeight(22)
  GR_Compat.SetChildText(cb, "Text", label)   -- 1.12: _G[name.."Text"]
  cb:SetScript("OnClick", function(self)
    GuildRecruiter_Settings[settingKey] = (self:GetChecked() and true) or false
    if settingKey == "guildSync" then RecomputeBand() end
  end)
  return cb
end

local function MakeNumBox(parent, name, x, y, w, maxLetters, applyFn)
  local ed = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
  ed:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  ed:SetWidth(w); ed:SetHeight(20)
  ed:SetAutoFocus(false); ed:SetNumeric(true); ed:SetMaxLetters(maxLetters)
  ed:SetScript("OnEnterPressed", function(self) local v = tonumber(self:GetText()); if v then applyFn(v) end; self:ClearFocus() end)
  ed:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return ed
end

local function Label(parent, text, x, y)
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  fs:SetText(text)
  return fs
end

-- a categorised section subheading (gold caption + a faint underline) so option
-- panels are always grouped, never a flat wall of controls
local function Header(parent, text, x, y, w)
  local h = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  h:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  h:SetText(text); h:SetTextColor(1, 0.82, 0)
  local ln = parent:CreateTexture(nil, "ARTWORK")
  GR_Compat.ColorTexture(ln, 1, 0.82, 0, 0.3)
  ln:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 15)
  ln:SetWidth(w); ln:SetHeight(1)
  return h
end

RefreshConfig = function()
  if not configFrame then return end
  local s = GuildRecruiter_Settings
  configFrame.updating = true
  configFrame.inviteSlider:SetValue(clamp(s.inviteDelay, INVITE_MIN, INVITE_MAX))
  configFrame.whoSlider:SetValue(clamp(s.whoDelay, WHO_MIN, WHO_MAX))
  configFrame.inviteEdit:SetText(tostring(s.inviteDelay))
  configFrame.whoEdit:SetText(tostring(s.whoDelay))
  configFrame.methodBtn:SetText(METHOD_LABEL[s.inviteMethod] or s.inviteMethod)
  configFrame.modeBtn:SetText(MODE_LABEL[s.mode] or s.mode)
  local msg = s.whisperMsg or ""
  if string.len(msg) > 84 then msg = string.sub(msg, 1, 82).."..." end
  configFrame.whisperPreview:SetText(msg ~= "" and ("|cffd0d0d0"..msg.."|r") or "|cff808080(empty)|r")
  configFrame.minEdit:SetText(tostring(s.minLevel))
  configFrame.maxEdit:SetText(tostring(s.maxLevel))
  configFrame.capEdit:SetText(tostring(s.sessionCap))
  configFrame.jitterCheck:SetChecked(s.jitter)
  configFrame.syncCheck:SetChecked(s.guildSync)
  configFrame.combatCheck:SetChecked(s.skipCombat)
  configFrame.instanceCheck:SetChecked(s.skipInstance)
  configFrame.quietCheck:SetChecked(s.quietWho)
  configFrame.collectCheck:SetChecked(s.collectOnly)
  configFrame.autoScanCheck:SetChecked(s.autoScan)
  configFrame.autoScanEdit:SetText(tostring(s.autoScanDelay))
  configFrame.replyBtn:SetText(REPLY_LABEL[s.replyMode] or s.replyMode)

  -- This tab is always variant A (the control) and never locks. We only enable
  -- controls where they make sense for the current MODE:
  --   method  -> only matters when we actually invite (not whisper-only mode)
  --   reply   -> only matters in whisper-then-invite mode
  --   whisper -> only matters when a whisper is sent (whisper or whisperinvite)
  local mode = s.mode
  local function setBtn(b, on) if on then b:Enable() else b:Disable() end end
  setBtn(configFrame.methodBtn, mode ~= "whisper")
  setBtn(configFrame.replyBtn,  mode == "whisperinvite")
  setBtn(configFrame.whisperBtn, mode == "whisper" or mode == "whisperinvite")
  configFrame.abNote:SetText(GuildRecruiter_ABActive()
    and "|cff40ff40A/B on -- this is variant A (control)|r" or "")
  -- tell the user WHY some Invite controls are greyed for the current mode
  local hw = GR_Compat.RequiresHardwareEvent   -- Forever: the addon never sends the invite itself
  if mode == "invite" then
    configFrame.modeNote:SetText(hw and "Invite-only: each Next press puts one name on the Ready list; you send the invite. Reply & Message aren't used."
      or "Invite-only: sends a guild invite straight away. Reply & Message aren't used.")
  elseif mode == "whisper" then
    configFrame.modeNote:SetText("Whisper-only: just messages them. Method & Reply aren't used.")
  else
    configFrame.modeNote:SetText(hw and "Whisper (automatic); a reply that passes the Reply rule goes to the Ready list (/gr ready) and you invite."
      or "Whisper, then invite when they reply (per the Reply rule).")
  end

  configFrame.updating = false
end

-- Clamp + store the auto-rescan gap. GLOBAL so the config box's applyFn adds no
-- upvalue to BuildSettingsPanel (which sits near the 32-upvalue limit). Defined
-- here (after RefreshConfig) so it captures configFrame/RefreshConfig as upvalues.
function GuildRecruiter_SetAutoScanDelay(v)
  local raw = tonumber(v)
  v = clamp(math.floor(raw or AUTO_MIN), AUTO_MIN, AUTO_MAX)
  if raw and raw ~= v then Print("Rescan gap adjusted to "..v.."s (allowed "..AUTO_MIN.."-"..AUTO_MAX..").") end
  GuildRecruiter_Settings.autoScanDelay = v
  if configFrame then RefreshConfig() end
end

-- One-line description of the /who query in flight + how far through the sweep
-- we are, e.g. "7-10 c-Warrior  (query 12, +3 queued)". GLOBAL so both the
-- status line and the progress bar can show it without adding upvalues to the
-- near-limit BuildSettingsPanel.
function GuildRecruiter_ScanNow()
  if not current then return "(preparing)" end
  local b = current.lo..(current.hi and current.hi ~= current.lo and ("-"..current.hi) or "")
  if current.class then b = b.." c-"..current.class end
  local pend = #pending
  return b.."  (query "..stats.queries..(pend > 0 and (", +"..pend.." queued") or "")..")"
end

local function StatusLine()
  if not running then return "Idle." end
  -- sweep position: where the band cursor sits (@lvl) and the current band width
  local pos = "band "..myLo.."-"..myHi.." @"..lo.." w"..width
  if paused then return "Paused -- /who "..GuildRecruiter_ScanNow().." | "..pos.." | queued "..#contactQueue end
  if (GuildRecruiter_rescanWait or 0) > 0 then
    return "rescanning in "..math.ceil(GuildRecruiter_rescanWait).."s | "..pos
         .." | queued "..#contactQueue.." | sent "..stats.contacted
  end
  if scanning and GuildRecruiter_Settings.collectOnly then
    return "collecting  /who "..GuildRecruiter_ScanNow().."  "..pos
         .."  collected "..stats.collected.." (list "..CountTable(GuildRecruiter_Settings.candidates)..")"
  end
  if scanning then
    return "scan  /who "..GuildRecruiter_ScanNow().."  "..pos
         .."  queued "..#contactQueue.." sent "..stats.contacted
         ..(stats.dropped > 0 and (" drop "..stats.dropped) or "")
         ..(CountTable(recruiters) > 0 and (" peers "..CountTable(recruiters)) or "")
  end
  return "draining  queued "..#contactQueue.." | sent "..stats.contacted
       .." ("..stats.invited.." inv, "..stats.whispered.." wh) | peers "..CountTable(recruiters)
end

-- GLOBAL on purpose: the settings-tab reply-mode button calls this, so its
-- OnClick closure references a global (not a local) and adds no upvalue to
-- BuildSettingsPanel, which sits near Lua 5.0's 32-upvalue-per-function limit.
function GuildRecruiter_CycleReplyMode()
  local cur, idx = GuildRecruiter_Settings.replyMode or "notno", 1
  for i = 1, #REPLY_ORDER do if REPLY_ORDER[i] == cur then idx = i end end
  idx = idx + 1; if idx > #REPLY_ORDER then idx = 1 end
  GuildRecruiter_Settings.replyMode = REPLY_ORDER[idx]
  RefreshConfig()
end

-- ---------------------------------------------------------------------------
-- Custom dropdowns (plain frames -- avoids UIDropDownMenu's finicky 1.12 API).
-- The open handler is GLOBAL so the settings dropdown buttons add no upvalue.
-- ---------------------------------------------------------------------------
local DD_DEF = {
  method = { METHOD_ORDER, METHOD_LABEL, "inviteMethod" },
  mode   = { MODE_ORDER,   MODE_LABEL,   "mode" },
  reply  = { REPLY_ORDER,  REPLY_LABEL,  "replyMode" },
}
local ddPopup   -- shared option list, built lazily

local function BuildDDPopup()
  local p = GR_Compat.BackdropFrame("Frame", "GuildRecruiterDDPopup", UIParent)
  p:SetFrameStrata("FULLSCREEN_DIALOG")
  GR_Compat.SetBackdrop(p, {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  p:EnableMouse(true); p:Hide()
  p.opts = {}
  for i = 1, 7 do   -- the longest list: the Lists tab's 7 views
    local ob = CreateFrame("Button", nil, p)
    ob:SetHeight(16)
    ob:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 16)
    ob:SetPoint("RIGHT", p, "RIGHT", -6, 0)
    local ht = ob:CreateTexture(nil, "HIGHLIGHT")
    ht:SetAllPoints(ob); ht:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    ht:SetBlendMode("ADD"); ht:SetAlpha(0.5)
    local t = ob:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    t:SetPoint("LEFT", 4, 0); t:SetPoint("RIGHT", -4, 0); t:SetJustifyH("LEFT"); ob.text = t
    ob:SetScript("OnClick", function(self)
      if self.cb then self.cb(self.value)          -- generic menu (e.g. Lists view)
      else self.target[self.key] = self.value end  -- settings/variant dropdown
      p:Hide(); GuildRecruiter_RefreshOpen()
    end)
    p.opts[i] = ob
  end
  ddPopup = p
end

-- a real dropdown is a button + a down-arrow; add the vanilla dropdown arrow so
-- these read as comboboxes, not plain buttons. GLOBAL -> adds no panel upvalue.
function GuildRecruiter_DDArrow(btn)
  local a = btn:CreateTexture(nil, "OVERLAY")
  -- scrollbar down-arrow: guaranteed present in 1.12 (FauxScrollFrame uses it)
  a:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
  a:SetWidth(18); a:SetHeight(18)
  a:SetPoint("RIGHT", btn, "RIGHT", -3, 0)
end

-- refresh whichever panels are open (called after any dropdown pick)
function GuildRecruiter_RefreshOpen()
  if RefreshConfig then RefreshConfig() end
  if RefreshABPanel then RefreshABPanel() end
  if RefreshStats then RefreshStats() end
end

-- open the option list for `kind`, writing the picked value into `target`
-- (defaults to the live settings table; pass a variant table for A/B rows)
function GuildRecruiter_OpenDD(btn, kind, target)
  target = target or GuildRecruiter_Settings
  local def = DD_DEF[kind]
  GuildRecruiter_OpenMenu(btn, def[1], def[2], nil, target, def[3])
end

-- open a list popup anchored under `btn`. Either supply (target,key) to write the
-- picked value into a table, or a `cb(value)` to handle the pick yourself.
function GuildRecruiter_OpenMenu(btn, order, label, cb, target, key)
  if not ddPopup then BuildDDPopup() end
  if ddPopup:IsShown() and ddPopup.owner == btn then ddPopup:Hide(); return end
  ddPopup.owner = btn
  local n = #order
  for i = 1, 7 do
    local ob = ddPopup.opts[i]
    if i <= n then
      local k = order[i]
      ob.value = k; ob.cb = cb; ob.target = target; ob.key = key
      ob.text:SetText(label[k] or k); ob:Show()
    else
      ob:Hide()
    end
  end
  ddPopup:SetWidth(btn:GetWidth())
  ddPopup:SetHeight(n * 16 + 8)
  ddPopup:ClearAllPoints()
  ddPopup:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
  ddPopup:Show()
end

-- ---------------------------------------------------------------------------
-- Shared multi-line message editor. A single-line box can't show a 200-char
-- whisper; this popup wraps the whole message so you can read while editing.
-- Opened by the Settings tab (variant A) and each A/B challenger row; it writes
-- back to whichever target table it was opened for. GLOBAL open handler so the
-- caller buttons add no upvalue.
-- ---------------------------------------------------------------------------
local msgEditor

local function BuildMsgEditor()
  local f = GR_Compat.BackdropFrame("Frame", "GuildRecruiterMsgEditor", UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetWidth(430); f:SetHeight(200); f:SetPoint("CENTER", 0, 80)
  GR_Compat.SetBackdrop(f, {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  })
  f:EnableMouse(true); f:Hide()
  tinsert(UISpecialFrames, "GuildRecruiterMsgEditor")   -- Escape closes (house rule)

  f.titleFS = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  f.titleFS:SetPoint("TOP", 0, -16)
  local hint = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  hint:SetPoint("TOPLEFT", 20, -40); hint:SetText("|cff999999%p = player name    %g = guild name|r")

  local box = GR_Compat.BackdropFrame("Frame", nil, f)
  box:SetPoint("TOPLEFT", 18, -58); box:SetPoint("TOPRIGHT", -18, -58); box:SetHeight(80)
  GR_Compat.SetBackdrop(box, {
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  GR_Compat.SetBackdropColor(box, 0, 0, 0, 0.6)

  local eb = CreateFrame("EditBox", "GuildRecruiterMsgEditBox", box)
  eb:SetPoint("TOPLEFT", 8, -6); eb:SetPoint("BOTTOMRIGHT", -8, 6)
  if eb.SetMultiLine then eb:SetMultiLine(true) end
  eb:SetFont("Fonts\\FRIZQT__.TTF", 12, "")   -- explicit empty flags: newer clients may reject the 2-arg form
  eb:SetMaxLetters(255); eb:SetAutoFocus(false); eb:SetTextInsets(2, 2, 2, 2)
  eb:SetScript("OnEscapePressed", function() f:Hide() end)
  f.eb = eb

  f.countFS = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  f.countFS:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -4)
  eb:SetScript("OnTextChanged", function(self) f.countFS:SetText(string.len(self:GetText()).."/255") end)

  local save = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  save:SetWidth(96); save:SetHeight(24); save:SetPoint("BOTTOMRIGHT", -18, 14); save:SetText("Save")
  save:SetScript("OnClick", function()
    local t = f.eb:GetText() or ""
    t = string.gsub(t, "\n", " "); t = string.gsub(t, "\r", "")   -- whispers are one line
    t = string.gsub(t, "^%s+", ""); t = string.gsub(t, "%s+$", "")
    if f.target == GuildRecruiter_Settings then
      f.target.whisperMsg = t                       -- control: keep exactly what was typed
    else
      f.target.whisperMsg = (t ~= "" and t) or nil  -- challenger: blank = inherit variant A
    end
    f:Hide(); GuildRecruiter_RefreshOpen()
  end)
  local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  cancel:SetWidth(96); cancel:SetHeight(24); cancel:SetPoint("RIGHT", save, "LEFT", -8, 0); cancel:SetText("Cancel")
  cancel:SetScript("OnClick", function() f:Hide() end)

  msgEditor = f
end

-- open the editor bound to `target` (GuildRecruiter_Settings for variant A, or a
-- challenger table). Blank in a challenger means "inherit variant A's message".
function GuildRecruiter_EditMessage(target)
  if not msgEditor then BuildMsgEditor() end
  msgEditor.target = target
  local ctrl = (target == GuildRecruiter_Settings)
  msgEditor.titleFS:SetText(ctrl and "Whisper message -- Variant A (control)"
                                  or ("Whisper message -- Variant "..(target.name or "?").." (blank = same as A)"))
  msgEditor.eb:SetText(target.whisperMsg or "")
  msgEditor:Show(); msgEditor.eb:SetFocus(); msgEditor.eb:SetCursorPosition(0)
end

local function BuildSettingsPanel(parent)
  local fr = CreateFrame("Frame", "GuildRecruiterConfig", parent)
  fr:SetAllPoints(parent)

  -- LEFT column: Speed / Safety / Targets --------------------------------
  Header(fr, "Speed", 18, -44, 250)
  fr.inviteSlider, fr.inviteEdit = MakeSlider(fr, "GuildRecruiterConfigInvite", "Invite/contact delay (s)", INVITE_MIN, INVITE_MAX, -84, ApplyInvite)
  fr.whoSlider,    fr.whoEdit    = MakeSlider(fr, "GuildRecruiterConfigWho",    "/who delay (s)",           WHO_MIN,    WHO_MAX,    -132, ApplyWho)
  fr.jitterCheck   = MakeCheck(fr, "GuildRecruiterConfigJitter", "Random delays (anti-detection)", 20, -162, "jitter")

  Header(fr, "Safety", 18, -196, 250)
  fr.quietCheck    = MakeCheck(fr, "GuildRecruiterConfigQuiet",    "Quiet /who chat",    20, -222, "quietWho")
  fr.combatCheck   = MakeCheck(fr, "GuildRecruiterConfigCombat",   "Pause in combat",    20, -246, "skipCombat")
  fr.instanceCheck = MakeCheck(fr, "GuildRecruiterConfigInstance", "Pause in instances", 20, -270, "skipInstance")

  Header(fr, "Targets", 18, -304, 250)
  Label(fr, "Levels", 24, -330)
  fr.minEdit = MakeNumBox(fr, "GuildRecruiterConfigMin", 150, -326, 34, 2, function(v) SetMinLevel(v) end)
  Label(fr, "to", 192, -330)
  fr.maxEdit = MakeNumBox(fr, "GuildRecruiterConfigMax", 214, -326, 34, 2, function(v) SetMaxLevel(v) end)
  Label(fr, "Session cap (0=off)", 24, -354)
  fr.capEdit = MakeNumBox(fr, "GuildRecruiterConfigCap", 150, -350, 34, 4, function(v) GuildRecruiter_Settings.sessionCap = clamp(math.floor(v), 0, 9999) end)

  -- RIGHT column: Invites -------------------------------------------------
  Header(fr, "Invites", 292, -44, 250)
  -- three uniform inline dropdown rows: label at 298, dropdown aligned at 352
  Label(fr, "Method:", 298, -82)
  fr.methodBtn = CreateFrame("Button", "GuildRecruiterConfigMethodBtn", fr, "UIPanelButtonTemplate")
  fr.methodBtn:SetPoint("TOPLEFT", 352, -78); fr.methodBtn:SetWidth(186); fr.methodBtn:SetHeight(22)
  fr.methodBtn:SetScript("OnClick", function(self) GuildRecruiter_OpenDD(self, "method") end)
  GuildRecruiter_DDArrow(fr.methodBtn)
  Label(fr, "Mode:", 298, -108)
  fr.modeBtn = CreateFrame("Button", "GuildRecruiterConfigModeBtn", fr, "UIPanelButtonTemplate")
  fr.modeBtn:SetPoint("TOPLEFT", 352, -104); fr.modeBtn:SetWidth(186); fr.modeBtn:SetHeight(22)
  fr.modeBtn:SetScript("OnClick", function(self) GuildRecruiter_OpenDD(self, "mode") end)
  GuildRecruiter_DDArrow(fr.modeBtn)
  Label(fr, "Reply:", 298, -134)
  fr.replyBtn = CreateFrame("Button", "GuildRecruiterConfigReplyBtn", fr, "UIPanelButtonTemplate")
  fr.replyBtn:SetPoint("TOPLEFT", 352, -130); fr.replyBtn:SetWidth(186); fr.replyBtn:SetHeight(22)
  fr.replyBtn:SetScript("OnClick", function(self) GuildRecruiter_OpenDD(self, "reply") end)
  GuildRecruiter_DDArrow(fr.replyBtn)
  fr.syncCheck   = MakeCheck(fr, "GuildRecruiterConfigSync",   "Guild sync (dedup + split)",   298, -160, "guildSync")
  Label(fr, "Whisper message:", 298, -188)
  fr.whisperPreview = fr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fr.whisperPreview:SetPoint("TOPLEFT", 298, -204); fr.whisperPreview:SetWidth(240)
  fr.whisperPreview:SetJustifyH("LEFT"); fr.whisperPreview:SetJustifyV("TOP"); fr.whisperPreview:SetHeight(30)
  fr.whisperBtn = CreateFrame("Button", "GuildRecruiterConfigWhisperBtn", fr, "UIPanelButtonTemplate")
  fr.whisperBtn:SetPoint("TOPLEFT", 298, -238); fr.whisperBtn:SetWidth(130); fr.whisperBtn:SetHeight(22)
  fr.whisperBtn:SetText("Edit message...")
  fr.whisperBtn:SetScript("OnClick", function() GuildRecruiter_EditMessage(GuildRecruiter_Settings) end)
  fr.abNote = fr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fr.abNote:SetPoint("TOPLEFT", 298, -266); fr.abNote:SetWidth(240); fr.abNote:SetHeight(14); fr.abNote:SetJustifyH("LEFT")
  -- explains which Invite controls are greyed and why, for the current Mode
  fr.modeNote = fr:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  fr.modeNote:SetPoint("TOPLEFT", 298, -288); fr.modeNote:SetWidth(240); fr.modeNote:SetHeight(40); fr.modeNote:SetJustifyH("LEFT"); fr.modeNote:SetJustifyV("TOP")

  fr.collectCheck = MakeCheck(fr, "GuildRecruiterConfigCollect", "Collect only (build a list, don't contact)", 298, -332, "collectOnly")
  local cnote = fr:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  cnote:SetPoint("TOPLEFT", 320, -356); cnote:SetWidth(218); cnote:SetJustifyH("LEFT")
  cnote:SetText("Scanning fills a saved list. Send it from the Lists tab.")

  -- RUN (spans full width) ------------------------------------------------
  Header(fr, "Controls", 18, -378, 524)
  fr.status = fr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fr.status:SetPoint("TOPLEFT", 24, -396); fr.status:SetWidth(512); fr.status:SetJustifyH("LEFT")

  fr.bar = CreateFrame("StatusBar", nil, fr)
  fr.bar:SetPoint("TOPLEFT", 24, -414); fr.bar:SetWidth(512); fr.bar:SetHeight(14)
  fr.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  fr.bar:SetStatusBarColor(0.2, 0.8, 0.3)
  fr.bar:SetMinMaxValues(0, 1); fr.bar:SetValue(0)
  local barbg = fr.bar:CreateTexture(nil, "BACKGROUND")
  barbg:SetAllPoints(fr.bar); GR_Compat.ColorTexture(barbg, 0, 0, 0, 0.4)
  fr.barText = fr.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fr.barText:SetPoint("CENTER", fr.bar, "CENTER", 0, 0)   -- says what the bar means (scan vs drain)

  -- start / pause / stop (pause label flips to Resume while paused)
  local startBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  startBtn:SetPoint("BOTTOMLEFT", 22, 16); startBtn:SetWidth(100); startBtn:SetHeight(22)
  startBtn:SetText("Start"); startBtn:SetScript("OnClick", function() Start() end)
  local pauseBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  pauseBtn:SetPoint("LEFT", startBtn, "RIGHT", 7, 0); pauseBtn:SetWidth(100); pauseBtn:SetHeight(22)
  pauseBtn:SetText("Pause"); pauseBtn:SetScript("OnClick", function() if paused then Resume() else Pause() end end)
  local stopBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  stopBtn:SetPoint("LEFT", pauseBtn, "RIGHT", 7, 0); stopBtn:SetWidth(100); stopBtn:SetHeight(22)
  stopBtn:SetText("Stop"); stopBtn:SetScript("OnClick", function() Stop() end)
  fr.pauseBtn = pauseBtn

  -- Auto-rescan (loop) toggle + rest interval, sharing the run-button baseline so
  -- it reads as a run modifier and disturbs no other layout. SetAutoScanDelay is a
  -- global => the box's applyFn adds no upvalue to this near-limit function.
  fr.autoScanCheck = MakeCheck(fr, "GuildRecruiterConfigAutoScan", "Auto-rescan", 0, 0, "autoScan")
  fr.autoScanCheck:ClearAllPoints()
  fr.autoScanCheck:SetPoint("BOTTOMLEFT", fr, "BOTTOMLEFT", 344, 15)
  fr.autoScanCheck:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Auto-rescan")
    GameTooltip:AddLine("Keep scanning: after a full /who sweep finishes, rest for the gap and sweep again, catching players who log in later. Runs until you press Stop.", 1, 1, 1, 1)
    GameTooltip:AddLine("Gap: "..(GuildRecruiter_Settings.autoScanDelay or 60).."s  (edit the box, or /gr autoscan <seconds>)", 0.6, 0.8, 1, 1)
    GameTooltip:Show()
  end)
  fr.autoScanCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
  fr.autoScanEdit = MakeNumBox(fr, "GuildRecruiterConfigAutoDelay", 0, 0, 34, 3, GuildRecruiter_SetAutoScanDelay)
  fr.autoScanEdit:ClearAllPoints()
  fr.autoScanEdit:SetPoint("LEFT", fr.autoScanCheck, "RIGHT", 100, 1)
  local asLbl = Label(fr, "s gap", 0, 0)
  asLbl:ClearAllPoints()
  asLbl:SetPoint("LEFT", fr.autoScanEdit, "RIGHT", 4, 0)

  -- throttled live refresh of the status line + bar
  fr.tick = 0
  fr:SetScript("OnUpdate", function(self, elapsed)
    fr.tick = fr.tick - (elapsed or 0)
    if fr.tick > 0 then return end
    fr.tick = 0.3
    fr.status:SetText(StatusLine())
    fr.pauseBtn:SetText(paused and "Resume" or "Pause")
    local span = myHi - myLo + 1
    local prog = 1
    if running and scanning and span > 0 then prog = clamp((lo - myLo) / span, 0, 1) end
    if not running or (GuildRecruiter_rescanWait or 0) > 0 then prog = 0 end
    fr.bar:SetValue(prog)
    -- label the bar so a full bar during the (long) drain phase isn't read as "done"
    if not running then fr.barText:SetText("")
    elseif (GuildRecruiter_rescanWait or 0) > 0 then fr.barText:SetText("Rescanning in "..math.ceil(GuildRecruiter_rescanWait).."s")
    elseif scanning and GuildRecruiter_Settings.collectOnly then fr.barText:SetText("Collecting "..math.floor(prog * 100 + 0.5).."%   /who "..GuildRecruiter_ScanNow())
    elseif scanning then fr.barText:SetText("Scanning "..math.floor(prog * 100 + 0.5).."%   /who "..GuildRecruiter_ScanNow())
    else fr.barText:SetText("Sending queued contacts ("..#contactQueue.." left)") end
  end)

  configFrame = fr
  return fr
end

-- ---------------------------------------------------------------------------
-- Profiles (swappable named setting snapshots; persisted in SavedVariables)
-- ---------------------------------------------------------------------------
local function CopyValue(v)
  if type(v) == "table" then
    local c = {}
    for k, x in pairs(v) do c[k] = CopyValue(x) end
    return c
  end
  return v
end

local function SaveProfile(name)
  if not name or name == "" then return false end
  GuildRecruiter_Settings.profiles = GuildRecruiter_Settings.profiles or {}
  local p = {}
  for i = 1, #PROFILE_KEYS do
    local k = PROFILE_KEYS[i]
    p[k] = CopyValue(GuildRecruiter_Settings[k])
  end
  GuildRecruiter_Settings.profiles[name] = p
  GuildRecruiter_Settings.activeProfile = name
  return true
end

local function LoadProfile(name)
  local prof = GuildRecruiter_Settings.profiles and GuildRecruiter_Settings.profiles[name]
  if not prof then return false end
  for i = 1, #PROFILE_KEYS do
    local k = PROFILE_KEYS[i]
    if prof[k] ~= nil then GuildRecruiter_Settings[k] = CopyValue(prof[k]) end
  end
  GuildRecruiter_Settings.activeProfile = name
  RecomputeBand(); RefreshConfig()
  return true
end

local function DeleteProfile(name)
  if GuildRecruiter_Settings.profiles then GuildRecruiter_Settings.profiles[name] = nil end
  if GuildRecruiter_Settings.activeProfile == name then GuildRecruiter_Settings.activeProfile = nil end
end

-- ---------------------------------------------------------------------------
-- Stats & Profiles window
-- ---------------------------------------------------------------------------
local statsFrame
local function Rate(j, d)
  local t = j + d
  if t <= 0 then return "--" end
  return math.floor(j / t * 100 + 0.5) .. "%"
end


local function BuildStatsPanel(parent)
  local fr = CreateFrame("Frame", "GuildRecruiterStats", parent)
  fr:SetAllPoints(parent)

  Header(fr, "Profiles", 18, -40, 524)
  local plabel = fr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  plabel:SetPoint("TOPLEFT", 18, -64); plabel:SetText("Name:")
  local pedit = CreateFrame("EditBox", "GuildRecruiterStatsProfile", fr, "InputBoxTemplate")
  pedit:SetPoint("TOPLEFT", 70, -60); pedit:SetWidth(150); pedit:SetHeight(20)
  pedit:SetAutoFocus(false); pedit:SetMaxLetters(24)
  pedit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local saveB = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  saveB:SetPoint("TOPLEFT", 18, -86); saveB:SetWidth(80); saveB:SetHeight(22); saveB:SetText("Save")
  local loadB = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  loadB:SetPoint("LEFT", saveB, "RIGHT", 6, 0); loadB:SetWidth(80); loadB:SetHeight(22); loadB:SetText("Load")
  local delB = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  delB:SetPoint("LEFT", loadB, "RIGHT", 6, 0); delB:SetWidth(80); delB:SetHeight(22); delB:SetText("Delete")
  saveB:SetScript("OnClick", function() if SaveProfile(pedit:GetText()) then RefreshStats() end end)
  loadB:SetScript("OnClick", function() if LoadProfile(pedit:GetText()) then RefreshStats() end end)
  delB:SetScript("OnClick", function()
    local nm = pedit:GetText()
    if not nm or nm == "" or not (GuildRecruiter_Settings.profiles and GuildRecruiter_Settings.profiles[nm]) then
      Print("No saved profile '"..(nm or "").."' to delete."); return
    end
    GuildRecruiter_Confirm("Delete profile |cffffffff"..nm.."|r? This can't be undone.",
      function() DeleteProfile(nm); RefreshStats(); Print("Deleted profile '"..nm.."'.") end)
  end)

  fr.profileText = fr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fr.profileText:SetPoint("TOPLEFT", 18, -114); fr.profileText:SetWidth(524); fr.profileText:SetJustifyH("LEFT")

  Header(fr, "Statistics", 18, -152, 524)
  fr.text = fr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fr.text:SetPoint("TOPLEFT", 18, -172); fr.text:SetWidth(524); fr.text:SetJustifyH("LEFT")

  local resetB = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  resetB:SetPoint("BOTTOMRIGHT", -16, 16); resetB:SetWidth(110); resetB:SetHeight(22); resetB:SetText("Reset stats")
  resetB:SetScript("OnClick", function()
    GuildRecruiter_Confirm("Reset ALL stats? This wipes lifetime tallies and every variant's A/B conversion data. Can't be undone.",
      function()
        GuildRecruiter_Settings.tally = { totals = { invited=0, whispered=0, joined=0, declined=0 }, days = {} }
        GuildRecruiter_Settings.varStats = {}
        RefreshStats()
      end)
  end)

  fr.tick = 0
  fr:SetScript("OnUpdate", function(self, elapsed)
    fr.tick = fr.tick - (elapsed or 0)
    if fr.tick > 0 then return end
    fr.tick = 1.0
    RefreshStats()
  end)

  statsFrame = fr
  return fr
end

RefreshStats = function()
  if not statsFrame then return end
  local t = GuildRecruiter_Settings.tally
  if not t or not t.totals then return end   -- guard: stats panel can tick before Defaults()
  local tot = t.totals
  local lines = {}
  tinsert(lines, "|cffffd100Lifetime|r")
  tinsert(lines, "Invited "..tot.invited.."    Whispered "..tot.whispered)
  tinsert(lines, "Joined "..tot.joined.."    Declined "..tot.declined.."    Join rate "..Rate(tot.joined, tot.declined))
  tinsert(lines, " ")
  tinsert(lines, "|cffffd100Recent days|r")
  local keys = {}
  for d in pairs(t.days) do tinsert(keys, d) end
  table.sort(keys)
  local n = #keys
  if n == 0 then tinsert(lines, "(no activity yet)") end
  local first = n - 2; if first < 1 then first = 1 end
  for i = first, n do
    local d = keys[i]; local r = t.days[d]
    local label = d
    if string.len(d) == 8 then label = string.sub(d, 5, 6).."/"..string.sub(d, 7, 8) end
    tinsert(lines, label..":  inv "..(r.invited or 0)..", wsp "..(r.whispered or 0)
                 ..", join "..(r.joined or 0)..", dec "..(r.declined or 0)
                 .."  ("..Rate(r.joined or 0, r.declined or 0)..")")
  end

  -- per-profile conversion comparison (for A/B): conv = joined / contacted
  local s = GuildRecruiter_Settings
  tinsert(lines, " ")
  tinsert(lines, "|cffffd100By variant / profile|r   A/B test: "..(GuildRecruiter_ABActive() and "|cff40ff40ON|r" or "off")
               .."  (A + "..#(s.abVariants or {}).." variant(s), * = active)")
  -- names currently in the live A/B test: "A" (control) + each challenger
  local active = {}
  if GuildRecruiter_ABActive() then
    active["A"] = true
    for j = 1, #s.abVariants do active[s.abVariants[j].name] = true end
  end
  local vs = s.varStats or {}
  local vnames = {}
  for v in pairs(vs) do tinsert(vnames, v) end
  table.sort(vnames)
  if #vnames == 0 then
    tinsert(lines, "no per-variant data yet -- run an A/B test (A/B tab) or load profiles, then recruit")
  else
    for i = 1, #vnames do
      if i > 6 then tinsert(lines, "(+"..(#vnames - 6).." more)"); break end
      local v = vnames[i]; local r = vs[v]
      local c = r.contacted or 0
      local conv = (c > 0) and (math.floor((r.joined or 0) / c * 100 + 0.5).."%") or "--"
      local flag = active[v] and " |cff40ff40*|r" or ""
      tinsert(lines, v..flag..":  contacted "..c..", joined "..(r.joined or 0)
                   ..", declined "..(r.declined or 0).."  (conv "..conv..")")
    end
  end
  statsFrame.text:SetText(table.concat(lines, "\n"))

  local pnames = {}
  if GuildRecruiter_Settings.profiles then
    for nm in pairs(GuildRecruiter_Settings.profiles) do tinsert(pnames, nm) end
  end
  table.sort(pnames)
  statsFrame.profileText:SetText("Active profile: |cff33ff99"..(GuildRecruiter_Settings.activeProfile or "(unsaved)")
    .."|r\nSaved: "..(#pnames > 0 and table.concat(pnames, ", ") or "(none)"))
end

-- ---------------------------------------------------------------------------
-- A/B tab: variant A is the live Settings tab (the control); this tab adds the
-- challengers (B/C/D) to test against it. Up to AB_MAX variants total = 1 + 3.
-- ---------------------------------------------------------------------------
local abFrame
local AB_MAX = 4                 -- A + 3 challengers
local MAX_CHAL = AB_MAX - 1

-- compact per-variant conversion (joined / that variant's own contacted). This
-- is the FAIR A/B metric -- it's a rate, so a variant shown less often (lower
-- weight) is not penalised vs one shown more.
local function ConvBlurb(name)
  local vs = GuildRecruiter_Settings.varStats and GuildRecruiter_Settings.varStats[name]
  local c = (vs and vs.contacted) or 0
  local conv = (c > 0) and (math.floor(((vs.joined or 0) / c) * 100 + 0.5).."%") or "--"
  return "|cff40ff40"..conv.."|r conv  ("..((vs and vs.joined) or 0).."/"..c..")"
end

-- a variant's share of the contact stream given its weight and the pool total
local function WeightPct(w, total)
  if total <= 0 then return "--" end
  return math.floor(w / total * 100 + 0.5).."%"
end

-- short, truncated preview of a message kept to a single line (blank shows a hint).
-- maxlen is tuned to the FontString width so it never wraps onto a second line.
local function MsgPreview(msg, blankHint, maxlen)
  maxlen = maxlen or 56
  if not msg or msg == "" then return "|cff808080"..(blankHint or "(empty)").."|r" end
  if string.len(msg) > maxlen then msg = string.sub(msg, 1, maxlen - 2).."..." end
  return "|cffd0d0d0"..msg.."|r"
end

local function BuildABPanel(parent)
  local fr = CreateFrame("Frame", "GuildRecruiterAB", parent)
  fr:SetAllPoints(parent)

  Header(fr, "A/B test", 18, -40, 524)
  fr.toggle = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.toggle:SetPoint("TOPLEFT", 18, -62); fr.toggle:SetWidth(150); fr.toggle:SetHeight(22)
  fr.toggle:SetScript("OnClick", function()
    GuildRecruiter_Settings.abOn = not GuildRecruiter_Settings.abOn; GuildRecruiter_RefreshOpen()
  end)
  fr.addBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.addBtn:SetPoint("LEFT", fr.toggle, "RIGHT", 8, 0); fr.addBtn:SetWidth(120); fr.addBtn:SetHeight(22); fr.addBtn:SetText("+ Add variant")
  fr.addBtn:SetScript("OnClick", function()
    local av = GuildRecruiter_Settings.abVariants
    if #av >= MAX_CHAL then return end
    local s = GuildRecruiter_Settings
    local used = {}
    for i = 1, #av do used[av[i].name] = true end
    local letter                          -- first free challenger letter B/C/D
    for i = 1, MAX_CHAL do local c = string.sub("BCD", i, i); if not used[c] then letter = c; break end end
    -- seeded from A (live) so a new challenger starts identical, then you tweak
    tinsert(av, { name = letter, mode = s.mode, whisperMsg = s.whisperMsg, inviteMethod = s.inviteMethod, replyMode = s.replyMode })
    RefreshABPanel()
  end)
  fr.hint = fr:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  fr.hint:SetPoint("TOPLEFT", 18, -90); fr.hint:SetWidth(524); fr.hint:SetJustifyH("LEFT")

  -- control row (variant A = the Settings tab), read-only here except its weight
  local cr = CreateFrame("Frame", nil, fr)
  cr:SetPoint("TOPLEFT", 16, -122); cr:SetPoint("RIGHT", fr, "RIGHT", -16, 0); cr:SetHeight(44)
  cr.nameFS = cr:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  cr.nameFS:SetPoint("TOPLEFT", 2, 0); cr.nameFS:SetText("Variant A  |cff999999(control = Settings)|r")
  cr.convFS = cr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  cr.convFS:SetPoint("LEFT", cr.nameFS, "RIGHT", 12, 0)
  cr.editBtn = CreateFrame("Button", nil, cr, "UIPanelButtonTemplate")
  cr.editBtn:SetPoint("TOPRIGHT", 0, 0); cr.editBtn:SetWidth(110); cr.editBtn:SetHeight(20); cr.editBtn:SetText("Open Settings")
  cr.editBtn:SetScript("OnClick", function() GuildRecruiter_GotoSettings() end)
  cr.wtBtn = CreateFrame("Button", nil, cr, "UIPanelButtonTemplate")
  cr.wtBtn:SetPoint("TOPLEFT", 14, -22); cr.wtBtn:SetWidth(132); cr.wtBtn:SetHeight(20)
  cr.wtBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  cr.wtBtn:SetScript("OnClick", function(self, button) GuildRecruiter_BumpWeight(nil, button == "RightButton" and -1 or 1) end)
  cr.wtBtn:SetScript("OnEnter", function(self) GuildRecruiter_WeightTip(self) end)
  cr.wtBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  cr.msgFS = cr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  cr.msgFS:SetPoint("TOPLEFT", 154, -24); cr.msgFS:SetWidth(236); cr.msgFS:SetHeight(14); cr.msgFS:SetJustifyH("LEFT")
  fr.ctrl = cr

  fr.rows = {}
  for i = 1, MAX_CHAL do
    local row = CreateFrame("Frame", nil, fr)
    row:SetPoint("TOPLEFT", 16, -168 - (i - 1) * 72); row:SetPoint("RIGHT", fr, "RIGHT", -16, 0); row:SetHeight(64)
    local nm = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    nm:SetPoint("TOPLEFT", 2, 0); row.nameFS = nm
    local cv = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cv:SetPoint("LEFT", nm, "RIGHT", 12, 0); row.convFS = cv
    local rm = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rm:SetPoint("TOPRIGHT", 0, 0); rm:SetWidth(72); rm:SetHeight(20); rm:SetText("Remove"); rm.idx = i
    rm:SetScript("OnClick", function(self) tremove(GuildRecruiter_Settings.abVariants, self.idx); RefreshABPanel() end)
    local md = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    md:SetPoint("TOPLEFT", 14, -22); md:SetWidth(150); md:SetHeight(20)
    md:SetScript("OnClick", function(self) GuildRecruiter_OpenDD(self, "mode", self.variant) end)
    GuildRecruiter_DDArrow(md); row.modeBtn = md
    local rp = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rp:SetPoint("LEFT", md, "RIGHT", 8, 0); rp:SetWidth(150); rp:SetHeight(20)
    rp:SetScript("OnClick", function(self) GuildRecruiter_OpenDD(self, "reply", self.variant) end)
    GuildRecruiter_DDArrow(rp); row.replyBtn = rp
    local mb = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    mb:SetPoint("LEFT", rp, "RIGHT", 8, 0); mb:SetWidth(140); mb:SetHeight(20); mb:SetText("Edit message...")
    mb:SetScript("OnClick", function(self) GuildRecruiter_EditMessage(self.variant) end)
    row.msgBtn = mb
    local wb = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    wb:SetPoint("TOPLEFT", 16, -46); wb:SetWidth(132); wb:SetHeight(20)
    wb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    wb:SetScript("OnClick", function(self, button) GuildRecruiter_BumpWeight(self.variant, button == "RightButton" and -1 or 1) end)
    wb:SetScript("OnEnter", function(self) GuildRecruiter_WeightTip(self) end)
    wb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.wtBtn = wb
    row.msgFS = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.msgFS:SetPoint("TOPLEFT", 156, -48); row.msgFS:SetWidth(350); row.msgFS:SetHeight(14); row.msgFS:SetJustifyH("LEFT")
    row:Hide()
    fr.rows[i] = row
  end

  abFrame = fr
  return fr
end

RefreshABPanel = function()
  if not abFrame then return end
  local s = GuildRecruiter_Settings
  local av = s.abVariants
  local n = #av               -- challenger count
  if not s.abOn then abFrame.toggle:SetText("A/B: Off")
  elseif n < 1 then abFrame.toggle:SetText("A/B: |cffffcc00On (inactive)|r")   -- on, but no variant to split = no-op
  else abFrame.toggle:SetText("A/B: |cff40ff40Running|r") end
  if s.abOn and n < 1 then
    abFrame.hint:SetText("A/B is on but has no other variant yet -- it won't do anything until you click '+ Add variant' to test one against A (your Settings).")
  else
    abFrame.hint:SetText("Each contact is dealt a variant by Weight (left-click +, right-click -). Blank variant fields inherit A. Compare the green conv% -- it's a rate, so weight doesn't skew it.")
  end
  if n >= MAX_CHAL then abFrame.addBtn:Disable() else abFrame.addBtn:Enable() end

  local wA = s.abWeightA or 1
  local totalW = wA
  for i = 1, n do totalW = totalW + (av[i].weight or 1) end

  abFrame.ctrl.convFS:SetText(ConvBlurb("A"))
  abFrame.ctrl.msgFS:SetText(MsgPreview(s.whisperMsg, "(no message)", 40))
  abFrame.ctrl.wtBtn:SetText("Weight "..wA.."  ("..WeightPct(wA, totalW)..")")

  for i = 1, MAX_CHAL do
    local row = abFrame.rows[i]
    if i <= n then
      local v = av[i]
      local w = v.weight or 1
      row.nameFS:SetText("Variant "..(v.name or "?"))
      row.convFS:SetText(ConvBlurb(v.name))
      row.modeBtn.variant = v;  row.modeBtn:SetText(MODE_LABEL[v.mode or s.mode] or "?")
      row.replyBtn.variant = v; row.replyBtn:SetText(REPLY_LABEL[v.replyMode or s.replyMode] or "?")
      row.msgBtn.variant = v
      row.wtBtn.variant = v;    row.wtBtn:SetText("Weight "..w.."  ("..WeightPct(w, totalW)..")")
      row.msgFS:SetText(MsgPreview(v.whisperMsg, "(same message as A)", 56))
      row:Show()
    else
      row:Hide()
    end
  end
end

-- ---------------------------------------------------------------------------
-- Main tabbed window (Settings / Lists / Stats / A/B) -- one frame, four panels
-- ---------------------------------------------------------------------------
local UI
local activeTab = "settings"
local tabPanels = {}
local tabButtons = {}
local TAB_DEFS = { { "settings", "Settings" }, { "lists", "Lists" }, { "stats", "Stats" }, { "ab", "A/B" } }

local function ShowTab(name)
  activeTab = name
  if ddPopup then ddPopup:Hide() end   -- don't leave a dropdown list floating across tabs
  for n, p in pairs(tabPanels) do if n == name then p:Show() else p:Hide() end end
  for n, b in pairs(tabButtons) do
    if n == name then b:LockHighlight() else b:UnlockHighlight() end
  end
  if name == "settings" then RefreshConfig()
  elseif name == "lists" then UpdateList()
  elseif name == "stats" then RefreshStats()
  elseif name == "ab" then RefreshABPanel() end
end

local function BuildUI()
  local m = GR_Compat.BackdropFrame("Frame", "GuildRecruiterUI", UIParent)
  m:SetWidth(560); m:SetHeight(470)
  m:SetPoint("CENTER", 0, 0)
  m:SetFrameStrata("DIALOG")
  GR_Compat.SetBackdrop(m, {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  m:EnableMouse(true); m:SetMovable(true); m:RegisterForDrag("LeftButton")
  m:SetScript("OnDragStart", function(self) self:StartMoving() end)
  m:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  m:SetScript("OnHide", function() if ddPopup then ddPopup:Hide() end end)  -- no orphan dropdown
  m:SetScript("OnUpdate", function(self, elapsed) GuildRecruiter_HeaderTick(self, elapsed) end)  -- run state on every tab
  tinsert(UISpecialFrames, "GuildRecruiterUI")   -- Escape closes the window (house rule)
  m:Hide()

  local title = m:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", 0, -16); title:SetText("Guild Rawcruiter  v"..VERSION)
  local close = CreateFrame("Button", nil, m, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  -- header run-state + Stop, visible on every tab during an active run
  m.runStatus = m:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  m.runStatus:SetPoint("TOPLEFT", 16, -16)
  m.stopBtn = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
  m.stopBtn:SetPoint("RIGHT", close, "LEFT", -2, 0); m.stopBtn:SetWidth(64); m.stopBtn:SetHeight(20); m.stopBtn:SetText("|cffff6060Stop|r")
  m.stopBtn:SetScript("OnClick", function() GuildRecruiter_StopRun() end)
  m.stopBtn:Hide()
  m.pauseBtn = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
  m.pauseBtn:SetPoint("RIGHT", m.stopBtn, "LEFT", -4, 0); m.pauseBtn:SetWidth(74); m.pauseBtn:SetHeight(20); m.pauseBtn:SetText("Pause")
  m.pauseBtn:SetScript("OnClick", function() GuildRecruiter_TogglePause() end)
  m.pauseBtn:Hide()

  tabPanels.settings = BuildSettingsPanel(m)
  tabPanels.lists    = BuildListsPanel(m)
  tabPanels.stats    = BuildStatsPanel(m)
  tabPanels.ab       = BuildABPanel(m)

  -- tabs hang just below the frame
  local prev
  for i = 1, #TAB_DEFS do
    local id, label = TAB_DEFS[i][1], TAB_DEFS[i][2]
    local b = CreateFrame("Button", "GuildRecruiterUITab"..i, m, "UIPanelButtonTemplate")
    b:SetWidth(106); b:SetHeight(24)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0)
    else b:SetPoint("TOPLEFT", m, "BOTTOMLEFT", 12, 2) end
    b:SetText(label)
    b:SetScript("OnClick", function() ShowTab(id) end)
    tabButtons[id] = b
    prev = b
  end

  UI = m
end

local function OpenTab(tab)
  Defaults()
  if not UI then BuildUI() end
  if UI:IsVisible() and activeTab == tab then
    UI:Hide()
  else
    ShowTab(tab); UI:Show()
  end
end

-- the three slash entry points now just open the relevant tab of the one window
local function ToggleConfig() OpenTab("settings") end
local function ToggleList()   OpenTab("lists") end
function GuildRecruiter_ToggleStats() OpenTab("stats") end
function GuildRecruiter_ToggleAB() OpenTab("ab") end
function GuildRecruiter_GotoSettings() OpenTab("settings") end  -- A/B control row -> Settings

-- ---------------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------------
-- Build the minimap tooltip. GLOBAL so both OnEnter and the live-refresh OnUpdate
-- can call it, and so it adds no upvalue to InitMinimap. Reads module state
-- directly, so it's accurate whether or not the config window is open.
function GuildRecruiter_MinimapTip(btn)
  local s = GuildRecruiter_Settings
  GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
  GameTooltip:AddLine("Guild Rawcruiter")
  if not running then
    GameTooltip:AddLine("Idle", 0.7, 0.7, 0.7)
  elseif paused then
    GameTooltip:AddLine("Paused", 1, 0.6, 0.2)
    GameTooltip:AddLine(StatusLine(), 1, 1, 1)
  else
    GameTooltip:AddLine("Running", 0.3, 1, 0.3)
    GameTooltip:AddLine(StatusLine(), 1, 1, 1)
  end
  GameTooltip:AddLine("Auto-rescan: "..(s.autoScan and ("on -- every "..(s.autoScanDelay or 60).."s") or "off"), 0.6, 0.8, 1)
  local hw = GR_Compat.RequiresHardwareEvent
  if hw and running then GameTooltip:AddLine("Next: "..GuildRecruiter_NextLabel(), 1, 0.82, 0) end
  local nr = GuildRecruiter_ReadyCount()
  if nr > 0 then GameTooltip:AddLine("Ready to invite: "..nr.."  (/gr ready)", 0.3, 1, 0.3) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
  GameTooltip:AddLine("Right-click: "..(running and "stop" or (hw and "arm (then press Next per /who or invite)" or "start")), 1, 1, 1)
  GameTooltip:Show()
end

local minimapBtn
local function MinimapUpdatePos()
  if not minimapBtn then return end
  local a = math.rad(GuildRecruiter_Settings.minimapAngle or 210)
  minimapBtn:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
  -- the secure Next button is anchored to UIParent, not to this button: re-place it
  local nb = GuildRecruiterNextButton
  if nb and nb:IsShown() then GuildRecruiter_PlaceNext(nb) end   -- does nothing in combat
end

InitMinimap = function()
  if minimapBtn or not Minimap then return end
  local mb = CreateFrame("Button", "GuildRecruiterMinimapButton", Minimap)
  mb:SetWidth(31); mb:SetHeight(31); mb:SetFrameStrata("MEDIUM"); mb:SetFrameLevel(8)
  mb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mb:RegisterForDrag("LeftButton")

  local icon = mb:CreateTexture(nil, "BACKGROUND")
  icon:SetWidth(20); icon:SetHeight(20)
  icon:SetTexture("Interface\\Icons\\INV_Scroll_03")
  icon:SetPoint("CENTER", 0, 0)
  local border = mb:CreateTexture(nil, "OVERLAY")
  border:SetWidth(52); border:SetHeight(52)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT", 0, 0)

  mb:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      if running then Stop() else Start() end
    else
      ToggleConfig()
    end
  end)
  mb:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      mx, my = mx / scale, my / scale
      local cx, cy = Minimap:GetCenter()
      GuildRecruiter_Settings.minimapAngle = math.deg(math.atan2(my - cy, mx - cx))
      MinimapUpdatePos()
    end)
  end)
  mb:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  mb:SetScript("OnEnter", function(self)
    GuildRecruiter_MinimapTip(self)
    -- keep the tooltip live while hovering, so status updates in real time
    self.tipTick = 0
    self:SetScript("OnUpdate", function(btn, elapsed)
      btn.tipTick = (btn.tipTick or 0) + (elapsed or 0)
      if btn.tipTick < 0.3 then return end
      btn.tipTick = 0
      GuildRecruiter_MinimapTip(btn)   -- OnLeave clears this OnUpdate, so it only runs while hovered
    end)
  end)
  mb:SetScript("OnLeave", function(self)
    self:SetScript("OnUpdate", nil)
    GameTooltip:Hide()
  end)

  minimapBtn = mb
  MinimapUpdatePos()
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function HistoryCount() return CountTable(GuildRecruiter_Settings.history) end

local function Status()
  if running then
    Print((paused and "Paused" or "Running").." -- "..StatusLine())
    if GR_Compat.RequiresHardwareEvent then Print("Next: "..GuildRecruiter_NextLabel().."  ("..GuildRecruiter_PressHint()..")") end
  else
    Print("Idle. Last run: contacted "..stats.contacted.." ("..stats.invited.." inv, "..stats.whispered.." wsp), guilded-skipped "..stats.guilded..".")
  end
  Print("Mode "..(GuildRecruiter_Settings.mode).." | invite="..GuildRecruiter_Settings.inviteDelay.."s who="..GuildRecruiter_Settings.whoDelay.."s | jitter "..(GuildRecruiter_Settings.jitter and "on" or "off").." | sync "..(GuildRecruiter_Settings.guildSync and "on" or "off").." | history "..HistoryCount())
  GuildRecruiter_ReadyPrune()
  Print("Ready to invite: "..GuildRecruiter_ReadyCount().." (/gr ready; expire after "..(GuildRecruiter_Settings.readyTTL or 30).." min) | reply alert "..(GuildRecruiter_Settings.readyAlert and "on" or "off")
    ..". Invites are counted on Done or when the join message names them, not when prompted.")
end

SLASH_GUILDRECRUITER1 = "/gr"
SlashCmdList["GUILDRECRUITER"] = function(msg)
  Defaults()
  msg = msg or ""
  local _, _, cmd, arg = string.find(msg, "^%s*(%S+)%s*(.*)$")
  cmd = string.lower(cmd or "")
  local larg = string.lower(arg or "")

  if cmd == "start" then Start()
  elseif cmd == "stop" then Stop()
  elseif cmd == "pause" then Pause()
  elseif cmd == "resume" then Resume()
  elseif cmd == "next" then GuildRecruiter_Next()   -- typed: /who and whisper steps only (no secure click)
  elseif cmd == "status" then Status()
  elseif cmd == "ready" then GuildRecruiter_ReadyToggle()   -- the Ready-to-invite panel
  elseif cmd == "alert" then
    if larg == "on" or larg == "off" then GuildRecruiter_Settings.readyAlert = (larg == "on") end
    Print("Reply alert (sound + taskbar flash when a yes-reply lands on the Ready list): "..(GuildRecruiter_Settings.readyAlert and "ON" or "OFF")..".  /gr alert on|off")
  elseif cmd == "collect" then
    if larg == "on" or larg == "off" then GuildRecruiter_Settings.collectOnly = (larg == "on"); RefreshConfig() end
    Print("Collect-only "..(GuildRecruiter_Settings.collectOnly and "ON -- scans build a list (send with /gr send)" or "off -- scans contact immediately")..".")
  elseif cmd == "send" then
    GuildRecruiter_SendToCandidates(false)
  elseif cmd == "inviteall" then
    GuildRecruiter_SendToCandidates(true)
  elseif cmd == "invite" then
    if arg and arg ~= "" then GuildRecruiter_InviteOne(arg) else Print("Usage: /gr invite <name>") end
  elseif cmd == "candidates" then
    Print("Collected candidates: "..CountTable(GuildRecruiter_Settings.candidates)..".  (Lists tab to view, /gr send to invite, /gr clearlist to empty.)")
  elseif cmd == "clearlist" then
    local cnt = CountTable(GuildRecruiter_Settings.candidates)
    if cnt == 0 then Print("Candidate list is already empty.")
    else GuildRecruiter_Confirm("Clear the "..cnt.." collected candidate(s)?", function() GuildRecruiter_Settings.candidates = {}; GuildRecruiter_RefreshOpen(); if listFrame then UpdateList() end; Print("Cleared candidate list.") end) end
  elseif cmd == "config" or cmd == "options" or cmd == "gui" then ToggleConfig()
  elseif cmd == "list" or cmd == "lists" then ToggleList()
  elseif cmd == "stats" then GuildRecruiter_ToggleStats()
  elseif cmd == "profile" then
    local _, _, sub, pname = string.find(arg or "", "^(%a+)%s*(.*)$")
    sub = sub and string.lower(sub) or ""
    if sub == "save" and pname ~= "" then
      SaveProfile(pname); Print("Saved profile '"..pname.."'.")
    elseif sub == "load" and pname ~= "" then
      if LoadProfile(pname) then Print("Loaded profile '"..pname.."'.") else Print("No profile '"..pname.."'.") end
    elseif sub == "delete" and pname ~= "" then
      DeleteProfile(pname); Print("Deleted profile '"..pname.."'.")
    elseif sub == "list" then
      local names = ""
      if GuildRecruiter_Settings.profiles then for nm in pairs(GuildRecruiter_Settings.profiles) do names = names..nm..", " end end
      Print("Profiles: "..(names ~= "" and names or "(none)").."  -- active: "..(GuildRecruiter_Settings.activeProfile or "(unsaved)"))
    else
      Print("Usage: /gr profile save|load|delete <name> | profile list")
    end
  elseif cmd == "noword" then
    local _, _, sub, phrase = string.find(larg, "^(%a+)%s*(.*)$")
    if sub == "add" and phrase ~= "" then
      GuildRecruiter_Settings.negatives[phrase] = true; Print("Added refusal word '"..phrase.."' (replies with it are skipped).")
    elseif sub == "remove" and phrase ~= "" then
      GuildRecruiter_Settings.negatives[phrase] = nil; Print("Removed refusal word '"..phrase.."'.")
    elseif sub == "list" then
      local a = ""
      for p in pairs(GuildRecruiter_Settings.negatives) do a = a..p..", " end
      Print("Refusal words: "..a)
    else
      Print("Usage: /gr noword add|remove <phrase> | noword list")
    end
  elseif cmd == "yesword" then
    local _, _, sub, phrase = string.find(larg, "^(%a+)%s*(.*)$")
    if sub == "add" and phrase ~= "" then
      GuildRecruiter_Settings.affirmatives[phrase] = true; Print("Added yes word '"..phrase.."' (used by 'yesonly' reply mode).")
    elseif sub == "remove" and phrase ~= "" then
      GuildRecruiter_Settings.affirmatives[phrase] = nil; Print("Removed yes word '"..phrase.."'.")
    elseif sub == "list" then
      local a = ""
      for p in pairs(GuildRecruiter_Settings.affirmatives) do a = a..p..", " end
      Print("Yes words: "..a)
    else
      Print("Usage: /gr yesword add|remove <phrase> | yesword list")
    end
  elseif cmd == "replymode" then
    if REPLY_LABEL[larg] then
      GuildRecruiter_Settings.replyMode = larg; RefreshConfig()
      Print("Reply mode: "..larg.." ("..REPLY_LABEL[larg]..").")
    else
      Print("Usage: /gr replymode notno|yesonly|any  (current: "..(GuildRecruiter_Settings.replyMode or "notno")..")")
    end
  elseif cmd == "ab" then
    local sub = string.lower(larg or "")
    if sub == "on" or sub == "off" then
      GuildRecruiter_Settings.abOn = (sub == "on"); GuildRecruiter_RefreshOpen()
      Print("Simultaneous A/B "..(GuildRecruiter_Settings.abOn and "ON" or "OFF").."  (A + "..#GuildRecruiter_Settings.abVariants.." variant(s)).")
    elseif sub == "clear" then
      GuildRecruiter_Settings.abVariants = {}; GuildRecruiter_RefreshOpen(); Print("A/B variants cleared (variant A = your Settings is unaffected).")
    else
      GuildRecruiter_ToggleAB()   -- open the A/B tab to set variants up
    end
  elseif cmd == "reset" then
    seen = {}; contactQueue = {}; replyQueue = {}   -- clear queues too, or a mid-run reset re-queues re-found players
    GuildRecruiter_dealt = nil
    Print("Cleared this session's scan list and queues (history kept).")
  elseif cmd == "debug" then
    GuildRecruiter_Settings.debug = (larg == "on") or (larg ~= "off" and not GuildRecruiter_Settings.debug)
    Print("Scan debug: "..(GuildRecruiter_Settings.debug and "ON (prints each /who's result count + learned cap)" or "OFF"))
  elseif cmd == "dataset" then
    local d = GuildRecruiter_Settings.dataset or {}
    local total = CountTable(d)
    if larg == "clear" then
      GuildRecruiter_Confirm("Clear the name dataset of "..total.." player(s)?",
        function() GuildRecruiter_Settings.dataset = {}; Print("Cleared name dataset ("..total.." entries).") end)
    else
      local byRace, byClass = {}, {}
      for _, rec in pairs(d) do
        local r = rec.race or "?"
        local c = rec.class or "?"
        byRace[r]  = (byRace[r]  or 0) + 1
        byClass[c] = (byClass[c] or 0) + 1
      end
      Print("Name dataset: "..total.." unique player(s) captured from /who (name/race/class/level).")
      local rl = ""; for r, n in pairs(byRace)  do rl = rl..r.."="..n.."  " end
      local cl = ""; for c, n in pairs(byClass) do cl = cl..c.."="..n.."  " end
      if rl ~= "" then Print("  by race:  "..rl) end
      if cl ~= "" then Print("  by class: "..cl) end
      Print("  Grows during scans; saved on logout/reload. '/gr dataset clear' to reset.")
    end
  elseif cmd == "forget" then
    local cnt = CountTable(GuildRecruiter_Settings.history or {})
    if cnt == 0 then Print("Invite history is already empty.")
    else
      GuildRecruiter_Confirm("Clear invite history of "..cnt.." player(s)? They'll become eligible to contact again.",
        function() GuildRecruiter_Settings.history = {}; Print("Cleared persistent invite history ("..cnt.." entries).") end)
    end
  elseif cmd == "hide" then
    GuildRecruiter_Settings.hideWho = not GuildRecruiter_Settings.hideWho
    if running and not paused then
      if GuildRecruiter_Settings.hideWho then SuppressWho(true) else SuppressWho(false) end
    end
    Print("Suppress Who window during scans: "..(GuildRecruiter_Settings.hideWho and "ON" or "OFF"))
  elseif cmd == "msg" then
    if arg and arg ~= "" then GuildRecruiter_Settings.whisperMsg = arg; RefreshConfig(); Print("Whisper message set.")
    else Print("Current whisper: "..(GuildRecruiter_Settings.whisperMsg or "")) end
  elseif cmd == "black" then
    local _, _, sub, who = string.find(larg, "^(%a+)%s*(.*)$")
    if sub == "add" and who and who ~= "" then
      GuildRecruiter_Settings.blacklist[who] = true; Print("Blacklisted "..who..".")
    elseif sub == "remove" and who and who ~= "" then
      GuildRecruiter_Settings.blacklist[who] = nil; Print("Un-blacklisted "..who..".")
    elseif sub == "list" then
      local names = ""
      for n in pairs(GuildRecruiter_Settings.blacklist) do names = names..n..", " end
      Print("Blacklist: "..(names ~= "" and names or "(empty)"))
    else
      Print("Usage: /gr black add <name> | black remove <name> | black list")
    end
  elseif cmd == "class" then
    if larg == "all" or larg == "" then
      GuildRecruiter_Settings.classFilter = nil; Print("Class filter cleared (all classes).")
    else
      local cf = {}
      for c in string.gmatch(larg, "[^%s,]+") do cf[c] = true end
      GuildRecruiter_Settings.classFilter = cf; Print("Class filter set: "..larg)
    end
  elseif cmd == "set" then
    local _, _, which, rest = string.find(larg, "^(%a+)%s+(%S+)$")
    local val = tonumber(rest)
    if val then val = math.floor(val) end   -- whole numbers only; drop decimals
    if which == "invite" and val and val >= 1 then
      val = clamp(val, 1, 600); GuildRecruiter_Settings.inviteDelay = val; RefreshConfig(); Print("Invite delay "..val.."s.")
    elseif which == "who" and val and val >= 1 then
      val = clamp(val, 1, 600); GuildRecruiter_Settings.whoDelay = val; RefreshConfig(); Print("Who delay "..val.."s.")
    elseif which == "reinvite" and val then
      val = clamp(val, 0, 3650); GuildRecruiter_Settings.reinviteDays = val; Print("Re-invite cooldown "..val.." day(s).")
    elseif which == "cap" and val then
      val = clamp(val, 0, 9999); GuildRecruiter_Settings.sessionCap = val; RefreshConfig(); Print("Session cap "..(val == 0 and "off" or val)..".")
    elseif which == "min" and val then
      SetMinLevel(val); Print("Levels "..GuildRecruiter_Settings.minLevel.."-"..GuildRecruiter_Settings.maxLevel..".")
    elseif which == "max" and val then
      SetMaxLevel(val); Print("Levels "..GuildRecruiter_Settings.minLevel.."-"..GuildRecruiter_Settings.maxLevel..".")
    elseif which == "method" and METHOD_LABEL[rest] then
      GuildRecruiter_Settings.inviteMethod = rest; RefreshConfig(); Print("Invite method: "..rest..".")
    elseif which == "mode" and MODE_LABEL[rest] then
      GuildRecruiter_Settings.mode = rest; RefreshConfig(); Print("Mode: "..MODE_LABEL[rest]..".")
    elseif which == "readyttl" and val and val >= 1 then
      val = clamp(val, 1, 1440); GuildRecruiter_Settings.readyTTL = val
      Print("Ready list entries expire after "..val.." min (no invite is recorded for them).")
    else
      Print("set invite|who|reinvite|cap|min|max <n> | set readyttl <minutes> | set method auto|byname|invite|chat | set mode invite|whisper|whisperinvite")
    end
  elseif cmd == "autoscan" then
    local n = tonumber(larg)
    if n then
      GuildRecruiter_SetAutoScanDelay(n)
      Print("Auto-rescan gap "..GuildRecruiter_Settings.autoScanDelay.."s"..(GuildRecruiter_Settings.autoScan and " (auto-rescan is ON)." or " (auto-rescan is off -- /gr autoscan on)."))
    else
      if larg == "on" then GuildRecruiter_Settings.autoScan = true
      elseif larg == "off" then GuildRecruiter_Settings.autoScan = false
      else GuildRecruiter_Settings.autoScan = not GuildRecruiter_Settings.autoScan end
      RefreshConfig()
      Print("Auto-rescan "..(GuildRecruiter_Settings.autoScan and ("ON -- loops scans every "..GuildRecruiter_Settings.autoScanDelay.."s until /gr stop") or "off")..".")
    end
  elseif cmd == "jitter" or cmd == "sync" or cmd == "combat" or cmd == "instance" or cmd == "quiet" then
    local keymap = { jitter="jitter", sync="guildSync", combat="skipCombat", instance="skipInstance", quiet="quietWho" }
    local key = keymap[cmd]
    GuildRecruiter_Settings[key] = (larg == "on") or (larg ~= "off" and not GuildRecruiter_Settings[key])
    if cmd == "sync" then RecomputeBand() end
    RefreshConfig()
    Print(cmd.." "..(GuildRecruiter_Settings[key] and "ON" or "OFF"))
  else
    Print("|cff33ff99Guild Rawcruiter v"..VERSION.."|r  --  /gr config, /gr list, /gr stats")
    Print("start | stop | pause | resume | status | reset | forget | hide")
    if GR_Compat.RequiresHardwareEvent then
      Print("next -- the next /who (one press each; whispers go out by themselves). Invite prompts need the Next button by the minimap, its key (Key Bindings > Guild Rawcruiter) or a macro with /click GuildRecruiterNextButton; not in combat")
      Print("ready -- the Ready list: yes-replies wait there for YOUR invite (Guild > Invite Member; shift-click the name in chat, or Copy + paste; then Done) | alert on|off | set readyttl <min>")
    end
    Print("autoscan on|off (loop scanning) | autoscan <seconds> (rest between cycles)")
    Print("collect on|off (scan into a list) | inviteall (fast) | send (paced) | invite <name> | candidates | clearlist")
    Print("set invite/who/reinvite/cap/min/max/method/mode <v> | msg <text> | class <list|all>")
    Print("profile save/load/delete/list <name> | replymode notno/yesonly/any | ab (open tab) /on/off/clear")
    Print("noword/yesword add/remove/list <phrase>")
    Print("black add/remove/list <name> | jitter/sync/combat/instance/quiet [on|off]")
  end
end

-- (init happens on VARIABLES_LOADED, once SavedVariables are actually loaded)
