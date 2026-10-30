# Playerbot Strategy Survey (`co` / `nc` / `de` arguments)

Companion to [playerbot-commands.md](playerbot-commands.md) (which covers the command
forms and the `+ - ~ ! ?` operators). The wiki is sparse, so everything here was read
directly from the mod-playerbots source: the registry in
`src/Ai/Base/StrategyContext.h`, the strategy
implementations in `src/Ai/Base/Strategy/*.cpp`, and every class registry in
`src/Ai/Class/<Class>/<Class>AiObjectContext.cpp`.

**Status legend:** ✅ exposed in CleanBot's UI today · ⬜ available, unused.

This is a reference, not a roadmap — nothing here is committed work.

---

## How strategies actually work

- `co` edits the **combat-state** strategy list, `nc` the **non-combat** list, and `de`
  the **dead-state** list (`ChangeStrategyAction.cpp`). CleanBot exposes controls for
  `co` and `nc`. These state-engine strategies run while their state is active;
  reaction-engine strategies are managed separately.
- A strategy is not a single switch. It contributes:
  - **Trigger → action wirings** with a numeric *relevance* (e.g. `"no target"` →
    `"attack anything"` @ 4.0). Each AI tick, the highest-relevance triggered action
    wins.
  - **Multipliers** that scale *other* actions' relevance. **0.0 is a hard veto** —
    this is how one strategy silently disables another while both show as "on".
- Spec-type class strategies live in sibling-replacing contexts: `co +fury`
  automatically drops `arms`/`tank`; `co +shadow` drops `heal`/`holy heal`, etc.
- Role tokens (`tank`, `heal`, `dps`, `aoe`, `cc`, `boost`, …) are **registered per
  class** with uneven coverage — see the class matrix below. Toggling an unregistered
  token is a no-op for that class.

---

## Default strategy loadout

Base strategy requests from `AiFactory.cpp` (`AddDefaultCombatStrategies`,
`AddDefaultNonCombatStrategies`, `AddDefaultDeadStrategies`). Effective lists depend on
the class registry, configured strategy overrides, and instance adjustments.
`PlayerbotAI::ResetStrategies` rebuilds the state-engine lists through these factories.
Spec branches key off the talent tab (`GetPlayerSpecTab`). This is why several CleanBot
toggles read as **on** the moment a bot is queried.

**Combat (`co`) — base requests, non-BG:** `racials`, `chat`, `default`, `cast time`,
`potions`, `duel`, `boost` (class-registered; absent for Warrior/Hunter/DK); plus `formation`;
`avoid aoe` when
`Playerbots.AutoAvoidAoe` and the bot has a real-player master. Then role-conditional:
`tank face` (tanks), `behind` (melee DPS), `save mana` + `healer dps` (healers, config-gated).
**No movement strategy by default** — in-combat movement is `close`/`ranged` + the spec.
Per spec (representative): Warrior prot → `prot tank assist pull pull back aoe`, arms/fury →
`arms|fury aoe dps assist`; Priest shadow → `shadow shadow debuff shadow aoe` (+`dps assist cure`),
disc → `disc` (+`dps assist cure`), holy → `holy heal` (+`dps assist cure`); Mage → spec + `bdps|bmana` + `dps assist cure cc aoe`;
Paladin prot → `prot tank assist pull pull back bthreat barmor cure`, holy → `holy dps assist cure bcast`, ret → `ret dps assist cure baoe`; Druid feral-cat →
`cat aoe cc dps assist feral charge`, bear → `bear tank assist pull pull back feral charge`, balance → `balance cure aoe cc dps assist`, resto → `resto cure dps assist tranquility`;
DK blood → `blood tank assist pull pull back`, frost/unholy → `frost|unholy + *aoe + dps assist`;
Hunter → `bm|mm|surv` + `cc dps assist aoe bdps`; Rogue → `combat|assassin aoe dps assist`;
Warlock → `affli|demo|destro` + a curse (+`meta melee` for demo) + `cc dps assist aoe`;
Shaman → `ele|enh|resto` + totems + `dps assist cure aoe`.

