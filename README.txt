GuildRecruiter  --  vanilla 1.12 guild recruitment helper
==========================================================

Scans online players with /who and sends paced guild invites to players who are
NOT already in a guild. Built for vanilla (1.12) clients / private servers.


INSTALL
-------
1. Extract the "GuildRecruiter" folder into:
      <WoW>\Interface\AddOns\
   You should end up with:
      <WoW>\Interface\AddOns\GuildRecruiter\GuildRecruiter.toc
2. FULLY RESTART the game (or log out to the character-select screen) the first
   time -- a /reload will NOT register a brand-new addon folder.
3. Make sure "GuildRecruiter" is enabled in the AddOns list at character select.


FIRST, CONFIRM YOUR SERVER'S INVITE METHOD
------------------------------------------
Different cores expose guild invites differently. Check once:

  Type this and see if it invites:
      /ginvite SomeName

  And print which Lua API exists:
      /script DEFAULT_CHAT_FRAME:AddMessage(tostring(GuildInvite).." / "..tostring(GuildInviteByName))

The addon uses GuildInviteByName() if present (Turtle WoW's canonical invite),
then GuildInvite(), and finally falls back to running the /ginvite chat command
-- so if /ginvite works for you manually, the addon will work too. On load it
prints which API it detected ("Invite API: GuildInviteByName" on Turtle). If your
server uses a different command, say so and it can be pointed at that instead.


COMMANDS  (slash:  /gr)
-----------------------
  /gr start                Begin scanning + inviting.
  /gr stop                 Halt the current run.
  /gr status               Show progress + history size.
  /gr config               Open the settings window (sliders + method picker).
  /gr reset                Clear THIS session's scan list (keeps history).
  /gr forget               Wipe the persistent invite history (everyone
                           becomes invitable again).
  /gr set invite <sec>     Seconds between guild invites (default 1, 1-10).
  /gr set who <sec>        Seconds between /who queries (default 3, 1-15).
  /gr set reinvite <days>  Don't re-invite someone within this many days
                           (default 14; 0 = never re-invite anyone twice).
  /gr set method <m>       Which invite function to use:
                             auto   - best available (recommended)
                             byname - force GuildInviteByName()
                             invite - force GuildInvite()
                             chat   - force the /ginvite chat command


SETTINGS WINDOW  (/gr config)
-----------------------------
Opens a small draggable panel with:
  * a slider AND a numeric input box for the invite delay (1-10s),
  * a slider AND a numeric input box for the /who delay (1-15s),
  * a button that cycles the invite method (auto / byname / invite / chat).
Slider and input box stay in sync, and everything mirrors the /gr set commands
-- change it in either place. Settings are saved account-wide.


REMEMBERS WHO IT INVITED
------------------------
Every invite is saved ACCOUNT-WIDE to SavedVariables, so it survives /reload
and game restarts AND is shared across all your characters -- recruit from any
alt and they won't re-invite people another character already hit. On later
runs, anyone you invited within the re-invite cooldown is skipped automatically.
Stale entries (past the cooldown) are pruned and become invitable again, so you
can keep recruiting over time without re-pestering recent declines. Use
"/gr forget" to start completely fresh.


HOW IT WORKS  (and its limits)
------------------------------
* /who is the only way to enumerate players in 1.12, it returns at most ~49
  results per query, and it is server-throttled. The addon sweeps level bands,
  widening them when a query comes back light and narrowing (then splitting by
  class, then race) only where the population is dense -- so it spends as few
  /who queries as possible and each one comes back as full as it can.
* It only invites players with NO guild (it never spams people already guilded).
* It never re-invites the same person within a run.
* /who is faction-locked in 1.12, so it only scans your own faction.
* Any runtime error stops the run cleanly with a "Stopped on error" message.

TURTLE WOW NOTES
----------------
* Defaults are tuned for Turtle (invite 1s, who 3s) -- much faster than the old
  conservative defaults built for throttle-harsh cores like Kronos.
* On start the addon calls SetWhoToUI(1) so EVERY /who comes back as a readable
  result event; without it, small result sets (<=3 players) leak to chat as text
  the addon can't read, and those players would be silently missed.
* The /who 50-result cap is server-side and CANNOT be bypassed (true on Turtle
  too), which is why the adaptive level/class/race subdivision still earns its
  keep -- it's the only way to enumerate a dense population fully.

SCANNING AND INVITING RUN IN PARALLEL (not 1-scan-1-invite)
-----------------------------------------------------------
A single /who returns up to 50 players and queues ALL the guildless ones at once;
a separate timer drains that queue at the invite delay. So invites are NOT gated
1-per-scan -- if it ever felt that way, it was the old 4s invite pacing trickling
a big queue out slowly. At the new 1s default the queue drains quickly.

TUNING FOR YOUR SERVER
----------------------
If /who scans get silently dropped (server throttle), raise the spacing:
      /gr set who 6
Invites drain once per timer tick, so 1s is the practical floor -- going lower
(per-frame) would flood-kick you. If even 1s causes issues, raise it.

PLEASE NOTE
-----------
Mass recruitment is against the rules on many servers even when limited to
guildless players. It's your account -- check your server's policy before
running a full sweep.
