-- ============================================================
-- spec/inventory_spec.lua  —  Tests for Individual/Inventory.lua pure parsers.
-- ============================================================

-- Load the addon file under the mock. Its load-time frame/menu/popup setup is absorbed
-- by the stubs in wow_mock.lua; the functions under test touch no live client API.
dofile("Individual/Inventory.lua")
local NS = CleanBotNS

describe("CB_ParseItemLine", function()
    it("parses a basic item link with default count 1", function()
        local link = "|cffffffff|Hitem:6948:0:0:0:0:0:0:0|h[Hearthstone]|h|r"
        local r = NS.CB_ParseItemLine(link)
        assert.is_not_nil(r)
        assert.equals(link, r.link)
        assert.equals(1, r.count)
    end)

    it("reads a stack count appended after the link", function()
        local r = NS.CB_ParseItemLine("|cffffffff|Hitem:2589|h[Linen Cloth]|h|r x20")
        assert.is_not_nil(r)
        assert.equals(20, r.count)
    end)

    it("percent-decodes encoded characters in the line", function()
        local r = NS.CB_ParseItemLine("|cffffffff|Hitem:1234|h[Big%20Bag]|h|r")
        assert.is_not_nil(r)
        assert.equals("|cffffffff|Hitem:1234|h[Big Bag]|h|r", r.link)
    end)

    it("returns nil for a line with no item link", function()
        assert.is_nil(NS.CB_ParseItemLine("Strategies: tank pve"))
    end)
end)

describe("CB_IsItemDisenchantable", function()
    local origGetItemInfo
    local itemDb = {}

    before_each(function()
        CleanBot_PartyBots = {
            enchanter = {
                name = "Enchanter",
                professions = {
                    { skillId = 333, key = "enchanting" },
                },
            },
            spellbook_enchanter = {
                name = "SpellbookEnchanter",
                spellbookSeen = {
                    [13262] = true,
                },
            },
            non_enchanter = {
                name = "Warrior",
                professions = {
                    { skillId = 164, key = "blacksmithing" },
                },
            },
        }

        itemDb = {}
        origGetItemInfo = _G.GetItemInfo
        _G.GetItemInfo = function(link)
            local item = itemDb[link]
            if not item then return nil end
            return item.name, link, item.quality, 80, 80, item.itemType, "", 1, item.equipLoc
        end
    end)

    it("returns false if bot does not have enchanting", function()
        itemDb["item:green_chest"] = { name = "Green Chest", quality = 2, itemType = "Armor", equipLoc = "INVTYPE_CHEST" }
        assert.is_false(NS.CB_IsItemDisenchantable("non_enchanter", "item:green_chest"))
    end)

    it("returns false for poor or common quality items", function()
        itemDb["item:gray_weapon"] = { name = "Gray Weapon", quality = 0, itemType = "Weapon", equipLoc = "INVTYPE_2HWEAPON" }
        itemDb["item:white_chest"] = { name = "White Chest", quality = 1, itemType = "Armor", equipLoc = "INVTYPE_CHEST" }
        assert.is_false(NS.CB_IsItemDisenchantable("enchanter", "item:gray_weapon"))
        assert.is_false(NS.CB_IsItemDisenchantable("enchanter", "item:white_chest"))
    end)

    it("returns false for quest items", function()
        itemDb["item:quest_gear"] = { name = "Quest Gear", quality = 2, itemType = "Quest", equipLoc = "INVTYPE_CHEST" }
        assert.is_false(NS.CB_IsItemDisenchantable("enchanter", "item:quest_gear"))
    end)

    it("returns false for non-disenchantable slots like shirts, tabards, bags, trinkets, relics", function()
        itemDb["item:shirt"]   = { name = "Shirt", quality = 2, itemType = "Armor", equipLoc = "INVTYPE_BODY" }
        itemDb["item:tabard"]  = { name = "Tabard", quality = 2, itemType = "Armor", equipLoc = "INVTYPE_TABARD" }
        itemDb["item:bag"]     = { name = "Bag", quality = 2, itemType = "Container", equipLoc = "INVTYPE_BAG" }
        itemDb["item:trinket"] = { name = "Trinket", quality = 2, itemType = "Armor", equipLoc = "INVTYPE_TRINKET" }
        itemDb["item:relic"]   = { name = "Relic", quality = 2, itemType = "Armor", equipLoc = "INVTYPE_RELIC" }

        assert.is_false(NS.CB_IsItemDisenchantable("enchanter", "item:shirt"))
        assert.is_false(NS.CB_IsItemDisenchantable("enchanter", "item:tabard"))
        assert.is_false(NS.CB_IsItemDisenchantable("enchanter", "item:bag"))
        assert.is_false(NS.CB_IsItemDisenchantable("enchanter", "item:trinket"))
        assert.is_false(NS.CB_IsItemDisenchantable("enchanter", "item:relic"))
    end)

    it("returns true for eligible uncommon+ armor and weapons on an enchanter bot", function()
        itemDb["item:green_chest"] = { name = "Green Chest", quality = 2, itemType = "Armor", equipLoc = "INVTYPE_CHEST" }
        itemDb["item:blue_sword"]  = { name = "Blue Sword", quality = 3, itemType = "Weapon", equipLoc = "INVTYPE_WEAPON" }
        itemDb["item:epic_ring"]   = { name = "Epic Ring", quality = 4, itemType = "Armor", equipLoc = "INVTYPE_FINGER" }

        assert.is_true(NS.CB_IsItemDisenchantable("enchanter", "item:green_chest"))
        assert.is_true(NS.CB_IsItemDisenchantable("enchanter", "item:blue_sword"))
        assert.is_true(NS.CB_IsItemDisenchantable("enchanter", "item:epic_ring"))
    end)

    it("identifies enchanter bots via spellbookSeen[13262]", function()
        itemDb["item:green_chest"] = { name = "Green Chest", quality = 2, itemType = "Armor", equipLoc = "INVTYPE_CHEST" }
        assert.is_true(NS.CB_IsItemDisenchantable("spellbook_enchanter", "item:green_chest"))
    end)
end)

