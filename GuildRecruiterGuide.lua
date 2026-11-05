--[[ Guild Rawcruiter -- the guide window (WoW: Forever build)

  One window, GuildRecruiterGuide, for someone who has never used the addon:
    * first run: three setup cards (approach, message, chat tab) with Back / Next;
    * after that, the live guide: ONE "What to do now" line, ONE big button that
      does that step, the four steps to invite the people who said yes (each one
      ticks itself from what the game shows), the few settings that matter, and
      a "Today" line. Everything else is under "Advanced..." (the old window).
  Opened by /gr, /gr guide, a left-click on the minimap button, and by itself at
  login until the player ticks "Don't show again".

  RULES (each one proven by a failure on a real Forever client; PORT_NOTES.md):
    * This file only READS Blizzard state: IsShown, StaticPopup_Visible,
      GetChatWindowInfo (GR_Compat.ListFrame), GetBindingKey, IsInGuild ... It
      never calls an invite function, SetItemRef or StaticPopup_Show, never
      touches the chat edit box, never writes to a Blizzard frame and never sets
      a script on one.
    * Anything that ACTS on a Blizzard window (open the Guild window, show the
      Rawcruiter chat tab) goes through a SECURE button the player clicks
      (SecureActionButtonTemplate, type "click": the template's own secure code
      calls :Click() on the Blizzard button). Attributes are set out of combat
      only. There is NO secure button for Invite Member: it has no global name.
    * The guide window is a plain frame. Its secure buttons are separate frames,
      parented and anchored to UIParent only, laid over plain placeholder slots
      in the window. Anchoring a secure frame to the window (or parenting it)
      would make the window protected: no moving or closing it in combat.
    * Secure buttons are hidden at PLAYER_REGEN_DISABLED (just before lockdown)
      and come back after combat. In combat the plain buttons and hints are used.
  Everything here is a global GuildRecruiter_Guide* function or a field on our
  own frames, so the main file's locals and upvalues are not touched.
]]--

local ADDON_NAME, ns = ...
ADDON_NAME = ADDON_NAME or "GuildRecruiter"
local GR_Compat = (type(ns) == "table" and ns.Compat) or GuildRecruiter_Compat
if not GR_Compat then return end   -- the main file did not load: nothing to guide

local GUIDE_W, GUIDE_H = 380, 500
local TICK_ON  = "Interface\\Buttons\\UI-CheckBox-Check"   -- both used by Blizzard's own UI code
local TICK_BOX = "Interface\\Buttons\\UI-CheckBox-Up"
local SAMPLE   = "Sam"                                     -- the player name in message previews

-- ready-made whispers: %p = their name, %g = your guild (WhisperBody caps the result at 255)
local TEMPLATES = {
  { title = "Short",            text = "Hi %p! Want an invite to <%g>? Just whisper back. :)" },
  { title = "Friendly",         text = "Hi %p! <%g> is a friendly, active guild: we level together, run dungeons and help each other out. Want to join? Whisper me yes and I'll send an invite." },
  { title = "Dungeons & raids", text = "Hey %p! <%g> is building groups for dungeons and raids. If you'd like a guild to play with, whisper me yes and I'll invite you. No pressure!" },
}

-- the two approaches: presets only (the sliders stay under Advanced)
local PRESETS = {
  whisperinvite = { mode = "whisperinvite", inviteDelay = 5, jitter = true, sessionCap = 30, replyMode = "notno" },
  invite        = { mode = "invite" },
}
local APPROACH = { whisperinvite = "Whisper first", invite = "Direct", whisper = "Whisper only" }

local autoShown = false   -- opened by itself once this session (PLAYER_ENTERING_WORLD)

-- ---------------------------------------------------------------------------
-- small builders (our own frames only)
-- ---------------------------------------------------------------------------
local function Plural(n, one, many) if n == 1 then return one end return many end

local function Text(parent, font, x, y, w, h)
  local fs = parent:CreateFontString(nil, "ARTWORK", font)
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  if w then fs:SetWidth(w) end
  if h then fs:SetHeight(h) end
  fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP")
  return fs
end

-- a plain button with a one-line tooltip (b.tip); the caller sets its OnClick
local function Btn(parent, w, h, label, tip)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetWidth(w); b:SetHeight(h); b:SetText(label)
  b.tip = tip
  b:SetScript("OnEnter", GuildRecruiter_GuideTip)
  b:SetScript("OnLeave", GuildRecruiter_GuideTipHide)
  return b
end

-- an empty box with a tick laid over it (tick:Show() = done)
local function TickBox(parent, size)
  local box = parent:CreateTexture(nil, "ARTWORK")
  box:SetTexture(TICK_BOX); box:SetWidth(size); box:SetHeight(size)
  local tick = parent:CreateTexture(nil, "OVERLAY")
  tick:SetTexture(TICK_ON); tick:SetAllPoints(box)
  tick:Hide()
  return box, tick
end

-- a two-digit number box; applies on Enter or when it loses focus
local function NumBox(parent, name, x, y, tip)
  local e = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
  e:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  e:SetWidth(28); e:SetHeight(20)
  e:SetAutoFocus(false); e:SetNumeric(true); e:SetMaxLetters(2)
  e.tip = tip
  e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEscapePressed", function(self) self.cancel = true; self:ClearFocus() end)
  e:SetScript("OnEditFocusLost", function(self) GuildRecruiter_GuideLevelBox(self) end)
  e:SetScript("OnEnter", GuildRecruiter_GuideTip)
  e:SetScript("OnLeave", GuildRecruiter_GuideTipHide)
  return e
end

-- display text: a typed "|" must not start an escape code
local function Plain(s) return (string.gsub(tostring(s or ""), "|", "||")) end

function GuildRecruiter_GuideTip(frame)
  local t = frame and frame.tip
  if type(t) ~= "string" or t == "" then return end
  GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
  GameTooltip:AddLine(t, 1, 1, 1, 1)
  GameTooltip:Show()
end
function GuildRecruiter_GuideTipHide() GameTooltip:Hide() end

-- one chat line, once per session, if the guide itself fails (never the run)
function GuildRecruiter_GuideError(err)
  if GR_Compat.guideErrored then return end
  GR_Compat.guideErrored = true
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff8000Rawcruiter:|r guide window error (recruiting is not affected): "..tostring(err))
  end
end

-- ---------------------------------------------------------------------------
-- saved fields (seed-once: an existing value is never changed here)
-- ---------------------------------------------------------------------------
function GuildRecruiter_GuideSeed()
  local s = GuildRecruiter_Settings
  if type(s) ~= "table" then return end
  if s.guideSeen == nil then s.guideSeen = false end                -- "Don't show again": no opening by itself
  if s.guideDone == nil then s.guideDone = false end                -- the setup cards were finished
  if type(s.guideCards) ~= "table" then s.guideCards = {} end       -- ticks on setup cards 1 and 2
  -- s.guidePos is written only when the window is dragged (like readyPos)
