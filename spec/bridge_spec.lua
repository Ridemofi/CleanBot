-- ============================================================
-- spec/bridge_spec.lua  —  Tests for Bridge.lua command routing + the serial whisper queue.
--
-- Loads Bridge.lua under the mock and drives its real code paths: the bridge/whisper routing
-- decision (CB_GetBridgeOpcode allowlist + the debug override), and the per-bot serial queue
-- (one request at a time, advancing only after reply-silence). Sends are captured by the mock;
-- the OnUpdate tick is driven via Mock.tick.
-- ============================================================

-- Load once (guarded): re-dofile'ing would re-register the OnUpdate/OnEvent handlers with the
-- mock, and double-firing them would corrupt the queue/tick. Inventory.lua provides
-- CB_ParseItemLine, which Bridge's INV_ITEM handler depends on — load it too so this spec is
-- self-sufficient regardless of spec order.
if not CleanBotNS.CB_ParseItemLine then dofile("Individual/Inventory.lua") end
if not CleanBotNS.CB_EnqueueRequest then dofile("Bridge.lua") end
-- The ROSTER~ handler seeds entries via CB_DefaultCombat/CB_DefaultClassData.
if not CleanBotNS.STRATEGY_MAP   then dofile("Individual/Strategies.lua") end
if not CleanBotNS.SPEC_DPS_TOKEN then dofile("Individual/ClassData.lua") end
if not CleanBotNS.CB_BuildProfessionRecipeTree then dofile("Individual/Professions.lua") end
local NS = CleanBotNS

-- Item line as the bot streams it (the "items"/"bank" reply format).
local function itemLine(id, name, count)
    local s = "|cffffffff|Hitem:" .. id .. "|h[" .. name .. "]|h|r"
    return count and (s .. " x" .. count) or s
end

describe("Bridge command routing", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots     = { bot = { name = "Bot" } }
        NS.bridgeState         = "present"
        NS.debugBridgeOverride = nil
        Mock.party             = 1   -- so CB_SendBridge picks the PARTY channel
    end)

    it("routes an allowlisted combat toggle through the bridge (no whisper)", function()
        NS.CB_SendBotCommand("Bot", "co +focus")
        assert.equals(1, #Mock.addon)
        assert.equals(0, #Mock.whispers)
        assert.equals("RUN~COMBAT~BOT~Bot~~co +focus", Mock.addon[1].text)
        assert.equals("PARTY", Mock.addon[1].channel)
    end)

    it("whispers a query (co ?) instead of bridging it", function()
        NS.CB_SendBotCommand("Bot", "co ?")
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("co ?", Mock.whispers[1].text)
        assert.equals("Bot", Mock.whispers[1].target)
    end)

    it("whispers a list query (items) rather than bridging it", function()
        NS.CB_SendBotCommand("Bot", "items")
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("items", Mock.whispers[1].text)
    end)
end)

describe("Bridge override gating", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots     = { bot = { name = "Bot" } }
        NS.bridgeState         = "present"
        NS.debugBridgeOverride = nil
        Mock.party             = 1
    end)

    it("forces a whisper when the override is 'absent', even for an allowlisted command", function()
        NS.debugBridgeOverride = "absent"
        NS.CB_SendBotCommand("Bot", "co +focus")
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("co +focus", Mock.whispers[1].text)
    end)
end)

describe("Serial whisper queue", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
    end)

    -- Recorder request: appends its tag to `order` when actually sent. No busy flag of its own —
    -- the queue's pump sets wqBusy, so the next won't run until a tick clears it on silence.
    local function recorder(order, tag)
        return function() order[#order + 1] = tag end
    end

    it("runs one request at a time, advancing on reply silence", function()
        local order = {}
        NS.CB_EnqueueRequest("bot", recorder(order, "a"))
        NS.CB_EnqueueRequest("bot", recorder(order, "b"))
        NS.CB_EnqueueRequest("bot", recorder(order, "c"))
        assert.are.same({ "a" }, order)                 -- only the first sent immediately

        Mock.tick(0.6); assert.are.same({ "a", "b" }, order)
        Mock.tick(0.6); assert.are.same({ "a", "b", "c" }, order)
        Mock.tick(0.6); assert.are.same({ "a", "b", "c" }, order)  -- queue drained, no-op
    end)

    it("does not advance before the silence threshold (WHISPER_SILENCE)", function()
        local order = {}
        NS.CB_EnqueueRequest("bot", recorder(order, "a"))
        NS.CB_EnqueueRequest("bot", recorder(order, "b"))
        assert.are.same({ "a" }, order)

        Mock.tick(0.3); assert.are.same({ "a" }, order)        -- 0.3 < 0.5: still busy
        Mock.tick(0.3); assert.are.same({ "a", "b" }, order)   -- cumulative 0.6 ≥ 0.5: advances
    end)

    it("a streaming reply holds the queue open (each line resets the silence timer)", function()
        local order = {}
        NS.CB_EnqueueRequest("bot", recorder(order, "a"))
        NS.CB_EnqueueRequest("bot", recorder(order, "b"))

        Mock.tick(0.4)                                          -- 0.4 < 0.5
        Mock.fireEvent("CHAT_MSG_WHISPER", "a reply line", "Bot")  -- resets the silence timer
        Mock.tick(0.4)                                          -- only 0.4 since the reset
        assert.are.same({ "a" }, order)                        -- held open past 0.8 real time

        Mock.tick(0.4); assert.are.same({ "a", "b" }, order)   -- 0.8 since reset ≥ 0.5: advances
    end)

    it("sends immediately when the bot has no entry yet (discovery probe)", function()
        -- A no-bridge probe whispers "co ?" to a member not yet in CleanBot_PartyBots.
        -- With no per-bot entry to serialize against, the send must still go out (the
        -- regression: it was silently dropped, so no-bridge detection never fired).
        local order = {}
        NS.CB_EnqueueRequest("stranger", recorder(order, "probe"))
        assert.are.same({ "probe" }, order)
    end)
end)