**Non-combat (`nc`) — base requests, non-BG:** `nc`, `food`, `chat`, **`follow`**, `default`,
`force rebuff`, `quest`, `loot`, `gather`, `duel`, `pvp`, `buff`, `mount`, `emote`. So **Follow, Eat & Drink,
Auto Loot, Auto Gather, Enable PvP, Force Rebuff** are all **on by default**. Plus per-class `dps assist` /
`tank assist` + class buffs/cures/pet (e.g. Hunter `bdps dps assist pet`; Paladin prot adds
`bsanc` at L20+, else `bmight`).

**Dead:** `dead`, `chat`, `default`, `follow`. The factory requests `stay` first, but
adding its exclusive sibling `follow` removes it. Solo random bots then drop `follow`.

---

## Generic strategies (StrategyContext.h — available to every class)

### Targeting & assist

| Token | Status | What the source does |
|---|---|---|
| `tank assist` | ✅ | Trigger `"tank assist"` → peel mobs off non-tanks @ 50. The **Peel** option of the **Targeting** dropdown. |
| `dps assist` | ✅ | `"not dps target active"` → attack the group's DPS target @ 50. The **Focus Down** option of the **Targeting** dropdown. |
| `dps aoe` | ✅ | `"not dps aoe target active"` → `DpsAoeTargetValue`: honors RTI/skull, then picks the **highest-HP attacker** (`FindMaxHpTargetStrategy`) to anchor on while the class AoE rotation cleaves. The AoE *target picker* — distinct from the class `aoe` *rotation*. The **Cleave Anchor** option of the **Targeting** dropdown. |

