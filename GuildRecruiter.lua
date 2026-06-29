--[[ Guild Recruiter -- vanilla 1.12 / Turtle WoW   (v2.0)

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

local VERSION    = "2.2"
local CAP_HINT   = 49      -- treat a query returning >= this many as truncated
local START_WIDTH = 10     -- initial level-band width to try
local WHO_TIMEOUT = 12     -- give up waiting on a reply after this many seconds
local SYNC_PREFIX = "GuildRec"
local PRESENCE_INTERVAL = 20  -- re-announce "I'm recruiting" this often (s)
local PRESENCE_TTL      = 60  -- forget a recruiter not heard from in this long
local WHISPER_WAIT      = 120 -- keep waiting this long for a whisper reply (s)
local BACKOFF_SECS      = 12  -- pause sends this long when the server throttles us

-- config-GUI slider ranges and option tables
local INVITE_MIN, INVITE_MAX = 1, 10
local WHO_MIN,    WHO_MAX    = 1, 15
local METHOD_ORDER = { "auto", "byname", "invite", "chat" }
local METHOD_LABEL = {
  auto   = "Auto (best available)",
  byname = "GuildInviteByName()",
  invite = "GuildInvite()",
  chat   = "/ginvite (chat command)",
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

-- default whisper; OLD_WHISPER is migrated to NEW_WHISPER so testers on the old
-- default pick up the better one (custom messages are left untouched)
local OLD_WHISPER = "Hi %p! We're recruiting for %g -- whisper me back if you're interested and I'll send an invite. :)"
local NEW_WHISPER = "Hi %p! :) I'm recruiting for <%g>, a friendly and active guild that loves grouping up for quests, dungeons and raids. If you're after a guild, just whisper me back and I'll send an invite -- no pressure either way!"

local f = CreateFrame("Frame", "GuildRecruiterFrame")

-- run state
local running, scanning, awaiting, paused = false, false, false, false
local lo        = 1        -- next uncovered level in the sweep
local width     = START_WIDTH
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
local stats = { contacted=0, invited=0, whispered=0, guilded=0, scanned=0, queries=0, dropped=0, cooldown=0 }

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99GuildRecruiter|r: "..msg)
end

local function clamp(v, a, b)
  if v < a then return a elseif v > b then return b else return v end
end

local function CountTable(t)
  local n = 0
  for _ in t do n = n + 1 end
  return n
end

-- Stop the default UI's Who panel from popping during a run. We unregister
-- WHO_LIST_UPDATE on FriendsFrame (our own frame still receives it) so the
-- window never opens at all -- no open-then-hide flicker. Restored when we stop.
local whoSuppressed = false
local function SuppressWho(on)
  if not FriendsFrame then return end
  if on then
    if not whoSuppressed and GuildRecruiter_Settings.hideWho then
      FriendsFrame:UnregisterEvent("WHO_LIST_UPDATE")
      whoSuppressed = true
    end
  elseif whoSuppressed then
    FriendsFrame:RegisterEvent("WHO_LIST_UPDATE")
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
  if not s.whisperMsg or s.whisperMsg == OLD_WHISPER then s.whisperMsg = NEW_WHISPER end
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
  if not s.minimapAngle then s.minimapAngle = 210 end
  -- prune history past the cooldown so the saved table can't grow forever
  if s.reinviteDays > 0 then
    local cutoff = time() - s.reinviteDays * 86400
    for n, t in s.history do
      if t < cutoff then s.history[n] = nil end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Skip rules: recently contacted, blacklisted
-- ---------------------------------------------------------------------------
local function RecentlyInvited(name)
  local s = GuildRecruiter_Settings
  local h = s.history
  if not h or not h[name] then return false end
  local days = s.reinviteDays
  if days <= 0 then return true end
  return (time() - h[name]) < days * 86400
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
    SendAddonMessage(SYNC_PREFIX, "V1 "..payload, "GUILD")
  end
end

-- names of all recruiters currently active (self when running, plus live peers)
local function ActiveNames()
  local me = UnitName("player")
  local names = {}
  if running then tinsert(names, me) end
  for n, _ in recruiters do
    if n ~= me then tinsert(names, n) end
  end
  if table.getn(names) == 0 then tinsert(names, me) end  -- always at least self
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
    local total = table.getn(names)
    local me = UnitName("player")
    local idx = 1
    for i = 1, total do if names[i] == me then idx = i end end
    local span = hiL - loL + 1
    local per  = math.ceil(span / total)
    myLo = loL + (idx - 1) * per
    myHi = myLo + per - 1
    if myHi > hiL then myHi = hiL end
    if myLo > hiL then myLo = hiL + 1 end  -- nothing left for me
  end
  -- if my band grew while idle but the run is alive, resume the sweep
  if running and not scanning and lo <= myHi then scanning = true end
end

local function OnAddonMessage()
  if arg1 ~= SYNC_PREFIX then return end
  local me = UnitName("player")
  local sender = arg4
  if sender == me then return end                 -- ignore our own echo
  local _, _, ver, kind, rest = string.find(arg2 or "", "^(%S+)%s+(%S+)%s*(.*)$")
  if ver ~= "V1" then return end
  if kind == "INV" then
    if rest and rest ~= "" then
      if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
      GuildRecruiter_Settings.history[rest] = time()  -- guild-wide dedup
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
local function RunChatCommand(text)
  local eb = ChatFrameEditBox or (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox)
  if not eb then return false end
  eb:SetText(text)
  if ChatEdit_SendText then
    ChatEdit_SendText(eb, 0)
  else
    local handler = eb:GetScript("OnEnterPressed")
    if handler then
      local prev = this
      this = eb; handler(); this = prev
    end
  end
  eb:SetText("")
  return true
end

-- GuildInviteByName is Turtle's canonical name-taking invite; auto prefers it
-- because bare GuildInvite() invites your TARGET on some cores.
local function DoGuildInvite(name)
  local m = GuildRecruiter_Settings.inviteMethod or "auto"
  if m == "byname" and type(GuildInviteByName) == "function" then
    GuildInviteByName(name)
  elseif m == "invite" and type(GuildInvite) == "function" then
    GuildInvite(name)
  elseif m == "chat" then
    RunChatCommand("/ginvite "..name)
  elseif type(GuildInviteByName) == "function" then
    GuildInviteByName(name)
  elseif type(GuildInvite) == "function" then
    GuildInvite(name)
  else
    RunChatCommand("/ginvite "..name)
  end
end

local function WhisperBody(name)
  local msg = GuildRecruiter_Settings.whisperMsg or ""
  local gname = GetGuildInfo("player") or "our guild"
  msg = string.gsub(msg, "%%p", name)
  msg = string.gsub(msg, "%%g", gname)
  return msg
end

local function RecordHandled(name)
  if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
  GuildRecruiter_Settings.history[name] = time()
  Broadcast("INV "..name)
end

-- perform the configured contact action for one name
local function Contact(name)
  local mode = GuildRecruiter_Settings.mode or "invite"
  if mode == "whisper" then
    SendChatMessage(WhisperBody(name), "WHISPER", nil, name)
    stats.whispered = stats.whispered + 1
    RecordHandled(name)
  elseif mode == "whisperinvite" then
    SendChatMessage(WhisperBody(name), "WHISPER", nil, name)
    stats.whispered = stats.whispered + 1
    whispered[name] = GetTime()
    RecordHandled(name)
  else
    DoGuildInvite(name)
    stats.invited = stats.invited + 1
    RecordHandled(name)
  end
  stats.contacted = stats.contacted + 1
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

local function NextQuery()
  if table.getn(pending) > 0 then
    current = tremove(pending, 1)
    return true
  end
  if lo < myLo then lo = myLo end
  if lo <= myHi and lo <= 60 then
    local hi = lo + width - 1
    if hi > myHi then hi = myHi end
    if hi > 60 then hi = 60 end
    current = { lo = lo, hi = hi, sweep = true }
    return true
  end
  return false
end

local function SendNextWho()
  if not NextQuery() then
    scanning = false
    Print("Scan complete: "..stats.queries.." queries, "..table.getn(contactQueue).." left to contact.")
    return
  end
  awaiting = true
  whoTimeout = WHO_TIMEOUT
  stats.queries = stats.queries + 1
  SendWho(BuildFilter(current))
end

local function ClassAllowed(class)
  local cf = GuildRecruiter_Settings.classFilter
  if not cf then return true end
  return cf[string.lower(class or "")] and true or false
end

local function ProcessWho()
  local me = UnitName("player")
  local num = GetNumWhoResults()
  for i = 1, num do
    -- 1.12: name, guild, level, race, class, zone
    local name, guild, _, _, class = GetWhoInfo(i)
    if name then
      stats.scanned = stats.scanned + 1
      if name == me or seen[name] then
        -- skip
      elseif guild and guild ~= "" then
        stats.guilded = stats.guilded + 1; seen[name] = true
      elseif Blacklisted(name) then
        seen[name] = true
      elseif not ClassAllowed(class) then
        seen[name] = true
      elseif RecentlyInvited(name) then
        stats.cooldown = stats.cooldown + 1; seen[name] = true
      else
        seen[name] = true
        tinsert(contactQueue, name)
      end
    end
  end

  local capped = (num >= CAP_HINT)
  local c = current
  if c and c.sweep then
    if capped then
      if c.lo < c.hi then
        width = math.floor((c.hi - c.lo + 1) / 2)
        if width < 1 then width = 1 end
      else
        for i = 1, table.getn(classes) do
          tinsert(pending, { lo = c.lo, hi = c.lo, class = classes[i] })
        end
        lo = c.lo + 1; width = 1
      end
    else
      lo = c.hi + 1
      if num < CAP_HINT * 0.6 then width = math.floor(width * 1.7) + 1 end
      local remain = myHi - lo + 1
      if width > remain then width = remain end
      if width < 1 then width = 1 end
    end
  elseif c and capped then
    -- a single class at a single level is still capped -- take what we got
    stats.dropped = stats.dropped + 1
  end

  awaiting = false
  whoTimer = GuildRecruiter_Settings.whoDelay
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

-- can we send a contact/invite right now?
local function SendsBlocked()
  if GetTime() < backoffUntil then return true end
  if GuildRecruiter_Settings.skipCombat and inCombat then return true end
  if InstanceBlocked() then return true end
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
  SuppressWho(false)
  Print("|cffff4040Stopped on error:|r "..tostring(reason))
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local InitMinimap  -- forward decl

local function GR_OnEvent()
  if event == "VARIABLES_LOADED" then
    GuildRecruiter_Settings = GuildRecruiter_Settings or {}
    Defaults()
    InitMinimap()
    local api = (type(GuildInviteByName) == "function" and "GuildInviteByName")
             or (type(GuildInvite) == "function" and "GuildInvite")
             or "/ginvite (chat fallback)"
    Print("v"..VERSION.." loaded. Invite API: "..api..". /gr for commands, /gr config for settings.")
  elseif event == "WHO_LIST_UPDATE" and running then
    ProcessWho()
    if GuildRecruiter_Settings.hideWho then hideSoon = true end
  elseif event == "CHAT_MSG_ADDON" then
    OnAddonMessage()
  elseif event == "CHAT_MSG_SYSTEM" then
    local m = string.lower(arg1 or "")
    if string.find(m, "too quickly") or string.find(m, "too many")
       or (string.find(m, "wait") and string.find(m, "invit")) then
      backoffUntil = GetTime() + BACKOFF_SECS
      Print("|cffffcc00Server throttle detected -- pausing sends "..BACKOFF_SECS.."s.|r")
    end
  elseif event == "CHAT_MSG_WHISPER" then
    local sender = arg2
    if sender and whispered[sender] then
      whispered[sender] = nil
      tinsert(replyQueue, sender)   -- they replied: invite them (paced)
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    inCombat = true
  elseif event == "PLAYER_REGEN_ENABLED" then
    inCombat = false
  end
end

f:RegisterEvent("VARIABLES_LOADED")
f:RegisterEvent("WHO_LIST_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("CHAT_MSG_WHISPER")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", function()
  local ok, err = pcall(GR_OnEvent)
  if not ok then Abort(err) end
end)

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------
local function HasOutstandingWhispers()
  for _, t in whispered do
    if GetTime() - t < WHISPER_WAIT then return true end
  end
  return false
end

local function GR_OnUpdate()
  if not running or paused then return end
  local e = arg1

  if hideSoon then
    hideSoon = false
    if FriendsFrame and FriendsFrame:IsVisible() then HideUIPanel(FriendsFrame) end
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
  for n, t in recruiters do
    if GetTime() - t > PRESENCE_TTL then recruiters[n] = nil; pruned = true end
  end
  if pruned then RecomputeBand() end

  -- forget whisper targets who never replied
  for n, t in whispered do
    if GetTime() - t > WHISPER_WAIT then whispered[n] = nil end
  end

  -- scanning
  if scanning then
    if awaiting then
      whoTimeout = whoTimeout - e
      if whoTimeout <= 0 then
        awaiting = false
        if current and current.sweep then lo = current.hi + 1 end
        whoTimer = GuildRecruiter_Settings.whoDelay
      end
    elseif GetTime() >= backoffUntil then
      whoTimer = whoTimer - e
      if whoTimer <= 0 then
        SendNextWho()
        whoTimer = Pace(GuildRecruiter_Settings.whoDelay)
      end
    end
  end

  -- contacting / inviting (paced; replies take priority)
  if table.getn(replyQueue) > 0 or table.getn(contactQueue) > 0 then
    inviteTimer = inviteTimer - e
    if inviteTimer <= 0 and not SendsBlocked() then
      if table.getn(replyQueue) > 0 then
        local name = tremove(replyQueue, 1)
        DoGuildInvite(name)
        if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
        GuildRecruiter_Settings.history[name] = time()
        stats.invited = stats.invited + 1
        Print("Invited (replied) "..name.." ("..stats.invited..")")
        inviteTimer = Pace(GuildRecruiter_Settings.inviteDelay)
      elseif not CapReached() then
        local name = tremove(contactQueue, 1)
        Contact(name)
        Print("Contacted "..name.." ("..stats.contacted..")")
        inviteTimer = Pace(GuildRecruiter_Settings.inviteDelay)
      end
    end
  elseif not scanning then
    -- whisper-on-reply mode keeps running a while to catch late replies
    if GuildRecruiter_Settings.mode == "whisperinvite" and HasOutstandingWhispers() then
      -- keep waiting
    else
      running = false
      SuppressWho(false)
      Broadcast("BYE")
      Print("Done. Contacted "..stats.contacted.." ("..stats.invited.." invited, "..stats.whispered.." whispered), skipped "..stats.guilded.." guilded, "..stats.queries.." queries.")
    end
  end
end

f:SetScript("OnUpdate", function()
  local ok, err = pcall(GR_OnUpdate)
  if not ok then Abort(err) end
end)

-- Quiet the /who chat spam during a run. There's no message-filter API on 1.12,
-- so we wrap ChatFrame_OnEvent and drop the /who summary/result system lines
-- while we're scanning. Our own CHAT_MSG_SYSTEM handler (on frame f) is separate
-- and still fires, so throttle-detection keeps working.
local function IsWhoNoise(m)
  if not m then return false end
  if string.find(m, "[Pp]layers? [Tt]otal") then return true end  -- "3 Players Total"
  if string.find(m, "^There are %d")          then return true end
  if string.find(m, "[Nn]o players")          then return true end  -- "No players found"
  return false
end

local Orig_ChatFrame_OnEvent = ChatFrame_OnEvent
function ChatFrame_OnEvent(ev)
  if running and GuildRecruiter_Settings.quietWho
     and ev == "CHAT_MSG_SYSTEM" and IsWhoNoise(arg1) then
    return
  end
  Orig_ChatFrame_OnEvent(ev)
end

-- ---------------------------------------------------------------------------
-- Run control
-- ---------------------------------------------------------------------------
local function ForceWhoToEvent()
  if type(SetWhoToUI) == "function" then pcall(SetWhoToUI, 1) end
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
  if running and not paused then Print("Already running. /gr stop to cancel, /gr pause to pause.") return end
  ForceWhoToEvent()
  SuppressWho(true)
  FactionLists()
  running, scanning, awaiting, paused = true, true, false, false
  current = nil
  pending, contactQueue, replyQueue, seen, whispered = {}, {}, {}, {}, {}
  whoTimer, inviteTimer, whoTimeout, presenceTimer = 0, 0, 0, 0
  stats = { contacted=0, invited=0, whispered=0, guilded=0, scanned=0, queries=0, dropped=0, cooldown=0 }
  RecomputeBand()
  lo, width = myLo, START_WIDTH
  if GuildRecruiter_Settings.guildSync and IsInGuild() then Broadcast("HI") end
  Print("Started ("..(MODE_LABEL[GuildRecruiter_Settings.mode] or "?")..") on levels "..myLo.."-"..myHi..". /gr stop to cancel.")
end

local function Stop()
  if not running then Print("Not running.") return end
  running, scanning, awaiting, paused = false, false, false, false
  SuppressWho(false)
  Broadcast("BYE")
  Print("Stopped. Contacted "..stats.contacted.." this run; "..table.getn(contactQueue).." still queued.")
end

local function Pause()
  if not running then Print("Not running.") return end
  if paused then Print("Already paused. /gr resume to continue.") return end
  paused = true
  SuppressWho(false)  -- let manual /who work normally while paused
  Broadcast("BYE")  -- yield my band to others while paused
  Print("Paused at level "..lo..". "..table.getn(contactQueue).." queued. /gr resume to continue.")
end

local function Resume()
  if not running then Print("Not running -- use /gr start.") return end
  if not paused then Print("Not paused.") return end
  paused = false
  SuppressWho(true)
  RecomputeBand()
  if GuildRecruiter_Settings.guildSync and IsInGuild() then Broadcast("HI") end
  Print("Resumed.")
end

-- ---------------------------------------------------------------------------
-- List window: view/edit the contact queue, blacklist, and invite history
-- ---------------------------------------------------------------------------
local listFrame, listMode = nil, "queue"
local listData = {}
local NUM_ROWS, ROW_HEIGHT = 13, 18
local LIST_ORDER = { "queue", "blacklist", "history" }
local LIST_TITLE = { queue = "Queue (this run)", blacklist = "Blacklist", history = "Invite history" }

local function BuildListData()
  listData = {}
  if listMode == "queue" then
    for i = 1, table.getn(contactQueue) do tinsert(listData, contactQueue[i]) end
  elseif listMode == "blacklist" then
    for n in GuildRecruiter_Settings.blacklist do tinsert(listData, n) end
    table.sort(listData)
  else
    for n in GuildRecruiter_Settings.history do tinsert(listData, n) end
    table.sort(listData)
  end
end

local function RemoveListItem(name)
  if listMode == "queue" then
    for i = 1, table.getn(contactQueue) do
      if contactQueue[i] == name then tremove(contactQueue, i); break end
    end
  elseif listMode == "blacklist" then
    GuildRecruiter_Settings.blacklist[name] = nil
  else
    GuildRecruiter_Settings.history[name] = nil
  end
end

local UpdateList  -- forward decl (handlers below capture it)

local function BuildListWindow()
  local fr = CreateFrame("Frame", "GuildRecruiterList", UIParent)
  fr:SetWidth(300); fr:SetHeight(380)
  fr:SetPoint("CENTER", 180, 0)
  fr:SetFrameStrata("DIALOG")
  fr:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  fr:EnableMouse(true); fr:SetMovable(true); fr:RegisterForDrag("LeftButton")
  fr:SetScript("OnDragStart", function() this:StartMoving() end)
  fr:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  fr.rows = {}

  local title = fr:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", 0, -16); title:SetText("Guild Recruiter -- Lists")
  local close = CreateFrame("Button", nil, fr, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  fr.cycle = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.cycle:SetPoint("TOP", 0, -38); fr.cycle:SetWidth(260); fr.cycle:SetHeight(22)
  fr.cycle:SetScript("OnClick", function()
    local idx = 1
    for i = 1, table.getn(LIST_ORDER) do if LIST_ORDER[i] == listMode then idx = i end end
    idx = idx + 1; if idx > table.getn(LIST_ORDER) then idx = 1 end
    listMode = LIST_ORDER[idx]; UpdateList()
  end)

  fr.hint = fr:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  fr.hint:SetPoint("TOP", 0, -62); fr.hint:SetText("click a name to remove it")

  local scroll = CreateFrame("ScrollFrame", "GuildRecruiterListScroll", fr, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 16, -78)
  scroll:SetPoint("BOTTOMRIGHT", -34, 52)
  scroll:SetScript("OnVerticalScroll", function() FauxScrollFrame_OnVerticalScroll(ROW_HEIGHT, UpdateList) end)
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
    row:SetScript("OnClick", function() if this.pname then RemoveListItem(this.pname); UpdateList() end end)
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
      GuildRecruiter_Settings.blacklist[string.lower(n)] = true
      addEdit:SetText(""); listMode = "blacklist"; UpdateList()
    end
  end
  local addBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  addBtn:SetPoint("LEFT", addEdit, "RIGHT", 8, 0); addBtn:SetWidth(92); addBtn:SetHeight(22)
  addBtn:SetText("Blacklist"); addBtn:SetScript("OnClick", doAdd)
  addEdit:SetScript("OnEnterPressed", function() doAdd(); this:ClearFocus() end)
  addEdit:SetScript("OnEscapePressed", function() this:ClearFocus() end)

  listFrame = fr
end

UpdateList = function()
  if not listFrame then return end
  BuildListData()
  local n = table.getn(listData)
  local offset = FauxScrollFrame_GetOffset(listFrame.scroll)
  for i = 1, NUM_ROWS do
    local idx = offset + i
    local row = listFrame.rows[i]
    if idx <= n then
      row.pname = listData[idx]; row.text:SetText(listData[idx]); row:Show()
    else
      row.pname = nil; row:Hide()
    end
  end
  FauxScrollFrame_Update(listFrame.scroll, n, NUM_ROWS, ROW_HEIGHT)
  listFrame.cycle:SetText("View: "..(LIST_TITLE[listMode] or listMode).."  ("..n..")")
end

local function ToggleList()
  Defaults()
  if not listFrame then BuildListWindow() end
  if listFrame:IsVisible() then listFrame:Hide() else UpdateList(); listFrame:Show() end
end

-- ---------------------------------------------------------------------------
-- Config GUI
-- ---------------------------------------------------------------------------
local configFrame
local RefreshConfig  -- forward decl

-- level setters used by both the GUI boxes and slash: clamp to 1-60, drop any
-- fraction, and keep min <= max (raising the other bound if they cross)
local function SetMinLevel(v)
  v = clamp(math.floor(tonumber(v) or 1), 1, 60)
  GuildRecruiter_Settings.minLevel = v
  if GuildRecruiter_Settings.maxLevel < v then GuildRecruiter_Settings.maxLevel = v end
  RecomputeBand(); RefreshConfig()
end
local function SetMaxLevel(v)
  v = clamp(math.floor(tonumber(v) or 60), 1, 60)
  GuildRecruiter_Settings.maxLevel = v
  if GuildRecruiter_Settings.minLevel > v then GuildRecruiter_Settings.minLevel = v end
  RecomputeBand(); RefreshConfig()
end

local function ApplyInvite(v) GuildRecruiter_Settings.inviteDelay = clamp(math.floor(v + 0.5), INVITE_MIN, INVITE_MAX); RefreshConfig() end
local function ApplyWho(v)    GuildRecruiter_Settings.whoDelay    = clamp(math.floor(v + 0.5), WHO_MIN, WHO_MAX); RefreshConfig() end

local function CycleMethod()
  local cur, idx = GuildRecruiter_Settings.inviteMethod or "auto", 1
  for i = 1, table.getn(METHOD_ORDER) do if METHOD_ORDER[i] == cur then idx = i end end
  idx = idx + 1; if idx > table.getn(METHOD_ORDER) then idx = 1 end
  GuildRecruiter_Settings.inviteMethod = METHOD_ORDER[idx]; RefreshConfig()
end

local function CycleMode()
  local cur, idx = GuildRecruiter_Settings.mode or "invite", 1
  for i = 1, table.getn(MODE_ORDER) do if MODE_ORDER[i] == cur then idx = i end end
  idx = idx + 1; if idx > table.getn(MODE_ORDER) then idx = 1 end
  GuildRecruiter_Settings.mode = MODE_ORDER[idx]; RefreshConfig()
end

local function MakeSlider(parent, prefix, label, alo, ahi, y, applyFn)
  local sl = CreateFrame("Slider", prefix.."Slider", parent, "OptionsSliderTemplate")
  sl:SetPoint("TOPLEFT", parent, "TOPLEFT", 22, y)
  sl:SetWidth(200); sl:SetHeight(16)
  sl:SetMinMaxValues(alo, ahi); sl:SetValueStep(1)
  getglobal(prefix.."SliderText"):SetText(label)
  getglobal(prefix.."SliderLow"):SetText(alo)
  getglobal(prefix.."SliderHigh"):SetText(ahi)
  local ed = CreateFrame("EditBox", prefix.."Edit", parent, "InputBoxTemplate")
  ed:SetPoint("LEFT", sl, "RIGHT", 26, 0)
  ed:SetWidth(38); ed:SetHeight(20)
  ed:SetAutoFocus(false); ed:SetNumeric(true); ed:SetMaxLetters(3)
  sl:SetScript("OnValueChanged", function() if not configFrame or not configFrame.updating then applyFn(this:GetValue()) end end)
  ed:SetScript("OnEnterPressed", function() local v = tonumber(this:GetText()); if v then applyFn(v) end; this:ClearFocus() end)
  ed:SetScript("OnEscapePressed", function() this:ClearFocus() end)
  return sl, ed
end

local function MakeCheck(parent, name, label, x, y, settingKey)
  local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  cb:SetWidth(22); cb:SetHeight(22)
  getglobal(name.."Text"):SetText(label)
  cb:SetScript("OnClick", function()
    GuildRecruiter_Settings[settingKey] = (this:GetChecked() and true) or false
    if settingKey == "guildSync" then RecomputeBand() end
  end)
  return cb
end

local function MakeNumBox(parent, name, x, y, w, maxLetters, applyFn)
  local ed = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
  ed:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  ed:SetWidth(w); ed:SetHeight(20)
  ed:SetAutoFocus(false); ed:SetNumeric(true); ed:SetMaxLetters(maxLetters)
  ed:SetScript("OnEnterPressed", function() local v = tonumber(this:GetText()); if v then applyFn(v) end; this:ClearFocus() end)
  ed:SetScript("OnEscapePressed", function() this:ClearFocus() end)
  return ed
end

local function Label(parent, text, x, y)
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  fs:SetText(text)
  return fs
end

RefreshConfig = function()
  if not configFrame then return end
  local s = GuildRecruiter_Settings
  configFrame.updating = true
  configFrame.inviteSlider:SetValue(clamp(s.inviteDelay, INVITE_MIN, INVITE_MAX))
  configFrame.whoSlider:SetValue(clamp(s.whoDelay, WHO_MIN, WHO_MAX))
  configFrame.inviteEdit:SetText(tostring(s.inviteDelay))
  configFrame.whoEdit:SetText(tostring(s.whoDelay))
  configFrame.methodBtn:SetText(METHOD_SHORT[s.inviteMethod] or s.inviteMethod)
  configFrame.modeBtn:SetText(MODE_SHORT[s.mode] or s.mode)
  configFrame.whisperEdit:SetText(s.whisperMsg or "")
  configFrame.minEdit:SetText(tostring(s.minLevel))
  configFrame.maxEdit:SetText(tostring(s.maxLevel))
  configFrame.capEdit:SetText(tostring(s.sessionCap))
  configFrame.jitterCheck:SetChecked(s.jitter)
  configFrame.syncCheck:SetChecked(s.guildSync)
  configFrame.combatCheck:SetChecked(s.skipCombat)
  configFrame.instanceCheck:SetChecked(s.skipInstance)
  configFrame.quietCheck:SetChecked(s.quietWho)
  configFrame.updating = false
end

local function StatusLine()
  if not running then return "Idle." end
  if paused then return "Paused at lvl "..lo.." | queued "..table.getn(contactQueue) end
  local where = scanning and ("scanning lvl "..lo) or "draining"
  return where.." | band "..myLo.."-"..myHi.." | queued "..table.getn(contactQueue)
       .." | sent "..stats.contacted.." | peers "..(CountTable(recruiters))
end

local function BuildConfig()
  local fr = CreateFrame("Frame", "GuildRecruiterConfig", UIParent)
  fr:SetWidth(360); fr:SetHeight(470)
  fr:SetPoint("CENTER", 0, 0)
  fr:SetFrameStrata("DIALOG")
  fr:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  fr:EnableMouse(true); fr:SetMovable(true); fr:RegisterForDrag("LeftButton")
  fr:SetScript("OnDragStart", function() this:StartMoving() end)
  fr:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  fr:Hide()

  local title = fr:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", 0, -16); title:SetText("Guild Recruiter  v"..VERSION)
  local close = CreateFrame("Button", nil, fr, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  fr.inviteSlider, fr.inviteEdit = MakeSlider(fr, "GuildRecruiterConfigInvite", "Invite/contact delay (s)", INVITE_MIN, INVITE_MAX, -48, ApplyInvite)
  fr.whoSlider,    fr.whoEdit    = MakeSlider(fr, "GuildRecruiterConfigWho",    "/who delay (s)",           WHO_MIN,    WHO_MAX,    -92, ApplyWho)

  Label(fr, "Invite method:", 24, -128)
  fr.methodBtn = CreateFrame("Button", "GuildRecruiterConfigMethodBtn", fr, "UIPanelButtonTemplate")
  fr.methodBtn:SetPoint("TOPLEFT", 150, -124); fr.methodBtn:SetWidth(184); fr.methodBtn:SetHeight(22)
  fr.methodBtn:SetScript("OnClick", function() CycleMethod() end)

  Label(fr, "Mode:", 24, -154)
  fr.modeBtn = CreateFrame("Button", "GuildRecruiterConfigModeBtn", fr, "UIPanelButtonTemplate")
  fr.modeBtn:SetPoint("TOPLEFT", 150, -150); fr.modeBtn:SetWidth(184); fr.modeBtn:SetHeight(22)
  fr.modeBtn:SetScript("OnClick", function() CycleMode() end)

  Label(fr, "Whisper message (%p = name, %g = guild):", 24, -178)
  fr.whisperEdit = CreateFrame("EditBox", "GuildRecruiterConfigWhisper", fr, "InputBoxTemplate")
  fr.whisperEdit:SetPoint("TOPLEFT", 26, -192); fr.whisperEdit:SetWidth(300); fr.whisperEdit:SetHeight(20)
  fr.whisperEdit:SetAutoFocus(false); fr.whisperEdit:SetMaxLetters(255)
  fr.whisperEdit:SetScript("OnEnterPressed", function() GuildRecruiter_Settings.whisperMsg = this:GetText(); this:ClearFocus() end)
  fr.whisperEdit:SetScript("OnEscapePressed", function() this:ClearFocus() end)

  Label(fr, "Levels", 24, -222)
  fr.minEdit = MakeNumBox(fr, "GuildRecruiterConfigMin", 70, -218, 34, 2, function(v) SetMinLevel(v) end)
  Label(fr, "to", 112, -222)
  fr.maxEdit = MakeNumBox(fr, "GuildRecruiterConfigMax", 132, -218, 34, 2, function(v) SetMaxLevel(v) end)
  Label(fr, "Session cap (0=off)", 186, -222)
  fr.capEdit = MakeNumBox(fr, "GuildRecruiterConfigCap", 300, -218, 34, 4, function(v) GuildRecruiter_Settings.sessionCap = clamp(math.floor(v), 0, 9999) end)

  fr.jitterCheck   = MakeCheck(fr, "GuildRecruiterConfigJitter",   "Random delays (anti-pattern)", 22,  -248, "jitter")
  fr.syncCheck     = MakeCheck(fr, "GuildRecruiterConfigSync",     "Guild sync (dedup + split)",   22,  -274, "guildSync")
  fr.combatCheck   = MakeCheck(fr, "GuildRecruiterConfigCombat",   "Pause in combat",              22,  -300, "skipCombat")
  fr.quietCheck    = MakeCheck(fr, "GuildRecruiterConfigQuiet",    "Quiet /who chat",              186, -248, "quietWho")
  fr.instanceCheck = MakeCheck(fr, "GuildRecruiterConfigInstance", "Pause in instances",           186, -274, "skipInstance")
  local listsBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  listsBtn:SetPoint("TOPLEFT", 188, -302); listsBtn:SetWidth(146); listsBtn:SetHeight(22)
  listsBtn:SetText("Lists / blacklist..."); listsBtn:SetScript("OnClick", function() ToggleList() end)

  -- live status + progress
  fr.status = fr:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fr.status:SetPoint("TOPLEFT", 24, -332); fr.status:SetWidth(310); fr.status:SetJustifyH("LEFT")

  fr.bar = CreateFrame("StatusBar", nil, fr)
  fr.bar:SetPoint("TOPLEFT", 24, -352); fr.bar:SetWidth(310); fr.bar:SetHeight(14)
  fr.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  fr.bar:SetStatusBarColor(0.2, 0.8, 0.3)
  fr.bar:SetMinMaxValues(0, 1); fr.bar:SetValue(0)
  local barbg = fr.bar:CreateTexture(nil, "BACKGROUND")
  barbg:SetAllPoints(fr.bar); barbg:SetTexture(0, 0, 0, 0.4)

  -- start / pause / stop (pause label flips to Resume while paused)
  local startBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  startBtn:SetPoint("BOTTOMLEFT", 22, 18); startBtn:SetWidth(100); startBtn:SetHeight(22)
  startBtn:SetText("Start"); startBtn:SetScript("OnClick", function() Start() end)
  local pauseBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  pauseBtn:SetPoint("LEFT", startBtn, "RIGHT", 7, 0); pauseBtn:SetWidth(100); pauseBtn:SetHeight(22)
  pauseBtn:SetText("Pause"); pauseBtn:SetScript("OnClick", function() if paused then Resume() else Pause() end end)
  local stopBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  stopBtn:SetPoint("LEFT", pauseBtn, "RIGHT", 7, 0); stopBtn:SetWidth(100); stopBtn:SetHeight(22)
  stopBtn:SetText("Stop"); stopBtn:SetScript("OnClick", function() Stop() end)
  fr.pauseBtn = pauseBtn

  -- throttled live refresh of the status line + bar
  fr.tick = 0
  fr:SetScript("OnUpdate", function()
    fr.tick = fr.tick - (arg1 or 0)
    if fr.tick > 0 then return end
    fr.tick = 0.3
    fr.status:SetText(StatusLine())
    fr.pauseBtn:SetText(paused and "Resume" or "Pause")
    local span = myHi - myLo + 1
    local prog = 1
    if running and scanning and span > 0 then prog = clamp((lo - myLo) / span, 0, 1) end
    if not running then prog = 0 end
    fr.bar:SetValue(prog)
  end)

  configFrame = fr
end

local function ToggleConfig()
  Defaults()
  if not configFrame then BuildConfig() end
  if configFrame:IsVisible() then configFrame:Hide()
  else RefreshConfig(); configFrame:Show() end
end

-- ---------------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------------
local minimapBtn
local function MinimapUpdatePos()
  if not minimapBtn then return end
  local a = math.rad(GuildRecruiter_Settings.minimapAngle or 210)
  minimapBtn:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
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

  mb:SetScript("OnClick", function()
    if arg1 == "RightButton" then
      if running then Stop() else Start() end
    else
      ToggleConfig()
    end
  end)
  mb:SetScript("OnDragStart", function()
    this:SetScript("OnUpdate", function()
      local mx, my = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      mx, my = mx / scale, my / scale
      local cx, cy = Minimap:GetCenter()
      GuildRecruiter_Settings.minimapAngle = math.deg(math.atan2(my - cy, mx - cx))
      MinimapUpdatePos()
    end)
  end)
  mb:SetScript("OnDragStop", function() this:SetScript("OnUpdate", nil) end)
  mb:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_LEFT")
    GameTooltip:AddLine("Guild Recruiter")
    GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
    GameTooltip:AddLine("Right-click: start / stop", 1, 1, 1)
    GameTooltip:Show()
  end)
  mb:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
  else
    Print("Idle. Last run: contacted "..stats.contacted.." ("..stats.invited.." inv, "..stats.whispered.." wsp), guilded-skipped "..stats.guilded..".")
  end
  Print("Mode "..(GuildRecruiter_Settings.mode).." | invite="..GuildRecruiter_Settings.inviteDelay.."s who="..GuildRecruiter_Settings.whoDelay.."s | jitter "..(GuildRecruiter_Settings.jitter and "on" or "off").." | sync "..(GuildRecruiter_Settings.guildSync and "on" or "off").." | history "..HistoryCount())
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
  elseif cmd == "status" then Status()
  elseif cmd == "config" or cmd == "options" or cmd == "gui" then ToggleConfig()
  elseif cmd == "list" or cmd == "lists" then ToggleList()
  elseif cmd == "reset" then
    seen = {}; Print("Cleared this session's scan list (history kept).")
  elseif cmd == "forget" then
    GuildRecruiter_Settings.history = {}; Print("Cleared persistent invite history.")
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
      for n in GuildRecruiter_Settings.blacklist do names = names..n..", " end
      Print("Blacklist: "..(names ~= "" and names or "(empty)"))
    else
      Print("Usage: /gr black add <name> | black remove <name> | black list")
    end
  elseif cmd == "class" then
    if larg == "all" or larg == "" then
      GuildRecruiter_Settings.classFilter = nil; Print("Class filter cleared (all classes).")
    else
      local cf = {}
      for c in string.gfind(larg, "[^%s,]+") do cf[c] = true end
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
    else
      Print("set invite|who|reinvite|cap|min|max <n> | set method auto|byname|invite|chat | set mode invite|whisper|whisperinvite")
    end
  elseif cmd == "jitter" or cmd == "sync" or cmd == "combat" or cmd == "instance" or cmd == "quiet" then
    local keymap = { jitter="jitter", sync="guildSync", combat="skipCombat", instance="skipInstance", quiet="quietWho" }
    local key = keymap[cmd]
    GuildRecruiter_Settings[key] = (larg == "on") or (larg ~= "off" and not GuildRecruiter_Settings[key])
    if cmd == "sync" then RecomputeBand() end
    RefreshConfig()
    Print(cmd.." "..(GuildRecruiter_Settings[key] and "ON" or "OFF"))
  else
    Print("|cff33ff99GuildRecruiter v"..VERSION.."|r  --  /gr config (settings), /gr list (queue/blacklist/history)")
    Print("start | stop | pause | resume | status | reset | forget | hide")
    Print("set invite/who/reinvite/cap/min/max/method/mode <v> | msg <text> | class <list|all>")
    Print("black add/remove/list <name> | jitter/sync/combat/instance/quiet [on|off]")
  end
end

-- (init happens on VARIABLES_LOADED, once SavedVariables are actually loaded)