describe("Bridge addon packets (CHAT_MSG_ADDON)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots     = { bot = { name = "Bot", awaitingInventory = true } }
        NS.bridgeState         = "present"
        NS.debugBridgeOverride = nil
    end)

    it("populates inventory from an INV_BEGIN/ITEM/SUMMARY/END burst", function()
        local e = CleanBot_PartyBots.bot
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INV_BEGIN~Bot~inv")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INV_ITEM~Bot~tok~|cffffffff|Hitem:6948|h[Hearthstone]|h|r")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INV_ITEM~Bot~tok~|cffffffff|Hitem:2589|h[Linen]|h|r x20")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INV_SUMMARY~Bot~tok~5~30~10~4~16")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INV_END~Bot")

        assert.equals(2,  #e.inventory.items)
        assert.equals(20, e.inventory.items[2].count)
        assert.equals(5,  e.money.gold)
        assert.equals(16, e.inventory.bagTotal)
        assert.equals(4,  e.inventory.bagUsed)
        assert.is_false(e.awaitingInventory)   -- INV_END landed
    end)

    it("ignores packets with a non-MBOT prefix", function()
        local e = CleanBot_PartyBots.bot
        Mock.fireEvent("CHAT_MSG_ADDON", "OTHER", "INV_BEGIN~Bot~inv")
        assert.is_nil(e.inventory)
    end)

    it("ignores inbound data packets while the override forces 'absent'", function()
        local e = CleanBot_PartyBots.bot
        NS.debugBridgeOverride = "absent"
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INV_BEGIN~Bot~inv")
        assert.is_nil(e.inventory)   -- the no-bridge guard dropped it
    end)

    it("seeds every bot from a multi-record ROSTER~ payload with its class", function()
        CleanBot_PartyBots = {}
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT",
            "ROSTER~Botone,8,80,571,1,100,95;Bottwo,6,80,571,1,100,0")

        local one, two = CleanBot_PartyBots.botone, CleanBot_PartyBots.bottwo
        assert.is_not_nil(one)
        assert.is_not_nil(two)   -- the regression: only the first record was parsed
        assert.equals("Botone", one.name)
        assert.equals("MAGE", one.class)          -- class id 8
        assert.equals("DEATHKNIGHT", two.class)   -- class id 6
        assert.is_not_nil(one.combat)             -- defaults seeded
    end)

    it("stores quest id, status, and the URL-decoded name from a QUESTS burst", function()
        local e = CleanBot_PartyBots.bot
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "QUESTS_BEGIN~Bot~tok~all")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "QUESTS_ITEM~Bot~tok~all~I~404~The%20Missing%20Diplomat")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "QUESTS_END~Bot~tok~all")

        assert.equals(1, #e.quests)
        assert.equals(404, e.quests[1].id)
        assert.equals("I", e.quests[1].status)
        assert.equals("The Missing Diplomat", e.quests[1].name)
    end)

    it("does not store the id-repeated name field the current bridge sends", function()
        -- MultiBotBridge fills the name field with to_string(questId); treating that as
        -- a title would make Abandon send "drop 404", which matches nothing server-side.
        local e = CleanBot_PartyBots.bot
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "QUESTS_BEGIN~Bot~tok~all")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "QUESTS_ITEM~Bot~tok~all~I~404~404")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "QUESTS_END~Bot~tok~all")

        assert.equals(404, e.quests[1].id)
        assert.is_nil(e.quests[1].name)
    end)

    it("HELLO_ACK flips bridgeState to present and ends the login phase", function()
        NS.bridgeReady      = false
        NS.bridgeState      = "unknown"
        NS.loginPhaseActive = true
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "HELLO_ACK~1")

        assert.is_true(NS.bridgeReady)
        assert.equals("present", NS.bridgeState)
        assert.is_false(NS.loginPhaseActive)
        assert.equals("HELLO_ACK~1", NS.lastHelloAck)
    end)

    it("HELLO_ACK is processed even when the override forces 'absent'", function()
        NS.bridgeReady         = false
        NS.bridgeState         = "unknown"
        NS.debugBridgeOverride = "absent"
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "HELLO_ACK~2")
        assert.is_true(NS.bridgeReady)   -- lifecycle packet runs above the no-bridge guard
    end)
end)

describe("Quest list collection (whisper)", function()
    before_each(function() Mock.reset() end)

    -- Quest reply line carrying a |Hquest:ID:…| link, as the bot streams it.
    local function questLine(id, name)
        return "|cffffff00|Hquest:" .. id .. ":70|h[" .. name .. "]|h|r"
    end

    it("routes quest lines by section header and finalizes on the summary line", function()
        local e = { name = "Bot", quests = {}, awaitingQuests = true, questStaging = {}, questStatus = "I" }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "--- Incompleted ---", "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", questLine(101, "Wolves"), "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", "--- Completed ---", "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", questLine(202, "Errand"), "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", "--- Summary --- Total: 2", "Bot")  -- terminator

        assert.equals(2, #e.quests)
        assert.equals(101, e.quests[1].id)
        assert.equals("I", e.quests[1].status)
        assert.equals("Wolves", e.quests[1].name)   -- link title, needed by Abandon ("drop <name>")
        assert.equals(202, e.quests[2].id)
        assert.equals("C", e.quests[2].status)
        assert.is_false(e.awaitingQuests)
    end)

    it("keeps the stale quest list when the reply never arrives (wipe guard)", function()
        local e = { name = "Bot", quests = { { id = 999, status = "I" } },
                    awaitingQuests = true, questStaging = {}, questReplyArrived = false,
                    questStatus = "I" }
        CleanBot_PartyBots = { bot = e }

        Mock.tick(0.6)   -- silence timeout fires with empty staging

        assert.equals(1, #e.quests)
        assert.equals(999, e.quests[1].id)
        assert.is_false(e.awaitingQuests)
        assert.is_nil(e.questStaging)
    end)

    it("treats a title containing 'Complete' as a quest, not a section header", function()
        local e = { name = "Bot", quests = {}, awaitingQuests = true, questStaging = {}, questStatus = "I" }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", questLine(303, "Complete the Ritual"), "Bot")
        assert.equals(1, #e.questStaging)
        assert.equals("I", e.questStaging[1].status)   -- stayed Incomplete; link matched first
    end)
end)

describe("Reconcile debounce (coalescing)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        NS.botInventoryFrames.bot = { IsShown = function() return true end }  -- "open" inventory
        NS.botBankFrames.bot      = nil                                        -- bank closed
    end)

    it("coalesces a burst of reconciles into a single fetch", function()
        local realFetch = NS.CB_FetchInventory
        local calls = 0
        NS.CB_FetchInventory = function() calls = calls + 1 end

        NS.CB_ScheduleReconcile("bot", "Bot")
        NS.CB_ScheduleReconcile("bot", "Bot")
        NS.CB_ScheduleReconcile("bot", "Bot")
        assert.equals(0, calls)              -- nothing fires until the debounce delay elapses
        Mock.tick(NS.RECONCILE_DELAY + 0.1)  -- all timers due; only the latest gen runs

        NS.CB_FetchInventory      = realFetch   -- restore before asserting
        NS.botInventoryFrames.bot = nil

        assert.equals(1, calls)
    end)
end)

describe("Whisper reply routing", function()
    before_each(function()
        Mock.reset()
    end)

    it("routes item lines to the section named by the last header (no cross-contamination)", function()
        local e = { name = "Bot", inventory = { items = {} }, bank = { items = {} },
                    awaitingInventory = true, invStaging = {},
                    awaitingBank = true, bankStaging = {} }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "=== Inventory ===", "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", itemLine(111, "Inv One"), "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", "=== Bank ===", "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", itemLine(222, "Bank One"), "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", itemLine(333, "Bank Two", 3), "Bot")

        assert.equals(1, #e.invStaging)
        assert.equals(2, #e.bankStaging)
        assert.is_true(e.invReplyArrived)
        assert.is_true(e.bankReplyArrived)
        assert.equals(3, e.bankStaging[2].count)
    end)

    it("finalizes a bank reply into bank.items on silence", function()
        local e = { name = "Bot", bank = { items = {} }, awaitingBank = true, bankStaging = {} }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "=== Bank ===", "Bot")
        Mock.fireEvent("CHAT_MSG_WHISPER", itemLine(222, "Bank One"), "Bot")
        Mock.tick(0.6)

        assert.equals(1, #e.bank.items)
        assert.is_false(e.awaitingBank)
        assert.is_nil(e.bankStaging)
    end)

    it("keeps the stale list when a reply never arrives (wipe guard)", function()
        local e = { name = "Bot", bank = { items = { { link = "KEEP", count = 1 } } },
                    awaitingBank = true, bankStaging = {}, bankReplyArrived = false }
        CleanBot_PartyBots = { bot = e }

        Mock.tick(0.6)   -- silence, but no reply ever arrived

        assert.equals(1, #e.bank.items)
        assert.equals("KEEP", e.bank.items[1].link)
        assert.is_false(e.awaitingBank)
    end)
end)

describe("Stats reply parsing", function()
    before_each(function() Mock.reset() end)

    it("parses money, bag totals (free→used), and clears awaitingMoney", function()
        local e = { name = "Bot", inventory = { items = {} }, awaitingMoney = true }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "5g 30s 10c, 12/16 Bag, 87% (5g 24s) Dur, 45/67% XP", "Bot")

        assert.equals(5,  e.money.gold)
        assert.equals(30, e.money.silver)
        assert.equals(10, e.money.copper)
        assert.equals(16, e.inventory.bagTotal)
        assert.equals(4,  e.inventory.bagUsed)   -- 16 total - 12 free
        assert.is_false(e.awaitingMoney)
    end)

    it("does not read the repair cost as coins when a denomination is missing", function()
        local e = { name = "Bot", inventory = { items = {} }, awaitingMoney = true }
        CleanBot_PartyBots = { bot = e }

        -- Broke-ish bot: wallet is 50s only; the repair cost (2g 30s 5c) is money-formatted.
        Mock.fireEvent("CHAT_MSG_WHISPER", "50s, 12/16 Bag, 87% (2g 30s 5c) Dur, 45/67% XP", "Bot")

        assert.equals(0,  e.money.gold)     -- must NOT pick up the repair cost's 2g
        assert.equals(50, e.money.silver)
        assert.equals(0,  e.money.copper)   -- must NOT pick up the repair cost's 5c
    end)
end)

describe("Formation reply parsing", function()
    before_each(function() Mock.reset() end)

    it("caches the formation token from a color-coded 'Formation:' whisper", function()
        local e = { name = "Bot" }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "Formation: |cff00ff00arrow", "Bot")

        assert.equals("arrow", e.formation)   -- color codes stripped, lowercased
    end)

    it("leaves formation unset for an unrelated whisper", function()
        local e = { name = "Bot" }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "just chatting", "Bot")

        assert.is_nil(e.formation)
    end)
end)