These three live in `AssistStrategyContext`, built `(false, true)` → `supportsSiblings = true`,
so they are **mutually exclusive** — one **Targeting** dropdown enforces that. The assist axis
is **orthogonal to the rotation Role** (tank/heal/dps); any role may pick a focus target (a Healer
set to Focus Down makes its Healer-DPS damage assist the group's kill target).

| Token | Status | What the source does |
|---|---|---|
| `attack tagged` | ⬜ | Allows attacking mobs tagged by other players. |
| `tell target` | ⬜ | Announces target changes in chat. |
| `focus heal targets` | ⬜ | Restricts healing to an explicit focus list. |

### Combat multipliers (the veto layer)

| Token | Status | What the source does |
|---|---|---|
| `threat` | ✅ | Vetoes (×0) any threat-generating action once the bot's threat reaches **80%** of the *tank's* threat — AoE actions already at **50%**. Bypassed when solo or when the `"neglect threat"` value is set. Threat is measured relative to the tank (`ThreatValues.cpp`), so see conflict #2. |
| `focus` | ✅ | FocusMultiplier vetoes **all AoE actions (except heals) and debuffs on attackers** — pure priority-target damage. CleanBot calls this **"Focus Fire"** and bundles it with **"AoE Rotation"** (`aoe`) in the DPS role's exclusive **"Rotation"** dropdown (the third option, "Balanced", leaves both off) — the two hard-conflict (see conflict #1), so a single selector enforces it. |
| `wait for attack` | ✅ | Vetoes **every** action except a whitelist (keep-safe-distance, `dps assist`, `set facing`, pull actions) until `wait for attack time` seconds after combat starts. Heals are **not** whitelisted — bots genuinely wait to heal too. Requires a group and a real-player master; skipped against player targets. |
| `cast time` | ✅ | Deprioritizes (×0.1) eligible current-target casts whose cast time exceeds the target's estimated remaining life at current group DPS. Lower-priority casts can still execute. "Smart Cast Time" checkbox in the Timing Controls section (default-on, universal); pure on/off — no value (the threshold is computed dynamically), so it is a checkbox, not a slider. |
| `save mana` | ✅ | Healer-only: below the config mana threshold, vetoes heals that are mana-inefficient relative to the damage actually being taken (tanks get more lenient rules than non-tanks). |
| `passive` | ✅ | PassiveMultiplier vetoes essentially everything — the "stand there" switch. "Passive" checkbox in the Commands tab (sent as `co +/-passive`; parse-only entry in `STRATEGY_MAP`). |

### Positioning & movement in combat

| Token | Status | What the source does |
|---|---|---|
| `close` | ✅ | `"enemy out of melee"` → `"reach melee"` @ HIGH+1. The melee engagement range. Exposed in the **"Distance"** exclusive dropdown (Close / Ranged / Default) at the top of the Positioning group. |
| `ranged` | ✅ | `"enemy too close for spell"` → `"flee"` @ MOVE+4. The caster engagement range. The other half of the **"Distance"** dropdown. |
| `behind` | ✅ | `"not behind target"` → `"set behind"` @ MOVE+7. |
| `kite` | ✅ | `"has aggro"` → `"runaway"` @ 51 — flee while being chased. "Kite" checkbox in the Positioning group (independent of the Distance dropdown — pairs with `ranged`). |
| `avoid aoe` | ✅ | Default action `"avoid aoe"` at **emergency** priority — steps out of hostile ground effects. |
| `tank face` | ✅ | Default action `"tank face"` @ MOVE — turns the mob away from the group. |
| `formation` | ⬜ | Default action `"combat formation move"` @ NORMAL — holds group formation in combat. |
| `move from group` | ⬜ | Spreads away from group members (opposite instinct to `formation`). |
| `pull back` | ✅ | `"return to pull position"` → walk the mob back to where the pull started @ MOVE+5. |
| `adds` | ✅ | `"possible adds"` → `"flee with pet"` @ 60 — attempt to retreat when potential adds are detected; recall the pet if present. "Avoid Adds" checkbox in the Positioning group. |

(`pull` itself is a class-registered token — see the matrix. During a pull,
PullMultiplier vetoes non-pull actions (except `follow` and `set facing`), by design; the pull shot auto-selects
throw/gun/bow/crossbow from the equipped ranged weapon.)

### Aggression / target acquisition

| Token | Status | What the source does |
|---|---|---|
| `aggressive` | ✅ | `"no target"` → `"aggressive target"` @ 4 — auto-acquire anything hostile. "Aggressive" checkbox in the Combat Control group. |
| `grind` | ✅ | `"no target"` → `"attack anything"` @ 4, plus baseline food/drink upkeep. |
| `pvp` | ✅ | `"enemy player near"` → `"attack enemy player"` @ 55. |
| `duel` | ⬜ | Accept duel requests and attack the duel opponent. |
| `start duel` | ⬜ | Registered strategy marker; its `InitTriggers` is empty and it declares no default actions. |

### Utility and reaction strategies

CleanBot exposes `food`, `loot`, and `gather` in Non-Combat, and `mark rti`, `potions`,
and `racials` in Combat. The server runs `react` in its separate reaction engine.

| Token | Status | What the source does |
|---|---|---|
| `food` | ✅ | Eat/drink when low on health/mana. |
| `loot` | ✅ | Loot nearby corpses after combat. |
| `gather` | ✅ | Gather nearby herb/ore/etc. nodes. |
| `mark rti` | ✅ | Auto-mark unmarked attackers with raid target icons. |
| `potions` | ✅ | Use healing/mana potions. "Use Potions" checkbox in the Combat tab's Combat Control group (default-on, universal). |
| `racials` | ✅ | Use racial abilities. "Use Racials" checkbox in the Combat tab's Combat Control group (default-on, universal). |
| `mount` | ⬜ | Mount/dismount to match the master (state checked on a timer). |
| `collision` | ⬜ | `"collision"` → `"move out of collision"` @ 2 — stops bots standing inside each other. |
| `sit` | ⬜ | Sit when idle. |
| `move random` | ⬜ | `"often"` → `"move random"` @ 1.5 — idle wandering. |
| `worldbuff` | ⬜ | `"need world buff"` → fetch configured world buffs. |
| `use bobber` / `master fishing` | ⬜ | Fishing: click bobbers / fish alongside the master (move near water, cast, equip upgrades). |
| `emote` | ⬜ | Ambient emote chatter. |
| `reveal` | ⬜ | Announce and ping nearby gathering nodes (`RevealGatheringItemAction`). |
| `force rebuff` | ⬜ | Audits and forces rebuffing group members; enabled by default in non-combat (`AiFactory.cpp:587`). |
| `react` | ⬜ | Default reaction-engine strategy: wakes the main AI when group attackers first appear so idling or eating/drinking bots acquire targets immediately (`ReactionStrategy.cpp`). |

### Movement modes (also set by the one-shot commands)

These four live in `MovementStrategyContext`, built `NamedObjectContext<Strategy>(false, true)`
→ `supportsSiblings = true`, so they are **mutually exclusive**: `Engine::addStrategy` calls
`GetSiblingStrategy` and removes the other three before adding one (`src/Bot/Engine/Engine.cpp`,
`NamedObjectContext.h`). Exclusivity is **per state engine**, and the two states genuinely
differ: a fresh bot has `follow` in its **non-combat** defaults only
(`AiFactory::AddDefaultNonCombatStrategies`) — the base combat list has no
movement strategy by default (combat positioning `close`/`ranged`/`kite` drives it) — but the
combat engine *does* act on movement when set (`PlayerbotAI::ChangeEngineOnCombat` snapshots a
combat-`stay` hold position). CleanBot therefore exposes **two** exclusive dropdowns:
**Non-Combat Movement** (Non-Combat tab, default Follow) and **Combat Movement** (Combat tab,
default Free Roam), each with a **Free Roam** entry that clears movement modes for that state.

| Token | Status | What the source does |
|---|---|---|
| `follow` | ✅ | Follow the master (FollowMasterStrategy). |
| `stay` | ✅ | Hold position. |
| `guard` | ✅ | Guard a spot — engage what comes, return after. |
| `runaway` | ✅ | Keep distance from enemies (`RunAwayAction` → `Flee`; see note). |
| `return` | ⬜ | Return to a saved position (`ReturnStrategy` in core, not in the exclusive movement group). |
| `flee` | ❌ | NOT a strategy in C++. `flee` is only an action and a chat shortcut (`FleeChatShortcutAction`) that applies `+follow,-stay,+passive`. |

**Flee vs. runaway (source-verified, `MovementActions.cpp` / `FleeManager.cpp`).** Both resolve to a
*single* `MoveTo` per execution — the continuous "keep your distance" feel comes from a strategy
**re-firing the action each tick** (with `runaway` rate-limited by `lastFlee`, ~2–`returnDelay`/1000 s in `MovementAction::Flee`), not from the
action looping.
- **`flee` action** (`FleeAction::Execute`) → `MoveAway(current target, fleeDistance, backwards)`: steps
  straight away from the current target along the first valid angle in a ±90° fan. `isUseful` only when
  the target is in **melee range** and the bot isn't channeling — a no-op at range. Does **not** use
  `FleeManager`.
- **`runaway` action** (`RunAwayAction::Execute`) → `Flee(group leader)`: if the bot is the enemy's
  target it moves *near* a friendly tank/master; otherwise near dps/healers; failing that it falls back
  to **`FleeManager`**, which samples a ring at `GetRange("flee")`, discards directions toward enemies /
  no-LOS / water, and picks the point **maximizing summed distance to all nearby enemies**.
- **`flee` shortcut**: There is NO `FleeStrategy` in C++. When a player whispers `flee`, `FleeChatShortcutAction` executes `ChangeStrategy("+follow,-stay,+passive")` to pull the bot back.

- Relevant config: `Playerbots.FleeDistance`, `Playerbots.ReturnDelay` (the flee throttle),
  `Playerbots.SightDistance`.

The same `supportsSiblings` mechanism makes the **assist** group (`dps assist` / `dps aoe` /
`tank assist`) and the **quest** group (`quest` / `accept all quests`) mutually exclusive too.

### World / system (mostly managed by the server or other commands)

`rpg`, `new rpg`, `travel`, `explore` — ambient "live a life" behavior for unmanaged
bots; `map` / `map full` — position reporting; `custom` — user-defined strategy from
the DB (`playerbots_custom_strategy`); `quest` / `accept all quests` — quest
interaction policy; `group`, `guild`, `lfg`, `ready check`, `dead` (release/resurrect
flow), `maintenance`, `chat`, `default` — internal plumbing; usually best left alone.

### Battlegrounds

`bg`, `battleground`, `warsong`, `alterac`, `arathi`, `eye`, `isle`, `arena`, `rtsc`
— BG-specific objective logic, normally toggled by the server when a bot enters a BG.

### Debug

`debug`, `debug move`, `debug rpg`, `debug spell`, `debug quest` — verbose tracing.

---

## Class coverage matrix (who registers which shared token)

Grepped verbatim from each `<Class>AiObjectContext.cpp` strategy factory. Toggling a
token a class doesn't register is a **no-op** for that bot.

| Token | War | Pal | Hun | Rog | Pri | Sha | Mag | Lock | Dru | DK |
|---|---|---|---|---|---|---|---|---|---|---|
| `nc` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `pull` | ✓ | ✓ | — | ✓ | ✓ | — | ✓ | ✓ | ✓ | ✓ |
| `aoe` | ✓ | — | ✓ | ✓ | ✓¹ | ✓ | ✓ | ✓ | ✓ | —² |
| `tank` | ✓ | ✓ | — | — | — | — | — | ✓ | ✓³ | ✓³ |
| `dps` | — | ✓ | — | — | ✓³ | ✓³ | — | — | ✓³ | — |
| `heal` | — | ✓ | — | — | ✓ | ✓³ | — | — | ✓³ | — |
| `cc` | — | ✓ | ✓ | ✓ | ✓ | — | ✓ | ✓ | ✓ | — |
| `boost` | — | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| `cure` | — | ✓ | — | — | ✓ | ✓ | ✓ | — | ✓ | — |
| `buff` | — | — | — | — | ✓ | — | ✓ | — | ✓ | — |
| `healer dps` | — | ✓ | — | — | ✓ | ✓ | — | — | ✓ | — |
| `offheal` | — | ✓ | — | — | — | —⁴ | — | — | ✓ | — |
| `melee` | — | — | — | — | — | ✓³ | — | — | — | — |
| `caster` | — | — | — | — | — | ✓³ | — | — | — | — |

¹ Priest `aoe` is an alias of `shadow aoe`. ² DK uses `frost aoe` / `unholy aoe`
instead. ³ Alias of a spec strategy: Druid `tank`→bear, `dps`→cat, `heal`→resto; DK `tank`→blood;
Priest `dps`→shadow; Shaman `heal`→resto, `dps`/`melee`→enh, `caster`→ele.
⁴ Shaman `offheal` exists but is commented out in source.

**Per-class extra tokens** (spec strategies are sibling-replacing):

- **Warrior** — specs `arms`, `fury` (`tank` = prot). Nothing else. No `cc`, no `boost`.
- **Paladin** — `bthreat` (threat blessing); auras `barmor` `baoe` `bcast` `bspeed`
  `rfire` `rfrost` `rshadow`; blessings `bmight` `bwisdom` `bkings` `bsanc`.
- **Hunter** — `pet`, `trap weave`; specs `bm` `mm` `surv` (built with `supportsSiblings = false`, not mutually exclusive in C++); buffs `bspeed` `bdps`
  `rnature`. **No `bmana`** (no Aspect of the Viper token), no `pull`, no `boost`.
- **Rogue** — `stealth`, `stealthed`; combat `combat`, `assassin` (no `dps` or `melee` tokens).
- **Priest** — `shadow aoe`, `dps debuff`/`shadow debuff`, `rshadow`; combat `heal`, `disc`,
  `shadow`/`dps`, `holy dps`, `holy heal`.
- **Shaman** — specs `resto` `enh` `ele` (+ role aliases above); totems: earth
  `strength of earth` `stoneskin` `tremor` `earthbind`, fire `searing` `magma`
  `flametongue` `wrath` `frost resistance`, water `healing stream` `mana spring`
  `cleansing` `fire resistance`, air `wrath of air` `windfury` `nature resistance`
  `grounding`. No `cc`.
- **Mage** — specs `frost` `fire` `frostfire` `arcane`; `firestarter`; buffs `bmana`
  `bdps`.
- **Warlock** — specs `affli` `demo` `destro`; `tank` (yes, really), `meta melee`,
  `pet` + `imp` `voidwalker` `succubus` `felhunter` `felguard`; soulstones `ss self`
  `ss master` `ss tank` `ss healer`; curses `curse of agony/elements/doom/
  exhaustion/tongues/weakness`; `firestone` `spellstone`.
- **Druid** — specs `bear`/`tank`, `cat`/`dps`, `balance`, `resto`; `blanketing`,
  `tranquility`, `feral charge`, `offheal`. `heal` is registered as an alias of `resto`.

- **Death Knight** — specs `blood`/`tank`, `frost`, `unholy`; `frost aoe`,
  `unholy aoe`. No `cc`, no `boost`, no `bdps`.

---

## Strategy conflicts

✖ = one side **hard-vetoes** the other's actions (multiplier returns 0).
⚠ = potential behavioral competition — actions may pull the bot in different directions.
Movement outcomes depend on active triggers, targets, and whether the actions can execute.

|                   | `aoe` actions | `tank` role | healing | `aggressive`/`grind` | `pvp` | `close` | `behind` | `tank face` | `save mana` |
|-------------------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `focus`           | ✖¹ |     |     |     |     |     |     |     |     |
| `threat`          | ⚠² |     |     |     |     |     |     |     |     |
| `wait for attack` | ✖³ |     | ✖³  | ✖³  | ✖³  |     |     |     |     |
| `passive`         | ✖⁴ |     |     | ✖⁴  | ✖⁴  |     |     |     |     |
| `ranged`          |    |     |     |     |     | ⚠⁵  |     |     |     |
| `kite`            |    |     |     |     |     | ⚠⁶  | ⚠⁶  |     |     |
| `adds`            |    |     |     | ⚠⁷  |     |     |     |     |     |
| `behind`          |    | ⚠⁸  |     |     |     |     |     | ⚠⁸  |     |
| `healer dps`      |    |     |     |     |     |     |     |     |     |

1. **`focus` cancels AoE damage abilities.** FocusMultiplier vetoes actions classified as
   AoE, except healing actions, and debuffs on attackers. It does not veto the `dps aoe`
   target selector.
2. **`threat` on tanks.** ThreatValue measures threat relative to *other* tanks in the group
   (excluding the bot itself; solo tanks return 0 threat, so it is a no-op). In multi-tank groups,
   a tank with `threat` active has abilities vetoed if threat reaches 80% (or 50% for AoE) of the
   other tank's threat. For DPS, note AoE is vetoed at 50% — earlier than the 80% single-target
   cutoff, so `threat` + `aoe` vetoes affected actions while threat remains at or above the threshold.
3. **`wait for attack` vetoes everything** not on its whitelist until the timer —
   including heals, `aggressive`/`grind` target acquisition, and `pvp` attacks. This
   is by design (the whitelist keeps `dps assist`, facing, and pull actions alive).
4. **`passive` vetoes all offense** — anything not on PassiveMultiplier's small
   allow-list is dead while it's on.
5. **`close` vs `ranged`** — reach-melee (HIGH+1) vs flee-when-near (MOVE+4): with
   both on, the bot may alternate between approaching and retreating when both actions are useful.
6. **`kite` vs `close`/`behind`** — `"has aggro"` → runaway @ 51 can compete with
   reach-melee/set-behind movement while the bot holds aggro.
7. **`adds` vs `aggressive`/`grind`** — when potential adds are detected, flee-with-pet @ 60
   can outrank target acquisition @ 4. Actual retreat depends on the trigger and movement feasibility.
8. **`behind` on the tank** — the tank holds the mob's front (`tank face` exists to
   keep it pointed away from the group); moving behind it can cause the mob to turn
   toward the tank and undermine that facing.
