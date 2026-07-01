--[[ Guild Rawcruiter -- vanilla 1.12 / Turtle WoW   (v2.0)

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

local VERSION    = "3.20"
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
    for i = 1, table.getn(NEGATIVES) do s.negatives[NEGATIVES[i]] = true end
  end
  if not s.affirmatives then   -- editable yes-word list ("yesonly" mode requires these)
    s.affirmatives = {}
    for i = 1, table.getn(AFFIRM_DEFAULTS) do s.affirmatives[AFFIRM_DEFAULTS[i]] = true end
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
  if not s.candidates then s.candidates = {} end          -- [name] = {t, level, class}; persists across logout
  -- abVariants are the CHALLENGERS only (B/C/D). Variant A is always the live
  -- Settings tab (the control), so it is never stored here.
  if not s.abVariants then s.abVariants = {} end
  local chal, used = {}, {}                       -- max 3 challengers; names B/C/D, kept stable
  for i = 1, table.getn(s.abVariants) do
    local v = s.abVariants[i]
    if type(v) == "string" then                   -- legacy: flagged-profile-name string -> table
      local p = s.profiles and s.profiles[v]
      v = { mode = p and p.mode, whisperMsg = p and p.whisperMsg,
            inviteMethod = p and p.inviteMethod, replyMode = p and p.replyMode }
    end
    -- "A" used to be a stored variant; it's the control now, so drop it. Keep an
    -- already-valid, unused B/C/D name as-is (so stats stay attached); only mint
    -- a new name for a bad/missing/duplicate one. Never reshuffle on load.
    if v.name ~= "A" and table.getn(chal) < 3 then
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
    for n, e in s.history do
      local et = (type(e) == "table") and e.t or e   -- entries are {t,p} now; tolerate old numbers
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
    for phrase in (GuildRecruiter_Settings.affirmatives or {}) do
      if string.find(norm, " " .. phrase .. " ", 1, true) then return true end
    end
    return false
  end
  -- "notno": invite unless a refusal word appears
  for phrase in (GuildRecruiter_Settings.negatives or {}) do
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
  -- if my band grew while idle but the run is alive, resume the sweep -- but
  -- ONLY for a scan run. A send/invite-all run is running with scanning=false on
  -- purpose; without this guard Resume() (or a peer's HI/BYE) would flip it into
  -- a /who scan.
  if running and GuildRecruiter_runKind == "scan" and not scanning and lo <= myHi then scanning = true end
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
local function DoGuildInvite(name, method)
  local m = method or GuildRecruiter_Settings.inviteMethod or "auto"
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

local function WhisperBody(name, msg)
  msg = msg or GuildRecruiter_Settings.whisperMsg or ""
  local gname = GetGuildInfo("player") or "our guild"
  msg = string.gsub(msg, "%%p", name)
  msg = string.gsub(msg, "%%g", gname)
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
  return s.abOn and s.abVariants and table.getn(s.abVariants) >= 1
end

-- deal a variant to a contact, weighted by each variant's frequency. nil =
-- control A (live). A's weight is s.abWeightA; each challenger has v.weight.
function GuildRecruiter_PickVariant()
  if not GuildRecruiter_ABActive() then return nil end
  local s = GuildRecruiter_Settings
  local av = s.abVariants
  local wA = s.abWeightA or 1
  local total = wA
  for i = 1, table.getn(av) do total = total + (av[i].weight or 1) end
  local r = random(1, total)
  if r <= wA then return nil end        -- landed in the control's share
  r = r - wA
  for i = 1, table.getn(av) do
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
    for i = 1, table.getn(av) do if av[i].name == nm then return av[i] end end
  end
  return nil
end

local function RecordHandled(name, vname)
  if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
  GuildRecruiter_Settings.history[name] = { t = time(), p = vname }
  Broadcast("INV "..name)
end

-- perform the configured contact action for one name (variant chosen per A/B)
local function Contact(name)
  local v = GuildRecruiter_PickVariant()                 -- challenger table, or nil = control A
  local cfg = GuildRecruiter_CfgOf(v)
  -- during an A/B test a nil pick is the control, credited as "A"; otherwise
  -- (A/B off) it's just the active profile, for sequential profile comparison.
  local vname = (v and v.name) or (GuildRecruiter_ABActive() and "A") or GuildRecruiter_Settings.activeProfile
  if cfg.mode == "whisper" then
    SendChatMessage(WhisperBody(name, cfg.whisperMsg), "WHISPER", nil, name)
    stats.whispered = stats.whispered + 1; TallyBump("whispered")
    RecordHandled(name, vname)
  elseif cfg.mode == "whisperinvite" then
    SendChatMessage(WhisperBody(name, cfg.whisperMsg), "WHISPER", nil, name)
    stats.whispered = stats.whispered + 1; TallyBump("whispered")
    whispered[name] = { t = GetTime(), v = vname }
    RecordHandled(name, vname)
  else
    DoGuildInvite(name, cfg.inviteMethod)
    stats.invited = stats.invited + 1; TallyBump("invited")
    RecordHandled(name, vname)
  end
  stats.contacted = stats.contacted + 1
  GuildRecruiter_VarBump(vname, "contacted")
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
    -- Sweep of my level band is done. If auto-rescan is on (and this is a scan
    -- run, not a send/blast), rest for autoScanDelay and then sweep again instead
    -- of ending -- catches players who log in later. `seen` is kept across cycles
    -- so a repeat sweep only acts on newly-appeared guildless players, and the
    -- persistent re-invite cooldown still guards against re-contacting. We keep
    -- scanning=true through the rest so the run stays alive (the drain-complete
    -- branch won't fire) and contacts keep draining in parallel.
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
      Print("Scan complete: "..stats.queries.." queries, "..table.getn(contactQueue).." left to contact.")
    end
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
    local name, guild, level, _, class = GetWhoInfo(i)
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
        for i = 1, table.getn(classes) do
          tinsert(pending, { lo = c.lo, hi = c.lo, class = classes[i] })
        end
        lo = c.lo + 1; width = 1
        if GuildRecruiter_Settings.debug then Print("  -> lvl "..c.lo.." capped: splitting by class ("..table.getn(classes).." queries)") end
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
  GuildRecruiter_rescanWait = 0
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
    local raw = arg1 or ""
    local m = string.lower(raw)
    if string.find(m, "too quickly") or string.find(m, "too many")
       or (string.find(m, "wait") and string.find(m, "invit")) then
      backoffUntil = GetTime() + BACKOFF_SECS
      Print("|cffffcc00Server throttle detected -- pausing sends "..BACKOFF_SECS.."s.|r")
    end
    -- analytics: attribute a join to us only if we contacted them; declines of
    -- our invitation are always ours
    local hist = GuildRecruiter_Settings.history
    if JOIN_PAT then
      local _, _, jn = string.find(raw, JOIN_PAT)
      local e = jn and hist and hist[jn]
      if e then
        TallyBump("joined")
        local p = (type(e) == "table") and e.p or nil
        if p ~= "(remote)" then GuildRecruiter_VarBump(p, "joined") end  -- a peer's contact isn't our variant
      end
    end
    if DECLINE_PAT then
      local _, _, dn = string.find(raw, DECLINE_PAT)
      if dn then
        TallyBump("declined")
        local e = hist and hist[dn]
        local p = (type(e) == "table") and e.p or nil
        if e and p ~= "(remote)" then GuildRecruiter_VarBump(p, "declined") end
      end
    end
  elseif event == "CHAT_MSG_WHISPER" then
    local sender = arg2
    local w = sender and whispered[sender]
    if w then
      if ShouldInvite(arg1, w.v) then   -- judge with the variant that whispered them
        whispered[sender] = nil
        tinsert(replyQueue, sender)   -- reply passes the policy: invite (paced)
      end
      -- otherwise keep waiting -- a later, clearer "yes" still triggers it
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
  for _, w in whispered do
    if GetTime() - (w.t or 0) < WHISPER_WAIT then return true end
  end
  return false
end

-- GLOBAL on purpose: extracting the contacting/draining block here keeps
-- GR_OnUpdate's upvalue count safely under the Lua 5.0 limit of 32.
function GuildRecruiter_Drain(e)
  -- contacting / inviting (paced; replies take priority)
  if table.getn(replyQueue) > 0 or table.getn(contactQueue) > 0 then
    inviteTimer = inviteTimer - e
    if inviteTimer <= 0 and not SendsBlocked() then
      if table.getn(replyQueue) > 0 then
        local name = tremove(replyQueue, 1)
        DoGuildInvite(name)
        if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
        local pe = GuildRecruiter_Settings.history[name]   -- keep the profile that contacted them
        GuildRecruiter_Settings.history[name] = { t = time(), p = (type(pe) == "table") and pe.p or GuildRecruiter_Settings.activeProfile }
        stats.invited = stats.invited + 1
        TallyBump("invited")
        Print("Invited (replied) "..name.." ("..stats.invited..")")
        inviteTimer = Pace(GuildRecruiter_Settings.inviteDelay)
      elseif not CapReached() then
        local name = tremove(contactQueue, 1)
        if GuildRecruiter_runKind == "blast" then    -- invite-all: straight guild invite, fast
          DoGuildInvite(name)
          if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
          GuildRecruiter_Settings.history[name] = { t = time(), p = GuildRecruiter_Settings.activeProfile }
          stats.invited = stats.invited + 1; stats.contacted = stats.contacted + 1
          TallyBump("invited")
          Print("Invited "..name.." ("..stats.invited..")")
        else
          Contact(name)
          Print("Contacted "..name.." ("..stats.contacted..")")
        end
        if GuildRecruiter_Settings.candidates then GuildRecruiter_Settings.candidates[name] = nil end  -- collected -> contacted
        inviteTimer = (GuildRecruiter_runKind == "blast") and INVITE_MIN or Pace(GuildRecruiter_Settings.inviteDelay)
      end
    end
  elseif not scanning then
    -- whisper-on-reply mode keeps running a while to catch late replies
    if GuildRecruiter_Settings.mode == "whisperinvite" and HasOutstandingWhispers() then
      -- keep waiting
    else
      running = false
      local kind = GuildRecruiter_runKind
      GuildRecruiter_runKind = nil
      SuppressWho(false)
      Broadcast("BYE")
      if kind == "blast" or kind == "send" then
        Print("Done. "..(kind == "blast" and "Invited " or "Contacted ")..stats.contacted.." of "..(GuildRecruiter_runTotal or stats.contacted)..". "..CountTable(GuildRecruiter_Settings.candidates).." candidate(s) remain.")
      elseif GuildRecruiter_Settings.collectOnly and stats.contacted == 0 then
        Print("Done collecting. List now has "..CountTable(GuildRecruiter_Settings.candidates).." candidate(s). Send them from the Lists tab.")
      else
        Print("Done. Contacted "..stats.contacted.." ("..stats.invited.." invited, "..stats.whispered.." whispered), skipped "..stats.guilded.." guilded, "..stats.queries.." queries.")
      end
    end
  end
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
  for n, w in whispered do
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
        SendNextWho()
        whoTimer = Pace(GuildRecruiter_Settings.whoDelay)
      end
    end
  end

  -- contacting / draining is its own global function so GR_OnUpdate stays well
  -- under Lua 5.0's 32-upvalue limit (this block alone references ~15 locals).
  GuildRecruiter_Drain(e)
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
  if running then Print("Already running. /gr stop to cancel"..(paused and ", /gr resume to continue." or ", /gr pause to pause.")) return end
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
  Print("Started ("..(MODE_LABEL[GuildRecruiter_Settings.mode] or "?")..") on levels "..myLo.."-"..myHi..". /gr stop to cancel.")
end

local function Stop()
  if not running then Print("Not running.") return end
  local wasSend = (GuildRecruiter_runKind ~= "scan")
  running, scanning, awaiting, paused = false, false, false, false
  GuildRecruiter_rescanWait = 0
  GuildRecruiter_runKind = nil
  SuppressWho(false)
  Broadcast("BYE")
  if wasSend then
    Print("Stopped. Invited "..stats.contacted.." this run; "..CountTable(GuildRecruiter_Settings.candidates).." candidate(s) remain on the list.")
  else
    Print("Stopped. Contacted "..stats.contacted.." this run; "..table.getn(contactQueue).." still queued.")
  end
end

-- Drain the persistent candidate list (built by Collect-only scans) through the
-- contact pipeline -- no scanning. blast=true => guild-invite EVERYONE as fast as
-- the server safely allows (ignores Mode); blast=false => paced, respects Mode.
-- GLOBAL so the slash + Lists buttons reach it.
function GuildRecruiter_SendToCandidates(blast)
  if not IsInGuild() then Print("You're not in a guild.") return end
  if running then Print("Already running -- /gr stop first"..(paused and " (or resume)." or ".")) return end
  Defaults()
  local s = GuildRecruiter_Settings
  local names = {}
  for n in s.candidates do tinsert(names, n) end
  if table.getn(names) == 0 then Print("No collected candidates. Turn on Collect (Settings) and scan first.") return end
  running, scanning, awaiting, paused = true, false, false, false
  GuildRecruiter_rescanWait = 0                          -- auto-rescan is scan-runs-only
  GuildRecruiter_runKind = blast and "blast" or "send"   -- fast invite-all vs paced send
  GuildRecruiter_runTotal = table.getn(names)            -- for N-of-M progress
  current = nil
  pending, contactQueue, replyQueue, seen, whispered = {}, {}, {}, {}, {}
  whoTimer, inviteTimer, whoTimeout, presenceTimer = 0, 0, 0, 0
  stats = { contacted=0, invited=0, whispered=0, guilded=0, scanned=0, queries=0, dropped=0, cooldown=0, collected=0 }
  for i = 1, table.getn(names) do tinsert(contactQueue, names[i]) end
  if s.guildSync and IsInGuild() then Broadcast("HI") end
  if blast then
    Print("Inviting all "..table.getn(names).." candidate(s) as fast as the server allows (auto-backs-off if throttled). /gr stop to cancel.")
  else
    Print("Sending to "..table.getn(names).." collected candidate(s) ("..(MODE_LABEL[s.mode] or "?").."). /gr stop to cancel.")
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

local function Pause()
  if not running then Print("Not running.") return end
  if paused then Print("Already paused. /gr resume to continue.") return end
  paused = true
  if GuildRecruiter_runKind == "scan" then
    SuppressWho(false)  -- let manual /who work normally while paused
    Broadcast("BYE")    -- yield my band to others while paused
  end
  Print("Paused. "..table.getn(contactQueue).." left. /gr resume to continue.")
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
-- List window: view/edit the contact queue, blacklist, and invite history
-- ---------------------------------------------------------------------------
local listFrame, listMode = nil, "queue"
local listData = {}
local NUM_ROWS, ROW_HEIGHT = 13, 18
local LIST_ORDER = { "candidates", "queue", "blacklist", "history", "negatives", "affirmatives" }
local LIST_TITLE = { candidates = "Candidates (collected)", queue = "Queue (this run)", blacklist = "Blacklist",
  history = "Invite history", negatives = "Refusal words (no)", affirmatives = "Yes words (yesonly mode)" }

local function BuildListData()
  listData = {}
  if listMode == "candidates" then
    for n in GuildRecruiter_Settings.candidates do tinsert(listData, n) end
    table.sort(listData)
  elseif listMode == "queue" then
    for i = 1, table.getn(contactQueue) do tinsert(listData, contactQueue[i]) end
  elseif listMode == "blacklist" then
    for n in GuildRecruiter_Settings.blacklist do tinsert(listData, n) end
    table.sort(listData)
  elseif listMode == "negatives" then
    for n in GuildRecruiter_Settings.negatives do tinsert(listData, n) end
  elseif listMode == "affirmatives" then
    for n in GuildRecruiter_Settings.affirmatives do tinsert(listData, n) end
    table.sort(listData)
  else
    for n in GuildRecruiter_Settings.history do tinsert(listData, n) end
    table.sort(listData)
  end
end

local function RemoveListItem(name)
  if listMode == "candidates" then
    GuildRecruiter_Settings.candidates[name] = nil
  elseif listMode == "queue" then
    for i = 1, table.getn(contactQueue) do
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
function GuildRecruiter_InviteOne(name)
  if not name then return end
  if not IsInGuild() then Print("You're not in a guild.") return end
  if running then Print("A run is active -- stop it first to invite individually.") return end
  DoGuildInvite(name)
  if not GuildRecruiter_Settings.history then GuildRecruiter_Settings.history = {} end
  GuildRecruiter_Settings.history[name] = { t = time(), p = GuildRecruiter_Settings.activeProfile }
  if GuildRecruiter_Settings.candidates then GuildRecruiter_Settings.candidates[name] = nil end
  TallyBump("invited")
  Print("Invited "..name..".")
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
    fr.hint:SetText((paused and "|cffffcc00Paused|r -- " or ("|cff40ff40"..verb.."|r  "))..prog)
  else
    fr.lpauseBtn:Hide(); fr.lstopBtn:Hide()
    fr.inviteBtn:Show(); fr.sendBtn:Show()
    local cc = CountTable(GuildRecruiter_Settings.candidates or {})
    fr.inviteBtn:SetText("Invite all ("..cc..")")
    if cc > 0 then fr.inviteBtn:Enable(); fr.sendBtn:Enable() else fr.inviteBtn:Disable(); fr.sendBtn:Disable() end
    fr.hint:SetText(listMode == "candidates"
      and "left-click a name to invite it -- right-click to drop it" or LIST_HINT)
  end
end

local function BuildListsPanel(parent)
  local fr = CreateFrame("Frame", "GuildRecruiterList", parent)
  fr:SetAllPoints(parent)
  fr.rows = {}

  fr.cycle = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.cycle:SetPoint("TOP", 0, -38); fr.cycle:SetWidth(260); fr.cycle:SetHeight(22)
  fr.cycle:SetScript("OnClick", function()
    GuildRecruiter_OpenMenu(this, LIST_ORDER, LIST_TITLE, function(v) listMode = v; UpdateList() end)
  end)
  GuildRecruiter_DDArrow(fr.cycle)

  fr.hint = fr:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  fr.hint:SetPoint("TOP", 0, -62); fr.hint:SetText(LIST_HINT)

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
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function()
      if not this.pname then return end
      local nm = this.pname
      if listMode == "candidates" then
        if arg1 == "RightButton" then RemoveListItem(nm)               -- drop a false positive
        else GuildRecruiter_InviteOne(nm) end                          -- left-click invites this one
        UpdateList()
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
  addEdit:SetScript("OnEnterPressed", function() doAdd(); this:ClearFocus() end)
  addEdit:SetScript("OnEscapePressed", function() this:ClearFocus() end)

  -- act on the collected candidate list: Invite all (fast guild invites) or
  -- Send (paced, respects Mode -- e.g. a whisper campaign)
  fr.inviteBtn = CreateFrame("Button", nil, fr, "UIPanelButtonTemplate")
  fr.inviteBtn:SetPoint("BOTTOMRIGHT", -16, 18); fr.inviteBtn:SetWidth(160); fr.inviteBtn:SetHeight(22)
  fr.inviteBtn:SetScript("OnClick", function()
    local cnt = CountTable(GuildRecruiter_Settings.candidates)
    if cnt == 0 then Print("No collected candidates yet. Turn on Collect (Settings) and scan.") return end
    GuildRecruiter_Confirm("Invite all "..cnt.." collected candidate(s) now? Guild invites go out as fast as the server allows.",
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
  -- keep the run strip / launch buttons live while this tab is shown
  fr.ltick = 0
  fr:SetScript("OnUpdate", function()
    fr.ltick = fr.ltick - (arg1 or 0)
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
  local n = table.getn(listData)
  local offset = FauxScrollFrame_GetOffset(listFrame.scroll)
  for i = 1, NUM_ROWS do
    local idx = offset + i
    local row = listFrame.rows[i]
    if idx <= n then
      local nm = listData[idx]
      row.pname = nm
      local disp = nm
      if listMode == "history" then
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
  FauxScrollFrame_Update(listFrame.scroll, n, NUM_ROWS, ROW_HEIGHT)
  listFrame.cycle:SetText("View: "..(LIST_TITLE[listMode] or listMode).."  ("..n..")")
  GuildRecruiter_ListControls(listFrame)   -- idle launch buttons vs live run strip
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
  sl:SetWidth(168); sl:SetHeight(16)
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

-- a categorised section subheading (gold caption + a faint underline) so option
-- panels are always grouped, never a flat wall of controls
local function Header(parent, text, x, y, w)
  local h = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  h:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  h:SetText(text); h:SetTextColor(1, 0.82, 0)
  local ln = parent:CreateTexture(nil, "ARTWORK")
  ln:SetTexture(1, 0.82, 0, 0.3)
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
  if mode == "invite" then
    configFrame.modeNote:SetText("Invite-only: sends a guild invite straight away. Reply & Message aren't used.")
  elseif mode == "whisper" then
    configFrame.modeNote:SetText("Whisper-only: just messages them. Method & Reply aren't used.")
  else
    configFrame.modeNote:SetText("Whisper, then invite when they reply (per the Reply rule).")
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
  local pend = table.getn(pending)
  return b.."  (query "..stats.queries..(pend > 0 and (", +"..pend.." queued") or "")..")"
end

local function StatusLine()
  if not running then return "Idle." end
  -- sweep position: where the band cursor sits (@lvl) and the current band width
  local pos = "band "..myLo.."-"..myHi.." @"..lo.." w"..width
  if paused then return "Paused -- /who "..GuildRecruiter_ScanNow().." | "..pos.." | queued "..table.getn(contactQueue) end
  if (GuildRecruiter_rescanWait or 0) > 0 then
    return "rescanning in "..math.ceil(GuildRecruiter_rescanWait).."s | "..pos
         .." | queued "..table.getn(contactQueue).." | sent "..stats.contacted
  end
  if scanning and GuildRecruiter_Settings.collectOnly then
    return "collecting  /who "..GuildRecruiter_ScanNow().."  "..pos
         .."  collected "..stats.collected.." (list "..CountTable(GuildRecruiter_Settings.candidates)..")"
  end
  if scanning then
    return "scan  /who "..GuildRecruiter_ScanNow().."  "..pos
         .."  queued "..table.getn(contactQueue).." sent "..stats.contacted
         ..(stats.dropped > 0 and (" drop "..stats.dropped) or "")
         ..(CountTable(recruiters) > 0 and (" peers "..CountTable(recruiters)) or "")
  end
  return "draining  queued "..table.getn(contactQueue).." | sent "..stats.contacted
       .." ("..stats.invited.." inv, "..stats.whispered.." wh) | peers "..CountTable(recruiters)
end

-- GLOBAL on purpose: the settings-tab reply-mode button calls this, so its
-- OnClick closure references a global (not a local) and adds no upvalue to
-- BuildSettingsPanel, which sits near Lua 5.0's 32-upvalue-per-function limit.
function GuildRecruiter_CycleReplyMode()
  local cur, idx = GuildRecruiter_Settings.replyMode or "notno", 1
  for i = 1, table.getn(REPLY_ORDER) do if REPLY_ORDER[i] == cur then idx = i end end
  idx = idx + 1; if idx > table.getn(REPLY_ORDER) then idx = 1 end
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
  local p = CreateFrame("Frame", "GuildRecruiterDDPopup", UIParent)
  p:SetFrameStrata("FULLSCREEN_DIALOG")
  p:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  p:EnableMouse(true); p:Hide()
  p.opts = {}
  for i = 1, 6 do
    local ob = CreateFrame("Button", nil, p)
    ob:SetHeight(16)
    ob:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 16)
    ob:SetPoint("RIGHT", p, "RIGHT", -6, 0)
    local ht = ob:CreateTexture(nil, "HIGHLIGHT")
    ht:SetAllPoints(ob); ht:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    ht:SetBlendMode("ADD"); ht:SetAlpha(0.5)
    local t = ob:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    t:SetPoint("LEFT", 4, 0); t:SetPoint("RIGHT", -4, 0); t:SetJustifyH("LEFT"); ob.text = t
    ob:SetScript("OnClick", function()
      if this.cb then this.cb(this.value)          -- generic menu (e.g. Lists view)
      else this.target[this.key] = this.value end  -- settings/variant dropdown
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
  local n = table.getn(order)
  for i = 1, 6 do
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
  local f = CreateFrame("Frame", "GuildRecruiterMsgEditor", UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetWidth(430); f:SetHeight(200); f:SetPoint("CENTER", 0, 80)
  f:SetBackdrop({
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

  local box = CreateFrame("Frame", nil, f)
  box:SetPoint("TOPLEFT", 18, -58); box:SetPoint("TOPRIGHT", -18, -58); box:SetHeight(80)
  box:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  box:SetBackdropColor(0, 0, 0, 0.6)

  local eb = CreateFrame("EditBox", "GuildRecruiterMsgEditBox", box)
  eb:SetPoint("TOPLEFT", 8, -6); eb:SetPoint("BOTTOMRIGHT", -8, 6)
  if eb.SetMultiLine then eb:SetMultiLine(true) end
  eb:SetFont("Fonts\\FRIZQT__.TTF", 12)
  eb:SetMaxLetters(255); eb:SetAutoFocus(false); eb:SetTextInsets(2, 2, 2, 2)
  eb:SetScript("OnEscapePressed", function() f:Hide() end)
  f.eb = eb

  f.countFS = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  f.countFS:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -4)
  eb:SetScript("OnTextChanged", function() f.countFS:SetText(string.len(this:GetText()).."/255") end)

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
  fr.methodBtn:SetScript("OnClick", function() GuildRecruiter_OpenDD(this, "method") end)
  GuildRecruiter_DDArrow(fr.methodBtn)
  Label(fr, "Mode:", 298, -108)
  fr.modeBtn = CreateFrame("Button", "GuildRecruiterConfigModeBtn", fr, "UIPanelButtonTemplate")
  fr.modeBtn:SetPoint("TOPLEFT", 352, -104); fr.modeBtn:SetWidth(186); fr.modeBtn:SetHeight(22)
  fr.modeBtn:SetScript("OnClick", function() GuildRecruiter_OpenDD(this, "mode") end)
  GuildRecruiter_DDArrow(fr.modeBtn)
  Label(fr, "Reply:", 298, -134)
  fr.replyBtn = CreateFrame("Button", "GuildRecruiterConfigReplyBtn", fr, "UIPanelButtonTemplate")
  fr.replyBtn:SetPoint("TOPLEFT", 352, -130); fr.replyBtn:SetWidth(186); fr.replyBtn:SetHeight(22)
  fr.replyBtn:SetScript("OnClick", function() GuildRecruiter_OpenDD(this, "reply") end)
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
  barbg:SetAllPoints(fr.bar); barbg:SetTexture(0, 0, 0, 0.4)
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
  fr.autoScanCheck:SetScript("OnEnter", function()
    GameTooltip:SetOwner(this, "ANCHOR_TOPLEFT")
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
  fr:SetScript("OnUpdate", function()
    fr.tick = fr.tick - (arg1 or 0)
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
    else fr.barText:SetText("Sending queued contacts ("..table.getn(contactQueue).." left)") end
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
    for k, x in v do c[k] = CopyValue(x) end
    return c
  end
  return v
end

local function SaveProfile(name)
  if not name or name == "" then return false end
  GuildRecruiter_Settings.profiles = GuildRecruiter_Settings.profiles or {}
  local p = {}
  for i = 1, table.getn(PROFILE_KEYS) do
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
  for i = 1, table.getn(PROFILE_KEYS) do
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
  pedit:SetScript("OnEscapePressed", function() this:ClearFocus() end)
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
  fr:SetScript("OnUpdate", function()
    fr.tick = fr.tick - (arg1 or 0)
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
  for d in t.days do tinsert(keys, d) end
  table.sort(keys)
  local n = table.getn(keys)
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
               .."  (A + "..table.getn(s.abVariants or {}).." variant(s), * = active)")
  -- names currently in the live A/B test: "A" (control) + each challenger
  local active = {}
  if GuildRecruiter_ABActive() then
    active["A"] = true
    for j = 1, table.getn(s.abVariants) do active[s.abVariants[j].name] = true end
  end
  local vs = s.varStats or {}
  local vnames = {}
  for v in vs do tinsert(vnames, v) end
  table.sort(vnames)
  if table.getn(vnames) == 0 then
    tinsert(lines, "no per-variant data yet -- run an A/B test (A/B tab) or load profiles, then recruit")
  else
    for i = 1, table.getn(vnames) do
      if i > 6 then tinsert(lines, "(+"..(table.getn(vnames) - 6).." more)"); break end
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
    for nm in GuildRecruiter_Settings.profiles do tinsert(pnames, nm) end
  end
  table.sort(pnames)
  statsFrame.profileText:SetText("Active profile: |cff33ff99"..(GuildRecruiter_Settings.activeProfile or "(unsaved)")
    .."|r\nSaved: "..(table.getn(pnames) > 0 and table.concat(pnames, ", ") or "(none)"))
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
    if table.getn(av) >= MAX_CHAL then return end
    local s = GuildRecruiter_Settings
    local used = {}
    for i = 1, table.getn(av) do used[av[i].name] = true end
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
  cr.wtBtn:SetScript("OnClick", function() GuildRecruiter_BumpWeight(nil, arg1 == "RightButton" and -1 or 1) end)
  cr.wtBtn:SetScript("OnEnter", function() GuildRecruiter_WeightTip(this) end)
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
    rm:SetScript("OnClick", function() tremove(GuildRecruiter_Settings.abVariants, this.idx); RefreshABPanel() end)
    local md = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    md:SetPoint("TOPLEFT", 14, -22); md:SetWidth(150); md:SetHeight(20)
    md:SetScript("OnClick", function() GuildRecruiter_OpenDD(this, "mode", this.variant) end)
    GuildRecruiter_DDArrow(md); row.modeBtn = md
    local rp = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rp:SetPoint("LEFT", md, "RIGHT", 8, 0); rp:SetWidth(150); rp:SetHeight(20)
    rp:SetScript("OnClick", function() GuildRecruiter_OpenDD(this, "reply", this.variant) end)
    GuildRecruiter_DDArrow(rp); row.replyBtn = rp
    local mb = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    mb:SetPoint("LEFT", rp, "RIGHT", 8, 0); mb:SetWidth(140); mb:SetHeight(20); mb:SetText("Edit message...")
    mb:SetScript("OnClick", function() GuildRecruiter_EditMessage(this.variant) end)
    row.msgBtn = mb
    local wb = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    wb:SetPoint("TOPLEFT", 16, -46); wb:SetWidth(132); wb:SetHeight(20)
    wb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    wb:SetScript("OnClick", function() GuildRecruiter_BumpWeight(this.variant, arg1 == "RightButton" and -1 or 1) end)
    wb:SetScript("OnEnter", function() GuildRecruiter_WeightTip(this) end)
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
  local n = table.getn(av)               -- challenger count
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
  for n, p in tabPanels do if n == name then p:Show() else p:Hide() end end
  for n, b in tabButtons do
    if n == name then b:LockHighlight() else b:UnlockHighlight() end
  end
  if name == "settings" then RefreshConfig()
  elseif name == "lists" then UpdateList()
  elseif name == "stats" then RefreshStats()
  elseif name == "ab" then RefreshABPanel() end
end

local function BuildUI()
  local m = CreateFrame("Frame", "GuildRecruiterUI", UIParent)
  m:SetWidth(560); m:SetHeight(470)
  m:SetPoint("CENTER", 0, 0)
  m:SetFrameStrata("DIALOG")
  m:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  m:EnableMouse(true); m:SetMovable(true); m:RegisterForDrag("LeftButton")
  m:SetScript("OnDragStart", function() this:StartMoving() end)
  m:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  m:SetScript("OnHide", function() if ddPopup then ddPopup:Hide() end end)  -- no orphan dropdown
  m:SetScript("OnUpdate", function() GuildRecruiter_HeaderTick(this, arg1) end)  -- run state on every tab
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
  for i = 1, table.getn(TAB_DEFS) do
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
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
  GameTooltip:AddLine("Right-click: "..(running and "stop" or "start"), 1, 1, 1)
  GameTooltip:Show()
end

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
    GuildRecruiter_MinimapTip(this)
    -- keep the tooltip live while hovering, so status updates in real time
    this.tipTick = 0
    this:SetScript("OnUpdate", function()
      this.tipTick = (this.tipTick or 0) + (arg1 or 0)
      if this.tipTick < 0.3 then return end
      this.tipTick = 0
      GuildRecruiter_MinimapTip(this)   -- OnLeave clears this OnUpdate, so it only runs while hovered
    end)
  end)
  mb:SetScript("OnLeave", function()
    this:SetScript("OnUpdate", nil)
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
      if GuildRecruiter_Settings.profiles then for nm in GuildRecruiter_Settings.profiles do names = names..nm..", " end end
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
      for p in GuildRecruiter_Settings.negatives do a = a..p..", " end
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
      for p in GuildRecruiter_Settings.affirmatives do a = a..p..", " end
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
      Print("Simultaneous A/B "..(GuildRecruiter_Settings.abOn and "ON" or "OFF").."  (A + "..table.getn(GuildRecruiter_Settings.abVariants).." variant(s)).")
    elseif sub == "clear" then
      GuildRecruiter_Settings.abVariants = {}; GuildRecruiter_RefreshOpen(); Print("A/B variants cleared (variant A = your Settings is unaffected).")
    else
      GuildRecruiter_ToggleAB()   -- open the A/B tab to set variants up
    end
  elseif cmd == "reset" then
    seen = {}; Print("Cleared this session's scan list (history kept).")
  elseif cmd == "debug" then
    GuildRecruiter_Settings.debug = (larg == "on") or (larg ~= "off" and not GuildRecruiter_Settings.debug)
    Print("Scan debug: "..(GuildRecruiter_Settings.debug and "ON (prints each /who's result count + learned cap)" or "OFF"))
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
    Print("autoscan on|off (loop scanning) | autoscan <seconds> (rest between cycles)")
    Print("collect on|off (scan into a list) | inviteall (fast) | send (paced) | invite <name> | candidates | clearlist")
    Print("set invite/who/reinvite/cap/min/max/method/mode <v> | msg <text> | class <list|all>")
    Print("profile save/load/delete/list <name> | replymode notno/yesonly/any | ab (open tab) /on/off/clear")
    Print("noword/yesword add/remove/list <phrase>")
    Print("black add/remove/list <name> | jitter/sync/combat/instance/quiet [on|off]")
  end
end

-- (init happens on VARIABLES_LOADED, once SavedVariables are actually loaded)
