# Professions

CleanBot provides an interface to inspect bot profession skills, browse learned
recipes, filter recipes, and order bots to craft items or apply target enchantments.

## Accessing Professions

- Right-click a bot's unit frame or raid frame and select **Professions**.
- Use the dropdown at the top of the professions window to switch between
  multiple professions learned by the selected bot.

## Interface Overview

- **Rank Bar:** Displays the bot's current and maximum skill level for the active
  profession, with visual progress.
- **Recipe List:** Displays all recipes learned by the bot, grouped by category.
  Categories can be collapsed or expanded by clicking on their headers.
- **Recipe Details:** Displays the selected recipe's icon, name, difficulty,
  tool requirements, and reagent list with counts (available in bot bags vs required).

## Search and Filters

- **Search Box:** Filters recipes in real time by name.
- **Filter Menu:** Accessible via the **Filter** button:
  - **Show Learned:** Toggle display of learned recipes.
  - **Has Skill Up:** Hides trivial and gray recipes that no longer grant skill points.
  - **Have Materials:** Displays only recipes for which the bot possesses all required reagents.
- **Reset Button:** Appears when non-default filters are active to restore defaults with one click.

## Crafting

- **Standard Crafting:** Clicking **Create** dispatches `RUN~CRAFT_RECIPE` to the bot.
  CleanBot monitors the bot's casting state (`UNIT_SPELLCAST_SUCCEEDED`, `FAILED`,
  `INTERRUPTED`) and automatically refreshes reagent counts and skill progress upon completion.
- **Target Enchantments:** For recipes that apply directly to equipment (e.g. Enchanting),
  clicking **Select Item** opens a picker displaying eligible targets organized into sections:
  the bot's equipped gear slots, armor and weapons located in its inventory bags (bags 0–4),
  and Enchanting Vellums. Non-enchantable slots (shirts, trinkets, relics, necks) are excluded.
  Selecting a target dispatches `RUN~CRAFT_RECIPE_TARGET`.

## Settings

The gear icon in the upper right opens a settings menu:
- **Hide item tooltips in list:** Disables recipe tooltips on list hover.
- **Colour names by skill difficulty:** Colors recipe names according to skill difficulty (orange, yellow, green, gray).
- **Plain skill bar (no animation):** Uses a static progress bar fill.

Settings are saved in `CleanBot_SavedVars.professionOpts` and persist across sessions.