9. **`healer dps` and `save mana`** — no conflict: `save mana` filters out mana-inefficient heals when
   mana drops below threshold; it does not block damage spells, so healers can still DPS.

Not a conflict, but looks like one: during a pull, `pull`'s PullMultiplier vetoes non-pull actions
(except `follow` and `set facing`) — the bot ignoring orders mid-pull is working as intended.

### Tank self-healing (Paladin) — sparse by design

The baseline tanking Paladin rotation has limited self-healing in combat.
`TankPaladinStrategy` adds **no** heal trigger (its `medium health` @65% → **Holy Shield**, a
block buff). Its inherited class-healing triggers come from `GenericPaladinStrategy`:
`critical health` (below `CriticalHealth`, default 25%) → **Lay on Hands** / **Divine Shield** (long
cooldowns — Divine Shield also sheds all threat), and `divine shield low health` → **Flash of
Light/Holy Light**, whose trigger is literally `HasAura("divine shield") && health < 80`:
the baseline triggers schedule those normal heals *while bubbled*. These class-healing triggers
depend on critical health or Divine Shield rather than mana availability; other strategies, such
as `potions`, can also provide healing. `heal`/`offheal` are
sibling-exclusive with `tank`, so there's no "tank + self-heal" combo to enable — keep a healer in
the group, or run the Paladin as **Off-Heal** (ret + emergency heals) if it should self-sustain
instead of tank.

