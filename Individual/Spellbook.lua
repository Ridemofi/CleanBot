-- ============================================================
-- Spellbook.lua  —  Dragonflight-style Bot Spellbook for CleanBot.
--
-- Credits & Attribution:
--   Visual design, layout structure, and texture assets courtesy of DragonUI.
--   Features: 3-column retail card layout, spec dividers, wooden category tabs,
--   parchment pages, medieval ink typography, and real-time search filtering.
-- ============================================================

local NS = CleanBotNS

-- ── Registry ─────────────────────────────────────────────────────────────
NS.botSpellbookFrame = nil
NS.botSpellbookFrames = setmetatable({}, {
    __index = function(t, k)
        return NS.botSpellbookFrame
    end,
})

local P = "Interface\\AddOns\\CleanBot\\Textures\\Spellbook\\"

-- ── Geometry Constants ───────────────────────────────────────────────────
local FRAME_W          = 1618
local FRAME_H          = 883
local UI_SCALE         = 0.64      -- 80% del tamaño anterior (1035x565 px en pantalla)

local HEADER_H         = 58
local PAGES_TOP        = -56
local PAGES_BOT        = 0

local RIBBON_W         = 102
local RIBBON_H         = 102 * (557 / 102)  -- 557px native aspect
local RIBBON_X         = 28

local CARD_W           = 216.667
local CARD_H           = 60
local CARD_XPAD        = 15
local CARD_YPAD        = 10
local GRID_COLS        = 3
local ROW_H            = CARD_H + CARD_YPAD   -- 70px

local ICON_BTN         = 40
local ICON_SZ          = 33.6      -- active icon inset (covers border cleanly)
local PASSIVE_ICON_SZ  = 34        -- round passive icon

local VIEW_W           = 680
local VIEW_H           = 620
local VIEW_TOP         = -122
local VIEW1_X          = 85        -- Left page X offset
local VIEW2_X          = -50       -- Right page X offset: (VIEW2_X - VIEW_W)
local SPAN_W           = GRID_COLS * CARD_W + (GRID_COLS - 1) * CARD_XPAD  -- 680px
local ROWS_PER_PAGE    = math.floor((VIEW_H + CARD_YPAD) / ROW_H)          -- 9 rows

local TAB_H_INACTIVE   = 36
local TAB_H_ACTIVE     = 42
local TAB_MIN_W        = 70
local TAB_TEXT_PAD     = 24
local TAB_GAP          = 1

