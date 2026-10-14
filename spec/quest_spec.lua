-- ============================================================
-- spec/quest_spec.lua  —  Individual/Quest.lua abandonment behavior.
-- Tests quest detail rendering and abandonment requests through bridge and whisper paths.
-- ============================================================
if not CleanBotNS.CB_RenderQuestDetail then dofile("Individual/Quest.lua") end
local NS = CleanBotNS

describe("CB_RenderQuestDetail abandonment", function()
    local origQuestEntries = GetNumQuestLogEntries
    local origFrames = NS.botQuestFrames
    local origCache = NS.questNameCache
    local origCreateHeader = NS.CB_CreateQuestHeader
    local origCreateParagraph = NS.CB_CreateQuestParagraph
    local origAnchorBelow = NS.CB_AnchorBelow
    local origResolveQuestName = NS.CB_ResolveQuestName
    local origPrint = NS.CB_Print
    local origBridgeState = NS.bridgeState
    local origBridgeOverride = NS.debugBridgeOverride
    local origCapabilities = NS.capabilities
    local origPartyBots = CleanBot_PartyBots
    local frame, button, messages, resolveCalls, resolveTitle

    local function restore()
        GetNumQuestLogEntries = origQuestEntries
        NS.botQuestFrames = origFrames
        NS.questNameCache = origCache
        NS.CB_CreateQuestHeader = origCreateHeader
        NS.CB_CreateQuestParagraph = origCreateParagraph
        NS.CB_AnchorBelow = origAnchorBelow
        NS.CB_ResolveQuestName = origResolveQuestName
        NS.CB_Print = origPrint
        NS.bridgeState = origBridgeState
        NS.debugBridgeOverride = origBridgeOverride
        NS.capabilities = origCapabilities
        CleanBot_PartyBots = origPartyBots
    end

    -- Local widget stubs for quests absent from the player's quest log.
    local function widget()
        return {
            scripts = {},
            SetScript = function(self, event, fn) self.scripts[event] = fn end,
            SetPoint = function() end,
            SetWidth = function() end,
            SetHeight = function() end,
            SetText = function() end,
            Hide = function() end,
            IsShown = function() return true end,
            GetWidth = function() return 300 end,
            GetHeight = function() return 200 end,
        }
    end

    before_each(function()
        restore()
        Mock.reset()
        Mock.party = 1
        NS.bridgeState = "present"
        NS.debugBridgeOverride = nil
        NS.capabilities = {}
        NS.questNameCache = {}
        CleanBot_PartyBots = { bot = { name = "Bot", quests = { { id = 404, status = "I" } } } }
        GetNumQuestLogEntries = function() return 0 end
        NS.CB_CreateQuestHeader = widget
        NS.CB_CreateQuestParagraph = widget
        NS.CB_AnchorBelow = function() end
        messages, resolveCalls, resolveTitle = {}, 0, nil
        NS.CB_Print = function(msg) messages[#messages + 1] = msg end
        NS.CB_ResolveQuestName = function(_, callback)
            resolveCalls = resolveCalls + 1
            resolveTitle = callback
        end
        button = widget()
        button.Enable = function(self) self.enabled = true end
        button.Disable = function(self) self.enabled = false end
        frame = widget()
        frame.abandonBtn = button
        frame.detailScrollChild = widget()
        frame.detailScrollFrame = widget()
        NS.botQuestFrames = { bot = frame }
    end)

    local function render(questId)
        NS.CB_RenderQuestDetail("bot", questId or 404)
    end

    local function click()
        button.scripts.OnClick()
    end

    local function reply(status, reason, questId, requestIndex)
        local token = Mock.addon[requestIndex or 1].text:match("^RUN~QUEST_ABANDON_TARGET~([^~]+)~")
        assert.is_not_nil(token)
        Mock.fireEvent("CHAT_MSG_ADDON", "MBOT", table.concat({
            "QUEST_ABANDON_TARGET_RESULT", token, "Bot", tostring(questId or 404), status, reason,
            status == "OK" and "1" or "0",
        }, "~"))
    end

    it("enables abandonment by ID and refreshes the quest list after confirmation", function()
        render()
        assert.is_true(button.enabled)
        assert.equals(0, resolveCalls)
        click()
        assert.is_true(frame.abandonPending)
        assert.is_false(button.enabled)
        assert.equals(1, #Mock.addon)
        assert.is_not_nil(Mock.addon[1].text:match("^RUN~QUEST_ABANDON_TARGET~[^~]+~Bot~404$"))
        assert.equals(0, #Mock.whispers)
        reply("OK", "OK")
        assert.is_nil(frame.abandonPending)
        assert.equals(2, #Mock.addon)
        assert.equals("GET~QUESTS~ALL~Bot~quests", Mock.addon[2].text)
        assert.equals(0, #Mock.whispers)
        assert.equals(0, #messages)
        restore()
    end)

    it("restores button availability after a server error without whisper or refresh", function()
        CleanBot_PartyBots.bot.quests[1].name = "Quest Title"
        render()
        click()
        reply("ERR", "FORBIDDEN")
        assert.is_nil(frame.abandonPending)
        assert.is_true(button.enabled)
        assert.equals(1, #messages)
        assert.is_not_nil(messages[1]:find("FORBIDDEN", 1, true))
        assert.equals(1, #Mock.addon)
        assert.equals(0, #Mock.whispers)
        click()
        assert.equals(2, #Mock.addon)
        reply("ERR", "FORBIDDEN", 404, 2)
        restore()
    end)

    it("restores button availability after timeout and ignores late results", function()
        CleanBot_PartyBots.bot.quests[1].name = "Quest Title"
        render()
        click()
        Mock.tick(NS.QUERY_TIMEOUT or 10)
        assert.is_nil(frame.abandonPending)
        assert.is_true(button.enabled)
        assert.equals(1, #messages)
        assert.is_not_nil(messages[1]:find("TIMEOUT", 1, true))
        reply("OK", "OK")
        assert.equals(1, #Mock.addon)
        assert.equals(0, #Mock.whispers)
        restore()
    end)

    it("blocks duplicate requests while abandonment is pending", function()
        render()
        click()
        click()
        render()
        assert.is_false(button.enabled)
        click()
        assert.equals(1, #Mock.addon)
        reply("OK", "OK")
        assert.is_nil(frame.abandonPending)
        restore()
    end)

    it("preserves the current quest selection when an earlier request completes", function()
        CleanBot_PartyBots.bot.quests[2] = { id = 405, status = "I" }
        render()
        click()
        render(405)
        assert.is_false(button.enabled)
        reply("OK", "OK")
        assert.equals(405, frame.selectedQuestID)
        assert.is_true(button.enabled)
        click()
        assert.is_not_nil(Mock.addon[3].text:match("^RUN~QUEST_ABANDON_TARGET~[^~]+~Bot~405$"))
        reply("OK", "OK", 405, 3)
        assert.is_nil(frame.abandonPending)
        assert.equals(0, #Mock.whispers)
        restore()
    end)

    it("sends whisper abandonment and requests a quest refresh after two seconds", function()
        NS.bridgeState = "absent"
        CleanBot_PartyBots.bot.quests[1].name = "Quest Title"
        render()
        click()
        assert.is_false(button.enabled)
        assert.equals(0, #Mock.addon)
        assert.equals(1, #Mock.whispers)
        assert.equals("drop Quest Title", Mock.whispers[1].text)
        assert.equals("Bot", Mock.whispers[1].target)
        frame.scripts.OnUpdate(frame, 1)
        assert.equals(1, #Mock.whispers)
        frame.scripts.OnUpdate(frame, 1)
        assert.is_nil(frame.scripts.OnUpdate)
        -- The serial whisper queue dispatches the quest query after reply silence.
        Mock.tick(NS.WHISPER_SILENCE_TIMEOUT or 0.5)
        assert.equals(2, #Mock.whispers)
        assert.equals("quests all", Mock.whispers[2].text)
        assert.equals(0, #Mock.addon)
        restore()
    end)

    it("resolves missing quest titles when the bridge is absent", function()
        NS.bridgeState = "absent"
        render()
        assert.is_false(button.enabled)
        assert.equals(1, resolveCalls)
        assert.equals(0, #Mock.addon)
        assert.equals(0, #Mock.whispers)
        NS.questNameCache[404] = "Resolved Title"
        resolveTitle("Resolved Title")
        assert.is_true(button.enabled)
        click()
        assert.equals("drop Resolved Title", Mock.whispers[1].text)
        assert.equals(0, #Mock.addon)
        restore()
    end)

    it("uses whisper routing when the bridge override is absent", function()
        NS.debugBridgeOverride = "absent"
        CleanBot_PartyBots.bot.quests[1].name = "Quest Title"
        render()
        click()
        assert.equals(0, #Mock.addon)
        assert.equals("drop Quest Title", Mock.whispers[1].text)
        restore()
    end)

    restore()
end)