---

## CleanBot integration notes (observations only — no committed work)

- **Class-aware gating (implemented).** The generic combat/role lists are now filtered
  per class via `NS.STRATEGY_CLASS_SUPPORT` + `NS.CB_StrategyShown` (`Strategies.lua`),
  and tokens a class implements under a different name use `cmdByClass` overrides
  (resolved by `NS.CB_EffStrategyCmd` for both send and `co ?` parse). This resolved:
  - `cc`/`boost` no longer shown where unregistered (cc: not War/Sha/DK; boost: not
    War/Hun/DK); `tank`/`heal` role entries hidden for classes that can't fill them.
  - Druid Healer sends `resto` (which `heal` aliases in C++; `resto` is what the bot reports); Druid/DK Tank send
    `bear`/`blood`. The parse map recognizes those tokens so the dropdown stays in sync.
  - Paladin blessings corrected to `bmight`/`bwisdom`/`bkings`/`bsanc` (`ClassData.lua`).
    (`bthreat` exists and is still unexposed.)
  - Hunter "Aspect of the Viper" removed — Hunter registers no token for it.
- **Read-only "Strategy" display.** This dropdown reflects the bot's *active* combat
  strategy, matched against the `co ?` reply. Shaman uses `ele`/`enh`/`resto`; Druid uses
  `bear`/`cat`/`balance`/`resto` (`ClassData.lua`). These match the canonical names reported
  by the server. Druid also accepts `heal` as an alias of `resto`.