end

-- ---------------------------------------------------------------------------
-- READ-ONLY detectors (polled while the window is shown)
-- ---------------------------------------------------------------------------
-- Each field only READS Blizzard state:
--   guildOpen  CommunitiesFrame:IsShown() (or a classic GuildFrame:IsShown())
--   popup      StaticPopup_Visible("ADD_GUILDMEMBER")                 (Invite Member)
--   finder     StaticPopup_Visible("ADD_GUILDMEMBER_WITH_FINDER_LINK") (its Guild Finder twin)
--   tabFrame   GR_Compat.ListFrame(): the chat frame whose tab is named "Rawcruiter"
--   tabShown   that chat frame:IsVisible() (docked and selected, or floating)
--   sent       GR_Compat.lastInvite, set by the C_GuildInfo.Invite post-hook
--              (GR_Compat.OnInviteSent), for 8 seconds after an invite
function GuildRecruiter_GuideSteps()
  local r = {}
  local cf, gf = CommunitiesFrame, GuildFrame
  r.guildOpen = ((cf and cf.IsShown and cf:IsShown()) or (gf and gf.IsShown and gf:IsShown())) and true or false
  if type(StaticPopup_Visible) == "function" then
    r.popup  = StaticPopup_Visible("ADD_GUILDMEMBER") and true or false
    r.finder = StaticPopup_Visible("ADD_GUILDMEMBER_WITH_FINDER_LINK") and true or false
  end
  local lf = GR_Compat.ListFrame()
  r.tabFrame = lf
  r.tabShown = (lf and lf:IsVisible()) and true or false
  local li = GR_Compat.lastInvite
  if li and GetTime() - (li.t or 0) < 8 then r.sent = li end
  return r
end

local function IsTrial()
  return ((type(IsTrialAccount) == "function" and IsTrialAccount())
       or (type(IsVeteranTrialAccount) == "function" and IsVeteranTrialAccount())) and true or false
end

-- what the client refused, in plain words, from the block report line
local function BlockWhat(line)
  if type(line) ~= "string" then return "an action" end
  if string.find(line, "SendWho", 1, true) then return "the /who search" end
  if string.find(line, "SendChatMessage", 1, true) then return "a whisper" end
  if string.find(line, "nvite", 1, true) then return "an invite" end
  return "an action"
end

