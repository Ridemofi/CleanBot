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
