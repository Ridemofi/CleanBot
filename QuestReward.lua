-- ============================================================
-- QuestReward.lua  —  Bot quest reward selection.
--
-- When the player is completing a quest with multiple choice rewards
-- (QUEST_COMPLETE with GetNumQuestChoices() > 1) and has tracked bots
-- in the party/raid:
--   • A clean side panel opens anchored to the right of QuestFrame.
--   • Lists each bot in the group with its class icon and name.
--   • Shows the quest reward items with full tooltips and rarity borders.
--   • Clicking an item sends "r <itemlink>" to that bot, ordering it
--     to pick that specific quest reward on turn-in.
--   • Shows a backpack/inventory button to inspect the bot's current gear.
--   • Closes automatically when the quest dialog finishes or closes.
-- ============================================================

local NS = CleanBotNS

-- ── State ────────────────────────────────────────────────────────────────────
local rewardFrame     = nil      ---@type table|nil
local activeChoices   = {}       -- array of { index, link, name, texture, count, quality }
local chosenByBot     = {}       -- [botKey] = itemIndex
local botRows         = {}       -- array of row frames
local openedInvKeys   = {}       -- bot inventory windows opened from this panel
local maxTries        = 4
local retryCount      = 0

local ROW_HEIGHT      = 46
local FRAME_WIDTH     = 410
local BUTTON_SIZE     = 32

-- ── Roster helper ───────────────────────────────────────────────────────────
--- Returns an array of tracked bot records currently in the player's group.
---@return table[] bots  Array of { key, name, class, unit }
local function CB_GetGroupBots()
    local bots = {}
    if not (CleanBot_PartyBots and NS.CB_ForEachGroupMember) then return bots end

    NS.CB_ForEachGroupMember(function(unit, name)
        if name then
            local key = strlower(name)
            local entry = CleanBot_PartyBots[key]
            if entry then
                table.insert(bots, {
                    key   = key,
                    name  = entry.name or name,
                    class = entry.class,
                    unit  = unit,
                })
            end
        end
    end)
    return bots
end

--- True when the player has at least one tracked bot in the current group.
---@return boolean
local function CB_HasBots()
    local bots = CB_GetGroupBots()
    return #bots > 0
end

-- ── Quest data collection ────────────────────────────────────────────────────
--- Reads choice rewards from the currently open quest turn-in dialog.
---@return table[] choices
---@return boolean allCached  True if all item links and names were available.
local function CB_CollectQuestChoices()
    local n = GetNumQuestChoices() or 0
    if n <= 1 then return {}, true end

    local choices = {}
    local allCached = true
    for i = 1, n do
        local link = GetQuestItemLink("CHOICE", i)
        local name, texture, count, quality = GetQuestItemInfo("CHOICE", i)
        if not link or not name then
            allCached = false
        end
        choices[i] = {
            index   = i,
            link    = link,
            name    = name or ("Item #" .. i),
            texture = texture or "Interface\\Icons\\INV_Misc_QuestionMark",
            count   = count or 1,
            quality = quality or 1,
        }
    end
    return choices, allCached
end

-- ── Selection and command sending ───────────────────────────────────────────
--- Orders a bot to select a specific choice reward index on turn-in.
---@param botName   string  Display name of the bot.
---@param botKey    string  Lowercased bot key.
---@param itemIndex number  Index in activeChoices (1..6).
local function CB_SelectRewardForBot(botName, botKey, itemIndex)
    local choice = activeChoices[itemIndex]
    if not choice or not choice.link then return end

    local cleanLink = NS.CB_CleanItemLink and NS.CB_CleanItemLink(choice.link) or choice.link
    if NS.CB_SendBotCommand then
        NS.CB_SendBotCommand(botName, "r " .. cleanLink)
    elseif SendChatMessage then
        SendChatMessage("r " .. cleanLink, "WHISPER", nil, botName)
    end

    chosenByBot[botKey] = itemIndex

    if NS.CB_Print then
        NS.CB_Print(botName .. " will choose reward: " .. choice.link)
    else
        print("|cffffcc00CleanBot|r: " .. botName .. " will choose reward: " .. choice.link)
    end
end

