# Changelog

## 0.7.1
- **Join now works with full character names.** Requests went to the first name only (for example "Bluubs" instead of "Bluubs Tanockers"), so they failed with "No player named ... is currently playing". RareWatch now sends requests and invites to the full name.
- **Fixed repeated chat messages** like "X reports Humar the Pridelord tamed (58m ago)" for an event that happened long ago. On busy rares, new reports weren't being saved, so every copy from other players looked new and was announced again. New reports are now saved properly, and each event is announced in chat only once.

## 0.7.0-beta
- **Join a sighting.** When another RareWatch user reports a rare alive in the last 10 minutes, a **Join** button appears next to it in the Tracking and History tabs. Click it to ask that player to bring you onto their layer. They get a prompt with **Accept** / **Decline** that shows how risky accepting is for them (2 minutes to answer, so they can finish a fight first). Once they accept, RareWatch accepts the invite, waits for the game to move you, and leaves the group again.
- **Protects the player who found the rare.** The game only allows about 10 layer moves an hour, and past that it can move the host to your layer instead. RareWatch counts every layer move for all characters on your account and stops asking at 8; the host's RareWatch refuses requests at 8 too. If a host gets moved anyway, both players are told, that player can't ask the host again for an hour, and their count is set to full.
- **No spam.** You only ever see one request at a time, and at most 3 every 5 minutes. Anyone you decline can't ask you again for 10 minutes, and **Pause 15 min** on the prompt stops all requests for a while.
- No join requests in combat, while dead, in an instance or while in a group. Hosts only get requests for a rare they saw themselves, on the layer they're still on, from someone in the same zone, and at most 6 joins every 10 minutes.
- New in Settings > Sharing: **Let others join my layer** (on by default) and **Layer moves this hour**. Layers is now part of the Sharing card.
- New command: `/rwatch swaps` lists the layer moves used this hour.
- Beta: please report how joining works for you, especially if a host gets moved.

## 0.6.6
- **The window is resizable.** Drag the grip in the bottom-right corner. The rare list, the detail panel, Browse and History all grow with it, so a bigger window shows more rares and more rows without scrolling. The size is saved between sessions.
- New **Reset window size** button in Settings (Advanced) to go back to the default size.
- Columns widen with the window, so names, layers and players that were cut off ("by Maul Re...", "Layer A (Nazul Tornf...") show in full on a bigger window. The Tracking list column grows a little too.
- Settings is redesigned as cards that fill the window: two columns normally, three on a wide window, with rows that fit the window height. Labels are no longer cut off.

## 0.6.5
- **Sharing is back on game build 71037 and later.** Other RareWatch users' kills, tames and sightings show again in the Tracking and History tabs, and you get the chat alerts again.
- Layer numbers can't be matched between players on these builds, so a shared report shows the layer **as that player sees it**, e.g. "C (Bob's)". Their letter is not necessarily your letter, so use it as a hint about when and roughly where, not as a timer for your own layer. Timers for your own layer still come only from what you see.
- Reports from older RareWatch versions, which carry raw numbers, show as "unknown layer".
- Fixed History showing the same kill many times (once per player or layer that reported it). One kill within about 2 minutes is now one entry, and duplicates already saved are merged when you log in.
- History is now always in the order things happened (newest first), even when another player reports an older kill late. New search box on the History tab filters by rare, player or layer.
- Settings no longer says sharing is paused, and the sharing switches work normally again.

## 0.6.4
- **Layers on game build 71037 and later.** The game now gives every creature its own numbers, so a creature's number no longer names a layer (two creatures side by side differ in both the server and zone parts). RareWatch used to show those raw numbers as "your layer", which is why it changed from one creature to the next.
- Your layer is now read once from the first creature that is not a pet or totem, shown as a letter (A, B, C, in the order you have been on them this login) with the raw number under it, and held. It is read again only when the game moves you (`SHARD_TRANSFER`), you cross a zone border, or you log in. Creatures that were in view at a move or a border are ignored, since they belong to the layer or zone you just left. A `/reload` keeps your layer.
- Kills, sightings and tames are filed under the layer you are holding, not under the creature's own number.
- **Sharing is paused on these builds.** Layer numbers cannot be matched between players, so nothing is sent and incoming data is ignored. Settings and the footer say so. Your own timers keep working. Older builds are unchanged.
- Because of the new numbers, a layer you return to after a move counts as a new letter, and timers kept from before the patch no longer line up with your current layer.

## 0.6.3
- Fixed the empty Tracking page: the stray "Drops" tab no longer shows when nothing is tracked, and the hint text and Browse button are centred without cutting off words.

## 0.6.2
- Fixed: your current layer is now always shown on a rare's page, even when its last kill is old. Before, a kill older than 48 hours vanished from the list, so a rare you killed 3 days ago on your layer showed nothing. If nobody has reported that layer yet you get a "no reports yet" row.
- Timer history now scales with each rare's respawn time instead of a fixed 72 hours. Long-respawn rares keep their records for days (up to 14); shown records last about twice the respawn.
- Sharing hardening: messages from other players are validated (layer, age, size), rate limited per sender, and capped, so one bad or spammy client cannot flood or bloat your data.
- Less CPU: health events are only watched for your target and mouseover, nameplates are polled lightly, and window refreshes from incoming data are batched.
- Old data is cleaned up periodically, with caps on layers per rare, history entries and discovered rares.

## 0.6.1
- Fixed the "Blocked by the game: UNKNOWN()" spam in chat when using abilities or cooldowns in combat with the RareWatch window open. The window no longer changes the game's key-passing setting during combat.

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