describe("CB_StartDisenchantWatcher", function()
    local fetched
    local loadingStates

    before_each(function()
        Mock.reset()
        Mock.party = 1
        Mock.roster = { party1 = "Bot1" }
        CleanBot_PartyBots = {
            bot1 = { name = "Bot1" }
        }
        fetched = {}
        loadingStates = {}
        NS.CB_FetchInventory = function(key, name, force)
            table.insert(fetched, { key = key, name = name, force = force })
        end
        NS.CB_SetInventoryLoading = function(frame, on, text)
            table.insert(loadingStates, { frame = frame, on = on, text = text })
        end
        NS.botInventoryFrames = {
            bot1 = { isInventoryFrame = true }
        }
    end)

    it("sets entry.isDisenchanting and activates Disenchanting... overlay", function()
        NS.CB_StartDisenchantWatcher("bot1", "Bot1")
        assert.is_true(CleanBot_PartyBots.bot1.isDisenchanting)
        assert.equals(1, #loadingStates)
        assert.is_true(loadingStates[1].on)
        assert.equals("Disenchanting...", loadingStates[1].text)
    end)

    it("triggers fetch after UNIT_SPELLCAST_SUCCEEDED and loot delay", function()
        NS.CB_StartDisenchantWatcher("bot1", "Bot1")
        Mock.fireEvent("UNIT_SPELLCAST_SUCCEEDED", "party1", "Disenchant", "", 1, 13262)
        assert.equals(0, #fetched)
        assert.is_nil(CleanBot_PartyBots.bot1.isDisenchanting)
        assert.equals("Refreshing...", loadingStates[#loadingStates].text)
        Mock.tick(0.6)
        assert.equals(1, #fetched)
        assert.equals("bot1", fetched[1].key)
        assert.equals("Bot1", fetched[1].name)
        assert.is_true(fetched[1].force)
    end)

    it("hides overlay and clears isDisenchanting on UNIT_SPELLCAST_INTERRUPTED", function()
        NS.CB_StartDisenchantWatcher("bot1", "Bot1")
        Mock.fireEvent("UNIT_SPELLCAST_INTERRUPTED", "party1", "Disenchant", "", 1, 13262)
        assert.is_nil(CleanBot_PartyBots.bot1.isDisenchanting)
        assert.is_false(loadingStates[#loadingStates].on)
        assert.equals(0, #fetched)
    end)

    it("hides overlay and clears isDisenchanting on UNIT_SPELLCAST_FAILED", function()
        NS.CB_StartDisenchantWatcher("bot1", "Bot1")
        Mock.fireEvent("UNIT_SPELLCAST_FAILED", "party1", "Disenchant", "", 1, 13262)
        assert.is_nil(CleanBot_PartyBots.bot1.isDisenchanting)
        assert.is_false(loadingStates[#loadingStates].on)
        assert.equals(0, #fetched)
    end)

    it("triggers fallback fetch at 4.5s if no unit event is received", function()
        NS.CB_StartDisenchantWatcher("bot1", "Bot1")
        Mock.tick(2.0)
        assert.equals(0, #fetched)
        Mock.tick(2.6)
        assert.equals(1, #fetched)
        assert.equals("bot1", fetched[1].key)
        assert.equals("Bot1", fetched[1].name)
        assert.is_nil(CleanBot_PartyBots.bot1.isDisenchanting)
    end)
end)