- **Two-axis Role + Assist split (implemented).** The combat tab exposes the two independent
  engine axes as two controls instead of one conflated "Role" dropdown:
  - **Role** (`roleDropdown`, rotation axis) — **Tank** (`tank`; cmdByClass bear/blood),
    **Healer** (`heal`; cmdByClass resto; also parses canonical `disc`, `holy`, and `holy heal`), and a Paladin-only **Off-Heal** (`offheal`). These are
    siblings in each class's combat `StrategyContext(false, true)` (except Warlock, where `tank` is registered in its general context), so the dropdown is exclusive.
    **DPS is the `noneLabel`** — there is no universal `dps` rotation token (War/Hun/Mag/Lock/DK
    register only spec tokens), so the damage role is the *absence* of tank/heal. For classes where tank/heal are
    siblings, setting them makes the engine *drop* the spec's damage rotation (for Warlock, setting `tank` does not drop its spec rotation server-side), so picking "DPS" must
    re-add it or the bot is left with no rotation. It re-adds the rotation matching the bot's
    **detected talent spec** (`NS.CB_DetectedDpsToken` → `NS.SPEC_DPS_TOKEN`, keyed off the spec
    field `CB_SyncTalentSpec` stamped into `classData.combat`) — so a Fury warrior gets `fury`
    back, a Balance druid gets `balance`, a ret Paladin gets `dps`. The Role group's
    `dpsCmdByClass` (`PALADIN`/`PRIEST` = `dps`) is only the fallback when the spec isn't known
    yet (no inspect). The none/DPS sub-section
    (`none = true`, keyed by the `ROLE_NONE` sentinel in `Individual.lua`) holds the **Rotation**
    bundle (`aoe`/`focus`) + **Avoid Aggro** (`threat`); the Paladin Off-Heal role reuses it via
    `roles = { "offheal" }`.
  - **Targeting** (plain exclusive `dropdown`, `noneLabel = "None"`, group `assist`) — **Focus Down**
    (`dps assist`), **Cleave Anchor** (`dps aoe`), **Peel** (`tank assist`). Orthogonal to Role.
  - A full AoE bot = Targeting **Cleave Anchor** + **AoE Rotation** selected in the Rotation dropdown; a healer that DPSes = Role
    **Healer** + **Healer DPS** (+ Targeting **Focus Down** to focus its damage).
