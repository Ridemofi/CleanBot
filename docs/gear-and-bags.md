# Gear & Bags

CleanBot lets you look after a bot's equipment, bags, quests, and even shopping almost like your
own character. Most of this lives on the **Individual** tab; bags and quests can also be opened
straight from the [right-click menu](managing-bots.md#the-right-click-menu).

## The bot's character (Individual tab)

Pick a bot and you'll see its **3D model** and a full **equipment paperdoll**. Hover any slot to
inspect the item. You can keep a bot's gear current here, or let it gear itself with **Auto Gear**
/ **Equip Upgrades** (see [Bot Behavior](bot-behavior.md)).

A quick-access button bar sits at the base of the model for opening the bot's **Inventory** (backpack),
**Spellbook** (grimoire), **Professions** (wrench), and **Quest Log** (scroll), with a live **XP bar**
underneath.

Use the ★ star button to add the bot to your **Favorites** preset on the
[Manage](managing-bots.md) tab.

## Bags

Open a bot's bags from its character view or the right-click **Inventory** menu. The inventory
window shows everything the bot carries plus its money. From here you can:

- **Use** an item (food, potions, quest items…). Consumables update stack counts immediately.
  Right-clicking eligible items opens a target selector for nearby Game Objects (chests, doors,
  quest objects) discovered through the bridge or query chatter.
- **Equip** gear straight from the bags.
- **Sell Trash** — vendor all the bot's gray items in one click (a vendor must be nearby).
- **Disenchant** — right-click eligible uncommon+ gear on an enchanter bot to disenchant it.
  The window locks with a `"Disenchanting..."` overlay until the cast finishes and materials
  arrive. Trinkets, relics, shirts, tabards, and bags are excluded.
- **Deposit to Guild Bank** — right-click an item and choose this to drop it into your guild's
  vault. The bot has to be **in your guild**, standing at a **guild vault**, with **deposit
  rights**; otherwise CleanBot tells you so. CleanBot currently exposes deposits only;
  it has no guild-bank browsing or withdrawal window.

Toggling a bot's bags fetches authoritative inventory data on open and hides the frame
instantly on close without issuing redundant network requests.

## At a vendor

Open a vendor **while you have bots in your group** and a strip of small **portrait tabs** (you +
each bot) appears down the right edge of the merchant window — a **dropdown** in a raid. You're
selected by default, so buying and selling work exactly as normal. Pick a **bot** instead and:

- **Buy for the bot** — right-click any item the vendor sells and that bot buys it. A
  **"Shopping for *Bot*"** banner shows who you're shopping for.
- **Sell from the bot** — right-click the bot's portrait (or the **Inventory** button in a raid)
  to open its bags, then right-click an item to sell it. Green-or-better items ask first, since
  **CleanBot currently provides no buyback for bots**. (Opening another bot's bags swaps the window over.)

The bot has to be standing near the vendor — if it's too far, CleanBot flashes a red warning and
doesn't send the order. A small **cog** at the top of the strip turns the whole thing on or off
(and there's nothing to see at all when you have no bots).

## Trading

You can move items between you and a bot through a normal trade window. Drag an item into the
trade to offer it; right-click an item the bot has offered to take it back. Your own bots accept
trades from you for free.

## Bank

A bot can list, deposit, and withdraw from its bank — but, like at the real bank, it needs to be
standing near a **banker NPC**. If none is nearby, CleanBot tells you so.

## Quests

Open a bot's **Quest Log** from its character view or the right-click menu. It lists the bot's
quests split into **Complete** and **Incomplete**, and lets you **abandon** ones it no longer
needs. When the MultiBot Bridge is present, abandonment is dispatched directly by quest ID
(`RUN~QUEST_ABANDON_TARGET`) without relying on chat title resolution.

### Quest Reward Selection

When turning in a quest that offers choice rewards with party bots present, CleanBot opens an
interactive side panel anchored to the right of the `QuestFrame`. Select an offered item,
then click the green check to confirm and send `r <itemlink>` to that bot. Click the small
backpack icon next to a bot to inspect its current equipment and bags before deciding.
Manual reward selection requires `Playerbots.AutoPickReward = no` in `playerbots.conf` and
applies to your **altbots** (your characters used as bots, including those from linked accounts).
Server-generated random bots continue to auto-pick rewards normally; this setting does
**not** make them wait for your selection.
