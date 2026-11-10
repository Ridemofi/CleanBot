# MultiBot Bridge Protocol

Developer reference for the `MBOT` addon-message protocol between CleanBot and the
server-side [mod-multibot-bridge](https://github.com/Wishmaster117/mod-multibot-bridge/blob/main/src/MultiBotBridge.cpp)
module. The client side lives in `Bridge.lua`; the bot-command survey is in
[playerbot-commands.md](playerbot-commands.md).

---

## Transport

All packets travel as addon messages with prefix `MBOT`:

```lua
SendAddonMessage("MBOT", msg, channel)
```

`CB_SendBridge(msg)` in `Bridge.lua` picks the channel:

| Situation | Channel |
|---|---|
| In a raid (`GetNumRaidMembers() > 0`) | `"RAID"` — `"PARTY"` does **not** reach raid members |
| In a party | `"PARTY"` |
| Solo, whether SelfBot is active or not | `"WHISPER"` to the player's own name |

The self-whisper works because the server bridge replies directly to the sender
(`player->SendDirectMessage`) and its chat hook fires on the whisper overload regardless
of recipient — so a solo player can complete the handshake and carry all traffic.

On bridge connection, CleanBot reads the current state with `GET~SELF_BOT~<token>`.
Checkbox changes use `RUN~SELF_BOT~<token>~ENABLE` or `RUN~SELF_BOT~<token>~DISABLE`.
The responses are `SELF_BOT_STATE~<token>~<OK/ERR>~<0/1>~<reason>` and
`SELF_BOT_RESULT~<token>~<OK/ERR>~<0/1>~<reason>`. CleanBot validates the response
against its latest request and updates the checkbox from the returned state, including
valid error responses. Requests time out after **5 seconds**; errors and timeouts do not
trigger a chat retry. When SelfBot is confirmed active with bridge present, CleanBot queries its
strategies silently with `GET~SELF_STRATEGY_STATE~<token>`, receiving standard `STATE_BEGIN~` /
`STATE_ITEM~` / `STATE_END~` framed packets, and directly queries its formation (`formation ?`) and
loot strategy (`ll ?`) via serialized silent whispers (since `GET~FORMATIONS~GROUP` excludes the
local player and the bridge lacks a loot query opcode); falls back to whispering `co ?` (which chains `nc ?`)
when the bridge is absent.

When the effective bridge state is not `present`, each click immediately sends
`.playerbots bot self` through chat and the server's system message updates the checkbox.
Clicks are not deferred during bridge detection. No SelfBot state is saved across sessions.

Server-side, the allowlisted text-command families (`COMBAT`, `POSITION`, `LOOT`, `RTI`)
use `ExecuteSilentBotCommand()`, which calls `botAI->HandleCommand` with
`CHAT_MSG_WHISPER` and a silent-routing prefix. Other `RUN~` endpoints, including
formation, inventory, and crafting, use their dedicated handlers.

---

## Handshake & state machine

`NS.bridgeState` is `"unknown"` until detection resolves, then `"present"` or `"absent"`.

1. **Trigger** — `CB_StartBridgeDetection()` runs at the first `PLAYER_ENTERING_WORLD`
   after loading the addon, on `PARTY_MEMBERS_CHANGED` /
   `RAID_ROSTER_UPDATE` while state is still `unknown`, and when SelfBot is confirmed active.
   It works while solo even with SelfBot inactive. Its internal checks skip detection when
   availability is already known or another detection is in progress.
   Scheduled checks at +1/+3/+6 s use the same guards; they do not resend `HELLO`
   while detection is pending or availability is already known.
2. **Probe** — client sends `HELLO~1`.
3. **Resolve** — a reply starting `HELLO_ACK~` ⇒ `bridgeState = "present"`, accompanied
   by capability broadcast packets (`CAPS_BEGIN`, `CAPS~<list>`, `CAPS_END`), followed by
   a debounced roster sync (`GET~ROSTER` / `GET~DETAILS` / `GET~STATES` or
   `GET~STATES~<token>`) and a linked-accounts fetch. No ack within **3 s** ⇒
   `bridgeState = "absent"`, and discovery falls back to whisper probing (`co ?` to each
   group member; only bots reply with a `Strategies:` line).

---

## Outbound packets

### Commands — `RUN~`

```
RUN~<OPCODE>~BOT~<botName>~<token>~<command>
```

Sent by `NS.CB_SendBotCommand` **only** when the effective bridge state is `present` AND
the command matches an opcode allowlist (`CB_GetBridgeOpcode`); everything else whispers.
Allowlists mirror the server's `IsAllowed*()` checks — keep `Bridge.lua` in sync with
`MultiBotBridge.cpp` when the bridge updates.

| Opcode | Allowed commands | Notes |
|---|---|---|
| `COMBAT` | `co +/-` for: focus, dps assist, aoe, dps aoe, tank assist, avoid aoe, save mana, threat, behind, wait for attack — plus `wait for attack time <N>` (N = 0–60, no `co` prefix) | Matched case-insensitively (server bridge caps at 60s; direct Playerbots whisper allows 0–99) |
| `POSITION` | `disperse disable`, `disperse set <N>` (0 < N ≤ 100) | Allowlisted plumbing — no CleanBot UI sends these yet |
| `LOOT` | `nc +loot`, `nc -loot`, `ll all/normal/gray/disenchant` | Server allowlist (`IsAllowedLootCommand`); case-sensitive on the server. CleanBot's `Bridge.lua` routes all 4 `ll` options through the bridge |
| `RTI` | `rti <icon>`, `rti cc <icon>` (STAR/CIRCLE/DIAMOND/TRIANGLE/MOON/SQUARE/CROSS/SKULL), `attack rti target`, `pull rti target` | Allowlisted plumbing — no CleanBot UI sends these yet |

The legacy `RUN~COMBAT` handler normalizes `co +dps aoe` / `co -dps aoe` to
`co +aoe` / `co -aoe`. These are different strategies in the Playerbots core: `dps aoe`
selects a target, while `aoe` enables a class rotation. CleanBot's Targeting dropdown
currently sends combined strategy changes, which do not match this single-command
allowlist and therefore use chat.

### Inventory actions — direct `RUN~ITEM_*` opcodes

Not routed via `CB_SendBotCommand`; bridge when `present` with exact bag/slot coordinates, whisper only when `absent`:

| Packet | Capability | Reply | Notes |
|---|---|---|---|
| `RUN~ITEM_ACTION~<bot>~<token>~SELL_GREY~0~0` | `INVENTORY_BULK_SELL_V1` | `INVENTORY_ITEM_ACTION~<bot>~<token>~SELL_GREY~<itemId>~<OK/ERR>~<reason>~<moved>` | Bulk "Sell Trash" (`CB_BridgeBulkSell` / `CB_BridgeGroupBulkSell`); whisper `s gray` only when absent |
| `RUN~ITEM_ACTION~<bot>~<token>~BANK_WITHDRAW~<itemId>~<count>` | — (matched by itemId+count, no coordinates) | `INVENTORY_ITEM_ACTION~<bot>~<token>~BANK_WITHDRAW~<itemId>~<OK/ERR>~<reason>~<moved>` | Bank withdraw (`CB_BridgeWithdrawItem`); whisper `bank -<link>` only when absent |
| `RUN~ITEM_SELL~<bot>~<token>~<bag>~<slot>~<itemId>~<count>` | `ITEM_SELL_SINGLE_V1` | `INVENTORY_ITEM_SELL~<bot>~<token>~<OK/ERR>~<reason>~<bag>~<slot>~<itemId>~<sold>` | Single-item vendor sell (`CB_BridgeSellItem`, wired into `CB_DoSell`); whisper `s <link>` only when absent |
| `RUN~ITEM_EQUIP~<bot>~<token>~<bag>~<slot>~<itemId>~<count>` | `ITEM_EQUIP_V1` | `INVENTORY_ITEM_EQUIP~` | Equip (`CB_BridgeEquipItem`); whisper `e <link>` only when absent |
| `RUN~ITEM_USE~<bot>~<token>~<bag>~<slot>~<itemId>~<count>` | `ITEM_USE_V1` | `INVENTORY_ITEM_USE~` | Use (`CB_BridgeUseItem`); whisper `u <link>` only when absent |
| `RUN~ITEM_DESTROY~<bot>~<token>~<bag>~<slot>~<itemId>~<count>` | `ITEM_DESTROY_V1` | `INVENTORY_ITEM_DESTROY~` | Destroy (`CB_BridgeDestroyItem`); whisper `destroy <link>` only when absent |
| `RUN~ITEM_DEPOSIT_EXACT~<bot>~<token>~BANK_DEPOSIT\|GBANK_DEPOSIT~<bag>~<slot>~<itemId>~<count>` | `ITEM_DEPOSIT_EXACT_V1` | `ITEM_DEPOSIT_EXACT~` | Deposit to personal / guild bank (`CB_BridgeDepositItem`); whisper `bank <link>` / `gb <link>` only when absent |
| `RUN~FORMATION~GROUP~~<token>~<formation>` | `FORMATION_V1` | `FORMATION_ACK~` | CleanBot routes all 9 tokens: `arrow`, `queue`, `near`, `melee`, `line`, `circle`, `chaos`, `shield`, `far`. Bridge-absent orders use `PARTY`/`RAID` chat. |
| `RUN~CRAFT_RECIPE~<bot>~<token>~<skillId>~<spellId>~<itemId>` | — | `PROFESSION_RECIPE_CRAFT~` | Craft recipe without item target (`CB_BridgeCraftRecipe`) |
| `RUN~CRAFT_RECIPE_TARGET~<token>~<bot>~<skillId>~<spellId>~<bag>~<slot>~<itemId>` | `CRAFT_RECIPE_TARGET_V1` | `CRAFT_RECIPE_TARGET_RESULT~` | Craft recipe targeting inventory or equipment slot (`CB_BridgeCraftRecipeTarget`; bag 255 for paperdoll) |
| `RUN~QUEST_ABANDON_TARGET~<token>~<bot>~<questId>` | `QUEST_ABANDON_TARGET_V1` | `QUEST_ABANDON_TARGET_RESULT~` | Abandon quest by ID (`CB_BridgeAbandonQuest`); whisper `drop <name>` only when absent |

Queries (`co ?`, `nc ?`, `ll ?`, plus `items` / `quests all` / `bank` / `stats` / `formation ?` / `talents spec list` when bridge is absent) are never
allowlisted, so they whisper and their replies arrive via `CHAT_MSG_WHISPER` as usual. When bridge is present, `stats` routes cleanly via `GET~STATS~<botName>`, formations route via `GET~FORMATIONS~GROUP~~<token>`, and premade specs route via `GET~TALENT_SPEC_LIST~<botName>~<token>`.

### Queries — `GET~`

| Packet | Purpose | Reply packets |
|---|---|---|
| `GET~ROSTER` | Bot names in the group | `ROSTER~` |
| `GET~DETAILS` | Per-bot identity/class | `DETAIL~` |
| `GET~STATES~<token>` | Framed strategy snapshot (`STATE_FRAMING_V1` capable) | `STATES_BEGIN~` / `STATE_BEGIN~` / `STATE_ITEM~` / `STATE_END~` / `STATES_END~` / `STATE_ABORT~` |
| `GET~STATES` | Per-bot strategy snapshot (legacy fallback) | `STATE~` |
| `GET~INVENTORY~<botName>~inv` | Bot's bag contents + money | `INV_BEGIN~` / `INV_SUMMARY~` / `INV_ITEM~` / `INV_END~` |
| `GET~INVENTORY_EXACT~<botName>~<token>` | Bot's bag contents with exact coordinates (`INVENTORY_EXACT_V1`) | `INV_EXACT_BEGIN~` / `INV_BAG~` / `INV_ITEM_LOC~` / `INV_EXACT_END~` |
| `GET~BANK~<botName>~<token>` | Bot's bank contents | `BANK_BEGIN~` / `BANK_ITEM~` / `BANK_ERROR~` / `BANK_END~` |
| `GET~SPELLBOOK~<botName>~<token>` | Bot's spellbook | `SB_BEGIN~` / `SB_ITEM~` / `SB_END~` (`SPELLBOOK_*` alias) |
| `GET~QUESTS~ALL~<botName>~quests` | Bot's quest log | `QUESTS_BEGIN~` / `QUESTS_ITEM~` / `QUESTS_END~` |
| `GET~STATS~<botName>` | Bot stats (level, money, bags, durability, XP, mana) | `STATS~` |
| `GET~FORMATIONS~GROUP~~<token>` | Bot movement formations for all group bots | `FORMATIONS_BEGIN~` / `FORMATIONS_ITEM~` / `FORMATIONS_END~` |
| `GET~TALENT_SPEC_LIST~<botName>~<token>` | Premade talent specs for bot's class and level | `TALENT_SPEC_BEGIN~` / `TALENT_SPEC_CURRENT~` / `TALENT_SPEC_ITEM~` / `TALENT_SPEC_END~` |
| `GET~PROFESSION~<botName>` | Bot's learned professions and current/max skill ranks | `PROFESSION~` |
| `GET~PROFESSION_RECIPES~<botName>~<skillId>~<token>` | Recipes learned by bot for specified skillId | `PROFESSION_RECIPES_BEGIN~` / `PROFESSION_RECIPES_ITEM~` / `PROFESSION_RECIPES_END~` |
| `GET~GAMEOBJECTS~<botName>~<token>` | Nearby interactive game objects (doors, chests, nodes) | `GAMEOBJECTS_BEGIN~` / `GAMEOBJECTS_ITEM~` / `GAMEOBJECTS_END~` / `GAMEOBJECTS_DONE~` |
| `GET~SELF_STRATEGY_STATE~<token>` | Combat and non-combat strategies for SelfBot | `STATE_BEGIN~` / `STATE_ITEM~` / `STATE_END~` |

`GET~ROSTER/DETAILS/STATES` are debounced: `CB_RequestSync` (0.5 s, all three) and
`CB_RequestStates` (0.4 s, states only — silent strategy reconciliation after a toggle).

---

## Inbound packets (`CHAT_MSG_ADDON`, prefix `MBOT`)

Parsed in `Bridge.lua`'s event handler. Fields are `~`-separated; `NS.CB_SplitOnce` walks
them. `<token>` fields echo request IDs. Correlation-aware handlers use them to match
pending requests, assemble staged responses, and invoke callbacks; simpler handlers
skip tokens they do not use.

| Packet | Layout | Handling |
|---|---|---|
| `HELLO_ACK~…` | — | Drives the real state machine (see below) |
| `ERR~<safeOpcode>~<safeRequestType>~<safeToken>~<reason>` | 4-field protocol error | Available on server; not currently handled by CleanBot |
| `CAPS_BEGIN` | — | Resets capabilities table and initiates capability batch |
| `CAPS~<c1>,<c2>,…` | comma-separated capabilities | Populates `NS.capabilities`; detects `STATE_FRAMING_V1` (`NS.stateFramingCapable`) |
| `CAPS_END` | — | Marks `NS.capabilitiesResolved = true` |
| `ROSTER~<rec>;<rec>;…` | one record per bot: `<name>,<classId>,<level>,<mapId>,<alive>,<hp%>,<mana%>` (`classId` = numeric `Player::getClass()`) | Seeds a minimal entry (name + class) for each unknown bot |
| `DETAIL~<name>~<race>~<gender>~<className>~<level>~<talentTab0>~<talentTab1>~<talentTab2>~<itemLevelScore>` | 9 fields exact bot detail | Establishes identity/class (CleanBot parses name and class; ignores level/talents/ilvl fields); preserves strategy data already parsed |
| `STATES_BEGIN~<token>~<botCount>` | starts global state sync | Initializes transaction tracker for `<token>` with expected bot count |
| `STATE_BEGIN~<token>~<name>~<cCount>~<nCount>` | starts bot state stream | Opens bot strategy accumulation buffer |
| `STATE_ITEM~<token>~<name>~<scope>~<idx>~<strat>` | single strategy (`scope`: C=combat, N=normal) | Stored at index in buffer |
| `STATE_END~<token>~<name>~<cCount>~<nCount>` | ends bot state stream | Assembles strategies, calls `CB_StoreCombat` / `CB_StoreNonCombat` and refreshes |
| `STATES_END~<token>~<sentCount>` | ends global state sync | Clears request token, refreshes tabs |
| `STATE_ABORT~<token>~<name>~<reason>` | abort notification | Clears active buffers and request token |
| `STATE~<name>~<combat>~<nonCombat>` | comma-separated strategy lists (legacy fallback) | Stored via `CB_StoreCombat` / `CB_StoreNonCombat` |
| `INV_BEGIN~<name>~…` | — | Resets `entry.inventory = { items = {} }` |
| `INV_SUMMARY~<name>~<token>~<gold>~<silver>~<copper>~<bagUsed>~<bagTotal>` | money + bag counts | Bag is **used/total** (the whisper-path `stats` reply is free/total — converted on parse) |
| `INV_ITEM~<name>~<token>~<encodedItem>` | one item per packet | Decoded by `NS.CB_ParseItemLine` |
| `INV_END~<name>~<token>` | — | Clears the in-flight flag; renders if the inventory frame is open |
| `STATS~<name>~<level>~<gold>~<silver>~<copper>~<bagUsed>~<bagTotal>~<durPct>~<xpPct>~<manaPct>` | bot stats snapshot | Populates level, money, bag totals, durability, and XP; refreshes inventory and paperdoll XP bar |
| `FORMATIONS_BEGIN~<token>~<count>` | — | Marks start of formations batch |
| `FORMATIONS_ITEM~<token>~<encodedBotName>~<encodedFormation>` | per-bot formation snapshot | Updates entry.formation for bot; clears awaitingFormation unconditionally |
| `FORMATIONS_END~<token>~<sentCount>` | — | Clears formationsPending and refreshes UI controls |
| `FORMATION_ACK~<scope>~<target>~<token>~<succeeded>~<failed>~<formation>` | formation change acknowledgement | Updates group members' formation if succeeded > 0; triggers re-fetch on failure |
| `TALENT_SPEC_BEGIN~<encodedBotName>~<token>` | — | Resets talent specs staging buffer |
| `TALENT_SPEC_CURRENT~<encodedBotName>~<token>~<activeSpec>~<tab1>~<tab2>~<tab3>` | `<activeSpec>` (1-based index) + 3 tab point counts | Available on server; not currently handled by CleanBot |
| `TALENT_SPEC_ITEM~<encodedBotName>~<token>~<specIndex>~<encodedSpecName>~<build>` | one premade talent spec (`build`: point distribution `t1-t2-t3`) | Staged into `req.staging` with parsed point distribution |
| `TALENT_SPEC_END~<encodedBotName>~<token>` | — | Finalizes premade specs list, stores in `NS.premadeSpecs[class]`, and refreshes UI dropdown |
| `QUESTS_BEGIN~<name>~<token>~<mode>` | — | Resets `entry.quests` |
| `QUESTS_ITEM~<name>~<token>~<mode>~<status>~<questID>~<questName>` | status `C`/`I`; name URL-encoded — but the current bridge fills it with the questID again (`SendQuestPacketsForBot`) | Appended as `{ id, status, name }`; `name` kept only when the field differs from the id (a real title), since quest Abandon must drop by title |
| `QUESTS_END~<name>~<token>~<mode>` | — | Renders if the quest frame is open |
| `QUESTS_DONE~<token>~<mode>` | batch completion | Available on server; not currently handled by CleanBot |
| `QUEST_REWARD_POLICY~AUTO\|MANUAL` | policy update | Available on server; not currently handled by CleanBot |
| `INV_EXACT_BEGIN~<name>~<token>` | — | Resets exact inventory staging |
| `INV_BAG~<name>~<token>~<kind>~<bag>~<slotStart>~<slotCount>~<bagItemId>` | bag layout | Accumulates exact bag totals |
| `INV_ITEM_LOC~<name>~<token>~<bag>~<slot>~<itemId>~<count>~<soulbound>` | one item with coordinates | Staged with bag/slot/itemId |
| `INV_EXACT_ERROR~<name>~<token>~<reason>` | exact inventory error (e.g. `RATE_LIMIT`) | Closes staging and surfaces error |
| `INV_EXACT_END~<name>~<token>` | — | Finalizes exact inventory and renders |
| `BANK_BEGIN~<name>~<token>` | — | Resets bank staging |
| `BANK_ITEM~<name>~<token>~<item>` | one bank item | Staged into bank list |
| `BANK_ERROR~<name>~<token>~<reason>` | error reason | Surfaces banker / guild-bank popup |
| `BANK_END~<name>~<token>` | — | Finalizes bank list and renders |
| `GBANK_BEGIN~<name>~<token>` | — | Available on server; not currently handled by CleanBot |
| `GBANK_ITEM~<name>~<token>~<item>` | one guild bank item | Available on server; not currently handled by CleanBot |
| `GBANK_ERROR~<name>~<token>~<reason>` | error reason | Available on server; not currently handled by CleanBot |
| `GBANK_END~<name>~<token>` | — | Available on server; not currently handled by CleanBot |
| `SB_BEGIN~<name>~<token>` (`SPELLBOOK_BEGIN~` alias) | — | Resets spellbook staging |
| `SB_ITEM~<name>~<token>~<spellId>~<ignored>` (`SPELLBOOK_ITEM~` alias) | one spell | Staged into spellbook list (`ignored` 1/0 tracks server skip list) |
| `SB_END~<name>~<token>` (`SPELLBOOK_END~` alias) | — | Sorts and renders spellbook |
| `SPELLBOOK_CAST_ACK~<token>~<spellId>~<OK/ERR>~<targetName>~<reason>` | cast confirmation (5 fields) | Available on server; not currently handled by CleanBot |
| `SPELLBOOK_IGNORE_ACK~<token>~<spellId>~<action>~<OK/ERR>~<ignored>~<reason>` | ignore confirmation (6 fields, `action`: `IGNORE` / `ALLOW`) | Available on server; not currently handled by CleanBot |
| `BUYBACK_RESULT~<bot>~<token>~<OK/ERR>~<reason>~<slot>~<itemId>~<count>~<price>` | buyback confirmation (8 fields) | Available on server; not currently handled by CleanBot |
| `INVENTORY_ITEM_ACTION~<bot>~<token>~SELL_GREY~<itemId>~<OK/ERR>~<reason>~<moved>` | bulk-sell result | Aggregates group-sell totals |
| `INVENTORY_ITEM_SELL~<bot>~<token>~<OK/ERR>~<reason>~<srcBag>~<srcSlot>~<srcItemId>~<soldCount>` | single-sell result (8 fields) | Reconciles inventory |
| `INVENTORY_ITEM_EQUIP~<bot>~<token>~<OK/ERR>~<reason>~<srcBag>~<srcSlot>~<dstSlot>` | equip result (7 fields) | Refreshes inventory and paperdoll |
| `INVENTORY_ITEM_USE~<bot>~<token>~<OK/ERR>~<reason>~<srcBag>~<srcSlot>~<srcItemId>` | use result (7 fields) | Reconciles inventory |
| `INVENTORY_ITEM_DESTROY~<bot>~<token>~<OK/ERR>~<reason>~<srcBag>~<srcSlot>~<srcItemId>` | destroy result (7 fields) | Reconciles inventory |
| `ITEM_DEPOSIT_EXACT~<bot>~<token>~<status>~<reason>~<action>~<bag>~<slot>~<itemId>~<count>~<moved>` | deposit result | Reconciles inventory and bank |
| `PROFESSION~<botName>~<profs>` | Semicolon-separated list: `<profKey>:<cur>/<max>;...` | Updates `entry.professions`, triggers `CB_OnProfessionsUpdated` |
| `PROFESSION_RECIPES_BEGIN~<bot>~<token>~<skillId>` | — | Resets profession recipe staging buffer |
| `PROFESSION_RECIPES_ITEM~<bot>~<token>~<skillId>~<spellId>~<itemId>~<difficulty>~<craftable>~<materials>` | Recipe metadata + reagents (`<matId>:<reqCount>:<availCount>;...`). Name, icon, and subType are client-resolved via `GetSpellInfo`/`GetItemInfo` | Staged into recipe list |
| `PROFESSION_RECIPES_END~<bot>~<token>~<skillId>` | — | Finalizes recipe cache and renders |
| `PROFESSION_RECIPE_CRAFT~<bot>~<token>~<skillId>~<spellId>~<itemId>~<OK/ERR>~<reason>` | Craft dispatch result | Confirms craft start or reports error; starts craft watcher |
| `CRAFT_RECIPE_TARGET_RESULT~<token>~<bot>~<OK/ERR>~<reason>~<skillId>~<spellId>~<bag>~<slot>~<itemId>` | Target craft result | Confirms enchant start or reports error; starts craft watcher |
| `QUEST_ABANDON_TARGET_RESULT~<token>~<rawName>~<questId>~<status>~<reason>~<abandoned>` | quest abandonment result | Reconciles quest list; executes completion callback |
| `GAMEOBJECTS_BEGIN~<rawName>~<token>` | — | Resets nearby game objects buffer |
| `GAMEOBJECTS_ITEM~<rawName>~<token>~<encodedLine>` | one object link (`|Hfound:guid:entry:|h[Name]|h|r`) | Decodes and stages game object into target list |
| `GAMEOBJECTS_END~<rawName>~<token>` | — | Marks object collection complete |
| `GAMEOBJECTS_DONE~<token>` | — | Finalizes transaction and invokes object selector callback |

---

## Debug override contract

`CB_EffectiveBridgeState()` (`return NS.debugBridgeOverride or NS.bridgeState`) is the
single decision point that makes `/cbdebug bridge on|off|reset` work (see
[debug-tools.md](debug-tools.md)). When adding bridge traffic:

1. **Bot commands** → send via `NS.CB_SendBotCommand` (already honors simulate mode and
   the override). Never call `SendChatMessage`/`SendAddonMessage` directly for these.
2. **Raw `GET~`/protocol traffic** → gate the present branch on
   `CB_EffectiveBridgeState() == "present"`, not raw `NS.bridgeState`, and provide a
   whisper path when the effective state is absent and that feature supports one
   (mirror `CB_FetchInventory` / `CB_FetchQuests`). Bridge-only features remain unavailable.
3. **New inbound handlers** → add them *below* the
   `elseif CB_EffectiveBridgeState() ~= "present" then return` guard so data packets are
   dropped when the override forces no-bridge. `HELLO_ACK~` and
   `CAPS_BEGIN` / `CAPS~` / `CAPS_END` run above the guard so the real handshake and
   negotiated capabilities remain tracked underneath the override.

Lifecycle reads (detection guard/timeout, `HELLO_ACK` → present, roster-event trigger,
world-entry resets) intentionally stay on raw `NS.bridgeState` so the true state is
always tracked underneath the override.

---

## Server rate limits

To prevent addon spam and packet saturation, `mod-multibot-bridge` (`MultiBotBridge.cpp`) enforces burst and window limits tracked per requester and category:

| Action / Packet Category | Rate Limit (Requests / Window) | Response on Exceeded |
|---|---|---|
| `GET_INVENTORY_EXACT` | 8 / 2s | `INV_EXACT_ERROR~<name>~<token>~RATE_LIMIT` |
| `GET_BANK` / `GET_GBANK` | 4 / 2s | `BANK_ERROR` / `GBANK_ERROR RATE_LIMIT` |
| `CRAFT_RECIPE` | 4 / 2s | Craft rejected with error message |
| `QUEST_ABANDON` | 4 / 2s | Abandon rejected with error message |
| `RUN~STRATEGY` mutations (separate from legacy `RUN~COMBAT`) | 24 / 2s | Mutation rejected |
| `ITEM_ACTION` (bulk sell, bank withdraw) | 24 / 2s per requester | Action rejected |
| Direct inventory actions (`ITEM_EQUIP`, `ITEM_UNEQUIP`, `ITEM_DESTROY`, `ITEM_USE`, `ITEM_SELL`, `ITEM_DEPOSIT_EXACT`, `ITEM_MOVE`, `BUYBACK_ITEM`) | 8 / 2s per requester per category | Action rejected (each category has an independent bucket) |
| `FORMATION_QUERY` | 8 / 2s | Query throttled |