-- ── Typography Colors & Font Sizes ───────────────────────────────────────
-- Authentic medieval manuscript dark ink (SPELLBOOK_FONT_COLOR #2e1b0f)
local INK_R, INK_G, INK_B = 0.1804, 0.1059, 0.0588
-- Matching dark ink for rank subtext
local SUB_R, SUB_G, SUB_B = INK_R, INK_G, INK_B

local FONT_NAME_SIZE   = 18
local FONT_SUB_SIZE    = 13

-- ── Texture UV Coordinates ───────────────────────────────────────────────
local CLASS_COORDS = {
    DEATHKNIGHT = { left=0.000488, right=0.062988, top=0.000977, bottom=0.125977 },
    DRUID       = { left=0.000488, right=0.062988, top=0.254883, bottom=0.379883 },
    HUNTER      = { left=0.000488, right=0.062988, top=0.508789, bottom=0.633789 },
    MAGE        = { left=0.000488, right=0.062988, top=0.635742, bottom=0.760742 },
    PALADIN     = { left=0.063965, right=0.126465, top=0.000977, bottom=0.125977 },
    PRIEST      = { left=0.063965, right=0.126465, top=0.127930, bottom=0.252930 },
    ROGUE       = { left=0.063965, right=0.126465, top=0.254883, bottom=0.379883 },
    SHAMAN      = { left=0.063965, right=0.126465, top=0.381836, bottom=0.506836 },
    WARLOCK     = { left=0.063965, right=0.126465, top=0.508789, bottom=0.633789 },
    WARRIOR     = { left=0.063965, right=0.126465, top=0.635742, bottom=0.760742 },
}

-- Texture atlas coordinates (assets courtesy of DragonUI)
local ATLAS = {
    cardBackplate   = { file = P .. "5506565-spellbook-items.blp", left=0.311523, right=0.561523, top=0.305664, bottom=0.368164 },
    listBackplate   = { file = P .. "5506565-spellbook-items.blp", left=0.000977, right=0.309570, top=0.305664, bottom=0.409180 },
    divider         = { file = P .. "5506565-spellbook-items.blp", left=0.249023, right=0.890625, top=0.411133, bottom=0.421875 },
    iconFrame       = { file = P .. "5506565-spellbook-items.blp", left=0.854492, right=0.989258, top=0.136719, bottom=0.264648 },
    iconHover       = { file = P .. "5506565-spellbook-items.blp", left=0.000977, right=0.129883, top=0.666992, bottom=0.789062 },
    passiveCircle   = { file = P .. "4556093-talents.blp",         left=0.106934, right=0.131348, top=0.555664, bottom=0.604492 },

    -- Red close button states (4698972-redbutton-exit-2x.blp)
    closeNormal     = { file = P .. "4698972-redbutton-exit-2x.blp", left=0.152344, right=0.292969, top=0.007812, bottom=0.304688 },
    closePressed    = { file = P .. "4698972-redbutton-exit-2x.blp", left=0.152344, right=0.292969, top=0.632812, bottom=0.929688 },
    closeDisabled   = { file = P .. "4698972-redbutton-exit-2x.blp", left=0.152344, right=0.292969, top=0.320312, bottom=0.617188 },
    closeHighlight  = { file = P .. "4698972-redbutton-exit-2x.blp", left=0.449219, right=0.589844, top=0.007812, bottom=0.304688 },

    -- Top category tabs (4707839-uiframe-tab.blp)
    tabLeft         = { file = P .. "4707839-uiframe-tab.blp", left=0.015625, right=0.562500, top=0.816406, bottom=0.957031 },
    tabMiddle       = { file = P .. "4707839-uiframe-tab.blp", left=0.000000, right=0.015625, top=0.175781, bottom=0.316406 },
    tabRight        = { file = P .. "4707839-uiframe-tab.blp", left=0.015625, right=0.593750, top=0.667969, bottom=0.808594 },
    activeTabLeft   = { file = P .. "4707839-uiframe-tab.blp", left=0.015625, right=0.562500, top=0.496094, bottom=0.660156 },
    activeTabMiddle = { file = P .. "4707839-uiframe-tab.blp", left=0.000000, right=0.015625, top=0.003906, bottom=0.167969 },
    activeTabRight  = { file = P .. "4707839-uiframe-tab.blp", left=0.015625, right=0.593750, top=0.324219, bottom=0.488281 },

    -- Metal Chrome NineSlice (2406979, 2406987, 2406984)
    metalCornerTL   = { file = P .. "2406979-uiframe-metal-corners.blp",    left=0.001953, right=0.294922, top=0.298828, bottom=0.591797 },
    metalCornerTR   = { file = P .. "2406979-uiframe-metal-corners.blp",    left=0.595703, right=0.888672, top=0.001953, bottom=0.294922 },
    metalCornerBL   = { file = P .. "2406979-uiframe-metal-corners.blp",    left=0.298828, right=0.423828, top=0.298828, bottom=0.423828 },
    metalCornerBR   = { file = P .. "2406979-uiframe-metal-corners.blp",    left=0.427734, right=0.552734, top=0.298828, bottom=0.423828 },
    metalEdgeTop    = { file = P .. "2406987-uiframe-metal-edges-horiz.blp", left=0.000000, right=1.000000, top=0.003906, bottom=0.589844 },
    metalEdgeBot    = { file = P .. "2406987-uiframe-metal-edges-horiz.blp", left=0.000000, right=0.500000, top=0.597656, bottom=0.847656 },
    metalEdgeLeft   = { file = P .. "2406984-uiframe-metal-edges-vert.blp",  left=0.001953, right=0.294922, top=0.000000, bottom=1.000000 },
    metalEdgeRight  = { file = P .. "2406984-uiframe-metal-edges-vert.blp",  left=0.298828, right=0.591797, top=0.000000, bottom=1.000000 },
}

local function applyAtlas(tex, info)
    if not (tex and info) then return end
    tex:SetTexture(info.file)
    tex:SetTexCoord(info.left, info.right, info.top, info.bottom)
end

-- ── WotLK Class Definitions & General Spells ──────────────────────────────
local CLASS_DISPLAY_NAMES = {
    WARRIOR     = "Warrior",
    PALADIN     = "Paladin",
    HUNTER      = "Hunter",
    ROGUE       = "Rogue",
    PRIEST      = "Priest",
    DEATHKNIGHT = "Death Knight",
    SHAMAN      = "Shaman",
    MAGE        = "Mage",
    WARLOCK     = "Warlock",
    DRUID       = "Druid",
}

local GENERAL_KEYWORDS = {
    -- Basic Attacks & Specs
    "Auto Attack", "Attack", "Attacking", "Shoot", "Throw",
    "Activate Primary Spec", "Activate Secondary Spec",

    -- Racials
    "Arcane Torrent", "Blood Fury", "Berserking", "Will of the Forsaken", "War Stomp",
    "Stoneform", "Escape Artist", "Every Man for Himself", "Shadowmeld", "Gift of the Naaru",

    -- Professions & Gathering
    "Enchanting", "Disenchant", "Engineering", "First Aid", "Jewelcrafting", "Alchemy",
    "Blacksmithing", "Mining", "Herbalism", "Skinning", "Tailoring", "Leatherworking",
    "Cooking", "Fishing", "Inscription", "Prospecting", "Milling", "Runeforging",

    -- Server/Bot Interactions & System Utilities
    "Closing", "Duel", "Grovel", "Honorless Target", "Opening", "Opening - No Text",
    "Remove Insignia", "Stuck", "Summon Friend", "Battle Chicken", "Mechanical Dragonling",
    "Gnomish", "Goblin",
}

local function isGeneralSpell(name)
    if not name then return false end
    for _, kw in ipairs(GENERAL_KEYWORDS) do
        if name:find(kw, 1, true) then return true end
    end
    return false
end

-- ── Card Factory ─────────────────────────────────────────────────────────
local function createCard(parent, index)
    local pName = (parent and parent.GetName and parent:GetName()) or "CleanBotSpellCard"
    local card = CreateFrame("Button", pName .. "_" .. index, parent)
    card:SetSize(CARD_W, CARD_H)
    card:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Backplate (DragonUI spellbook-item-backplate)
    -- Inactive: transparent (0); hover: full opacity glow.
    local bg = card:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    applyAtlas(bg, ATLAS.cardBackplate)
    bg:SetAlpha(0)
    card.bg = bg

    -- Icon Slot (40x40 fixed container anchored LEFT)
    local iconSlot = CreateFrame("Frame", nil, card)
    iconSlot:SetSize(ICON_BTN, ICON_BTN)
    iconSlot:SetPoint("LEFT", card, "LEFT", 0, 0)
    card.iconSlot = iconSlot

    -- Square Icon (Active spells)
    local icon = iconSlot:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SZ, ICON_SZ)
    icon:SetPoint("CENTER", iconSlot, "CENTER", 0, 0)
    icon:SetTexCoord(0, 1, 0, 1)
    card.icon = icon

    -- Round Icon (Passive spells)
    local iconRound = iconSlot:CreateTexture(nil, "ARTWORK")
    iconRound:SetSize(PASSIVE_ICON_SZ, PASSIVE_ICON_SZ)
    iconRound:SetPoint("CENTER", iconSlot, "CENTER", 0, 0)
    iconRound:Hide()
    card.iconRound = iconRound

    -- Decorative Border (Active square overhang or Passive round circle)
    local border = iconSlot:CreateTexture(nil, "OVERLAY", nil, 1)
    card.border = border

    -- Icon Hover Highlight (Gold glow on hover)
    local highlight = iconSlot:CreateTexture(nil, "OVERLAY", nil, 2)
    applyAtlas(highlight, ATLAS.iconHover)
    highlight:SetAllPoints(border)
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.35)
    highlight:Hide()
    card.highlight = highlight

    -- Active Spell Glow (Sparkles / marching border for active buffs / auras)
    local activeGlow = iconSlot:CreateTexture(nil, "OVERLAY", nil, 3)
    applyAtlas(activeGlow, ATLAS.iconHover)
    activeGlow:SetAllPoints(border)
    activeGlow:SetBlendMode("ADD")
    activeGlow:SetVertexColor(1, 0.9, 0.4, 0.6)
    activeGlow:Hide()
    card.activeGlow = activeGlow

    -- Spell Title (Dark Medieval Ink, No Shadow)
    local name = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    name:SetJustifyH("LEFT")
    name:SetPoint("TOPLEFT", iconSlot, "TOPRIGHT", 10, -2)
    name:SetPoint("RIGHT", card, "RIGHT", -4, 0)
    name:SetTextColor(INK_R, INK_G, INK_B)
    name:SetShadowColor(0, 0, 0, 0)
    if name.SetWordWrap then name:SetWordWrap(true) end
    if name.SetMaxLines then name:SetMaxLines(2) end
    do
        local f, _, g = name:GetFont()
        if f and FONT_NAME_SIZE > 0 then name:SetFont(f, FONT_NAME_SIZE, g) end
    end
    card.name = name

    -- Spell Rank / Subtext (Dark Medieval Ink, Same as Name, No Shadow)
    local subtext = card:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    subtext:SetJustifyH("LEFT")
    subtext:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
    subtext:SetPoint("RIGHT", card, "RIGHT", -4, 0)
    subtext:SetTextColor(SUB_R, SUB_G, SUB_B)
    subtext:SetShadowColor(0, 0, 0, 0)
    do
        local f, _, g = subtext:GetFont()
        if f and FONT_SUB_SIZE > 0 then subtext:SetFont(f, FONT_SUB_SIZE, g) end
    end
    card.subtext = subtext

    -- Interactive Hover State
    card:SetScript("OnEnter", function(self)
        self.bg:SetAlpha(1.0)
        self.highlight:Show()

        if not self.spellId then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("spell:" .. self.spellId)
        if not self.isPassive then
            local f = self.bookFrame or NS.botSpellbookFrame or (self:GetParent() and self:GetParent():GetParent() and self:GetParent():GetParent():GetParent())
            local bName = (f and (f.botName or f.botKey)) or "bot"
            local pName = UnitName("player") or "player"

            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff00ff00Left-Click:|r Cast on " .. bName .. " (self)", 0.2, 1, 0.2)
            GameTooltip:AddLine("|cff00ff00Right-Click:|r Cast on " .. pName .. " (you)", 0.2, 1, 0.2)
        end
        GameTooltip:Show()
    end)

    card:SetScript("OnLeave", function(self)
        self.bg:SetAlpha(0)
        self.highlight:Hide()
        GameTooltip:Hide()
    end)

    -- Click to order cast (Left = self, Right = player)
    card:SetScript("OnClick", function(self, button)
        if self.isPassive or not self.spellId then return end
        local f = self.bookFrame or NS.botSpellbookFrame or (self:GetParent() and self:GetParent():GetParent() and self:GetParent():GetParent():GetParent())
        local botName = f and (f.botName or f.botKey)
        if not botName then return end

        local targetName = (button == "RightButton") and (UnitName("player") or "player") or botName
        local spellRef = (self.spellLink and self.spellLink ~= "" and self.spellLink) or self.spellName or ("spell:" .. self.spellId)

        local cmd = "cast " .. spellRef .. " on " .. targetName
        NS.CB_SendBotCommand(botName, cmd)
        if NS.CB_Print then
            NS.CB_Print(botName .. " casting: " .. spellRef .. " on " .. targetName)
        end
    end)

    card.bookFrame = (parent and parent:GetParent() and parent:GetParent():GetParent()) or NS.botSpellbookFrame
    card:Hide()
    return card