- **Off-heal hybrids (implemented).** `offheal` adds emergency heals on top of a damage rotation.
  Its engine shape differs by class, so CleanBot exposes it two ways (one shared `offheal` field,
  each gated to its class via `classOnly` in `CB_StrategyShown`): **Druid** registers it in the
  *non-sibling* general context → an independent **Off-Heal** checkbox in the Role group's DPS
  sub-section (next to Avoid Aggro) and Tank sub-section (niche — limited in Bear Form, but valid);
  **Paladin** registers
  `OffhealRetPaladinStrategy` in the *sibling* combat context → an exclusive **Off-Heal** **Role**
  option (ret damage + heals, replacing plain ret). Shaman's `offheal` is commented out in source;
  no other class registers it.
- **Conflict guardrails** worth considering: warn (or auto-exclusive) on
  `focus` ↔ `aoe`, `close` ↔ `ranged`.
- **Initial UI defaults.** `CB_DefaultCombat`/`CB_DefaultNonCombat` (`Strategies.lua`)
  seed local fields before the bot replies, including Non-Combat Movement = Follow,
  `Eat & Drink` / `Auto Loot` / `Auto Gather` / `Enable PvP` (nc), and `Use Cooldowns` (combat).
  These are optimistic UI values; the bot's active strategies may differ because of its
  class, configuration, or saved settings. Authoritative `co ?` / `nc ?` replies replace
  the initial values. Seeds use a strategy's `default = true` or a group's `defaultField`;
  `CB_StrategyShown` separately controls class visibility.
