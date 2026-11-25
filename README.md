# RareWatch

A rare tracker for **WoW Forever**. It answers one question: is a rare in my zone up right now, on any layer another RareWatch user is on? If it is, one click asks that player to bring you onto their layer.

Download it from [CurseForge](https://www.curseforge.com/wow/addons/rarewatch), or grab this repo and copy the `RareWatch` folder into `World of Warcraft\_forever_\Interface\AddOns\`.

## What it does

- Every rare in the zone you're in is watched automatically. **Track** any other rare to hear about it from every zone.
- When you or another RareWatch user spots a watched rare, you get one alert, and it shows in the status box with a **Join** button
- Kills and tames show too ("Killed by Bob, 40m ago"), so you know when a sighting is over
- 327 built-in rares, plus rares discovered in Forever by RareWatch users, with drops, coordinates and waypoints
- Shares kills, tames and sightings with other RareWatch users automatically. No chat commands needed to report anything.
- Mute a rare to keep it listed without alerts

## Joining someone's layer

The game moves you to another layer when you join the group of a player who is on it. When another RareWatch user reports a rare alive in the last 10 minutes, a **Join** button appears next to the sighting (status box, Rares page and History):

1. Click **Join**. The player who saw the rare (the host) gets a prompt and clicks **Accept** or **Decline**. They have 2 minutes, so they can finish a fight first.
2. When they accept, RareWatch accepts the invite, waits for the game to move you, then leaves the group again.

The game only allows about 10 layer moves an hour. Past that it refuses, and it may move the **host** to your layer instead, losing them the rare. To stop that:

- RareWatch counts every layer move (from RareWatch, Layer-Swap or joining any group) for all characters on your account, and stops asking at 8. `/rwatch swaps` shows the count.
- The host's RareWatch also refuses requests from anyone at 8 or more.
- No requests in combat, while dead, in an instance, or while already in a group. The host only gets requests for a rare they saw themselves, on the layer they're still on, from someone in the same zone, and at most 6 joins every 10 minutes.
- No spam for the host: one request at a time, at most 3 every 5 minutes, anyone declined waits 10 minutes, and **Pause 15 min** on the prompt stops requests for a while.
- If the host is moved anyway, both sides are told, that player can't ask the host again for an hour, and their count is set to full.

Hosting is on by default. Turn it off in Settings > Sharing > **Let others join my layer**.

Type `/rwatch` in game to open it.

## Found a bug, or have an idea?

Open an [issue](../../issues). For bugs it helps a lot to include your RareWatch version and the output of `/rwatch debug`.

## Data and credits

The rare list comes from [QuestieDB](https://github.com/Questie/QuestieDB) (names, levels, Forever map coordinates), and the respawn estimates come from [cmangos classic-db](https://github.com/cmangos/classic-db). The estimates are emulator values, so they can differ from what Forever actually does. Drop rates seen in WoW Forever are data from [ForeverDB.net](https://foreverdb.net); items new in Forever were noted from Wowhead's WoW Forever pages, and the remaining drops are cmangos vanilla data. See [NOTICE.txt](NOTICE.txt). RareWatch is not affiliated with the Questie team, ForeverDB.net or Wowhead.

The interface uses the [Inter](https://rsms.me/inter/) font (SIL OFL) and [Tabler Icons](https://tabler.io/icons) (MIT). Their licenses are in `RareWatch/media`.

## License

GPL v3, see [LICENSE](LICENSE). The rare data above is GPL, so RareWatch as a whole is too.