end

-- ── Section Header Factory ───────────────────────────────────────────────
local function createHeader(parent, index)
    local pName = (parent and parent.GetName and parent:GetName()) or "CleanBotSpellHeader"
    local h = CreateFrame("Frame", pName .. "_" .. index, parent)
    h:SetSize(SPAN_W, 46)

    -- Soft Header Plate (DragonUI spellbook-list-backplate)
    local plate = h:CreateTexture(nil, "BACKGROUND")
    applyAtlas(plate, ATLAS.listBackplate)
    plate:SetSize(416, 106)
    plate:SetPoint("LEFT", h, "LEFT", -85, 12)
    plate:SetAlpha(0.65)
    h.plate = plate

    -- Section Title Text (Dark medieval ink, large bold)
    local text = h:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
    text:SetJustifyH("LEFT")
    text:SetPoint("TOPLEFT", h, "TOPLEFT", 6, -2)
    text:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", -40, 14)
    text:SetTextColor(INK_R, INK_G, INK_B)
    text:SetShadowColor(0, 0, 0, 0)
    h.text = text

    -- Decorative Horizontal Divider (DragonUI spellbook-divider)
    local divider = h:CreateTexture(nil, "ARTWORK")
    applyAtlas(divider, ATLAS.divider)
    divider:SetHeight(11)
    divider:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT", -20, 2)
    divider:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", -40, 2)
    h.divider = divider

    h:Hide()
    return h
end

-- ── Flow Layout Calculator ───────────────────────────────────────────────
local function layoutElements(elements)
    local R = ROWS_PER_PAGE
    local p, r, c = 0, 0, 0

    local function advanceRow()
        r = r + 1
        if r >= R then
            r = 0
            p = p + 1
        end
    end

    for _, el in ipairs(elements) do
        if el.kind == "header" then
            if c > 0 then
                c = 0
                advanceRow()
            end
            el.p, el.r, el.c = p, r, 0
            advanceRow()
            c = 0
        else
            el.p, el.r, el.c = p, r, c
            c = c + 1
            if c >= GRID_COLS then
                c = 0
                advanceRow()
            end
        end
    end

    local maxPage = 0
    for _, el in ipairs(elements) do
        if el.p and el.p > maxPage then maxPage = el.p end
    end
    local totalSpreads = math.max(1, math.ceil((maxPage + 1) / 2))
    return totalSpreads
end

-- Map element coordinate (p = page index 0-based, r = row, c = col) to host frame point
local function getElementPoint(p, r, c)
    local y = VIEW_TOP - (r * ROW_H)
    if (p % 2) == 0 then
        -- Left page: anchored from TOPLEFT
        local x = VIEW1_X + (c * (CARD_W + CARD_XPAD))
        return "TOPLEFT", "TOPLEFT", x, y
    else
        -- Right page: anchored from TOPRIGHT
        local x = (VIEW2_X - VIEW_W) + (c * (CARD_W + CARD_XPAD))
        return "TOPLEFT", "TOPRIGHT", x, y
    end
end