-- What to do now: ONE headline, a sub line, a warning line, and what the ONE big
-- button does (action "start" | "resume" | "next" | nil), its label and whether
-- it is enabled. READ-ONLY: GuildRecruiter_NextStep and GuildRecruiter_RunState
-- change nothing (NextStep never deals the A/B variant).
function GuildRecruiter_GuideState()
  local s = GuildRecruiter_Settings
  local st = { label = "Start", enabled = false }
  local rs = GuildRecruiter_RunState()
  st.running, st.paused = rs.running, rs.paused
  local hw = GR_Compat.RequiresHardwareEvent
  local combat = GR_Compat.InCombat()
  if combat then st.warn = "In combat: the Open and Show buttons come back when it ends."
  elseif IsTrial() then st.warn = "Trial account: the game limits trial chat and addon messages, so some steps may not work." end

  if not IsInGuild() then
    st.headline = "Join a guild first"
    st.sub = "Guild Rawcruiter recruits for your guild, so you need to be in one."
    st.tip = "You need to be in a guild to recruit for it."
    return st
  end
  -- (only once the guild's data has arrived: right after login the rank may not be known yet)
  if s.mode ~= "whisper" and GetGuildInfo("player") and not GR_Compat.CanGuildInvite() then
    st.headline = "Your rank can't invite people -- ask an officer"
    st.sub = "An officer can give your rank the Invite permission in the guild's settings."
    st.tip = "Your guild rank has no Invite permission."
    return st
  end

  local act, wait, _, short, inv = GuildRecruiter_NextStep()
  wait = math.ceil(wait or 0)
  local head, sub
  if not rs.running and act == "one" then
    -- a single invite set from the Lists tab (/gr invite): one press shows it
    head, sub = "Press Next for that player's name", "It goes on your list; then invite them with the steps below."
    st.action, st.label, st.enabled = "next", short or "Next", not combat
    st.tip = "Shows the name you picked in the Lists tab."
  elseif not rs.running then
    head = "Press Start"
    sub = "Looks for players with no guild ("..(APPROACH[s.mode] or tostring(s.mode))..", levels "..(s.minLevel or 1).."-"..(s.maxLevel or 60)..")."
    st.action, st.label, st.enabled = "start", "Start", true
    st.tip = hw and "Start a run. Nothing is sent until you press Next." or "Start a run."
  elseif rs.paused then
    head = GR_Compat.pausedByBlock and ("Paused: the game blocked "..BlockWhat(GR_Compat.blockLine)) or "Paused"
    sub = GR_Compat.pausedByBlock and "Press Resume to try again, or Stop to end the run." or "Press Resume to carry on, or Stop to end the run."
    st.action, st.label, st.enabled = "resume", "Resume", true
    st.tip = "Carry on from where the run stopped."
  elseif not hw then
    head, sub = "Running -- the addon searches and contacts by itself", "Press Pause or Stop at any time."
    st.label = "Running"
  elseif act == "who" then
    st.action = "next"
    st.tip = "Sends one /who search for players with no guild. The game allows one per click or key press."
    if rs.rest > 0 then
      head, sub = "Resting "..wait.."s before the next search -- nothing to do", "Auto-rescan waits between sweeps to catch players who log in later."
      st.label = "Next search in "..wait.."s"
    elseif rs.awaiting then
      head, sub = "Searching -- waiting for the game's answer", "The players it finds are whispered by themselves."
      st.label = "Searching..."
    elseif wait > 0 then
      head, sub = "Next search in "..wait.."s", "Each press of Next sends one /who search."
      st.label = "Next search in "..wait.."s"
    else
      head, sub = "Press Next to search for players", "Each press sends one /who search; the game allows one per click or key press."
      st.label, st.enabled = "Next: search", true
    end
  elseif act == "contact" then
    st.action = "next"
    st.tip = "Direct: gives you the next player to invite (it goes on your list)."
    sub = "Direct: each press gives you one name to invite yourself."
    if inv and combat then head, st.label = "In combat -- the next name waits until it ends", "After combat"
    elseif wait > 0 then head, st.label = "Next name in "..wait.."s", "Next in "..wait.."s"
    else head, st.label, st.enabled = "Press Next for the next player to invite", "Next: "..(short or "name"), true end
  elseif short and string.find(short, "^Whispering") then
    head = "Whispering "..rs.queued.." "..Plural(rs.queued, "player", "players").." -- nothing to do"
    sub = "Whispers go out by themselves every few seconds. The next search comes after them."
    st.label = "Whispering..."
  elseif short and string.find(short, "^Held: ") then
    head = "On hold: "..string.sub(short, 7)
    sub = "Sending waits while you are in combat or an instance, or while the server slows us down."
    st.label = "On hold"
  elseif short == "Cap reached" then
    head = "Reached your limit of "..rs.cap.." for this run"
    sub = "The run is ending. Press Start again later for more."
    st.label = "Limit reached"
  elseif short == "Sweep done" then
    head, sub = "Search finished -- waiting for replies", "Every level in your range was searched. Replies can still come in."
    st.label = "Waiting for replies"
  else
    head, sub = "Waiting for replies -- nothing to do", "Whispers are out. Anyone who says yes shows up below."
    st.label = "Waiting for replies"
  end

  local n, yes = GuildRecruiter_ReadyCount(), 0
  for _, e in pairs(s.ready or {}) do
    if type(e) == "table" and e.kind == "reply" then yes = yes + 1 end
  end
  if n > 0 then
    -- "said yes" only when they did: a Direct prompt (kind invite) never replied
    st.headline = n.." "..Plural(n, "person", "people")..((yes == n) and " said yes -- invite them below"
      or " waiting for your invite -- see below")
    st.sub = "Meanwhile: "..head
  else
    st.headline, st.sub = head, sub
  end
  return st
end

-- ---------------------------------------------------------------------------
-- actions (all plain addon code; the big button's press reuses the Next code)
-- ---------------------------------------------------------------------------
-- The ONE big button. secure = the click came through the secure twin
-- (GuildRecruiterGuideNext, its PreClick) rather than the plain button.
-- A "next" step is exactly the existing press: the secure Next button's
-- PreClick code (GuildRecruiter_SecurePreClick), or /gr next for the plain
-- button. Nothing is duplicated.
function GuildRecruiter_GuidePress(btn, button, down, secure)
  if down then return end
  local st = GuildRecruiter_GuideState()
  if st.action == "start" then
    GuildRecruiter_StartRun()
  elseif st.action == "resume" then
    GuildRecruiter_TogglePause()
  elseif st.action == "next" and st.enabled then
    if secure then GuildRecruiter_SecurePreClick(btn, button, down)
    else GuildRecruiter_Next() end
  end
end

function GuildRecruiter_GuideApproach(mode)
  local p = PRESETS[mode]
  if not p then return end
  GuildRecruiter_GuideSeed()
  local s = GuildRecruiter_Settings
  for k, v in pairs(p) do s[k] = v end
  s.guideCards.approach = true
  GuildRecruiter_RefreshOpen()          -- the Advanced window shows the same values
  GuildRecruiter_GuideRefresh()
end

function GuildRecruiter_GuideTemplate(i)
  local t = TEMPLATES[i]
  if not t then return end
  GuildRecruiter_GuideSeed()
  GuildRecruiter_Settings.whisperMsg = t.text
  GuildRecruiter_Settings.guideCards.message = true
  GuildRecruiter_RefreshOpen()
  GuildRecruiter_GuideRefresh()
end

function GuildRecruiter_GuideOwnMessage()
  GuildRecruiter_GuideSeed()
  GuildRecruiter_Settings.guideCards.message = true
  GuildRecruiter_EditMessage(GuildRecruiter_Settings)   -- the existing message editor
end

-- a level box lost focus: apply it through the same setters as the Settings tab
function GuildRecruiter_GuideLevelBox(box)
  if box.cancel then box.cancel = nil; return end   -- Esc: the next refresh puts the saved value back
  local v = tonumber(box:GetText())
  local s = GuildRecruiter_Settings
  if not v then return end
  if box.isMax then
    if v ~= s.maxLevel then GuildRecruiter_SetMaxLevel(v) end
  elseif v ~= s.minLevel then
    GuildRecruiter_SetMinLevel(v)
  end
end

-- no Rawcruiter tab: print the waiting names (oldest first, at most 5) as links
-- in the main chat, one line each (GR_Compat.PrintLink, the existing prompt line)
function GuildRecruiter_GuidePrintNames()
  local names = GuildRecruiter_ReadyNames()
  local shown = 0
  for i = #names, 1, -1 do
    GR_Compat.PrintLink(names[i])
    shown = shown + 1
    if shown >= 5 then break end
  end
end

function GuildRecruiter_GuideMakeTab()
  GR_Compat.MakeChatTab()                       -- /gr chattab (Blizzard's FCF_OpenNewWindow), then /reload
  local g = GuildRecruiterGuide
  if g and GR_Compat.ListFrame() then g.madeTab = true end
  GuildRecruiter_GuideRefresh()
end

function GuildRecruiter_GuideReload()
  GuildRecruiter_Settings.guideDone = true      -- after the reload, open on the live guide
  local fn = (C_UI and C_UI.Reload) or ReloadUI
  if type(fn) == "function" then pcall(fn) end
end

function GuildRecruiter_GuideCard(n)
  local g = GuildRecruiterGuide
  if not g then return end
  if n < 1 then n = 1 elseif n > 3 then n = 3 end
  g.card = n
  GuildRecruiter_GuideRefresh()
end

function GuildRecruiter_GuideFinish()
  GuildRecruiter_Settings.guideDone = true
  local g = GuildRecruiterGuide
  if g then g.view = "live"; g.single = false end
  GuildRecruiter_GuideRefresh()
end

function GuildRecruiter_GuideNextCard()
  local g = GuildRecruiterGuide
  if not g then return end
  if g.single or (g.card or 1) >= 3 then GuildRecruiter_GuideFinish()
  else GuildRecruiter_GuideCard((g.card or 1) + 1) end
end

-- ---------------------------------------------------------------------------
-- the window
-- ---------------------------------------------------------------------------
function GuildRecruiter_GuideBuildLive(g)
  local f = g.live
  local c = Text(f, "GameFontNormalSmall", 18, -38, 344, 14); c:SetText("WHAT TO DO NOW")
  f.headline = Text(f, "GameFontNormalLarge", 18, -54, 344, 40)
  f.sub  = Text(f, "GameFontHighlightSmall", 18, -96, 344, 26)
  f.warn = Text(f, "GameFontNormalSmall", 18, -122, 344, 14); f.warn:SetTextColor(1, 0.5, 0.25)

  -- the ONE big button: a placeholder slot, the plain button on it, and (out of
  -- combat) the secure twin laid over it by GuildRecruiter_GuideSync
  f.primarySlot = CreateFrame("Frame", nil, f)
  f.primarySlot:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -140); f.primarySlot:SetWidth(200); f.primarySlot:SetHeight(30)
  f.primary = Btn(f, 200, 30, "Start", "Does the step named above.")
  f.primary:SetAllPoints(f.primarySlot)
  f.primary:SetScript("OnClick", function(self, button) GuildRecruiter_GuidePress(self, button, false, false) end)
  f.pauseBtn = Btn(f, 66, 22, "Pause", "Pause the run; Resume carries on where it stopped.")
  f.pauseBtn:SetPoint("LEFT", f.primarySlot, "RIGHT", 8, 0)
  f.pauseBtn:SetScript("OnClick", function() GuildRecruiter_TogglePause() end)
  f.stopBtn = Btn(f, 60, 22, "Stop", "End the run. People who said yes stay on your list.")
  f.stopBtn:SetPoint("LEFT", f.pauseBtn, "RIGHT", 4, 0)
  f.stopBtn:SetScript("OnClick", function() GuildRecruiter_StopRun() end)

  f.inviteCap = Text(f, "GameFontNormalSmall", 18, -184, 344, 14)
  f.empty = Text(f, "GameFontHighlight", 18, -206, 344, 40)
  f.rows = {}
  for i = 1, 4 do
    local row = CreateFrame("Frame", nil, f)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -200 - (i - 1) * 26)
    row:SetWidth(350); row:SetHeight(24)
    row.hl = row:CreateTexture(nil, "BACKGROUND")
    row.hl:SetAllPoints(row); GR_Compat.ColorTexture(row.hl, 1, 0.82, 0, 0.12); row.hl:Hide()
    row.box, row.tick = TickBox(row, 20)
    row.box:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 26, 0); row.text:SetWidth(254); row.text:SetHeight(24)
    row.text:SetJustifyH("LEFT")
    -- where a secure button (Open / Show) is laid, out of combat
    row.slot = CreateFrame("Frame", nil, row)
    row.slot:SetPoint("RIGHT", row, "RIGHT", -2, 0); row.slot:SetWidth(64); row.slot:SetHeight(20)
    row:Hide()
    f.rows[i] = row
  end
  -- step 3 without a Rawcruiter tab: print the names in the main chat instead
  f.printBtn = Btn(f, 64, 20, "Print", "Prints the waiting names in your chat, ready to shift-click.")
  f.printBtn:SetAllPoints(f.rows[3].slot)
  f.printBtn:SetScript("OnClick", function() GuildRecruiter_GuidePrintNames() end)
  f.printBtn:Hide()
  f.waiting = Text(f, "GameFontHighlightSmall", 18, -308, 278, 28)
  f.listBtn = Btn(f, 60, 20, "List", "Shows every waiting name with Copy and Done buttons.")
  f.listBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 302, -306)
  f.listBtn:SetScript("OnClick", function() GuildRecruiter_ReadyShow(true) end)

  c = Text(f, "GameFontNormalSmall", 18, -344, 344, 14); c:SetText("YOUR SETTINGS")
  Text(f, "GameFontHighlightSmall", 18, -368, 80, 16):SetText("Approach")
  f.approachBtn = Btn(f, 170, 22, "Whisper first", "Click to switch between Whisper first and Direct.")
  f.approachBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 100, -364)
  f.approachBtn:SetScript("OnClick", function()
    GuildRecruiter_GuideApproach(GuildRecruiter_Settings.mode == "whisperinvite" and "invite" or "whisperinvite")
  end)
  Text(f, "GameFontHighlightSmall", 18, -394, 80, 16):SetText("Levels")
  f.minBox = NumBox(f, "GuildRecruiterGuideMin", 106, -390, "Lowest level to look for (1-60). Press Enter to keep it.")
  Text(f, "GameFontHighlightSmall", 142, -394, 20, 16):SetText("to")
  f.maxBox = NumBox(f, "GuildRecruiterGuideMax", 164, -390, "Highest level to look for (1-60). Press Enter to keep it.")
  f.maxBox.isMax = true
  Text(f, "GameFontHighlightSmall", 18, -420, 80, 16):SetText("Message")
  f.msg = Text(f, "GameFontHighlightSmall", 100, -420, 196, 28)
  f.msgBtn = Btn(f, 60, 20, "Change", "Pick another ready-made message, or write your own.")
  f.msgBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 302, -416)
  f.msgBtn:SetScript("OnClick", function() GuildRecruiter_GuideShow("setup", 2, true) end)
  f.today = Text(f, "GameFontDisableSmall", 18, -450, 344, 14)
