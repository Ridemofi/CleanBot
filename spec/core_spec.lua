-- ============================================================
-- spec/core_spec.lua  —  CleanBot.lua pure helpers (the real file is loaded by
-- run.lua before any spec): CB_SplitOnce, the party/raid group helpers, and
-- Bridge.lua's CB_CleanItemLink (here because it's a pure item-link transform,
-- not protocol). Frame construction + login init are in-game only.
-- ============================================================
if not CleanBotNS.CB_Emit          then dofile("Events.lua") end
if not CleanBotNS.CB_ParseItemLine then dofile("Individual/Inventory.lua") end
if not CleanBotNS.CB_CleanItemLink then dofile("Bridge.lua") end
local NS = CleanBotNS

describe("CB_SplitOnce", function()
    it("splits on the first separator only", function()
        local before, after = NS.CB_SplitOnce("RUN~COMBAT~BOT", "~")
        assert.equals("RUN", before)
        assert.equals("COMBAT~BOT", after)
    end)

    it("returns the whole string and '' when the separator is absent", function()
        local before, after = NS.CB_SplitOnce("HELLO", "~")
        assert.equals("HELLO", before)
        assert.equals("", after)
    end)

    it("handles a leading/trailing separator (empty halves)", function()
        local b1, a1 = NS.CB_SplitOnce("~rest", "~")
        assert.equals("", b1); assert.equals("rest", a1)
        local b2, a2 = NS.CB_SplitOnce("head~", "~")
        assert.equals("head", b2); assert.equals("", a2)
    end)

    it("matches the separator literally, not as a Lua pattern", function()
        -- '.' is a pattern wildcard; plain matching must find the actual dot.
        local before, after = NS.CB_SplitOnce("a.b", ".")
        assert.equals("a", before)
        assert.equals("b", after)
        -- '%' would error or mismatch under pattern matching.
        local b2, a2 = NS.CB_SplitOnce("50%~x", "%")
        assert.equals("50", b2)
        assert.equals("~x", a2)
    end)
end)

describe("Group helpers (party vs raid)", function()
    before_each(function() Mock.reset() end)

    it("CB_GroupInfo returns party prefix + count when only in a party", function()
        Mock.party = 3
        local prefix, n = NS.CB_GroupInfo()
        assert.equals("party", prefix)
        assert.equals(3, n)
    end)

    it("CB_GroupInfo prefers raid over party (party APIs return 0 in a raid)", function()
        Mock.party = 4   -- stale/nonzero party count must not win
        Mock.raid  = 10
        local prefix, n = NS.CB_GroupInfo()
        assert.equals("raid", prefix)
        assert.equals(10, n)
    end)

    it("CB_InGroup is false solo, true in party or raid", function()
        assert.is_false(NS.CB_InGroup())
        Mock.party = 1
        assert.is_true(NS.CB_InGroup())
        Mock.reset(); Mock.raid = 5
        assert.is_true(NS.CB_InGroup())
    end)

    it("CB_ForEachGroupMember visits every party member (party excludes the player)", function()
        Mock.party  = 2
        Mock.roster = { party1 = "Botone", party2 = "Bottwo" }
        local seen = {}
        NS.CB_ForEachGroupMember(function(unit, name) seen[#seen + 1] = unit .. "=" .. tostring(name) end)
        assert.same({ "party1=Botone", "party2=Bottwo" }, seen)
    end)

    it("CB_ForEachGroupMember skips the player's own raid unit (raid includes the player)", function()
        Mock.raid       = 3
        Mock.roster     = { raid1 = "Botone", raid2 = "TestPlayer", raid3 = "Bottwo" }
        Mock.playerUnit = "raid2"
        local seen = {}
        NS.CB_ForEachGroupMember(function(unit) seen[#seen + 1] = unit end)
        assert.same({ "raid1", "raid3" }, seen)
    end)

    it("CB_ForEachGroupMember visits nobody when solo", function()
        local n = 0
        NS.CB_ForEachGroupMember(function() n = n + 1 end)
        assert.equals(0, n)
    end)

    it("CB_FindPartyUnit resolves a name in the current group type, nil otherwise", function()
        Mock.raid   = 2
        Mock.roster = { raid1 = "Botone", raid2 = "TestPlayer" }
        assert.equals("raid1", NS.CB_FindPartyUnit("Botone"))
        assert.is_nil(NS.CB_FindPartyUnit("Stranger"))
    end)
end)

describe("CB_ItemTypeToken", function()
    it("resolves the client-locale class names from GetAuctionItemClasses positions", function()
        -- GetItemInfo's itemType return is localized; comparisons must use these
        -- tokens (4th = Consumable, 12th = Quest), never English literals.
        assert.equals("Consumable", NS.CB_ItemTypeToken("consumable"))
        assert.equals("Quest", NS.CB_ItemTypeToken("quest"))
    end)
end)

describe("CB_CleanItemLink", function()
    before_each(function() Mock.reset() end)

    it("re-fetches the canonical link for a raw link with extra fields", function()
        Mock.items[6948] = "|cffffffff|Hitem:6948:0:0:0:0:0:0:0|h[Hearthstone]|h|r"
        local raw = "|cffffffff|Hitem:6948:1234:5678:0:0:0:0:0|h[Hearthstone of Doom]|h|r"
        assert.equals(Mock.items[6948], NS.CB_CleanItemLink(raw))
    end)

    it("falls back to the raw link on a client-cache miss", function()
        local raw = "|cffffffff|Hitem:99999:0:0:0|h[Unknown]|h|r"
        assert.equals(raw, NS.CB_CleanItemLink(raw))
    end)

    it("survives a link with no item id (no error, raw returned)", function()
        assert.equals("not a link", NS.CB_CleanItemLink("not a link"))
    end)
end)

describe("questRewardEnabled", function()
    it("is false by default to prevent conflicts with AiPlayerbot.AutoPickReward", function()
        assert.is_false(NS.questRewardEnabled)
    end)
end)