-- ── 3-Slice Wooden Header Tab Factory ────────────────────────────────────
local function createCategoryTab(parent, index, label, onClick)
    local t = CreateFrame("Button", parent:GetName() .. "_Tab" .. index, parent)
    t:SetHeight(TAB_H_INACTIVE)
    t:SetID(index)
    t:SetFrameLevel((parent:GetFrameLevel() or 1) + 10)

    -- Background textures (offsets -3 / +7 for seamless tab joining)
    local left = t:CreateTexture(nil, "BACKGROUND")
    left:SetPoint("TOPLEFT", t, "TOPLEFT", -3, 0)
    left:SetSize(35, TAB_H_INACTIVE)
    applyAtlas(left, ATLAS.tabLeft)
    t.left = left

    local right = t:CreateTexture(nil, "BACKGROUND")
    right:SetPoint("TOPRIGHT", t, "TOPRIGHT", 7, 0)
    right:SetSize(37, TAB_H_INACTIVE)
    applyAtlas(right, ATLAS.tabRight)
    t.right = right

    local mid = t:CreateTexture(nil, "BACKGROUND")
    mid:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
    mid:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0)
    mid:SetHorizTile(true)
    mid:SetHeight(TAB_H_INACTIVE)
    applyAtlas(mid, ATLAS.tabMiddle)
    t.mid = mid

    -- Custom tab highlight (ADD blend mode, 0.4 alpha)
    local hlLeft = t:CreateTexture(nil, "HIGHLIGHT")
    applyAtlas(hlLeft, ATLAS.tabLeft)
    hlLeft:SetSize(35, TAB_H_INACTIVE)
    hlLeft:SetPoint("TOPLEFT", left, "TOPLEFT", 0, 0)
    hlLeft:SetBlendMode("ADD")
    hlLeft:SetAlpha(0.4)
    t.hlLeft = hlLeft

    local hlRight = t:CreateTexture(nil, "HIGHLIGHT")
    applyAtlas(hlRight, ATLAS.tabRight)
    hlRight:SetSize(37, TAB_H_INACTIVE)
    hlRight:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, 0)
    hlRight:SetBlendMode("ADD")
    hlRight:SetAlpha(0.4)
    t.hlRight = hlRight

    local hlMid = t:CreateTexture(nil, "HIGHLIGHT")
    applyAtlas(hlMid, ATLAS.tabMiddle)
    hlMid:SetHorizTile(true)
    hlMid:SetHeight(TAB_H_INACTIVE)
    hlMid:SetPoint("TOPLEFT", hlLeft, "TOPRIGHT", 0, 0)
    hlMid:SetPoint("TOPRIGHT", hlRight, "TOPLEFT", 0, 0)
    hlMid:SetBlendMode("ADD")
    hlMid:SetAlpha(0.4)
    t.hlMid = hlMid

    local fs = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("CENTER", t, "CENTER", 0, 2)
    fs:SetTextColor(0.8, 0.8, 0.8)
    fs:SetText(label)
    t.label = fs

    function t:SetSelected(selected)
        if selected then
            applyAtlas(self.left,  ATLAS.activeTabLeft)
            applyAtlas(self.right, ATLAS.activeTabRight)
            applyAtlas(self.mid,   ATLAS.activeTabMiddle)
            self.left:ClearAllPoints()
            self.left:SetPoint("TOPLEFT", self, "TOPLEFT", -1, 0)
            self.left:SetSize(35, TAB_H_ACTIVE)
            self.right:ClearAllPoints()
            self.right:SetPoint("TOPRIGHT", self, "TOPRIGHT", 8, 0)
            self.right:SetSize(37, TAB_H_ACTIVE)
            self.mid:SetHeight(TAB_H_ACTIVE)
            self:SetHeight(TAB_H_ACTIVE)
            self.label:ClearAllPoints()
            self.label:SetPoint("CENTER", self, "CENTER", 0, -3)
            self.label:SetTextColor(1.0, 0.82, 0.0) -- Gold active text
            self.hlLeft:SetAlpha(0)
            self.hlRight:SetAlpha(0)
            self.hlMid:SetAlpha(0)
        else
            applyAtlas(self.left,  ATLAS.tabLeft)
            applyAtlas(self.right, ATLAS.tabRight)
            applyAtlas(self.mid,   ATLAS.tabMiddle)
            self.left:ClearAllPoints()
            self.left:SetPoint("TOPLEFT", self, "TOPLEFT", -3, 0)
            self.left:SetSize(35, TAB_H_INACTIVE)
            self.right:ClearAllPoints()
            self.right:SetPoint("TOPRIGHT", self, "TOPRIGHT", 7, 0)
            self.right:SetSize(37, TAB_H_INACTIVE)
            self.mid:SetHeight(TAB_H_INACTIVE)
            self:SetHeight(TAB_H_INACTIVE)
            self.label:ClearAllPoints()
            self.label:SetPoint("CENTER", self, "CENTER", 0, 2)
            if self.classColor then
                self.label:SetTextColor(self.classColor.r, self.classColor.g, self.classColor.b)
            else
                self.label:SetTextColor(0.8, 0.8, 0.8)   -- Inactive grey/white
            end
            self.hlLeft:SetAlpha(0.4)
            self.hlRight:SetAlpha(0.4)
            self.hlMid:SetAlpha(0.4)
        end
    end

    t:SetScript("OnClick", function(self)
        if onClick then onClick(self:GetID()) end
    end)

    -- Auto width based on text length
    local tw = fs:GetStringWidth() or 30
    t:SetWidth(math.max(TAB_MIN_W, tw + TAB_TEXT_PAD))
    t:SetSelected(false)
    t:Show()
    return t
end

-- ── Party Bot Query Helper ────────────────────────────────────────────────
local function getPartyBotList()
    local list = {}
    local seen = {}

    -- 1. Direct live group members check via NS.CB_ForEachGroupMember
    if NS.CB_ForEachGroupMember then
        NS.CB_ForEachGroupMember(function(unit, name)
            if name and UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local key = strlower(name)
                if not seen[key] then
                    seen[key] = true
                    local _, class = UnitClass(unit)
                    local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
                    local botClass = (entry and entry.class) or class or "WARRIOR"
                    local botName = (entry and entry.name) or name
                    table.insert(list, { key = key, name = botName, class = botClass })
                end
            end
        end)
    end

    -- 2. Fallback to NS.desiredBots if group enumeration returned nothing
    if #list == 0 and NS.desiredBots and #NS.desiredBots > 0 then
        for _, d in ipairs(NS.desiredBots) do
            if d.key and not seen[d.key] then
                seen[d.key] = true
                local entry = CleanBot_PartyBots and CleanBot_PartyBots[d.key]
                local botClass = (entry and entry.class) or d.class or "WARRIOR"
                local botName = (entry and entry.name) or d.name or d.key
                table.insert(list, { key = d.key, name = botName, class = botClass })
            end
        end
    end

    return list
end