end

function GuildRecruiter_GuideBuildSetup(g)
  local f = g.setup
  f.steps = {}
  local names = { "1  Approach", "2  Message", "3  Chat tab" }
  for i = 1, 3 do
    local st = CreateFrame("Frame", nil, f)
    st:SetPoint("TOPLEFT", f, "TOPLEFT", 18 + (i - 1) * 116, -38)
    st:SetWidth(112); st:SetHeight(20)
    st.box, st.tick = TickBox(st, 18)
    st.box:SetPoint("LEFT", st, "LEFT", 0, 0)
    st.text = st:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    st.text:SetPoint("LEFT", st, "LEFT", 22, 0); st.text:SetText(names[i])
    f.steps[i] = st
  end
  f.title = Text(f, "GameFontNormalLarge", 18, -66, 344, 22)
  f.cards = {}

  -- card 1: the approach
  local c1 = CreateFrame("Frame", nil, f); c1:SetAllPoints(f); f.cards[1] = c1
  c1.optA = Btn(c1, 300, 26, "Whisper first (recommended)", "Whisper players with no guild; you invite the ones who say yes.")
  c1.optA:SetPoint("TOPLEFT", c1, "TOPLEFT", 18, -96)
  c1.optA:SetScript("OnClick", function() GuildRecruiter_GuideApproach("whisperinvite") end)
  c1.boxA, c1.tickA = TickBox(c1, 20); c1.boxA:SetPoint("LEFT", c1.optA, "RIGHT", 8, 0)
  Text(c1, "GameFontHighlightSmall", 26, -126, 334, 44):SetText("The addon whispers players who have no guild, one every 5 to 11 seconds, up to 30 per run. Anyone who answers yes is listed for you to invite.")
  c1.optB = Btn(c1, 300, 26, "Direct", "No whispers: each press of Next gives you one player to invite yourself.")
  c1.optB:SetPoint("TOPLEFT", c1, "TOPLEFT", 18, -178)
  c1.optB:SetScript("OnClick", function() GuildRecruiter_GuideApproach("invite") end)
  c1.boxB, c1.tickB = TickBox(c1, 20); c1.boxB:SetPoint("LEFT", c1.optB, "RIGHT", 8, 0)
  Text(c1, "GameFontHighlightSmall", 26, -208, 334, 44):SetText("No whispers. Each press of Next gives you one player with no guild, and you invite them yourself.")
  Text(c1, "GameFontDisableSmall", 18, -262, 344, 28):SetText("You can switch any time in the guide. Every other setting is under Advanced.")

  -- card 2: the message
  local c2 = CreateFrame("Frame", nil, f); c2:SetAllPoints(f); f.cards[2] = c2
  c2.tpl = {}
  for i = 1, #TEMPLATES do
    local b = Btn(c2, 106, 24, TEMPLATES[i].title, "Use this ready-made message. You can change it any time.")
    b:SetPoint("TOPLEFT", c2, "TOPLEFT", 18 + (i - 1) * 112, -96)
    b.index = i
    b:SetScript("OnClick", function(self) GuildRecruiter_GuideTemplate(self.index) end)
    c2.tpl[i] = b
  end
  c2.own = Btn(c2, 150, 22, "Write your own...", "Opens the message editor. %p becomes their name, %g your guild.")
  c2.own:SetPoint("TOPLEFT", c2, "TOPLEFT", 18, -128)
  c2.own:SetScript("OnClick", function() GuildRecruiter_GuideOwnMessage() end)
  Text(c2, "GameFontNormalSmall", 18, -160, 344, 14):SetText("Preview (what "..SAMPLE.." would see):")
  c2.preview = Text(c2, "GameFontHighlight", 18, -178, 344, 78)
  c2.note = Text(c2, "GameFontDisableSmall", 18, -262, 344, 28)

  -- card 3: the chat tab
  local c3 = CreateFrame("Frame", nil, f); c3:SetAllPoints(f); f.cards[3] = c3
  Text(c3, "GameFontHighlightSmall", 18, -96, 344, 56):SetText("People who say yes are listed in a chat tab of their own, called Rawcruiter. You shift-click a name there to put it in the guild's Invite box.")
  c3.box, c3.tick = TickBox(c3, 20); c3.box:SetPoint("TOPLEFT", c3, "TOPLEFT", 16, -156)
  c3.status = Text(c3, "GameFontHighlight", 42, -158, 320, 18)
  c3.create = Btn(c3, 240, 24, "Create the Rawcruiter chat tab", "Makes a new chat tab named Rawcruiter. Reload once afterwards.")
  c3.create:SetPoint("TOPLEFT", c3, "TOPLEFT", 18, -186)
  c3.create:SetScript("OnClick", function() GuildRecruiter_GuideMakeTab() end)
  c3.have = Btn(c3, 160, 24, "I already made it", "Your Rawcruiter tab was found. Go on to the guide.")
  c3.have:SetPoint("TOPLEFT", c3, "TOPLEFT", 18, -186)
  c3.have:SetScript("OnClick", function() GuildRecruiter_GuideFinish() end)
  c3.reload = Btn(c3, 120, 24, "Reload now", "Reloads the game's interface (like /reload). The guide opens again after.")
  c3.reload:SetPoint("TOPLEFT", c3, "TOPLEFT", 18, -216)
  c3.reload:SetScript("OnClick", function() GuildRecruiter_GuideReload() end)
  c3.reloadNote = Text(c3, "GameFontHighlightSmall", 146, -218, 216, 28)
  c3.reloadNote:SetText("Reload once so a click on a name can't be blocked.")
  Text(c3, "GameFontDisableSmall", 18, -262, 344, 28):SetText("Skip it and the names are printed in your main chat instead.")

  f.back = Btn(f, 80, 22, "Back", "Go to the previous card.")
  f.back:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 44)
  f.back:SetScript("OnClick", function() GuildRecruiter_GuideCard((GuildRecruiterGuide.card or 1) - 1) end)
  f.next = Btn(f, 100, 22, "Next", "Go on. A card you leave as it is just keeps its setting.")
  f.next:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 44)
  f.next:SetScript("OnClick", function() GuildRecruiter_GuideNextCard() end)
