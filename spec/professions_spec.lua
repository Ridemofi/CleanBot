-- ============================================================
-- spec/professions_spec.lua - Individual/Professions.lua behavior.
-- ============================================================
if not CleanBotNS.CB_BuildProfessionRecipeTree then dofile("Individual/Professions.lua") end
local NS = CleanBotNS

describe("CB_BuildProfessionRecipeTree", function()
    it("builds recipe tree grouped by subType and sorted by difficulty", function()
        local raw = {
            { name = "Rough Dynamite", difficulty = "gray",   subType = "Explosives" },
            { name = "Iron Grenade",   difficulty = "yellow", subType = "Explosives" },
            { name = "Flash Powder",   difficulty = "orange", subType = "Explosives" },
            { name = "Copper Tube",    difficulty = "green",  subType = "Parts" },
            { name = "Copper Mod",     difficulty = "orange", subType = "Parts" },
            { name = "Secret Device",  difficulty = "orange", subType = nil }, -- Miscellaneous category
        }

        local tree = NS.CB_BuildProfessionRecipeTree(raw)
        assert.is_not_nil(tree)
        assert.equals(3, #tree)

        assert.equals("Explosives", tree[1].name)
        assert.equals("Parts", tree[2].name)
        assert.equals("Miscellaneous", tree[3].name)

        assert.equals(3, #tree[1].recipes)
        assert.equals("Flash Powder", tree[1].recipes[1].name)
        assert.equals("orange", tree[1].recipes[1].difficulty)
        assert.equals("Iron Grenade", tree[1].recipes[2].name)
        assert.equals("yellow", tree[1].recipes[2].difficulty)
        assert.equals("Rough Dynamite", tree[1].recipes[3].name)
        assert.equals("gray", tree[1].recipes[3].difficulty)

        assert.equals(2, #tree[2].recipes)
        assert.equals("Copper Mod", tree[2].recipes[1].name)
        assert.equals("orange", tree[2].recipes[1].difficulty)
        assert.equals("Copper Tube", tree[2].recipes[2].name)
        assert.equals("green", tree[2].recipes[2].difficulty)

        assert.equals(1, #tree[3].recipes)
        assert.equals("Secret Device", tree[3].recipes[1].name)
    end)
end)

describe("BotHasTool (Professions.lua)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            artemis = { name = "Artemis" },
        }
    end)

    it("returns true when toolName is empty or nil", function()
        local has = NS.CB_BotHasTool({ botKey = "artemis" }, nil, nil)
        assert.is_true(has)
        local has2 = NS.CB_BotHasTool({ botKey = "artemis" }, "", nil)
        assert.is_true(has2)
    end)

    it("does not crash when entry.inventory contains numeric stats without items table", function()
        CleanBot_PartyBots.artemis.inventory = { bagUsed = 8, bagTotal = 20 }
        local has = NS.CB_BotHasTool({ botKey = "artemis" }, "Blacksmith Hammer", { numAvailable = 0 })
        assert.is_false(has)
    end)

    it("handles non-table elements in inventory gracefully", function()
        CleanBot_PartyBots.artemis.inventory = { items = { 12345, "invalid", true } }
        local has = NS.CB_BotHasTool({ botKey = "artemis" }, "Blacksmith Hammer", { numAvailable = 0 })
        assert.is_false(has)
    end)

    it("returns true when tool is found in inventory.items", function()
        CleanBot_PartyBots.artemis.inventory = {
            items = {
                { itemId = 5956, name = "Blacksmith Hammer" }
            }
        }
        local has = NS.CB_BotHasTool({ botKey = "artemis" }, "Blacksmith Hammer", { numAvailable = 0 })
        assert.is_true(has)
    end)

    it("returns false when entry.inventory is nil", function()
        CleanBot_PartyBots.artemis.inventory = nil
        local has = NS.CB_BotHasTool({ botKey = "artemis" }, "Blacksmith Hammer", { numAvailable = 0 })
        assert.is_false(has)
    end)
end)

describe("CB_ToggleProfessions target selection and reset (d2155b7)", function()
    local origFetchInv = NS.CB_FetchInventory
    local origFetchProf = NS.CB_FetchProfessions
    local origGetFrame = NS.CB_GetProfessionsFrame
    local origRenderProf = NS.CB_RenderProfessions
    local dummyFrame
    local rendered

    local function restore()
        NS.CB_FetchInventory = origFetchInv
        NS.CB_FetchProfessions = origFetchProf
        NS.CB_GetProfessionsFrame = origGetFrame
        NS.CB_RenderProfessions = origRenderProf
    end

    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            artemis = {
                name = "Artemis",
                professions = {
                    { key = "engineering", name = "Engineering" },
                    { key = "mining", name = "Mining" },
                },
                inventory = { items = { { itemId = 5956, name = "Blacksmith Hammer" } } },
                inventoryAt = GetTime(),
            },
        }
        rendered = nil
        dummyFrame = {
            botKey = nil,
            botName = nil,
            currentProf = nil,
            selectedRecipe = nil,
            rawRecipes = nil,
            recipeTree = {},
            IsShown = function() return false end,
            Show = function() end,
            Hide = function() end,
            GetPoint = function() return "CENTER" end,
            ClearAllPoints = function() end,
            SetPoint = function() end,
            GetFrameStrata = function() return "MEDIUM" end,
            GetFrameLevel = function() return 1 end,
        }
        NS.CB_GetProfessionsFrame = function(k, n) return dummyFrame end
        NS.CB_FetchProfessions = function() end
        NS.CB_FetchInventory = function() end
        NS.CB_RenderProfessions = function(f, prof) rendered = prof end
    end)

    it("resets state on bot switch and renders first valid prof", function()
        dummyFrame.botKey = "other"
        dummyFrame.currentProf = "Mining"
        dummyFrame.selectedRecipe = { name = "Old" }
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.is_nil(dummyFrame.selectedRecipe)
        assert.equals("artemis", dummyFrame.botKey)
        assert.equals("Engineering", rendered)
    end)

    it("keeps current prof when same bot still has it", function()
        dummyFrame.botKey = "artemis"
        dummyFrame.currentProf = "Mining"
        dummyFrame.selectedRecipe = { name = "Keep" }
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals("Mining", rendered)
        assert.is_not_nil(dummyFrame.selectedRecipe)
    end)

    it("falls back to first valid when current prof is stale", function()
        dummyFrame.botKey = "artemis"
        dummyFrame.currentProf = "Tailoring"
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals("Engineering", rendered)
    end)

    it("respects primary order regardless of input order", function()
        CleanBot_PartyBots.artemis.professions = {
            { key = "mining", name = "Mining" },
            { key = "engineering", name = "Engineering" },
        }
        dummyFrame.botKey = "other"
        dummyFrame.currentProf = nil
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals("Engineering", rendered)
    end)

    it("prefers primary over secondary", function()
        CleanBot_PartyBots.artemis.professions = {
            { key = "cooking", name = "Cooking" },
            { key = "alchemy", name = "Alchemy" },
        }
        dummyFrame.botKey = "other"
        dummyFrame.currentProf = nil
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals("Alchemy", rendered)
    end)

    it("falls back to secondary when alone", function()
        CleanBot_PartyBots.artemis.professions = {
            { key = "cooking", name = "Cooking" },
        }
        dummyFrame.botKey = "other"
        dummyFrame.currentProf = nil
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals("Cooking", rendered)
    end)

    it("renders nothing when only Herbalism without side-tab icon", function()
        CleanBot_PartyBots.artemis.professions = {
            { key = "herbalism", name = "Herbalism" },
        }
        dummyFrame.botKey = "other"
        dummyFrame.currentProf = nil
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.is_nil(rendered)
    end)

    it("picks Cooking over Herbalism without icon", function()
        CleanBot_PartyBots.artemis.professions = {
            { key = "herbalism", name = "Herbalism" },
            { key = "cooking", name = "Cooking" },
        }
        dummyFrame.botKey = "other"
        dummyFrame.currentProf = nil
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals("Cooking", rendered)
    end)

    restore()
end)

