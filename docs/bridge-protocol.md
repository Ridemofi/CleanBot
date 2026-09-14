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
| Solo with self-bot active (`NS.selfBotActive`) | `"WHISPER"` to the player's own name |
| Solo, no self-bot | no-op (nothing to talk to) |

The self-whisper works because the server bridge replies directly to the sender
(`player->SendDirectMessage`) and its chat hook fires on the whisper overload regardless
of recipient — so a solo player can complete the handshake and carry all traffic.

Server-side, `RUN~` commands route through `ExecuteSilentBotCommand()`, which calls
`botAI->HandleCommand(CHAT_MSG_WHISPER, command, requester)` — identical to a whisper,
but with no whisper log spam.

---

## Handshake & state machine

`NS.bridgeState` is `"unknown"` until detection resolves, then `"present"` or `"absent"`.

1. **Trigger** — `CB_StartBridgeDetection()` runs at `PLAYER_ENTERING_WORLD` (with retries
   at +1/+3/+6 s for late-loading rosters), on `PARTY_MEMBERS_CHANGED` /
   `RAID_ROSTER_UPDATE` while state is still `unknown`, and when self-bot is enabled.
   It needs either a group or an active self-bot, and is idempotent.
2. **Probe** — client sends `HELLO~1`.
3. **Resolve** — a reply starting `HELLO_ACK~` ⇒ `bridgeState = "present"`, accompanied
   by capability broadcast packets (`CAPS_BEGIN`, `CAPS~<list>`, `CAPS_END`), followed by
   an immediate debounced roster sync (`GET~ROSTER` / `GET~DETAILS` / `GET~STATES` or
   `GET~STATES~<token>`) and a linked-accounts fetch. No ack within **3 s** ⇒
   `bridgeState = "absent"`, and discovery falls back to whisper probing (`co ?` to each
   group member; only bots reply with a `Strategies:` line).

---

## Outbound packets

### Commands — `RUN~`

```
RUN~<OPCODE>~BOT~<botName>~~<command>
```

Sent by `NS.CB_SendBotCommand` **only** when the effective bridge state is `present` AND
the command matches an opcode allowlist (`CB_GetBridgeOpcode`); everything else whispers.
Allowlists mirror the server's `IsAllowed*()` checks — keep `Bridge.lua` in sync with
`MultiBotBridge.cpp` when the bridge updates.

| Opcode | Allowed commands | Notes |
|---|---|---|
| `COMBAT` | `co +/-` for: focus, dps assist, aoe, dps aoe, tank assist, avoid aoe, save mana, threat, behind, wait for attack — plus `wait for attack time <N>` (N = 0–60, no `co` prefix) | Matched case-insensitively |
| `POSITION` | `disperse disable`, `disperse set <N>` (0 < N ≤ 100) | Allowlisted plumbing — no CleanBot UI sends these yet |
| `LOOT` | `nc +loot`, `nc -loot`, `ll all/normal/gray/quest/skill` | Case-sensitive on the server |
| `RTI` | `rti <icon>`, `rti cc <icon>` (STAR/CIRCLE/DIAMOND/TRIANGLE/MOON/SQUARE/CROSS/SKULL), `attack rti target`, `pull rti target` | Allowlisted plumbing — no CleanBot UI sends these yet |

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
| `RUN~ITEM_DEPOSIT_EXACT~<bot>~<token>~BANK_DEPOSIT\|GBANK_DEPOSIT~<bag>~<slot>~<itemId>~<count>` | `ITEM_DEPOSIT_EXACT_V1` | `ITEM_DEPOSIT_EXACT~` | Deposit to personal / guild bank (`CB_BridgeDepositItem`); whisper `bank <link>` / `guild bank <link>` only when absent |
| `RUN~FORMATION~GROUP~~<token>~<formation>` | — | `FORMATION_ACK~` | Set group formation (8 tokens: `arrow`, `queue`, `near`, `melee`, `line`, `circle`, `chaos`, `shield`); `far` and absent fallback to `PARTY`/`RAID` |
| `RUN~CRAFT_RECIPE~<bot>~<token>~<skillId>~<spellId>~<itemId>` | — | `PROFESSION_RECIPE_CRAFT~` | Craft recipe without item target (`CB_BridgeCraftRecipe`) |
| `RUN~CRAFT_RECIPE_TARGET~<token>~<bot>~<skillId>~<spellId>~<bag>~<slot>~<itemId>` | — | `CRAFT_RECIPE_TARGET_RESULT~` | Craft recipe targeting inventory or equipment slot (`CB_BridgeCraftRecipeTarget`; bag 255 for paperdoll) |

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

