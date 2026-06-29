--[[ Guild Recruiter -- vanilla 1.12

  Scans online players with /who and sends paced guild invites to players who
  are NOT already in a guild.

  Coverage is the hard part: /who returns at most ~49 results per query and is
  server-throttled. So instead of blindly querying fixed level brackets, we
  ADAPTIVELY SUBDIVIDE: query a wide slice, and only if it comes back at the cap
  (i.e. truncated) do we split it finer --
      level range -> two halves -> single level -> by class -> by race
  A slice that returns under the cap was fully captured in that one query, so we
  never waste queries on sparse parts of the population.

  /who is faction-locked in 1.12, so we only enumerate our own faction's classes
  and races (and guild invites are same-faction anyway). The `seen` set means
  overlapping slices never double-invite anyone.

  Slash:  /gr start | stop | status | reset | set invite <sec> | set who <sec>
]]--

GuildRecruiter_Settings = GuildRecruiter_Settings or {}

local CAP_HINT   = 49      -- treat a query returning >= this many as truncated
local START_WIDTH = 10     -- initial level-band width to try
local WHO_TIMEOUT = 12     -- give up waiting on a reply after this many seconds

-- config-GUI slider ranges and invite-method options
local INVITE_MIN, INVITE_MAX = 1, 10
local WHO_MIN,    WHO_MAX    = 1, 15
local METHOD_ORDER = { "auto", "byname", "invite", "chat" }
local METHOD_LABEL = {
  auto   = "Auto (best available)",
  byname = "GuildInviteByName()",
  invite = "GuildInvite()",
  chat   = "/ginvite (chat command)",
}

local f = CreateFrame("Frame", "GuildRecruiterFrame")

local running   = false
local scanning  = false
local awaiting  = false
local lo        = 1        -- next uncovered level in the sweep
local width     = START_WIDTH
local pending   = {}       -- targeted class/race sub-queries for dense levels
local current   = nil      -- slice currently being queried
local queue     = {}       -- names pending an invite
local seen      = {}        -- names already queued/invited this run
local hideSoon  = false    -- close the Who window the frame after a query
local classes   = {}       -- our faction's class names
local races     = {}       -- our faction's race names

local whoTimer, inviteTimer, whoTimeout = 0, 0, 0
local stats = { invited = 0, guilded = 0, scanned = 0, queries = 0, dropped = 0, cooldown = 0 }

local function Defaults()
  local s = GuildRecruiter_Settings
  if not s.inviteDelay  then s.inviteDelay  = 1 end   -- Turtle: 1s is fast but safe
  if not s.whoDelay     then s.whoDelay     = 3 end   -- /who is still server-throttled; keep a small gap
  if not s.reinviteDays then s.reinviteDays = 14 end   -- 0 = never re-invite
  if not s.history      then s.history      = {} end   -- [name] = last invite time()
  if s.hideWho == nil   then s.hideWho      = true end  -- auto-close Who window while scanning
  if not s.inviteMethod then s.inviteMethod = "auto" end -- auto|byname|invite|chat
  -- prune entries past the cooldown so the saved table can't grow forever
  if s.reinviteDays > 0 then
    local cutoff = time() - s.reinviteDays * 86400
    for n, t in s.history do
      if t < cutoff then s.history[n] = nil end
    end
  end
end

-- have we invited this person recently enough to skip them?
local function RecentlyInvited(name)
  local h = GuildRecruiter_Settings.history
  if not h or not h[name] then return false end
  local days = GuildRecruiter_Settings.reinviteDays
  if days <= 0 then return true end                    -- never re-invite
  return (time() - h[name]) < days * 86400
end

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GuildRecruiter|r: "..msg)
end

-- run a chat slash command (e.g. "/ginvite Name") programmatically, for cores
-- that don't expose GuildInvite() to Lua
local function RunChatCommand(text)
  local eb = ChatFrameEditBox or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox)
  if not eb then return false end
  eb:SetText(text)
  if ChatEdit_SendText then
    ChatEdit_SendText(eb, 0)
  else
    local handler = eb:GetScript("OnEnterPressed")
    if handler then
      local prev = this           -- 1.12 scripts read the global `this`
      this = eb
      handler()
      this = prev
    end
  end
  eb:SetText("")
  return true
end