describe("CB_OnProfessionsUpdated reselection (d2155b7)", function()
    local origFrame = NS.botProfessionsFrame
    local origRenderProf = NS.CB_RenderProfessions
    local dummyFrame
    local rendered

    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            artemis = {
                name = "Artemis",
                professions = {
                    { key = "engineering", name = "Engineering" },
                    { key = "mining", name = "Mining" },
                },
            },
        }
        rendered = nil
        dummyFrame = {
            botKey = "artemis",
            botName = "Artemis",
            currentProf = nil,
            IsShown = function() return true end,
            Show = function() end,
            Hide = function() end,
            GetFrameStrata = function() return "MEDIUM" end,
            GetFrameLevel = function() return 1 end,
        }
        NS.botProfessionsFrame = dummyFrame
        NS.CB_RenderProfessions = function(f, prof) rendered = prof end
    end)

    it("renders first valid when current prof is stale", function()
        dummyFrame.currentProf = "Tailoring"
        NS.CB_OnProfessionsUpdated("artemis")
        NS.botProfessionsFrame = origFrame
        NS.CB_RenderProfessions = origRenderProf
        assert.equals("Engineering", rendered)
    end)

    it("keeps frame without render when current prof still valid", function()
        dummyFrame.currentProf = "Mining"
        NS.CB_OnProfessionsUpdated("artemis")
        NS.botProfessionsFrame = origFrame
        NS.CB_RenderProfessions = origRenderProf
        assert.is_nil(rendered)
    end)

    it("ignores updates for other bots", function()
        dummyFrame.currentProf = "Tailoring"
        NS.CB_OnProfessionsUpdated("other")
        NS.botProfessionsFrame = origFrame
        NS.CB_RenderProfessions = origRenderProf
        assert.is_nil(rendered)
    end)

    NS.botProfessionsFrame = origFrame
    NS.CB_RenderProfessions = origRenderProf
end)