local function CB_UpdateBotTabs(f)
    if not (f and f.host) then return end
    local botList = getPartyBotList()
    local found = false
    for _, b in ipairs(botList) do
        if b.key == f.botKey then found = true; break end
    end
    if not found and f.botKey then
        local entry = CleanBot_PartyBots and CleanBot_PartyBots[f.botKey]
        table.insert(botList, 1, {
            key   = f.botKey,
            name  = (entry and entry.name) or f.botName or f.botKey,
            class = (entry and entry.class) or "WARRIOR",
        })
    end

    f.tabBots = botList

    local prevTab = nil
    for idx, bot in ipairs(botList) do
        local tab = f.tabs[idx]
        if not tab then
            tab = createCategoryTab(f.host, idx, bot.name, function(tabId)
                local b = f.tabBots and f.tabBots[tabId]
                if b and b.key and b.key ~= f.botKey then
                    if f.SelectBot then
                        f:SelectBot(b.key, b.name)
                    end
                end
            end)
            f.tabs[idx] = tab
        end

        tab.botKey = bot.key
        tab.classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[bot.class]
        tab.label:SetText(bot.name)

        local tw = tab.label:GetStringWidth() or 30
        tab:SetWidth(math.max(TAB_MIN_W, tw + TAB_TEXT_PAD))

        tab:ClearAllPoints()
        if prevTab then
            tab:SetPoint("TOPLEFT", prevTab, "TOPRIGHT", TAB_GAP, 0)
        else
            tab:SetPoint("TOPLEFT", f.host, "TOPLEFT", 70, -2)
        end

        tab:SetSelected(bot.key == f.botKey)
        tab:Show()
        prevTab = tab
    end

    for idx = #botList + 1, #f.tabs do
        f.tabs[idx]:Hide()
    end
end

-- ── Rank Collapse Helper (collapses lower ranks to highest learned) ──────
local function collapseRanks(list)
    local out, idxByName = {}, {}
    for _, sp in ipairs(list) do
        local rankNum = tonumber((sp.rank or ""):match("(%d+)"))
        local prev = rankNum and idxByName[sp.name]
        if prev then
            if rankNum > (out[prev]._rank or 0) then
                sp._rank = rankNum
                out[prev] = sp
            end
        else
            sp._rank = rankNum
            table.insert(out, sp)
            if rankNum then idxByName[sp.name] = #out end
        end
    end
    return out
end