end

function GuildRecruiter_GuideBuild()
  local g = GuildRecruiterGuide
  if g then return g end
  g = GR_Compat.BackdropFrame("Frame", "GuildRecruiterGuide", UIParent)
  g:SetWidth(GUIDE_W); g:SetHeight(GUIDE_H)
  g:SetFrameStrata("HIGH")
  g:SetClampedToScreen(true)
  GR_Compat.SetBackdrop(g, { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 } })
  g:EnableMouse(true); g:SetMovable(true); g:RegisterForDrag("LeftButton")
  local pos = GuildRecruiter_Settings.guidePos
  if type(pos) == "table" and type(pos[1]) == "string" then
    g:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
  else
    -- top-right by default: clear of the Guild window (CommunitiesFrame is 814 px wide in
    -- the left panel area, Invite Member at its bottom-right) and of the chat (bottom-left)
    g:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -16, -200)
  end
  -- while dragged, the secure buttons step aside (they are anchored to UIParent)
  g:SetScript("OnDragStart", function(self)
    self.dragging = true
    GuildRecruiter_GuideSync()
    self:StartMoving()
  end)
  g:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self.dragging = false
    local point, _, relPoint, x, y = self:GetPoint(1)
    if point then GuildRecruiter_Settings.guidePos = { point, relPoint, x, y } end
    GuildRecruiter_GuideSync()
  end)
  g:SetScript("OnShow", function() GuildRecruiter_GuideRefresh() end)
  g:SetScript("OnHide", function() GuildRecruiter_GuideSync() end)   -- out of combat: the secure buttons hide too
  g:SetScript("OnUpdate", function(self, elapsed)
    local ok, err = pcall(GuildRecruiter_GuideTick, self, elapsed)
    if not ok then GuildRecruiter_GuideError(err) end
  end)

  g.title = g:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  g.title:SetPoint("TOP", g, "TOP", 0, -16)
  local close = CreateFrame("Button", nil, g, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", g, "TOPRIGHT", -6, -6)
  close.tip = "Close the guide. /gr or the minimap button opens it again."
  close:SetScript("OnClick", function() GuildRecruiterGuide:Hide() end)   -- our own frame only
  close:SetScript("OnEnter", GuildRecruiter_GuideTip)
  close:SetScript("OnLeave", GuildRecruiter_GuideTipHide)

  g.live = CreateFrame("Frame", nil, g); g.live:SetAllPoints(g)
  g.setup = CreateFrame("Frame", nil, g); g.setup:SetAllPoints(g)
  GuildRecruiter_GuideBuildLive(g)
  GuildRecruiter_GuideBuildSetup(g)

  -- footer, on both views
  g.setupBtn = Btn(g, 64, 20, "Setup", "Go through the three setup cards again.")
  g.setupBtn:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 16, 14)
  g.setupBtn:SetScript("OnClick", function() GuildRecruiter_GuideShow("setup", 1) end)
  g.advBtn = Btn(g, 90, 20, "Advanced...", "Every other setting, the lists and the stats (the full window).")
  g.advBtn:SetPoint("LEFT", g.setupBtn, "RIGHT", 4, 0)
  g.advBtn:SetScript("OnClick", function() GuildRecruiter_GotoSettings() end)
  g.dontShow = CreateFrame("CheckButton", "GuildRecruiterGuideDontShow", g, "UICheckButtonTemplate")
  g.dontShow:SetWidth(22); g.dontShow:SetHeight(22)
  g.dontShow:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 212, 12)
  GR_Compat.SetChildText(g.dontShow, "Text", "Don't show again")
  g.dontShow.tip = "Stop this guide opening by itself (at login, or when someone says yes). /gr still opens it."
  g.dontShow:SetScript("OnClick", function(self) GuildRecruiter_Settings.guideSeen = self:GetChecked() and true or false end)
  g.dontShow:SetScript("OnEnter", GuildRecruiter_GuideTip)
  g.dontShow:SetScript("OnLeave", GuildRecruiter_GuideTipHide)

  g.view, g.card = "live", 1
  g:Hide()
  return g