-- ── UI Row management ────────────────────────────────────────────────────────
--- Updates selection and visual state for a bot row.
--- If isConfirmed: selected button stays highlighted, other buttons become desaturated (gray) and dimmed.
--- If not isConfirmed: selected button is highlighted, check button activates, others remain selectable.
---@param row table
---@param selectedIdx number?
---@param isConfirmed boolean?
local function CB_UpdateRowSelectionVisual(row, selectedIdx, isConfirmed)
    local checkBtn = row.checkBtn
    local numChoices = #activeChoices

    if isConfirmed then
        -- Confirmed state: only the selected item remains active, others are grayed out
        if checkBtn then
            checkBtn:Disable()
            checkBtn:SetAlpha(0.40)
            if checkBtn.icon then checkBtn.icon:SetDesaturated(false) end
        end

        for i = 1, 6 do
            local btn = row.itemButtons[i]
            if btn and i <= numChoices then
                if selectedIdx and i == selectedIdx then
                    btn.icon:SetDesaturated(false)
                    btn:SetAlpha(1.0)
                    if btn.selectedTexture then btn.selectedTexture:Show() end
                    if btn.LockHighlight then btn:LockHighlight() end
                else
                    btn.icon:SetDesaturated(true)
                    btn:SetAlpha(0.35)
                    if btn.selectedTexture then btn.selectedTexture:Hide() end
                    if btn.UnlockHighlight then btn:UnlockHighlight() end
                    btn:Disable()
                end
            end
        end

        if selectedIdx and activeChoices[selectedIdx] then
            local choice = activeChoices[selectedIdx]
            row.statusLabel:SetText("|cff40ff40✓ " .. (choice.name or "Chosen") .. "|r")
        end
    else
        -- Unconfirmed state (pending or selected before confirming)
        for i = 1, 6 do
            local btn = row.itemButtons[i]
            if btn and i <= numChoices then
                btn.icon:SetDesaturated(false)
                btn:Enable()

                if selectedIdx and i == selectedIdx then
                    btn:SetAlpha(1.0)
                    if btn.selectedTexture then btn.selectedTexture:Show() end
                    if btn.LockHighlight then btn:LockHighlight() end
                else
                    btn:SetAlpha(selectedIdx and 0.80 or 1.0)
                    if btn.selectedTexture then btn.selectedTexture:Hide() end
                    if btn.UnlockHighlight then btn:UnlockHighlight() end
                end
            end
        end

        if selectedIdx and activeChoices[selectedIdx] then
            local choice = activeChoices[selectedIdx]
            row.statusLabel:SetText("|cffffcc00Selected: " .. (choice.name or "") .. "|r")
            if checkBtn then
                checkBtn:Enable()
                checkBtn:SetAlpha(1.0)
                if checkBtn.icon then checkBtn.icon:SetDesaturated(false) end
            end
        else
            row.statusLabel:SetText("|cff888888(Pending)|r")
            if checkBtn then
                checkBtn:Disable()
                checkBtn:SetAlpha(0.25)
                if checkBtn.icon then checkBtn.icon:SetDesaturated(true) end
            end
        end
    end
end

