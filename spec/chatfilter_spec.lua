-- ============================================================
-- spec/chatfilter_spec.lua  —  ChatFilter.lua display filters: outgoing self-whisper
-- tag consumption, the incoming reply window, the group-echo filter, and the system-
-- message classifier. Filters are captured by the mock's ChatFrame_AddMessageEventFilter;
-- a returned true = line hidden. The bubble scanner (WorldFrame walk) is in-game only.
-- ============================================================
if not CleanBotNS.CB_Emit           then dofile("Events.lua") end
if not CleanBotNS.CB_ParseItemLine  then dofile("Individual/Inventory.lua") end
if not CleanBotNS.CB_EnqueueRequest then dofile("Bridge.lua") end
if not CleanBotNS.STRATEGY_MAP      then dofile("Individual/Strategies.lua") end
if not CleanBotNS.SPEC_DPS_TOKEN    then dofile("Individual/ClassData.lua") end
CleanBotNS.FORMATIONS = CleanBotNS.FORMATIONS or { { token = "arrow" } }
if not CleanBotNS.CB_IsSelfSender   then dofile("Overhear.lua") end

local loadedFilters = Mock.chatFilters.CHAT_MSG_SYSTEM ~= nil
if not loadedFilters then dofile("ChatFilter.lua") end
local NS = CleanBotNS