describe("Loot strategy reply parsing", function()
    before_each(function() Mock.reset() end)

    it("caches the loot mode from an 'll ?' / 'Loot strategy:' whisper", function()
        local e = { name = "Bot" }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "Loot strategy: |cff00ff00disenchant", "Bot")

        assert.equals("disenchant", e.lootStrategy)  -- color codes stripped, lowercased
    end)

    it("leaves lootStrategy unset for an unrelated whisper", function()
        local e = { name = "Bot" }
        CleanBot_PartyBots = { bot = e }

        Mock.fireEvent("CHAT_MSG_WHISPER", "just chatting", "Bot")

        assert.is_nil(e.lootStrategy)
    end)
end)

describe("Bridge single sell (ITEM_SELL)", function()
    local link = "|cffffffff|Hitem:1234|h[Grey Thing]|h|r"
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        NS.bridgeState = "present"
        NS.debugBridgeOverride = nil
        Mock.party = 1
    end)

    it("sends RUN~ITEM_SELL with exact coordinates when present", function()
        local cell = { bag = 0, slot = 5, itemId = 1234, count = 2, itemLink = link }
        assert.is_true(NS.CB_BridgeSellItem("bot", "Bot", link, cell))
        assert.equals(1, #Mock.addon)
        assert.is_true(Mock.addon[1].text:find("RUN~ITEM_SELL~Bot~", 1, true) == 1)
        assert.equals(0, #Mock.whispers)
    end)

    it("returns false without coordinates when present (no whisper fallback)", function()
        assert.is_false(NS.CB_BridgeSellItem("bot", "Bot", link, {}))
        assert.equals(0, #Mock.addon)
        assert.equals(0, #Mock.whispers)
    end)

    it("whispers s <link> when bridge is absent", function()
        NS.bridgeState = "absent"
        local cell = { bag = 0, slot = 5, itemId = 1234, count = 1, itemLink = link }
        assert.is_true(NS.CB_BridgeSellItem("bot", "Bot", link, cell))
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
    end)
end)

describe("Vendor sell sounds", function()
    local realPlay = NS.CB_PlaySellSound
    local sounds
    before_each(function()
        NS.CB_PlaySellSound = realPlay
        NS.groupSellPending = nil
        NS.bulkSellPending = {}
        Mock.reset()
        NS.bridgeState = "present"
        NS.debugBridgeOverride = nil
        Mock.party = 1
        sounds = 0
        NS.CB_PlaySellSound = function() sounds = sounds + 1 end
    end)

    it("plays one coin on single-sell OK", function()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_SELL~Bot~tok1~OK~OK~0~5~1234~1")
        assert.equals(1, sounds)
    end)

    it("stays silent on single-sell ERR", function()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_SELL~Bot~tok1~ERR~VENDOR_NOT_FOUND~0~5~1234~0")
        assert.equals(0, sounds)
    end)

    it("plays one coin on single-bot bulk sell OK with items", function()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        NS.CB_BridgeBulkSell("bot", "Bot")
        assert.equals(1, #Mock.addon)
        local sentMsg = Mock.addon[1].text
        local tok = strmatch(sentMsg, "RUN~ITEM_ACTION~Bot~([^~]+)~SELL_GREY")
        assert.is_not_nil(tok)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~Bot~" .. tok .. "~SELL_GREY~0~OK~OK~3")
        assert.equals(1, sounds)
    end)

    it("stays silent on single-bot bulk sell OK with 0 items", function()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        NS.CB_BridgeBulkSell("bot", "Bot")
        local sentMsg = Mock.addon[1].text
        local tok = strmatch(sentMsg, "RUN~ITEM_ACTION~Bot~([^~]+)~SELL_GREY")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~Bot~" .. tok .. "~SELL_GREY~0~OK~OK~0")
        assert.equals(0, sounds)
    end)

    it("stays silent on single-bot bulk sell ERR", function()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        NS.CB_BridgeBulkSell("bot", "Bot")
        local sentMsg = Mock.addon[1].text
        local tok = strmatch(sentMsg, "RUN~ITEM_ACTION~Bot~([^~]+)~SELL_GREY")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~Bot~" .. tok .. "~SELL_GREY~0~ERR~VENDOR_NOT_FOUND~0")
        assert.equals(0, sounds)
    end)

    it("plays once when every group SELL_GREY reply lands", function()
        Mock.party = 2
        Mock.roster = { party1 = "BotA", party2 = "BotB" }
        CleanBot_PartyBots = { bota = { name = "BotA" }, botb = { name = "BotB" } }
        NS.CB_BridgeGroupBulkSell()
        assert.equals(2, #Mock.addon)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~BotA~t1~SELL_GREY~0~OK~OK~3")
        assert.equals(0, sounds)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~BotB~t2~SELL_GREY~0~OK~OK~2")
        assert.equals(1, sounds)
    end)

    it("plays once on timeout with partial replies and ignores late stragglers", function()
        Mock.party = 2
        Mock.roster = { party1 = "BotA", party2 = "BotB" }
        CleanBot_PartyBots = { bota = { name = "BotA" }, botb = { name = "BotB" } }
        NS.CB_BridgeGroupBulkSell()
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~BotA~t1~SELL_GREY~0~OK~OK~3")
        Mock.tick(4.1)
        assert.equals(1, sounds)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~BotB~t2~SELL_GREY~0~OK~OK~2")
        assert.equals(1, sounds)
    end)

    it("stays silent when nobody sold anything", function()
        Mock.party = 2
        Mock.roster = { party1 = "BotA", party2 = "BotB" }
        CleanBot_PartyBots = { bota = { name = "BotA" }, botb = { name = "BotB" } }
        NS.CB_BridgeGroupBulkSell()
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~BotA~t1~SELL_GREY~0~OK~OK~0")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~BotB~t2~SELL_GREY~0~OK~OK~0")
        assert.equals(0, sounds)
    end)
end)

describe("Bridge bank withdraw (ITEM_ACTION BANK_WITHDRAW)", function()
    local link = "|cffffffff|Hitem:5678|h[Bank Thing]|h|r"
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        NS.bridgeState = "present"
        NS.debugBridgeOverride = nil
        NS.withdrawPending = {}
        Mock.party = 1
    end)

    it("sends RUN~ITEM_ACTION BANK_WITHDRAW matched by itemId+count when present", function()
        assert.is_true(NS.CB_BridgeWithdrawItem("bot", "Bot", link, 3))
        assert.equals(1, #Mock.addon)
        assert.is_true(Mock.addon[1].text:find("RUN~ITEM_ACTION~Bot~", 1, true) == 1)
        assert.is_true(Mock.addon[1].text:find("~BANK_WITHDRAW~5678~3", 1, true) ~= nil)
        assert.equals(0, #Mock.whispers)
    end)

    it("returns false for a bad link when present (no whisper)", function()
        assert.is_false(NS.CB_BridgeWithdrawItem("bot", "Bot", "nonsense", 1))
        assert.equals(0, #Mock.addon)
        assert.equals(0, #Mock.whispers)
    end)

    it("returns false when bridge is absent (caller whispers)", function()
        NS.bridgeState = "absent"
        assert.is_false(NS.CB_BridgeWithdrawItem("bot", "Bot", link, 1))
        assert.equals(0, #Mock.addon)
    end)

    it("clears the pending token on OK", function()
        NS.CB_BridgeWithdrawItem("bot", "Bot", link, 1)
        local sentMsg = Mock.addon[1].text
        local tok = strmatch(sentMsg, "RUN~ITEM_ACTION~Bot~([^~]+)~BANK_WITHDRAW")
        assert.is_not_nil(tok)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INVENTORY_ITEM_ACTION~Bot~" .. tok .. "~BANK_WITHDRAW~5678~OK~OK~1")
        assert.is_nil(NS.withdrawPending[tok])
    end)
end)

describe("Bridge stats (GET~STATS and STATS~ packet)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            mirabella = { name = "Mirabella" }
        }
        NS.bridgeState = "present"
        NS.debugBridgeOverride = nil
        Mock.party = 1
    end)

    it("dispatches GET~STATS~botName via bridge and marks in-flight without whispering", function()
        local entry = CleanBot_PartyBots.mirabella
        NS.CB_FetchStats(entry)
        assert.equals(1, #Mock.addon)
        assert.equals("GET~STATS~Mirabella", Mock.addon[1].text)
        assert.equals(0, #Mock.whispers)
        assert.is_true(entry.awaitingMoney)
        assert.equals(0, entry.moneyTimeout)

        -- In-flight dedup: second call bounces
        NS.CB_FetchStats(entry)
        assert.equals(1, #Mock.addon)
    end)

    it("parses incoming STATS~ wire payload and updates bot entry", function()
        local entry = CleanBot_PartyBots.mirabella
        entry.awaitingMoney = true
        entry.moneyTimeout = 5.0

        -- STATS~name~level~gold~silver~copper~bagUsed~bagTotal~durabilityPct~xpPct~manaPct
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "STATS~Mirabella~80~12~34~56~8~20~95~41~100")

        assert.is_false(entry.awaitingMoney)
        assert.equals(0, entry.moneyTimeout)
        assert.is_not_nil(entry.statsAt)
        assert.equals(80, entry.level)
        assert.same({ gold = 12, silver = 34, copper = 56 }, entry.money)
        assert.equals(8, entry.inventory.bagUsed)
        assert.equals(20, entry.inventory.bagTotal)
        assert.equals(95, entry.durability)
        assert.equals("41", entry.xpPercent)
        assert.equals(100, entry.manaPct)
    end)

    it("whispers stats when bridge is absent", function()
        NS.bridgeState = "absent"
        local entry = CleanBot_PartyBots.mirabella
        NS.CB_FetchStats(entry)
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("stats", Mock.whispers[1].text)
        assert.equals("Mirabella", Mock.whispers[1].target)
    end)
end)

describe("Bridge formations (GET~FORMATIONS and RUN~FORMATION)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            mirabella = { name = "Mirabella" },
            artemis = { name = "Artemis" },
        }
        NS.bridgeState = "present"
        NS.debugBridgeOverride = nil
        NS.formationsPending = false
        NS.formationsTimeout = 0
        NS.formationsToken = nil
        Mock.party = 1
    end)

    it("dispatches GET~FORMATIONS~GROUP~~token via bridge and marks bots awaitingFormation", function()
        NS.CB_FetchFormationsBridge()
        assert.equals(1, #Mock.addon)
        assert.is_not_nil(Mock.addon[1].text:match("^GET~FORMATIONS~GROUP~~%d+%-forms%-%d+$"))
        assert.is_true(NS.formationsPending)
        assert.is_true(CleanBot_PartyBots.mirabella.awaitingFormation)
        assert.is_true(CleanBot_PartyBots.artemis.awaitingFormation)
        assert.equals(0, #Mock.whispers)

        -- Deduplication: second call without force does not send duplicate packet
        NS.CB_FetchFormationsBridge()
        assert.equals(1, #Mock.addon)
    end)

    it("parses FORMATIONS_BEGIN, FORMATIONS_ITEM, and FORMATIONS_END wire packets", function()
        NS.CB_FetchFormationsBridge()
        local token = NS.formationsToken

        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "FORMATIONS_BEGIN~" .. token .. "~2")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "FORMATIONS_ITEM~" .. token .. "~Mirabella~arrow")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "FORMATIONS_ITEM~" .. token .. "~Artemis~melee")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "FORMATIONS_END~" .. token .. "~2")

        assert.is_false(NS.formationsPending)
        assert.equals("arrow", CleanBot_PartyBots.mirabella.formation)
        assert.is_false(CleanBot_PartyBots.mirabella.awaitingFormation)
        assert.equals("melee", CleanBot_PartyBots.artemis.formation)
        assert.is_false(CleanBot_PartyBots.artemis.awaitingFormation)
    end)

    it("clears awaitingFormation flag when ITEM returns '?' without corrupting existing formation", function()
        CleanBot_PartyBots.mirabella.formation = "arrow"
        NS.CB_FetchFormationsBridge()
        local token = NS.formationsToken

        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "FORMATIONS_ITEM~" .. token .. "~Mirabella~%3F")

        assert.is_false(CleanBot_PartyBots.mirabella.awaitingFormation)
        assert.equals("arrow", CleanBot_PartyBots.mirabella.formation)
    end)

    it("dispatches RUN~FORMATION~GROUP~~token~formation for allowed formations in group command", function()
        if not NS.CB_SendGroupCommand then dofile("CommandControls.lua") end
        NS.CB_SendGroupCommand("formation arrow")

        assert.equals(1, #Mock.addon)
        assert.is_not_nil(Mock.addon[1].text:match("^RUN~FORMATION~GROUP~~%d+%-setform%-%d+~arrow$"))
        assert.equals("arrow", CleanBot_PartyBots.mirabella.formation)
        assert.equals("arrow", CleanBot_PartyBots.artemis.formation)
        assert.equals(0, #Mock.chat)
    end)

    it("falls back to PARTY/RAID chat broadcast for unsupported formation 'far'", function()
        if not NS.CB_SendGroupCommand then dofile("CommandControls.lua") end
        NS.CB_SendGroupCommand("formation far")

        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.chat)
        assert.equals("formation far", Mock.chat[1].text)
        assert.equals("PARTY", Mock.chat[1].channel)
    end)

    it("whispers formation ? when bridge is absent", function()
        NS.bridgeState = "absent"
        local entry = CleanBot_PartyBots.mirabella
        NS.CB_FetchFormation(entry)

        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("formation ?", Mock.whispers[1].text)
        assert.equals("Mirabella", Mock.whispers[1].target)
        assert.is_true(entry.awaitingFormation)
    end)

    it("handles FORMATION_ACK and triggers re-fetch on failure", function()
        local reFetchCalled = false
        local oldFetch = NS.CB_FetchFormationsBridge
        NS.CB_FetchFormationsBridge = function(force)
            if force then reFetchCalled = true end
        end

        -- ACK with succeeded = 2, failed = 0
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "FORMATION_ACK~GROUP~~tok123~2~0~shield")
        assert.equals("shield", CleanBot_PartyBots.mirabella.formation)
        assert.equals("shield", CleanBot_PartyBots.artemis.formation)
        assert.is_false(reFetchCalled)

        -- ACK with failed = 1 triggers reconciliation
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "FORMATION_ACK~GROUP~~tok123~1~1~shield")
        assert.is_true(reFetchCalled)

        NS.CB_FetchFormationsBridge = oldFetch
    end)
end)

describe("Spellbook bridge gating and timeout", function()
    local NS = CleanBotNS

    before_each(function()
        Mock.reset()
        Mock.party = 1
        CleanBot_PartyBots = {
            mirabella = {
                name      = "Mirabella",
                class     = "MAGE",
                combat    = {},
                nonCombat = {},
                classData = {},
            },
        }
    end)

    it("does not send GET~SPELLBOOK or set awaitingSpellbook when bridge is absent", function()
        NS.bridgeState = "absent"
        NS.CB_RequestSpellbook("mirabella", "Mirabella", false)

        assert.equals(0, #Mock.addon)
        assert.is_nil(CleanBot_PartyBots.mirabella.awaitingSpellbook)
    end)

    it("sends GET~SPELLBOOK and sets awaitingSpellbook when bridge is present", function()
        NS.bridgeState = "present"
        NS.CB_RequestSpellbook("mirabella", "Mirabella", false)

        assert.equals(1, #Mock.addon)
        assert.equals("MBOT", Mock.addon[1].prefix)
        assert.is_true(Mock.addon[1].text:find("^GET~SPELLBOOK~Mirabella~") ~= nil)
        assert.is_true(CleanBot_PartyBots.mirabella.awaitingSpellbook)
    end)

    it("times out awaitingSpellbook after QUERY_TIMEOUT in invTickFrame", function()
        NS.bridgeState = "present"
        NS.CB_RequestSpellbook("mirabella", "Mirabella", false)
        assert.is_true(CleanBot_PartyBots.mirabella.awaitingSpellbook)

        -- Advance time past QUERY_TIMEOUT (10.0s)
        Mock.tick(10.1)

        assert.is_false(CleanBot_PartyBots.mirabella.awaitingSpellbook)
        assert.equals(0, CleanBot_PartyBots.mirabella.spellbookTimeout)
    end)
end)

describe("Talent spec list bridge routing and handling", function()
    local NS = CleanBotNS

    before_each(function()
        Mock.reset()
        Mock.party = 1
        CleanBot_PartyBots = {
            artemis = {
                name  = "Artemis",
                class = "WARRIOR",
            },
        }
        NS.premadeSpecs = {}
        NS.premadeSpecsFetching = {}
        NS.pendingSpecListRequests = {}
    end)

    it("sends GET~TALENT_SPEC_LIST with unique token when bridge is present", function()
        NS.bridgeState = "present"
        NS.CB_FetchSpecList("artemis", CleanBot_PartyBots.artemis)

        assert.equals(1, #Mock.addon)
        assert.equals(0, #Mock.whispers)
        assert.equals("MBOT", Mock.addon[1].prefix)
        assert.is_true(Mock.addon[1].text:find("^GET~TALENT_SPEC_LIST~Artemis~") ~= nil)
        assert.is_true(NS.premadeSpecsFetching["WARRIOR"])
    end)

    it("falls back to whisper 'talents spec list' when bridge is absent", function()
        NS.bridgeState = "absent"
        NS.CB_FetchSpecList("artemis", CleanBot_PartyBots.artemis)

        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("talents spec list", Mock.whispers[1].text)
        assert.equals("Artemis", Mock.whispers[1].target)
        assert.is_true(NS.premadeSpecsFetching["WARRIOR"])
    end)

    it("parses incoming spec items and populates premadeSpecs on END", function()
        NS.bridgeState = "present"
        NS.CB_FetchSpecList("artemis", CleanBot_PartyBots.artemis)

        local sentMsg = Mock.addon[1].text
        local token = sentMsg:match("^GET~TALENT_SPEC_LIST~Artemis~(.+)$")
        assert.is_not_nil(token)

        local syncCalled = false
        local oldSync = NS.CB_SyncTalentSpec
        NS.CB_SyncTalentSpec = function(key)
            if key == "artemis" then syncCalled = true end
        end

        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "TALENT_SPEC_BEGIN~Artemis~" .. token)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "TALENT_SPEC_CURRENT~Artemis~" .. token .. "~0~51~0~20")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "TALENT_SPEC_ITEM~Artemis~" .. token .. "~1~arms%20pve~51-0-20")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "TALENT_SPEC_ITEM~Artemis~" .. token .. "~2~fury%20pve~18-53-0")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "TALENT_SPEC_END~Artemis~" .. token)

        assert.is_true(syncCalled)
        assert.is_nil(NS.premadeSpecsFetching["WARRIOR"])
        assert.is_not_nil(NS.premadeSpecs["WARRIOR"])
        assert.equals(2, #NS.premadeSpecs["WARRIOR"])
        assert.equals("arms pve", NS.premadeSpecs["WARRIOR"][1].name)
        assert.are.same({ 51, 0, 20 }, NS.premadeSpecs["WARRIOR"][1].t)
        assert.equals("fury pve", NS.premadeSpecs["WARRIOR"][2].name)
        assert.are.same({ 18, 53, 0 }, NS.premadeSpecs["WARRIOR"][2].t)

        NS.CB_SyncTalentSpec = oldSync
    end)

    it("isolates parallel requests by token avoiding cross-contamination", function()
        CleanBot_PartyBots.mirabella = { name = "Mirabella", class = "MAGE" }
        NS.bridgeState = "present"

        NS.CB_FetchSpecList("artemis", CleanBot_PartyBots.artemis)
        local tok1 = Mock.addon[1].text:match("^GET~TALENT_SPEC_LIST~Artemis~(.+)$")

        NS.CB_FetchSpecList("mirabella", CleanBot_PartyBots.mirabella)
        local tok2 = Mock.addon[2].text:match("^GET~TALENT_SPEC_LIST~Mirabella~(.+)$")

        assert.is_true(tok1 ~= tok2)

        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "TALENT_SPEC_BEGIN~Mirabella~" .. tok2)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "TALENT_SPEC_ITEM~Mirabella~" .. tok2 .. "~1~frost%20pve~0-0-71")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "TALENT_SPEC_END~Mirabella~" .. tok2)

        assert.is_not_nil(NS.premadeSpecs["MAGE"])
        assert.equals(1, #NS.premadeSpecs["MAGE"])
        assert.equals("frost pve", NS.premadeSpecs["MAGE"][1].name)
        assert.is_nil(NS.premadeSpecs["WARRIOR"])
    end)
end)

describe("Bridge professions and recipes protocol", function()
    local NS

    before_each(function()
        Mock.reset()
        NS = CleanBotNS
        CleanBot_PartyBots = {
            artemis = {
                name = "Artemis",
                class = "WARRIOR",
                level = 80,
            },
        }
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "HELLO_ACK~2")
        Mock.party = 1
        Mock.addon = {}
    end)

    it("sends GET~PROFESSION query and respects TTL", function()
        NS.CB_FetchProfessions("artemis", "Artemis")
        assert.equals(1, #Mock.addon)
        assert.equals("GET~PROFESSION~Artemis", Mock.addon[1].text)

        -- Immediate second call without force does not duplicate
        NS.CB_FetchProfessions("artemis", "Artemis")
        assert.equals(1, #Mock.addon)

        -- Force flag bypasses TTL
        NS.CB_FetchProfessions("artemis", "Artemis", true)
        assert.equals(2, #Mock.addon)
        assert.equals("GET~PROFESSION~Artemis", Mock.addon[2].text)
    end)

    it("parses PROFESSION~ packet into entry.professions", function()
        local payload = "PROFESSION~Artemis~engineering:150/225;mining:225/300;cooking:75/150"
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", payload)

        local entry = CleanBot_PartyBots.artemis
        assert.is_not_nil(entry.professions)
        assert.equals(3, #entry.professions)

        assert.equals("engineering", entry.professions[1].key)
        assert.equals("Engineering", entry.professions[1].name)
        assert.equals(150, entry.professions[1].cur)
        assert.equals(225, entry.professions[1].max)
        assert.equals(202, entry.professions[1].skillId)

        assert.equals("mining", entry.professions[2].key)
        assert.equals("Mining", entry.professions[2].name)
        assert.equals(225, entry.professions[2].cur)
        assert.equals(300, entry.professions[2].max)
        assert.equals(186, entry.professions[2].skillId)

        assert.equals("cooking", entry.professions[3].key)
        assert.equals("Cooking", entry.professions[3].name)
        assert.equals(75, entry.professions[3].cur)
        assert.equals(150, entry.professions[3].max)
        assert.equals(185, entry.professions[3].skillId)
    end)

    it("streams and collects PROFESSION_RECIPES packets", function()
        NS.CB_FetchProfessionRecipes("artemis", "Artemis", 202)
        assert.equals(1, #Mock.addon)
        local token = Mock.addon[1].text:match("^GET~PROFESSION_RECIPES~Artemis~202~(.+)$")
        assert.is_not_nil(token)

        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "PROFESSION_RECIPES_BEGIN~Artemis~" .. token .. "~202")

        -- Item 1: Gun recipe (orange, craftable 2, 2 copper tubes and 4 bolts)
        local mats1 = "4359:2:5;4360:4:10"
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "PROFESSION_RECIPES_ITEM~Artemis~" .. token .. "~202~3928~4362~orange~2~" .. mats1)

        -- Item 2: Bomb recipe (yellow, craftable 0)
        local mats2 = "4359:1:0"
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "PROFESSION_RECIPES_ITEM~Artemis~" .. token .. "~202~3930~4364~yellow~0~" .. mats2)

        -- Item 3: Profession launcher ability / utility spell (Engineering 4036: itemId 0 and no reagents - should be filtered)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "PROFESSION_RECIPES_ITEM~Artemis~" .. token .. "~202~4036~0~optimal~0~")

        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "PROFESSION_RECIPES_END~Artemis~" .. token .. "~202")

        local entry = CleanBot_PartyBots.artemis
        assert.is_not_nil(entry.professionRecipes)
        assert.is_not_nil(entry.professionRecipes[202])
        local list = entry.professionRecipes[202].recipes
        assert.equals(2, #list)

        assert.equals(3928, list[1].spellId)
        assert.equals(4362, list[1].itemId)
        assert.equals("orange", list[1].difficulty)
        assert.equals(2, list[1].numAvailable)
        assert.equals(2, #list[1].reagents)
        assert.equals(4359, list[1].reagents[1].itemId)
        assert.equals(2, list[1].reagents[1].count)
        assert.equals(5, list[1].reagents[1].available)

        assert.equals(3930, list[2].spellId)
        assert.equals("yellow", list[2].difficulty)
        assert.equals(0, list[2].numAvailable)
    end)

    it("prunes timed out recipe requests after QUERY_TIMEOUT", function()
        NS.CB_FetchProfessionRecipes("artemis", "Artemis", 202)
        local token = Mock.addon[1].text:match("^GET~PROFESSION_RECIPES~Artemis~202~(.+)$")
        assert.is_not_nil(NS.pendingRecipeRequests[token])

        -- Advance time by 11 seconds
        Mock.tick(11)

        assert.is_nil(NS.pendingRecipeRequests[token])
    end)

    it("builds recipe tree grouped by subType and sorted by difficulty", function()
        local raw = {
            { name = "Rough Dynamite", difficulty = "gray",   subType = "Explosives" },
            { name = "Iron Grenade",   difficulty = "yellow", subType = "Explosives" },
            { name = "Flash Powder",   difficulty = "orange", subType = "Explosives" },
            { name = "Copper Tube",    difficulty = "green",  subType = "Parts" },
            { name = "Copper Mod",     difficulty = "orange", subType = "Parts" },
            { name = "Secret Device",  difficulty = "orange", subType = nil }, -- Should go to Miscellaneous
        }

        local tree = NS.CB_BuildProfessionRecipeTree(raw)
        assert.is_not_nil(tree)
        assert.equals(3, #tree)

        -- Categories: Explosives, Parts, Miscellaneous (Miscellaneous always last)
        assert.equals("Explosives", tree[1].name)
        assert.equals("Parts", tree[2].name)
        assert.equals("Miscellaneous", tree[3].name)

        -- In Explosives: Flash Powder (orange), Iron Grenade (yellow), Rough Dynamite (gray)
        assert.equals(3, #tree[1].recipes)
        assert.equals("Flash Powder", tree[1].recipes[1].name)
        assert.equals("orange", tree[1].recipes[1].difficulty)
        assert.equals("Iron Grenade", tree[1].recipes[2].name)
        assert.equals("yellow", tree[1].recipes[2].difficulty)
        assert.equals("Rough Dynamite", tree[1].recipes[3].name)
        assert.equals("gray", tree[1].recipes[3].difficulty)

        -- In Parts: Copper Mod (orange), Copper Tube (green)
        assert.equals(2, #tree[2].recipes)
        assert.equals("Copper Mod", tree[2].recipes[1].name)
        assert.equals("orange", tree[2].recipes[1].difficulty)
        assert.equals("Copper Tube", tree[2].recipes[2].name)
        assert.equals("green", tree[2].recipes[2].difficulty)

        -- In Miscellaneous: Secret Device (orange)
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

describe("CB_ToggleProfessions background inventory sync", function()
    local origFetchInv = NS.CB_FetchInventory
    local origFetchProf = NS.CB_FetchProfessions
    local origGetFrame = NS.CB_GetProfessionsFrame
    local origRenderProf = NS.CB_RenderProfessions
    local fetchInvCalls = 0
    local dummyFrame

    local function restore()
        NS.CB_FetchInventory = origFetchInv
        NS.CB_FetchProfessions = origFetchProf
        NS.CB_GetProfessionsFrame = origGetFrame
        NS.CB_RenderProfessions = origRenderProf
    end

    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            artemis = { name = "Artemis" },
        }
        fetchInvCalls = 0

        dummyFrame = {
            botKey = nil,
            botName = nil,
            currentProf = nil,
            IsShown = function() return false end,
            Show = function() end,
            Hide = function() end,
            GetPoint = function() return "CENTER" end,
            ClearAllPoints = function() end,
            SetPoint = function() end,
        }

        NS.CB_GetProfessionsFrame = function(k, n)
            return dummyFrame
        end
        NS.CB_FetchProfessions = function() end
        NS.CB_FetchInventory = function(k, n)
            fetchInvCalls = fetchInvCalls + 1
        end
        NS.CB_RenderProfessions = function() end
    end)

    it("fetches inventory when bot has no inventory items synced", function()
        CleanBot_PartyBots.artemis.inventory = nil
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals(1, fetchInvCalls)
    end)

    it("fetches inventory when bot has only STATS numeric bag counts but no items table", function()
        CleanBot_PartyBots.artemis.inventory = { bagUsed = 8, bagTotal = 20 }
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals(1, fetchInvCalls)
    end)

    it("does not fetch inventory when bot already has fresh items synced within INVENTORY_TTL", function()
        CleanBot_PartyBots.artemis.inventory = {
            items = { { itemId = 5956, name = "Blacksmith Hammer" } }
        }
        CleanBot_PartyBots.artemis.inventoryAt = GetTime()
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals(0, fetchInvCalls)
    end)

    it("refetches inventory when items are older than INVENTORY_TTL", function()
        CleanBot_PartyBots.artemis.inventory = {
            items = { { itemId = 5956, name = "Blacksmith Hammer" } }
        }
        CleanBot_PartyBots.artemis.inventoryAt = GetTime() - 35
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals(1, fetchInvCalls)
    end)

    it("does not fetch inventory if an inventory request is already in flight", function()
        CleanBot_PartyBots.artemis.awaitingInventory = true
        NS.CB_ToggleProfessions("artemis", "Artemis")
        restore()
        assert.equals(0, fetchInvCalls)
    end)

    restore()
end)

describe("INV_END and INV_EXACT_END record inventoryAt timestamp", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            artemis = { name = "Artemis", inventory = { items = {} } },
        }
    end)

    it("sets inventoryAt on INV_END", function()
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INV_END~Artemis")
        assert.is_not_nil(CleanBot_PartyBots.artemis.inventoryAt)
    end)

    it("sets inventoryAt on INV_EXACT_END", function()
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "INV_EXACT_END~Artemis")
        assert.is_not_nil(CleanBot_PartyBots.artemis.inventoryAt)
    end)
end)

describe("Bridge craft recipe (RUN~CRAFT_RECIPE and PROFESSION_RECIPE_CRAFT)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            artemis = { name = "Artemis" },
        }
        NS.bridgeState = "present"
        NS.debugBridgeOverride = nil
        NS.craftPending = {}
        Mock.party = 1
    end)

    it("sends RUN~CRAFT_RECIPE with expected fields when bridge is present", function()
        local ok = NS.CB_BridgeCraftRecipe("artemis", "Artemis", 202, 3918, 4358)
        assert.is_true(ok)
        assert.equals(1, #Mock.addon)
        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE~Artemis~([^~]+)~202~3918~4358$")
        assert.is_not_nil(token)
        assert.is_not_nil(NS.craftPending[token])
        assert.equals(202, NS.craftPending[token].skillId)
        assert.equals(3918, NS.craftPending[token].spellId)
        assert.equals(4358, NS.craftPending[token].itemId)
    end)

    it("handles PROFESSION_RECIPE_CRAFT OK response and invokes callback", function()
        local cbCalled, cbSuccess, cbReason, cbItemId = false, nil, nil, nil
        NS.CB_BridgeCraftRecipe("artemis", "Artemis", 202, 3918, 4358, function(success, reason, itId)
            cbCalled = true
            cbSuccess = success
            cbReason = reason
            cbItemId = itId
        end)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE~Artemis~([^~]+)~202~3918~4358$")
        assert.is_not_nil(token)

        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "PROFESSION_RECIPE_CRAFT~Artemis~" .. token .. "~202~3918~4358~OK~OK")

        assert.is_true(cbCalled)
        assert.is_true(cbSuccess)
        assert.equals("OK", cbReason)
        assert.equals(4358, cbItemId)
        assert.is_nil(NS.craftPending[token])
    end)

    it("handles PROFESSION_RECIPE_CRAFT ERR response and cleans pending token", function()
        local cbCalled, cbSuccess, cbReason = false, nil, nil
        NS.CB_BridgeCraftRecipe("artemis", "Artemis", 202, 3918, 4358, function(success, reason)
            cbCalled = true
            cbSuccess = success
            cbReason = reason
        end)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE~Artemis~([^~]+)~202~3918~4358$")
        assert.is_not_nil(token)

        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "PROFESSION_RECIPE_CRAFT~Artemis~" .. token .. "~202~3918~4358~ERR~NO_MATERIALS")

        assert.is_true(cbCalled)
        assert.is_false(cbSuccess)
        assert.equals("NO_MATERIALS", cbReason)
        assert.is_nil(NS.craftPending[token])
    end)

    it("returns false if bridge is absent", function()
        NS.bridgeState = "absent"
        local ok = NS.CB_BridgeCraftRecipe("artemis", "Artemis", 202, 3918, 4358)
        assert.is_false(ok)
        assert.equals(0, #Mock.addon)
    end)

    it("times out pending craft request after QUERY_TIMEOUT", function()
        local cbCalled, cbSuccess, cbReason = false, nil, nil
        NS.CB_BridgeCraftRecipe("artemis", "Artemis", 202, 3918, 4358, function(success, reason)
            cbCalled = true
            cbSuccess = success
            cbReason = reason
        end)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE~Artemis~([^~]+)~202~3918~4358$")
        assert.is_not_nil(NS.craftPending[token])

        -- Advance time past 10s
        Mock.tick(11)

        assert.is_nil(NS.craftPending[token])
        assert.is_true(cbCalled)
        assert.is_false(cbSuccess)
        assert.equals("TIMEOUT", cbReason)
    end)
end)