--- Creates a single bot row frame containing portrait/class icon, name,
--- inventory button, up to 6 reward buttons, and a status label.
---@param parent table
---@param index  number
---@return table row
local function CB_CreateBotRow(parent, index)
    local row = CreateFrame("Frame", "CleanBotQuestRewardRow_" .. index, parent)
    row:SetHeight(ROW_HEIGHT)

    -- Background panel
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0.10, 0.10, 0.12, 0.50)
    row.bg = bg

    -- Bottom divider line
    local line = row:CreateTexture(nil, "BORDER")
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 4, 0)
    line:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 0)
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetVertexColor(0.25, 0.25, 0.28, 0.60)
    row.line = line

    -- Class/Portrait icon (20x20)
    local classIcon = row:CreateTexture(nil, "ARTWORK")
    classIcon:SetSize(20, 20)
    classIcon:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -5)
    row.classIcon = classIcon

    -- Bot name FontString
    local nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameLabel:SetPoint("LEFT", classIcon, "RIGHT", 5, 0)
    nameLabel:SetJustifyH("LEFT")
    row.nameLabel = nameLabel

    -- Inspect / Bag icon button (18x18)
    local invBtn = CreateFrame("Button", nil, row)
    invBtn:SetSize(18, 18)
    invBtn:SetPoint("LEFT", nameLabel, "RIGHT", 6, 0)
    local invIcon = invBtn:CreateTexture(nil, "ARTWORK")
    invIcon:SetAllPoints()
    invIcon:SetTexture("Interface\\Buttons\\Button-Backpack-Up")
    invBtn.icon = invIcon
    invBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    invBtn:SetScript("OnClick", function()
        if row.botKey and row.botName and NS.CB_RequestInventory then
            NS.CB_RequestInventory(row.botKey, row.botName, rewardFrame)
            openedInvKeys[row.botKey] = true
        end
    end)
    NS.CB_SetTooltip(invBtn, "Bot Inventory", "Open this bot's bags to inspect current gear.")
    row.invBtn = invBtn

    -- Status label (Pending / Chosen)
    local statusLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusLabel:SetPoint("BOTTOMLEFT", classIcon, "BOTTOMLEFT", 0, -14)
    statusLabel:SetJustifyH("LEFT")
    statusLabel:SetText("|cff888888(Pending)|r")
    row.statusLabel = statusLabel

    -- Green Check confirmation button (26x26)
    local checkBtn = CreateFrame("Button", "CleanBotQuestRewardCheckBtn_" .. index, row)
    checkBtn:SetSize(26, 26)
    checkBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)

    local checkIcon = checkBtn:CreateTexture(nil, "ARTWORK")
    checkIcon:SetAllPoints()
    checkIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    checkBtn.icon = checkIcon

    checkBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    checkBtn:SetPushedTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    checkBtn:SetAlpha(0.25)
    checkBtn:Disable()

    NS.CB_AttachTooltip(checkBtn, function(tt)
        if row.confirmed then
            tt:AddLine("Reward Confirmed", 0.2, 1, 0.2)
            tt:AddLine("The chosen quest reward has already been claimed for " .. (row.botName or "this bot") .. ".", 1, 1, 1, true)
        elseif row.selectedIdx and activeChoices[row.selectedIdx] then
            local choice = activeChoices[row.selectedIdx]
            tt:AddLine("Confirm Reward", 0.2, 1, 0.2)
            tt:AddLine("Click to confirm and claim |cffffffff" .. (choice.name or "item") .. "|r for " .. (row.botName or "this bot") .. ".", 1, 1, 1, true)
        else
            tt:AddLine("Confirm Reward", 0.8, 0.8, 0.8)
            tt:AddLine("Select a reward item first, then click here to confirm.", 1, 1, 1, true)
        end
    end)

    checkBtn:SetScript("OnClick", function()
        if row.confirmed or not row.selectedIdx then return end
        row.confirmed = true
        CB_SelectRewardForBot(row.botName, row.botKey, row.selectedIdx)
        CB_UpdateRowSelectionVisual(row, row.selectedIdx, true)
    end)
    row.checkBtn = checkBtn

    -- Up to 6 Choice Reward Buttons
    row.itemButtons = {}
    for btnIdx = 1, 6 do
        local btn = CreateFrame("Button", "CleanBotQuestRewardBtn_" .. index .. "_" .. btnIdx, row)
        btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
        btn:SetPoint("RIGHT", checkBtn, "LEFT", -6 - ((6 - btnIdx) * (BUTTON_SIZE + 4)), 0)

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        btn.icon = icon

        if NS.CB_CropIcon then
            NS.CB_CropIcon(icon)
        end

        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        btn:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

        -- Quality border frame
        if NS.CB_ApplyQualityBackdrop then
            NS.CB_ApplyQualityBackdrop(btn)
        end

        -- Selected checkmark / border overlay
        local selTex = btn:CreateTexture(nil, "OVERLAY")
        selTex:SetAllPoints()
        selTex:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        selTex:SetBlendMode("ADD")
        selTex:Hide()
        btn.selectedTexture = selTex

        -- Stack count
        local countFS = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        countFS:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
        countFS:Hide()
        btn.countFS = countFS

        -- Tooltip
        NS.CB_AttachTooltip(btn, function(tt, self)
            if not self.itemLink then return false end
            tt:SetHyperlink(self.itemLink)
            tt:AddLine(" ")
            if row.confirmed then
                if row.selectedIdx == self.choiceIndex then
                    tt:AddLine("|cff00ff00Reward Claimed:|r This bot received this item.", 0.2, 1, 0.2)
                else
                    tt:AddLine("|cff888888Not Selected|r", 0.6, 0.6, 0.6)
                end
            else
                tt:AddLine("|cff00ff00Left-Click:|r Select this reward (click green check to confirm).", 0.2, 1, 0.2)
            end
        end)

        -- Click handler: selects item (does not confirm yet)
        btn:SetScript("OnClick", function()
            if row.confirmed then return end
            if row.botName and row.botKey and btn.choiceIndex then
                row.selectedIdx = btn.choiceIndex
                CB_UpdateRowSelectionVisual(row, row.selectedIdx, false)
            end
        end)

        btn:Hide()
        row.itemButtons[btnIdx] = btn
    end

    return row
