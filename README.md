# RareWatch

A rare spawn tracker for **WoW Forever**. It tracks kills, tames and sightings of rare and rare-elite mobs, works out each rare's respawn window per layer, and shares what it learns with everyone else running RareWatch. No chat commands needed to report anything.

Download it from [CurseForge](https://www.curseforge.com/wow/addons/rarewatch), or grab this repo and copy the `RareWatch` folder into `World of Warcraft\_forever_\Interface\AddOns\`.

## What it does

- Spots rares around you and logs kills, tames and sightings
- Respawn timers per layer, with alerts when a rare is likely up
- 327 built-in rares with respawn estimates
- Shares sightings and kills with other RareWatch users automatically
- History tab, tracking list, and layer names you can set yourself
- **Join a sighting (beta):** when another RareWatch user sees a rare, ask to join their layer with one click

## Joining someone's layer (beta)

The game moves you to another layer when you join the group of a player who is on it. When another RareWatch user reports a rare alive in the last 10 minutes, a **Join** button appears next to the sighting (Tracking and History tabs):

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