describe("Bridge craft recipe target (RUN~CRAFT_RECIPE_TARGET and CRAFT_RECIPE_TARGET_RESULT)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = {
            artemis = { name = "Artemis" },
        }
        NS.bridgeState = "present"
        NS.debugBridgeOverride = nil
        NS.craftTargetPending = {}
        Mock.party = 1
    end)

    it("sends RUN~CRAFT_RECIPE_TARGET with expected fields when bridge is present", function()
        local ok = NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 255, 8, 43210)
        assert.is_true(ok)
        assert.equals(1, #Mock.addon)
        assert.equals("MBOT", Mock.addon[1].prefix)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE_TARGET~([^~]+)~Artemis~333~27960~255~8~43210$")
        assert.is_not_nil(token)
        assert.is_not_nil(NS.craftTargetPending[token])
        assert.equals(333, NS.craftTargetPending[token].skillId)
        assert.equals(27960, NS.craftTargetPending[token].spellId)
        assert.equals(255, NS.craftTargetPending[token].targetBag)
        assert.equals(8, NS.craftTargetPending[token].targetSlot)
        assert.equals(43210, NS.craftTargetPending[token].targetItemId)
    end)

    it("accepts slot 0 for head equipment slot", function()
        local ok = NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 255, 0, 43210)
        assert.is_true(ok)
        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE_TARGET~([^~]+)~Artemis~333~27960~255~0~43210$")
        assert.is_not_nil(token)
        assert.equals(0, NS.craftTargetPending[token].targetSlot)
    end)

    it("handles CRAFT_RECIPE_TARGET_RESULT OK response and invokes callback", function()
        local cbCalled, cbSuccess, cbReason, cbItem = false, nil, nil, nil
        NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 255, 8, 43210, function(success, reason, targetItemId)
            cbCalled = true
            cbSuccess = success
            cbReason = reason
            cbItem = targetItemId
        end)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE_TARGET~([^~]+)~Artemis~333~27960~255~8~43210$")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "CRAFT_RECIPE_TARGET_RESULT~" .. token .. "~Artemis~OK~OK~333~27960~255~8~43210")

        assert.is_true(cbCalled)
        assert.is_true(cbSuccess)
        assert.equals("OK", cbReason)
        assert.equals(43210, cbItem)
        assert.is_nil(NS.craftTargetPending[token])
    end)

    it("handles CRAFT_RECIPE_TARGET_RESULT ERR response and cleans pending token", function()
        local cbCalled, cbSuccess, cbReason = false, nil, nil
        NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 255, 8, 43210, function(success, reason)
            cbCalled = true
            cbSuccess = success
            cbReason = reason
        end)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE_TARGET~([^~]+)~Artemis~333~27960~255~8~43210$")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "CRAFT_RECIPE_TARGET_RESULT~" .. token .. "~Artemis~ERR~INVALID_TARGET_ITEM~333~27960~255~8~43210")

        assert.is_true(cbCalled)
        assert.is_false(cbSuccess)
        assert.equals("INVALID_TARGET_ITEM", cbReason)
        assert.is_nil(NS.craftTargetPending[token])
    end)

    it("returns false if bridge is absent", function()
        NS.bridgeState = "absent"
        local ok = NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 255, 8, 43210)
        assert.is_false(ok)
        assert.equals(0, #Mock.addon)
    end)

    it("times out pending craft target request after QUERY_TIMEOUT", function()
        local cbCalled, cbSuccess, cbReason = false, nil, nil
        NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 255, 8, 43210, function(success, reason)
            cbCalled = true
            cbSuccess = success
            cbReason = reason
        end)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE_TARGET~([^~]+)~Artemis~333~27960~255~8~43210$")
        assert.is_not_nil(NS.craftTargetPending[token])

        Mock.tick(11)

        assert.is_nil(NS.craftTargetPending[token])
        assert.is_true(cbCalled)
        assert.is_false(cbSuccess)
        assert.equals("TIMEOUT", cbReason)
    end)

    it("sends RUN~CRAFT_RECIPE_TARGET with bag 0 (backpack) for item or vellum target", function()
        local ok = NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 0, 3, 37602)
        assert.is_true(ok)
        assert.equals(1, #Mock.addon)
        assert.equals("MBOT", Mock.addon[1].prefix)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE_TARGET~([^~]+)~Artemis~333~27960~0~3~37602$")
        assert.is_not_nil(token)
        assert.is_not_nil(NS.craftTargetPending[token])
        assert.equals(333, NS.craftTargetPending[token].skillId)
        assert.equals(27960, NS.craftTargetPending[token].spellId)
        assert.equals(0, NS.craftTargetPending[token].targetBag)
        assert.equals(3, NS.craftTargetPending[token].targetSlot)
        assert.equals(37602, NS.craftTargetPending[token].targetItemId)
    end)

    it("sends RUN~CRAFT_RECIPE_TARGET with bag 1-4 for inventory bag item", function()
        local ok = NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 2, 5, 43145)
        assert.is_true(ok)
        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE_TARGET~([^~]+)~Artemis~333~27960~2~5~43145$")
        assert.is_not_nil(token)
        assert.equals(2, NS.craftTargetPending[token].targetBag)
        assert.equals(5, NS.craftTargetPending[token].targetSlot)
        assert.equals(43145, NS.craftTargetPending[token].targetItemId)
    end)

    it("handles CRAFT_RECIPE_TARGET_RESULT OK for bag items", function()
        local cbCalled, cbSuccess, cbReason, cbItem = false, nil, nil, nil
        NS.CB_BridgeCraftRecipeTarget("artemis", "Artemis", 333, 27960, 1, 4, 37603, function(success, reason, targetItemId)
            cbCalled = true
            cbSuccess = success
            cbReason = reason
            cbItem = targetItemId
        end)

        local token = Mock.addon[1].text:match("^RUN~CRAFT_RECIPE_TARGET~([^~]+)~Artemis~333~27960~1~4~37603$")
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", "CRAFT_RECIPE_TARGET_RESULT~" .. token .. "~Artemis~OK~OK~333~27960~1~4~37603")

        assert.is_true(cbCalled)
        assert.is_true(cbSuccess)
        assert.equals("OK", cbReason)
        assert.equals(37603, cbItem)
        assert.is_nil(NS.craftTargetPending[token])
    end)
end)