end

-- ── Main Frame construction ─────────────────────────────────────────────────
local function CB_BuildRewardFrame()
    if rewardFrame then return rewardFrame end

    local f = CreateFrame("Frame", "CleanBotQuestRewardFrame", UIParent)
    f:SetSize(FRAME_WIDTH, 200)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Window Skin
    if NS.CB_ApplyFrameSkin then
        NS.CB_ApplyFrameSkin(f, 0)
    else
        f:SetBackdrop(NS.PANEL_BACKDROP or {
            bgFile   = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0.08, 0.08, 0.10, 0.95)
        f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end

    -- Title Bar
    local titleLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleLabel:SetPoint("TOP", f, "TOP", 0, -8)
    titleLabel:SetText("|cffffcc00Bot Quest Rewards|r")
    f.titleLabel = titleLabel

    -- Subtitle / Instruction
    local subLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -26)
    subLabel:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -26)
    subLabel:SetJustifyH("LEFT")
    subLabel:SetText("Select an item, then click the green check to confirm:")
    f.subLabel = subLabel

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetSize(22, 22)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
    end)
    f.closeBtn = closeBtn

    -- Content rows container
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -44)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
    f.content = content

    f:Hide()
    rewardFrame = f
    return f
end

-- ── Rendering ────────────────────────────────────────────────────────────────
local function CB_RenderRewardFrame()
    local f = CB_BuildRewardFrame()
    local bots = CB_GetGroupBots()
    local numBots = #bots
    local numChoices = #activeChoices

    if numBots <= 0 or numChoices <= 0 then
        f:Hide()
        return
    end

    -- Adjust frame height based on bot count (min 130px, max 480px)
    local totalHeight = 52 + (numBots * (ROW_HEIGHT + 4)) + 8
    f:SetHeight(math.min(totalHeight, 480))

    -- Populate rows
    for i = 1, math.max(numBots, #botRows) do
        local row = botRows[i]
        if i <= numBots then
            if not row then
                row = CB_CreateBotRow(f.content, i)
                botRows[i] = row
            end

            local bot = bots[i]
            row.botKey  = bot.key
            row.botName = bot.name
            row.botUnit = bot.unit

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, -((i - 1) * (ROW_HEIGHT + 4)))
            row:SetPoint("TOPRIGHT", f.content, "TOPRIGHT", 0, -((i - 1) * (ROW_HEIGHT + 4)))

            -- Class icon
            local coords = bot.class and NS.CLASS_ICON_COORDS and NS.CLASS_ICON_COORDS[bot.class]
            if coords then
                row.classIcon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
                row.classIcon:SetTexCoord(unpack(coords))
            else
                row.classIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                row.classIcon:SetTexCoord(0, 1, 0, 1)
            end

            -- Class-colored name
            local c = bot.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[bot.class]
            if c then
                row.nameLabel:SetText(string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, bot.name))
            else
                row.nameLabel:SetText(bot.name)
            end

            -- Position & populate choice buttons
            for btnIdx = 1, 6 do
                local btn = row.itemButtons[btnIdx]
                if btnIdx <= numChoices then
                    local choice = activeChoices[btnIdx]
                    btn.choiceIndex = btnIdx
                    btn.itemLink    = choice.link
                    btn.icon:SetTexture(choice.texture)

                    btn:ClearAllPoints()
                    btn:SetPoint("RIGHT", row.checkBtn, "LEFT", -6 - ((numChoices - btnIdx) * (BUTTON_SIZE + 4)), 0)

                    if choice.count and choice.count > 1 then
                        btn.countFS:SetText(tostring(choice.count))
                        btn.countFS:Show()
                    else
                        btn.countFS:Hide()
                    end

                    if NS.CB_ApplyItemVisuals then
                        NS.CB_ApplyItemVisuals(btn, choice.link)
                    elseif NS.CB_SetQualityBorder and choice.quality then
                        NS.CB_SetQualityBorder(btn, choice.quality)
                    end

                    btn:Show()
                else
                    btn.choiceIndex = nil
                    btn.itemLink    = nil
                    btn:Hide()
                end
            end

            -- Refresh visual selection
            local confirmedIdx = chosenByBot[bot.key]
            if confirmedIdx then
                row.selectedIdx = confirmedIdx
                row.confirmed   = true
                CB_UpdateRowSelectionVisual(row, confirmedIdx, true)
            else
                row.confirmed   = false
                CB_UpdateRowSelectionVisual(row, row.selectedIdx, false)
            end
            row:Show()
        elseif row then
            row:Hide()
        end
    end

    -- Anchor beside QuestFrame
    f:ClearAllPoints()
    if QuestFrame and QuestFrame:IsShown() then
        f:SetPoint("TOPLEFT", QuestFrame, "TOPRIGHT", 6, 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 180, 50)
    end

    f:Show()