-- Invite a player by the configured method. "auto" (default) prefers
-- GuildInviteByName (Turtle WoW's canonical name-taking invite) because on some
-- cores the bare GuildInvite() invites your CURRENT TARGET rather than a name,
-- which would mis-invite during an unattended scan. The override lets you pin a
-- specific method if auto-detect picks the wrong one on your server.
local function DoGuildInvite(name)
  local m = GuildRecruiter_Settings.inviteMethod or "auto"
  if m == "byname" and type(GuildInviteByName) == "function" then
    GuildInviteByName(name)
  elseif m == "invite" and type(GuildInvite) == "function" then
    GuildInvite(name)
  elseif m == "chat" then
    RunChatCommand("/ginvite "..name)
  -- auto (or a forced method whose function is missing): best available
  elseif type(GuildInviteByName) == "function" then
    GuildInviteByName(name)
  elseif type(GuildInvite) == "function" then
    GuildInvite(name)
  else
    RunChatCommand("/ginvite "..name)
  end
end

-- halt the whole run (used when anything errors)
local function Abort(reason)
  running, scanning, awaiting = false, false, false
  Print("|cffff4040Stopped on error:|r "..tostring(reason))
end

-- build the /who filter string for a slice
local function BuildFilter(s)
  local parts = {}
  if s.lo == s.hi then
    tinsert(parts, "" .. s.lo)
  else
    tinsert(parts, s.lo .. "-" .. s.hi)
  end
  if s.class then tinsert(parts, 'c-"' .. s.class .. '"') end
  if s.race  then tinsert(parts, 'r-"' .. s.race  .. '"') end
  return table.concat(parts, " ")
end

-- pick the next slice to query: targeted sub-queries first, else sweep onward
local function NextQuery()
  if table.getn(pending) > 0 then
    current = tremove(pending, 1)
    return true
  end
  if lo <= 60 then
    local hi = lo + width - 1
    if hi > 60 then hi = 60 end
    current = { lo = lo, hi = hi, sweep = true }
    return true
  end
  return false
end

local function SendNextWho()
  if not NextQuery() then
    scanning = false
    Print("Scan complete: "..stats.queries.." queries, "..table.getn(queue).." left to invite.")
    return
  end
  awaiting = true
  whoTimeout = WHO_TIMEOUT
  stats.queries = stats.queries + 1
  SendWho(BuildFilter(current))
end

local function ProcessWho()
  local me = UnitName("player")
  local num = GetNumWhoResults()
  for i = 1, num do
    -- 1.12: name, guild, level, race, class, zone
    local name, guild = GetWhoInfo(i)
    if name then
      stats.scanned = stats.scanned + 1
      if name == me or seen[name] then
        -- skip (self / already handled this run)
      elseif guild and guild ~= "" then
        stats.guilded = stats.guilded + 1
        seen[name] = true
      elseif RecentlyInvited(name) then
        stats.cooldown = stats.cooldown + 1   -- invited recently in a prior run
        seen[name] = true
      else
        seen[name] = true
        tinsert(queue, name)
      end
    end
  end

  local capped = (num >= CAP_HINT)
  local c = current
  if c and c.sweep then
    if capped then
      if c.lo < c.hi then
        -- band truncated: narrow it and retry from the same level (no advance)
        width = floor((c.hi - c.lo + 1) / 2)
        if width < 1 then width = 1 end
      else
        -- a single level is dense: harvest done, split it by class, move on
        for i = 1, table.getn(classes) do
          tinsert(pending, { lo = c.lo, hi = c.lo, class = classes[i] })
        end
        lo = c.lo + 1
        width = 1
      end
    else
      -- band fully captured in one query: advance, and widen if it came back
      -- light so the next query fills closer to the cap
      lo = c.hi + 1
      if num < CAP_HINT * 0.6 then width = floor(width * 1.7) + 1 end
      local remain = 60 - lo + 1
      if width > remain then width = remain end
      if width < 1 then width = 1 end
    end
  elseif c and capped then
    -- a targeted class/race sub-query truncated: split class -> race, else drop
    if not c.race then
      for i = 1, table.getn(races) do
        tinsert(pending, { lo = c.lo, hi = c.hi, class = c.class, race = races[i] })
      end
    else
      stats.dropped = stats.dropped + 1
    end
  end

  awaiting = false
  whoTimer = GuildRecruiter_Settings.whoDelay
end

local function GR_OnEvent()
  if event == "VARIABLES_LOADED" then
    -- SavedVariables are guaranteed loaded now; safe to initialise defaults
    GuildRecruiter_Settings = GuildRecruiter_Settings or {}
    Defaults()
    local api = (type(GuildInviteByName) == "function" and "GuildInviteByName")
             or (type(GuildInvite) == "function" and "GuildInvite")
             or "/ginvite (chat fallback)"
    Print("v1.2 loaded. Invite API: "..api..". /gr for commands, /gr config for settings.")
  elseif event == "WHO_LIST_UPDATE" and running then
    ProcessWho()
    if GuildRecruiter_Settings.hideWho then hideSoon = true end
  end
end

f:RegisterEvent("VARIABLES_LOADED")
f:RegisterEvent("WHO_LIST_UPDATE")
f:SetScript("OnEvent", function()
  local ok, err = pcall(GR_OnEvent)
  if not ok then Abort(err) end
end)

local function GR_OnUpdate()
  if not running then return end
  local e = arg1

  -- a query opened the Who/social window last frame; close it again
  if hideSoon then
    hideSoon = false
    if FriendsFrame and FriendsFrame:IsVisible() then HideUIPanel(FriendsFrame) end
  end

  if scanning then
    if awaiting then
      whoTimeout = whoTimeout - e
      if whoTimeout <= 0 then
        -- no reply (likely /who got throttled): skip this slice so we never
        -- loop re-asking for the same band
        awaiting = false
        if current and current.sweep then lo = current.hi + 1 end
        whoTimer = GuildRecruiter_Settings.whoDelay
      end
    else
      whoTimer = whoTimer - e
      if whoTimer <= 0 then
        SendNextWho()
        whoTimer = GuildRecruiter_Settings.whoDelay
      end
    end
  end

  if table.getn(queue) > 0 then
    inviteTimer = inviteTimer - e
    if inviteTimer <= 0 then
      local name = tremove(queue, 1)
      DoGuildInvite(name)
      if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
      GuildRecruiter_Settings.history[name] = time()   -- persist so we don't re-invite after a restart
      stats.invited = stats.invited + 1
      Print("Invited "..name.." ("..stats.invited..")")
      inviteTimer = GuildRecruiter_Settings.inviteDelay
    end
  elseif not scanning then
    running = false
    Print("Done. Invited "..stats.invited..", skipped "..stats.guilded.." already-guilded, "..stats.queries.." queries.")
  end
end

f:SetScript("OnUpdate", function()
  local ok, err = pcall(GR_OnUpdate)
  if not ok then Abort(err) end
end)

-- our faction's class & race lists (/who is faction-locked in 1.12)
local function FactionLists()
  classes = {}
  races = {}
  if UnitFactionGroup("player") == "Horde" then
    classes = { "Warrior", "Hunter", "Rogue", "Priest", "Shaman", "Mage", "Warlock", "Druid" }
    races   = { "Orc", "Undead", "Tauren", "Troll" }
  else
    classes = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Mage", "Warlock", "Druid" }
    races   = { "Human", "Dwarf", "Night Elf", "Gnome" }
  end
end

-- Route /who results to the WHO_LIST_UPDATE event for EVERY query. With this
-- off (the default on some clients), short result lists (<=3) come back as
-- CHAT_MSG_SYSTEM text we can't read with GetWhoInfo, so those players would be
-- silently missed. Turtle WoW exposes SetWhoToUI; guard + pcall for cores without it.
local function ForceWhoToEvent()
  if type(SetWhoToUI) == "function" then
    pcall(SetWhoToUI, 1)
  end
end

local function Start()
  if not IsInGuild() then Print("You're not in a guild.") return end
  if running then Print("Already running. /gr stop to cancel.") return end
  ForceWhoToEvent()
  FactionLists()
  running, scanning, awaiting = true, true, false
  current = nil
  lo, width = 1, START_WIDTH        -- sweep starts here; band width self-adjusts
  pending = {}
  queue = {}
  seen  = {}
  whoTimer, inviteTimer, whoTimeout = 0, 0, 0
  stats = { invited = 0, guilded = 0, scanned = 0, queries = 0, dropped = 0, cooldown = 0 }
  Print("Started. Adaptive /who scan + guildless invites at "..GuildRecruiter_Settings.inviteDelay.."s each. /gr stop to cancel.")
end

local function Stop()
  if not running then Print("Not running.") return end
  running, scanning, awaiting = false, false, false
  Print("Stopped. Invited "..stats.invited.." this run; "..table.getn(queue).." still queued.")
end

local function HistoryCount()
  local n = 0
  for _ in GuildRecruiter_Settings.history do n = n + 1 end
  return n
end

local function Status()
  if running then
    Print("Running -- "..(scanning and ("scanning ~lvl "..lo.." (band "..width..")") or "draining")..". Sub-queries "..table.getn(pending)..", queue "..table.getn(queue)..", invited "..stats.invited..", on-cooldown skipped "..stats.cooldown..", queries "..stats.queries..".")
  else
    Print("Idle. Last run: invited "..stats.invited..", guilded-skipped "..stats.guilded..", cooldown-skipped "..stats.cooldown..".")
  end
  Print("History: "..HistoryCount().." names remembered; re-invite cooldown "..GuildRecruiter_Settings.reinviteDays.." day(s). invite="..GuildRecruiter_Settings.inviteDelay.."s who="..GuildRecruiter_Settings.whoDelay.."s")
end

-- ----------------------------------------------------------------------------
-- Config GUI: sliders + numeric input boxes for the two pacing delays, and a
-- cycle button for the invite-method override. Built lazily on first open.
-- ----------------------------------------------------------------------------
local configFrame

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

-- push current settings into the widgets (guarded so SetValue doesn't recurse
-- back through OnValueChanged and overwrite the very value we're displaying)
local function RefreshConfig()
  if not configFrame then return end
  local s = GuildRecruiter_Settings
  configFrame.updating = true
  configFrame.inviteSlider:SetValue(clamp(s.inviteDelay, INVITE_MIN, INVITE_MAX))
  configFrame.whoSlider:SetValue(clamp(s.whoDelay, WHO_MIN, WHO_MAX))
  configFrame.inviteEdit:SetText(tostring(s.inviteDelay))
  configFrame.whoEdit:SetText(tostring(s.whoDelay))
  configFrame.methodBtn:SetText("Invite method: "..(METHOD_LABEL[s.inviteMethod] or s.inviteMethod))
  configFrame.updating = false
end

local function ApplyInvite(v)
  GuildRecruiter_Settings.inviteDelay = clamp(floor(v + 0.5), INVITE_MIN, INVITE_MAX)
  RefreshConfig()
end

local function ApplyWho(v)
  GuildRecruiter_Settings.whoDelay = clamp(floor(v + 0.5), WHO_MIN, WHO_MAX)
  RefreshConfig()
end

local function CycleMethod()
  local cur, idx = GuildRecruiter_Settings.inviteMethod or "auto", 1
  for i = 1, table.getn(METHOD_ORDER) do
    if METHOD_ORDER[i] == cur then idx = i end
  end
  idx = idx + 1
  if idx > table.getn(METHOD_ORDER) then idx = 1 end
  GuildRecruiter_Settings.inviteMethod = METHOD_ORDER[idx]
  RefreshConfig()
end

-- helper: build a labelled slider with a numeric input box to its right
local function MakeRow(parent, prefix, label, lo, hi, yoff, applyFn)
  local sl = CreateFrame("Slider", prefix.."Slider", parent, "OptionsSliderTemplate")
  sl:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, yoff)
  sl:SetWidth(210); sl:SetHeight(16)
  sl:SetMinMaxValues(lo, hi)
  sl:SetValueStep(1)
  getglobal(prefix.."SliderText"):SetText(label)
  getglobal(prefix.."SliderLow"):SetText(lo)
  getglobal(prefix.."SliderHigh"):SetText(hi)

  local ed = CreateFrame("EditBox", prefix.."Edit", parent, "InputBoxTemplate")
  ed:SetPoint("LEFT", sl, "RIGHT", 26, 0)
  ed:SetWidth(38); ed:SetHeight(20)
  ed:SetAutoFocus(false)
  ed:SetNumeric(true)
  ed:SetMaxLetters(3)

  sl:SetScript("OnValueChanged", function()
    if not configFrame or not configFrame.updating then applyFn(this:GetValue()) end
  end)
  ed:SetScript("OnEnterPressed", function()
    local v = tonumber(this:GetText())
    if v then applyFn(v) end
    this:ClearFocus()
  end)
  ed:SetScript("OnEscapePressed", function() this:ClearFocus() end)

  return sl, ed
end

local function BuildConfig()
  local fr = CreateFrame("Frame", "GuildRecruiterConfig", UIParent)
  fr:SetWidth(340); fr:SetHeight(250)
  fr:SetPoint("CENTER", 0, 0)
  fr:SetFrameStrata("DIALOG")
  fr:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  fr:EnableMouse(true)
  fr:SetMovable(true)
  fr:RegisterForDrag("LeftButton")
  fr:SetScript("OnDragStart", function() this:StartMoving() end)
  fr:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  fr:Hide()

  local title = fr:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", 0, -16)
  title:SetText("Guild Recruiter")

  local close = CreateFrame("Button", nil, fr, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  fr.inviteSlider, fr.inviteEdit = MakeRow(fr, "GuildRecruiterConfigInvite",
    "Invite delay (seconds)", INVITE_MIN, INVITE_MAX, -58, ApplyInvite)
  fr.whoSlider, fr.whoEdit = MakeRow(fr, "GuildRecruiterConfigWho",
    "/who delay (seconds)", WHO_MIN, WHO_MAX, -112, ApplyWho)

  local mb = CreateFrame("Button", "GuildRecruiterConfigMethodBtn", fr, "UIPanelButtonTemplate")
  mb:SetPoint("TOPLEFT", 22, -156)
  mb:SetWidth(296); mb:SetHeight(22)
  mb:SetScript("OnClick", function() CycleMethod() end)
  fr.methodBtn = mb

  local note = fr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  note:SetPoint("BOTTOMLEFT", 18, 16)
  note:SetPoint("BOTTOMRIGHT", -18, 16)
  note:SetJustifyH("LEFT")
  note:SetText("Invite floor is 1s -- faster risks a flood-kick. /who is still server-\nthrottled; if scans get dropped, raise the /who delay.")

  configFrame = fr
end

local function ToggleConfig()
  Defaults()
  if not configFrame then BuildConfig() end
  if configFrame:IsVisible() then
    configFrame:Hide()
  else
    RefreshConfig()
    configFrame:Show()
  end
end

SLASH_GUILDRECRUITER1 = "/gr"
SlashCmdList["GUILDRECRUITER"] = function(msg)
  Defaults()
  msg = string.lower(msg or "")
  local _, _, cmd, arg = string.find(msg, "^(%a+)%s*(.*)$")
  if cmd == "start" then
    Start()
  elseif cmd == "stop" then
    Stop()
  elseif cmd == "status" then
    Status()
  elseif cmd == "config" or cmd == "options" or cmd == "gui" then
    ToggleConfig()
  elseif cmd == "reset" then
    seen = {}
    Print("Cleared this session's scan list (persistent invite history kept).")
  elseif cmd == "forget" then
    GuildRecruiter_Settings.history = {}
    Print("Cleared the persistent invite history -- everyone is invitable again.")
  elseif cmd == "hide" then
    GuildRecruiter_Settings.hideWho = not GuildRecruiter_Settings.hideWho
    Print("Auto-hide Who window while scanning: "..(GuildRecruiter_Settings.hideWho and "ON" or "OFF"))
  elseif cmd == "set" then
    local _, _, which, rest = string.find(arg, "^(%a+)%s+(%S+)$")
    local val = tonumber(rest)
    if which == "invite" and val and val >= 1 then
      GuildRecruiter_Settings.inviteDelay = val
      RefreshConfig()
      Print("Invite delay set to "..val.."s. (1s floor: invites drain once per timer tick; lower would flood-kick.)")
    elseif which == "who" and val and val >= 1 then
      GuildRecruiter_Settings.whoDelay = val
      RefreshConfig()
      Print("Who delay set to "..val.."s. (/who is still server-throttled -- if scans get dropped, raise this.)")
    elseif which == "reinvite" and val then
      GuildRecruiter_Settings.reinviteDays = val
      if val == 0 then
        Print("Re-invite cooldown: never re-invite anyone already invited.")
      else
        Print("Re-invite cooldown set to "..val.." day(s).")
      end
    elseif which == "method" then
      if rest and METHOD_LABEL[rest] then
        GuildRecruiter_Settings.inviteMethod = rest
        RefreshConfig()
        Print("Invite method set to "..rest.." ("..METHOD_LABEL[rest]..").")
      else
        Print("Usage: /gr set method auto|byname|invite|chat")
      end
    else
      Print("Usage: /gr set invite <sec(>=1)> | set who <sec(>=1)> | set reinvite <days(0=never)> | set method <auto|byname|invite|chat>")
    end
  else
    Print("Commands: start | stop | status | config | reset | forget | hide | set invite/who/reinvite/method <v>")
    Print("Use |cffffff00/gr config|r for sliders + invite-method picker. Invites only guildless players, skips anyone invited in the last "..GuildRecruiter_Settings.reinviteDays.." day(s), paced to avoid flood-kick.")
  end
end

-- (init happens on VARIABLES_LOADED, once SavedVariables are actually loaded)