`GET~ROSTER/DETAILS/STATES` are debounced: `CB_RequestSync` (0.5 s, all three) and
`CB_RequestStates` (0.4 s, states only — silent strategy reconciliation after a toggle).

---

## Inbound packets (`CHAT_MSG_ADDON`, prefix `MBOT`)

Parsed in `Bridge.lua`'s event handler. Fields are `~`-separated; `NS.CB_SplitOnce` walks
them. `<token>` fields are request-correlation echoes and are skipped on parse.

| Packet | Layout | Handling |
|---|---|---|
| `HELLO_ACK~…` | — | Drives the real state machine (see below) |
| `CAPS_BEGIN` | — | Resets capabilities table and initiates capability batch |
| `CAPS~<c1>,<c2>,…` | comma-separated capabilities | Populates `NS.capabilities`; detects `STATE_FRAMING_V1` (`NS.stateFramingCapable`) |
| `CAPS_END` | — | Marks `NS.capabilitiesResolved = true` |
| `ROSTER~<rec>;<rec>;…` | one record per bot: `<name>,<classId>,<level>,<mapId>,<alive>,<hp%>,<mana%>` (`classId` = numeric `Player::getClass()`) | Seeds a minimal entry (name + class) for each unknown bot |
| `DETAIL~<name>~?~?~<class>~…` | name + class | Establishes identity/class; preserves strategy data already parsed |
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
| `INV_END~<name>` | — | Clears the in-flight flag; renders if the inventory frame is open |
| `STATS~<name>~<level>~<gold>~<silver>~<copper>~<bagUsed>~<bagTotal>~<durPct>~<xpPct>~<manaPct>` | bot stats snapshot | Populates level, money, bag totals, durability, and XP; refreshes inventory and paperdoll XP bar |
| `FORMATIONS_BEGIN~<token>~<count>` | — | Marks start of formations batch |
| `FORMATIONS_ITEM~<token>~<encodedBotName>~<encodedFormation>` | per-bot formation snapshot | Updates entry.formation for bot; clears awaitingFormation unconditionally |
| `FORMATIONS_END~<token>~<sentCount>` | — | Clears formationsPending and refreshes UI controls |
| `FORMATION_ACK~<scope>~<target>~<token>~<succeeded>~<failed>~<formation>` | formation change acknowledgement | Updates group members' formation if succeeded > 0; triggers re-fetch on failure |
| `QUESTS_BEGIN~<name>~<token>~<mode>` | — | Resets `entry.quests` |
| `QUESTS_ITEM~<name>~<token>~<mode>~<status>~<questID>~<questName>` | status `C`/`I`; name URL-encoded — but the current bridge fills it with the questID again (`SendQuestPacketsForBot`) | Appended as `{ id, status, name }`; `name` kept only when the field differs from the id (a real title), since quest Abandon must drop by title |
| `QUESTS_END~<name>~<token>~<mode>` | — | Renders if the quest frame is open |
| `INV_EXACT_BEGIN~<name>~<token>` | — | Resets exact inventory staging |
| `INV_BAG~<name>~<token>~<kind>~<bag>~<slotStart>~<slotCount>~<bagItemId>` | bag layout | Accumulates exact bag totals |
| `INV_ITEM_LOC~<name>~<token>~<bag>~<slot>~<itemId>~<count>~<soulbound>` | one item with coordinates | Staged with bag/slot/itemId |
| `INV_EXACT_END~<name>~<token>` | — | Finalizes exact inventory and renders |
| `BANK_BEGIN~<name>~<token>` | — | Resets bank staging |
| `BANK_ITEM~<name>~<token>~<item>` | one bank item | Staged into bank list |
| `BANK_ERROR~<name>~<token>~<reason>` | error reason | Surfaces banker / guild-bank popup |
| `BANK_END~<name>~<token>` | — | Finalizes bank list and renders |
| `SB_BEGIN~<name>~<token>` (`SPELLBOOK_BEGIN~` alias) | — | Resets spellbook staging |
| `SB_ITEM~<name>~<token>~<spell>` (`SPELLBOOK_ITEM~` alias) | one spell | Staged into spellbook list |
| `SB_END~<name>~<token>` (`SPELLBOOK_END~` alias) | — | Sorts and renders spellbook |
| `INVENTORY_ITEM_ACTION~<bot>~<token>~SELL_GREY~<itemId>~<OK/ERR>~<reason>~<moved>` | bulk-sell result | Aggregates group-sell totals |
| `INVENTORY_ITEM_SELL~<bot>~<token>~<OK/ERR>~<reason>~<bag>~<slot>~<itemId>~<sold>` | single-sell result | Reconciles inventory |
| `INVENTORY_ITEM_EQUIP~<bot>~<token>~<OK/ERR>~<reason>` | equip result | Refreshes inventory and paperdoll |
| `INVENTORY_ITEM_USE~<bot>~<token>~<OK/ERR>~<reason>` | use result | Reconciles inventory |
| `INVENTORY_ITEM_DESTROY~<bot>~<token>~<OK/ERR>~<reason>` | destroy result | Reconciles inventory |
| `ITEM_DEPOSIT_EXACT~<bot>~<token>~<status>~<reason>~<action>~<bag>~<slot>~<itemId>~<count>~<moved>` | deposit result | Reconciles inventory and bank |
| `PROFESSION~<botName>~<profs>` | Semicolon-separated list: `<profKey>:<cur>/<max>;...` | Updates `entry.professions`, triggers `CB_OnProfessionsUpdated` |
| `PROFESSION_RECIPES_BEGIN~<bot>~<token>~<skillId>` | — | Resets profession recipe staging buffer |
| `PROFESSION_RECIPES_ITEM~<bot>~<token>~<skillId>~<spellId>~<itemId>~<difficulty>~<craftable>~<materials>` | Recipe metadata + reagents (`<matId>:<reqCount>:<availCount>;...`). Name, icon, and subType are client-resolved via `GetSpellInfo`/`GetItemInfo` | Staged into recipe list |
| `PROFESSION_RECIPES_END~<bot>~<token>~<skillId>` | — | Finalizes recipe cache and renders |
| `PROFESSION_RECIPE_CRAFT~<bot>~<token>~<skillId>~<spellId>~<itemId>~<OK/ERR>~<reason>` | Craft dispatch result | Confirms craft start or reports error; starts craft watcher |
| `CRAFT_RECIPE_TARGET_RESULT~<token>~<bot>~<OK/ERR>~<reason>~<skillId>~<spellId>~<bag>~<slot>~<itemId>` | Target craft result | Confirms enchant start or reports error; starts craft watcher |

---

## Debug override contract

`CB_EffectiveBridgeState()` (`return NS.debugBridgeOverride or NS.bridgeState`) is the
single decision point that makes `/cbdebug bridge on|off|reset` work (see
[debug-tools.md](debug-tools.md)). When adding bridge traffic:

1. **Bot commands** → send via `NS.CB_SendBotCommand` (already honors simulate mode and
   the override). Never call `SendChatMessage`/`SendAddonMessage` directly for these.
2. **Raw `GET~`/protocol traffic** → gate the present branch on
   `CB_EffectiveBridgeState() == "present"`, not raw `NS.bridgeState`, and provide a
   whisper fallback where one exists (mirror `CB_FetchInventory` / `CB_FetchQuests`).
3. **New inbound handlers** → add them *below* the
   `elseif CB_EffectiveBridgeState() ~= "present" then return` guard so data packets are
   dropped when the override forces no-bridge. Only `HELLO_ACK~` runs above the guard,
   because it drives the *real* state machine so `bridge reset` can restore the truth.

Lifecycle reads (detection guard/timeout, `HELLO_ACK` → present, roster-event trigger,
login/logout resets) intentionally stay on raw `NS.bridgeState` so the true state is
always tracked underneath the override.
