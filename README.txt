Guild Rawcruiter  --  vanilla 1.12 / Turtle WoW guild recruitment helper
==============================================================================


WoW: FOREVER BUILD  (branch "forever", version 4.0.0-forever.1)
-----------------------------------------------------------------
This is a BETA port to the WoW: Forever client (## Interface: 16001, modified
Lua 5.1, Mainline-style API). It has NOT been tested in game -- it was ported
and checked offline only. The 1.12 / Turtle build stays on the "main" branch;
the text below this section describes that build's features, which the port
keeps (same settings, defaults, slash commands and pacing values), except that
each /who and each invite now waits for a key press -- see "ONE KEY PRESS PER
/WHO OR INVITE" below.

What changed: the Lua 5.0 code was converted to Lua 5.1 (no table.getn,
string.gfind, getglobal, `this` or arg1 globals), and every client call whose
Forever behaviour is unconfirmed now goes through one small compatibility
layer, GR_Compat, at the top of GuildRecruiter.lua. Each GR_Compat function
checks which API the client actually has (feature detection, never a version
check) and uses the modern one when present, else the old 1.12 global:
  /who            C_FriendList.SendWho / GetNumWhoResults / GetWhoInfo /
                  SetWhoToUi          (else SendWho, GetWhoInfo, SetWhoToUI)
  guild invite    C_GuildInfo.Invite  (else GuildInviteByName, GuildInvite,
                                       then the /ginvite chat command)
  whisper         C_ChatInfo.SendChatMessage      (else SendChatMessage)
  guild sync      C_ChatInfo.SendAddonMessage + RegisterAddonMessagePrefix
  window frames   BackdropTemplate when the client has it
Values the client marks secret (issecretvalue) are skipped, never compared.
On load the addon prints which invite, /who and whisper calls it picked.

ONE KEY PRESS PER /WHO OR INVITE (key-press mode)
The warcraft.wiki.gg pages for C_FriendList.SendWho and C_GuildInfo.Invite say
both need a hardware event (a key press or mouse click), and the other Forever
recruiters all work one /who or one invite per press. So on a client that has
C_FriendList.SendWho, the addon never sends a /who or an invite from its timer.
It waits for you to press "Next":
  /gr start       ARMS the run (or right-click the minimap button). Nothing is
                  sent yet; chat tells you how to press Next.
  Next            Each press sends ONE thing, in this order:
                    1. an invite to someone who replied yes (whisper-then-invite)
                    2. the next queued contact: an invite, or the first whisper
                       of whisper-then-invite mode
                    3. otherwise the next /who of the sweep
                  Three ways to press it:
                    - a key: Key Bindings > Guild Rawcruiter >
                      "Next: send one /who or one invite" (binding name
                      GUILDRECRUITER_NEXT, from Bindings.xml). No default key.
                    - the "Next" button that appears under the minimap button
                      while a run is armed (and on the Lists tab during
                      Invite all / Send)
                    - typing /gr next (a macro with /gr next works too)
The button shows what the next press will do and when it is allowed, e.g.
"Next: send /who", "/who ready in 2s", "Invite Bob", "Waiting for /who".
A number in [brackets] is how many replies are ready to invite.
Your delay settings (invite delay, /who delay, random delays) still apply, as
the shortest gap between presses: press too early and chat says "wait Ns".
The timer still does the waiting: /who timeouts and retries, reading the
results, judging whisper replies, auto-backoff, the rest between auto-rescan
sweeps (each new sweep waits for a press), and ending the run.
Whisper-only contacts are not restricted, so in "whisper" mode the whispers
still go out by themselves at the invite delay; you only press for the /who.
Lists tab "Invite all" / "Send": confirm once to arm, then each click on Next
sends one invite and chat says "N left, click again".
If the client still blocks a call (ADDON_ACTION_BLOCKED / FORBIDDEN naming
this addon), the run pauses and one chat line names the blocked call.
On a client without C_FriendList.SendWho the old automatic timer loop runs
unchanged and Next is not needed.
NONE OF THIS HAS BEEN TESTED IN GAME. Details and open questions are in
PORT_NOTES.md.

Before trusting it, run this in game and send the output along with any error:
  /dump select(4, GetBuildInfo())
  /run print(C_FriendList and C_FriendList.SendWho, SendWho, GuildInvite, C_GuildInfo and C_GuildInfo.Invite, string.gfind, table.getn, BackdropTemplateMixin)

Install path on the Forever beta was reported as
  World of Warcraft\_classic_beta_\Interface\AddOns\GuildRecruiter\
(this may change). The folder must stay named "GuildRecruiter".

==============================================================================

