# Getting Started

CleanBot is a clean, point-and-click interface for managing **Playerbots** on a World of
Warcraft 3.3.5a (Wrath of the Lich King) server. Instead of memorizing whisper commands, you
drive your bots from a tidy window, a right-click menu, and an optional floating action bar.

## What you need

- A 3.3.5a server running the **mod-playerbots** module (so you have bots to command).
- **Optional — [MultiBot Bridge](bridge-protocol.md):** a small server module that provides
  structured bot data and reduces command whispers. Some commands still use whispers with
  the bridge installed. Most features also work without it, though Spellbook and Professions
  require the bridge. You can hide command chatter in
  [Settings](settings.md) → *Hide Bot Chatter*.
- **Optional — ElvUI:** if you have it installed, CleanBot automatically matches its look.

The companion *Multibot* addon is **not** required.

## Opening the window

- Type **`/cb`** or **`/cleanbot`**, or
- **Left-click** the wrench button on your minimap.

The minimap button also: **right-click** to toggle the [Action Bar](action-bar.md),
**shift + right-click** for the action bar's edit mode, and **drag** to move the button. Its
tooltip shows your live bridge status (green = present, red = absent).

## The four tabs

| Tab | What it's for |
|---|---|
| **[Manage](managing-bots.md)** | Invite/dismiss bots, spawn/despawn them, summon the group, and save bot **presets**. |
| **[Individual](bot-behavior.md)** | Focus one bot — see its [gear and bags](gear-and-bags.md) and set how it [behaves](bot-behavior.md). |
| **[Group](bot-behavior.md)** | Set behavior for **every** bot at once. |
| **[Settings](settings.md)** | Appearance, behavior toggles, and the action bar. |

## Managing your own character

CleanBot can also run **your own character** as a bot. Turn on *Auto-Enable Self as Bot* in
[Settings](settings.md) → Other → Behavior and you'll spawn managed each login — handy for soloing with
a self-bot or testing without a group.

## Where to next

- [Action Bar](action-bar.md) — one-click bot commands.
- [Managing Bots](managing-bots.md) — building and running your group.
- [Bot Behavior](bot-behavior.md) — roles, rotations, movement, loot.
- [Gear & Bags](gear-and-bags.md) — equipment, inventory, vendors, trading, quests.
- [Professions](professions.md) — bot profession skills, recipes, crafting, and target enchantments.
- [Spellbook](spellbook.md) — inspect learned spells and order manual casting.
- [Settings](settings.md) — appearance and toggles.
