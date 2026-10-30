# Spellbook

CleanBot provides a full Dragonflight-inspired spellbook interface to inspect a bot's learned spells,
search abilities in real time, and command bots to cast utility, buffs, or combat abilities on demand.

## Accessing the Spellbook

- **Right-Click Menu:** Right-click a bot's unit frame or raid frame and select **Spellbook**.
- **Character Paperdoll:** Click the small grimoire book button next to the bag and quest buttons
  on the **Individual** tab's 3D model view.
- **Bot Switching:** Use the tabs along the top of the spellbook window to switch between party
  members without closing and reopening the window. Bot names are colored by their class.

> [!NOTE]
> The Spellbook requires the **MultiBot Bridge** server module (`GET~SPELLBOOK`). Although Playerbots
> provides the `spells` chat command, CleanBot does not stream spell data over whispers to avoid
> flooding the chat with spell lists. Casting currently uses the `cast` command via whispers.
> When the bridge is absent, the Spellbook entry is hidden from the right-click menu, and opening
> it from the character paperdoll displays a *"MultiBot Bridge Required"* overlay.

## Interface Overview

- **Two-Page Parchment Display:** Designed with a retail-style open book aesthetic, displaying spells
  in a 3-column card grid across two pages.
- **Spell Sections:** Page headings group abilities under **General** and the bot's class name.
  The tabs along the top switch between bots.
- **Highest-Rank Collapsing:** CleanBot automatically collapses lower ranks of the same ability,
  displaying only the highest learned rank to keep the pages uncluttered.
- **Passive Abilities:** Passive spells feature distinct circular portraits and are clearly marked
  to prevent accidental cast orders.
- **Search Box:** Type in the top search field to filter spells in real time by name.

## Ordering Bots to Cast (Dual-Click Casting)

Clicking any active spell card orders the bot to cast it:

- **Left-Click:** Orders the bot to cast the spell on your current target (or on the bot itself if
  no target is selected). Dispatches `cast <spell>`.
- **Right-Click (Self-Cast on Player):** Orders the bot to cast the spell directly onto **you**
  (e.g. blessings, heals, dispels, shields). Dispatches `cast <spell> on <player>`.