Scans online players with /who and sends paced guild contacts (invite and/or
whisper) to players who are NOT already in a guild. Built for vanilla (1.12)
clients and Turtle WoW.


INSTALL
-------
1. On the Releases page:
      https://github.com/Desocode/GuildRecruiter/releases/latest
   download the "GuildRecruiter.zip" asset (under "Assets").
   DO NOT use the green "Code -> Download ZIP" button or the "Source code (zip)"
   link -- those unzip to a mis-named "GuildRecruiter-main" folder WoW won't load.
2. Extract it so the "GuildRecruiter" folder lands in:
      <WoW>\Interface\AddOns\GuildRecruiter\GuildRecruiter.toc
3. FULLY RESTART the game the first time (a /reload won't register a new addon,
   and the .toc version bump needs a restart too).
4. Enable "Guild Rawcruiter" in the AddOns list at character select.
   (The install folder stays named "GuildRecruiter" -- that's intentional, so
    your saved settings carry over.)

On load it prints which invite API it detected (e.g. "Invite API:
GuildInviteByName" on Turtle). If /ginvite works manually, the addon works.


QUICK START
-----------
Everything lives in ONE window with three tabs along the bottom -- Settings,
Lists, and Stats. Open it on any tab:
  /gr config     Open on the Settings tab (sliders, mode, filters, run buttons).
  /gr list       Open on the Lists tab: view/edit the candidates, contact queue,
                 blacklist, invite history, and yes/refusal word lists (click a
                 row to remove; add via the box at the bottom).
  /gr stats      Open on the Stats tab: profiles + join/decline analytics.
  /gr start      Begin scanning + contacting (or click the minimap button).
  /gr stop       Halt. /gr pause + /gr resume keep your place.
The minimap button: LEFT-click opens the window, RIGHT-click starts/stops.

The /who chat spam ("N players total" etc.) is hidden while a run is active
(/gr quiet off to show it).

A minimap button is added: LEFT-click opens settings, RIGHT-click starts/stops,
drag it around the minimap to reposition.


CONTACT MODES  (/gr set mode ...)
---------------------------------
  invite          Send a guild invite (default; original behaviour).
  whisper         Send only a whisper -- no invite. More polite / less spammy.
  whisperinvite   Whisper first; then auto-invite (~1s later) ONLY if they reply
                  with something affirmative ("yes", "sure", "invite me", ...).

REPLY POLICY (whisperinvite mode)
---------------------------------
/gr replymode chooses when a whisper reply triggers the invite:
  notno    (default) invite unless the reply contains a refusal word ("no thanks")
  yesonly  invite only when the reply matches a yes-word ("yes", "invite me", ...)
  any      invite on any reply at all
Both word lists are editable in the Lists tab or via slash:
  /gr noword add|remove|list <phrase>    Refusal words (block the invite).
  /gr yesword add|remove|list <phrase>   Yes words (required in yesonly mode).
A vague reply ("what guild?") keeps the person on hold so a later "ok" still works.

PROFILES (swappable setting presets, saved across logout)
---------------------------------------------------------
Save your tuning (delays, mode, message, level range, filters, toggles...) as a
named profile and switch between them -- e.g. a polite "whisper" profile and a
fast "invite" profile. Managed in the Stats window or via slash:
  /gr profile save <name> | load <name> | delete <name> | list

STATS  (/gr stats)
------------------
Tracks invited / whispered / joined / declined with a join-rate %, both lifetime
and per-day, saved across logouts so you can compare over time. Joins are
attributed to you only for people you contacted; declines of your invites always
count. (Detection reads the client's guild join/decline messages; if your core's
wording differs and counts look off, tell me the exact text.)

A/B TESTING (compare configs simultaneously)
---------------------------------------------
Find out which approach actually converts better. Your live Settings are variant
A (the control); add challenger variants B/C/D on the A/B tab (each with its own
message / mode / method / reply policy), turn A/B on, and every player you
contact is randomly dealt one variant -- so all run in the same hour over the
same /who population (a fair test). Run-level settings (delays, levels, pacing)
are shared. Each variant's contacted / joined / declined and conversion % show
in the Stats tab.
  /gr ab            open the A/B tab (add/edit variants there)
  /gr ab on         (then recruit normally)
  /gr ab off | clear
Even with A/B off, stats are tagged by the active profile, so you can also just
run profile A for a while, switch to B, and compare. A/B stats are per-account
(they merge across your own alts, not across other guildmates).

Whisper text is editable (/gr msg <text> or the settings window). Tokens:
  %p = player name      %g = your guild name
Default: "Hi %p! :) I'm recruiting for <%g>, a friendly and active guild that
loves grouping up for quests, dungeons and raids. If you're after a guild, just
whisper me back and I'll send an invite -- no pressure either way!"

NOTE: blind mass guild invites break many servers' rules (Turtle included).
Whisper or whisper-on-reply modes are the safer, better-received options.


GUILD COORDINATION  (multiple recruiters, /gr sync on)
------------------------------------------------------
If several guildmates run this addon at once it coordinates over guild addon
messages (invisible to everyone else):
  * DEDUP  -- every contact is shared, so two recruiters never hit the same
             person, and the re-invite cooldown becomes guild-wide.
  * SPLIT  -- active recruiters announce themselves and the 1-60 sweep is
             divided evenly between them (by name order) so they cover
             different level bands instead of overlapping.
Best-effort: only works for guildmates online at the same time on the same
addon version. Dedup guarantees no double-invites even if the split rebalances.


ANTI-PATTERN / SAFETY OPTIONS
-----------------------------
  Random delays (/gr jitter on)   Varies each delay instead of fixed intervals
                                  (e.g. invite 1s -> 1-2.2s) so timing isn't
                                  clockwork-regular.
  Auto-backoff                    Watches for the server's "too many / too
                                  quickly" throttle message and pauses sends a
                                  few seconds automatically.
  Pause in combat (/gr combat on) Holds contacts while you're in combat.
  Pause in instances              Holds contacts while inside an instance
                                  (where the API exists on your client).
  Session cap (/gr set cap <n>)   Stop after N contacts in a run (0 = no cap).
  Blacklist (/gr black ...)       Never contact specific names.
  Class filter (/gr class ...)    Only contact certain classes
                                  (e.g. /gr class mage,priest; "all" clears).
  Level range (/gr set min/max)   Only sweep part of 1-60 (e.g. 60-60 for a
                                  max-level raiding guild).


ALL COMMANDS  (slash:  /gr)
---------------------------
  start | stop | pause | resume | status | config
  next                  (Forever build) Send the next /who or invite -- one
                        per press. Bind a key: Key Bindings > Guild Rawcruiter.
  reset                 Clear THIS session's scan list (keeps history).
  forget                Wipe the persistent invite history.
  hide                  Toggle auto-hiding the Who window during scans.
  msg <text>            Set the whisper message.
  class <list|all>      Class filter (comma/space separated, or "all").
  list                  Open the queue / blacklist / history window.
  quiet [on|off]        Hide the /who chat spam during a run (default on).
  black add|remove|list <name>
  set invite <s>        Seconds between contacts (1-10).
  set who <s>           Seconds between /who queries (1-15).
  set reinvite <days>   Don't re-contact within this many days (0 = never twice).
  set cap <n>           Session contact cap (0 = unlimited).
  set min <lvl> / set max <lvl>   Level range to sweep.
  set method auto|byname|invite|chat   Which guild-invite function to use.
  set mode invite|whisper|whisperinvite
  replymode notno|yesonly|any    When a whisper reply triggers the invite.
  noword / yesword add|remove|list <phrase>   Edit the reply word lists.
  collect [on|off] | send | inviteall | invite <name> | candidates | clearlist
  profile save|load|delete|list <name>
  ab [on|off|clear]     A/B testing (bare /gr ab opens the tab).
  autoscan [on|off|<seconds>]   Loop the scan with a rest between sweeps.
  stats | debug [on|off]
  jitter|sync|combat|instance [on|off]


HOW THE SCAN WORKS  (and its limits)
------------------------------------
* /who is the only way to enumerate players in 1.12; it returns at most ~49
  results per query (server-side cap, NOT bypassable even on Turtle) and is
  server-throttled. The addon sweeps level bands, widening when a query comes
  back light and narrowing (then splitting by class) where the population is
  dense -- spending as few /who queries as possible.
* On start it calls SetWhoToUI(1) so every /who returns a readable result event
  (otherwise small result sets leak to chat text and get missed).
* It only contacts players with NO guild, skips anyone contacted within the
  re-invite cooldown, and never contacts the same person twice in a run.
* /who is faction-locked in 1.12, so it only scans your own faction.
* Any runtime error stops the run cleanly with a "Stopped on error" message.


REMEMBERS WHO IT CONTACTED
--------------------------
Every contact is saved ACCOUNT-WIDE (and, with sync on, shared guild-wide), so
it survives /reload and restarts and is shared across your characters. Stale
entries past the cooldown are pruned automatically. "/gr forget" starts fresh.


PLEASE NOTE
-----------
Mass recruitment is against the rules on many servers even when limited to
guildless players. It's your account -- check your server's policy. Whisper or
whisper-on-reply mode is far less likely to get you reported than blind invites.
