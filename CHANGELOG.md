# Changelog

## 0.6.0
- New: **Drops.** Every rare now has a Drops tab showing its loot: gold, tameable family, and items with drop chances, with the AH price if you use the Flip addon (vendor price otherwise). Search the Browse list by item name ("Mark of the Pack Leader") and filter to tameable rares.
- Drop rates seen in WoW Forever come from ForeverDB.net data and are tagged "seen". Items added in Forever are tagged "new" (small samples, rates are rough). Everything else is vanilla data and may differ in Forever.
- Scroll bars can now be clicked and dragged, not just scrolled with the wheel.
- Fixed the Settings page running off the bottom of the window.
- Fixed the blocked-action warning spamming inside dungeons. RareWatch now ignores instances (it is an open-world tracker) and draws the big alert text on its own frame instead of Blizzard's raid warning.
- Removed the respawn-source tooltip.

## 0.5.2
- Fixed the "blocked from an action only available to the Blizzard UI" warning on login and /reload (found via the taint log). RareWatch no longer registers for the combat log, which this client blocks, and no longer writes to the game's Esc-close list, which tainted the UI.

## 0.5.1
- Fixed the "RareWatch has been blocked from an action only available to the Blizzard UI" warning on login and /reload. RareWatch no longer edits your chat windows; it hides the sync channel's join messages with a chat filter instead.

## 0.5.0
- Automatic sync: kills, tames and sightings are shared between RareWatch users with no setup
- Hello and digest exchange so new users catch up on what they missed
- Other users' reports appear in History, even for rares you aren't tracking

## 0.4.2
- Earlier release