end

-- ---------------------------------------------------------------------------
-- refresh (a few times a second while shown; read-only except our own frames)
-- ---------------------------------------------------------------------------
function GuildRecruiter_GuideWaiting()
  local names = GuildRecruiter_ReadyNames()           -- newest first
  local r = GuildRecruiter_Settings.ready or {}
  local parts = {}
  for i = #names, 1, -1 do
    if #parts >= 3 then break end
    local e = r[names[i]]
    tinsert(parts, Plain(names[i]).." "..GuildRecruiter_ReadyAge(type(e) == "table" and e.t or nil))
  end
  local more = #names - #parts
  return "Waiting ("..#names.."), longest first: "..table.concat(parts, ", ")..((more > 0) and (" +"..more.." more") or "")
end

-- the four invite steps. Each tick comes from GuildRecruiter_GuideSteps (read
-- only); the first step not yet done is the current one. Also says which secure
-- buttons are wanted (want.guild / want.tab).
function GuildRecruiter_GuideRows(f, sp, want)
  local key = GR_Compat.BindingKey("TOGGLEGUILDTAB")
  local lf = sp.tabFrame
  local li = sp.sent
  local state = {
    (sp.guildOpen or sp.popup or sp.finder) and "done" or "todo",
    (sp.popup or sp.finder) and "done" or "todo",
    (not lf) and "skip" or (sp.tabShown and "done" or "todo"),
    li and "done" or "todo",
  }
  local text = {
    (state[1] == "done") and "Guild window is open"
      or ("Open the Guild window"..(key and (" (or press "..key..")") or " (Guild button on your bar)")),
    (state[2] == "done") and ("Invite box is open"..(sp.finder and " (Guild Finder version)" or ""))
      or "Click Invite Member (bottom of the Guild window)",
    (not lf) and "Find the name in your chat (no Rawcruiter tab)"
      or ((state[3] == "done") and "The Rawcruiter tab is showing" or "Switch your chat to the Rawcruiter tab"),
    li and (li.trial and (Plain(li.name).." is a Free Trial account -- skipped") or ("Invited "..Plain(li.name)))
      or (sp.finder and "Type the name (this box ignores shift-click), press Accept"
      or "Shift-click a name there, then press Accept"),
  }
  local current
  for i = 1, 4 do if state[i] == "todo" then current = i; break end end
  for i = 1, 4 do
    local row = f.rows[i]
    if state[i] == "done" then row.tick:Show() else row.tick:Hide() end
    local t = i..".  "..text[i]
    if i == current then
      row.text:SetText("|cffffd100>|r "..t); row.text:SetTextColor(1, 1, 1); row.hl:Show()
    elseif state[i] == "done" then
      row.text:SetText(t); row.text:SetTextColor(0.45, 1, 0.45); row.hl:Hide()
    else
      row.text:SetText(t); row.text:SetTextColor(0.6, 0.6, 0.6); row.hl:Hide()
    end
    row:Show()
  end
  want.guild = (state[1] == "todo")
  want.tab = (state[3] == "todo")
  local nm = lf and lf.GetName and lf:GetName()
  want.tabButton = nm and _G[nm.."Tab"] or nil
  if lf then f.printBtn:Hide() else f.printBtn:Show() end
end

function GuildRecruiter_GuideRefreshLive(g)
  local f, s = g.live, GuildRecruiter_Settings
  local st = GuildRecruiter_GuideState()
  f.headline:SetText(st.headline or "")
  f.sub:SetText(st.sub or "")
  f.warn:SetText(st.warn or "")
  f.primary:SetText(st.label or "Start")
  f.primary.tip = st.tip or "Does the step named above."
  if st.enabled then f.primary:Enable() else f.primary:Disable() end
  if st.running then
    f.stopBtn:Show()
    if st.paused then f.pauseBtn:Hide() else f.pauseBtn:Show() end
  else
    f.stopBtn:Hide(); f.pauseBtn:Hide()
  end

  local want = { label = st.label, enabled = st.enabled, tip = f.primary.tip }
  f.inviteCap:SetText((s.mode == "invite") and "INVITE THE PEOPLE ON YOUR LIST" or "INVITE THE PEOPLE WHO SAID YES")
  local n = GuildRecruiter_ReadyCount()
  local sp = GuildRecruiter_GuideSteps()
  if n == 0 then
    for i = 1, 4 do f.rows[i]:Hide() end
    f.waiting:Hide(); f.listBtn:Hide(); f.printBtn:Hide()
    local li = sp.sent
    if li then
      f.empty:SetText((li.trial and (Plain(li.name).." is a Free Trial account and can't join -- skipped.")
        or ("Invited "..Plain(li.name)..".")).."\nNobody else is waiting right now.")
    elseif s.mode == "invite" then
      f.empty:SetText("Nobody is waiting for an invite.\nPress Next for a name; the steps to invite them appear here.")
    else
      f.empty:SetText("Nobody has said yes yet.\nWhen someone does, the steps to invite them appear here.")
    end
    f.empty:Show()
  else
    f.empty:Hide()
    GuildRecruiter_GuideRows(f, sp, want)
    f.waiting:SetText(GuildRecruiter_GuideWaiting()); f.waiting:Show(); f.listBtn:Show()
  end
  g.want = want

  f.approachBtn:SetText(APPROACH[s.mode] or tostring(s.mode))
  if not f.minBox:HasFocus() then f.minBox:SetText(tostring(s.minLevel or 1)) end
  if not f.maxBox:HasFocus() then f.maxBox:SetText(tostring(s.maxLevel or 60)) end
  if s.mode == "invite" then
    f.msg:SetText("|cff999999Direct sends no whisper.|r")
  else
    local m = GuildRecruiter_WhisperPreview(SAMPLE, s.whisperMsg) or ""
    if string.len(m) > 96 then m = string.sub(m, 1, 94).."..." end
    f.msg:SetText(Plain(m))
  end
  local d = GuildRecruiter_TodayTally()
  f.today:SetText("Today: "..(d.whispered or 0).." whispered, "..(d.yes or 0).." said yes, "
    ..(d.invited or 0).." invited, "..(d.trial or 0).." free trial skipped")