- **Movement modes (implemented).** Two exclusive `dropdown` groups with
  `noneLabel = "Free Roam"` (`NS.MOVEMENT_STRATEGIES` shared in `Strategies.lua`):
  **Non-Combat Movement** (writes/reads the `nc` list, default Follow) and **Combat
  Movement** (writes/reads the `co` list, default Free Roam). Each is a normal single-state
  exclusive dropdown (reuses `CB_ApplyExclusiveSelection`); the `noneLabel` clear entry =
  nil selection drops all four. (The Paladin Blessings dropdowns use the same `noneLabel`
  mechanism with `"None"`.) The **Action Bar Movement flyout** (Follow / Stay / Runaway,
  `ActionBar.lua`) is a third surface onto the same strategies: Follow/Stay apply to whichever
  list matches the **player's** current combat state (in combat → `co`, else → `nc`), while
  **Runaway** always sets the `runaway` strategy in the **combat** list and auto-reverts to the
  previous combat movement when combat ends (`PLAYER_REGEN_ENABLED`). The same three words are
  also parsed when overheard in chat (`Overhear.lua`).
- Useful unexposed candidates: `formation` (the combat strategy — distinct from the
  Formation *command*), `move from group`, `collision`, `mount`, Shaman resistance
  totems (`frost resistance` / `fire resistance` / `nature resistance`), Paladin `bthreat`.

---

## Source map

- Strategy name registry (generic): `src/Ai/Base/StrategyContext.h`
- co/nc state mapping + operators: `src/Ai/Base/Actions/ChangeStrategyAction.cpp`
- Multiplier strategies: `src/Ai/Base/Strategy/ThreatStrategy.cpp` (also defines
  `focus`), `WaitForAttackStrategy.cpp`, `CastTimeStrategy.cpp`,
  `ConserveManaStrategy.cpp`, `PassiveStrategy.cpp`
- Positioning: `CombatStrategy.cpp` (also defines `avoid aoe`, `tank face`,
  `formation`), `MeleeCombatStrategy.cpp` (also `behind`), `RangedCombatStrategy.cpp`,
  `KiteStrategy.cpp`, `PullStrategy.cpp` (also `pull back`, `adds`)
- Assist: `TankAssistStrategy.cpp`, `DpsAssistStrategy.cpp`
- Aggression: `AggressiveStrategy.cpp`, `GrindingStrategy.cpp`,
  `AttackEnemyPlayersStrategy.cpp`
- Non-combat: `NonCombatStrategy.cpp/.h`, `UseFoodStrategy.cpp`,
  `LootNonCombatStrategy.cpp`
- Threat math: `src/Ai/Base/Value/ThreatValues.cpp`
- Strategy-context exclusivity (`supportsSiblings`): `src/Bot/Engine/NamedObjectContext.h`,
  `Engine::addStrategy` in `src/Bot/Engine/Engine.cpp`
- Default loadout per state/spec: `src/Bot/Factory/AiFactory.cpp`
  (`AddDefaultCombatStrategies` / `AddDefaultNonCombatStrategies` / `AddDefaultDeadStrategies`),
  applied by `PlayerbotAI::ResetStrategies`; combat-`stay` position snapshot in
  `PlayerbotAI::ChangeEngineOnCombat`
- Class registries: `src/Ai/Class/<Class>/<Class>AiObjectContext.cpp`
- CleanBot's sent tokens: `Individual/Strategies.lua`, `Individual/ClassData.lua`