end

-- ── Event Handlers ───────────────────────────────────────────────────────────
local function CB_HideRewardFrame()
    if rewardFrame then
        rewardFrame:Hide()
    end
    -- Close any inventory frames that were opened exclusively through this dialog
    if NS.botInventoryFrames then
        for k in pairs(openedInvKeys) do
            local invF = NS.botInventoryFrames[k]
            if invF and invF:IsShown() then
                invF:Hide()
            end
        end
    end
    openedInvKeys = {}
    chosenByBot   = {}
    for _, row in ipairs(botRows) do
        row.selectedIdx = nil
        row.confirmed   = false
    end
    retryCount    = 0
end

local function CB_CheckAndShowRewards()
    if not CB_HasBots() then
        CB_HideRewardFrame()
        return
    end

    local choices, allCached = CB_CollectQuestChoices()
    if #choices <= 1 then
        CB_HideRewardFrame()
        return
    end

    activeChoices = choices
    CB_RenderRewardFrame()

    -- Retry resolution if some links weren't loaded from client cache yet
    if not allCached and retryCount < maxTries then
        retryCount = retryCount + 1
        if NS.CB_After then
            NS.CB_After(0.25, function()
                if rewardFrame and rewardFrame:IsShown() and QuestFrame and QuestFrame:IsShown() then
                    CB_CheckAndShowRewards()
                end
            end)
        end
    end
end

local function CB_OnQuestComplete()
    -- Only trigger if the quest dialog has choices to select from
    retryCount = 0
    CB_CheckAndShowRewards()
end

-- ── Registration ─────────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame", "CleanBotQuestRewardEventFrame")
eventFrame:RegisterEvent("QUEST_COMPLETE")
eventFrame:RegisterEvent("QUEST_FINISHED")
eventFrame:RegisterEvent("QUEST_ITEM_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "QUEST_COMPLETE" then
        CB_OnQuestComplete()
    elseif event == "QUEST_FINISHED" then
        CB_HideRewardFrame()
    elseif event == "QUEST_ITEM_UPDATE" then
        if rewardFrame and rewardFrame:IsShown() then
            CB_CheckAndShowRewards()
        end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        if rewardFrame and rewardFrame:IsShown() then
            if CB_HasBots() then
                CB_RenderRewardFrame()
            else
                CB_HideRewardFrame()
            end
        end
    end
end)

-- Hook QuestFrame OnHide so our panel closes if the player closes the quest window
if QuestFrame and QuestFrame.HookScript then
    QuestFrame:HookScript("OnHide", function()
        CB_HideRewardFrame()
    end)
end