end

function GuildRecruiter_GuideRefreshSetup(g)
  local f, s = g.setup, GuildRecruiter_Settings
  local card = g.card or 1
  local cards = s.guideCards or {}
  local lf = GR_Compat.ListFrame()
  local done = { cards.approach, cards.message, lf ~= nil }
  for i = 1, 3 do
    local st = f.steps[i]
    if done[i] then st.tick:Show() else st.tick:Hide() end
    if i == card then st.text:SetTextColor(1, 0.82, 0) else st.text:SetTextColor(0.6, 0.6, 0.6) end
    if i == card then f.cards[i]:Show() else f.cards[i]:Hide() end
  end
  if card == 1 then
    f.title:SetText("How should we reach people?")
    local c1 = f.cards[1]
    if s.mode == "whisperinvite" then c1.tickA:Show(); c1.optA:LockHighlight() else c1.tickA:Hide(); c1.optA:UnlockHighlight() end
    if s.mode == "invite" then c1.tickB:Show(); c1.optB:LockHighlight() else c1.tickB:Hide(); c1.optB:UnlockHighlight() end
  elseif card == 2 then
    f.title:SetText("What should the whisper say?")
    local c2 = f.cards[2]
    for i = 1, #TEMPLATES do
      if s.whisperMsg == TEMPLATES[i].text then c2.tpl[i]:LockHighlight() else c2.tpl[i]:UnlockHighlight() end
    end
    c2.preview:SetText(Plain(GuildRecruiter_WhisperPreview(SAMPLE, s.whisperMsg) or ""))
    c2.note:SetText((s.mode == "invite") and "Direct sends no whisper; this message is used if you switch to Whisper first."
      or "%p becomes the player's name and %g your guild's name.")
  else
    f.title:SetText("Where do the names show up?")
    local c3 = f.cards[3]
    if lf then
      c3.tick:Show(); c3.status:SetText("Found your Rawcruiter chat tab."); c3.create:Hide()
      if g.madeTab then c3.have:Hide(); c3.reload:Show(); c3.reloadNote:Show()
      else c3.have:Show(); c3.reload:Hide(); c3.reloadNote:Hide() end
    else
      c3.tick:Hide(); c3.status:SetText("No Rawcruiter chat tab yet.")
      c3.create:Show(); c3.have:Hide(); c3.reload:Hide(); c3.reloadNote:Hide()
    end
  end
  if card > 1 and not g.single then f.back:Show() else f.back:Hide() end
  f.next:SetText(g.single and "Done" or ((card >= 3) and "Finish" or "Next"))
end

function GuildRecruiter_GuideRefresh()
  local g = GuildRecruiterGuide
  if not g or not g:IsShown() or type(GuildRecruiter_Settings) ~= "table" then return end
  GuildRecruiter_GuideSeed()
  g.dontShow:SetChecked(GuildRecruiter_Settings.guideSeen and true or false)
  if g.view == "setup" then
    g.live:Hide(); g.setup:Show(); g.setupBtn:Hide()
    g.title:SetText("Guild Rawcruiter -- Setup")
    g.want = nil
    GuildRecruiter_GuideRefreshSetup(g)
  else
    g.setup:Hide(); g.live:Show(); g.setupBtn:Show()
    g.title:SetText("Guild Rawcruiter")
    GuildRecruiter_GuideRefreshLive(g)
  end
  GuildRecruiter_GuideSync()
  -- the plain big button stands in whenever its secure twin is not on screen
  -- (in combat, while dragging, or if the secure button could not be made)
  local sb = g.sec and g.sec.next
  if g.view ~= "setup" and not (sb and sb:IsShown()) then g.live.primary:Show() else g.live.primary:Hide() end
end

function GuildRecruiter_GuideTick(g, elapsed)
  g.tick = (g.tick or 0) - (elapsed or 0)
  if g.tick > 0 then return end
  g.tick = 0.2
  g.readyTick = (g.readyTick or 0) + 0.2
  if g.readyTick >= 1 then
    g.readyTick = 0
    GuildRecruiter_ReadyRefresh()   -- expiry + the Rawcruiter tab, once a second (what the Ready panel did)
  end
  GuildRecruiter_GuideRefresh()
end

-- ---------------------------------------------------------------------------
-- the secure buttons (SecureActionButtonTemplate). Built once, out of combat.
-- Parented and anchored to UIParent ONLY, at the screen spot of a placeholder
-- slot in the guide (like GuildRecruiterNextButton under the minimap button).
--   GuildRecruiterGuideNext      the big button. No action attribute is ever
--                                set: its PreClick runs GuildRecruiter_GuidePress
--                                (the Next press reuses GuildRecruiter_SecurePreClick).
--   GuildRecruiterGuideOpenGuild type = "click", clickbutton = GuildMicroButton
--   GuildRecruiterGuideShowTab   type = "click", clickbutton = ChatFrame<N>Tab
--                                (N = the Rawcruiter chat frame, GR_Compat.ListFrame)
-- "click" is the template's own SECURE_ACTIONS.click: delegate:Click(button),
-- with the same access checks as a "/click" macro, without the macro parser.
-- ---------------------------------------------------------------------------
function GuildRecruiter_GuideSecureButton(name, label)
  local b = CreateFrame("Button", name, UIParent, "SecureActionButtonTemplate,UIPanelButtonTemplate")
  b:SetFrameStrata("HIGH")
  b:SetWidth(64); b:SetHeight(20)
  b:SetAttribute("useOnKeyDown", false)   -- acts on the click's UP edge, like GuildRecruiterNextButton
  b:RegisterForClicks("LeftButtonUp")
  b:SetText(label)
  b:SetScript("OnEnter", GuildRecruiter_GuideTip)
  b:SetScript("OnLeave", GuildRecruiter_GuideTipHide)
  b:Hide()
  return b
end

