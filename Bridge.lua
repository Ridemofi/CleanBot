-- ============================================================
-- Bridge.lua  —  MBOT bridge / playerbot protocol layer.
--
-- Owns the handshake, debounced sync, no-bridge whisper discovery,
-- linked-account fetch, inventory fetch, quest fetch, the event
-- handler that parses ROSTER~ / DETAIL~ / STATE~ / INV_* / QUESTS_*
-- addon messages plus the co?/nc? whisper replies, and the item-link
-- cleaning helper used before sending links over bot commands.
-- ============================================================
local NS = CleanBotNS

-- URL-decode a percent-encoded string (e.g. quest names from the bridge).
-- Converts %XX hex sequences to their ASCII characters.
---@param s string  Percent-encoded string.
---@return string   The decoded string.
local function CB_UrlDecode(s)
    return (s:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

-- Returns the clean API item link for a raw item link (which may carry color
-- codes and extra enchant/gem fields that confuse the server-side parser).
-- Strips to the item ID and re-fetches a canonical link from the client cache via
-- GetItemInfo, falling back to the raw link on a cache miss.
-- Use this before sending any item link over a bot command (give/equip/etc.).
---@param rawLink string  The raw item link (may carry extra fields).
---@return string         The canonical client-cache link, or rawLink on a cache miss.
NS.CB_CleanItemLink = function(rawLink)
    local itemId = strmatch(rawLink, "item:(%d+)")
    local _, apiLink = GetItemInfo(tonumber(itemId) or 0)
    return apiLink or rawLink
end

-- Numeric class ids as sent in ROSTER~ records (Player::getClass()); 10 is unused.
local CLASS_ID_TOKENS = {
    [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER",  [4] = "ROGUE",   [5] = "PRIEST",
    [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
}

-- ============================================================
-- Bot discovery / roster helpers
-- These support bot identification and class resolution during the
-- handshake and STATE~ packet handling below, so they live alongside the
-- discovery state and probing logic. Called at event time, so they may
-- reference helpers defined in earlier-loading files (CB_GroupInfo).
-- ============================================================

-- Tests whether a unit token belongs to a tracked playerbot.
---@param unit string  Unit token to test (e.g. "party1").
---@return boolean      Whether the unit is a tracked playerbot.
NS.CleanBot_IsBot = function(unit)
    local name = UnitName(unit)
    if not name then return false end
    if CleanBot_PartyBots[strlower(name)] then return true end
    return false
end

-- Returns the group unit id ("partyN" or "raidN") whose name matches, or nil.
-- Walks the raid roster when in a raid, the party roster otherwise.
---@param name string  Character name to locate in the party/raid.
---@return string|nil   The matching unit token (e.g. "party2" / "raid5"), or nil.
NS.CB_FindPartyUnit = function(name)
    local prefix, n = NS.CB_GroupInfo()
    for i = 1, n do
        local unit = prefix .. i
        if UnitName(unit) == name then return unit end
    end
    return nil
end

-- Resolves a bot's class token from the live party roster (authoritative),
-- falling back to the supplied value (or WARRIOR) when the unit isn't found.
---@param name     string  Character name to resolve the class for.
---@param fallback string? Class token to return when resolution fails.
---@return string|nil       The resolved class token, or fallback.
NS.CB_ResolveClass = function(name, fallback)
    local unit = NS.CB_FindPartyUnit(name)
    if unit then
        local _, class = UnitClass(unit)
        if class then return class end
    end
    return fallback or "WARRIOR"
end

-- ============================================================
-- Bridge / handshake state
-- ============================================================
NS.lastRawStates = nil
NS.lastHelloAck  = nil
NS.bridgeReady   = false
-- Capability negotiation (CAPS) & state framing
NS.capabilities          = {}
NS.stateFramingCapable   = false
NS.capabilitiesResolved  = false
NS.capabilityBatchActive = false
NS.stateRequests         = {}
NS.stateActive           = {}
NS.stateSeq              = 0

-- Bridge availability: "unknown" until detection resolves, then "present"
-- (HELLO_ACK received) or "absent" (detection timed out). Drives whether
-- strategy reads use GET~STATES (bridge) or co?/nc? whispers (no bridge).
NS.bridgeState   = "unknown"
NS.probed        = {}   -- name-key -> true: party member already probed for bot-hood
NS.awaitingProbe = {}   -- name-key -> true: probe co? sent, awaiting a "Strategies:" reply

-- Debug overrides — both are nil/false by default and are toggled via /cbdebug.
-- nil = auto (follow real handshake); "present" or "absent" = forced override.
NS.debugBridgeOverride = nil   ---@type string|nil
-- When true, CB_SendBotCommand prints commands to chat instead of sending them.
NS.debugSimulate       = false ---@type boolean
-- When true, strategy toggles log any optimistic-vs-actual mismatch after the
-- authoritative state comes back (see CB_SendStrategyToggle / CB_VerifyStrategyExpect).
NS.debugVerify         = false ---@type boolean

-- No-bridge login gating: on a fresh login (not a /reload) bots may not be
-- online yet, so we block CB_ProbePartyForBots until bridge detection resolves.
-- Once it does, the probe sweep runs and a not-yet-ready bot is caught later via
-- its readiness whisper (see NS.joinCandidates).
NS.loginPhaseActive = false  -- true only on fresh login, cleared when detection resolves

-- Re-probe candidates: members CB_ProbePartyForBots has probed but not yet confirmed. If that
-- probe goes unanswered because the bot was still loading, its later readiness whisper re-probes
-- it (the greeting branch in CHAT_MSG_WHISPER). The fast path there uses a LIVE group check plus
-- "not probed", so the first greeting from a freshly-joined member triggers immediately without
-- any pre-set flag; this set only covers the re-probe-after-unanswered case. Cleared on the
-- re-probe / on confirmation / on leaving, so a chatty human gets at most one stray probe.
NS.joinCandidates   = {}     -- name-key -> display-name: probed, awaiting a re-probe if unanswered

-- ============================================================
-- Linked accounts  (populated by .playerbots account linkedAccounts)
-- ============================================================
NS.linkedAccounts            = {}
NS.awaitingLinkedAccounts    = false  -- true = waiting for "Linked accounts:" header
NS.collectingLinkedAccounts  = false  -- true = reading "- NAME" lines

NS.CleanBot_FetchLinkedAccounts = function()
    NS.linkedAccounts           = {}
    NS.awaitingLinkedAccounts   = true
    NS.collectingLinkedAccounts = false
    SendChatMessage(".playerbots account linkedAccounts", "SAY")
end

-- ============================================================
-- Debounced bridge sync + UI refresh
-- ============================================================
NS.syncPending = false

-- No-bridge discovery: whisper "co ?" to each group member (party or raid)
-- exactly once. Only members that reply with a "Strategies: " line are treated
-- as bots (handled in the CHAT_MSG_WHISPER branch). Humans never respond, so
-- they are probed a single time and then ignored. Each probed member is flagged as a
-- joinCandidate so that, if this probe goes unanswered because the bot was still loading,
-- its later readiness whisper re-probes it (see the CHAT_MSG_WHISPER greeting branch).
-- Skipped during loginPhaseActive — bots may not be online yet on fresh
-- login; probing waits until detection resolves, then this sweep runs.
local function CB_ProbePartyForBots()
    if NS.loginPhaseActive then return end

    -- Forget probe records for members who have left, so a rejoin re-probes.
    local present = {}
    NS.CB_ForEachGroupMember(function(unit, nm)
        if nm then present[strlower(nm)] = true end
    end)
    for k in pairs(NS.probed) do
        if not present[k] then
            NS.probed[k] = nil; NS.awaitingProbe[k] = nil; NS.joinCandidates[k] = nil
        end
    end

    NS.CB_ForEachGroupMember(function(unit, nm)
        if nm and UnitIsPlayer(unit) then
            local key = strlower(nm)
            if not CleanBot_PartyBots[key] and not NS.probed[key] then
                NS.probed[key]         = true
                NS.awaitingProbe[key]  = true
                NS.joinCandidates[key] = nm   -- re-probe target if this probe goes unanswered
                NS.CB_SendBotCommand(nm, "co ?")
            end
        end
    end)
end

-- ============================================================
-- Self-bot management
-- ============================================================
-- mod-playerbots can register the player's own character as a bot. The authoritative
-- live signal is the server's "Enable/Disable player botAI" system message (parsed in
-- the CHAT_MSG_SYSTEM handler), which fires however the toggle happens — addon, login
-- auto-enable, or a manually typed `.playerbot bot self`. CB_SetSelfBotActive applies
-- that live state on the addon side; it never sends the toggle command itself (that is
-- a pure server toggle, sent only once on a fresh login — see PLAYER_ENTERING_WORLD).
--
-- NS.selfBotActive  = live state (driven by the messages; persisted only for reload).
-- NS.manageSelf     = auto-enable-on-login preference (Settings checkbox / first-time popup).

--- Applies the player's live self-bot state on the addon side (no command is sent).
--- active=true seeds the player as a known bot, reads real strategies, and surfaces them
--- in the lists; active=false drops them. Persists the state for /reload recovery.
---@param active boolean  Whether the player is currently a self-bot.
NS.CB_SetSelfBotActive = function(active)
    active = active and true or false
    NS.selfBotActive = active
    if CleanBot_SavedVars then CleanBot_SavedVars.selfBotActive = active end

    local name = UnitName("player")
    local key  = name and strlower(name)

    if active and key then
        -- Seed a known-bot entry (same shape as the ROSTER~ handler) so the player counts
        -- as a bot regardless of bridge state. Class comes from the client (always known).
        if not CleanBot_PartyBots[key] then
            local _, class = UnitClass("player")
            class = class or "WARRIOR"
            CleanBot_PartyBots[key] = {
                name      = name,
                class     = class,
                combat    = NS.CB_DefaultCombat(),
                nonCombat = NS.CB_DefaultNonCombat(),
                classData = NS.CB_DefaultClassData(class),
            }
        end

        -- Now that we're a live self-bot, resolve the bridge if it hasn't yet (the gate
        -- keys off NS.selfBotActive, so a self-whisper handshake can run solo).
        if NS.bridgeState == "unknown" and NS.CB_StartBridgeDetection then
            NS.CB_StartBridgeDetection()
        end

        -- Read the player's actual strategies. A bare "co ?" (awaitingCo, NOT coVerifyOnly)
        -- stores the combat reply then chains "nc ?" — a full read, same as the probe path.
        -- Always whispers (queries are never bridged), and self-whisper works here.
        local entry = CleanBot_PartyBots[key]
        if entry then
            entry.awaitingCo = true
            NS.CB_SendBotCommand(name, "co ?")
        end
    elseif key then
        CleanBot_PartyBots[key] = nil
    end

    if CleanBotFrame:IsShown() and NS.CleanBot_RefreshTabs then
        NS.CleanBot_RefreshTabs()
    end
end

-- ============================================================
-- Bridge allowlists — mirror of MultiBotBridge.cpp IsAllowed*()
-- Source: https://github.com/Wishmaster117/mod-multibot-bridge/blob/main/src/MultiBotBridge.cpp
-- Keep in sync with the server when the bridge is updated.
-- ============================================================

-- RUN~COMBAT — IsAllowedCombatCommand()
local BRIDGE_COMBAT_CMDS = {
    ["CO +FOCUS"]           = true,
    ["CO -FOCUS"]           = true,
    ["CO +DPS ASSIST"]      = true,
    ["CO -DPS ASSIST"]      = true,
    ["CO +AOE"]             = true,
    ["CO -AOE"]             = true,
    ["CO +DPS AOE"]         = true,
    ["CO -DPS AOE"]         = true,
    ["CO +TANK ASSIST"]     = true,
    ["CO -TANK ASSIST"]     = true,
    ["CO +AVOID AOE"]       = true,
    ["CO -AVOID AOE"]       = true,
    ["CO +SAVE MANA"]       = true,
    ["CO -SAVE MANA"]       = true,
    ["CO +THREAT"]          = true,
    ["CO -THREAT"]          = true,
    ["CO +BEHIND"]          = true,
    ["CO -BEHIND"]          = true,
    ["CO +WAIT FOR ATTACK"] = true,
    ["CO -WAIT FOR ATTACK"] = true,
    -- "wait for attack time N" (N = 0–60) handled via pattern below
}

-- RUN~LOOT — IsAllowedLootCommand()  (case-sensitive after trim)
local BRIDGE_LOOT_CMDS = {
    ["nc +loot"] = true,
    ["nc -loot"] = true,
    ["ll all"]   = true,
    ["ll normal"] = true,
    ["ll gray"]  = true,
    ["ll quest"] = true,
    ["ll skill"] = true,
}

-- RUN~RTI — IsAllowedRTIIcon()
local BRIDGE_RTI_ICONS = {
    ["STAR"]     = true,
    ["CIRCLE"]   = true,
    ["DIAMOND"]  = true,
    ["TRIANGLE"] = true,
    ["MOON"]     = true,
    ["SQUARE"]   = true,
    ["CROSS"]    = true,
    ["SKULL"]    = true,
}

-- RUN~FORMATION — IsAllowedFormationName() (case-sensitive, lowercase 8 tokens; "far" excluded)
local BRIDGE_FORMATIONS = {
    ["arrow"]  = true,
    ["queue"]  = true,
    ["near"]   = true,
    ["melee"]  = true,
    ["line"]   = true,
    ["circle"] = true,
    ["chaos"]  = true,
    ["shield"] = true,
}
NS.BRIDGE_FORMATIONS = BRIDGE_FORMATIONS

---@param command string  The bot command being routed.
---@return string|nil      The bridge opcode ("COMBAT"/"POSITION"/"LOOT"/"RTI") or nil to whisper.
local function CB_GetBridgeOpcode(command)
    -- COMBAT: static set
    if BRIDGE_COMBAT_CMDS[strupper(command)] then return "COMBAT" end

    -- COMBAT: "wait for attack time N" — no "co" prefix, N must be 0–60
    local n = strmatch(command, "^[Ww][Aa][Ii][Tt]%s+[Ff][Oo][Rr]%s+[Aa][Tt][Tt][Aa][Cc][Kk]%s+[Tt][Ii][Mm][Ee]%s+(%d+)$")
    if n and tonumber(n) <= 60 then return "COMBAT" end

    -- POSITION: "disperse disable" or "disperse set N" (0 < N ≤ 100)
    local lower = strlower(command)
    if lower == "disperse disable" then return "POSITION" end
    local dval = strmatch(lower, "^disperse set%s+(.+)$")
    if dval then
        local v = tonumber(dval)
        if v and v > 0 and v <= 100 then return "POSITION" end
    end

    -- LOOT: static set (case-sensitive)
    if BRIDGE_LOOT_CMDS[command] then return "LOOT" end

    -- RTI: "attack/pull rti target", "rti <icon>", "rti cc <icon>"
    local upper = strupper(command)
    if upper == "ATTACK RTI TARGET" or upper == "PULL RTI TARGET" then return "RTI" end
    local rtiIcon = strmatch(upper, "^RTI%s+(%S+)$")
    if rtiIcon and BRIDGE_RTI_ICONS[rtiIcon] then return "RTI" end
    local rtiCCIcon = strmatch(upper, "^RTI%s+CC%s+(%S+)$")
    if rtiCCIcon and BRIDGE_RTI_ICONS[rtiCCIcon] then return "RTI" end

    return nil
end

-- Returns the effective bridge state, respecting NS.debugBridgeOverride.
-- Use this instead of reading NS.bridgeState directly inside CB_SendBotCommand
-- so that /cbdebug bridge on/off can exercise both code paths without a real bridge.
local function CB_EffectiveBridgeState()
    return NS.debugBridgeOverride or NS.bridgeState
end
NS.CB_EffectiveBridgeState = CB_EffectiveBridgeState

-- Sends a bridge addon packet on the correct channel:
--   • In a raid  → "RAID"   ("PARTY" does not reach raid members)
--   • In a party → "PARTY"
--   • Solo + self-management on → "WHISPER" to self. The server bridge replies directly
--     to the sender (player->SendDirectMessage in MultiBotBridge.cpp) and its chat hook
--     fires on the whisper overload regardless of recipient, so a self-whisper completes
--     the handshake and carries all GET~/RUN~ traffic with no group present.
--   • Solo without self-management → no bots to talk to, so this no-ops.
local function CB_SendBridge(msg)
    if GetNumRaidMembers() > 0 then
        SendAddonMessage("MBOT", msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage("MBOT", msg, "PARTY")
    elseif NS.selfBotActive then
        SendAddonMessage("MBOT", msg, "WHISPER", UnitName("player"))
    end
end

-- Command-reply window: bots confirm nearly every command with a whisper — a one-line ack
-- ("Picking ...", "Wait for attack time set to ...") or a multi-line dump (items/quests/spec).
-- Rather than enumerate every reply string, we open a per-bot window the instant we whisper a
-- command with INITIAL_REPLY_TIMEOUT (5.0s) patience to accommodate initial bot processing and
-- login latency. ChatFilter.lua suppresses that bot's whispers while the window is open and
-- slides it to WHISPER_SILENCE (0.5s) as each reply line arrives, closing promptly once quiet.
NS.INITIAL_REPLY_TIMEOUT = 5.0
NS.botReplyWindow = NS.botReplyWindow or {}   -- [lowername] = GetTime() deadline

---@param botName string  The bot we just whispered a command/query to.
local function CB_MarkExpectReply(botName)
    if botName and botName ~= "" then
        NS.botReplyWindow[strlower(botName)] = GetTime() + (NS.INITIAL_REPLY_TIMEOUT or 5.0)
    end
end
-- Exposed so broadcast (party/raid) commands can open reply windows for the bots
-- they reach, letting ChatFilter hide their whispered replies (CommandControls.lua).
NS.CB_MarkExpectReply = CB_MarkExpectReply

-- Outgoing whisper provenance: CHAT_MSG_WHISPER_INFORM can't tell an addon-sent command from
-- one the user typed by hand, so we tag each command whisper we send. ChatFilter.lua hides only
-- the tagged ones, leaving manually typed whispers to a bot visible. Keyed by recipient+text,
-- holding a short list of send timestamps (a list, not a flag, so two identical commands in a
-- row each get their own tag); ChatFilter consumes one per matching INFORM and expires stale
-- tags (a failed send fires no INFORM, so its tag must not linger and hide a later manual one).
NS.selfWhispers = NS.selfWhispers or {}   -- ["lowerRecipient\0text"] = { GetTime(), ... }

---@param recipient string  Whisper target (bot name).
---@param text      string  Exact whisper text the addon is sending.
local function CB_TagSelfWhisper(recipient, text)
    if not recipient or recipient == "" then return end
    local k    = strlower(recipient) .. "\0" .. (text or "")
    local list = NS.selfWhispers[k]
    if not list then list = {}; NS.selfWhispers[k] = list end
    list[#list + 1] = GetTime()
end

-- Same provenance problem for broadcast commands: the player's own party/raid echo
-- (CHAT_MSG_PARTY/RAID, sender = the player) is indistinguishable from a manually typed line, so we
-- tag each broadcast CleanBot sends. Keyed by text only (sender is always the player); ChatFilter
-- consumes one tag per matching echo and expires stale ones.
NS.selfGroupMessages = NS.selfGroupMessages or {}   -- [text] = { GetTime(), ... }

---@param text string  Exact party/raid message the addon is broadcasting.
local function CB_TagSelfGroup(text)
    if not text or text == "" then return end
    local list = NS.selfGroupMessages[text]
    if not list then list = {}; NS.selfGroupMessages[text] = list end
    list[#list + 1] = GetTime()
end
NS.CB_TagSelfGroup = CB_TagSelfGroup

-- Raw dispatch: the actual bridge-or-whisper send. Routes through the bridge (silent) when
-- present and the command is allowlisted; otherwise whispers. Honors the debugSimulate and
-- debugBridgeOverride toggles. Called by the serial queue (for whispers) and directly for
-- bridge/simulated commands — NOT to be called directly for ad-hoc whispers; use
-- CB_SendBotCommand so they serialize.
local cmdSeq = 0
local function CB_NextCmdToken(prefix)
    cmdSeq = (cmdSeq or 0) + 1
    return tostring(math.floor(GetTime() * 1000)) .. "-" .. (prefix or "cmd") .. "-" .. tostring(cmdSeq)
end

---@param botName string  Target bot's name (whisper recipient / bridge BOT field).
---@param command string  The command text to run.
local function CB_SendBotCommandRaw(botName, command)
    if NS.debugSimulate then
        NS.CB_Print("|cff888888[simulate]|r → " .. botName .. ": " .. command)
        return
    end
    if CB_EffectiveBridgeState() == "present" then
        local opcode = CB_GetBridgeOpcode(command)
        if opcode then
            local token = CB_NextCmdToken("cmd")
            CB_SendBridge("RUN~" .. opcode .. "~BOT~" .. botName .. "~" .. token .. "~" .. command)
            return
        end
    end
    CB_MarkExpectReply(botName)
    CB_TagSelfWhisper(botName, command)
    SendChatMessage(command, "WHISPER", nil, botName)
end
NS.CB_SendBotCommandRaw = CB_SendBotCommandRaw  -- for queued fetch/move sends (avoids re-enqueue)

-- Sends a command to a bot. WHISPER commands are serialized through the bot's request queue
-- so their (possibly multi-line, link-bearing) replies never interleave with another reply
-- stream and corrupt our parsing. Bridge commands (structured addon messages, no whisper
-- reply) and simulated commands bypass the queue so they stay snappy.
NS.CB_SendBotCommand = function(botName, command)
    -- Simulate prints, no reply; bridge is a fast addon message with no whisper stream.
    if NS.debugSimulate
        or (CB_EffectiveBridgeState() == "present" and CB_GetBridgeOpcode(command)) then
        CB_SendBotCommandRaw(botName, command)
        return
    end
    NS.CB_EnqueueRequest(strlower(botName), function() CB_SendBotCommandRaw(botName, command) end)
end

local function CB_BeginStateRequest(isGlobal, botName)
    NS.stateSeq = (NS.stateSeq or 0) + 1
    local suffix = isGlobal and "states" or "state"
    local token = tostring(math.floor(GetTime() * 1000)) .. "-" .. suffix .. "-" .. tostring(NS.stateSeq)
    NS.stateRequests[token] = {
        token         = token,
        global        = isGlobal == true,
        botName       = botName or "",
        startedAt     = GetTime(),
        begun         = false,
        expectedBots  = 0,
        completedBots = 0,
    }
    NS.CB_After(10.0, function()
        if NS.stateRequests[token] then
            NS.stateRequests[token] = nil
        end
    end)
    return token
end

local function CB_ClearStateRequest(token)
    if not token then return end
    NS.stateRequests[token] = nil
    for k, v in pairs(NS.stateActive) do
        if v.token == token then
            NS.stateActive[k] = nil
        end
    end
end

NS.CB_RequestSync = function()
    if NS.syncPending then return end
    NS.syncPending = true
    NS.CB_After(0.5, function()
        NS.syncPending = false
        if CB_EffectiveBridgeState() == "present" then
            CB_SendBridge("GET~ROSTER")
            CB_SendBridge("GET~DETAILS")
            if NS.stateFramingCapable then
                local token = CB_BeginStateRequest(true)
                CB_SendBridge("GET~STATES~" .. token)
            else
                CB_SendBridge("GET~STATES")
            end
            if NS.CB_FetchFormationsBridge then
                NS.CB_FetchFormationsBridge()
            end
        elseif CB_EffectiveBridgeState() == "absent" then
            CB_ProbePartyForBots()
        end
        if CleanBotFrame:IsShown() then
            NS.CleanBot_RefreshTabs()
        end
    end)
end

--- Convenience wrapper: kicks off a debounced roster/details/states sync.
NS.CB_RequestRosterThenRefresh = function()
    NS.CB_RequestSync()
end

-- Lightweight, debounced strategy-state re-sync (bridge path). Unlike
-- CB_RequestSync it sends ONLY GET~STATES (framed when capable) — no ROSTER/DETAILS
-- and no RefreshTabs — so it reconciles strategy flags without tab/inspect churn.
-- Used to verify a strategy toggle silently after sending it over the bridge.
NS.statesPending = false
NS.CB_RequestStates = function()
    if NS.statesPending then return end
    NS.statesPending = true
    NS.CB_After(0.4, function()
        NS.statesPending = false
        if CB_EffectiveBridgeState() == "present" then
            if NS.stateFramingCapable then
                local token = CB_BeginStateRequest(true)
                CB_SendBridge("GET~STATES~" .. token)
            else
                CB_SendBridge("GET~STATES")
            end
        end
    end)
end

-- Authoritative per-bot re-read of strategies + formation + loot — used to VERIFY/reconcile after a
-- command that optimistically rewrites a bot's whole state (e.g. the Individual tab's "reset botAI",
-- applied optimistically by Overhear). Unlike CB_RequestSync this targets one ALREADY-KNOWN bot —
-- CB_RequestSync's no-bridge probe (CB_ProbePartyForBots) skips known bots, so it can't re-read here.
-- "co ?" needs awaitingCo set so its reply is parsed and chains "nc ?" (mirrors CB_SetSelfBotActive);
-- the formation/loot replies match by prefix and need no flag. All three are whispered queries (never
-- bridged) and queue in order BEHIND the triggering command, so they read the post-command state; each
-- reply repaints via CB_UpdateTabData, overwriting the optimistic guess with the bot's real values.
---@param key     string  Bot name-key (CleanBot_PartyBots index).
---@param botName string  The bot's name (whisper recipient).
NS.CB_RereadBotState = function(key, botName)
    local entry = key and CleanBot_PartyBots[key]
    if not (entry and botName) then return end
    entry.awaitingCo = true
    NS.CB_SendBotCommand(botName, "co ?")
    NS.CB_SendBotCommand(botName, "formation ?")
    NS.CB_SendBotCommand(botName, "ll ?")
end

-- Sends a combat/non-combat strategy toggle, then arranges an authoritative
-- re-read so the optimistic UI converges to the bot's real state (self-healing).
-- Path-aware to avoid reintroducing bridge whisper spam:
--   bridge present → send the toggle as usual (allowlisted singles stay silent),
--                    then a silent debounced GET~STATES (CB_RequestStates).
--   no bridge      → send the atomic combined form "<prefix> <toggle>,?" so the
--                    bot's "Strategies:" reply (still via CHAT_MSG_WHISPER) reflects
--                    the post-set state; arm awaitingCo/awaitingNc to consume it.
-- expectMap = { [field] = bool } of the toggled strategies; recorded for the
-- /cbdebug verify mismatch check (only when NS.debugVerify is on).
---@param slot      table   The bound slot (resolves the live bot via slot.key/.name).
---@param prefix    string  "co" or "nc".
---@param toggleStr string  Toggle body, e.g. "+focus", "-aoe", "+arms,-fury,-prot".
---@param expectMap table?  field→expected-bool map for the debug mismatch check.
NS.CB_SendStrategyToggle = function(slot, prefix, toggleStr, expectMap)
    local entry = CleanBot_PartyBots[slot.key]

    if entry and NS.debugVerify and expectMap then
        local section = (prefix == "co") and "combat" or "nonCombat"
        entry.stratExpect = entry.stratExpect or {}
        local acc = entry.stratExpect[section] or {}
        for f, v in pairs(expectMap) do acc[f] = v end   -- merge so rapid toggles all check
        entry.stratExpect[section] = acc
    end

    if CB_EffectiveBridgeState() == "present" then
        NS.CB_SendBotCommand(slot.name, prefix .. " " .. toggleStr)
        NS.CB_RequestStates()
    else
        NS.CB_SendBotCommand(slot.name, prefix .. " " .. toggleStr .. ",?")
        if entry then
            if prefix == "co" then
                entry.awaitingCo   = true
                entry.coVerifyOnly = true   -- parse the combat reply but don't chain "nc ?"
            else
                entry.awaitingNc = true
            end
        end
    end
end

-- Finalizes a whisper-path quest collection: swaps the staged quests into the
-- live list and re-renders if the bot's quest frame is open. Shared by the
-- summary-line terminator and the silence-timeout fallback below.
---@param key   string  Bot name-key.
---@param entry table   The bot roster entry being finalized.
local function CB_FinalizeQuestCollection(key, entry)
    entry.awaitingQuests = false
    entry.questTimeout   = 0
    -- Only swap when the reply actually arrived: a lost/late reply times out with
    -- empty staging, and overwriting would wipe a good list (mirrors invReplyArrived).
    if entry.questReplyArrived and entry.questStaging then
        entry.quests = entry.questStaging
    end
    entry.questStaging = nil
    local f = NS.botQuestFrames and NS.botQuestFrames[key]
    if f and f:IsShown() and NS.CB_RenderQuests then NS.CB_RenderQuests(key) end
end

-- Finalizes a bridge spellbook collection: sorts the staged spells,
-- saves them into entry.spells, and updates the UI if open.
---@param key   string  Bot name-key.
---@param entry table   The bot roster entry being finalized.
local function CB_FinalizeSpellbookCollection(key, entry)
    entry.awaitingSpellbook = false
    entry.spellbookTimeout  = 0
    if entry.spellbookStaging and #entry.spellbookStaging > 0 then
        table.sort(entry.spellbookStaging, function(a, b)
            if a.isPassive ~= b.isPassive then
                return not a.isPassive
            end
            return (a.name or "") < (b.name or "")
        end)
        entry.spells = entry.spellbookStaging
    end
    entry.spellbookStaging = nil
    entry.spellbookSeen    = nil
    local f = NS.botSpellbookFrames and NS.botSpellbookFrames[key]
    if f and f:IsShown() and NS.CB_RenderSpellbook then
        NS.CB_RenderSpellbook(key)
    end
end

-- Requests the bot's spellbook via Bridge (GET~SPELLBOOK)
---@param key     string   Bot name-key.
---@param botName string?  Display name.
---@param force   boolean? True to force refresh even if cached.
NS.spellbookSeq = NS.spellbookSeq or 0
NS.CB_RequestSpellbook = function(key, botName, force)
    local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
    if not entry then
        local bName = botName or key
        entry = {
            name      = bName,
            class     = "WARRIOR",
            combat    = NS.CB_DefaultCombat and NS.CB_DefaultCombat(),
            nonCombat = NS.CB_DefaultNonCombat and NS.CB_DefaultNonCombat(),
            classData = NS.CB_DefaultClassData and NS.CB_DefaultClassData("WARRIOR"),
        }
        CleanBot_PartyBots[key] = entry
    end

    if CB_EffectiveBridgeState() ~= "present" then
        if NS.CB_RenderSpellbook then NS.CB_RenderSpellbook(key) end
        return
    end

    if not force and entry.spells and #entry.spells > 0 then
        if NS.CB_RenderSpellbook then NS.CB_RenderSpellbook(key) end
        return
    end

    entry.awaitingSpellbook = true
    entry.spellbookTimeout  = 0
    entry.spellbookStaging  = {}
    entry.spellbookSeen     = {}

    local bName = botName or entry.name or key
    NS.spellbookSeq = NS.spellbookSeq + 1
    local token = tostring(math.floor(GetTime() * 1000)) .. "-" .. tostring(NS.spellbookSeq)
    entry.spellbookToken = token

    CB_SendBridge(string.format("GET~SPELLBOOK~%s~%s", bName, token))
    if NS.CB_RenderSpellbook then NS.CB_RenderSpellbook(key) end
end

-- ============================================================
-- Premade talent-spec list cache  (per class, in-memory)
-- "talents spec list" replies one line per premade: "1. arms pve (51-0-20)"
-- where the name is the exact "talents spec <name>" argument (== dropdown cmd)
-- and (t1-t2-t3) is the per-tree point spread. CB_SyncTalentSpec matches the
-- inspected bot's tree totals against these spreads to identify its premade.
-- ============================================================
NS.premadeSpecs         = {}   -- [class] = { { name = "arms pve", t = {51,0,20} }, ... }
NS.premadeSpecsFetching = {}   -- [class] = true while a list fetch is in flight

-- Whispers "talents spec list" to one bot of the class and arms collection.
-- One fetch per class per session; the reply lines are collected in the
-- CHAT_MSG_WHISPER handler and finalized on 2s silence in invTickFrame.
---@param key   string  Bot name-key of the bot to query.
---@param entry table   The bot roster entry (provides name/class).
NS.CB_FetchSpecList = function(key, entry)
    if not entry or not entry.class then return end
    if NS.premadeSpecs[entry.class] or NS.premadeSpecsFetching[entry.class] then return end
    NS.premadeSpecsFetching[entry.class] = true

    if CB_EffectiveBridgeState() == "present" then
        NS.pendingSpecListRequests = NS.pendingSpecListRequests or {}
        NS.specListSeq = (NS.specListSeq or 0) + 1
        local bName = entry.name or key
        local token = tostring(math.floor(GetTime() * 1000)) .. "-speclist-" .. tostring(NS.specListSeq)
        NS.pendingSpecListRequests[token] = {
            token   = token,
            class   = entry.class,
            key     = key,
            botName = bName,
            staging = {},
            expires = GetTime() + (NS.QUERY_TIMEOUT or 10.0),
        }
        CB_SendBridge(string.format("GET~TALENT_SPEC_LIST~%s~%s", bName, token))
        return
    end

    -- Enqueue: the silence timer (specListTimeout) must start at SEND time, not now, or a
    -- deferred send behind other requests would finalize before the reply arrives.
    NS.CB_EnqueueRequest(key, function()
        entry.awaitingSpecList = true
        entry.specListTimeout  = 0
        entry.specListStaging  = {}
        NS.CB_SendBotCommandRaw(entry.name, "talents spec list")
    end)
end

-- Publishes a collected spec list to the per-class cache and re-runs the
-- pending talent sync that requested it.
---@param key   string  Bot name-key.
---@param entry table   The bot roster entry being finalized.
local function CB_FinalizeSpecList(key, entry)
    entry.awaitingSpecList = false
    entry.specListTimeout  = 0
    if entry.class then
        NS.premadeSpecsFetching[entry.class] = nil
        -- Publish even an empty list so a server with no premades doesn't refetch
        -- on every inspect; the sync just falls back to tree-name display.
        NS.premadeSpecs[entry.class] = entry.specListStaging or {}
    end
    entry.specListStaging = nil
    if NS.CB_SyncTalentSpec then NS.CB_SyncTalentSpec(key) end
end

-- Inter-line silence and collection finalization timeout.
-- Once a reply stream starts, lines arrive rapidly (gaps < 20ms). 0.5s ensures snappy
-- UI finalization (inventory/bank/quests) without lag. For initial command latency
-- before the first reply arrives, see NS.INITIAL_REPLY_TIMEOUT (5.0s).
NS.WHISPER_SILENCE = 0.5

-- Safety timeout for in-flight single-query responses (stats, formation, loot strategy).
-- Prevents getting stuck forever if a bot drops a reply, while avoiding premature
-- retries when queued behind earlier commands in the serial whisper queue.
NS.QUERY_TIMEOUT = 10.0
NS.PROFESSIONS_TTL = 30.0

-- Profession skill IDs and canonical names matching MultiBotBridge.cpp:704-719
NS.PROF_SKILL_IDS = {
    alchemy        = 171,
    blacksmithing  = 164,
    enchanting     = 333,
    engineering    = 202,
    herbalism      = 182,
    inscription    = 773,
    jewelcrafting  = 755,
    leatherworking = 165,
    mining         = 186,
    skinning       = 393,
    tailoring      = 197,
    cooking        = 185,
    firstaid       = 129,
    fishing        = 356,
}

NS.PROF_CANONICAL_NAMES = {
    alchemy        = "Alchemy",
    blacksmithing  = "Blacksmithing",
    enchanting     = "Enchanting",
    engineering    = "Engineering",
    herbalism      = "Herbalism",
    inscription    = "Inscription",
    jewelcrafting  = "Jewelcrafting",
    leatherworking = "Leatherworking",
    mining         = "Mining",
    skinning       = "Skinning",
    tailoring      = "Tailoring",
    cooking        = "Cooking",
    firstaid       = "First Aid",
    fishing        = "Fishing",
}

NS.PROF_NAME_TO_SKILL_ID = {}
for k, v in pairs(NS.PROF_SKILL_IDS) do
    NS.PROF_NAME_TO_SKILL_ID[k] = v
    local cName = NS.PROF_CANONICAL_NAMES[k]
    if cName then
        NS.PROF_NAME_TO_SKILL_ID[cName] = v
        NS.PROF_NAME_TO_SKILL_ID[cName:lower()] = v
    end
end

-- ── Per-bot serial whisper queue ─────────────────────────────────────────
-- A bot's reply (items / bank / stats list, a "Strategies:" line, a "put X to bank"
-- confirmation, …) is a whisper that can span many lines and may echo item links. Sending
-- another whisper before it finishes interleaves the replies and corrupts our parsing
-- (duplicate items, items snapping back). So EVERY whisper to a bot is queued and sent ONE
-- AT A TIME. The queue owns a single generic busy flag (wqBusy): set when a request is sent,
-- and cleared once the bot's reply has gone silent (each incoming whisper resets the timer in
-- CHAT_MSG_WHISPER). Typed flags like awaitingInventory still drive parsing/finalize/lock, but
-- the queue's advancement is governed solely by wqBusy, so it works uniformly for every kind
-- of request. Bridge/simulated commands don't whisper and bypass the queue (see CB_SendBotCommand).

---@param key string  Bot name-key.
local function CB_PumpQueue(key)
    local entry = CleanBot_PartyBots[key]
    if not entry or not entry.reqQueue or entry.wqBusy then return end
    local send = table.remove(entry.reqQueue, 1)
    if send then
        entry.wqBusy    = true   -- held until the reply goes silent (tick below)
        entry.wqTimeout = 0
        send()
    end
end

-- Enqueues a whisper request (`send` performs the actual raw whisper). Runs immediately when
-- the bot is idle, else after the in-flight request's reply completes.
---@param key  string  Bot name-key.
---@param send fun()   Performs the raw whisper send.
NS.CB_EnqueueRequest = function(key, send)
    local entry = CleanBot_PartyBots[key]
    if not entry then
        -- No per-bot entry to serialize against — e.g. a no-bridge discovery probe
        -- ("co ?") to a member not yet known to be a bot. There is no reply stream to
        -- interleave with, so send immediately rather than dropping it.
        send()
        return
    end
    entry.reqQueue = entry.reqQueue or {}
    entry.reqQueue[#entry.reqQueue + 1] = send
    CB_PumpQueue(key)
end

-- Tick inventory, money, quest, and spec-list timeouts for the whisper path
-- (silence = collection done), then drain the serial request queue as bots go idle.
local invTickFrame = CreateFrame("Frame")
invTickFrame:SetScript("OnUpdate", function(self, dt)
    for key, entry in pairs(CleanBot_PartyBots) do
        if entry.awaitingSpecList then
            entry.specListTimeout = (entry.specListTimeout or 0) + dt
            if entry.specListTimeout >= NS.WHISPER_SILENCE then
                CB_FinalizeSpecList(key, entry)
            end
        end

        if entry.awaitingQuests then
            entry.questTimeout = (entry.questTimeout or 0) + dt
            if entry.questTimeout >= NS.WHISPER_SILENCE then
                CB_FinalizeQuestCollection(key, entry)
            end
        end

        if entry.awaitingInventory then
            entry.invTimeout = (entry.invTimeout or 0) + dt
            if entry.invTimeout >= NS.WHISPER_SILENCE then
                entry.awaitingInventory = false
                entry.invTimeout        = 0

                -- Whisper path only (marked by invStaging): atomically swap the
                -- freshly-staged items in (replacing the preserved stale set) so
                -- a refresh updates cleanly, then fetch money/bag separately so
                -- its reply arrives on its own and isn't swallowed here.
                -- On the bridge path invStaging is nil and INV_END has normally
                -- already rendered; this branch is just a safety-net flag clear.
                -- Only swap when the reply actually arrived: a lost/late reply times
                -- out with empty staging, and overwriting would wipe a good list.
                if entry.invStaging then
                    if entry.invReplyArrived and entry.inventory then
                        entry.inventory.items = entry.invStaging
                        entry.inventoryAt     = GetTime()
                        -- Inventory just changed (e.g. Sell Trash) — force past the TTL so the
                        -- bag/money totals reflect the new state (in-flight dedup still applies).
                        NS.CB_FetchStats(entry, true)
                    end
                    entry.invStaging      = nil
                    entry.invReplyArrived = nil
                    entry.curItemSection  = nil
                end

                local f = NS.botInventoryFrames and NS.botInventoryFrames[key]
                if f and f:IsShown() then
                    NS.CB_RenderInventory(key)
                elseif f and NS.CB_SetInventoryLoading then
                    NS.CB_SetInventoryLoading(f, false)
                end
            end
        end

        if entry.awaitingBank and entry.bankStaging then
            entry.bankTimeout = (entry.bankTimeout or 0) + dt
            if entry.bankTimeout >= NS.WHISPER_SILENCE then
                entry.awaitingBank = false
                entry.bankTimeout  = 0

                -- Whisper-only (bankStaging marker): swap the freshly-staged bank items
                -- in atomically, replacing the preserved stale set so a refresh updates
                -- cleanly. No money/bag fetch — the bank reply carries no summary.
                -- Only swap when the reply actually arrived (else keep the stale list,
                -- so a lost/late reply doesn't wipe the bank to empty).
                if entry.bankReplyArrived and entry.bank then
                    entry.bank.items = entry.bankStaging
                end
                entry.bankStaging      = nil
                entry.bankReplyArrived = nil
                entry.curItemSection   = nil

                local f = NS.botBankFrames and NS.botBankFrames[key]
                if f and f:IsShown() then
                    NS.CB_RenderBank(key)
                elseif f and NS.CB_SetInventoryLoading then
                    NS.CB_SetInventoryLoading(f, false)
                end
            end
        end

        if entry.awaitingMoney then
            entry.moneyTimeout = (entry.moneyTimeout or 0) + dt
            if entry.moneyTimeout >= NS.QUERY_TIMEOUT then
                entry.awaitingMoney  = false
                entry.moneyTimeout   = 0
            end
        end

        if entry.awaitingFormation then
            entry.formationTimeout = (entry.formationTimeout or 0) + dt
            if entry.formationTimeout >= NS.QUERY_TIMEOUT then
                entry.awaitingFormation = false
                entry.formationTimeout  = 0
            end
        end

        if entry.awaitingLootStrategy then
            entry.lootStrategyTimeout = (entry.lootStrategyTimeout or 0) + dt
            if entry.lootStrategyTimeout >= NS.QUERY_TIMEOUT then
                entry.awaitingLootStrategy = false
                entry.lootStrategyTimeout  = 0
            end
        end

        if entry.awaitingSpellbook then
            entry.spellbookTimeout = (entry.spellbookTimeout or 0) + dt
            if entry.spellbookTimeout >= NS.QUERY_TIMEOUT then
                entry.awaitingSpellbook = false
                entry.spellbookTimeout  = 0
                local f = NS.botSpellbookFrames and NS.botSpellbookFrames[key]
                if f and f:IsShown() and NS.CB_RenderSpellbook then
                    NS.CB_RenderSpellbook(key)
                end
            end
        end

        if entry.awaitingProfessions then
            entry.professionsTimeout = (entry.professionsTimeout or 0) + dt
            if entry.professionsTimeout >= NS.QUERY_TIMEOUT then
                entry.awaitingProfessions = false
                entry.professionsTimeout  = 0
            end
        end

        -- Deposit/withdraw ("bank <link>") completion: arms the no-banker popup for the op
        -- window; cleared after silence (timer reset on each whisper from this bot, below).
        if entry.awaitingBankOp then
            entry.bankOpTimeout = (entry.bankOpTimeout or 0) + dt
            if entry.bankOpTimeout >= NS.WHISPER_SILENCE then
                entry.awaitingBankOp = false
                entry.bankOpTimeout  = 0
            end
        end

        -- Serial-queue completion: the in-flight request is done once the bot's reply stream
        -- goes silent. Runs AFTER the typed finalizes above (which parse/render this reply),
        -- so the next request is sent only once the current one is fully handled.
        if entry.wqBusy then
            entry.wqTimeout = (entry.wqTimeout or 0) + dt
            if entry.wqTimeout >= NS.WHISPER_SILENCE then
                entry.wqBusy = false
            end
        end

        -- Drain the serial whisper queue as the bot returns to idle.
        if entry.reqQueue and #entry.reqQueue > 0 and not entry.wqBusy then
            CB_PumpQueue(key)
        end
    end

    -- Safety net for in-flight Bridge bank requests (clears overlay on network drop/timeout)
    if NS.pendingBankRequests then
        local now = GetTime()
        for token, req in pairs(NS.pendingBankRequests) do
            if now >= req.expires then
                NS.pendingBankRequests[token] = nil
                local entry = CleanBot_PartyBots[req.key]
                if entry and entry.awaitingBank and not entry.bankStaging then
                    entry.awaitingBank = false
                    local bf = NS.botBankFrames and NS.botBankFrames[req.key]
                    if bf and NS.CB_SetInventoryLoading then
                        NS.CB_SetInventoryLoading(bf, false)
                    end
                end
            end
        end
    end

    -- Safety net for in-flight Bridge spec list requests (clears fetching flag on timeout)
    if NS.pendingSpecListRequests then
        local now = GetTime()
        for token, req in pairs(NS.pendingSpecListRequests) do
            if now >= req.expires then
                NS.pendingSpecListRequests[token] = nil
                if req.class then
                    NS.premadeSpecsFetching[req.class] = nil
                end
            end
        end
    end

    -- Safety net for in-flight Bridge recipe list requests (clears pending request on timeout)
    if NS.pendingRecipeRequests then
        local now = GetTime()
        for token, req in pairs(NS.pendingRecipeRequests) do
            if now >= (req.expires or 0) then
                NS.pendingRecipeRequests[token] = nil
            end
        end
    end

    -- Safety net for in-flight Bridge craft requests (clears pending request on timeout)
    if NS.craftPending then
        local now = GetTime()
        for token, req in pairs(NS.craftPending) do
            if now - (req.sentAt or 0) >= (NS.QUERY_TIMEOUT or 10.0) then
                NS.craftPending[token] = nil
                if req.callback then
                    req.callback(false, "TIMEOUT", req.itemId)
                end
            end
        end
    end

    -- Safety net for in-flight Bridge craft target requests (clears pending request on timeout)
    if NS.craftTargetPending then
        local now = GetTime()
        for token, req in pairs(NS.craftTargetPending) do
            if now - (req.sentAt or 0) >= (NS.QUERY_TIMEOUT or 10.0) then
                NS.craftTargetPending[token] = nil
                if req.callback then
                    req.callback(false, "TIMEOUT", req.targetItemId)
                end
            end
        end
    end

    -- Safety net for in-flight Bridge formations query (clears flags on network drop/timeout)
    if NS.formationsPending then
        NS.formationsTimeout = (NS.formationsTimeout or 0) + dt
        if NS.formationsTimeout >= NS.QUERY_TIMEOUT then
            NS.formationsPending = false
            NS.formationsTimeout = 0
            NS.formationsToken   = nil
            for _, e in pairs(CleanBot_PartyBots) do
                if e.awaitingFormation then
                    e.awaitingFormation = false
                    e.formationTimeout  = 0
                end
            end
        end
    end
end)

NS.pendingBankRequests = NS.pendingBankRequests or {}

local bankSeq = 0
local function CB_NextBankToken(prefix)
    bankSeq = (bankSeq or 0) + 1
    return tostring(math.floor(GetTime() * 1000)) .. "-" .. (prefix or "bank") .. "-" .. tostring(bankSeq)
end

local invSeq = 0
local function CB_NextInvToken(prefix)
    invSeq = (invSeq or 0) + 1
    return tostring(math.floor(GetTime() * 1000)) .. "-" .. (prefix or "inv") .. "-" .. tostring(invSeq)
end

local recSeq = 0
local function CB_NextRecToken(prefix)
    recSeq = (recSeq or 0) + 1
    return tostring(math.floor(GetTime() * 1000)) .. "-" .. (prefix or "rec") .. "-" .. tostring(recSeq)
end

NS.CB_FetchProfessions = function(key, botName, force)
    if not key then return end
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    local now = GetTime()
    if not force then
        if entry.professionsAt and (now - entry.professionsAt) < (NS.PROFESSIONS_TTL or 30.0) then
            return
        end
        if entry.awaitingProfessions and (entry.professionsTimeout or 0) < (NS.QUERY_TIMEOUT or 10.0) then
            return
        end
    end
    local bName = (entry and entry.name) or botName or key
    entry.awaitingProfessions = true
    entry.professionsTimeout  = 0
    CB_SendBridge(string.format("GET~PROFESSION~%s", bName))
end

NS.CB_FetchProfessionRecipes = function(key, botName, skillId, force)
    if not key or not skillId then return end
    local sId = tonumber(skillId)
    if not sId or sId <= 0 then return end
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    entry.professionRecipes = entry.professionRecipes or {}
    local cached = entry.professionRecipes[sId]
    local now = GetTime()
    if not force and cached and cached.recipes and (now - (cached.timestamp or 0)) < (NS.PROFESSIONS_TTL or 30.0) then
        if NS.CB_OnProfessionRecipesLoaded then
            NS.CB_OnProfessionRecipesLoaded(key, sId, cached.recipes)
        end
        return
    end

    local bName = (entry and entry.name) or botName or key
    local token = CB_NextRecToken("rec")
    NS.pendingRecipeRequests = NS.pendingRecipeRequests or {}
    NS.pendingRecipeRequests[token] = {
        botKey    = key,
        botName   = bName,
        skillId   = sId,
        expires   = now + (NS.QUERY_TIMEOUT or 10.0),
        staging   = {},
    }
    CB_SendBridge(string.format("GET~PROFESSION_RECIPES~%s~%d~%s", bName, sId, token))
end

local craftSeq = 0
local function CB_NextCraftToken(prefix)
    craftSeq = (craftSeq or 0) + 1
    return tostring(math.floor(GetTime() * 1000)) .. "-" .. (prefix or "crf") .. "-" .. tostring(craftSeq)
end

--- Orders a bot to craft a profession recipe via Bridge (RUN~CRAFT_RECIPE~<botName>~<token>~<skillId>~<spellId>~<itemId>).
---@param key      string Bot name-key.
---@param botName  string Bot display name.
---@param skillId  number Skill line ID (e.g. 202 for Engineering).
---@param spellId  number Recipe spell ID.
---@param itemId   number Expected created item ID (or 0).
---@param callback function? Optional completion callback: function(success: boolean, reason: string, actualItemId: number).
---@return boolean true if sent, false otherwise.
NS.CB_BridgeCraftRecipe = function(key, botName, skillId, spellId, itemId, callback)
    if not key or not skillId or not spellId then return false end
    local sId = tonumber(skillId)
    local spId = tonumber(spellId)
    local itId = tonumber(itemId) or 0
    if not sId or sId <= 0 or not spId or spId <= 0 then return false end

    if CB_EffectiveBridgeState() ~= "present" then
        return false
    end

    local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
    local bName = (entry and entry.name) or botName or key
    local token = CB_NextCraftToken("crf")

    NS.craftPending = NS.craftPending or {}
    NS.craftPending[token] = {
        botKey   = key,
        botName  = bName,
        skillId  = sId,
        spellId  = spId,
        itemId   = itId,
        callback = callback,
        sentAt   = GetTime(),
    }

    CB_SendBridge(string.format("RUN~CRAFT_RECIPE~%s~%s~%d~%d~%d", bName, token, sId, spId, itId))
    return true
end

--- Orders a bot to cast a target-based recipe (e.g. Enchanting) via Bridge (RUN~CRAFT_RECIPE_TARGET~<token>~<botName>~<skillId>~<spellId>~<targetBag>~<targetSlot>~<targetItemId>).
---@param key          string Bot name-key.
---@param botName      string Bot display name.
---@param skillId      number Skill line ID (e.g. 333 for Enchanting).
---@param spellId      number Recipe spell ID.
---@param targetBag    number Target item bag (255 for equipped or backpack).
---@param targetSlot   number Target item slot (0..18 for equipped, 0-indexed).
---@param targetItemId number Target item entry ID.
---@param callback     function? Optional completion callback: function(success: boolean, reason: string, targetItemId: number).
---@return boolean true if sent, false otherwise.
NS.CB_BridgeCraftRecipeTarget = function(key, botName, skillId, spellId, targetBag, targetSlot, targetItemId, callback)
    if not key or not skillId or not spellId or targetSlot == nil or not targetItemId then return false end
    local sId = tonumber(skillId)
    local spId = tonumber(spellId)
    local tBag = tonumber(targetBag) or 255
    local tSlot = tonumber(targetSlot)
    local tItemId = tonumber(targetItemId)
    if not sId or sId <= 0 or not spId or spId <= 0 or not tSlot or tSlot < 0 or not tItemId or tItemId <= 0 then return false end

    if CB_EffectiveBridgeState() ~= "present" then
        return false
    end

    local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
    local bName = (entry and entry.name) or botName or key
    local token = CB_NextCraftToken("crt")

    NS.craftTargetPending = NS.craftTargetPending or {}
    NS.craftTargetPending[token] = {
        botKey       = key,
        botName      = bName,
        skillId      = sId,
        spellId      = spId,
        targetBag    = tBag,
        targetSlot   = tSlot,
        targetItemId = tItemId,
        callback     = callback,
        sentAt       = GetTime(),
    }

    CB_SendBridge(string.format("RUN~CRAFT_RECIPE_TARGET~%s~%s~%d~%d~%d~%d~%d", token, bName, sId, spId, tBag, tSlot, tItemId))
    return true
end

-- Performs the actual inventory fetch (sets the busy flag + sends). Runs from the serial
-- queue so it never overlaps another reply stream. Bridge path is instant; whisper path
-- streams the "items" reply, collected via invStaging and finalized on silence.
---@param key     string  Bot name-key (lowercased lookup key).
---@param botName string  Bot's display name (whisper/bridge target).
---@param manual  boolean? If true, forces the "Refreshing..." loading overlay (manual button click).
local function CB_DoFetchInventory(key, botName, manual)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    -- Preserve existing inventory while the fresh fetch is in flight so the
    -- frame can display stale-but-correct data instead of going blank.
    entry.inventory = entry.inventory or { items = {} }

    local useBridge = CB_EffectiveBridgeState() == "present"

    -- In-flight flag drives the loading overlay AND the interaction lock; cleared in
    -- CB_RenderInventory when data lands (or by the silence-timeout tick as a safety net).
    entry.awaitingInventory = true
    entry.invTimeout        = 0
    entry.curItemSection    = nil    -- reset header-routed staging for the new collection
    entry.invReplyArrived   = false  -- set true when the reply (header/item) actually lands

    -- Overlay policy: always for a first (empty) load or manual refresh button click, but
    -- for background auto-reconciles of an already-rendered grid only on the whisper path.
    local invF = NS.botInventoryFrames and NS.botInventoryFrames[key]
    entry.invOverlay = (manual == true) or (not (invF and invF.rendered)) or not useBridge
    if invF and invF:IsShown() and entry.invOverlay and NS.CB_SetInventoryLoading then
        NS.CB_SetInventoryLoading(invF, true)
    end

    if useBridge then
        if NS.capabilities and NS.capabilities["INVENTORY_EXACT_V1"] then
            local token = CB_NextInvToken("exinv")
            CB_SendBridge("GET~INVENTORY_EXACT~" .. botName .. "~" .. token)
        else
            CB_SendBridge("GET~INVENTORY~" .. botName .. "~inv")
        end
    else
        -- invStaging is the whisper-path marker: its presence tells the tick to run the
        -- whisper finalize (swap + stats fetch). Fresh replies are collected here and only
        -- swapped into entry.inventory.items atomically once collection completes.
        -- Raw send: this already runs from the queue (CB_FetchInventory enqueued it).
        entry.invStaging = {}
        CB_SendBotCommandRaw(botName, "items")
    end
end

-- Enqueues an inventory fetch onto the bot's serial whisper queue (see CB_EnqueueRequest).
---@param key     string  Bot name-key (lowercased lookup key).
---@param botName string  Bot's display name (whisper/bridge target).
---@param manual  boolean? If true, forces the "Refreshing..." loading overlay (manual button click).
NS.CB_FetchInventory = function(key, botName, manual)
    NS.CB_EnqueueRequest(key, function() CB_DoFetchInventory(key, botName, manual) end)
end

-- How long a fetched "stats" reply is considered fresh. Re-selecting a bot within this
-- window reuses the cached money/XP/durability instead of re-whispering; older revisits
-- refetch so the values stay reasonably current.
NS.STATS_TTL = 30  -- seconds
NS.INVENTORY_TTL = 30  -- seconds

-- Fetches a bot's "stats" reply (money, bag totals, durability, XP). The reply is
-- parsed in the awaitingMoney branch of CHAT_MSG_WHISPER (below). "stats" is a query,
-- so it always whispers (never allowlisted) and the reply returns via CHAT_MSG_WHISPER
-- regardless of CB_EffectiveBridgeState() — no override gating needed. This is the
-- single source of truth for the "stats" whisper: the inventory-finalize tick and the
-- on-demand XP-bar fetch both route through here.
--
-- Two guards keep this from spamming a bot (mirrors CB_FetchSpecList's guard pattern):
--   • in-flight dedup — never stack a second "stats" while one is awaiting a reply, so the
--     post-login RefreshTabs→SelectBot burst can't hammer the first bot once per frame.
--   • TTL freshness — skip the refetch when the cached reply is younger than STATS_TTL,
--     so re-selecting a recently-viewed bot reuses the cache. Pass force=true to bypass
--     the TTL (e.g. after an inventory change that may have altered bag/money); the
--     in-flight dedup still applies.
---@param entry table   The CleanBot_PartyBots entry to refresh.
---@param force boolean? Bypass the TTL freshness check (still respects in-flight dedup).
NS.CB_FetchStats = function(entry, force)
    if not entry or not entry.name then return end
    if entry.awaitingMoney then return end
    if not force and entry.statsAt and (GetTime() - entry.statsAt) < NS.STATS_TTL then
        return
    end
    -- Mark in-flight immediately before enqueuing so concurrent callers bounce
    -- rather than stacking duplicate whispers in reqQueue while wqBusy is held.
    entry.awaitingMoney = true
    entry.moneyTimeout  = 0

    if CB_EffectiveBridgeState() == "present" then
        CB_SendBridge("GET~STATS~" .. entry.name)
        return
    end

    -- Enqueue so the "stats" reply doesn't overlap an items/bank stream.
    NS.CB_EnqueueRequest(strlower(entry.name), function()
        CB_MarkExpectReply(entry.name)
        CB_TagSelfWhisper(entry.name, "stats")
        SendChatMessage("stats", "WHISPER", nil, entry.name)
    end)
end

local formSeq = 0
local function CB_NextFormToken(prefix)
    formSeq = (formSeq or 0) + 1
    return tostring(math.floor(GetTime() * 1000)) .. "-" .. (prefix or "forms") .. "-" .. tostring(formSeq)
end

--- Queries movement formations for all bots in the group via Bridge (GET~FORMATIONS~GROUP~~<token>).
---@param force boolean? Re-query even if a query is already in flight.
NS.CB_FetchFormationsBridge = function(force)
    if CB_EffectiveBridgeState() ~= "present" then return end
    if NS.formationsPending and not force then return end

    local token = CB_NextFormToken("forms")
    NS.formationsPending = true
    NS.formationsTimeout = 0
    NS.formationsToken   = token

    for _, e in pairs(CleanBot_PartyBots) do
        e.awaitingFormation = true
        e.formationTimeout  = 0
    end

    CB_SendBridge("GET~FORMATIONS~GROUP~~" .. token)
end

--- Sets movement formation for the whole group via Bridge (RUN~FORMATION~GROUP~~<token>~<formation>).
---@param lowerForm string  Lowercase formation token (must be in BRIDGE_FORMATIONS).
NS.CB_BridgeSetGroupFormation = function(lowerForm)
    if not lowerForm or not BRIDGE_FORMATIONS[lowerForm] then return end
    local token = CB_NextFormToken("setform")
    CB_SendBridge("RUN~FORMATION~GROUP~~" .. token .. "~" .. lowerForm)

    -- Optimistic cache for all known group members
    for _, e in pairs(CleanBot_PartyBots) do
        e.formation = lowerForm
    end
    if NS.CB_RefreshCommands then NS.CB_RefreshCommands() end
end

-- Queries a bot's current movement formation ("formation ?"). The reply
-- ("Formation: <name>") is parsed in the CHAT_MSG_WHISPER handler into entry.formation.
-- When bridge is present, dispatches GET~FORMATIONS~GROUP to fetch all bots silently.
-- When bridge is absent, whispers "formation ?" to the specific bot.
-- Cached: skips when entry.formation is already known or a query is in flight unless `force` is set.
-- Routes through CB_SendBotCommand so it serializes and the reply is hidden.
---@param entry table   The CleanBot_PartyBots entry to query.
---@param force boolean? Re-query even when a formation is already cached.
NS.CB_FetchFormation = function(entry, force)
    if not entry or not entry.name then return end
    if CB_EffectiveBridgeState() == "present" then
        if (entry.formation and not force) or NS.formationsPending then return end
        NS.CB_FetchFormationsBridge(force)
        return
    end

    if (entry.formation and not force) or entry.awaitingFormation then return end
    entry.awaitingFormation = true
    entry.formationTimeout  = 0
    NS.CB_SendBotCommand(entry.name, "formation ?")
end

-- Queries a bot's current loot-quality strategy ("ll ?"). The reply
-- ("Loot strategy: <mode>") is parsed in the CHAT_MSG_WHISPER handler into entry.lootStrategy.
-- Cached: skips when entry.lootStrategy is already known or a query is in flight unless `force` is set.
-- Routes through CB_SendBotCommand so it serializes and the reply is hidden (same as CB_FetchFormation).
---@param entry table   The CleanBot_PartyBots entry to query.
---@param force boolean? Re-query even when a loot strategy is already cached.
NS.CB_FetchLootStrategy = function(entry, force)
    if not entry or not entry.name then return end
    if (entry.lootStrategy and not force) or entry.awaitingLootStrategy then return end
    entry.awaitingLootStrategy = true
    entry.lootStrategyTimeout  = 0
    NS.CB_SendBotCommand(entry.name, "ll ?")
end

-- Fetches a bot's bank contents. List via GET~BANK when bridge is present, otherwise whisper "bank", and the
-- whisper reply (header "=== Bank ===" then item lines) is collected via the header-routed
-- staging branch in CHAT_MSG_WHISPER and finalized by the silence tick. The reply
-- carries no money/slot summary, so there is no stats fetch. Needs a banker NPC near
-- the bot; otherwise the bot replies "Cannot find banker nearby" (handled as a popup).
-- Performs the actual bank fetch (sets the busy flag + sends "bank"). Runs from the serial
-- queue so the multi-line reply never overlaps another stream.
---@param key     string  Bot name-key (lowercased lookup key).
---@param botName string  Bot's display name (whisper target).
---@param manual  boolean? If true, forces the "Refreshing..." loading overlay (manual button click).
local function CB_DoFetchBank(key, botName, manual)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    -- Preserve existing bank items while the fresh fetch is in flight (stale display).
    entry.bank            = entry.bank or { items = {} }
    entry.awaitingBank    = true
    entry.bankTimeout     = 0
    entry.curItemSection  = nil
    entry.bankReplyArrived = false  -- set true when the reply (header/item) actually lands

    local useBridge = CB_EffectiveBridgeState() == "present"
    local bankF = NS.botBankFrames and NS.botBankFrames[key]
    entry.bankOverlay = (manual == true) or (not (bankF and bankF.rendered)) or not useBridge
    if bankF and bankF:IsShown() and entry.bankOverlay and NS.CB_SetInventoryLoading then
        NS.CB_SetInventoryLoading(bankF, true)
    end

    if useBridge then
        local token = CB_NextBankToken("bank")
        NS.pendingBankRequests[token] = {
            key = key,
            botName = botName,
            items = {},
            expires = GetTime() + 2.5,
            failed = false,
        }
        CB_SendBridge("GET~BANK~" .. botName .. "~" .. token)
    else
        -- bankStaging is the whisper-path marker the silence tick keys off to finalize.
        -- Raw send: this already runs from the queue (CB_FetchBank enqueued it).
        entry.bankStaging = {}
        CB_SendBotCommandRaw(botName, "bank")
    end
end

-- Enqueues a bank fetch onto the bot's serial whisper queue (see CB_EnqueueRequest).
---@param key     string  Bot name-key (lowercased lookup key).
---@param botName string  Bot's display name (whisper target).
---@param manual  boolean? If true, forces the "Refreshing..." loading overlay (manual button click).
NS.CB_FetchBank = function(key, botName, manual)
    NS.CB_EnqueueRequest(key, function() CB_DoFetchBank(key, botName, manual) end)
end

-- Debounced post-action reconcile. A burst of optimistic item moves (deposit/withdraw,
-- use, sell) bumps a per-entry token; the actual refetch fires once the user stops (token
-- still current) and only for the currently-open frames. The eager optimistic display
-- carries the UI in the meantime, and the refetch is enqueued so it is serialized behind
-- the move commands (no interleaving). Coalescing avoids one slow round-trip per move.
NS.RECONCILE_DELAY = 1.0
---@param key     string  Bot name-key.
---@param botName string  Bot's display name (fetch target).
NS.CB_ScheduleReconcile = function(key, botName)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    entry.reconcileGen = (entry.reconcileGen or 0) + 1
    local gen = entry.reconcileGen
    NS.CB_After(NS.RECONCILE_DELAY, function()
        local e = CleanBot_PartyBots[key]
        if not e or e.reconcileGen ~= gen then return end  -- superseded by a newer action
        local invF  = NS.botInventoryFrames and NS.botInventoryFrames[key]
        local bankF = NS.botBankFrames and NS.botBankFrames[key]
        -- Enqueued (not sent inline): the queue runs these after the move commands' replies
        -- complete, so the list query reflects the finished moves and never interleaves.
        if invF  and invF:IsShown()  then NS.CB_FetchInventory(key, botName) end
        if bankF and bankF:IsShown() then NS.CB_FetchBank(key, botName) end
    end)
end

-- Overheard inventory/bank/equip command (Overhear.lua) → re-sync any open window for that bot.
-- Reuses the coalesced reconcile (inventory + bank, each gated on its window being shown). For the
-- currently-viewed bot also refresh the equipment inspect, mirroring the UNIT_INVENTORY_CHANGED path.
NS.CB_On(NS.EV.BOT_INVENTORY_DIRTY, function(key)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end
    NS.CB_ScheduleReconcile(key, entry.name)
    if key == NS.selectedBotKey and NS.tabList and NS.CB_QueueEquipRefresh then
        for _, info in ipairs(NS.tabList) do
            if info.key == key and info.unit then
                NS.CB_QueueEquipRefresh({ { key = key, unit = info.unit } })
                break
            end
        end
    end
end)

---@param key     string        Bot name-key (lowercased lookup key).
---@param botName string        Bot's display name (whisper/bridge target).
---@param anchor  table|string? Placement forwarded to CB_ToggleInventory ("CENTER", a frame, or nil).
NS.CB_RequestInventory = function(key, botName, anchor)
    NS.CB_FetchInventory(key, botName)
    NS.CB_ToggleInventory(key, botName, anchor)
end

-- Vendor sell coin sound. Wrapped so specs can stub it (no PlaySound in tests).
NS.CB_PlaySellSound = function()
    if type(PlaySound) == "function" then PlaySound(120) end
end

-- Aggregated group-sell transaction: a single coin once every expected SELL_GREY
-- reply lands (or the timeout fires), and only if at least one bot sold anything.
NS.groupSellPending = nil
local groupSellGen = 0
local function CB_GroupSellFinalize(gen)
    local p = NS.groupSellPending
    if not p or p.gen ~= gen then return end
    NS.groupSellPending = nil
    if (p.soldTotal or 0) > 0 then
        if NS.CB_PlaySellSound then NS.CB_PlaySellSound() end
    end
end

-- Sells all gray items for a single bot. Uses INVENTORY_BULK_SELL_V1 when bridge is present,
-- whisper "s gray" only when bridge is absent.
---@param key     string Bot name-key.
---@param botName string Bot display name.
NS.bulkSellPending = NS.bulkSellPending or {}
NS.CB_BridgeBulkSell = function(key, botName)
    if CB_EffectiveBridgeState() == "present" then
        local token = CB_NextInvToken("bsell")
        NS.bulkSellPending[token] = true
        CB_SendBridge("RUN~ITEM_ACTION~" .. botName .. "~" .. token .. "~SELL_GREY~0~0")
    else
        NS.CB_SendBotCommand(botName, "s gray")
        NS.CB_ScheduleReconcile(key, botName)
    end
end

-- Sells all gray items for every bot in the group. Uses INVENTORY_BULK_SELL_V1 when bridge is present,
-- broadcasts "s gray" to the group only when bridge is absent.
NS.CB_BridgeGroupBulkSell = function()
    if CB_EffectiveBridgeState() == "present" then
        groupSellGen = groupSellGen + 1
        local pending = { gen = groupSellGen, expected = {}, received = 0, soldTotal = 0 }
        NS.groupSellPending = pending
        local function addBot(key, name)
            pending.expected[key] = true
            local token = CB_NextInvToken("gbsell")
            CB_SendBridge("RUN~ITEM_ACTION~" .. name .. "~" .. token .. "~SELL_GREY~0~0")
        end
        if NS.CB_ForEachGroupMember then
            NS.CB_ForEachGroupMember(function(_, name)
                local key = name and strlower(name)
                if key and CleanBot_PartyBots[key] then addBot(key, name) end
            end)
        else
            for key, entry in pairs(CleanBot_PartyBots) do
                if entry and entry.name then
                    addBot(key, entry.name)
                end
            end
        end
        local empty = true
        for _ in pairs(pending.expected) do empty = false; break end
        if empty then
            NS.groupSellPending = nil
            return
        end
        local gen = pending.gen
        NS.CB_After(4, function() CB_GroupSellFinalize(gen) end)
    else
        NS.CB_SendGroupCommand("s gray")
        if NS.CB_ForEachGroupMember and NS.CB_ScheduleReconcile then
            NS.CB_ForEachGroupMember(function(_, name)
                local key = name and strlower(name)
                if key and CleanBot_PartyBots[key] then NS.CB_ScheduleReconcile(key, name) end
            end)
        end
    end
end

-- Equips an item on a bot. Uses ITEM_EQUIP_V1 when bridge is present with exact bag/slot coordinates,
-- whisper "e <link>" only when bridge is absent.
---@param key     string Bot name-key.
---@param botName string Bot display name.
---@param link    string Item link.
---@param cell    table? Inventory cell (carries bag/slot if exact coordinates are available).
NS.CB_BridgeEquipItem = function(key, botName, link, cell)
    if CB_EffectiveBridgeState() == "present" then
        local hasExact = cell and cell.bag ~= nil and cell.slot ~= nil
        if hasExact then
            local itemId = cell.itemId or tonumber(strmatch(link or "", "item:(%d+)")) or 0
            local count = cell.count or 1
            local token = CB_NextInvToken("equip")
            CB_SendBridge("RUN~ITEM_EQUIP~" .. botName .. "~" .. token .. "~" .. tostring(cell.bag) .. "~" .. tostring(cell.slot) .. "~" .. tostring(itemId) .. "~" .. tostring(count))
            NS.CB_After(1.5, function()
                NS.CB_FetchInventory(key, botName)
                if key == NS.selectedBotKey and NS.tabList and NS.CB_QueueEquipRefresh then
                    for _, info in ipairs(NS.tabList) do
                        if info.key == key and info.unit then
                            NS.CB_QueueEquipRefresh({ { key = key, unit = info.unit } })
                            break
                        end
                    end
                end
            end)
        end
    else
        NS.CB_SendBotCommand(botName, "e " .. NS.CB_CleanItemLink(link))
        NS.CB_After(1.5, function()
            NS.CB_FetchInventory(key, botName)
            if key == NS.selectedBotKey and NS.tabList and NS.CB_QueueEquipRefresh then
                for _, info in ipairs(NS.tabList) do
                    if info.key == key and info.unit then
                        NS.CB_QueueEquipRefresh({ { key = key, unit = info.unit } })
                        break
                    end
                end
            end
        end)
    end
end

-- Uses an item (consumable). Uses ITEM_USE_V1 when bridge is present with exact bag/slot coordinates,
-- whisper "u <link>" only when bridge is absent.
---@param key     string Bot name-key.
---@param botName string Bot display name.
---@param link    string Item link.
---@param cell    table? Inventory cell (carries bag/slot if exact coordinates are available).
NS.CB_BridgeUseItem = function(key, botName, link, cell)
    if CB_EffectiveBridgeState() == "present" then
        local hasExact = cell and cell.bag ~= nil and cell.slot ~= nil
        if hasExact then
            local itemId = cell.itemId or tonumber(strmatch(link or "", "item:(%d+)")) or 0
            local count = cell.count or 1
            local token = CB_NextInvToken("use")
            CB_SendBridge("RUN~ITEM_USE~" .. botName .. "~" .. token .. "~" .. tostring(cell.bag) .. "~" .. tostring(cell.slot) .. "~" .. tostring(itemId) .. "~" .. tostring(count))
            NS.CB_ScheduleReconcile(key, botName)
            return true
        end
        return false
    else
        NS.CB_SendBotCommand(botName, "u " .. NS.CB_CleanItemLink(link))
        NS.CB_ScheduleReconcile(key, botName)
        return true
    end
end

-- Destroys an item. Uses ITEM_DESTROY_V1 when bridge is present with exact bag/slot coordinates,
-- whisper "destroy <link>" only when bridge is absent.
---@param key     string Bot name-key.
---@param botName string Bot display name.
---@param link    string Item link.
---@param cell    table? Inventory cell (carries bag/slot if exact coordinates are available).
NS.CB_BridgeDestroyItem = function(key, botName, link, cell)
    if CB_EffectiveBridgeState() == "present" then
        local hasExact = cell and cell.bag ~= nil and cell.slot ~= nil
        if hasExact then
            local itemId = cell.itemId or tonumber(strmatch(link or "", "item:(%d+)")) or 0
            local count = cell.count or 1
            local token = CB_NextInvToken("destroy")
            CB_SendBridge("RUN~ITEM_DESTROY~" .. botName .. "~" .. token .. "~" .. tostring(cell.bag) .. "~" .. tostring(cell.slot) .. "~" .. tostring(itemId) .. "~" .. tostring(count))
            NS.CB_ScheduleReconcile(key, botName)
            return true
        end
        return false
    else
        NS.CB_SendBotCommand(botName, "destroy " .. NS.CB_CleanItemLink(link))
        NS.CB_ScheduleReconcile(key, botName)
        return true
    end
end

-- Sells a single item at a vendor. Uses ITEM_SELL when bridge is present with exact bag/slot coordinates,
-- whisper "s <link>" only when bridge is absent.
---@param key     string Bot name-key.
---@param botName string Bot display name.
---@param link    string Item link.
---@param cell    table? Inventory cell (carries bag/slot if exact coordinates are available).
NS.CB_BridgeSellItem = function(key, botName, link, cell)
    if CB_EffectiveBridgeState() == "present" then
        local hasExact = cell and cell.bag ~= nil and cell.slot ~= nil
        if hasExact then
            local itemId = cell.itemId or tonumber(strmatch(link or "", "item:(%d+)")) or 0
            local count = cell.count or 1
            local token = CB_NextInvToken("sell")
            CB_SendBridge("RUN~ITEM_SELL~" .. botName .. "~" .. token .. "~" .. tostring(cell.bag) .. "~" .. tostring(cell.slot) .. "~" .. tostring(itemId) .. "~" .. tostring(count))
            NS.CB_ScheduleReconcile(key, botName)
            return true
        end
        return false
    else
        NS.CB_SendBotCommand(botName, "s " .. NS.CB_CleanItemLink(link))
        NS.CB_ScheduleReconcile(key, botName)
        return true
    end
end

-- Deposits an item to personal bank or guild bank via ITEM_DEPOSIT_EXACT_V1 when bridge is present with exact
-- bag/slot coordinates. Returns true if sent via Bridge, false otherwise;
-- whisper path is used only when bridge is absent.
---@param botName string  Bot's display name.
---@param action  string  "BANK_DEPOSIT" or "GBANK_DEPOSIT".
---@param cell    table?  Inventory cell button carrying exact coordinates.
---@return boolean sentViaBridge
NS.CB_BridgeDepositItem = function(botName, action, cell)
    if CB_EffectiveBridgeState() ~= "present" then return false end
    if not cell or cell.bag == nil or cell.slot == nil then return false end
    local itemId = cell.itemId or tonumber(strmatch(cell.itemLink or "", "item:(%d+)")) or 0
    if itemId <= 0 then return false end
    local count = cell.count or 1

    local token = CB_NextBankToken("dep")
    CB_SendBridge("RUN~ITEM_DEPOSIT_EXACT~" .. botName .. "~" .. token .. "~" .. action .. "~" .. tostring(cell.bag) .. "~" .. tostring(cell.slot) .. "~" .. tostring(itemId) .. "~" .. tostring(count))
    return true
end

-- Withdraws an item from personal bank to bags via ITEM_ACTION BANK_WITHDRAW, matched by
-- itemId + count (bank carries no slot coordinates). Uses bridge when present,
-- whisper "bank -<link>" only when bridge is absent.
---@param key     string Bot name-key.
---@param botName string Bot display name.
---@param link    string Item link.
---@param count   number? Stack count to withdraw.
---@return boolean sentViaBridge
NS.withdrawPending = NS.withdrawPending or {}
NS.CB_BridgeWithdrawItem = function(key, botName, link, count)
    if CB_EffectiveBridgeState() ~= "present" then return false end
    local itemId = tonumber(strmatch(link or "", "item:(%d+)")) or 0
    if itemId <= 0 then return false end

    local token = CB_NextInvToken("wdraw")
    NS.withdrawPending[token] = { key = key, botName = botName }
    CB_SendBridge("RUN~ITEM_ACTION~" .. botName .. "~" .. token .. "~BANK_WITHDRAW~" .. tostring(itemId) .. "~" .. tostring(count or 1))
    NS.CB_ScheduleReconcile(key, botName)
    return true
end

-- Fetches the quest log for a bot. Bridge path sends a structured GET~QUESTS
-- request; the QUESTS_BEGIN/ITEM/END packets are handled below in the
-- CHAT_MSG_ADDON block. Whisper "quests all" only when bridge is absent and parses the reply
-- lines in the CHAT_MSG_WHISPER handler into the same { {id, status, name} } shape.
-- The live entry.quests is intentionally NOT cleared here: the bridge path
-- resets it on QUESTS_BEGIN, and the whisper path swaps fresh data in on
-- finalize (CB_FinalizeQuestCollection) — so the last render survives on screen
-- until the new list is ready.
---@param key     string  Bot name-key (lowercased lookup key).
---@param botName string  Bot's display name (whisper/bridge target).
NS.CB_FetchQuests = function(key, botName)
    local entry = CleanBot_PartyBots[key]
    if not entry then return end

    if CB_EffectiveBridgeState() == "present" then
        CB_SendBridge("GET~QUESTS~ALL~" .. botName .. "~quests")
    else
        -- Whisper path: enqueue so the multi-line "quests all" reply is serialized; the typed
        -- flags are set at SEND time (the queued function) so the silence timer starts then.
        -- Lines are collected into staging keyed by section header (Incompleted/Completed) and
        -- swapped in on the summary line or after silence (invTickFrame).
        NS.CB_EnqueueRequest(key, function()
            entry.awaitingQuests    = true
            entry.questTimeout      = 0
            entry.questStatus       = "I"   -- current section; flipped by reply headers
            entry.questStaging      = {}
            entry.questReplyArrived = false
            -- "quests all" (not bare "quests", which only prints the summary) makes the
            -- bot stream the per-quest lines + section headers we parse — mirrors the
            -- bridge's GET~QUESTS~ALL mode.
            NS.CB_SendBotCommandRaw(botName, "quests all")
        end)
    end
end

-- ============================================================
-- Bridge handshake
-- ============================================================
local function CB_BridgeRequest()
    NS.CB_RequestSync()
end

local function CB_SendHello()
    -- CB_SendBridge picks the channel (group broadcast, or self-whisper when solo +
    -- selfBotActive), and no-ops when there is nothing to detect against.
    if NS.CB_InGroup() or NS.selfBotActive then
        CB_SendBridge("HELLO~1")
    end
end

-- Sends HELLO and, if no HELLO_ACK arrives within the timeout, declares the
-- bridge absent and switches to no-bridge (whisper) discovery. Only runs while
-- the bridge state is still unknown.
local function CB_StartBridgeDetection()
    if NS.bridgeState ~= "unknown" then return end
    if NS.bridgeDetecting then return end           -- a detection timer is already running
    -- Need either a group to detect against, or an active self-bot (which talks to the
    -- bridge over a self-whisper). Solo with no self-bot has nothing to detect.
    if not NS.CB_InGroup() and not NS.selfBotActive then return end
    NS.bridgeDetecting = true
    CB_SendHello()

    NS.CB_After(3, function()
        NS.bridgeDetecting  = false
        NS.loginPhaseActive = false   -- login gate lifted regardless of outcome
        if NS.bridgeState == "unknown" then
            NS.bridgeState = "absent"
            -- Keep the Debug tab's "Auto (<state>)" label current.
            if NS.CB_RefreshDebugTab then NS.CB_RefreshDebugTab() end

            -- Detection done with no bridge: run the probe sweep now that login gating is
            -- lifted. It probes every current member (flagging each as a joinCandidate), so a
            -- bot ready during detection is caught here; a not-yet-ready one is caught later by
            -- its readiness whisper.
            NS.CB_RequestSync()
        end
    end)
end

-- Exposed so the self-bot toggle can kick off detection the moment it's enabled
-- (the function is idempotent — guards on state / in-progress / nothing-to-detect).
NS.CB_StartBridgeDetection = CB_StartBridgeDetection

-- ============================================================
-- Bridge: listen for MBOT messages and party changes
-- ============================================================
local bridgeFrame = CreateFrame("Frame")
bridgeFrame:RegisterEvent("CHAT_MSG_ADDON")
bridgeFrame:RegisterEvent("CHAT_MSG_WHISPER")
bridgeFrame:RegisterEvent("CHAT_MSG_SYSTEM")
bridgeFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
bridgeFrame:RegisterEvent("RAID_ROSTER_UPDATE")
bridgeFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
bridgeFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
bridgeFrame:RegisterEvent("INSPECT_TALENT_READY")
bridgeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
bridgeFrame:RegisterEvent("PLAYER_LOGOUT")
bridgeFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_WHISPER" then
        local msg, sender = ...
        local key   = strlower(sender)
        local entry = CleanBot_PartyBots[key]

        -- Readiness detection (no-bridge): a bot announces itself once loaded by whispering the
        -- player. The greeting text varies across playerbots versions ("Hi", "Hi!", "Hello", …),
        -- so we trigger on the whisper itself, not its content. Group membership is checked LIVE
        -- here (not via a pre-set flag) so a greeting that arrives before our roster-change
        -- handler runs still triggers immediately, independent of event ordering.
        -- We probe on the FIRST unsolicited whisper from a current group member (not yet probed),
        -- OR re-probe a joinCandidate whose earlier sweep probe went unanswered while it loaded.
        -- Clearing the candidate bounds a chatty human to a single stray probe. Excludes a
        -- "Strategies:" line (the reply, handled below), known bots, and the fresh-login window.
        if not entry and not NS.loginPhaseActive
           and strsub(msg, 1, 12) ~= "Strategies: "
           and CB_EffectiveBridgeState() ~= "present"
           and (not NS.probed[key] or NS.joinCandidates[key]) then
            local inGroup = false
            NS.CB_ForEachGroupMember(function(unit, nm) if nm == sender then inGroup = true end end)
            if inGroup then
                NS.probed[key]         = true
                NS.awaitingProbe[key]  = true
                NS.joinCandidates[key] = nil
                NS.CB_SendBotCommand(sender, "co ?")
                return
            end
        end

        -- Keep the serial queue's silence timer (and a deposit/withdraw's op timer) alive while
        -- this bot's reply streams in, so the queue waits for the full reply before advancing.
        if entry and entry.wqBusy then entry.wqTimeout = 0 end
        if entry and entry.awaitingBankOp then entry.bankOpTimeout = 0 end

        -- No-banker error: a bank list/deposit/withdraw issued with no banker NPC near
        -- the bot. The chat filter hides this line from chat, but this handler still
        -- receives it (filters are display-only). Surface it as an explanatory popup.
        if entry and (entry.awaitingBank or entry.awaitingBankOp)
           and strfind(msg, "Cannot find banker nearby", 1, true) then
            entry.awaitingBank   = false
            entry.bankStaging    = nil
            entry.bankTimeout    = 0
            entry.awaitingBankOp = false
            entry.bankOpTimeout  = 0
            entry.curItemSection = nil
            local bf = NS.botBankFrames and NS.botBankFrames[key]
            if bf and NS.CB_SetInventoryLoading then NS.CB_SetInventoryLoading(bf, false) end
            StaticPopup_Show("CLEANBOT_NO_BANKER", entry.name)
            return
        end

        -- Guild-bank deposit failure ("guild bank <item>" from the inventory menu). The reply is
        -- hidden from chat by the reply-window filter, so surface the reason as a popup. Gated on
        -- entry (a managed bot), so a human whisper can't trip it. Success ("put to guild bank")
        -- falls through — hidden by the filter and ignored by parsing.
        if entry and (strfind(msg, "Cannot find the guild bank nearby", 1, true)
            or strfind(msg, "to guild bank. I have no rights", 1, true)
            or strfind(msg, "I'm not in your guild!", 1, true)) then
            StaticPopup_Show("CLEANBOT_NO_GUILD_BANK", entry.name)
            return
        end

        -- Spec-list collection: reply lines from "talents spec list", one premade
        -- per line, e.g. "1. arms pve (51-0-20)". Only actual spec lines are consumed
        -- (and reset the silence timeout); any other line falls through to the branches
        -- below. This matters because a "stats" fetch on the same select interleaves its
        -- reply ("… 92/150% XP") with the spec stream — if we returned on every line we
        -- would swallow that stats reply and the XP bar would never populate.
        -- Finalized by the silence tick in invTickFrame (CB_FinalizeSpecList).
        if entry and entry.awaitingSpecList then
            local name, t1, t2, t3 = msg:match("^%s*%d+%.%s+(.-)%s+%((%d+)%-(%d+)%-(%d+)%)%s*$")
            if name then
                entry.specListTimeout = 0
                if entry.specListStaging then
                    entry.specListStaging[#entry.specListStaging + 1] = {
                        name = name,
                        t    = { tonumber(t1), tonumber(t2), tonumber(t3) },
                    }
                end
                return
            end
        end

        -- Item collection (whisper path): inventory ("items") and bank ("bank") replies
        -- share the same item-line format, so they're separated by their section headers
        -- ("=== Inventory ===" / "=== Bank ==="). curItemSection tracks which collection
        -- the following |Hitem: lines belong to, so a concurrent inventory + bank fetch
        -- can't cross-contaminate. Gated on the *Staging markers (whisper-only) rather
        -- than the awaiting flags, so a bridge-path inventory fetch — which sets
        -- awaitingInventory but never sends "items" — doesn't swallow unrelated whispers.
        if entry and (entry.invStaging or entry.bankStaging) then
            -- A header (or any item line) means the reply actually arrived — recorded so
            -- the finalize can tell "bot reported empty" from "reply lost/late" and never
            -- wipe a good list on a timeout with empty staging.
            if strfind(msg, "=== Bank ===", 1, true) then
                entry.curItemSection = "bank";      entry.bankReplyArrived = true; entry.bankTimeout = 0; return
            elseif strfind(msg, "=== Inventory ===", 1, true) then
                entry.curItemSection = "inventory"; entry.invReplyArrived  = true; entry.invTimeout  = 0; return
            end

            if strfind(msg, "|Hitem:", 1, true) then
                local item = NS.CB_ParseItemLine and NS.CB_ParseItemLine(msg)
                if item then
                    if entry.curItemSection == "bank" and entry.bankStaging then
                        entry.bankStaging[#entry.bankStaging + 1] = item
                        entry.bankReplyArrived = true
                    elseif entry.invStaging then   -- inventory (default before any header)
                        entry.invStaging[#entry.invStaging + 1] = item
                        entry.invReplyArrived = true
                    end
                end
            end
            -- Reset whichever collection's silence timer this line belongs to.
            if entry.curItemSection == "bank" then entry.bankTimeout = 0
            else entry.invTimeout = 0 end
            return
        end

        -- Money/stats capture (whisper path): reply from "stats" whisper.
        -- The real reply is laced with WoW color/hyperlink escape codes, e.g.
        --   "2g 34s 56c, |h|cff20ff2012/16|h|cffffffff Bag, |cff...87% (5g 24s)|cffffffff Dur, |cff...45/67%|cffffffff XP"
        -- so we strip the |c / |h / |r escapes first, then parse the cleaned text.
        -- The bag count is FREE/TOTAL (not used/total); convert to used to match
        -- the bridge's INV_SUMMARY semantics (which reports used/total).
        -- Each money denomination is optional (e.g. a broke bot omits gold).
        -- Identify the stats reply by its CONTENT SIGNATURE — it always carries the
        -- "Bag" and "Dur" fields — rather than trusting the awaitingMoney flag alone.
        -- This is essential because other replies (e.g. talent spec-list lines) can
        -- interleave with the stats reply while awaitingMoney is still set; keying off
        -- the flag would mis-parse such a line and clear awaitingMoney prematurely.
        -- Signature matching also rescues a reply that arrives after the 0.5s
        -- WHISPER_SILENCE window has already cleared awaitingMoney (cold bot / slow
        -- round-trip) — otherwise the XP bar would never populate until a warm refetch.
        if entry and strfind(msg, "Bag", 1, true) and strfind(msg, "Dur", 1, true) then
            local clean = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|h", ""):gsub("|r", "")
            local xpCur, xpMax = clean:match("(%d+)/(%d+)%%%s*XP")
            if clean:match("%d+/%d+%s*Bag") then
                entry.moneyTimeout  = 0
                entry.awaitingMoney = false
                entry.statsAt       = GetTime()   -- mark fresh for the CB_FetchStats TTL

                -- Coins live before the Bag field; the repair cost inside "(…) Dur" is
                -- money-formatted too, so a missing denomination must not match it.
                local moneyPart = clean:match("^(.-)%d+/%d+%s*Bag") or ""
                local gold   = tonumber(moneyPart:match("(%d+)g")) or 0
                local silver = tonumber(moneyPart:match("(%d+)s")) or 0
                local copper = tonumber(moneyPart:match("(%d+)c")) or 0
                entry.money  = { gold = gold, silver = silver, copper = copper }

                -- Bag totals are not available from the "items" whisper, but stats gives them.
                local bagFree, bagTotal = clean:match("(%d+)/(%d+)%s*Bag")
                if bagFree and entry.inventory then
                    bagFree  = tonumber(bagFree)
                    bagTotal = tonumber(bagTotal)
                    entry.inventory.bagTotal = bagTotal
                    entry.inventory.bagUsed  = bagTotal - bagFree
                end

                -- Durability and XP are whisper-only — store for future display.
                -- Dur is "N% (repair cost) Dur"; XP is "cur/rest% XP".
                local durPct     = tonumber(clean:match("(%d+)%%%s*%(.-%)%s*Dur"))
                entry.durability = durPct
                entry.xpPercent  = xpCur and (tonumber(xpCur) .. "/" .. tonumber(xpMax)) or nil

                local f = NS.botInventoryFrames and NS.botInventoryFrames[strlower(sender)]
                if f and f:IsShown() then NS.CB_RenderInventory(strlower(sender)) end

                -- XP just landed — repaint the paperdoll XP bar if this bot is live.
                if NS.CB_RefreshXPBarForKey then NS.CB_RefreshXPBarForKey(strlower(sender)) end
                return
            end
        end

        -- Quest list collection (whisper path): reply to the "quests" command.
        -- The bot streams section headers (Incompleted/Completed) then one quest
        -- hyperlink per line, ending with a "--- Summary --- / Total:" line.
        -- Status comes from the active section; the quest ID from the |Hquest:ID:
        -- link. Collected into questStaging, swapped into entry.quests on finalize.
        if entry and entry.awaitingQuests then
            entry.questTimeout      = 0
            entry.questReplyArrived = true
            -- Quest lines carry a |Hquest:ID: link — match that FIRST so a quest
            -- whose title contains "Complete"/"Incomplete" isn't mistaken for a
            -- section header. Headers (no link) only set the current status.
            local id = tonumber(msg:match("|Hquest:(%d+):"))
            if id then
                entry.questStaging[#entry.questStaging + 1] = {
                    id     = id,
                    status = entry.questStatus,
                    name   = msg:match("%[(.-)%]"),   -- bracketed link title (see QUESTS_ITEM note)
                }
            elseif msg:find("Summary", 1, true) or msg:match("^%s*Total:") then
                CB_FinalizeQuestCollection(key, entry)
            elseif msg:find("Incomplet", 1, true) then
                entry.questStatus = "I"
            elseif msg:find("Complet", 1, true) then
                entry.questStatus = "C"
            end
            return
        end

        -- Current-formation reply: "formation ?" / no-arg answers "Formation: |cff00ff00<name>"
        -- (SetFormationAction → TellMaster). Strip color codes first so an initial color escape
        -- doesn't defeat the prefix match, cache the token, refresh the Commands-tab dropdowns.
        local cleanMsg = msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|h", ""):gsub("|r", "")
        if entry and cleanMsg:find("^%s*Formation:%s*") then
            entry.awaitingFormation = false
            entry.formationTimeout  = 0
            local name = cleanMsg:match("Formation:%s*(%a+)")
            if name then
                entry.formation = strlower(name)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key, { formation = true }) end
            end
            return
        end

        -- Current-loot-strategy reply: "ll ?" answers "Loot strategy: <mode>" (normal/gray/all/
        -- disenchant). Strip color codes first, cache the lowercase token, refresh the Loot Quality
        -- dropdowns that display it.
        if entry and cleanMsg:find("^%s*Loot strategy:%s*") then
            entry.awaitingLootStrategy = false
            entry.lootStrategyTimeout  = 0
            local mode = cleanMsg:match("Loot strategy:%s*(%a+)")
            if mode then
                entry.lootStrategy = strlower(mode)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key, { loot = true }) end
            end
            return
        end

        if strsub(msg, 1, 12) ~= "Strategies: " then return end

        if entry then
            -- Known bot: response to a co?/nc? read (no-bridge mode, or a manual re-read).
            if entry.awaitingCo then
                entry.awaitingCo = false
                entry.class = NS.CB_ResolveClass(sender, entry.class)
                NS.CB_StoreCombat(entry, msg)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end
                if entry.coVerifyOnly then
                    -- Combined "co +x,?" verify: consume only the combat reply.
                    entry.coVerifyOnly = nil
                else
                    entry.awaitingNc = true
                    NS.CB_SendBotCommand(entry.name, "nc ?")
                end
            elseif entry.awaitingNc then
                entry.awaitingNc = false
                NS.CB_StoreNonCombat(entry, msg)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end
            end

        elseif NS.awaitingProbe[key] then
            -- No-bridge discovery: a probed party member replied, so it IS a bot.
            NS.awaitingProbe[key]  = nil
            NS.joinCandidates[key] = nil   -- confirmed; no longer awaiting a readiness whisper
            local class = NS.CB_ResolveClass(sender, "WARRIOR")
            local existing = CleanBot_PartyBots[key]
            if existing then
                entry = existing
                entry.name       = sender
                entry.class      = class
                entry.classData  = entry.classData or NS.CB_DefaultClassData(class)
                entry.awaitingNc = true
            else
                entry = {
                    name       = sender,
                    class      = class,
                    combat     = NS.CB_DefaultCombat(),
                    nonCombat  = NS.CB_DefaultNonCombat(),
                    classData  = NS.CB_DefaultClassData(class),
                    awaitingNc = true,
                }
                CleanBot_PartyBots[key] = entry
            end
            NS.CB_StoreCombat(entry, msg)
            NS.CB_SendBotCommand(sender, "nc ?")
            if CleanBotFrame:IsShown() then NS.CleanBot_RefreshTabs() end
        end
        return

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg = ...
        if prefix ~= "MBOT" then return end

        if msg and strsub(msg, 1, 10) == "HELLO_ACK~" then
            -- HELLO_ACK drives the *real* state machine and is processed even when
            -- the override forces "absent", so /cbdebug bridge reset can restore the
            -- true state. CB_BridgeRequest below re-syncs via the effective path.
            NS.lastHelloAck = msg
            if not NS.bridgeReady then
                NS.bridgeReady      = true
                NS.bridgeState      = "present"
                NS.bridgeDetecting  = false
                NS.loginPhaseActive = false  -- bridge handles discovery; no whisper-probe gating needed
                NS.joinCandidates   = {}
                -- Keep the Debug tab's "Auto (<state>)" label current.
                if NS.CB_RefreshDebugTab then NS.CB_RefreshDebugTab() end
                CB_BridgeRequest()
                NS.CleanBot_FetchLinkedAccounts()
            end

        elseif msg and (msg == "CAPS_BEGIN" or strsub(msg, 1, 11) == "CAPS_BEGIN~") then
            NS.capabilities          = {}
            NS.stateFramingCapable   = false
            NS.capabilitiesResolved  = false
            NS.capabilityBatchActive = true

        elseif msg and strsub(msg, 1, 5) == "CAPS~" then
            local capsStr = strsub(msg, 6)
            for cap in gmatch(capsStr, "[^,]+") do
                cap = cap:match("^%s*(.-)%s*$")
                if cap ~= "" then
                    NS.capabilities[cap] = true
                    if cap == "STATE_FRAMING_V1" then
                        NS.stateFramingCapable = true
                    end
                end
            end
            if not NS.capabilityBatchActive then
                NS.capabilitiesResolved = true
            end

        elseif msg and (msg == "CAPS_END" or strsub(msg, 1, 9) == "CAPS_END~") then
            NS.capabilityBatchActive = false
            NS.capabilitiesResolved  = true

        elseif CB_EffectiveBridgeState() ~= "present" then
            -- Override forces the no-bridge path: ignore all inbound bridge data
            -- packets (ROSTER~/DETAIL~/STATE~/INV_*/QUESTS_*) so the cache is only
            -- ever populated via the whisper discovery path. Without this guard a
            -- real bridge would keep pushing strategy/inventory data and the
            -- "absent" simulation would be incomplete.
            return

        elseif msg and strsub(msg, 1, 7) == "ROSTER~" then
            -- One packet packs EVERY bot: "Name,classId,level,mapId,alive,hp,mana;Name2,…"
            -- (";"-separated records, ","-separated fields; classId = Player::getClass()).
            -- Seed each bot's identity + class here; DETAIL~/STATE~ fill in the rest.
            for record in gmatch(strsub(msg, 8), "[^;]+") do
                local name, r2  = NS.CB_SplitOnce(record, ",")
                local classId   = NS.CB_SplitOnce(r2, ",")
                if name ~= "" then
                    local key = strlower(name)
                    if not CleanBot_PartyBots[key] then
                        local class = CLASS_ID_TOKENS[tonumber(classId)] or "WARRIOR"
                        CleanBot_PartyBots[key] = {
                            name      = name,
                            class     = class,
                            combat    = NS.CB_DefaultCombat(),
                            nonCombat = NS.CB_DefaultNonCombat(),
                            classData = NS.CB_DefaultClassData(class),
                        }
                    end
                end
            end

        elseif msg and strsub(msg, 1, 7) == "DETAIL~" then
            local name, className = strmatch(msg, "^DETAIL~([^~]+)~[^~]+~[^~]+~([^~]+)~")
            if name and className then
                local classKey = strupper(className)
                classKey = gsub(classKey, "%s+", "")
                local key      = strlower(name)
                local existing = CleanBot_PartyBots[key]
                -- Bridge mode: strategy data arrives via GET~STATES (STATE~ packets),
                -- so DETAIL~ only establishes identity/class. Mutate existing entry in place
                -- to preserve cached formation, lootStrategy, statsAt, and in-flight request state.
                if existing then
                    existing.name      = name
                    existing.class     = classKey
                    existing.classData = existing.classData or NS.CB_DefaultClassData(classKey)
                else
                    CleanBot_PartyBots[key] = {
                        name      = name,
                        class     = classKey,
                        combat    = NS.CB_DefaultCombat(),
                        nonCombat = NS.CB_DefaultNonCombat(),
                        classData = NS.CB_DefaultClassData(classKey),
                    }
                end
            end

        -- ── Strategy framed packets (STATE_FRAMING_V1) ──────────────────────
        elseif msg and strsub(msg, 1, 13) == "STATES_BEGIN~" then
            local rest = strsub(msg, 14)
            local token, botCount = NS.CB_SplitOnce(rest, "~")
            local req = NS.stateRequests[token]
            if req and req.global then
                req.begun         = true
                req.expectedBots  = tonumber(botCount) or 0
                req.completedBots = 0
            end

        elseif msg and strsub(msg, 1, 12) == "STATE_BEGIN~" then
            local rest = strsub(msg, 13)
            local token, r2 = NS.CB_SplitOnce(rest, "~")
            local rawName, r3 = NS.CB_SplitOnce(r2, "~")
            local cCount, nCount = NS.CB_SplitOnce(r3, "~")
            local botName = CB_UrlDecode(rawName):match("^%s*(.-)%s*$")
            if botName and botName ~= "" then
                local botKey = strlower(botName)
                local txKey = token .. "~" .. botKey
                NS.stateActive[txKey] = {
                    token          = token,
                    botName        = botName,
                    botKey         = botKey,
                    combatExpected = tonumber(cCount) or 0,
                    normalExpected = tonumber(nCount) or 0,
                    combat         = {},
                    normal         = {},
                }
            end

        elseif msg and strsub(msg, 1, 11) == "STATE_ITEM~" then
            local rest = strsub(msg, 12)
            local token, r2 = NS.CB_SplitOnce(rest, "~")
            local rawName, r3 = NS.CB_SplitOnce(r2, "~")
            local scope, r4 = NS.CB_SplitOnce(r3, "~")
            local idxStr, rawStrategy = NS.CB_SplitOnce(r4, "~")
            local botName = CB_UrlDecode(rawName):match("^%s*(.-)%s*$")
            local botKey = strlower(botName)
            local txKey = token .. "~" .. botKey
            local tx = NS.stateActive[txKey]
            if tx then
                local index = tonumber(idxStr)
                local strategy = CB_UrlDecode(rawStrategy)
                if index then
                    scope = strupper(scope)
                    if scope == "C" then
                        tx.combat[index] = strategy
                    elseif scope == "N" then
                        tx.normal[index] = strategy
                    end
                end
            end

        elseif msg and strsub(msg, 1, 10) == "STATE_END~" then
            local rest = strsub(msg, 11)
            local token, r2 = NS.CB_SplitOnce(rest, "~")
            local rawName, r3 = NS.CB_SplitOnce(r2, "~")
            local botName = CB_UrlDecode(rawName):match("^%s*(.-)%s*$")
            local botKey = strlower(botName)
            local txKey = token .. "~" .. botKey
            local tx = NS.stateActive[txKey]
            if tx then
                local combatStr = table.concat(tx.combat, ", ")
                local ncStr     = table.concat(tx.normal, ", ")
                local entry     = CleanBot_PartyBots[botKey]
                if not entry then
                    local class = NS.CB_ResolveClass(botName, "WARRIOR")
                    entry = {
                        name      = botName,
                        class     = class,
                        combat    = NS.CB_DefaultCombat(),
                        nonCombat = NS.CB_DefaultNonCombat(),
                        classData = NS.CB_DefaultClassData(class),
                    }
                    CleanBot_PartyBots[botKey] = entry
                else
                    entry.class = NS.CB_ResolveClass(botName, entry.class)
                end
                NS.CB_StoreCombat(entry, combatStr)
                NS.CB_StoreNonCombat(entry, ncStr)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(botKey) end
                NS.stateActive[txKey] = nil
                local req = NS.stateRequests[token]
                if req and req.global then
                    req.completedBots = (req.completedBots or 0) + 1
                end
            end

        elseif msg and strsub(msg, 1, 11) == "STATES_END~" then
            local rest = strsub(msg, 12)
            local token = NS.CB_SplitOnce(rest, "~")
            CB_ClearStateRequest(token)
            if CleanBotFrame:IsShown() then
                NS.CleanBot_RefreshTabs()
            end

        elseif msg and strsub(msg, 1, 12) == "STATE_ABORT~" then
            local rest = strsub(msg, 13)
            local token = NS.CB_SplitOnce(rest, "~")
            CB_ClearStateRequest(token)

        -- ── Strategy legacy snapshot (fallback) ─────────────────────────────
        elseif msg and strsub(msg, 1, 6) == "STATE~" then
            -- Bridge strategy snapshot for one bot: STATE~Name~combat~nonCombat
            -- (combat / nonCombat are comma-separated strategy lists.)
            NS.lastRawStates = msg
            local rest             = strsub(msg, 7)
            local name, r2         = NS.CB_SplitOnce(rest, "~")
            local combatStr, ncStr = NS.CB_SplitOnce(r2,   "~")
            name = name:match("^%s*(.-)%s*$")
            if name and name ~= "" then
                local key   = strlower(name)
                local entry = CleanBot_PartyBots[key]
                if not entry then
                    -- STATE~ arrived before ROSTER~/DETAIL~; create a minimal entry.
                    local class = NS.CB_ResolveClass(name, "WARRIOR")
                    entry = {
                        name      = name,
                        class     = class,
                        combat    = NS.CB_DefaultCombat(),
                        nonCombat = NS.CB_DefaultNonCombat(),
                        classData = NS.CB_DefaultClassData(class),
                    }
                    CleanBot_PartyBots[key] = entry
                else
                    entry.class = NS.CB_ResolveClass(name, entry.class)
                end
                NS.CB_StoreCombat(entry, combatStr)
                NS.CB_StoreNonCombat(entry, ncStr)
                if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key) end
            end

        elseif msg and strsub(msg, 1, 10) == "INV_BEGIN~" then
            local rest = strsub(msg, 11)
            local name = NS.CB_SplitOnce(rest, "~")
            local key  = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.inventory = { items = {} }
            end

        elseif msg and strsub(msg, 1, 12) == "INV_SUMMARY~" then
            local rest              = strsub(msg, 13)
            local name, r2          = NS.CB_SplitOnce(rest, "~")
            local _, r3             = NS.CB_SplitOnce(r2,   "~")  -- skip token
            local gold, r4          = NS.CB_SplitOnce(r3,   "~")
            local silver, r5        = NS.CB_SplitOnce(r4,   "~")
            local copper, r6        = NS.CB_SplitOnce(r5,   "~")
            local bagUsed, bagTotal = NS.CB_SplitOnce(r6,   "~")
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                -- Money is a bot attribute, not an inventory item — stored separately
                -- so it can be displayed and accessed independently of the bag grid.
                entry.money = {
                    gold   = tonumber(gold)   or 0,
                    silver = tonumber(silver) or 0,
                    copper = tonumber(copper) or 0,
                }
                if entry.inventory then
                    entry.inventory.bagUsed  = tonumber(bagUsed)  or 0
                    entry.inventory.bagTotal = tonumber(bagTotal) or 0
                end
            end

        elseif msg and strsub(msg, 1, 6) == "STATS~" then
            local rest              = strsub(msg, 7)
            local rawName, r2       = NS.CB_SplitOnce(rest, "~")
            local level, r3         = NS.CB_SplitOnce(r2,   "~")
            local gold, r4          = NS.CB_SplitOnce(r3,   "~")
            local silver, r5        = NS.CB_SplitOnce(r4,   "~")
            local copper, r6        = NS.CB_SplitOnce(r5,   "~")
            local bagUsed, r7       = NS.CB_SplitOnce(r6,   "~")
            local bagTotal, r8      = NS.CB_SplitOnce(r7,   "~")
            local durPct, r9        = NS.CB_SplitOnce(r8,   "~")
            local xpPct, manaPct    = NS.CB_SplitOnce(r9,   "~")

            local botName = CB_UrlDecode(rawName):match("^%s*(.-)%s*$")
            local key     = strlower(botName)
            local entry   = CleanBot_PartyBots[key]
            if entry then
                entry.moneyTimeout  = 0
                entry.awaitingMoney = false
                entry.statsAt       = GetTime()

                if level and level ~= "" then
                    entry.level = tonumber(level) or entry.level
                end

                entry.money = {
                    gold   = tonumber(gold)   or 0,
                    silver = tonumber(silver) or 0,
                    copper = tonumber(copper) or 0,
                }

                entry.inventory = entry.inventory or {}
                entry.inventory.bagUsed  = tonumber(bagUsed)  or 0
                entry.inventory.bagTotal = tonumber(bagTotal) or 0

                entry.durability = tonumber(durPct) or 0
                entry.xpPercent  = xpPct and tostring(tonumber(xpPct) or 0) or nil
                entry.manaPct    = tonumber(manaPct) or 0

                local f = NS.botInventoryFrames and NS.botInventoryFrames[key]
                if f and f:IsShown() then
                    NS.CB_RenderInventory(key)
                end
                if NS.CB_RefreshXPBarForKey then
                    NS.CB_RefreshXPBarForKey(key)
                end
                if NS.CB_UpdateTabData then
                    NS.CB_UpdateTabData(key)
                end
            end

        elseif msg and strsub(msg, 1, 9) == "INV_ITEM~" then
            local rest      = strsub(msg, 10)
            local name, r2  = NS.CB_SplitOnce(rest, "~")
            local _, encoded = NS.CB_SplitOnce(r2,  "~")   -- skip token
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry and entry.inventory then
                local item = NS.CB_ParseItemLine and NS.CB_ParseItemLine(encoded)
                if item then
                    local items = entry.inventory.items
                    items[#items + 1] = item
                end
            end

        elseif msg and strsub(msg, 1, 8) == "INV_END~" then
            local rest = strsub(msg, 9)
            local name = NS.CB_SplitOnce(rest, "~")
            local key  = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.awaitingInventory = false
                entry.inventoryAt = GetTime()
            end
            local f    = NS.botInventoryFrames and NS.botInventoryFrames[key]
            if f and f:IsShown() then
                NS.CB_RenderInventory(key)
            elseif f and NS.CB_SetInventoryLoading then
                NS.CB_SetInventoryLoading(f, false)
            end

        -- ── Exact physical inventory packets (INVENTORY_EXACT_V1) ────────
        elseif msg and strsub(msg, 1, 16) == "INV_EXACT_BEGIN~" then
            local rest = strsub(msg, 17)
            local name = NS.CB_SplitOnce(rest, "~")
            local key  = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.inventory = entry.inventory or {}
                entry.inventory.items = {}
                entry.inventory.exactBagTotal = 0
            end

        elseif msg and strsub(msg, 1, 8) == "INV_BAG~" then
            -- INV_BAG~<botName>~<token>~<kind>~<bag>~<slotStart>~<slotCount>~<bagItemId>
            local rest = strsub(msg, 9)
            local name, r2 = NS.CB_SplitOnce(rest, "~")
            local _, r3 = NS.CB_SplitOnce(r2, "~")
            local kind, r4 = NS.CB_SplitOnce(r3, "~")
            local _, r5 = NS.CB_SplitOnce(r4, "~")
            local _, r6 = NS.CB_SplitOnce(r5, "~")
            local slotCount = NS.CB_SplitOnce(r6, "~")
            local key = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry and entry.inventory and (kind == "BACKPACK" or kind == "BAG") then
                local count = tonumber(slotCount) or 0
                entry.inventory.exactBagTotal = (entry.inventory.exactBagTotal or 0) + count
                entry.inventory.bagTotal = entry.inventory.exactBagTotal
            end

        elseif msg and strsub(msg, 1, 13) == "INV_ITEM_LOC~" then
            -- INV_ITEM_LOC~<botName>~<token>~<srcBag>~<srcSlot>~<itemId>~<count>~<isSoulbound>
            local rest = strsub(msg, 14)
            local name, r2 = NS.CB_SplitOnce(rest, "~")
            local _, r3 = NS.CB_SplitOnce(r2, "~")
            local srcBag, r4 = NS.CB_SplitOnce(r3, "~")
            local srcSlot, r5 = NS.CB_SplitOnce(r4, "~")
            local itemId, r6 = NS.CB_SplitOnce(r5, "~")
            local count, isSoulbound = NS.CB_SplitOnce(r6, "~")
            local key = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry and entry.inventory then
                local numId = tonumber(itemId) or 0
                local numCount = tonumber(count) or 1
                local numBag = tonumber(srcBag) or 0
                local numSlot = tonumber(srcSlot) or 0
                local itemName, link = GetItemInfo(numId)
                if not link then
                    link = "|cffffffff|Hitem:" .. numId .. ":0:0:0:0:0:0:0:0|h[" .. (itemName or ("Item " .. numId)) .. "]|h|r"
                end
                local items = entry.inventory.items
                items[#items + 1] = {
                    link = link,
                    count = numCount,
                    bag = numBag,
                    slot = numSlot,
                    itemId = numId,
                    soulbound = (isSoulbound == "1" or isSoulbound == "true"),
                }
            end

        elseif msg and strsub(msg, 1, 14) == "INV_EXACT_END~" then
            local rest = strsub(msg, 15)
            local name = NS.CB_SplitOnce(rest, "~")
            local key  = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.awaitingInventory = false
                entry.inventoryAt = GetTime()
                if entry.inventory then
                    entry.inventory.bagUsed = #entry.inventory.items
                end
            end
            local f = NS.botInventoryFrames and NS.botInventoryFrames[key]
            if f and f:IsShown() then
                NS.CB_RenderInventory(key)
            elseif f and NS.CB_SetInventoryLoading then
                NS.CB_SetInventoryLoading(f, false)
            end

        -- ── Formation packets (GET~FORMATIONS / RUN~FORMATION) ───────────
        elseif msg and strsub(msg, 1, 17) == "FORMATIONS_BEGIN~" then
            local rest = strsub(msg, 18)
            local token, count = NS.CB_SplitOnce(rest, "~")
            -- Initial frame marker; token validated on items/end

        elseif msg and strsub(msg, 1, 16) == "FORMATIONS_ITEM~" then
            -- FORMATIONS_ITEM~<token>~<encodedBotName>~<encodedFormation>
            local rest = strsub(msg, 17)
            local token, r2 = NS.CB_SplitOnce(rest, "~")
            local rawName, rawForm = NS.CB_SplitOnce(r2, "~")
            local botName = CB_UrlDecode(rawName):match("^%s*(.-)%s*$")
            local formName = CB_UrlDecode(rawForm):match("^%s*(.-)%s*$")
            if botName and botName ~= "" then
                local key = strlower(botName)
                local entry = CleanBot_PartyBots[key]
                if entry then
                    -- Unconditionally clear awaiting flags to prevent 10s hang on "?"
                    entry.awaitingFormation = false
                    entry.formationTimeout  = 0
                    if formName and formName ~= "" and formName ~= "?" then
                        entry.formation = strlower(formName)
                        if NS.CB_UpdateTabData then NS.CB_UpdateTabData(key, { formation = true }) end
                    end
                end
            end

        elseif msg and strsub(msg, 1, 15) == "FORMATIONS_END~" then
            local rest = strsub(msg, 16)
            local token, count = NS.CB_SplitOnce(rest, "~")
            NS.formationsPending = false
            NS.formationsTimeout = 0
            NS.formationsToken   = nil
            if NS.CB_RefreshCommands then NS.CB_RefreshCommands() end

        elseif msg and strsub(msg, 1, 14) == "FORMATION_ACK~" then
            -- FORMATION_ACK~<scope>~<target>~<token>~<succeeded>~<failed>~<formation>
            local rest = strsub(msg, 15)
            local scope, r2 = NS.CB_SplitOnce(rest, "~")
            local target, r3 = NS.CB_SplitOnce(r2, "~")
            local token, r4 = NS.CB_SplitOnce(r3, "~")
            local succeeded, r5 = NS.CB_SplitOnce(r4, "~")
            local failed, encForm = NS.CB_SplitOnce(r5, "~")
            local succCount = tonumber(succeeded) or 0
            local failCount = tonumber(failed) or 0
            local form = strlower(CB_UrlDecode(encForm):match("^%s*(.-)%s*$"))
            if succCount > 0 and form ~= "" then
                for _, e in pairs(CleanBot_PartyBots) do
                    e.formation = form
                end
                if NS.CB_RefreshCommands then NS.CB_RefreshCommands() end
            end
            -- If any bot failed or nothing succeeded, re-fetch to reconcile real server state
            if failCount > 0 or succCount == 0 then
                if NS.CB_FetchFormationsBridge then
                    NS.CB_FetchFormationsBridge(true)
                end
            end

        -- ── Inventory & Item action ACKs ──────────────────────────────────
        elseif msg and strsub(msg, 1, 22) == "INVENTORY_ITEM_ACTION~" then
            -- INVENTORY_ITEM_ACTION~<botName>~<token>~<action>~<itemId>~<status>~<reason>~<moved>
            local rest = strsub(msg, 23)
            local rawName, r2 = NS.CB_SplitOnce(rest, "~")
            local name = CB_UrlDecode(rawName)
            local token, r3 = NS.CB_SplitOnce(r2, "~")
            local action, r4 = NS.CB_SplitOnce(r3, "~")
            local itemId, r5 = NS.CB_SplitOnce(r4, "~")
            local status, r6 = NS.CB_SplitOnce(r5, "~")
            local reason, moved = NS.CB_SplitOnce(r6, "~")
            local key = strlower(name)
            local movedCount = tonumber(moved) or 0
            local isSingleBulk = NS.bulkSellPending and token and NS.bulkSellPending[token]
            if isSingleBulk then
                NS.bulkSellPending[token] = nil
            end
            local isWithdraw = action == "BANK_WITHDRAW" and NS.withdrawPending and token and NS.withdrawPending[token]
            if isWithdraw then
                NS.withdrawPending[token] = nil
            end
            if status == "OK" then
                if action == "SELL_GREY" and movedCount > 0 then
                    if NS.CB_Print then
                        NS.CB_Print(string.format("%s: %d grey item(s) sold.", name, movedCount))
                    end
                    if isSingleBulk and NS.CB_PlaySellSound then
                        NS.CB_PlaySellSound()
                    end
                end
            end
            if status ~= "OK" and isWithdraw and reason == "BANKER_NOT_FOUND" then
                StaticPopup_Show("CLEANBOT_NO_BANKER", name)
            end
            local gp = NS.groupSellPending
            if gp and action == "SELL_GREY" and gp.expected and gp.expected[key] then
                gp.expected[key] = nil
                gp.received = (gp.received or 0) + 1
                if status == "OK" then gp.soldTotal = (gp.soldTotal or 0) + movedCount end
                local remaining = false
                for _ in pairs(gp.expected) do remaining = true; break end
                if not remaining then CB_GroupSellFinalize(gp.gen) end
            end
            NS.CB_ScheduleReconcile(key, name)

        elseif msg and strsub(msg, 1, 21) == "INVENTORY_ITEM_EQUIP~" then
            local rest = strsub(msg, 22)
            local name, r2 = NS.CB_SplitOnce(rest, "~")
            local _, r3 = NS.CB_SplitOnce(r2, "~")
            local status = NS.CB_SplitOnce(r3, "~")
            local key = strlower(name)
            if status ~= "OK" then
                NS.CB_ScheduleReconcile(key, name)
            end

        elseif msg and strsub(msg, 1, 19) == "INVENTORY_ITEM_USE~" then
            local rest = strsub(msg, 20)
            local name, r2 = NS.CB_SplitOnce(rest, "~")
            local _, r3 = NS.CB_SplitOnce(r2, "~")
            local status = NS.CB_SplitOnce(r3, "~")
            local key = strlower(name)
            if status ~= "OK" then
                NS.CB_ScheduleReconcile(key, name)
            end

        elseif msg and strsub(msg, 1, 23) == "INVENTORY_ITEM_DESTROY~" then
            local rest = strsub(msg, 24)
            local name, r2 = NS.CB_SplitOnce(rest, "~")
            local _, r3 = NS.CB_SplitOnce(r2, "~")
            local status = NS.CB_SplitOnce(r3, "~")
            local key = strlower(name)
            if status ~= "OK" then
                NS.CB_ScheduleReconcile(key, name)
            end

        elseif msg and strsub(msg, 1, 20) == "INVENTORY_ITEM_SELL~" then
            local rest = strsub(msg, 21)
            local name, r2 = NS.CB_SplitOnce(rest, "~")
            local _, r3 = NS.CB_SplitOnce(r2, "~")
            local status = NS.CB_SplitOnce(r3, "~")
            local key = strlower(name)
            if status == "OK" then
                if NS.CB_PlaySellSound then NS.CB_PlaySellSound() end
            else
                NS.CB_ScheduleReconcile(key, name)
            end

        -- ── Bank packets (mod-multibot-bridge) ───────────────────────────
        -- BANK_BEGIN~<botName>~<token>
        elseif msg and strsub(msg, 1, 11) == "BANK_BEGIN~" then
            local rest = strsub(msg, 12)
            local rawName, token = NS.CB_SplitOnce(rest, "~")
            local botName = CB_UrlDecode(rawName)
            local key = strlower(botName)
            local req = token and NS.pendingBankRequests and NS.pendingBankRequests[token]
            if req then
                req.items = {}
                req.failed = false
            end
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.bank = entry.bank or { items = {} }
            end

        -- BANK_ITEM~<botName>~<token>~<urlEncodedItemLine>
        elseif msg and strsub(msg, 1, 10) == "BANK_ITEM~" then
            local rest = strsub(msg, 11)
            local rawName, r2 = NS.CB_SplitOnce(rest, "~")
            local token, rawLine = NS.CB_SplitOnce(r2, "~")
            local req = token and NS.pendingBankRequests and NS.pendingBankRequests[token]
            if req and rawLine then
                local line = CB_UrlDecode(rawLine)
                local item = NS.CB_ParseItemLine and NS.CB_ParseItemLine(line)
                if item then
                    req.items[#req.items + 1] = item
                end
            end

        -- BANK_ERROR~<botName>~<token>~<reason>
        elseif msg and strsub(msg, 1, 11) == "BANK_ERROR~" then
            local rest = strsub(msg, 12)
            local rawName, r2 = NS.CB_SplitOnce(rest, "~")
            local token, reason = NS.CB_SplitOnce(r2, "~")
            local botName = CB_UrlDecode(rawName)
            local key = strlower(botName)
            local req = token and NS.pendingBankRequests and NS.pendingBankRequests[token]
            if req then
                req.failed = true
                req.reason = reason
            end
            if reason == "BANKER_NOT_FOUND" then
                local entry = CleanBot_PartyBots[key]
                if entry then entry.awaitingBank = false end
                local bf = NS.botBankFrames and NS.botBankFrames[key]
                if bf and NS.CB_SetInventoryLoading then
                    NS.CB_SetInventoryLoading(bf, false)
                end
                StaticPopup_Show("CLEANBOT_NO_BANKER", botName)
            end

        -- BANK_END~<botName>~<token>
        elseif msg and strsub(msg, 1, 9) == "BANK_END~" then
            local rest = strsub(msg, 10)
            local rawName, token = NS.CB_SplitOnce(rest, "~")
            local botName = CB_UrlDecode(rawName)
            local key = strlower(botName)
            local req = token and NS.pendingBankRequests and NS.pendingBankRequests[token]
            if req then NS.pendingBankRequests[token] = nil end

            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.awaitingBank = false
                if req and not req.failed and entry.bank then
                    entry.bank.items = req.items
                end
            end
            local f = NS.botBankFrames and NS.botBankFrames[key]
            if f and f:IsShown() then
                NS.CB_RenderBank(key)
            elseif f and NS.CB_SetInventoryLoading then
                NS.CB_SetInventoryLoading(f, false)
            end

        -- ITEM_DEPOSIT_EXACT~<botName>~<token>~<status>~<reason>~<action>~<srcBag>~<srcSlot>~<srcItemId>~<srcCount>~<moved>
        elseif msg and strsub(msg, 1, 19) == "ITEM_DEPOSIT_EXACT~" then
            local rest = strsub(msg, 20)
            local rawName, r2 = NS.CB_SplitOnce(rest, "~")
            local _, r3 = NS.CB_SplitOnce(r2, "~")
            local status, r4 = NS.CB_SplitOnce(r3, "~")
            local rawReason, r5 = NS.CB_SplitOnce(r4, "~")
            local action = NS.CB_SplitOnce(r5, "~")
            local botName = CB_UrlDecode(rawName)
            local key = strlower(botName)
            local reason = CB_UrlDecode(rawReason)

            if status == "OK" then
                NS.CB_ScheduleReconcile(key, botName)
            else
                if reason == "BANKER_NOT_FOUND" then
                    StaticPopup_Show("CLEANBOT_NO_BANKER", botName)
                    NS.CB_FetchInventory(key, botName)
                    local bf = NS.botBankFrames and NS.botBankFrames[key]
                    if bf and bf:IsShown() then NS.CB_RenderBank(key) end
                elseif reason == "GUILD_BANK_NOT_FOUND" or reason == "NO_GUILD_BANK_RIGHTS"
                    or reason == "GUILD_BANK_FULL" or reason == "BOT_NOT_IN_GUILD" or reason == "NOT_IN_SAME_GUILD" then
                    StaticPopup_Show("CLEANBOT_NO_GUILD_BANK", botName)
                    NS.CB_FetchInventory(key, botName)
                    local bf = NS.botBankFrames and NS.botBankFrames[key]
                    if bf and bf:IsShown() then NS.CB_RenderBank(key) end
                else
                    NS.CB_ScheduleReconcile(key, botName)
                end
            end

        -- ── Quest log packets ────────────────────────────────────────────
        -- Request: GET~QUESTS~ALL~botName~quests
        -- Packets: QUESTS_BEGIN~name~token~mode
        --          QUESTS_ITEM~name~token~mode~status~questID~questName
        --          QUESTS_END~name~token~mode
        -- status = "C" (complete) or "I" (incomplete). questName is URL-encoded, but the
        -- current bridge fills it with the questID again — see the handler note below.
        elseif msg and strsub(msg, 1, 13) == "QUESTS_BEGIN~" then
            local rest  = strsub(msg, 14)
            local name  = NS.CB_SplitOnce(rest, "~")
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.quests = {}
            end

        elseif msg and strsub(msg, 1, 12) == "QUESTS_ITEM~" then
            local rest              = strsub(msg, 13)
            local name,   r2        = NS.CB_SplitOnce(rest, "~")
            local _,      r3        = NS.CB_SplitOnce(r2,   "~")  -- skip token
            local _,      r4        = NS.CB_SplitOnce(r3,   "~")  -- skip mode
            local status, r5        = NS.CB_SplitOnce(r4,   "~")
            local questID, questName = NS.CB_SplitOnce(r5, "~")
            local key   = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry and entry.quests then
                -- Needed by the Abandon button: the server's drop command matches by link
                -- or title, so a bot-only quest must be dropped by NAME, not id. The
                -- bridge currently sends the id AGAIN in the name field (MultiBotBridge
                -- SendQuestPacketsForBot: UrlEncodeField(to_string(questId))), so only a
                -- field that differs from the id is a real title (future-proofing).
                questName = CB_UrlDecode(questName)
                entry.quests[#entry.quests + 1] = {
                    id     = tonumber(questID),
                    status = status,
                    name   = (questName ~= "" and questName ~= questID) and questName or nil,
                }
            end

        elseif msg and strsub(msg, 1, 11) == "QUESTS_END~" then
            local rest = strsub(msg, 12)
            local name = NS.CB_SplitOnce(rest, "~")
            local key  = strlower(name)
            local f    = NS.botQuestFrames and NS.botQuestFrames[key]
            if f and f:IsShown() then
                if NS.CB_RenderQuests then NS.CB_RenderQuests(key) end
            end

        elseif msg and (strsub(msg, 1, 9) == "SB_BEGIN~" or strsub(msg, 1, 15) == "SPELLBOOK_BEGIN~") then
            local rest = (strsub(msg, 1, 9) == "SB_BEGIN~") and strsub(msg, 10) or strsub(msg, 16)
            local name, token = NS.CB_SplitOnce(rest, "~")
            local key = strlower(strtrim(name or ""))
            local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
            if not entry then
                entry = {
                    name      = strtrim(name or ""),
                    class     = "WARRIOR",
                    combat    = NS.CB_DefaultCombat and NS.CB_DefaultCombat(),
                    nonCombat = NS.CB_DefaultNonCombat and NS.CB_DefaultNonCombat(),
                    classData = NS.CB_DefaultClassData and NS.CB_DefaultClassData("WARRIOR"),
                }
                CleanBot_PartyBots[key] = entry
            end
            entry.awaitingSpellbook = true
            entry.spellbookStaging  = {}
            entry.spellbookSeen     = {}
            local f = NS.botSpellbookFrames and NS.botSpellbookFrames[key]
            if f and f:IsShown() and NS.CB_RenderSpellbook then
                NS.CB_RenderSpellbook(key)
            end

        elseif msg and (strsub(msg, 1, 8) == "SB_ITEM~" or strsub(msg, 1, 14) == "SPELLBOOK_ITEM~") then
            local rest = (strsub(msg, 1, 8) == "SB_ITEM~") and strsub(msg, 9) or strsub(msg, 15)
            local name, r2 = NS.CB_SplitOnce(rest, "~")
            local token, spellId = NS.CB_SplitOnce(r2, "~")
            if (not spellId or spellId == "") and token ~= "" then
                spellId = token
            end
            local key = strlower(strtrim(name or ""))
            local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
            if entry and entry.spellbookStaging and spellId then
                entry.spellbookSeen = entry.spellbookSeen or {}
                for sId in spellId:gmatch("%d+") do
                    local id = tonumber(sId)
                    if id and id > 0 and not entry.spellbookSeen[id] then
                        entry.spellbookSeen[id] = true
                        local sName, rank, icon = GetSpellInfo(id)
                        local isPassive = (IsPassiveSpell and IsPassiveSpell(id)) or false
                        local link = GetSpellLink and GetSpellLink(id)
                        entry.spellbookStaging[#entry.spellbookStaging + 1] = {
                            id        = id,
                            name      = sName or ("Spell #" .. id),
                            rank      = rank or "",
                            icon      = icon or "Interface\\Icons\\INV_Misc_QuestionMark",
                            isPassive = isPassive,
                            link      = link or "",
                        }
                    end
                end
            end

        elseif msg and (strsub(msg, 1, 7) == "SB_END~" or strsub(msg, 1, 13) == "SPELLBOOK_END~") then
            local rest = (strsub(msg, 1, 7) == "SB_END~") and strsub(msg, 8) or strsub(msg, 14)
            local name, token = NS.CB_SplitOnce(rest, "~")
            local key = strlower(strtrim(name or ""))
            local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
            if entry then
                CB_FinalizeSpellbookCollection(key, entry)
            else
                local f = NS.botSpellbookFrames and NS.botSpellbookFrames[key]
                if f and f:IsShown() and NS.CB_RenderSpellbook then
                    NS.CB_RenderSpellbook(key)
                end
            end

        -- ── Premade talent-spec list packets (GET~TALENT_SPEC_LIST) ────────
        elseif msg and strsub(msg, 1, 18) == "TALENT_SPEC_BEGIN~" then
            local rest = strsub(msg, 19)
            local rawName, token = NS.CB_SplitOnce(rest, "~")
            local req = token and NS.pendingSpecListRequests and NS.pendingSpecListRequests[token]
            if req then
                req.staging = {}
            end

        elseif msg and strsub(msg, 1, 20) == "TALENT_SPEC_CURRENT~" then
            -- Ignored as per design: CleanBot only needs the premade spreads for the dropdown.

        elseif msg and strsub(msg, 1, 17) == "TALENT_SPEC_ITEM~" then
            -- TALENT_SPEC_ITEM~<botName>~<token>~<specIndex>~<encodedSpecName>~<build>
            local rest = strsub(msg, 18)
            local rawName, r2 = NS.CB_SplitOnce(rest, "~")
            local token, r3   = NS.CB_SplitOnce(r2, "~")
            local req = token and NS.pendingSpecListRequests and NS.pendingSpecListRequests[token]
            if req then
                local specIndex, r4 = NS.CB_SplitOnce(r3, "~")
                local encName, build = NS.CB_SplitOnce(r4, "~")
                local specName = CB_UrlDecode(encName)
                local t1, t2, t3 = (build or ""):match("(%d+)%-(%d+)%-(%d+)")
                if specName and specName ~= "" and t1 and t2 and t3 then
                    req.staging[#req.staging + 1] = {
                        name = specName,
                        t    = { tonumber(t1), tonumber(t2), tonumber(t3) },
                    }
                end
            end

        elseif msg and strsub(msg, 1, 16) == "TALENT_SPEC_END~" then
            local rest = strsub(msg, 17)
            local rawName, token = NS.CB_SplitOnce(rest, "~")
            local req = token and NS.pendingSpecListRequests and NS.pendingSpecListRequests[token]
            if req then
                NS.pendingSpecListRequests[token] = nil
                local cls = req.class
                if cls then
                    NS.premadeSpecsFetching[cls] = nil
                    NS.premadeSpecs[cls] = req.staging or {}
                end
                if req.key and NS.CB_SyncTalentSpec then
                    NS.CB_SyncTalentSpec(req.key)
                end
            end

        -- ── Bot profession list packet (GET~PROFESSION) ─────────────────────
        elseif msg and strsub(msg, 1, 11) == "PROFESSION~" then
            local rest = strsub(msg, 12)
            local rawName, profsStr = NS.CB_SplitOnce(rest, "~")
            local botName = CB_UrlDecode(rawName):match("^%s*(.-)%s*$")
            local key = strlower(botName)
            local entry = CleanBot_PartyBots[key]
            if entry then
                entry.awaitingProfessions = false
                entry.professionsTimeout  = 0
                entry.professionsAt       = GetTime()
                local list = {}
                if profsStr and profsStr ~= "" then
                    for item in string.gmatch(profsStr, "([^;]+)") do
                        local decItem = CB_UrlDecode(item)
                        local profKey, cur, max = decItem:match("^(%a+):(%d+)/(%d+)$")
                        if profKey then
                            local sId = NS.PROF_SKILL_IDS and NS.PROF_SKILL_IDS[profKey]
                            local pName = (NS.PROF_CANONICAL_NAMES and NS.PROF_CANONICAL_NAMES[profKey])
                                or (profKey:sub(1,1):upper() .. profKey:sub(2))
                            table.insert(list, {
                                key     = profKey,
                                name    = pName,
                                cur     = tonumber(cur) or 0,
                                max     = tonumber(max) or 0,
                                skillId = sId,
                            })
                        end
                    end
                end
                entry.professions = list
                if NS.CB_OnProfessionsUpdated then
                    NS.CB_OnProfessionsUpdated(key)
                end
            end

        -- ── Profession recipe streaming packets (GET~PROFESSION_RECIPES) ───
        elseif msg and strsub(msg, 1, 25) == "PROFESSION_RECIPES_BEGIN~" then
            local rest = strsub(msg, 26)
            local rawName, r2 = NS.CB_SplitOnce(rest, "~")
            local token, skillId = NS.CB_SplitOnce(r2, "~")
            local req = token and NS.pendingRecipeRequests and NS.pendingRecipeRequests[token]
            if req then
                req.staging = {}
            end

        elseif msg and strsub(msg, 1, 24) == "PROFESSION_RECIPES_ITEM~" then
            -- PROFESSION_RECIPES_ITEM~<botName>~<token>~<skillId>~<spellId>~<itemId>~<difficulty>~<craftable>~<materials>
            local rest = strsub(msg, 25)
            local rawName, r2 = NS.CB_SplitOnce(rest, "~")
            local token, r3   = NS.CB_SplitOnce(r2, "~")
            local req = token and NS.pendingRecipeRequests and NS.pendingRecipeRequests[token]
            if req then
                local skillId, r4     = NS.CB_SplitOnce(r3, "~")
                local spellId, r5     = NS.CB_SplitOnce(r4, "~")
                local itemId, r6      = NS.CB_SplitOnce(r5, "~")
                local diffEnc, r7     = NS.CB_SplitOnce(r6, "~")
                local craftable, mEnc = NS.CB_SplitOnce(r7, "~")

                local sId = tonumber(spellId) or 0
                local iId = tonumber(itemId) or 0
                -- Note on difficulty values ("orange", "yellow", "green", "gray"):
                -- Recipe difficulty is computed server-side by mod-multibot-bridge
                -- (MultiBotBridge.cpp: GetRecipeDifficulty). In mod-multibot-bridge,
                -- GetRecipeDifficulty evaluates thresholds using skillLine->MinSkillLineRank
                -- rather than skillLine->TrivialSkillLineRankLow, which can cause recipes
                -- to be classified as "green" earlier than the standard client interface.
                local diff = CB_UrlDecode(diffEnc or ""):lower()
                local numAvail = tonumber(craftable) or 0
                local rawMats = CB_UrlDecode(mEnc or "")

                local reagents = {}
                if rawMats ~= "" then
                    for chunk in string.gmatch(rawMats, "([^;]+)") do
                        local matId, reqCount, availCount = chunk:match("^(%d+):(%d+):(%d+)$")
                        if matId then
                            local mId = tonumber(matId)
                            local mName, mQuality, mIcon
                            if GetItemInfo then
                                local name, _, qual, _, _, _, _, _, _, tex = GetItemInfo(mId)
                                mName, mQuality, mIcon = name, qual, tex
                            end
                            table.insert(reagents, {
                                itemId    = mId,
                                count     = tonumber(reqCount) or 1,
                                available = tonumber(availCount) or 0,
                                name      = mName or ("Item #" .. mId),
                                icon      = mIcon or "Interface\\Icons\\INV_Misc_QuestionMark",
                                quality   = mQuality or 1,
                            })
                        end
                    end
                end

                local spName, spIcon
                if GetSpellInfo then
                    local name, _, tex = GetSpellInfo(sId)
                    spName, spIcon = name, tex
                end

                local itName, itQuality, itSubType, itIcon
                if iId > 0 and GetItemInfo then
                    local name, _, qual, _, _, _, subType, _, _, tex = GetItemInfo(iId)
                    itName, itQuality, itSubType, itIcon = name, qual, subType, tex
                end

                local rName = itName or spName or ("Recipe #" .. sId)
                local rIcon = (iId > 0 and itIcon) or spIcon or "Interface\\Icons\\INV_Misc_QuestionMark"
                local rSubtype = (itSubType and itSubType ~= "") and itSubType or "Miscellaneous"

                -- Only include genuine craftable recipes or item enchantments.
                -- Filters out profession launcher abilities (e.g. "Tailoring") and utility spells (e.g. "Disenchant").
                if iId > 0 or #reagents > 0 then
                    table.insert(req.staging, {
                        spellId      = sId,
                        itemId       = iId,
                        name         = rName,
                        icon         = rIcon,
                        difficulty   = diff,
                        subType      = rSubtype,
                        craftable    = numAvail,
                        numAvailable = numAvail,
                        reagents     = reagents,
                        quality      = itQuality or 1,
                    })
                end
            end

        elseif msg and strsub(msg, 1, 23) == "PROFESSION_RECIPES_END~" then
            local rest = strsub(msg, 24)
            local rawName, r2 = NS.CB_SplitOnce(rest, "~")
            local token, skillId = NS.CB_SplitOnce(r2, "~")
            local req = token and NS.pendingRecipeRequests and NS.pendingRecipeRequests[token]
            if req then
                NS.pendingRecipeRequests[token] = nil
                local entry = CleanBot_PartyBots[req.botKey]
                if entry then
                    entry.professionRecipes = entry.professionRecipes or {}
                    entry.professionRecipes[req.skillId] = {
                        timestamp = GetTime(),
                        recipes   = req.staging,
                    }
                end
                if NS.CB_OnProfessionRecipesLoaded then
                    NS.CB_OnProfessionRecipesLoaded(req.botKey, req.skillId, req.staging)
                end
            end

        elseif msg and strsub(msg, 1, 24) == "PROFESSION_RECIPE_CRAFT~" then
            local rest = strsub(msg, 25)
            local rawName, r1 = NS.CB_SplitOnce(rest, "~")
            local token, r2 = NS.CB_SplitOnce(r1, "~")
            local skillId, r3 = NS.CB_SplitOnce(r2, "~")
            local spellId, r4 = NS.CB_SplitOnce(r3, "~")
            local actualItemId, r5 = NS.CB_SplitOnce(r4, "~")
            local status, reason = NS.CB_SplitOnce(r5, "~")

            local botName = rawName and CB_UrlDecode(rawName) or rawName
            local decReason = reason and CB_UrlDecode(reason) or ""
            local isOk = (status == "OK")

            local pending = token and NS.craftPending and NS.craftPending[token]
            if pending then
                NS.craftPending[token] = nil
                if pending.callback then
                    pending.callback(isOk, decReason, tonumber(actualItemId))
                end
            end

            if isOk then
                if NS.CB_Print then
                    NS.CB_Print(string.format("%s begins crafting.", botName or "Bot"))
                end
            else
                if NS.CB_Print then
                    local errMsg = decReason ~= "" and decReason or "FAILED"
                    NS.CB_Print(string.format("%s cannot craft: %s.", botName or "Bot", errMsg))
                end
            end

        elseif msg and strsub(msg, 1, 27) == "CRAFT_RECIPE_TARGET_RESULT~" then
            local rest = strsub(msg, 28)
            local token, r1 = NS.CB_SplitOnce(rest, "~")
            local rawName, r2 = NS.CB_SplitOnce(r1, "~")
            local status, r3 = NS.CB_SplitOnce(r2, "~")
            local reason, r4 = NS.CB_SplitOnce(r3, "~")
            local skillId, r5 = NS.CB_SplitOnce(r4, "~")
            local spellId, r6 = NS.CB_SplitOnce(r5, "~")
            local targetBag, r7 = NS.CB_SplitOnce(r6, "~")
            local targetSlot, targetItemId = NS.CB_SplitOnce(r7, "~")

            local botName = rawName and CB_UrlDecode(rawName) or rawName
            local decReason = reason and CB_UrlDecode(reason) or ""
            local isOk = (status == "OK")

            local pending = token and NS.craftTargetPending and NS.craftTargetPending[token]
            if pending then
                NS.craftTargetPending[token] = nil
                if pending.callback then
                    pending.callback(isOk, decReason, tonumber(targetItemId))
                end
            end

            if isOk then
                if NS.CB_Print then
                    NS.CB_Print(string.format("%s begins enchanting.", botName or "Bot"))
                end
            else
                if NS.CB_Print then
                    local errMsg = decReason ~= "" and decReason or "FAILED"
                    NS.CB_Print(string.format("%s cannot enchant: %s.", botName or "Bot", errMsg))
                end
            end
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        -- Self-bot live state: the server prints "Enable/Disable player botAI" on every
        -- toggle (addon, login auto-enable, or a manually typed command). This is the
        -- authoritative source of truth — drive tracking off it rather than assuming.
        local lower = msg and strlower(msg)
        if lower and lower:find("player botai", 1, true) then
            if lower:find("enable", 1, true) then
                -- First-ever detection: offer to set the auto-enable preference (once).
                if CleanBot_SavedVars and not CleanBot_SavedVars.selfBotPromptShown then
                    CleanBot_SavedVars.selfBotPromptShown = true
                    if not NS.manageSelf then StaticPopup_Show("CLEANBOT_SELFBOT_AUTO") end
                end
                NS.CB_SetSelfBotActive(true)
            elseif lower:find("disable", 1, true) then
                NS.CB_SetSelfBotActive(false)
            end
            return
        end

        -- Workaround: ".playerbots bot add/addaccount/login <name>" fails with
        -- "<cmd>: <Name> - player already logged in" when the character is already online —
        -- the server won't pull an online character into the group. Fall back to a normal
        -- party invite. The per-name system line carries the name, so this one handler covers
        -- every bot-add path (Invite by Name / Preset / Login Target / Invite Account, or a
        -- hand-typed command). Match the raw msg to keep the name's casing.
        if msg then
            local onlineName = msg:match("(%S+)%s*%-%s*[Pp]layer already logged in")
            if onlineName then
                InviteUnit(onlineName)
                NS.CB_Print(onlineName .. " was already online \226\128\148 sent a party invite instead.")
                return
            end
        end

        if NS.awaitingLinkedAccounts and msg and strlower(msg):find("linked accounts") then
            -- Header line received — start collecting account entries
            NS.awaitingLinkedAccounts   = false
            NS.collectingLinkedAccounts = true
            NS.linkedAccounts           = {}
        elseif NS.collectingLinkedAccounts then
            local name = msg and msg:match("^%-%s*(%S+)")
            if name then
                NS.linkedAccounts[#NS.linkedAccounts + 1] = name
            else
                -- Non-matching line signals end of the list
                NS.collectingLinkedAccounts = false
            end
        end

    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        -- Either group-roster event drives detection/sync: party APIs read 0 while
        -- in a raid, so RAID_ROSTER_UPDATE is required to detect bots in a raid.
        if NS.bridgeState == "unknown" then
            CB_StartBridgeDetection()
        else
            NS.CB_RequestSync()
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        if NS.individualPanel and NS.individualPanel:IsShown() and NS.CleanBot_RefreshTabs then
            NS.CleanBot_RefreshTabs()
        end

    elseif event == "UNIT_INVENTORY_CHANGED" then
        -- Re-inspect ONLY the currently-viewed bot. Bots re-gear themselves
        -- constantly (looting, auto-equip), so reacting for every bound bot
        -- burns the ~6/10s NotifyInspect throttle and evicts the viewed bot's
        -- single-unit inspect cache — non-viewed bots get fresh data anyway
        -- when selected (SelectBot inspects on every selection).
        local unit = ...
        if unit and NS.tabList and NS.CB_QueueEquipRefresh then
            for _, info in ipairs(NS.tabList) do
                if info.unit == unit and info.key == NS.selectedBotKey then
                    NS.CB_QueueEquipRefresh({{ key = info.key, unit = unit }})
                    break
                end
            end
        end

    elseif event == "INSPECT_TALENT_READY" then
        -- 3.3.5a's inspect-data-ready event (there is no "INSPECT_READY"). Carries
        -- only `success`, not a unit id — Equip.lua maps it to the serialised
        -- in-flight inspect. Equipment is readable immediately once this fires.
        if NS.CB_OnInspectReady then
            NS.CB_OnInspectReady()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- One-shot: reset bridge state at the first world entry (login),
        -- then stop listening so later zone/instance loads don't wipe the cache.
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")

        -- Determine whether this is a fresh login or a /reload.
        -- PLAYER_LOGOUT does not fire on /reload, so sessionActive remaining true
        -- means the last session ended via reload rather than a proper logout.
        local isReload = CleanBot_SavedVars and CleanBot_SavedVars.sessionActive == true
        CleanBot_SavedVars.sessionActive = true

        NS.loginPhaseActive = not isReload  -- gate bot probing on fresh login only
        NS.joinCandidates   = {}
        NS.bridgeReady      = false
        NS.bridgeState      = "unknown"
        NS.bridgeDetecting  = false
        NS.capabilities          = {}
        NS.stateFramingCapable   = false
        NS.capabilitiesResolved  = false
        NS.capabilityBatchActive = false
        NS.stateRequests         = {}
        NS.stateActive           = {}
        -- Keep the Debug tab's "Auto (<state>)" label current.
        if NS.CB_RefreshDebugTab then NS.CB_RefreshDebugTab() end
        NS.probed           = {}
        NS.awaitingProbe    = {}
        CleanBot_PartyBots  = {}

        -- Self-bot live state across the world entry:
        --   Fresh login — the character always spawns with self-bot OFF, so force it off
        --     (overriding any stale persisted value); auto-enable below re-toggles it.
        --   Reload — server state is preserved and no message re-fires, so keep the
        --     persisted NS.selfBotActive (restored at PLAYER_LOGIN) and re-apply it below.
        if not isReload then
            NS.selfBotActive = false
            if CleanBot_SavedVars then CleanBot_SavedVars.selfBotActive = false end
        end

        CB_StartBridgeDetection()
        -- The party/raid roster may not be query-able yet at login, so the call
        -- above can no-op (GetNum*Members == 0) and the roster event may have
        -- already fired during the loading screen. Retry a few times so being
        -- already in a group — especially a raid — is reliably detected.
        -- CB_StartBridgeDetection is idempotent (guards on state / in-progress /
        -- in-group), so extra calls are harmless once detection has begun.
        NS.CB_After(1, CB_StartBridgeDetection)
        NS.CB_After(3, CB_StartBridgeDetection)
        NS.CB_After(6, CB_StartBridgeDetection)

        -- Self-bot enable/restore (delayed so the player is in-world and detection has had
        -- a chance to start). `.playerbot bot self` is a pure toggle and the character
        -- spawns OFF, so it is sent ONLY on a fresh login — never on reload (which would
        -- turn it off). The "Enable player botAI" reply drives CB_SetSelfBotActive.
        if not isReload then
            if NS.manageSelf then
                NS.CB_After(2, function() SendChatMessage(".playerbot bot self", "SAY") end)
            end
        elseif NS.selfBotActive then
            -- Reload while active: re-seed the wiped cache without re-toggling the server.
            NS.CB_After(2, function() NS.CB_SetSelfBotActive(true) end)
        end

    elseif event == "PLAYER_LOGOUT" then
        -- Clear the flag so the next session is treated as a fresh login.
        if CleanBot_SavedVars then
            CleanBot_SavedVars.sessionActive = false
        end
    end
end)