-- The single filter registered for `event` (each event has exactly one CleanBot filter).
local function filter(event, msg, author)
    local list = Mock.chatFilters[event]
    assert(list and #list == 1, "expected exactly one filter for " .. event)
    return list[1](nil, event, msg, author)
end

describe("ChatFilter outgoing whisper (INFORM)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots     = { bot = { name = "Bot" } }
        NS.hideBotChatter      = true
        NS.selfWhispers        = {}
        NS.botReplyWindow      = {}
        NS.debugBridgeOverride = "absent"   -- force the whisper path so sends get tagged
    end)

    it("hides an addon-sent command once, but shows an identical manual whisper", function()
        NS.CB_SendBotCommand("Bot", "s gray")            -- real send: tags NS.selfWhispers
        assert.equals(1, #Mock.whispers)
        assert.is_true(filter("CHAT_MSG_WHISPER_INFORM", "s gray", "Bot"))    -- addon echo hidden
        Mock.now = 0.1   -- the manual whisper's echo lands on a later frame
        assert.is_false(filter("CHAT_MSG_WHISPER_INFORM", "s gray", "Bot"))   -- manual repeat shown
    end)

    it("gives every chat window the same verdict for one line (per-frame replay)", function()
        -- Filters run once per chat window; a second window in the same frame must not
        -- find the tag already consumed and leak the echo.
        NS.CB_SendBotCommand("Bot", "s gray")
        assert.is_true(filter("CHAT_MSG_WHISPER_INFORM", "s gray", "Bot"))   -- window 1
        assert.is_true(filter("CHAT_MSG_WHISPER_INFORM", "s gray", "Bot"))   -- window 2, same frame
        Mock.now = 0.1
        assert.is_false(filter("CHAT_MSG_WHISPER_INFORM", "s gray", "Bot"))  -- tag consumed exactly once
    end)

    it("shows a manual whisper with no tag at all", function()
        assert.is_false(filter("CHAT_MSG_WHISPER_INFORM", "hello bot", "Bot"))
    end)

    it("expires a stale tag (failed send must not hide a later manual command)", function()
        NS.CB_SendBotCommand("Bot", "s gray")
        Mock.now = 10   -- > SELF_WHISPER_TTL after the tag
        assert.is_false(filter("CHAT_MSG_WHISPER_INFORM", "s gray", "Bot"))
    end)

    it("never hides whispers to someone outside the group/bot cache", function()
        assert.is_false(filter("CHAT_MSG_WHISPER_INFORM", "s gray", "Stranger"))
    end)

    it("is inert when Hide Bot Chatter is off", function()
        NS.CB_SendBotCommand("Bot", "s gray")
        NS.hideBotChatter = false
        assert.is_false(filter("CHAT_MSG_WHISPER_INFORM", "s gray", "Bot"))
    end)
end)

describe("ChatFilter incoming whisper (reply window)", function()
    before_each(function()
        Mock.reset()
        CleanBot_PartyBots = { bot = { name = "Bot" } }
        NS.hideBotChatter  = true
        NS.botReplyWindow  = {}
    end)

    it("hides a bot reply inside the command-reply window and slides the window", function()
        NS.CB_MarkExpectReply("Bot")                       -- window: now + WHISPER_SILENCE
        Mock.now = NS.WHISPER_SILENCE - 0.1
        assert.is_true(filter("CHAT_MSG_WHISPER", "Picking gray items", "Bot"))
        -- The reply slid the window forward, so a follow-up line inside the new window still hides.
        Mock.now = Mock.now + NS.WHISPER_SILENCE - 0.1
        assert.is_true(filter("CHAT_MSG_WHISPER", "another line", "Bot"))
    end)

    it("shows a bot whisper after the window closes (unsolicited greeting)", function()
        NS.CB_MarkExpectReply("Bot")
        Mock.now = NS.WHISPER_SILENCE + 0.1
        assert.is_false(filter("CHAT_MSG_WHISPER", "Hello!", "Bot"))
    end)

    it("shows whispers from non-group senders regardless of any window", function()
        assert.is_false(filter("CHAT_MSG_WHISPER", "hi", "Stranger"))
    end)
end)

describe("ChatFilter group echo", function()
    before_each(function()
        Mock.reset()
        NS.hideBotChatter    = true
        NS.selfGroupMessages = {}
    end)

    it("hides the player's own echo of a tagged broadcast, once per tag", function()
        NS.CB_TagSelfGroup("follow")
        assert.is_true(filter("CHAT_MSG_PARTY", "follow", "TestPlayer"))
        Mock.now = 0.1   -- a later, manually typed echo
        assert.is_false(filter("CHAT_MSG_PARTY", "follow", "TestPlayer"))  -- tag consumed
    end)

    it("replays the verdict to a second chat window in the same frame", function()
        NS.CB_TagSelfGroup("follow")
        assert.is_true(filter("CHAT_MSG_PARTY", "follow", "TestPlayer"))   -- window 1
        assert.is_true(filter("CHAT_MSG_PARTY", "follow", "TestPlayer"))   -- window 2, same frame
    end)

    it("keeps another member's identical message visible", function()
        NS.CB_TagSelfGroup("follow")
        assert.is_false(filter("CHAT_MSG_RAID", "follow", "SomeoneElse"))
    end)

    it("expires stale tags", function()
        NS.CB_TagSelfGroup("follow")
        Mock.now = 10
        assert.is_false(filter("CHAT_MSG_PARTY_LEADER", "follow", "TestPlayer"))
    end)
end)

describe("ChatFilter system messages", function()
    before_each(function()
        Mock.reset()
        NS.hideBotChatter = true
    end)

    it("hides the self-bot toggle line", function()
        assert.is_true(filter("CHAT_MSG_SYSTEM", "Player botAI enabled"))
    end)

    it("hides the linked-accounts header and its '- NAME' rows, then stops at a normal line", function()
        assert.is_true(filter("CHAT_MSG_SYSTEM", "Linked accounts:"))
        assert.is_true(filter("CHAT_MSG_SYSTEM", " - Botone"))
        assert.is_true(filter("CHAT_MSG_SYSTEM", " - Bottwo"))
        assert.is_false(filter("CHAT_MSG_SYSTEM", "You have joined a group."))  -- ends collection
        assert.is_false(filter("CHAT_MSG_SYSTEM", " - Botthree"))  -- row-shaped, but list is closed
    end)

    it("hides per-name bot command results but not similar-shaped normal lines", function()
        assert.is_true(filter("CHAT_MSG_SYSTEM", "add: Botone - ok"))
        assert.is_true(filter("CHAT_MSG_SYSTEM", "login: Botone - player already logged in"))
        assert.is_false(filter("CHAT_MSG_SYSTEM", "note: Botone - is a nice bot"))
    end)

    it("shows everything when Hide Bot Chatter is off", function()
        NS.hideBotChatter = false
        assert.is_false(filter("CHAT_MSG_SYSTEM", "Player botAI enabled"))
    end)
end)
