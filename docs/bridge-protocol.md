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

Not routed via `CB_SendBotCommand`; sent with exact bag/slot coordinates when bridge is `present`:

| Packet | Capability | Reply | Notes |
|---|---|---|---|
| `RUN~ITEM_ACTION~<bot>~<token>~SELL_GREY~0~0` | `INVENTORY_BULK_SELL_V1` | `INVENTORY_ITEM_ACTION~<bot>~<token>~SELL_GREY~<itemId>~<OK/ERR>~<reason>~<moved>` | Bulk "Sell Trash" (`CB_BridgeBulkSell` / `CB_BridgeGroupBulkSell`); whisper `s gray` fallback |
| `RUN~ITEM_SELL~<bot>~<token>~<bag>~<slot>~<itemId>~<count>` | `ITEM_SELL_SINGLE_V1` | `INVENTORY_ITEM_SELL~<bot>~<token>~<OK/ERR>~<reason>~<bag>~<slot>~<itemId>~<sold>` | Single-item vendor sell (`CB_BridgeSellItem`, wired into `CB_DoSell`); whisper `s <link>` fallback when absent |

Queries (`co ?`, `nc ?`, `items`, `quests all`, `stats`, `talents spec list`) are never
allowlisted, so they always whisper and their replies arrive via `CHAT_MSG_WHISPER` as usual.

### Queries — `GET~`

| Packet | Purpose | Reply packets |
|---|---|---|
| `GET~ROSTER` | Bot names in the group | `ROSTER~` |
| `GET~DETAILS` | Per-bot identity/class | `DETAIL~` |
| `GET~STATES~<token>` | Framed strategy snapshot (`STATE_FRAMING_V1` capable) | `STATES_BEGIN~` / `STATE_BEGIN~` / `STATE_ITEM~` / `STATE_END~` / `STATES_END~` / `STATE_ABORT~` |
| `GET~STATES` | Per-bot strategy snapshot (legacy fallback) | `STATE~` |
| `GET~INVENTORY~<botName>~inv` | Bot's bag contents + money | `INV_BEGIN~` / `INV_SUMMARY~` / `INV_ITEM~` / `INV_END~` |
| `GET~QUESTS~ALL~<botName>~quests` | Bot's quest log | `QUESTS_BEGIN~` / `QUESTS_ITEM~` / `QUESTS_END~` |

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
| `QUESTS_BEGIN~<name>~<token>~<mode>` | — | Resets `entry.quests` |
| `QUESTS_ITEM~<name>~<token>~<mode>~<status>~<questID>~<questName>` | status `C`/`I`; name URL-encoded — but the current bridge fills it with the questID again (`SendQuestPacketsForBot`) | Appended as `{ id, status, name }`; `name` kept only when the field differs from the id (a real title), since quest Abandon must drop by title |
| `QUESTS_END~<name>~<token>~<mode>` | — | Renders if the quest frame is open |

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
