# RareWatch

A rare spawn tracker for **WoW Forever**. It tracks kills, tames and sightings of rare and rare-elite mobs, works out each rare's respawn window per layer, and shares what it learns with everyone else running RareWatch. No chat commands needed to report anything.

Download it from [CurseForge](https://www.curseforge.com/wow/addons/rarewatch), or grab this repo and copy the `RareWatch` folder into `World of Warcraft\_forever_\Interface\AddOns\`.

## What it does

- Spots rares around you and logs kills, tames and sightings
- Respawn timers per layer, with alerts when a rare is likely up
- 327 built-in rares with respawn estimates
- Shares sightings and kills with other RareWatch users automatically
- History tab, tracking list, and layer names you can set yourself

Type `/rwatch` in game to open it.

## Found a bug, or have an idea?

Open an [issue](../../issues). For bugs it helps a lot to include your RareWatch version and the output of `/rwatch debug`.

## Data and credits

The rare list comes from [QuestieDB](https://github.com/Questie/QuestieDB) (names, levels, Forever map coordinates), and the respawn estimates come from [cmangos classic-db](https://github.com/cmangos/classic-db). The estimates are emulator values, so they can differ from what Forever actually does. Drop rates seen in WoW Forever are data from [ForeverDB.net](https://foreverdb.net); items new in Forever were noted from Wowhead's WoW Forever pages, and the remaining drops are cmangos vanilla data. See [NOTICE.txt](NOTICE.txt). RareWatch is not affiliated with the Questie team, ForeverDB.net or Wowhead.

The interface uses the [Inter](https://rsms.me/inter/) font (SIL OFL) and [Tabler Icons](https://tabler.io/icons) (MIT). Their licenses are in `RareWatch/media`.

## License

GPL v3, see [LICENSE](LICENSE). The rare data above is GPL, so RareWatch as a whole is too.
