GuildRecruiter  --  vanilla 1.12 / Turtle WoW guild recruitment helper   (v2.0)
==============================================================================

Scans online players with /who and sends paced guild contacts (invite and/or
whisper) to players who are NOT already in a guild. Built for vanilla (1.12)
clients and Turtle WoW.


INSTALL
-------
1. The "GuildRecruiter" folder goes in:
      <WoW>\Interface\AddOns\GuildRecruiter\GuildRecruiter.toc
2. FULLY RESTART the game the first time (a /reload won't register a new addon,
   and the .toc version bump needs a restart too).
3. Enable "GuildRecruiter" in the AddOns list at character select.

On load it prints which invite API it detected (e.g. "Invite API:
GuildInviteByName" on Turtle). If /ginvite works manually, the addon works.


QUICK START
-----------
  /gr config     Open the settings window (recommended).
  /gr list       Open the list window: view/edit the contact queue, the
                 blacklist, and the invite history (click a name to remove it;
                 add names to the blacklist from the box at the bottom).
  /gr start      Begin scanning + contacting (or click the minimap button).
  /gr stop       Halt. /gr pause + /gr resume keep your place.

The /who chat spam ("N players total" etc.) is hidden while a run is active
(/gr quiet off to show it).

A minimap button is added: LEFT-click opens settings, RIGHT-click starts/stops,
drag it around the minimap to reposition.


CONTACT MODES  (/gr set mode ...)
---------------------------------
  invite          Send a guild invite (default; original behaviour).
  whisper         Send only a whisper -- no invite. More polite / less spammy.
  whisperinvite   Whisper first; if the player whispers back, THEN invite them.

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
