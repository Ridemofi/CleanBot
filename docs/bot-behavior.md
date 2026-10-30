# Bot Behavior

You decide how your bots fight, move, and look after themselves. Set it for **one bot** on the
**Individual** tab, or for **everyone at once** on the **Group** tab. Both lay the options out the
same way, across a few inner tabs.

Controls update when you make a change, then synchronize with the bot's reply.
Whisper commands may wait in the bot's request queue before being sent.

## Commands

Quick one-shot actions and settings: **Summon**, **Passive** (stand down), **Formation** (how the
group arranges itself), and the gear buttons (**Auto Gear**, **Equip Upgrades**,
**Roll**). Several of these are also on the [Action Bar](action-bar.md) and the
[Manage](managing-bots.md) tab. (Talent **spec** selection is located on the [Class tab](#class-tab)).

## Combat

How a bot behaves in a fight:

- **Role** — *Tank*, *Healer*, or *DPS* (some classes also offer *Off-Heal*). This picks the
  bot's rotation; CleanBot only shows the roles a class can actually fill.
- **Targeting** — who the bot focuses: *Focus Down* (single target), *Cleave Anchor* (AoE anchor), or *Peel* (protect party members).
- **Distance & Positioning** — *Close* (melee) or *Ranged* (caster) engagement, plus **Avoid AoE**, **Stay Behind Target**, and **Avoid Adds** (`adds` — attempts to retreat when potential adds are detected; recalls the pet if present).
- **Rotation** — *AoE Rotation* (cleave) vs. *Focus Fire* (single target) vs. *Balanced*.
- **Kite**, **Aggressive**, **Avoid Aggro** — movement and threat behavior.
- **Combat Movement** — *Follow*, *Stay*, *Guard*, *Run Away*, or *Free Roam* (disables movement overrides).
- Upkeep toggles — **Use Cooldowns**, **Use Potions**, **Use Racials**, **Smart Cast Time**, **Mark Targets**, **Grind Mobs** — and
  a **wait-for-attack** timer (hold fire for N seconds after combat starts), **Crowd Control** (controls the Moon-marked target), and role-specific toggles (Tank: **Pull**, **Pull Back**, **Face Target Away**; Healer: **Save Mana**, **Healer DPS**).

## Non-Combat

How a bot behaves out of combat:

- **Movement** — Follow you, Stay put, Guard a spot, and so on.
- **Eat/Drink** (instant action button) / **Eat & Drink** (behavior checkbox), **Auto Loot**, **Auto Gather**, **Enable PvP**.
- **Loot Quality** — how picky the bot is about what it loots.
- Class buffs and other self-maintenance.

## Class tab

A fourth tab named after the bot's class holds class-specific options — totems, blessings and
auras, curses, pet control, stealth, traps, and the like. It also hosts the **Talent Spec** dropdown (Protection, Holy, Fury, etc.) and the **Show Talents** inspect button.

## The Group tab

The **Group** tab lets you manage and command multiple bots simultaneously across party and raid:

- **Automatic Role Groups:** Pre-filtered lists for *Tanks*, *DPS*, *DPS (Single)*, *DPS (AoE)*, and *Healers* with official LFG role icons.
- **Automatic Class Groups:** Groups by every class represented in your party or raid.
- **Custom Groups:** Create and edit named custom rosters with **Add Group**, **Rename Group**, **Remove Group**, **Add Bot**, **Add Target**, and **Remove Bot**.
- **Mixed State Indicator:** When selected bots have conflicting strategies, controls show a distinct `(?) / Mixed` state.
- **Class Switcher:** For mixed groups, the Class tab includes a dropdown to tune class-specific settings per class without losing group selection.

## Interface utilities

- **Collapse / Expand (`>` / `<`):** A toggle tab on the right edge of CleanBotFrame (`CleanBotIndividualExpandBtn`) collapses the strategy panels, leaving a compact view of only the 3D model and paperdoll gear.
- **Reset Strategies:** A utility button in the Individual tab header; sends `reset botAI` to clear the bot's saved AI settings and restore its strategy sets to the server defaults.

## Want the full list?

These tabs cover the common controls in plain language. For the exhaustive, source-verified
reference — every strategy token, what it does, per-class coverage, and conflicts — see
[Playerbot Strategies](playerbot-strategies.md) and [Playerbot Commands](playerbot-commands.md).
