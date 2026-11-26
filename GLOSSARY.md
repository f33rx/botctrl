# BotCtrl

Playerbot commander for World of Warcraft 3.3.5a. These terms keep the source tree distinct from the running client copy.

## Language

**Dev repo**:
`~/src/f33rx/botctrl`, the only place BotCtrl source is edited and committed. Inner addon files live in `BotCtrl/` so a GitHub zip installs correctly.
_Avoid_: Install, client copy

**Install**:
The running WotLK client copy, rooted at `/mnt/c/Users/f33rx/Dropbox/My PC (LAPTOP-MSGHPUTN)/Downloads/ChromieCraft_3.3.5a`, where WoW loads `Interface/AddOns/BotCtrl/BotCtrl.toc`. **Install** means copy the inner `BotCtrl/` folder from the **Dev repo** into that path; do not commit in the **Install**.
_Avoid_: Dev repo, source

**Fight scheme**:
The current Fight page and its keybinds. 1–5, Shift-1–3, and Ctrl-1–5 always send the existing fight orders, whichever page is visible. Setup, Mark, and Clear stay on that pad. A tab must not move or rebind them.
_Avoid_: Tab, Order

**Order**:
A playerbot chat command. A tab click sends it to party or raid chat. A whisper is only for tank hold, mage water, and Setup.
_Avoid_: Fight scheme, Tab

**Tab**:
A click-only page of orders on the same pad. It does not replace the fight scheme.
_Avoid_: Fight scheme, Install

**Strat**:
A click-only tab. Party orders: `co +boost`, `co -boost`, `co +aoe`, `co -aoe`, `co +assist`, `co +threat`, `co +cc`, `co +avoid aoe`, `nc +loot`, `co ?`, `nc ?`. No `co !`, no `nc !`, no class-only strats.
_Avoid_: Fight scheme, Orders, Quest

**Orders**:
A click-only tab. Party orders: `release`, `revive`, `give leader`, `disperse disable`, `ll gray`, `ll quest`, `ll skill`, `ll all`, `open items`, `s vendor`, `reset`, `pet attack`, `pet follow`, `pet stay`, `pet passive`, `pet defensive`. `reset` here is the stuck-cast order, not `reset botAI` and not the frame-position slash.
_Avoid_: Fight scheme, Strat, Quest

**Quest**:
A click-only tab. `accept *` and `talk` only when the target is an NPC. `quests` and `quests all` have no target check. No abandon, no reward pick, no `rpg do quest`.
_Avoid_: Fight scheme, Orders
