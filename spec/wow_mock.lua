-- ============================================================
-- spec/wow_mock.lua  —  Minimal WoW 3.3.5a client API mock.
--
-- Defines just enough global state for CleanBot's logic files to LOAD under a standalone
-- Lua interpreter and for the functions under test to run. NOT a full emulation — extend it
-- as new specs exercise more of the API. Anything needing the live client (real frame
-- layout, rendering) is out of scope.
--
-- The `Mock` table is the test-facing control surface: it records outgoing sends, lets a
-- spec drive the OnUpdate tick and the clock, and resets between tests.
-- ============================================================

-- The namespace each addon file binds via `local NS = CleanBotNS`.
_G.CleanBotNS = _G.CleanBotNS or {}

_G.Mock = {
    whispers = {},   -- recorded SendChatMessage(..., "WHISPER", ...)  → { text=, target= }
    chat     = {},   -- recorded SendChatMessage on any other channel  → { text=, channel= }
    addon    = {},   -- recorded SendAddonMessage                      → { prefix=, text=, channel= }
    onUpdate = {},   -- captured OnUpdate handlers → { frame=, fn= }
    onEvent  = {},   -- captured OnEvent handlers  → { frame=, fn= }
    timers   = {},   -- pending CB_After callbacks  → { elapsed=, delay=, fn= }
    now      = 0,    -- value returned by GetTime()
    raid     = 0,    -- GetNumRaidMembers()
    party    = 0,    -- GetNumPartyMembers()
    roster     = {},  -- [unit] = name, for UnitName lookups (e.g. roster.party1 = "Botone")
    playerUnit = nil, -- group unit that IS the player (e.g. "raid2"), for UnitIsUnit
    chatFilters = {}, -- captured ChatFrame_AddMessageEventFilter fns → [event] = { fn, ... }
    items       = {}, -- GetItemInfo cache → [itemId] = canonical link
}

--- Clears recorded sends + the clock. Call from before_each. Leaves captured frame handlers
--- and chat filters intact (both are registered once at file load, not per test).
function Mock.reset()
    Mock.whispers   = {}
    Mock.chat       = {}
    Mock.addon      = {}
    Mock.timers     = {}
    Mock.now        = 0
    Mock.raid       = 0
    Mock.party      = 0
    Mock.roster     = {}
    Mock.playerUnit = nil
    Mock.items      = {}
end

--- Advances the clock by dt, fires every captured OnUpdate handler with (frame, dt), then
--- fires any CB_After callback whose delay has elapsed — mirrors one client frame.
function Mock.tick(dt)
    Mock.now = Mock.now + dt
    for _, h in ipairs(Mock.onUpdate) do h.fn(h.frame, dt) end
    local due = {}
    for _, t in ipairs(Mock.timers) do
        t.elapsed = t.elapsed + dt
        if t.elapsed >= t.delay then due[#due + 1] = t end
    end
    for _, t in ipairs(due) do
        for i, x in ipairs(Mock.timers) do if x == t then table.remove(Mock.timers, i); break end end
        t.fn()
    end
end

--- Fires a WoW event into every captured OnEvent handler as (frame, event, ...).
--- e.g. Mock.fireEvent("CHAT_MSG_WHISPER", "=== Bank ===", "Bot").
function Mock.fireEvent(event, ...)
    for _, h in ipairs(Mock.onEvent) do h.fn(h.frame, event, ...) end
end

-- Chainable frame stub. SetScript captures OnUpdate/OnEvent so specs can drive them; every
-- other method is a no-op returning the frame so load-time frame setup survives `dofile`.
local function makeFrame()
    local f = {}
    f.SetScript = function(self, event, fn)
        if event == "OnUpdate" then Mock.onUpdate[#Mock.onUpdate + 1] = { frame = self, fn = fn } end
        if event == "OnEvent"  then Mock.onEvent[#Mock.onEvent + 1]   = { frame = self, fn = fn } end
        return self
    end
    f.HookScript    = function(self) return self end
    f.RegisterEvent = function(self) return self end
    setmetatable(f, { __index = function() return function() return f end end })
    return f
end
_G.CreateFrame = function() return makeFrame() end
_G.UIParent    = makeFrame()

-- Globals referenced at file scope by the addon.
_G.StaticPopupDialogs = _G.StaticPopupDialogs or {}
_G.OKAY               = _G.OKAY or "Okay"

-- Client API used by the code under test.
_G.GetTime            = function() return Mock.now end
_G.GetNumRaidMembers  = function() return Mock.raid end
_G.GetNumPartyMembers = function() return Mock.party end

-- The player is "TestPlayer"; group units resolve through Mock.roster.
_G.UnitName = function(unit)
    if unit == nil or unit == "player" then return "TestPlayer" end
    return Mock.roster[unit]
end
-- Unit identity: "player" and Mock.playerUnit are the same character.
local function canonUnit(u)
    if u == "player" or (Mock.playerUnit and u == Mock.playerUnit) then return "player" end
    return u
end
_G.UnitIsUnit = function(a, b) return canonUnit(a) == canonUnit(b) end

-- Item cache: only ids seeded into Mock.items resolve (others = cache miss → nils).
_G.GetItemInfo = function(itemId)
    local link = Mock.items[itemId]
    if not link then return nil end
    local name = link:match("%[(.-)%]")
    return name, link
end

-- Chat-frame display filters register once at file load; specs invoke them via
-- Mock.chatFilters[event][i](nil, event, ...) to drive the display pipeline.
_G.ChatFrame_AddMessageEventFilter = function(event, fn)
    local list = Mock.chatFilters[event]
    if not list then list = {}; Mock.chatFilters[event] = list end
    list[#list + 1] = fn
end

_G.SendChatMessage = function(text, channel, _, target)
    if channel == "WHISPER" then
        Mock.whispers[#Mock.whispers + 1] = { text = text, target = target }
    else
        Mock.chat[#Mock.chat + 1] = { text = text, channel = channel }
    end
end
_G.SendAddonMessage = function(prefix, text, channel)
    Mock.addon[#Mock.addon + 1] = { prefix = prefix, text = text, channel = channel }
end

-- WoW string helpers — aliases of the standard string library used throughout the addon.
_G.strmatch = string.match
_G.gmatch   = string.gmatch
_G.strfind  = string.find
_G.strsub   = string.sub
_G.strlower = string.lower
_G.strupper = string.upper
_G.strrep   = string.rep
_G.strtrim  = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

-- Test-environment overrides installed AFTER run.lua dofiles the real CleanBot.lua
-- (which provides CB_SplitOnce, the group helpers, etc. — tested directly in core_spec).
-- CB_Print is muted, and CB_After is redirected onto Mock.timers so Mock.reset()
-- can drop pending callbacks between tests (the real shared timer can't be flushed).
function Mock.silenceCore()
    _G.CleanBotNS.CB_Print = function() end
    _G.CleanBotNS.CB_After = function(delay, fn)
        Mock.timers[#Mock.timers + 1] = { elapsed = 0, delay = delay, fn = fn }
    end
end