function GuildRecruiter_GuideBuildSecure()
  local sec = {}
  sec.next = GuildRecruiter_GuideSecureButton("GuildRecruiterGuideNext", "Start")
  sec.next:SetScript("PreClick", function(self, button, down) GuildRecruiter_GuidePress(self, button, down, true) end)
  sec.next:SetScript("PostClick", function(self, button, down) GuildRecruiter_SecurePostClick(self, button, down) end)
  sec.guild = GuildRecruiter_GuideSecureButton("GuildRecruiterGuideOpenGuild", "Open")
  sec.guild.tip = "Opens the Guild window (the same as your Guild key)."
  sec.tab = GuildRecruiter_GuideSecureButton("GuildRecruiterGuideShowTab", "Show")
  sec.tab.tip = "Switches your chat to the Rawcruiter tab, where the names are."
  return sec
end

function GuildRecruiter_GuideMakeSecure(g)
  if g.sec or g.secFailed then return g.sec end
  if GR_Compat.InCombat() then return nil end
  local ok, res = pcall(GuildRecruiter_GuideBuildSecure)
  if ok and type(res) == "table" then
    g.sec = res
  else
    g.secFailed = true                          -- never retried: the plain buttons and hints stay
    GuildRecruiter_GuideError("secure buttons: "..tostring(res))
  end
  return g.sec
end

-- lay one secure button over its slot, or hide it. Out of combat only (the caller checks).
function GuildRecruiter_GuidePlace(g, b, slot, want)
  if want and slot and slot:IsVisible() then
    local l, bt = slot:GetLeft(), slot:GetBottom()
    if l and bt then
      local k = slot:GetEffectiveScale() / UIParent:GetEffectiveScale()
      local x, y, w, h = l * k, bt * k, slot:GetWidth() * k, slot:GetHeight() * k
      if b.gx ~= x or b.gy ~= y then
        b:ClearAllPoints(); b:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
        b.gx, b.gy = x, y
      end
      if b.gw ~= w or b.gh ~= h then b:SetWidth(w); b:SetHeight(h); b.gw, b.gh = w, h end
      local lvl = g:GetFrameLevel() + 20
      if b:GetFrameLevel() ~= lvl then b:SetFrameLevel(lvl) end
      if not b:IsShown() then b:Show() end
      return
    end
  end
  if b:IsShown() then b:Hide() end
end

-- show, place, label or hide the three secure buttons to match the window.
-- OUT OF COMBAT ONLY: in combat lockdown it returns at once (the buttons were
-- hidden at PLAYER_REGEN_DISABLED, and PLAYER_REGEN_ENABLED calls this again).
function GuildRecruiter_GuideSync()
  local g = GuildRecruiterGuide
  if not g or GR_Compat.InCombat() then return end
  local sec = GuildRecruiter_GuideMakeSecure(g)
  if not sec then return end
  local w = g.want
  local live = (g:IsShown() and g.view ~= "setup" and not g.dragging and w) and true or false
  w = w or {}
  local b = sec.next
  if live then
    if b:GetText() ~= w.label then b:SetText(w.label or "Next") end
    if w.enabled then b:Enable() else b:Disable() end
    b.tip = w.tip
  end
  GuildRecruiter_GuidePlace(g, b, g.live.primarySlot, live)
  -- Open: the Guild window, through the micro-menu button's own click
  local gm = GuildMicroButton
  if gm and sec.guild.target ~= gm then
    sec.guild:SetAttribute("type", "click")
    sec.guild:SetAttribute("clickbutton", gm)
    sec.guild.target = gm
  end
  GuildRecruiter_GuidePlace(g, sec.guild, g.live.rows[1].slot, live and w.guild and gm ~= nil)
  -- Show: the Rawcruiter chat tab, through that tab's own click
  local tab = w.tabButton
  if tab and sec.tab.target ~= tab then
    sec.tab:SetAttribute("type", "click")
    sec.tab:SetAttribute("clickbutton", tab)
    sec.tab.target = tab
  end
  GuildRecruiter_GuidePlace(g, sec.tab, g.live.rows[3].slot, live and w.tab and tab ~= nil and sec.tab.target == tab)
end

-- PLAYER_REGEN_DISABLED fires just BEFORE combat lockdown: the last moment the
-- secure buttons may be hidden. In combat the plain buttons and hints are used.
function GuildRecruiter_GuideSecureHide()
  local g = GuildRecruiterGuide
  if not g or not g.sec or GR_Compat.InCombat() then return end
  for _, b in pairs(g.sec) do
    if b:IsShown() then b:Hide() end
  end
end

-- ---------------------------------------------------------------------------
-- opening and closing
-- ---------------------------------------------------------------------------
-- view: "live" | "setup" | nil (setup until it is finished, then live)
-- card: the setup card; single: one card only, its button says Done
function GuildRecruiter_GuideShow(view, card, single)
  GuildRecruiter_GuideSeed()
  if type(GuildRecruiter_Settings) ~= "table" then return end
  local g = GuildRecruiter_GuideBuild()
  if not view then view = GuildRecruiter_Settings.guideDone and "live" or "setup" end
  g.view = view
  if view == "setup" then
    g.card = card or g.card or 1
    g.single = single and true or false
  else
    g.single = false
  end
  if g:IsShown() then GuildRecruiter_GuideRefresh() else g:Show() end   -- OnShow refreshes
end

-- /gr, /gr guide and the minimap button
function GuildRecruiter_GuideToggle()
  local g = GuildRecruiterGuide
  if g and g:IsShown() then g:Hide(); return end
  GuildRecruiter_GuideShow()
end

-- someone said yes (or a Direct prompt): open the live guide, unless the player
-- ticked "Don't show again" -- then false, and the Ready panel pops as before
function GuildRecruiter_GuideNotify(name)
  GuildRecruiter_GuideSeed()
  local s = GuildRecruiter_Settings
  if type(s) ~= "table" or s.guideSeen then return false end
  GuildRecruiter_GuideShow("live")
  return true
end

function GuildRecruiter_GuideEvent(event, a1)
  if event == "ADDON_LOADED" then
    if a1 == ADDON_NAME then GuildRecruiter_GuideSeed() end
  elseif event == "PLAYER_ENTERING_WORLD" then
    if autoShown then return end
    autoShown = true                            -- once per session (not on every zone change)
    GuildRecruiter_GuideSeed()
    if type(GuildRecruiter_Settings) == "table" and not GuildRecruiter_Settings.guideSeen then
      GuildRecruiter_GuideShow()
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    GuildRecruiter_GuideSecureHide()
  elseif event == "PLAYER_REGEN_ENABLED" then
    GuildRecruiter_GuideRefresh()               -- includes GuildRecruiter_GuideSync
  end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(self, event, a1)
  local ok, err = pcall(GuildRecruiter_GuideEvent, event, a1)
  if not ok then GuildRecruiter_GuideError(err) end
end)