-- ── Spellbook Renderer ───────────────────────────────────────────────────
local function CB_RenderSpellbookCards(f)
    local key = f.botKey
    if not key then return end
    local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
    local spells = entry and entry.spells or {}
    local botClass = (entry and entry.class) or "PALADIN"

    -- 1. Build flattened elements based on search query
    local searchQuery = (f.searchQuery or ""):lower()
    local elements = {}

    -- Section 1: General abilities (Racials, basic attacks, professions)
    local generalSpells = {}
    for _, sp in ipairs(spells) do
        local spName = sp.name or ""
        if isGeneralSpell(spName) and (searchQuery == "" or spName:lower():find(searchQuery, 1, true)) then
            table.insert(generalSpells, sp)
        end
    end
    if #generalSpells > 0 then
        generalSpells = collapseRanks(generalSpells)
        table.insert(elements, { kind = "header", label = "General" })
        for _, sp in ipairs(generalSpells) do
            table.insert(elements, { kind = "card", spell = sp })
        end
    end

    -- Section 2: Class Spells (e.g. Paladin, Warrior, Mage, etc.)
    local classSpells = {}
    for _, sp in ipairs(spells) do
        local spName = sp.name or ""
        if not isGeneralSpell(spName) and (searchQuery == "" or spName:lower():find(searchQuery, 1, true)) then
            table.insert(classSpells, sp)
        end
    end

    if #classSpells > 0 then
        classSpells = collapseRanks(classSpells)
        local classLabel = CLASS_DISPLAY_NAMES[botClass] or botClass
        table.insert(elements, { kind = "header", label = classLabel })
        for _, sp in ipairs(classSpells) do
            table.insert(elements, { kind = "card", spell = sp })
        end
    end

    -- 2. Calculate pagination with flow layout
    local totalSpreads = layoutElements(elements)
    f.totalSpreads = totalSpreads
    if f.currentSpread > totalSpreads then f.currentSpread = totalSpreads end
    if f.currentSpread < 1 then f.currentSpread = 1 end

    local currentSpreadIdx = f.currentSpread - 1  -- 0-based
    local cardPoolIdx = 0
    local headerPoolIdx = 0

    -- 3. Render visible elements on the current two-page spread
    for _, el in ipairs(elements) do
        local onCurrentSpread = (math.floor((el.p or 0) / 2) == currentSpreadIdx)

        if el.kind == "header" then
            headerPoolIdx = headerPoolIdx + 1
            local header = f.headers[headerPoolIdx]
            if not header then
                header = createHeader(f.content, headerPoolIdx)
                f.headers[headerPoolIdx] = header
            end

            if onCurrentSpread then
                local pt, rpt, x, y = getElementPoint(el.p, el.r, 0)
                header:ClearAllPoints()
                header:SetPoint(pt, f.content, rpt, x, y + 10)
                header.text:SetText(el.label or "")
                header:Show()
            else
                header:Hide()
            end

        elseif el.kind == "card" then
            cardPoolIdx = cardPoolIdx + 1
            local card = f.cards[cardPoolIdx]
            if not card then
                card = createCard(f.content, cardPoolIdx)
                f.cards[cardPoolIdx] = card
            end
            card.bookFrame = f

            if onCurrentSpread then
                local sp = el.spell
                card.spellId   = sp.id
                card.spellName = sp.name
                card.spellLink = sp.link
                card.isPassive = sp.isPassive

                card.name:SetText(sp.name or "Unknown")

                -- Passive vs Active styling
                if sp.isPassive then
                    card.icon:Hide()
                    card.iconRound:Show()
                    applyAtlas(card.border, ATLAS.passiveCircle)
                    card.border:ClearAllPoints()
                    card.border:SetAllPoints(card.iconSlot)
                    card.border:SetVertexColor(0.85, 0.85, 0.85)

                    if SetPortraitToTexture then
                        SetPortraitToTexture(card.iconRound, sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                    else
                        card.iconRound:SetTexture(sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                    end

                    card.subtext:SetText(sp.rank or "")
                    card.activeGlow:Hide()
                else
                    card.iconRound:Hide()
                    card.icon:Show()
                    card.icon:SetTexture(sp.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                    applyAtlas(card.border, ATLAS.iconFrame)
                    card.border:ClearAllPoints()
                    card.border:SetPoint("TOPLEFT", card.iconSlot, "TOPLEFT", -11, 1)
                    card.border:SetPoint("BOTTOMRIGHT", card.iconSlot, "BOTTOMRIGHT", 1, -7)
                    card.border:SetVertexColor(1, 1, 1)

                    if sp.rank and sp.rank ~= "" then
                        card.subtext:SetText(sp.rank)
                    else
                        card.subtext:SetText("")
                    end

                    -- Aura / active ability indicator
                    local isAura = sp.name and (sp.name:find("Aura") or sp.name:find("Blessing") or sp.name:find("Seal"))
                    if isAura then
                        card.activeGlow:Show()
                    else
                        card.activeGlow:Hide()
                    end
                end

                local pt, rpt, x, y = getElementPoint(el.p, el.r, el.c)
                card:ClearAllPoints()
                card:SetPoint(pt, f.content, rpt, x, y)
                card.bg:SetAlpha(0)
                card.highlight:Hide()
                card:Show()
            else
                card:Hide()
            end
        end
    end

    -- Hide remaining unused frames in the pool
    for i = cardPoolIdx + 1, #f.cards do f.cards[i]:Hide() end
    for i = headerPoolIdx + 1, #f.headers do f.headers[i]:Hide() end

    -- 4. Update Pagination controls
    f.pageLabel:SetText(string.format("Page %d/%d", f.currentSpread, totalSpreads))
    if f.currentSpread <= 1 then f.prevBtn:Disable() else f.prevBtn:Enable() end
    if f.currentSpread >= totalSpreads then f.nextBtn:Disable() else f.nextBtn:Enable() end

    -- 5. Synchronize Bot Tabs
    CB_UpdateBotTabs(f)

    -- 6. Loading overlay state
    local isBridge = not NS.CB_EffectiveBridgeState or (NS.CB_EffectiveBridgeState() == "present")
    if not isBridge and not (entry and entry.spells and #entry.spells > 0) then
        f.loadingLabel:SetText("|cffff4444MultiBot Bridge Required|r\n\n|cffffffffThis feature requires the |cffffd200mod-multibot-bridge|r\nserver module to read spells.|r")
        f.loadingOverlay:Show()
    elseif entry and entry.awaitingSpellbook then
        f.loadingLabel:SetText("Fetching spells from " .. (entry.name or f.botName) .. "...")
        f.loadingOverlay:Show()
    else
        f.loadingOverlay:Hide()
    end
end

NS.CB_RenderSpellbook = function(key)
    local f = NS.botSpellbookFrame
    if f and f:IsShown() and f.botKey == key then
        CB_RenderSpellbookCards(f)
    end
end

-- ── Main Spellbook Frame Construction ────────────────────────────────────
NS.CB_GetSpellbookFrame = function(key, botName)
    local f = NS.botSpellbookFrame
    if f then
        if f.SelectBot then f:SelectBot(key, botName) end
        return f
    end

    f = CreateFrame("Frame", "CleanBotSpellbookFrame", UIParent)
    NS.CB_RegisterRootFrame(f)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetScale(UI_SCALE)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    tinsert(UISpecialFrames, f:GetName())
    f:Hide()

    f:RegisterEvent("PARTY_MEMBERS_CHANGED")
    f:RegisterEvent("RAID_ROSTER_UPDATE")
    f:SetScript("OnEvent", function(self, event)
        if (event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE") and self:IsShown() then
            CB_UpdateBotTabs(self)
        end
    end)

    f.botKey        = key
    f.botName       = botName
    f.currentSpread = 1
    f.cards         = {}
    f.headers       = {}
    f.tabs          = {}
    f.searchQuery   = ""

    -- ── Dark Background Tint ─────────────────────────────────────────────
    local tint = f:CreateTexture(nil, "BACKGROUND")
    tint:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -22)
    tint:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    tint:SetTexture(0.04, 0.04, 0.05, 1)
    f.bgTint = tint

    -- ── Tier 2 Content Host (Inset 22px under the metal chrome title bar) ─
    local host = CreateFrame("Frame", f:GetName() .. "_Host", f)
    host:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -22)
    host:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    host:SetFrameLevel((f:GetFrameLevel() or 1) + 1)
    f.host = host

    -- Top Wooden Header Beam (5834697-bg-header.blp)
    local headerBg = host:CreateTexture(nil, "BORDER", nil, 0)
    headerBg:SetPoint("TOPLEFT", host, "TOPLEFT", 8, 0)
    headerBg:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, 0)
    headerBg:SetHeight(HEADER_H)
    headerBg:SetTexture(P .. "5834697-bg-header.blp")
    headerBg:SetTexCoord(0, 1, 0, 1)
    f.headerBg = headerBg

    -- Left Parchment Page (5834697-bg-left.blp)
    local leftBg = host:CreateTexture(nil, "BACKGROUND", nil, -2)
    leftBg:SetPoint("TOPLEFT", host, "TOPLEFT", 0, PAGES_TOP)
    leftBg:SetPoint("BOTTOMRIGHT", host, "BOTTOM", -1, PAGES_BOT)
    leftBg:SetTexture(P .. "5834697-bg-left.blp")
    leftBg:SetTexCoord(0, 1, 0, 1)
    f.leftBg = leftBg

    -- Right Parchment Page (5834697-bg-right.blp)
    local rightBg = host:CreateTexture(nil, "BACKGROUND", nil, -2)
    rightBg:SetPoint("TOPLEFT", host, "TOP", 1, PAGES_TOP)
    rightBg:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, PAGES_BOT)
    rightBg:SetTexture(P .. "5834697-bg-right.blp")
    rightBg:SetTexCoord(0, 1, 0, 1)
    f.rightBg = rightBg

    -- Center Spine Ribbon (5834697-bg-ribbon.blp)
    local ribbon = host:CreateTexture(nil, "OVERLAY", nil, -1)
    ribbon:SetSize(RIBBON_W, RIBBON_H)
    ribbon:SetPoint("TOP", host, "TOP", RIBBON_X, PAGES_TOP)
    ribbon:SetTexture(P .. "5834697-bg-ribbon.blp")
    ribbon:SetTexCoord(0, 1, 0, 1)
    f.ribbon = ribbon

    -- ── Wooden Header Band Controls (Right side: Refresh & Search) ────────
    local refreshBtn = CreateFrame("Button", nil, host)
    refreshBtn:SetSize(22, 22)
    refreshBtn:SetPoint("TOPRIGHT", host, "TOPRIGHT", -14, -16)
    refreshBtn:SetFrameLevel((host:GetFrameLevel() or 1) + 10)
    local rfIcon = refreshBtn:CreateTexture(nil, "ARTWORK")
    rfIcon:SetAllPoints()
    rfIcon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
    refreshBtn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    f.refreshBtn = refreshBtn

    local searchBox = CreateFrame("EditBox", f:GetName() .. "_Search", host)
    searchBox:SetSize(180, 26)
    searchBox:SetPoint("RIGHT", refreshBtn, "LEFT", -8, 0)
    searchBox:SetFrameLevel((host:GetFrameLevel() or 1) + 10)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject("GameFontHighlightSmall")
    searchBox:SetTextInsets(24, 8, 0, 0)
    searchBox:SetMaxLetters(30)

    if searchBox.SetBackdrop then
        searchBox:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        searchBox:SetBackdropColor(0.05, 0.05, 0.07, 0.8)
        searchBox:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    end

    local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
    searchIcon:SetSize(14, 14)
    searchIcon:SetPoint("LEFT", searchBox, "LEFT", 5, 0)
    searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")

    local placeholder = searchBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", searchBox, "LEFT", 24, 0)
    placeholder:SetText("Search")
    searchBox.placeholder = placeholder

    searchBox:SetScript("OnTextChanged", function(self)
        local txt = self:GetText() or ""
        if txt == "" then
            placeholder:Show()
        else
            placeholder:Hide()
        end
        f.searchQuery = txt
        f.currentSpread = 1
        CB_RenderSpellbookCards(f)
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
    f.searchBox = searchBox

    -- ── Tier 1 Metal Chrome NineSlice & Frame Chrome ───────────────────────
    local ns = CreateFrame("Frame", f:GetName() .. "_NineSlice", f)
    ns:SetAllPoints(f)
    ns:SetFrameLevel((f:GetFrameLevel() or 1) + 6)
    f.NineSlice = ns

    -- Metal Corners (2406979)
    local cTL = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    cTL:SetSize(75, 75)
    cTL:SetPoint("TOPLEFT", f, "TOPLEFT", -13, 16)
    applyAtlas(cTL, ATLAS.metalCornerTL)

    local cTR = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    cTR:SetSize(75, 75)
    cTR:SetPoint("TOPRIGHT", f, "TOPRIGHT", 4, 16)
    applyAtlas(cTR, ATLAS.metalCornerTR)

    local cBL = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    cBL:SetSize(32, 32)
    cBL:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -13, -3)
    applyAtlas(cBL, ATLAS.metalCornerBL)

    local cBR = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    cBR:SetSize(32, 32)
    cBR:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -3)
    applyAtlas(cBR, ATLAS.metalCornerBR)

    -- Metal Edges (2406987 & 2406984)
    local eTop = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    eTop:SetHeight(75)
    eTop:SetPoint("TOPLEFT", cTL, "TOPRIGHT", 0, 0)
    eTop:SetPoint("TOPRIGHT", cTR, "TOPLEFT", 0, 0)
    eTop:SetHorizTile(true)
    applyAtlas(eTop, ATLAS.metalEdgeTop)

    local eBot = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    eBot:SetHeight(32)
    eBot:SetPoint("BOTTOMLEFT", cBL, "BOTTOMRIGHT", 0, 0)
    eBot:SetPoint("BOTTOMRIGHT", cBR, "BOTTOMLEFT", 0, 0)
    eBot:SetHorizTile(true)
    applyAtlas(eBot, ATLAS.metalEdgeBot)

    local eLeft = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    eLeft:SetWidth(75)
    eLeft:SetPoint("TOPLEFT", cTL, "BOTTOMLEFT", 0, 0)
    eLeft:SetPoint("BOTTOMLEFT", cBL, "TOPLEFT", 0, 0)
    eLeft:SetVertTile(true)
    applyAtlas(eLeft, ATLAS.metalEdgeLeft)

    local eRight = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    eRight:SetWidth(75)
    eRight:SetPoint("TOPRIGHT", cTR, "BOTTOMRIGHT", 0, 0)
    eRight:SetPoint("BOTTOMRIGHT", cBR, "TOPRIGHT", 0, 0)
    eRight:SetVertTile(true)
    applyAtlas(eRight, ATLAS.metalEdgeRight)

    -- Circular Class Portrait Badge (Seated inside the cTL ring)
    local portrait = ns:CreateTexture(nil, "ARTWORK", nil, 1)
    portrait:SetSize(60, 60)
    portrait:SetPoint("TOPLEFT", f, "TOPLEFT", -5, 8)
    portrait:SetTexture(P .. "1662186-classicon.blp")
    f.portrait = portrait

    -- Window Title (Centered on the top metal chrome bar)
    local title = ns:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -4)
    f.title = title

    -- Red Modern Close Button (Top-Right on the metal bar)
    local closeBtn = CreateFrame("Button", "CleanBotSpellbookClose", f)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, 0)
    closeBtn:SetFrameLevel((f:GetFrameLevel() or 1) + 20)

    local nt = closeBtn:CreateTexture(nil, "ARTWORK"); nt:SetAllPoints(); applyAtlas(nt, ATLAS.closeNormal); closeBtn:SetNormalTexture(nt)
    local pt = closeBtn:CreateTexture(nil, "ARTWORK"); pt:SetAllPoints(); applyAtlas(pt, ATLAS.closePressed); closeBtn:SetPushedTexture(pt)
    local ht = closeBtn:CreateTexture(nil, "HIGHLIGHT"); ht:SetAllPoints(); applyAtlas(ht, ATLAS.closeHighlight); closeBtn:SetHighlightTexture(ht)
    closeBtn:SetScript("OnClick", function() f:Hide() end)
    f.closeBtn = closeBtn

    -- ── Content Area Container ───────────────────────────────────────────
    local content = CreateFrame("Frame", f:GetName() .. "_Content", host)
    content:SetAllPoints(host)
    f.content = content

    -- ── Bottom-Right Pagination Controls ─────────────────────────────────
    local pageLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pageLabel:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -80, 42)
    pageLabel:SetJustifyH("RIGHT")
    pageLabel:SetTextColor(INK_R, INK_G, INK_B)
    pageLabel:SetShadowColor(0, 0, 0, 0)
    f.pageLabel = pageLabel

    local prevBtn = CreateFrame("Button", nil, host)
    prevBtn:SetSize(30, 30)
    prevBtn:SetPoint("RIGHT", pageLabel, "LEFT", -10, 0)
    prevBtn:SetNormalTexture(P .. "130869-ui-spellbookicon-prevpage-up-retail.blp")
    prevBtn:SetPushedTexture(P .. "130868-ui-spellbookicon-prevpage-down-retail.blp")
    prevBtn:SetDisabledTexture(P .. "130867-ui-spellbookicon-prevpage-disabled-retail.blp")
    prevBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    prevBtn:SetScript("OnClick", function()
        if f.currentSpread > 1 then
            f.currentSpread = f.currentSpread - 1
            CB_RenderSpellbookCards(f)
        end
    end)
    f.prevBtn = prevBtn

    local nextBtn = CreateFrame("Button", nil, host)
    nextBtn:SetSize(30, 30)
    nextBtn:SetPoint("LEFT", pageLabel, "RIGHT", 10, 0)
    nextBtn:SetNormalTexture(P .. "130866-ui-spellbookicon-nextpage-up-retail.blp")
    nextBtn:SetPushedTexture(P .. "130865-ui-spellbookicon-nextpage-down-retail.blp")
    nextBtn:SetDisabledTexture(P .. "130864-ui-spellbookicon-nextpage-disabled-retail.blp")
    nextBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    nextBtn:SetScript("OnClick", function()
        if f.currentSpread < (f.totalSpreads or 1) then
            f.currentSpread = f.currentSpread + 1
            CB_RenderSpellbookCards(f)
        end
    end)
    f.nextBtn = nextBtn

    -- ── Loading Overlay ──────────────────────────────────────────────────
    local loadingOverlay = CreateFrame("Frame", nil, f)
    loadingOverlay:SetAllPoints()
    loadingOverlay:SetFrameLevel((f:GetFrameLevel() or 1) + 25)
    loadingOverlay:EnableMouse(true)

    local lbg = loadingOverlay:CreateTexture(nil, "BACKGROUND")
    lbg:SetAllPoints()
    lbg:SetTexture("Interface\\Buttons\\WHITE8X8")
    lbg:SetVertexColor(0, 0, 0, 0.45)

    local loadingLabel = loadingOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    loadingLabel:SetPoint("CENTER", loadingOverlay, "CENTER", 0, 20)
    loadingLabel:SetTextColor(1, 0.82, 0)
    f.loadingLabel = loadingLabel
    f.loadingOverlay = loadingOverlay
    loadingOverlay:Hide()

    -- ── Bot Selection Method ─────────────────────────────────────────────
    function f:SelectBot(botKey, bName)
        if not botKey then return end
        self.botKey = botKey

        local entry = CleanBot_PartyBots and CleanBot_PartyBots[botKey]
        self.botName = (entry and entry.name) or bName or botKey
        local botClass = (entry and entry.class) or "WARRIOR"

        -- Update Title with Class Color
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[botClass]
        if c then
            self.title:SetText(string.format("|cff%02x%02x%02x%s|r's Spellbook", c.r * 255, c.g * 255, c.b * 255, self.botName))
        else
            self.title:SetText("|cffffd200" .. self.botName .. "'s Spellbook|r")
        end

        -- Update Portrait
        local cCoords = CLASS_COORDS[botClass] or CLASS_COORDS.WARRIOR
        self.portrait:SetTexCoord(cCoords.left, cCoords.right, cCoords.top, cCoords.bottom)

        -- Update Refresh Button
        NS.CB_SetTooltip(self.refreshBtn, "Refresh Spells", "Fetch fresh spell list from " .. self.botName .. ".")
        self.refreshBtn:SetScript("OnClick", function()
            if NS.CB_RequestSpellbook then
                NS.CB_RequestSpellbook(self.botKey, self.botName, true)
            end
        end)

        -- Reset spread & query
        self.currentSpread = 1
        self.searchQuery = ""
        if self.searchBox then
            self.searchBox:SetText("")
            if self.searchBox.placeholder then self.searchBox.placeholder:Show() end
        end

        -- Request spells if not yet cached
        if not (entry and entry.spells and #entry.spells > 0) then
            if NS.CB_RequestSpellbook then
                NS.CB_RequestSpellbook(self.botKey, self.botName, false)
            end
        end

        CB_RenderSpellbookCards(self)
    end

    NS.botSpellbookFrame = f
    f:SelectBot(key, botName)
    return f
end

-- ── Public Toggles ───────────────────────────────────────────────────────
NS.CB_ToggleSpellbook = function(key, botName, anchor)
    if not key then return end
    local f = NS.CB_GetSpellbookFrame(key, botName)

    if f:IsShown() and f.botKey == key then
        f:Hide()
        return
    end

    if f.SelectBot then
        f:SelectBot(key, botName)
    end

    f:ClearAllPoints()
    if anchor == "CENTER" then
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    elseif CleanBotFrame and CleanBotFrame:IsShown() then
        f:SetPoint("TOPLEFT", CleanBotFrame, "TOPRIGHT", 10, 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    end

    f:Show()

    if NS.CB_EffectiveBridgeState and NS.CB_EffectiveBridgeState() ~= "present" and NS.CB_Print then
        NS.CB_Print("Spellbook requires mod-multibot-bridge on the server.")
    end
end

--- Button factory placed on the bot's equip/model panel alongside Bag & Quest
NS.CB_CreateSpellbookButton = function(slot, model, slotSize)
    local btn = NS.CB_CreateIconButton(model, "CleanBotSpellbookBtn_" .. slot.index,
        "Interface\\Spellbook\\Spellbook-Icon", slotSize)

    -- Anchor immediately to the right of bag button
    if slot.bagBtn then
        btn:SetPoint("LEFT", slot.bagBtn, "RIGHT", 4, 0)
        btn:SetPoint("TOP",  slot.bagBtn, "TOP",   0, 0)
    else
        btn:SetPoint("LEFT", slot.equipSlots[9], "RIGHT", 6, 0)
        btn:SetPoint("TOP",  slot.equipSlots[16], "TOP",  0, 0)
    end

    -- Native Quickslot2 border
    if not NS.ElvUI_S then
        local border = btn:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        border:SetPoint("CENTER", btn, "CENTER", 0, -1)
        border:SetSize(slotSize * (64 / 37), slotSize * (64 / 37))
    end

    btn:SetScript("OnClick", function()
        local key = slot.key
        if not key then return end
        local entry = CleanBot_PartyBots[key]
        local botName = entry and entry.name or slot.name or key
        NS.CB_ToggleSpellbook(key, botName)
    end)
    NS.CB_SetTooltip(btn, function()
        local isBridge = not NS.CB_EffectiveBridgeState or (NS.CB_EffectiveBridgeState() == "present")
        return isBridge and "Spellbook" or "Spellbook (Requires Bridge)"
    end, function()
        local isBridge = not NS.CB_EffectiveBridgeState or (NS.CB_EffectiveBridgeState() == "present")
        if not isBridge then
            return "|cffff2020Server Requirement:|r\nRequires mod-multibot-bridge installed on the server."
        end
        return "View this bot's spells and abilities."
    end)

    slot.spellbookBtn = btn
end
