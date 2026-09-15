-- ============================================================
-- Professions.lua  —  Bot Professions and Crafting for CleanBot.
--
-- Texture assets courtesy of Blizzard Entertainment and
-- DragonUI / DragonUI: New Era.
--
-- Provides profession inspection, recipe navigation, and crafting dispatch:
-- - Metal NineSlice frame with circular portrait cutout
-- - Bevelled inner panels for recipe listing and schematic view
-- - Categorized collapsible recipe tree
-- - Skill-up and rank progress bar
-- - Schematic crafting view with reagent tracking and target selector
-- - Recipe filtering by learned status, difficulty, and materials
-- ============================================================

local NS = CleanBotNS

-- ── Registry ─────────────────────────────────────────────────────────────
NS.botProfessionsFrame = nil
NS.botProfessionsFrames = setmetatable({}, {
    __index = function(t, k)
        return NS.botProfessionsFrame
    end,
})

local P = "Interface\\AddOns\\CleanBot\\Textures\\Professions\\"
local S = "Interface\\AddOns\\CleanBot\\Textures\\Spellbook\\"

local CHROME_SHEET = P .. "4417031-professions-chrome-sheet.blp"
local AH_CHROME    = P .. "3046538-auctionhouse-chrome.blp"
local RED_BUTTON   = P .. "1536801-128redbutton.blp"
local CLOSE_SHEET  = S .. "4698972-redbutton-exit-2x.blp"

local INNER_CORNER = P .. "1723831-uiframe-inner.blp"
local INNER_VERT   = P .. "1723832-uiframe-inner.blp"
local INNER_HORIZ  = P .. "1723833-uiframe-inner.blp"
local ROCK_BODY    = P .. "374155-uibackground-rock.blp"

local METAL_CORNERS = S .. "2406979-uiframe-metal-corners.blp"
local METAL_VERT    = S .. "2406984-uiframe-metal-edges-vert.blp"
local METAL_HORIZ   = S .. "2406987-uiframe-metal-edges-horiz.blp"

local SCROLL_MAIN   = P .. "4331838-minimal-scrollbar.blp"
local SCROLL_MID    = P .. "4332072-minimal-scrollbar-track-middle.blp"
local SCROLL_THUMB_MID = P .. "5142784-minimal-scrollbar-small-thumb-middle.blp"
local SCROLL_THUMB_CAP = P .. "5142787-minimal-scrollbar-small.blp"

-- ── Geometry Constants ───────────────────────────────────────────────────
local FRAME_W          = 942
local FRAME_H          = 658
local UI_SCALE         = 0.72      -- ≈ 678x474 px on screen (90% del tamaño actual)

local RECIPELIST_W     = 274
local RECIPELIST_TL    = { 5, -72 }
local RECIPELIST_BL    = { 0, 5 }

local SCHEMATIC_W      = 655
local SCHEMATIC_H      = 553

local RANKBAR_W        = 453
local RANKBAR_H        = 29
local RANKBAR_TL       = { 280, -34 }

local FILL_X           = 6
local FILL_Y           = -3
local FILL_H           = 18
local FILL_MAXW        = 440

local ROW_H_CAT        = 24
local ROW_H_RECIPE     = 20
local VISIBLE_ROWS     = 25

-- ── Atlas Texture Coordinates ─────────────────────────────────────────────
local ATLAS = {
    -- Metal Corners (2406979)
    metalCornerTL   = { file = METAL_CORNERS, left = 0.001953, right = 0.294922, top = 0.298828, bottom = 0.591797 },
    metalCornerTR   = { file = METAL_CORNERS, left = 0.595703, right = 0.888672, top = 0.001953, bottom = 0.294922 },
    metalCornerBL   = { file = METAL_CORNERS, left = 0.298828, right = 0.423828, top = 0.298828, bottom = 0.423828 },
    metalCornerBR   = { file = METAL_CORNERS, left = 0.427734, right = 0.552734, top = 0.298828, bottom = 0.423828 },
    metalEdgeTop    = { file = METAL_HORIZ,   left = 0.000000, right = 1.000000, top = 0.003906, bottom = 0.589844 },
    metalEdgeBot    = { file = METAL_HORIZ,   left = 0.000000, right = 0.500000, top = 0.597656, bottom = 0.847656 },
    metalEdgeLeft   = { file = METAL_VERT,    left = 0.001953, right = 0.294922, top = 0.000000, bottom = 1.000000 },
    metalEdgeRight  = { file = METAL_VERT,    left = 0.298828, right = 0.591797, top = 0.000000, bottom = 1.000000 },

    -- TopTileStreaks decorative band
    topStreaks      = { file = INNER_HORIZ,   left = 0.000000, right = 1.000000, top = 0.007812, bottom = 0.343750 },

    -- InsetFrameTemplate inner border
    innerTL         = { file = INNER_CORNER,  left = 0.757812, right = 0.804688, top = 0.554688, bottom = 0.601562 },
    innerTR         = { file = INNER_CORNER,  left = 0.820312, right = 0.867188, top = 0.554688, bottom = 0.601562 },
    innerBL         = { file = INNER_CORNER,  left = 0.632812, right = 0.679688, top = 0.554688, bottom = 0.601562 },
    innerBR         = { file = INNER_CORNER,  left = 0.695312, right = 0.742188, top = 0.554688, bottom = 0.601562 },
    innerLeft       = { file = INNER_VERT,    left = 0.484375, right = 0.531250, top = 0.000000, bottom = 1.000000 },
    innerRight      = { file = INNER_VERT,    left = 0.562500, right = 0.609375, top = 0.000000, bottom = 1.000000 },
    innerTop        = { file = INNER_HORIZ,   left = 0.000000, right = 1.000000, top = 0.906250, bottom = 0.929688 },
    innerBot        = { file = INNER_HORIZ,   left = 0.000000, right = 1.000000, top = 0.867188, bottom = 0.890625 },

    -- Left panel summary list background
    summaryBg       = { file = CHROME_SHEET,  left = 0.000488, right = 0.131348, top = 0.257812, bottom = 0.537109 },

    -- Category header bars & collapse/expand
    catLeft         = { file = CHROME_SHEET,  left = 0.223633, right = 0.230469, top = 0.550293, bottom = 0.562988 },
    catMid          = { file = CHROME_SHEET,  left = 0.228027, right = 0.228516, top = 0.348633, bottom = 0.361328 },
    catRight        = { file = CHROME_SHEET,  left = 0.223633, right = 0.230469, top = 0.563965, bottom = 0.576660 },
    catCollapse     = { file = CHROME_SHEET,  left = 0.218262, right = 0.229004, top = 0.465332, bottom = 0.473145 },
    catExpand       = { file = CHROME_SHEET,  left = 0.217773, right = 0.228516, top = 0.475098, bottom = 0.482910 },

    -- Row selection & hover
    recipeActive    = { file = CHROME_SHEET,  left = 0.703125, right = 0.833496, top = 0.138672, bottom = 0.147949 },
    recipeHover     = { file = CHROME_SHEET,  left = 0.841309, right = 0.992188, top = 0.136230, bottom = 0.146484 },

    -- Skill-up chevrons
    skillHigh       = { file = CHROME_SHEET,  left = 0.223633, right = 0.229980, top = 0.587891, bottom = 0.595215 },
    skillMedium     = { file = CHROME_SHEET,  left = 0.223633, right = 0.229980, top = 0.604492, bottom = 0.611816 },
    skillLow        = { file = CHROME_SHEET,  left = 0.223633, right = 0.229980, top = 0.596191, bottom = 0.603516 },

    -- Rank bar chrome
    skillbarBg      = { file = CHROME_SHEET,  left = 0.664062, right = 0.884277, top = 0.193359, bottom = 0.207520 },
    skillbarFrame   = { file = CHROME_SHEET,  left = 0.233398, right = 0.453613, top = 0.286621, bottom = 0.300781 },

    -- Reagent slot art
    slotBg          = { file = CHROME_SHEET,  left = 0.195801, right = 0.216797, top = 0.362305, bottom = 0.383301 },
    slotFrame       = { file = CHROME_SHEET,  left = 0.197754, right = 0.217285, top = 0.802246, bottom = 0.821777 },

    -- Details quality pane (3-slice)
    qualityTop      = { file = CHROME_SHEET,  left = 0.233398, right = 0.360352, top = 0.210449, bottom = 0.259277 },
    qualityMid      = { file = CHROME_SHEET,  left = 0.399414, right = 0.526367, top = 0.161621, bottom = 0.162109 },
    qualityBot      = { file = CHROME_SHEET,  left = 0.361328, right = 0.488281, top = 0.210449, bottom = 0.258789 },

    -- Red buttons (1536801)
    btnLeft         = { file = RED_BUTTON,    left = 0.763672, right = 0.986328, top = 0.444824, bottom = 0.507324 },
    btnLeftDown     = { file = RED_BUTTON,    left = 0.763672, right = 0.986328, top = 0.571777, bottom = 0.634277 },
    btnLeftDisabled = { file = RED_BUTTON,    left = 0.763672, right = 0.986328, top = 0.508301, bottom = 0.570801 },
    btnMid          = { file = RED_BUTTON,    left = 0.000000, right = 0.125000, top = 0.000488, bottom = 0.062988 },
    btnMidDown      = { file = RED_BUTTON,    left = 0.000000, right = 0.125000, top = 0.127441, bottom = 0.189941 },
    btnMidDisabled  = { file = RED_BUTTON,    left = 0.000000, right = 0.125000, top = 0.063965, bottom = 0.126465 },
    btnRight        = { file = RED_BUTTON,    left = 0.001953, right = 0.572266, top = 0.254395, bottom = 0.316895 },
    btnRightDown    = { file = RED_BUTTON,    left = 0.001953, right = 0.572266, top = 0.381348, bottom = 0.443848 },
    btnRightDisabled= { file = RED_BUTTON,    left = 0.001953, right = 0.572266, top = 0.317871, bottom = 0.380371 },
    btnHighlight    = { file = RED_BUTTON,    left = 0.001953, right = 0.863281, top = 0.190918, bottom = 0.253418 },

    -- Minimal scrollbar
    sbTrackTop      = { file = SCROLL_MAIN,   left = 0.164062, right = 0.226562, top = 0.609375, bottom = 0.734375 },
    sbTrackBot      = { file = SCROLL_MAIN,   left = 0.085938, right = 0.148438, top = 0.765625, bottom = 0.890625 },
    sbTrackMid      = { file = SCROLL_MID,    left = 0.015625, right = 0.140625, top = 0.000000, bottom = 1.000000 },
    sbArrowUp       = { file = SCROLL_MAIN,   left = 0.687500, right = 0.820312, top = 0.015625, bottom = 0.187500 },
    sbArrowUpOver   = { file = SCROLL_MAIN,   left = 0.390625, right = 0.523438, top = 0.218750, bottom = 0.390625 },
    sbArrowUpDown   = { file = SCROLL_MAIN,   left = 0.835938, right = 0.968750, top = 0.015625, bottom = 0.187500 },
    sbArrowDown     = { file = SCROLL_MAIN,   left = 0.242188, right = 0.375000, top = 0.812500, bottom = 0.984375 },
    sbArrowDownOver = { file = SCROLL_MAIN,   left = 0.539062, right = 0.671875, top = 0.015625, bottom = 0.187500 },
    sbArrowDownDown = { file = SCROLL_MAIN,   left = 0.390625, right = 0.523438, top = 0.015625, bottom = 0.187500 },
    sbThumbTop      = { file = SCROLL_THUMB_CAP, left = 0.312500, right = 0.437500, top = 0.843750, bottom = 0.968750 },
    sbThumbBot      = { file = SCROLL_THUMB_CAP, left = 0.609375, right = 0.734375, top = 0.484375, bottom = 0.609375 },
    sbThumbMid      = { file = SCROLL_THUMB_MID, left = 0.484375, right = 0.609375, top = 0.000977, bottom = 0.699219 },

    -- Favorite star (3046538)
    favOff          = { file = AH_CHROME,     left = 0.940430, right = 0.979492, top = 0.084961, bottom = 0.120117 },
    favOn           = { file = AH_CHROME,     left = 0.940430, right = 0.979492, top = 0.047852, bottom = 0.083008 },

    -- Close button (4698972)
    closeNormal     = { file = CLOSE_SHEET,   left = 0.152344, right = 0.292969, top = 0.007812, bottom = 0.304688 },
    closePressed    = { file = CLOSE_SHEET,   left = 0.152344, right = 0.292969, top = 0.632812, bottom = 0.929688 },
    closeHighlight  = { file = CLOSE_SHEET,   left = 0.449219, right = 0.589844, top = 0.007812, bottom = 0.304688 },
}

local function ApplyAtlas(tex, info)
    if not (tex and info) then return end
    tex:SetTexture(info.file)
    tex:SetTexCoord(info.left, info.right, info.top, info.bottom)
end

-- ── Inset Frame Bevelled Border Helper (InsetFrameTemplate) ──────────────
local function ApplyInsetBorder(parent)
    local border = CreateFrame("Frame", nil, parent)
    border:SetAllPoints(parent)
    border:EnableMouse(false)

    local tl = border:CreateTexture(nil, "BORDER", nil, -5)
    ApplyAtlas(tl, ATLAS.innerTL)
    tl:SetSize(6, 6)
    tl:SetPoint("TOPLEFT", border, "TOPLEFT", 0, 0)

    local tr = border:CreateTexture(nil, "BORDER", nil, -5)
    ApplyAtlas(tr, ATLAS.innerTR)
    tr:SetSize(6, 6)
    tr:SetPoint("TOPRIGHT", border, "TOPRIGHT", 0, 0)

    local bl = border:CreateTexture(nil, "BORDER", nil, -5)
    ApplyAtlas(bl, ATLAS.innerBL)
    bl:SetSize(6, 6)
    bl:SetPoint("BOTTOMLEFT", border, "BOTTOMLEFT", 0, -1)

    local br = border:CreateTexture(nil, "BORDER", nil, -5)
    ApplyAtlas(br, ATLAS.innerBR)
    br:SetSize(6, 6)
    br:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", 0, -1)

    local t = border:CreateTexture(nil, "BORDER", nil, -5)
    ApplyAtlas(t, ATLAS.innerTop)
    t:SetHeight(3)
    t:SetPoint("TOPLEFT", tl, "TOPRIGHT", 0, 0)
    t:SetPoint("TOPRIGHT", tr, "TOPLEFT", 0, 0)
    t:SetHorizTile(true)

    local b = border:CreateTexture(nil, "BORDER", nil, -5)
    ApplyAtlas(b, ATLAS.innerBot)
    b:SetHeight(3)
    b:SetPoint("BOTTOMLEFT", bl, "BOTTOMRIGHT", 0, 0)
    b:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT", 0, 0)
    b:SetHorizTile(true)

    local l = border:CreateTexture(nil, "BORDER", nil, -5)
    ApplyAtlas(l, ATLAS.innerLeft)
    l:SetWidth(3)
    l:SetPoint("TOPLEFT", tl, "BOTTOMLEFT", 0, 0)
    l:SetPoint("BOTTOMLEFT", bl, "TOPLEFT", 0, 0)
    l:SetVertTile(true)

    local r = border:CreateTexture(nil, "BORDER", nil, -5)
    ApplyAtlas(r, ATLAS.innerRight)
    r:SetWidth(3)
    r:SetPoint("TOPRIGHT", tr, "BOTTOMRIGHT", 0, 0)
    r:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT", 0, 0)
    r:SetVertTile(true)

    return border
end

-- ── Red Button Skinning Helper ───────────────────────────────────────────
local function SkinRedButton(btn)
    if btn:GetHeight() <= 20 then
        btn:SetNormalFontObject("GameFontNormalSmall")
        btn:SetHighlightFontObject("GameFontHighlightSmall")
        btn:SetDisabledFontObject("GameFontDisableSmall")
    else
        btn:SetNormalFontObject("GameFontNormal")
        btn:SetHighlightFontObject("GameFontHighlight")
        btn:SetDisabledFontObject("GameFontDisable")
    end

    local nt = btn:GetNormalTexture()
    if nt then nt:SetAlpha(0) end
    local pt = btn:GetPushedTexture()
    if pt then pt:SetAlpha(0) end
    local dt = btn:GetDisabledTexture()
    if dt then dt:SetAlpha(0) end
    local ht = btn:GetHighlightTexture()
    if ht then ht:SetAlpha(0) end

    local nLeft = btn:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(nLeft, ATLAS.btnLeft)
    nLeft:SetPoint("LEFT", btn, "LEFT", 0, 0)

    local nRight = btn:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(nRight, ATLAS.btnRight)
    nRight:SetPoint("RIGHT", btn, "RIGHT", 0, 0)

    local nMid = btn:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(nMid, ATLAS.btnMid)
    nMid:SetPoint("TOPLEFT", nLeft, "TOPRIGHT", 0, 0)
    nMid:SetPoint("BOTTOMRIGHT", nRight, "BOTTOMLEFT", 0, 0)

    local function updateScale()
        local h = btn:GetHeight()
        local w = btn:GetWidth()
        if h <= 0 or w <= 0 then return end
        local scale = h / 128
        local leftW = math.floor(114 * scale)
        local rightW = math.floor(292 * scale)
        local both = leftW + rightW
        if both > w then
            local ratio = w / both
            leftW = math.floor(leftW * ratio)
            rightW = w - leftW
        end
        nLeft:SetSize(leftW, h)
        nRight:SetSize(rightW, h)
    end
    updateScale()
    btn:HookScript("OnSizeChanged", updateScale)

    local function updateState(state)
        local isDis = btn.IsEnabled and not btn:IsEnabled()
        if isDis then
            ApplyAtlas(nLeft, ATLAS.btnLeftDisabled)
            ApplyAtlas(nMid, ATLAS.btnMidDisabled)
            ApplyAtlas(nRight, ATLAS.btnRightDisabled)
        elseif state == "PUSHED" then
            ApplyAtlas(nLeft, ATLAS.btnLeftDown)
            ApplyAtlas(nMid, ATLAS.btnMidDown)
            ApplyAtlas(nRight, ATLAS.btnRightDown)
        else
            ApplyAtlas(nLeft, ATLAS.btnLeft)
            ApplyAtlas(nMid, ATLAS.btnMid)
            ApplyAtlas(nRight, ATLAS.btnRight)
        end
    end

    btn:HookScript("OnMouseDown", function() updateState("PUSHED") end)
    btn:HookScript("OnMouseUp", function() updateState("NORMAL") end)
    btn:HookScript("OnEnable", function() updateState("NORMAL") end)
    btn:HookScript("OnDisable", function() updateState("DISABLED") end)
    btn:HookScript("OnShow", function() updateState() end)
    updateState()

    local hTex = btn:CreateTexture(nil, "HIGHLIGHT")
    ApplyAtlas(hTex, ATLAS.btnHighlight)
    hTex:SetAllPoints(btn)
    hTex:SetBlendMode("ADD")
    hTex:SetAlpha(0.3)
end

-- ── Profession Layout and Texture Configuration ───────────────────────────
local PROF_CONFIG = {
    ["Engineering"] = {
        title = "Engineering",
        portrait = P .. "4620673-ui-profession-engineering.blp",
        bg = P .. "4722478-professions-recipe-background-engineering.blp",
        flip = P .. "4881558-skillbar-fill-flipbook-engineering.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.498535,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
    ["Alchemy"] = {
        title = "Alchemy",
        portrait = P .. "4620669-ui-profession-alchemy.blp",
        bg = P .. "4625450-professions-recipe-background-alchemy.blp",
        flip = P .. "4696956-skillbar-fill-flipbook-alchemy.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.498535,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
    ["Blacksmithing"] = {
        title = "Blacksmithing",
        portrait = P .. "4620670-ui-profession-blacksmithing.blp",
        bg = P .. "4625448-professions-recipe-background-blacksmithing.blp",
        flip = P .. "4683154-skillbar-fill-flipbook-blacksmithing.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.498535,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
    ["Cooking"] = {
        title = "Cooking",
        portrait = P .. "4620671-ui-profession-cooking.blp",
        bg = P .. "4671747-professions-recipe-background-cooking.blp",
        flip = P .. "4872261-skillbar-fill-flipbook-cooking.blp",
        left = 0.000488, right = 0.836426, top = 0.000977, bottom = 0.997070,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
    ["Enchanting"] = {
        title = "Enchanting",
        portrait = P .. "4620672-ui-profession-enchanting.blp",
        bg = P .. "4723320-professions-recipe-background-enchanting.blp",
        flip = P .. "4693223-skillbar-fill-flipbook-enchanting.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.614746,
        rows = 37, cols = 2, frames = 74, first = 3, duration = 7.8,
    },
    ["Inscription"] = {
        title = "Inscription",
        portrait = P .. "4620676-ui-profession-inscription.blp",
        bg = P .. "4723119-professions-recipe-background-inscription.blp",
        flip = P .. "4872264-skillbar-fill-flipbook-inscription.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.498535,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
    ["Jewelcrafting"] = {
        title = "Jewelcrafting",
        portrait = P .. "4620677-ui-profession-jewelcrafting.blp",
        bg = P .. "4723112-professions-recipe-background-jewelcrafting.blp",
        flip = P .. "4693237-skillbar-fill-flipbook-jewelcrafting.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.365723,
        rows = 22, cols = 2, frames = 44, first = 3, duration = 7.8,
    },
    ["Leatherworking"] = {
        title = "Leatherworking",
        portrait = P .. "4620678-ui-profession-leatherworking.blp",
        bg = P .. "4723154-professions-recipe-background-leatherworking.blp",
        flip = P .. "4696971-skillbar-fill-flipbook-leatherworking.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.498535,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
    ["Skinning"] = {
        title = "Skinning",
        portrait = P .. "4620680-ui-profession-skinning.blp",
        bg = P .. "4723308-professions-recipe-background-skinning.blp",
        flip = P .. "4872267-skillbar-fill-flipbook-skinning.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.498535,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
    ["Tailoring"] = {
        title = "Tailoring",
        portrait = P .. "4620681-ui-profession-tailoring.blp",
        bg = P .. "4627497-professions-recipe-background-tailoring.blp",
        flip = P .. "4693230-skillbar-fill-flipbook-tailoring.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.498535,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
    ["Herbalism"] = {
        title = "Herbalism",
        portrait = P .. "4620675-ui-profession-herbalism.blp",
        bg = P .. "4723159-professions-recipe-background-herbalism.blp",
    },
    ["Mining"] = {
        title = "Mining",
        portrait = P .. "4620679-ui-profession-mining.blp",
        bg = P .. "4723189-professions-recipe-background-mining.blp",
    },
    ["Fishing"] = {
        title = "Fishing",
        portrait = P .. "4620674-ui-profession-fishing.blp",
        bg = P .. "4723316-professions-recipe-background-fishing.blp",
    },
    ["First Aid"] = {
        title = "First Aid",
        portrait = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
        bg = P .. "4659666-professions-recipe-background.blp",
        flip = P .. "4872267-skillbar-fill-flipbook-skinning.blp",
        left = 0.000488, right = 0.836426, top = 0.000488, bottom = 0.498535,
        rows = 30, cols = 2, frames = 60, first = 3, duration = 7.8,
    },
}

local function GetProfConfig(name)
    if not name then return PROF_CONFIG["Engineering"] end
    if PROF_CONFIG[name] then return PROF_CONFIG[name] end
    local lower = name:lower()
    local canonical = NS.PROF_CANONICAL_NAMES and NS.PROF_CANONICAL_NAMES[lower]
    if canonical and PROF_CONFIG[canonical] then return PROF_CONFIG[canonical] end
    for k, cfg in pairs(PROF_CONFIG) do
        if k:lower() == lower then return cfg end
    end
    return PROF_CONFIG["Engineering"]
end


-- ── Flipbook Flare Geometry ───────────────────────────────────────────────
local FLARE_U0    = 0.837402
local FLARE_U1    = 0.863281
local FLARE_H     = 0.016114
local FLARE_MAX_W = 53
local FLARE_PX_H  = 16

local function positionFlare(flareTex, fillTex, tcTop, fillW)
    if not (flareTex and fillTex) then return end
    local fw    = math.min(FLARE_MAX_W, fillW or 0)
    local uSpan = FLARE_U1 - FLARE_U0
    local cropU0 = FLARE_U1 - (uSpan * (fw / FLARE_MAX_W))

    flareTex:SetDrawLayer("ARTWORK", 3)
    flareTex:ClearAllPoints()
    flareTex:SetPoint("RIGHT", fillTex, "RIGHT", 0, 0)
    flareTex:SetTexCoord(cropU0, FLARE_U1, tcTop or 0, math.min(1, (tcTop or 0) + FLARE_H))
    flareTex:SetSize(fw, FLARE_PX_H)
end

-- ── Flipbook Animation Engine ─────────────────────────────────────────────
local flipDriver = CreateFrame("Frame")
local flipActive = {}

local function applyFlipFrame(f)
    local first = f.first or 1
    local span  = f.frames - first
    local idx
    if span <= 0 then
        idx = first
    else
        idx = first + math.floor((f.elapsed / f.duration) * span)
        if idx >= f.frames then idx = f.frames - 1 end
    end
    local col = idx % f.cols
    local row = math.floor(idx / f.cols)

    local frac = f.frac or (f.tex and f.tex._frac) or 1
    local u0 = f.l + col * f.cellW
    local u1 = u0 + f.cellW * frac
    local v0 = f.t + row * f.cellH
    local v1 = f.t + (row + 1) * f.cellH

    f.tex:SetTexCoord(u0, u1, v0, v1)
end

flipDriver:SetScript("OnUpdate", function(_, dt)
    for i = #flipActive, 1, -1 do
        local f = flipActive[i]
        f.elapsed = f.elapsed + dt
        while f.elapsed >= f.duration do f.elapsed = f.elapsed - f.duration end
        applyFlipFrame(f)
    end
    if #flipActive == 0 then flipDriver:Hide() end
end)
flipDriver:Hide()

local function StartFlipAnimation(tex, texturePath, info, frac)
    if not (tex and info and texturePath) then return end
    tex:SetTexture(texturePath)
    tex._frac = frac or (117 / 150)

    local phase = 0
    for i = #flipActive, 1, -1 do
        local a = flipActive[i]
        if a.tex == tex then
            if a.cols == (info.cols or 2) and a.frames == (info.frames or 60) and a.duration == (info.duration or 7.8) then
                phase = a.elapsed
            end
            table.remove(flipActive, i)
        end
    end

    local cols = info.cols or 2
    local rows = info.rows or 30
    local cellW = (info.right - info.left) / cols
    local cellH = (info.bottom - info.top) / rows

    local entry = {
        tex = tex,
        l = info.left,
        t = info.top,
        cellW = cellW,
        cellH = cellH,
        rows = rows,
        cols = cols,
        frames = info.frames or (rows * cols),
        duration = info.duration or 7.8,
        elapsed = phase,
        first = info.first or 3,
        frac = tex._frac,
    }
    applyFlipFrame(entry)
    table.insert(flipActive, entry)
    flipDriver:Show()
end

local function StopFlipAnimation(tex)
    for i = #flipActive, 1, -1 do
        if flipActive[i].tex == tex then
            table.remove(flipActive, i)
        end
    end
    if #flipActive == 0 then flipDriver:Hide() end
end

local function refreshFlipFrame(tex)
    for _, f in ipairs(flipActive) do
        if f.tex == tex then
            f.frac = tex._frac
            applyFlipFrame(f)
            return true
        end
    end
    return false
end

-- ── Skill-up Rank Animation Engine ───────────────────────────────────────
local RANK_ANIM_RATE = 1.6   -- seconds to sweep the WHOLE bar; a small tick is proportionally shorter
local RANK_ANIM_MIN  = 0.30  -- floor, so a 1-point skill-up is still readable
local RANK_ANIM_MAX  = 1.10  -- ceiling, so a big jump doesn't crawl
local RANK_ANIM_EASE = 3     -- ease-out exponent (1 = linear)

local rankAnim = CreateFrame("Frame")
rankAnim:Hide()

local currentAnim = nil

local function stopRankAnim(rb)
    if currentAnim and (rb == nil or currentAnim.rb == rb) then
        if currentAnim.rb then
            currentAnim.rb._sweeping = false
        end
        currentAnim = nil
        rankAnim:Hide()
    end
end

local function applyFillFrac(rb, frac)
    if not rb then return end
    local maxW = rb.FillMaxW or FILL_MAXW
    local w = math.max(1, math.floor(maxW * frac + 0.5))
    local prev = rb._ratio
    rb._ratio = frac

    if rb._genericFill then
        if rb.fill then
            rb.fill:SetWidth(w)
            rb.fill:SetShown(frac > 0)
        end
        if rb.flare then rb.flare:Hide() end
        return
    end

    if rb.fill then
        rb.fill:SetWidth(w)
        rb.fill._frac = frac
        rb.fill:SetShown(frac > 0)
        if rb._flipping then
            refreshFlipFrame(rb.fill)
        end
    end

    if rb.flare and rb._flareInfo then
        local fl = rb._flareInfo
        if frac > 0 then
            positionFlare(rb.flare, rb.fill, fl.top, w)
            rb.flare:Show()
            rb.flare:SetAlpha(1)
        else
            rb.flare:Hide()
        end
        if frac >= 1 and rb._sweeping and prev and prev < 1 then
            rb.flare:Hide()
        end
    elseif rb.flare then
        rb.flare:Hide()
    end
end

rankAnim:SetScript("OnUpdate", function(self, dt)
    local a = currentAnim
    if not a or type(a) ~= "table" then
        self:Hide()
        return
    end

    a.elapsed = a.elapsed + dt
    local p = a.elapsed / a.duration
    if p > 1 then p = 1 end
    local e = 1 - (1 - p) ^ RANK_ANIM_EASE

    applyFillFrac(a.rb, a.fromFrac + (a.toFrac - a.fromFrac) * e)

    local shown = a.fromRank + (a.toRank - a.fromRank) * e
    a.rb._rankShown = shown
    if a.rb.text then
        a.rb.text:SetText(string.format("%d / %d", math.floor(shown + 0.5), a.maxRank))
    end

    if p >= 1 then
        a.rb._sweeping = false
        currentAnim = nil
        self:Hide()
    end
end)

local function setFillFrac(rb, frac, rank, maxRank, animate)
    local fromFrac, fromRank = rb._ratio, rb._rankShown

    if not (animate and fromFrac and fromRank) then
        stopRankAnim(rb)
        rb._sweeping = false
        applyFillFrac(rb, frac)
        rb._rankShown = rank
        if rb.text then
            if maxRank > 0 then
                rb.text:SetText(string.format("%d / %d", rank, maxRank))
            else
                rb.text:SetText(rank > 0 and tostring(rank) or "-- / --")
            end
        end
        return
    end

    local dur = math.abs(frac - fromFrac) * RANK_ANIM_RATE
    dur = math.max(RANK_ANIM_MIN, math.min(RANK_ANIM_MAX, dur))

    currentAnim = {
        rb = rb,
        fromFrac = fromFrac,
        toFrac = frac,
        fromRank = fromRank,
        toRank = rank,
        maxRank = maxRank,
        elapsed = 0,
        duration = dur,
    }
    rb._sweeping = true
    applyFillFrac(rb, fromFrac)
    rankAnim:Show()
end

-- ── Difficulty Colors and Ordering ─────────────────────────────────────────
local DIFF_ORDER = {
    orange  = 1, optimal = 1,
    yellow  = 2, medium  = 2,
    green   = 3, easy    = 3,
    gray    = 4, trivial = 4,
}

local DIFF_COLORS = {
    optimal = { r = 1.00, g = 0.50, b = 0.25 }, -- Orange
    orange  = { r = 1.00, g = 0.50, b = 0.25 },
    medium  = { r = 1.00, g = 1.00, b = 0.00 }, -- Yellow
    yellow  = { r = 1.00, g = 1.00, b = 0.00 },
    easy    = { r = 0.25, g = 0.75, b = 0.25 }, -- Green
    green   = { r = 0.25, g = 0.75, b = 0.25 },
    trivial = { r = 0.60, g = 0.60, b = 0.60 }, -- Gray
    gray    = { r = 0.60, g = 0.60, b = 0.60 },
}

-- Groups flat recipe list by itemSubType (or "Miscellaneous") and sorts by difficulty
local function BuildRecipeTree(rawRecipes)
    if not rawRecipes or #rawRecipes == 0 then
        return {}
    end

    local catMap = {}
    local catOrder = {}

    for _, r in ipairs(rawRecipes) do
        local subType = r.subType
        if not subType or subType == "" or subType == "Miscellaneous" then
            if r.itemId and r.itemId > 0 and GetItemInfo then
                local _, _, _, _, _, _, itSub = GetItemInfo(r.itemId)
                if itSub and itSub ~= "" then
                    subType = itSub
                    r.subType = itSub
                end
            end
        end
        if not subType or subType == "" then
            subType = "Miscellaneous"
        end

        if not catMap[subType] then
            catMap[subType] = {}
            table.insert(catOrder, subType)
        end
        table.insert(catMap[subType], r)
    end

    table.sort(catOrder, function(a, b)
        if a == "Miscellaneous" then return false end
        if b == "Miscellaneous" then return true end
        return a < b
    end)

    local tree = {}
    for _, catName in ipairs(catOrder) do
        local recipesInCat = catMap[catName]
        table.sort(recipesInCat, function(a, b)
            local da = DIFF_ORDER[a.difficulty] or 99
            local db = DIFF_ORDER[b.difficulty] or 99
            if da ~= db then
                return da < db
            end
            return (a.name or "") < (b.name or "")
        end)

        table.insert(tree, {
            name = catName,
            recipes = recipesInCat,
        })
    end

    return tree
end
NS.CB_BuildProfessionRecipeTree = BuildRecipeTree


-- ── Detail Renderer & Tooltip Scanner ─────────────────────────────────────
local profScanTip = CreateFrame("GameTooltip", "CleanBotProfScanTip", UIParent or CreateFrame("Frame"), "GameTooltipTemplate")
if profScanTip.SetOwner then
    profScanTip:SetOwner(UIParent or profScanTip, "ANCHOR_NONE")
end
local recipeDescCache = {}

local function GetRecipeDescription(recipe)
    if not recipe then return nil end
    if recipe.description and recipe.description ~= "" then
        return recipe.description
    end

    local cacheKey = (recipe.itemId and recipe.itemId > 0 and ("item:" .. recipe.itemId))
        or (recipe.spellId and recipe.spellId > 0 and ("spell:" .. recipe.spellId))

    if cacheKey and recipeDescCache[cacheKey] then
        return recipeDescCache[cacheKey]
    end

    if not cacheKey then return nil end

    profScanTip:ClearLines()
    local ok = pcall(profScanTip.SetHyperlink, profScanTip, cacheKey)
    if not ok then return nil end

    local numLines = profScanTip:NumLines()
    if not numLines or numLines == 0 then return nil end

    local lines = {}
    for i = 1, numLines do
        local fontString = _G["CleanBotProfScanTipTextLeft" .. i]
        local text = fontString and fontString:GetText()
        if text and text ~= "" then
            local r, g, b = fontString:GetTextColor()
            if r and g and b and (r < 0.95 or g < 0.95 or b < 0.95) then
                local hex = string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), text)
                table.insert(lines, hex)
            else
                table.insert(lines, text)
            end
        end
    end

    if #lines > 0 then
        local desc = table.concat(lines, "\n")
        if #lines > 1 or (recipe.name and lines[1] == recipe.name) then
            recipeDescCache[cacheKey] = desc
        end
        return desc
    end

    return nil
end

local function StripColorCodes(text)
    if not text then return "" end
    local s = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|h", ""):gsub("|n", "")
    return s
end

local function ScanSpellRecipeDetails(spellId, recipe)
    local details = {
        title = recipe and recipe.name,
        toolsHeader = "Tools:",
        toolName = nil,
        reagentsHeader = "Reagents:",
        description = recipe and recipe.description,
    }
    if not spellId or spellId <= 0 then return details end

    profScanTip:ClearLines()
    local ok = pcall(profScanTip.SetHyperlink, profScanTip, "spell:" .. spellId)
    if not ok then return details end

    local numLines = profScanTip:NumLines() or 0
    if numLines == 0 then return details end

    local lines = {}
    local cleanLines = {}
    for i = 1, numLines do
        local fs = _G["CleanBotProfScanTipTextLeft" .. i]
        local text = fs and fs:GetText()
        if text and text ~= "" then
            lines[#lines + 1] = text
            cleanLines[#cleanLines + 1] = StripColorCodes(text)
        end
    end

    local total = #lines
    if total == 0 then return details end

    details.title = cleanLines[1] or details.title

    -- Identify the line containing known reagents from recipe.reagents (Language-Agnostic)
    local knownReagents = {}
    if recipe and recipe.reagents then
        for _, r in ipairs(recipe.reagents) do
            local rName = r.name
            if (not rName or rName:find("^Item #")) and r.itemId and GetItemInfo then
                local gName = GetItemInfo(r.itemId)
                if gName then rName = gName end
            end
            if rName and rName ~= "" then
                table.insert(knownReagents, rName:lower())
            end
        end
    end

    local reagentListIdx = nil
    if #knownReagents > 0 then
        for i = 2, total do
            local low = cleanLines[i]:lower()
            for _, rName in ipairs(knownReagents) do
                if low:find(rName, 1, true) then
                    reagentListIdx = i
                    break
                end
            end
            if reagentListIdx then break end
        end
    end

    -- Use official WoW global string for reagents header in any locale (e.g. "Reagents:", "Componentes:")
    local rawReagentsHeader = _G["SPELL_REAGENTS"] or "Reagents:"
    local reagentKeyword = rawReagentsHeader:match("^([^:|%s]+)") or "Reagents"
    details.reagentsHeader = reagentKeyword .. ":"

    local descStartIdx = 2
    if reagentListIdx then
        -- Process any lines between Title (1) and Reagent list (reagentListIdx)
        for k = 2, reagentListIdx - 1 do
            local cLine = cleanLines[k]
            local normLine = cLine:gsub("[%c%p%s]", ""):lower()
            local normReagents = reagentKeyword:lower()

            if normLine == normReagents then
                details.reagentsHeader = reagentKeyword .. ":"
            else
                -- Tools / Requirement line (e.g. "Tools: Runed Copper Rod")
                local tHead, tName = cLine:match("^([^:]+:?)%s*(.+)$")
                if tHead and tName then
                    if not tHead:find(":$") then tHead = tHead .. ":" end
                    details.toolsHeader = tHead
                    details.toolName = tName
                else
                    details.toolsHeader = "Tools:"
                    details.toolName = cLine
                end
            end
        end
        descStartIdx = reagentListIdx + 1
    else
        if total >= 2 then
            local cLine = cleanLines[2]
            local tHead, tName = cLine:match("^([^:]+:?)%s*(.+)$")
            if tHead and tName then
                if not tHead:find(":$") then tHead = tHead .. ":" end
                details.toolsHeader = tHead
                details.toolName = tName
                descStartIdx = 3
            end
        end
    end

    local descLines = {}
    for i = descStartIdx, total do
        local cLine = cleanLines[i]
        if cLine and cLine ~= "" then
            table.insert(descLines, cLine)
        end
    end

    if #descLines > 0 then
        details.description = table.concat(descLines, "\n")
    end

    return details
end

local function BotHasTool(f, toolName, recipe)
    if not toolName or toolName == "" then return true end

    -- 1. Server ground truth: if craftable > 0, C++ MultiBotBridge already confirmed BotHasRecipeRequiredTools!
    if recipe and recipe.numAvailable and recipe.numAvailable > 0 then
        return true
    end

    -- 2. If all reagents are available but craftable == 0, the missing tool is the blocking cause
    if recipe and recipe.reagents and #recipe.reagents > 0 then
        local allMatsReady = true
        for _, r in ipairs(recipe.reagents) do
            if (r.available or 0) < (r.count or 1) then
                allMatsReady = false
                break
            end
        end
        if allMatsReady then
            return false
        end
    end

    -- 3. Check bot equipped items (slots 1..18) and bot bags
    local botKey = f and f.botKey
    local entry = CleanBot_PartyBots and botKey and CleanBot_PartyBots[botKey]
    local botName = (entry and entry.name) or (f and f.botName) or botKey
    local unit = (NS.CB_FindPartyUnit and NS.CB_FindPartyUnit(botName)) or (entry and entry.unit)

    local normTool = toolName:lower():gsub("[%c%p%s]", "")

    if unit and GetInventoryItemLink then
        for slotId = 1, 18 do
            local link = GetInventoryItemLink(unit, slotId)
            if link then
                local itName = GetItemInfo and GetItemInfo(link)
                if itName then
                    local normItem = itName:lower():gsub("[%c%p%s]", "")
                    if normItem == normTool or normItem:find(normTool, 1, true) then
                        return true
                    end
                end
            end
        end
    end

    if entry and entry.inventory then
        local invItems = entry.inventory.items or entry.inventory
        for _, it in pairs(invItems) do
            local itName = it.name
            if not itName and it.itemId and GetItemInfo then
                itName = GetItemInfo(it.itemId)
            end
            if itName then
                local normItem = itName:lower():gsub("[%c%p%s]", "")
                if normItem == normTool or normItem:find(normTool, 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

local function ShowRecipeTooltip(owner, recipe, optFrame)
    if not owner or not recipe then return end
    local f = optFrame or (owner.profFrame) or (owner.GetParent and owner:GetParent() and owner:GetParent().profFrame) or NS.botProfessionsFrame
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")

    local itemId = tonumber(recipe.itemId)
    -- Recipes creating a physical item: display Blizzard's native item tooltip (stats, level, armor)
    if itemId and itemId > 0 and GameTooltip.SetHyperlink then
        local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. itemId)
        if ok and GameTooltip:NumLines() and GameTooltip:NumLines() > 0 then
            GameTooltip:Show()
            return
        end
    end

    -- Service/enchantment spells: format identically to WoW with colors evaluated from the bot's inventory
    local spellId = tonumber(recipe.spellId)
    local details = ScanSpellRecipeDetails(spellId, recipe)

    GameTooltip:ClearLines()

    -- 1. Recipe Title in WoW gold (1.0, 0.82, 0.0)
    local titleText = details.title or recipe.name or ""
    GameTooltip:AddLine(titleText, 1.0, 0.82, 0.0)

    -- 2. Tools (if any): Header in white, tool name in white or red depending on bot
    if details.toolName and details.toolName ~= "" then
        local hasTool = BotHasTool(f, details.toolName, recipe)
        local toolColorHex = hasTool and "|cffffffff" or "|cffff2020"
        local head = details.toolsHeader or "Tools:"
        GameTooltip:AddLine(head .. " " .. toolColorHex .. details.toolName .. "|r", 1.0, 1.0, 1.0)
    end

    -- 3. Reagents: "Reagents:" header, comma-separated list of reagent names with bot colors
    local reagents = recipe.reagents or {}
    if #reagents > 0 then
        local head = details.reagentsHeader or "Reagents:"
        GameTooltip:AddLine(head, 1.0, 1.0, 1.0)

        local names = {}
        for _, r in ipairs(reagents) do
            local rName = r.name
            if (not rName or rName:find("^Item #")) and r.itemId and GetItemInfo then
                local gName = GetItemInfo(r.itemId)
                if gName then rName = gName end
            end
            rName = rName or ("Item " .. (r.itemId or 0))

            local hasEnough = (r.available or 0) >= (r.count or 1)
            local colorHex = hasEnough and "|cffffffff" or "|cffff2020"
            table.insert(names, colorHex .. rName .. "|r")
        end

        GameTooltip:AddLine(table.concat(names, ", "), 1.0, 1.0, 1.0, true)
    end

    -- 4. Enchantment effect description in WoW yellow (1.0, 0.82, 0.0) with wrap
    local descText = details.description or recipe.description
    if descText and descText ~= "" then
        GameTooltip:AddLine(descText, 1.0, 0.82, 0.0, true)
    end

    GameTooltip:Show()
end

local function ShowReagentTooltip(owner, data)
    if not owner or not data then return end
    local anchor = owner.iconHit or owner
    GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
    local shown = false
    local itemId = tonumber(data.itemId)
    if itemId and itemId > 0 and GameTooltip.SetHyperlink then
        local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. itemId)
        if ok and GameTooltip:NumLines() and GameTooltip:NumLines() > 0 then
            shown = true
        end
    end
    if not shown then
        GameTooltip:ClearLines()
        GameTooltip:AddLine(data.name or "Reagent", 1, 1, 1)
        GameTooltip:AddLine(string.format("%d / %d", data.available or 0, data.count or 1), 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

local function HandleLinkClick(recipeOrData)
    if not recipeOrData then return false end
    if (IsModifiedClick and IsModifiedClick("CHATLINK")) or IsShiftKeyDown() then
        local link = recipeOrData.link
        local itemId = tonumber(recipeOrData.itemId)
        if not link and itemId and GetItemInfo then
            link = select(2, GetItemInfo(itemId))
        end
        local spellId = tonumber(recipeOrData.spellId)
        if not link and spellId and GetSpellLink then
            link = GetSpellLink(spellId)
        end
        if link then
            if HandleModifiedItemClick and HandleModifiedItemClick(link) then
                return true
            end
            if ChatEdit_InsertLink then
                ChatEdit_InsertLink(link)
                return true
            end
        end
    end
    return false
end

local RefreshRecipeList -- forward declaration

local function SelectRecipe(f, recipe)
    f.selectedRecipe = recipe
    local sf = f.SchematicForm
    if not sf then return end

    if not recipe then
        if sf.EmptyText then sf.EmptyText:Show() end
        sf.OutputIcon.recipe = nil
        sf.OutputIcon:Hide()
        sf.OutputName:SetText("")
        sf.FavoriteBtn:Hide()
        sf.RequiresText:Hide()
        sf.DetailsPanel:Hide()
        sf.ReagentHeader:Hide()
        for _, slot in ipairs(sf.reagentSlots or {}) do
            slot.data = nil
            slot:Hide()
        end
        f.CreateButton:Disable()
        f.CreateAllButton:Disable()
        return
    end

    if sf.EmptyText then sf.EmptyText:Hide() end

    -- 1. Output Item Header
    if (not recipe.name or recipe.name:find("^Recipe #")) and recipe.itemId and GetItemInfo then
        local itName, _, _, _, _, _, _, _, _, itTex = GetItemInfo(recipe.itemId)
        if itName then
            recipe.name = itName
            if itTex then recipe.icon = itTex end
        end
    end

    sf.OutputIcon.recipe = recipe
    sf.OutputIcon.icon:SetTexture(recipe.icon)
    sf.OutputIcon:Show()

    local isGreen = (recipe.quality and recipe.quality >= 2)
    if isGreen then
        sf.OutputName:SetTextColor(0.12, 1.0, 0.0) -- Uncommon Green
    else
        local dc = DIFF_COLORS[recipe.difficulty] or DIFF_COLORS.trivial
        sf.OutputName:SetTextColor(dc.r, dc.g, dc.b)
    end
    sf.OutputName:SetText(recipe.name)

    sf.FavoriteBtn:Hide()
    sf.FavoriteBtn.tex:SetTexture(AH_CHROME)
    sf.FavoriteBtn.tex:SetTexCoord(ATLAS.favOff.left, ATLAS.favOff.right, ATLAS.favOff.top, ATLAS.favOff.bottom)

    if recipe.requires then
        sf.RequiresText:SetText(recipe.requires)
        sf.RequiresText:Show()
    else
        sf.RequiresText:Hide()
    end

    -- 2. Reagents
    sf.ReagentHeader:Show()
    local reagents = recipe.reagents or {}
    for i = 1, 8 do
        local slot = sf.reagentSlots[i]
        local data = reagents[i]
        if data then
            slot.data = data
            if (not data.name or data.name:find("^Item #")) and data.itemId and GetItemInfo then
                local rName, _, rQual, _, _, _, _, _, _, rTex = GetItemInfo(data.itemId)
                if rName then
                    data.name = rName
                    data.icon = rTex or data.icon
                    data.quality = rQual or data.quality
                end
            end

            slot.icon:SetTexture(data.icon)
            local hasEnough = data.available >= data.count
            slot.count:SetText(string.format("%d/%d", data.available, data.count))
            slot.count:SetTextColor(1, 1, 1)

            slot.name:SetText(data.name)
            if hasEnough then
                slot.name:SetTextColor(1, 1, 1)
            else
                slot.name:SetTextColor(0.65, 0.65, 0.65)
            end

            -- Quality border around reagent (only if rare/uncommon)
            if data.quality and data.quality > 1 then
                slot.glow:SetVertexColor(0.12, 1.0, 0.0)
                slot.glow:Show()
            else
                slot.glow:Hide()
            end

            slot:Show()
        else
            slot.data = nil
            slot:Hide()
        end
    end

    -- 3. Details Panel
    local desc
    local hasItem = recipe.itemId and recipe.itemId > 0
    if not hasItem and recipe.spellId and recipe.spellId > 0 then
        local details = ScanSpellRecipeDetails(recipe.spellId, recipe)
        desc = details and details.description
    else
        desc = GetRecipeDescription(recipe)
    end
    if desc and desc ~= "" then
        sf.DetailsText:SetText(desc)
        sf.DetailsIcon:SetTexture(recipe.icon)
        local textH = sf.DetailsText:GetStringHeight() or 80
        local panelH = math.max(196, math.min(460, 82 + textH + 30))
        sf.DetailsPanel:SetHeight(panelH)
        sf.DetailsPanel:Show()
    else
        sf.DetailsPanel:Hide()
    end

    -- 4. Create Buttons
    if f.TargetPicker and f.TargetPicker:IsShown() and f.TargetPicker.recipe ~= recipe then
        f.TargetPicker:Hide()
    end

    local hasItem = recipe.itemId and recipe.itemId > 0
    if not hasItem then
        f.CreateButton:SetText("Select Item")
        if recipe.numAvailable and recipe.numAvailable > 0 and not f.isCrafting then
            f.CreateButton:Enable()
        else
            f.CreateButton:Disable()
        end
    elseif recipe.numAvailable and recipe.numAvailable > 0 then
        if not f.isCrafting then
            f.CreateButton:Enable()
            f.CreateButton:SetText("Create")
        end
    else
        if not f.isCrafting then
            f.CreateButton:Disable()
            f.CreateButton:SetText("Create")
        end
    end
    f.CreateAllButton:Disable()

    -- 5. Highlight in row pool
    for _, row in ipairs(f.RecipeList.rows or {}) do
        if row.recipe and row.recipe.name == recipe.name then
            row.sel:Show()
        else
            row.sel:Hide()
        end
    end
end

-- ── Minimal Scrollbar Visual Sync Helper ─────────────────────────────────
local function SyncMinimalScrollbar(rl, total)
    local maxOffset = math.max(0, total - VISIBLE_ROWS)
    local offset = FauxScrollFrame_GetOffset(rl.scrollFrame) or 0
    if offset > maxOffset then offset = maxOffset end

    local custom = rl.customScrollbar
    if not custom then return end

    if maxOffset <= 0 then
        custom.thumb:Hide()
        if rl.upArrow then rl.upArrow:Disable() end
        if rl.downArrow then rl.downArrow:Disable() end
    else
        custom.thumb:Show()
        if rl.upArrow then
            if offset <= 0 then rl.upArrow:Disable() else rl.upArrow:Enable() end
        end
        if rl.downArrow then
            if offset >= maxOffset then rl.downArrow:Disable() else rl.downArrow:Enable() end
        end
        if not custom.thumb._dragging then
            local trackH = custom:GetHeight() - custom.thumb:GetHeight()
            local frac = offset / maxOffset
            if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
            custom.thumb:ClearAllPoints()
            custom.thumb:SetPoint("TOP", custom, "TOP", 0, -frac * trackH)
        end
    end
end

-- ── Left Recipe List Refresh ─────────────────────────────────────────────
local function ResetFilters(f)
    f.filters = f.filters or {}
    f.filters.showLearned = true
    f.filters.makeable = false
    f.filters.skillUp = false
    if f.RecipeList and f.RecipeList.searchBox then
        f.RecipeList.searchBox:SetText("")
    end
    if f.RecipeList and f.RecipeList.filterReset then
        f.RecipeList.filterReset:Hide()
    end
end

function RefreshRecipeList(f)
    local rl = f.RecipeList
    if not rl then return end

    f.filters = f.filters or { showLearned = true, makeable = false, skillUp = false }
    local filt = f.filters
    local filterText = (rl.searchBox:GetText() or ""):lower()

    local flat = {}
    local tree = f.recipeTree or {}
    for _, cat in ipairs(tree) do
        local visible = {}
        for _, r in ipairs(cat.recipes or {}) do
            local skip = false
            if not filt.showLearned then
                skip = true
            end
            if not skip and filt.skillUp and (r.difficulty == "trivial" or r.difficulty == "gray" or r.difficulty == "nodifficulty") then
                skip = true
            end
            if not skip and filt.makeable and (r.numAvailable or 0) <= 0 then
                skip = true
            end
            if not skip and filterText ~= "" and not r.name:lower():find(filterText, 1, true) then
                skip = true
            end
            if not skip then
                table.insert(visible, r)
            end
        end

        if #visible > 0 then
            table.insert(flat, { kind = "cat", name = cat.name, key = cat.name })
            if not f.collapsedCats[cat.name] then
                for _, r in ipairs(visible) do
                    table.insert(flat, { kind = "recipe", r = r })
                end
            end
        end
    end

    local total = #flat
    rl.totalEntries = total
    local maxOffset = math.max(0, total - VISIBLE_ROWS)
    local offset = FauxScrollFrame_GetOffset(rl.scrollFrame) or 0
    if offset > maxOffset then
        offset = maxOffset
        FauxScrollFrame_SetOffset(rl.scrollFrame, offset)
    end

    for i = 1, VISIBLE_ROWS do
        local row = rl.rows[i]
        local idx = offset + i
        local item = flat[idx]

        if item then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", rl.scrollContent, "TOPLEFT", 14, -(i - 1) * ROW_H_RECIPE)
            row:SetPoint("TOPRIGHT", rl.scrollContent, "TOPRIGHT", -4, -(i - 1) * ROW_H_RECIPE)

            if item.kind == "cat" then
                row.isCat = true
                row.catKey = item.key
                row.recipe = nil
                row:SetHeight(ROW_H_CAT)

                row.catLeft:Show()
                row.catMid:Show()
                row.catRight:Show()
                row.catLabel:SetText(item.name)
                row.catLabel:Show()

                local isCollapsed = f.collapsedCats[item.key]
                ApplyAtlas(row.collapseIcon, isCollapsed and ATLAS.catExpand or ATLAS.catCollapse)
                row.collapseIcon:Show()

                row.chevron:Hide()
                row.rname:Hide()
                row.rcount:Hide()
                row.sel:Hide()
                if row.hov then
                    row.hov:SetAlpha(0)
                    row.hov:Hide()
                end
            else
                row.isCat = false
                row.recipe = item.r
                row:SetHeight(ROW_H_RECIPE)
                if row.hov then
                    row.hov:SetAlpha(0.4)
                end

                row.catLeft:Hide()
                row.catMid:Hide()
                row.catRight:Hide()
                row.catLabel:Hide()
                row.collapseIcon:Hide()

                row.rname:SetText(item.r.name)
                local dc = DIFF_COLORS[item.r.difficulty] or DIFF_COLORS.trivial
                if f.opts and f.opts.colorByDifficulty then
                    row.rname:SetTextColor(dc.r, dc.g, dc.b)
                else
                    row.rname:SetTextColor(0.96, 0.89, 0.58)
                end
                row.rname:Show()

                -- Chevron
                local diff = item.r.difficulty
                if diff == "optimal" or diff == "orange" then
                    ApplyAtlas(row.chevron, ATLAS.skillHigh)
                    row.chevron:Show()
                elseif diff == "medium" or diff == "yellow" then
                    ApplyAtlas(row.chevron, ATLAS.skillMedium)
                    row.chevron:Show()
                elseif diff == "easy" or diff == "green" then
                    ApplyAtlas(row.chevron, ATLAS.skillLow)
                    row.chevron:Show()
                else
                    row.chevron:Hide()
                end

                -- Craftable count
                if item.r.numAvailable and item.r.numAvailable > 0 then
                    row.rcount:SetText(string.format("[%d]", item.r.numAvailable))
                    row.rcount:Show()
                else
                    row.rcount:Hide()
                end

                -- Active selection
                if f.selectedRecipe and f.selectedRecipe.name == item.r.name then
                    row.sel:Show()
                else
                    row.sel:Hide()
                end
            end

            row:Show()
        else
            row:Hide()
        end
    end

    if rl.filterReset then
        local hasFilterToggles = (not filt.showLearned) or filt.makeable or filt.skillUp
        if hasFilterToggles and filterText == "" then
            rl.filterReset:Show()
        else
            rl.filterReset:Hide()
        end
    end

    FauxScrollFrame_Update(rl.scrollFrame, total, VISIBLE_ROWS, ROW_H_RECIPE)
    SyncMinimalScrollbar(rl, total)
end

-- ── Options Menu Settings Persistence ───────────────────────────────────
local function loadOpts(f)
    f.opts = f.opts or { hideListTooltips = false, colorByDifficulty = false, genericBar = false }
    local root = _G.CleanBot_SavedVars
    local o = root and root.professionOpts
    if type(o) == "table" then
        if o.hideListTooltips  ~= nil then f.opts.hideListTooltips  = o.hideListTooltips  and true or false end
        if o.colorByDifficulty ~= nil then f.opts.colorByDifficulty = o.colorByDifficulty and true or false end
        if o.genericBar        ~= nil then f.opts.genericBar        = o.genericBar        and true or false end
    end
end

local function saveOpts(f)
    if not _G.CleanBot_SavedVars then _G.CleanBot_SavedVars = {} end
    if type(_G.CleanBot_SavedVars.professionOpts) ~= "table" then
        _G.CleanBot_SavedVars.professionOpts = {}
    end
    local o = _G.CleanBot_SavedVars.professionOpts
    if not f.opts then return end
    o.hideListTooltips  = f.opts.hideListTooltips  and true or false
    o.colorByDifficulty = f.opts.colorByDifficulty and true or false
    o.genericBar        = f.opts.genericBar        and true or false
end

-- ── Options Menu Popup ────────────────────────────────────────────────────
local function buildCogMenu(f, cog)
    if f.CogMenu then return f.CogMenu end

    local menu = CreateFrame("Frame", "CleanBotProfessionsCogMenu", cog)
    menu:SetFrameStrata("DIALOG")
    menu:SetPoint("TOPRIGHT", cog, "BOTTOMRIGHT", 0, -2)
    if menu.SetBackdrop then
        menu:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end
    menu:Hide()
    menu:EnableMouse(true)

    local maxCalculatedWidth = 230

    local function checkRow(label, getfn, setfn, y)
        local cb = CreateFrame("CheckButton", nil, menu, "UICheckButtonTemplate")
        cb:SetSize(20, 20)
        cb:SetPoint("TOPLEFT", 12, y)

        local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText(label)

        local strWidth = fs:GetStringWidth() or 0
        local neededWidth = math.ceil(12 + 20 + 4 + strWidth + 28)
        if neededWidth > maxCalculatedWidth then
            maxCalculatedWidth = neededWidth
        end

        cb:SetChecked(getfn())
        cb:SetScript("OnClick", function(self)
            setfn(self:GetChecked() and true or false)
        end)
        cb._sync = function() cb:SetChecked(getfn()) end
        return cb
    end

    menu.cbTip = checkRow("Hide item tooltips in list",
        function() return f.opts.hideListTooltips end,
        function(v)
            f.opts.hideListTooltips = v
            saveOpts(f)
        end, -12)

    menu.cbDiff = checkRow("Colour names by skill difficulty",
        function() return f.opts.colorByDifficulty end,
        function(v)
            f.opts.colorByDifficulty = v
            saveOpts(f)
            RefreshRecipeList(f)
        end, -40)

    menu.cbBar = checkRow("Plain skill bar (no animation)",
        function() return f.opts.genericBar end,
        function(v)
            f.opts.genericBar = v
            saveOpts(f)
            if NS.CB_RenderProfessions then
                NS.CB_RenderProfessions(f, f.currentProf)
            end
        end, -68)

    menu:SetSize(maxCalculatedWidth, 106)

    for _, cb in ipairs({ menu.cbTip, menu.cbDiff, menu.cbBar }) do
        local fs = cb and cb:GetFontString()
        if fs then
            fs:SetPoint("RIGHT", menu, "RIGHT", -16, 0)
        end
    end

    menu:SetScript("OnShow", function(self)
        loadOpts(f)
        if self.cbTip  and self.cbTip._sync  then self.cbTip._sync()  end
        if self.cbDiff and self.cbDiff._sync then self.cbDiff._sync() end
        if self.cbBar  and self.cbBar._sync  then self.cbBar._sync()  end
    end)
    f.CogMenu = menu
    return menu
end

-- ── Profession Dropdown Menu (Dropdown Triggered from Header) ──────────────
local function buildProfDropdown(f, headerBtn)
    if f.ProfDropdown then return f.ProfDropdown end

    local menu = CreateFrame("Frame", "CleanBotProfessionsDropdownMenu", headerBtn)
    menu:SetFrameStrata("DIALOG")
    menu:SetPoint("TOP", headerBtn, "BOTTOM", 0, -2)
    menu:SetWidth(220)
    if menu.SetBackdrop then
        menu:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        menu:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    end
    menu:Hide()
    menu:EnableMouse(true)

    local ROW_H = 26
    local items = {}

    local sampleProfs = {
        { name = "Engineering", key = "Engineering", cur = 150, max = 225 },
        { name = "Mining",      key = "Mining",      cur = 225, max = 300 },
        { name = "Cooking",     key = "Cooking",     cur = 75,  max = 150 },
    }

    menu.Refresh = function()
        local list = sampleProfs
        local entry = CleanBot_PartyBots and f.botKey and CleanBot_PartyBots[f.botKey]
        if entry and entry.professions and #entry.professions > 0 then
            list = entry.professions
        end

        local totalH = 14 + (#list * ROW_H) + 6
        menu:SetHeight(totalH)

        for i, p in ipairs(list) do
            local row = items[i]
            if not row then
                row = CreateFrame("Button", nil, menu)
                row:SetHeight(ROW_H)
                row:SetPoint("LEFT", menu, "LEFT", 8, 0)
                row:SetPoint("RIGHT", menu, "RIGHT", -8, 0)

                local icon = row:CreateTexture(nil, "ARTWORK")
                icon:SetSize(20, 20)
                icon:SetPoint("LEFT", row, "LEFT", 4, 0)
                if icon.SetMask then
                    icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
                end
                row.icon = icon

                local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
                label:SetJustifyH("LEFT")
                row.label = label

                local rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                rank:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                rank:SetJustifyH("RIGHT")
                rank:SetTextColor(0.8, 0.8, 0.8)
                row.rank = rank

                local hov = row:CreateTexture(nil, "HIGHLIGHT")
                hov:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                hov:SetBlendMode("ADD")
                hov:SetAllPoints()
                hov:SetAlpha(0.5)

                row:SetScript("OnClick", function(self)
                    if self.profKey and NS.CB_RenderProfessions then
                        NS.CB_RenderProfessions(f, self.profKey)
                    end
                    menu:Hide()
                end)

                items[i] = row
            end

            row:SetPoint("TOP", menu, "TOP", 0, -(8 + (i - 1) * ROW_H))
            row.profKey = p.name or p.key
            local pCfg = GetProfConfig(p.name or p.key)
            local ic = p.icon or (pCfg and pCfg.portrait) or "Interface\\Icons\\INV_Misc_QuestionMark"
            row.icon:SetTexture(ic)
            row.label:SetText(p.name or p.key)
            row.rank:SetText(string.format("%d/%d", p.cur or 0, p.max or 0))

            if f.currentProf and (f.currentProf == p.name or f.currentProf == p.key or (p.name and f.currentProf:lower() == p.name:lower())) then
                row.label:SetTextColor(1, 0.82, 0)
            else
                row.label:SetTextColor(1, 1, 1)
            end
            row:Show()
        end

        for i = #list + 1, #items do
            items[i]:Hide()
        end
    end

    menu:SetScript("OnShow", function(self)
        self.Refresh()
        if f.headerArrow then
            ApplyAtlas(f.headerArrow, ATLAS.catExpand)
        end
    end)

    menu:SetScript("OnHide", function(self)
        if f.headerArrow then
            ApplyAtlas(f.headerArrow, ATLAS.catCollapse)
        end
    end)

    f.ProfDropdown = menu
    return menu
end

-- ── Main Professions Frame Construction ──────────────────────────────────
NS.CB_GetProfessionsFrame = function(key, botName)
    local f = NS.botProfessionsFrame
    if f then
        f.botKey  = key
        f.botName = botName or key
        loadOpts(f)
        return f
    end

    f = CreateFrame("Frame", "CleanBotProfessionsFrame", UIParent)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetScale(UI_SCALE)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnHide", function(self)
        if self.RankBar then
            stopRankAnim(self.RankBar)
            self.RankBar._snapNext = true
            if self.RankBar.fill then
                StopFlipAnimation(self.RankBar.fill)
                self.RankBar._flipping = false
                self.RankBar._flipTexture = nil
            end
        end
        if self.CogMenu then
            self.CogMenu:Hide()
        end
        if self.ProfDropdown then
            self.ProfDropdown:Hide()
        end
        if CloseDropDownMenus then
            CloseDropDownMenus()
        end
        ResetFilters(self)
    end)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    tinsert(UISpecialFrames, f:GetName())

    loadOpts(f)
    f.collapsedCats = {}

    -- ── 1. Rock Body Fill ─────────────────────────────────────────────────
    local body = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    body:SetTexture(ROCK_BODY, "REPEAT", "REPEAT")
    body:SetHorizTile(true)
    body:SetVertTile(true)
    body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -21)
    body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f.bodyBg = body

    -- ── 2. TopTileStreaks Band ────────────────────────────────────────────
    local streaks = f:CreateTexture(nil, "BORDER", nil, -7)
    ApplyAtlas(streaks, ATLAS.topStreaks)
    streaks:SetHorizTile(true)
    streaks:SetHeight(43)
    streaks:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -21)
    streaks:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -21)
    f.topStreaks = streaks

    -- ── 3. Metal NineSlice Frame Chrome (PortraitFrameTemplate) ───────────
    local ns = CreateFrame("Frame", f:GetName() .. "_NineSlice", f)
    ns:SetAllPoints(f)
    ns:SetFrameLevel((f:GetFrameLevel() or 1) + 20)
    ns:EnableMouse(false)
    f.NineSlice = ns

    local cTL = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    cTL:SetSize(75, 75)
    cTL:SetPoint("TOPLEFT", f, "TOPLEFT", -13, 16)
    ApplyAtlas(cTL, ATLAS.metalCornerTL)

    local cTR = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    cTR:SetSize(75, 75)
    cTR:SetPoint("TOPRIGHT", f, "TOPRIGHT", 4, 16)
    ApplyAtlas(cTR, ATLAS.metalCornerTR)

    local cBL = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    cBL:SetSize(32, 32)
    cBL:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -13, -3)
    ApplyAtlas(cBL, ATLAS.metalCornerBL)

    local cBR = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    cBR:SetSize(32, 32)
    cBR:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -3)
    ApplyAtlas(cBR, ATLAS.metalCornerBR)

    local eTop = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    eTop:SetHeight(75)
    eTop:SetPoint("TOPLEFT", cTL, "TOPRIGHT", 0, 0)
    eTop:SetPoint("TOPRIGHT", cTR, "TOPLEFT", 0, 0)
    eTop:SetHorizTile(true)
    ApplyAtlas(eTop, ATLAS.metalEdgeTop)

    local eBot = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    eBot:SetHeight(32)
    eBot:SetPoint("BOTTOMLEFT", cBL, "BOTTOMRIGHT", 0, 0)
    eBot:SetPoint("BOTTOMRIGHT", cBR, "BOTTOMLEFT", 0, 0)
    eBot:SetHorizTile(true)
    ApplyAtlas(eBot, ATLAS.metalEdgeBot)

    local eLeft = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    eLeft:SetWidth(75)
    eLeft:SetPoint("TOPLEFT", cTL, "BOTTOMLEFT", 0, 0)
    eLeft:SetPoint("BOTTOMLEFT", cBL, "TOPLEFT", 0, 0)
    eLeft:SetVertTile(true)
    ApplyAtlas(eLeft, ATLAS.metalEdgeLeft)

    local eRight = ns:CreateTexture(nil, "OVERLAY", nil, 2)
    eRight:SetWidth(75)
    eRight:SetPoint("TOPRIGHT", cTR, "BOTTOMRIGHT", 0, 0)
    eRight:SetPoint("BOTTOMRIGHT", cBR, "TOPRIGHT", 0, 0)
    eRight:SetVertTile(true)
    ApplyAtlas(eRight, ATLAS.metalEdgeRight)

    -- ── 4. Circular Portrait Icon ─────────────────────────────────────────
    local portrait = ns:CreateTexture(nil, "ARTWORK", nil, 1)
    portrait:SetSize(60, 60)
    portrait:SetPoint("TOPLEFT", f, "TOPLEFT", -6, 7)
    portrait:SetTexture(P .. "4620673-ui-profession-engineering.blp")
    if portrait.SetMask then
        portrait:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    end
    f.portrait = portrait

    -- Portrait Clickable Trigger
    local portraitBtn = CreateFrame("Button", nil, ns)
    portraitBtn:SetAllPoints(portrait)
    portraitBtn:SetFrameLevel((ns:GetFrameLevel() or 20) + 5)
    f.portraitBtn = portraitBtn

    -- ── 5. Window Title Header Button (Interactive Dropdown Trigger) ───────
    local headerBtn = CreateFrame("Button", "CleanBotProfessionsHeaderBtn", ns)
    headerBtn:SetHeight(20)
    headerBtn:SetPoint("TOP", f, "TOP", 0, -3)
    headerBtn:SetFrameLevel((ns:GetFrameLevel() or 20) + 5)

    local title = headerBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", headerBtn, "LEFT", 4, 0)
    title:SetText("Engineering")
    f.title = title
    f.headerBtn = headerBtn

    local headerArrow = headerBtn:CreateTexture(nil, "OVERLAY")
    headerArrow:SetSize(13, 9)
    headerArrow:SetPoint("LEFT", title, "RIGHT", 4, -1)
    ApplyAtlas(headerArrow, ATLAS.catCollapse)
    f.headerArrow = headerArrow

    headerBtn:SetWidth((title:GetStringWidth() or 80) + 25)

    local headerHov = headerBtn:CreateTexture(nil, "HIGHLIGHT")
    headerHov:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    headerHov:SetBlendMode("ADD")
    headerHov:SetAllPoints()
    headerHov:SetAlpha(0.35)

    local function toggleDropdown()
        local menu = buildProfDropdown(f, headerBtn)
        if menu:IsShown() then
            menu:Hide()
        else
            if f.CogMenu and f.CogMenu:IsShown() then f.CogMenu:Hide() end
            menu:Show()
        end
    end

    headerBtn:SetScript("OnClick", toggleDropdown)
    portraitBtn:SetScript("OnClick", toggleDropdown)

    -- ── 6. Red Close Button ───────────────────────────────────────────────
    local closeBtn = CreateFrame("Button", "CleanBotProfessionsClose", f)
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", 1, 0)
    closeBtn:SetFrameLevel((ns:GetFrameLevel() or 20) + 10)

    local nt = closeBtn:CreateTexture(nil, "ARTWORK"); nt:SetAllPoints(); ApplyAtlas(nt, ATLAS.closeNormal); closeBtn:SetNormalTexture(nt)
    local pt = closeBtn:CreateTexture(nil, "ARTWORK"); pt:SetAllPoints(); ApplyAtlas(pt, ATLAS.closePressed); closeBtn:SetPushedTexture(pt)
    local ht = closeBtn:CreateTexture(nil, "HIGHLIGHT"); ht:SetAllPoints(); ApplyAtlas(ht, ATLAS.closeHighlight); closeBtn:SetHighlightTexture(ht)
    closeBtn:SetScript("OnClick", function()
        if f.ProfDropdown then f.ProfDropdown:Hide() end
        if f.CogMenu then f.CogMenu:Hide() end
        f:Hide()
    end)
    f.closeBtn = closeBtn

    -- ── 7. Rank Bar (Skill Progress) ──────────────────────────────────────
    local rb = CreateFrame("Frame", nil, f)
    rb:SetSize(RANKBAR_W, RANKBAR_H)
    rb:SetFrameLevel((f:GetFrameLevel() or 1) + 10)
    rb:SetPoint("TOPLEFT", f, "TOPLEFT", RANKBAR_TL[1], RANKBAR_TL[2])
    f.RankBar = rb

    local rbBg = rb:CreateTexture(nil, "BACKGROUND", nil, -8)
    ApplyAtlas(rbBg, ATLAS.skillbarBg)
    rbBg:SetPoint("TOPLEFT", rb, "TOPLEFT", 0, 0)
    rbBg:SetSize(451, 29)

    -- Themed profession flipbook fill
    local fillFrac = 117 / 150
    local fillW = math.floor(FILL_MAXW * fillFrac)

    local engInfo = PROF_CONFIG["Engineering"]

    local fill = rb:CreateTexture(nil, "ARTWORK", nil, 2)
    fill:SetTexture(engInfo.flip)
    fill:SetPoint("TOPLEFT", rb, "TOPLEFT", FILL_X, FILL_Y)
    fill:SetSize(fillW, FILL_H)
    fill:SetBlendMode("BLEND")
    fill._frac = fillFrac
    rb.fill = fill

    StartFlipAnimation(fill, engInfo.flip, engInfo, fillFrac)

    -- Flare on moving crest (ARTWORK 3: under border OVERLAY 1)
    local flare = rb:CreateTexture(nil, "ARTWORK", nil, 3)
    flare:SetTexture(engInfo.flip)
    flare:SetBlendMode("ADD")
    positionFlare(flare, fill, engInfo.top, fillW)
    rb.flare = flare

    local rbFrame = rb:CreateTexture(nil, "OVERLAY", nil, 1)
    ApplyAtlas(rbFrame, ATLAS.skillbarFrame)
    rbFrame:SetPoint("TOPLEFT", rb, "TOPLEFT", 0, 0)
    rbFrame:SetSize(451, 29)

    local rbText = rb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    do
        local fn = rbText:GetFont()
        if fn then rbText:SetFont(fn, 12, "OUTLINE") end
    end
    rbText:SetPoint("CENTER", rb, "CENTER", 0, 3)
    rbText:SetText("117 / 150")
    rb.text = rbText
    rb._snapNext = true

    -- Chat Link Button
    local linkBtn = CreateFrame("Button", nil, f)
    linkBtn:SetSize(28, 28)
    linkBtn:SetPoint("LEFT", rb, "RIGHT", 6, -2)
    linkBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-Chat-Up")
    linkBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-Chat-Down")
    linkBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    linkBtn:SetScript("OnClick", function()
        if NS.CB_Print then NS.CB_Print("Engineering (117/150)") end
    end)
    f.linkBtn = linkBtn

    -- Options Cog Button
    local cogBtn = CreateFrame("Button", "CleanBotProfessionsCog", f)
    cogBtn:SetSize(16, 18)
    cogBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -38)
    cogBtn:SetFrameLevel((ns:GetFrameLevel() or 20) + 10)

    local cogIcon = cogBtn:CreateTexture(nil, "ARTWORK")
    cogIcon:SetTexture(S .. "5684744-questlog.blp")
    cogIcon:SetTexCoord(0.138672, 0.167969, 0.035156, 0.066406)
    cogIcon:SetAllPoints(cogBtn)
    cogBtn.Icon = cogIcon

    local cogHi = cogBtn:CreateTexture(nil, "HIGHLIGHT")
    cogHi:SetTexture(S .. "5684744-questlog.blp")
    cogHi:SetTexCoord(0.138672, 0.167969, 0.035156, 0.066406)
    cogHi:SetAllPoints(cogBtn)
    cogHi:SetBlendMode("ADD")
    cogHi:SetAlpha(0.4)
    cogBtn.Hi = cogHi

    cogBtn:SetScript("OnClick", function()
        local menu = buildCogMenu(f, cogBtn)
        if menu:IsShown() then
            menu:Hide()
        else
            menu:Show()
        end
    end)
    f.cogBtn = cogBtn

    -- ── 8. Left Panel (RecipeList) ────────────────────────────────────────
    local rl = CreateFrame("Frame", "CleanBotProfessionsRecipeList", f)
    rl:SetWidth(RECIPELIST_W)
    rl:SetPoint("TOPLEFT", f, "TOPLEFT", RECIPELIST_TL[1], RECIPELIST_TL[2])
    rl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", RECIPELIST_BL[1], RECIPELIST_BL[2])
    f.RecipeList = rl

    local rlBg = rl:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(rlBg, ATLAS.summaryBg)
    rlBg:SetAllPoints(rl)

    -- Inset bevel border
    ApplyInsetBorder(rl)

    -- Filter button (Red button)
    local filterBtn = CreateFrame("Button", nil, rl)
    filterBtn:SetSize(60, 18)
    filterBtn:SetPoint("TOPRIGHT", rl, "TOPRIGHT", -26, -9)
    SkinRedButton(filterBtn)
    filterBtn:SetNormalFontObject("GameFontNormalSmall")
    filterBtn:SetHighlightFontObject("GameFontHighlightSmall")
    filterBtn:SetDisabledFontObject("GameFontDisableSmall")
    filterBtn:SetText("Filter")
    local filterFs = filterBtn:GetFontString()
    if filterFs then
        filterFs:ClearAllPoints()
        filterFs:SetPoint("CENTER", filterBtn, "CENTER", 0, 0)
    end
    rl.filterBtn = filterBtn

    filterBtn:SetScript("OnClick", function(self)
        if not UIDropDownMenu_Initialize then return end

        local dd = f._filterDropdown
        if not dd then
            dd = CreateFrame("Frame", "CleanBotProfFilterDropDown", UIParent, "UIDropDownMenuTemplate")
            f._filterDropdown = dd
        end

        if _G.UIDROPDOWNMENU_OPEN_MENU == dd and _G.DropDownList1 and _G.DropDownList1:IsShown() then
            if CloseDropDownMenus then CloseDropDownMenus() end
            return
        end

        UIDropDownMenu_Initialize(dd, function()
            local function toggle(key)
                f.filters = f.filters or { showLearned = true, makeable = false, skillUp = false }
                f.filters[key] = not f.filters[key]
                RefreshRecipeList(f)
            end

            local function addCheck(label, key)
                local info = UIDropDownMenu_CreateInfo()
                info.text = label
                info.checked = f.filters and f.filters[key]
                info.keepShownOnClick = true
                info.func = function() toggle(key) end
                UIDropDownMenu_AddButton(info)
            end

            addCheck("Show Learned", "showLearned")
            addCheck("Has Skill Up", "skillUp")
            addCheck("Have Materials", "makeable")
        end, "MENU")

        ToggleDropDownMenu(1, nil, dd, self, 0, 0)
    end)

    -- Filter reset button
    local resetBtn = CreateFrame("Button", nil, rl)
    resetBtn:SetSize(16, 16)
    resetBtn:SetPoint("LEFT", filterBtn, "RIGHT", 2, 0)
    local rtex = resetBtn:CreateTexture(nil, "OVERLAY")
    rtex:SetAllPoints(resetBtn)
    rtex:SetTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    resetBtn:Hide()
    resetBtn:SetScript("OnClick", function()
        if CloseDropDownMenus then CloseDropDownMenus() end
        ResetFilters(f)
        RefreshRecipeList(f)
    end)
    rl.filterReset = resetBtn

    -- Search Box
    local sb = CreateFrame("EditBox", "CleanBotProfessionsSearch", rl)
    sb:SetHeight(20)
    sb:SetPoint("TOPLEFT", rl, "TOPLEFT", 8, -8)
    sb:SetPoint("RIGHT", filterBtn, "LEFT", -4, 0)
    sb:SetAutoFocus(false)
    sb:SetFontObject("GameFontHighlightSmall")
    sb:SetTextInsets(20, 18, 0, 0)
    if sb.SetBackdrop then
        sb:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        sb:SetBackdropColor(0, 0, 0, 0.6)
        sb:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end

    local sbIcon = sb:CreateTexture(nil, "OVERLAY")
    sbIcon:SetSize(14, 14)
    sbIcon:SetPoint("LEFT", sb, "LEFT", 4, 0)
    sbIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")

    sb:SetScript("OnTextChanged", function() RefreshRecipeList(f) end)
    sb:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    sb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    rl.searchBox = sb

    -- Scroll Frame
    local sfScroll = CreateFrame("ScrollFrame", "CleanBotProfessionsScroll", rl, "FauxScrollFrameTemplate")
    sfScroll:SetPoint("TOPLEFT", rl, "TOPLEFT", 4, -34)
    sfScroll:SetPoint("BOTTOMRIGHT", rl, "BOTTOMRIGHT", -22, 6)
    sfScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H_RECIPE, function()
            RefreshRecipeList(f)
        end)
    end)
    local function onWheel(self, delta)
        local total = rl.totalEntries or 0
        local maxOffset = math.max(0, total - VISIBLE_ROWS)
        local current = FauxScrollFrame_GetOffset(sfScroll) or 0
        local nextVal = current - delta
        if nextVal < 0 then nextVal = 0 end
        if nextVal > maxOffset then nextVal = maxOffset end
        if nextVal ~= current then
            FauxScrollFrame_SetOffset(sfScroll, nextVal)
            RefreshRecipeList(f)
        end
    end
    sfScroll:EnableMouseWheel(true)
    sfScroll:SetScript("OnMouseWheel", onWheel)
    rl.scrollFrame = sfScroll

    -- Hide native Blizzard silver scrollbar
    local stockSb = _G[sfScroll:GetName() .. "ScrollBar"]
    if stockSb then
        stockSb:SetAlpha(0)
        stockSb:EnableMouse(false)
    end

    -- Custom Minimal Scrollbar
    local customSb = CreateFrame("Frame", nil, rl)
    customSb:SetWidth(8)
    customSb:SetPoint("TOPRIGHT", rl, "TOPRIGHT", -8, -50)
    customSb:SetPoint("BOTTOMRIGHT", rl, "BOTTOMRIGHT", -8, 26)
    customSb:EnableMouse(true)
    customSb:SetFrameLevel((rl:GetFrameLevel() or 1) + 10)

    local sbTrackTop = customSb:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(sbTrackTop, ATLAS.sbTrackTop)
    sbTrackTop:SetSize(8, 8)
    sbTrackTop:SetPoint("TOP", customSb, "TOP", 0, 0)

    local sbTrackBot = customSb:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(sbTrackBot, ATLAS.sbTrackBot)
    sbTrackBot:SetSize(8, 8)
    sbTrackBot:SetPoint("BOTTOM", customSb, "BOTTOM", 0, 0)

    local sbTrackMid = customSb:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(sbTrackMid, ATLAS.sbTrackMid)
    sbTrackMid:SetPoint("TOPLEFT", sbTrackTop, "BOTTOMLEFT", 0, 0)
    sbTrackMid:SetPoint("BOTTOMRIGHT", sbTrackBot, "TOPRIGHT", 0, 0)
    sbTrackMid:SetVertTile(true)

    -- Arrows
    local upArrow = CreateFrame("Button", nil, rl)
    upArrow:SetSize(17, 11)
    upArrow:SetPoint("BOTTOM", customSb, "TOP", 0, 4)
    local upN = upArrow:CreateTexture(nil, "ARTWORK"); upN:SetAllPoints(); ApplyAtlas(upN, ATLAS.sbArrowUp); upArrow:SetNormalTexture(upN)
    local upP = upArrow:CreateTexture(nil, "ARTWORK"); upP:SetAllPoints(); ApplyAtlas(upP, ATLAS.sbArrowUpDown); upArrow:SetPushedTexture(upP)
    local upH = upArrow:CreateTexture(nil, "HIGHLIGHT"); upH:SetAllPoints(); ApplyAtlas(upH, ATLAS.sbArrowUpOver); upH:SetBlendMode("ADD"); upArrow:SetHighlightTexture(upH)
    upArrow:SetScript("OnClick", function()
        local current = FauxScrollFrame_GetOffset(sfScroll) or 0
        if current > 0 then
            FauxScrollFrame_SetOffset(sfScroll, current - 1)
            RefreshRecipeList(f)
        end
    end)
    rl.upArrow = upArrow

    local downArrow = CreateFrame("Button", nil, rl)
    downArrow:SetSize(17, 11)
    downArrow:SetPoint("TOP", customSb, "BOTTOM", 0, -4)
    local dN = downArrow:CreateTexture(nil, "ARTWORK"); dN:SetAllPoints(); ApplyAtlas(dN, ATLAS.sbArrowDown); downArrow:SetNormalTexture(dN)
    local dP = downArrow:CreateTexture(nil, "ARTWORK"); dP:SetAllPoints(); ApplyAtlas(dP, ATLAS.sbArrowDownDown); downArrow:SetPushedTexture(dP)
    local dH = downArrow:CreateTexture(nil, "HIGHLIGHT"); dH:SetAllPoints(); ApplyAtlas(dH, ATLAS.sbArrowDownOver); dH:SetBlendMode("ADD"); downArrow:SetHighlightTexture(dH)
    downArrow:SetScript("OnClick", function()
        local total = rl.totalEntries or 0
        local maxOffset = math.max(0, total - VISIBLE_ROWS)
        local current = FauxScrollFrame_GetOffset(sfScroll) or 0
        if current < maxOffset then
            FauxScrollFrame_SetOffset(sfScroll, current + 1)
            RefreshRecipeList(f)
        end
    end)
    rl.downArrow = downArrow

    -- Thumb
    local thumb = CreateFrame("Frame", nil, customSb)
    thumb:SetWidth(8)
    thumb:SetHeight(48)
    thumb:SetPoint("TOP", customSb, "TOP", 0, 0)
    thumb:EnableMouse(true)
    thumb:SetFrameLevel((customSb:GetFrameLevel() or 10) + 5)

    local thTop = thumb:CreateTexture(nil, "ARTWORK")
    ApplyAtlas(thTop, ATLAS.sbThumbTop)
    thTop:SetSize(8, 8)
    thTop:SetPoint("TOP", thumb, "TOP", 0, 0)

    local thBot = thumb:CreateTexture(nil, "ARTWORK")
    ApplyAtlas(thBot, ATLAS.sbThumbBot)
    thBot:SetSize(8, 8)
    thBot:SetPoint("BOTTOM", thumb, "BOTTOM", 0, 0)

    local thMid = thumb:CreateTexture(nil, "ARTWORK")
    ApplyAtlas(thMid, ATLAS.sbThumbMid)
    thMid:SetPoint("TOPLEFT", thTop, "BOTTOMLEFT", 0, 0)
    thMid:SetPoint("BOTTOMRIGHT", thBot, "TOPRIGHT", 0, 0)
    thMid:SetVertTile(true)

    local function updateScrollFromThumbY(desiredTop)
        local trackTop = customSb:GetTop()
        local trackH   = customSb:GetHeight() or 0
        local thumbH   = thumb:GetHeight() or 0
        local travel   = trackH - thumbH
        if not trackTop or travel <= 0 then return end

        local maxTop = trackTop
        local minTop = trackTop - travel
        if desiredTop > maxTop then desiredTop = maxTop end
        if desiredTop < minTop then desiredTop = minTop end

        local frac = (maxTop - desiredTop) / travel
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end

        local total = rl.totalEntries or 0
        local maxOffset = math.max(0, total - VISIBLE_ROWS)
        local newOffset = math.floor(frac * maxOffset + 0.5)

        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", customSb, "TOP", 0, -frac * travel)

        local curOffset = FauxScrollFrame_GetOffset(sfScroll) or 0
        if newOffset ~= curOffset then
            FauxScrollFrame_SetOffset(sfScroll, newOffset)
            RefreshRecipeList(f)
        end
    end

    thumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self._dragging = true
        self:SetScript("OnUpdate", function(s)
            local _, cursorY = GetCursorPosition()
            local scale = customSb:GetEffectiveScale() or 1
            cursorY = cursorY / scale
            local thumbH = s:GetHeight() or 0
            updateScrollFromThumbY(cursorY + (thumbH / 2))
        end)
    end)

    thumb:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        self._dragging = false
        self:SetScript("OnUpdate", nil)
        SyncMinimalScrollbar(rl, rl.totalEntries or 0)
    end)

    thumb:SetScript("OnHide", function(self)
        self._dragging = false
        self:SetScript("OnUpdate", nil)
    end)

    customSb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local _, cursorY = GetCursorPosition()
        local scale = self:GetEffectiveScale() or 1
        cursorY = cursorY / scale
        local thumbH = thumb:GetHeight() or 0
        updateScrollFromThumbY(cursorY + (thumbH / 2))
    end)

    customSb.thumb = thumb
    rl.customScrollbar = customSb

    local scrollContent = CreateFrame("Frame", nil, rl)
    scrollContent:SetPoint("TOPLEFT", sfScroll, "TOPLEFT", 0, 0)
    scrollContent:SetPoint("BOTTOMRIGHT", sfScroll, "BOTTOMRIGHT", 0, 0)
    rl.scrollContent = scrollContent

    -- Row Pool
    rl.rows = {}
    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, scrollContent)
        row:SetHeight(ROW_H_RECIPE)

        -- Category widgets
        local cLeft = row:CreateTexture(nil, "BACKGROUND")
        ApplyAtlas(cLeft, ATLAS.catLeft)
        cLeft:SetPoint("LEFT", row, "LEFT", 0, 2)
        cLeft:SetSize(14, 26)
        row.catLeft = cLeft

        local cRight = row:CreateTexture(nil, "BACKGROUND")
        ApplyAtlas(cRight, ATLAS.catRight)
        cRight:SetPoint("RIGHT", row, "RIGHT", 0, 2)
        cRight:SetSize(14, 26)
        row.catRight = cRight

        local cMid = row:CreateTexture(nil, "BACKGROUND")
        ApplyAtlas(cMid, ATLAS.catMid)
        cMid:SetPoint("TOPLEFT", cLeft, "TOPRIGHT", 0, 0)
        cMid:SetPoint("BOTTOMRIGHT", cRight, "BOTTOMLEFT", 0, 0)
        row.catMid = cMid

        local cLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cLabel:SetPoint("LEFT", row, "LEFT", 10, 2)
        cLabel:SetJustifyH("LEFT")
        row.catLabel = cLabel

        local cIcon = row:CreateTexture(nil, "ARTWORK")
        cIcon:SetPoint("RIGHT", row, "RIGHT", -10, 2)
        cIcon:SetSize(14, 10)
        row.collapseIcon = cIcon

        -- Recipe widgets
        local chev = row:CreateTexture(nil, "ARTWORK")
        chev:SetSize(13, 15)
        chev:SetPoint("LEFT", row, "LEFT", 2, 0)
        row.chevron = chev

        local rname = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        rname:SetPoint("LEFT", chev, "RIGHT", 4, 0)
        rname:SetPoint("RIGHT", row, "RIGHT", -34, 0)
        rname:SetJustifyH("LEFT")
        row.rname = rname

        local rcount = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        rcount:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        rcount:SetJustifyH("RIGHT")
        row.rcount = rcount

        -- Active selection & hover
        local sel = row:CreateTexture(nil, "OVERLAY", nil, 2)
        ApplyAtlas(sel, ATLAS.recipeActive)
        sel:SetPoint("CENTER", row, "CENTER", 0, -1)
        sel:SetSize(267, 19)
        sel:Hide()
        row.sel = sel

        local hov = row:CreateTexture(nil, "HIGHLIGHT")
        ApplyAtlas(hov, ATLAS.recipeHover)
        hov:SetPoint("CENTER", row, "CENTER", 0, -1)
        hov:SetSize(267, 21)
        hov:SetAlpha(0.4)
        row.hov = hov

        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            if HandleLinkClick(self.recipe) then
                return
            end
            if self.isCat and self.catKey then
                f.collapsedCats[self.catKey] = not f.collapsedCats[self.catKey]
                RefreshRecipeList(f)
            elseif self.recipe then
                SelectRecipe(f, self.recipe)
            end
        end)

        row:SetScript("OnEnter", function(self)
            if self.isCat then
                if self.hov then self.hov:SetAlpha(0); self.hov:Hide() end
                return
            end
            if self.hov then self.hov:SetAlpha(0.4) end
            if self.recipe and not (f.opts and f.opts.hideListTooltips) then
                ShowRecipeTooltip(self, self.recipe)
            end
        end)

        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        row.profFrame = f
        rl.rows[i] = row
    end

    -- ── 9. Right Panel (SchematicForm) ────────────────────────────────────
    local sf = CreateFrame("Frame", "CleanBotProfessionsSchematic", f)
    sf:SetWidth(SCHEMATIC_W)
    sf:SetPoint("TOPLEFT", rl, "TOPRIGHT", 2, 0)
    sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 5)
    f.SchematicForm = sf

    -- Blueprint background with EXACT UV crop to fill the 655x553 pane!
    local sfBg = sf:CreateTexture(nil, "BACKGROUND")
    sfBg:SetTexture(P .. "4722478-professions-recipe-background-engineering.blp")
    sfBg:SetTexCoord(0.000977, 0.660156, 0.000977, 0.536133)
    sfBg:SetAllPoints(sf)
    sf.bg = sfBg

    -- Inset bevel border
    ApplyInsetBorder(sf)

    -- Output Icon (47x47)
    local outIcon = CreateFrame("Button", nil, sf)
    outIcon:SetSize(47, 47)
    outIcon:SetPoint("TOPLEFT", sf, "TOPLEFT", 28, -28)
    outIcon.profFrame = f

    local outTex = outIcon:CreateTexture(nil, "ARTWORK")
    outTex:SetAllPoints(outIcon)
    outTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    outIcon.icon = outTex

    outIcon:RegisterForClicks("LeftButtonUp")
    outIcon:SetScript("OnEnter", function(self)
        ShowRecipeTooltip(self, self.recipe or f.selectedRecipe)
    end)
    outIcon:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    outIcon:SetScript("OnClick", function(self)
        HandleLinkClick(self.recipe or f.selectedRecipe)
    end)
    sf.OutputIcon = outIcon

    -- Output Name (Large Font)
    local outName = sf:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    outName:SetPoint("LEFT", outIcon, "RIGHT", 14, 8)
    outName:SetJustifyH("LEFT")
    sf.OutputName = outName

    -- Favorite Star
    local favBtn = CreateFrame("Button", nil, sf)
    favBtn:SetSize(20, 18)
    favBtn:SetPoint("LEFT", outName, "RIGHT", 6, 1)
    local favTex = favBtn:CreateTexture(nil, "ARTWORK")
    favTex:SetAllPoints()
    favBtn.tex = favTex
    favBtn:Hide()
    sf.FavoriteBtn = favBtn

    -- Requires Line
    local reqText = sf:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    reqText:SetPoint("TOPLEFT", outName, "BOTTOMLEFT", 0, -4)
    reqText:SetJustifyH("LEFT")
    sf.RequiresText = reqText

    -- Empty-state hint (shown until a recipe is selected)
    local empty = sf:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    empty:SetPoint("CENTER", sf, "CENTER", 0, 40)
    empty:SetVertexColor(0.5, 0.5, 0.5)
    empty:SetText("Select a recipe to craft")
    sf.EmptyText = empty

    -- Reagents Header
    local rh = sf:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    rh:SetPoint("TOPLEFT", outIcon, "BOTTOMLEFT", 0, -38)
    rh:SetText("Reagents")
    sf.ReagentHeader = rh

    -- Reagent Slots (48px tall rows)
    sf.reagentSlots = {}
    for i = 1, 8 do
        local rslot = CreateFrame("Button", nil, sf)
        rslot:SetSize(320, 48)
        rslot:SetPoint("TOPLEFT", rh, "BOTTOMLEFT", 0, -8 - ((i - 1) * 48))
        rslot:EnableMouse(true)
        rslot:RegisterForClicks("LeftButtonUp")

        local sbg = rslot:CreateTexture(nil, "BACKGROUND")
        ApplyAtlas(sbg, ATLAS.slotBg)
        sbg:SetSize(43, 43)
        sbg:SetPoint("LEFT", rslot, "LEFT", 2, 0)
        rslot.sbg = sbg

        local iconHit = CreateFrame("Frame", nil, rslot)
        iconHit:SetAllPoints(sbg)
        rslot.iconHit = iconHit

        local sicon = rslot:CreateTexture(nil, "BORDER")
        sicon:SetPoint("TOPLEFT", sbg, "TOPLEFT", 3, -4)
        sicon:SetPoint("BOTTOMRIGHT", sbg, "BOTTOMRIGHT", -4, 3)
        sicon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        rslot.icon = sicon

        local sframe = rslot:CreateTexture(nil, "OVERLAY")
        ApplyAtlas(sframe, ATLAS.slotFrame)
        sframe:SetSize(40, 40)
        sframe:SetPoint("CENTER", sbg, "CENTER", 0, 0)

        local glow = rslot:CreateTexture(nil, "OVERLAY", nil, 7)
        glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        glow:SetBlendMode("ADD")
        glow:SetPoint("TOPLEFT", sbg, "TOPLEFT", -15, 15)
        glow:SetPoint("BOTTOMRIGHT", sbg, "BOTTOMRIGHT", 15, -15)
        glow:Hide()
        rslot.glow = glow

        local scount = rslot:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        scount:SetPoint("LEFT", sbg, "RIGHT", 8, 0)
        scount:SetWidth(40)
        scount:SetJustifyH("LEFT")
        rslot.count = scount

        local sname = rslot:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        sname:SetPoint("LEFT", scount, "RIGHT", 2, 0)
        sname:SetPoint("RIGHT", rslot, "RIGHT", -2, 0)
        sname:SetJustifyH("LEFT")
        rslot.name = sname

        rslot:SetScript("OnEnter", function(self)
            ShowReagentTooltip(self.iconHit or self, self.data)
        end)
        rslot:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        rslot:SetScript("OnClick", function(self)
            HandleLinkClick(self.data)
        end)

        sf.reagentSlots[i] = rslot
    end

    -- ── 10. Details Panel (Right Side Quality Pane) ────────────────────────
    local dp = CreateFrame("Frame", nil, sf)
    dp:SetSize(250, 220)
    dp:SetPoint("RIGHT", sf, "RIGHT", -16, 0)
    sf.DetailsPanel = dp

    local dpTop = dp:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(dpTop, ATLAS.qualityTop)
    dpTop:SetPoint("TOPLEFT", dp, "TOPLEFT", 0, 0)
    dpTop:SetPoint("TOPRIGHT", dp, "TOPRIGHT", 0, 0)
    dpTop:SetHeight(96)

    local dpBot = dp:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(dpBot, ATLAS.qualityBot)
    dpBot:SetPoint("BOTTOMLEFT", dp, "BOTTOMLEFT", 0, 0)
    dpBot:SetPoint("BOTTOMRIGHT", dp, "BOTTOMRIGHT", 0, 0)
    dpBot:SetHeight(96)

    local dpMid = dp:CreateTexture(nil, "BACKGROUND")
    ApplyAtlas(dpMid, ATLAS.qualityMid)
    dpMid:SetPoint("TOPLEFT", dpTop, "BOTTOMLEFT", 0, 0)
    dpMid:SetPoint("BOTTOMRIGHT", dpBot, "TOPRIGHT", 0, 0)

    local dicon = dp:CreateTexture(nil, "ARTWORK")
    dicon:SetSize(38, 38)
    dicon:SetPoint("TOP", dp, "TOP", 0, -34)
    dicon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    sf.DetailsIcon = dicon

    local dbtn = CreateFrame("Button", nil, dp)
    dbtn:SetAllPoints(dicon)
    dbtn:RegisterForClicks("LeftButtonUp")
    dbtn:SetScript("OnEnter", function(self)
        ShowRecipeTooltip(self, f.selectedRecipe)
    end)
    dbtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    dbtn:SetScript("OnClick", function()
        HandleLinkClick(f.selectedRecipe)
    end)
    sf.DetailsBtn = dbtn

    local dframe = dp:CreateTexture(nil, "OVERLAY")
    ApplyAtlas(dframe, ATLAS.slotFrame)
    dframe:SetSize(46, 46)
    dframe:SetPoint("CENTER", dicon, "CENTER", 0, 0)

    local dpText = dp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dpText:SetPoint("TOPLEFT", dp, "TOPLEFT", 16, -82)
    dpText:SetPoint("BOTTOMRIGHT", dp, "BOTTOMRIGHT", -16, 16)
    dpText:SetJustifyH("CENTER")
    dpText:SetJustifyV("TOP")
    sf.DetailsText = dpText

    -- ── 11. Bottom Action Controls ──────────────────────────────────────────
    local createBtn = CreateFrame("Button", "CleanBotProfessionsCreateBtn", f, "UIPanelButtonTemplate")
    createBtn:SetSize(110, 22)
    createBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 16)
    createBtn:SetText("Create")
    createBtn:SetFrameLevel((sf:GetFrameLevel() or 1) + 20)
    SkinRedButton(createBtn)
    createBtn:Disable()
    f.CreateButton = createBtn

    local qtyBox = CreateFrame("EditBox", "CleanBotProfessionsCount", f, "InputBoxTemplate")
    qtyBox:SetSize(36, 20)
    qtyBox:SetAutoFocus(false)
    qtyBox:SetNumeric(true)
    qtyBox:SetPoint("RIGHT", createBtn, "LEFT", -34, 0)
    qtyBox:SetText("1")
    qtyBox:SetMaxLetters(4)
    qtyBox:SetFrameLevel((sf:GetFrameLevel() or 1) + 20)
    qtyBox:Hide()
    f.qtyBox = qtyBox

    local minusBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    minusBtn:SetSize(20, 20)
    minusBtn:SetPoint("RIGHT", qtyBox, "LEFT", -8, 0)
    minusBtn:SetText("-")
    minusBtn:SetFrameLevel((sf:GetFrameLevel() or 1) + 20)
    SkinRedButton(minusBtn)
    minusBtn:Hide()
    minusBtn:SetScript("OnClick", function()
        local n = tonumber(qtyBox:GetText()) or 1
        if n > 1 then qtyBox:SetText(tostring(n - 1)) end
    end)

    local plusBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    plusBtn:SetSize(20, 20)
    plusBtn:SetPoint("LEFT", qtyBox, "RIGHT", 4, 0)
    plusBtn:SetText("+")
    plusBtn:SetFrameLevel((sf:GetFrameLevel() or 1) + 20)
    SkinRedButton(plusBtn)
    plusBtn:Hide()
    plusBtn:SetScript("OnClick", function()
        local n = tonumber(qtyBox:GetText()) or 1
        local maxN = (f.selectedRecipe and f.selectedRecipe.numAvailable) or 99
        if maxN < 1 then maxN = 1 end
        if n < maxN then qtyBox:SetText(tostring(n + 1)) end
    end)

    local createAllBtn = CreateFrame("Button", "CleanBotProfessionsCreateAllBtn", f, "UIPanelButtonTemplate")
    createAllBtn:SetSize(125, 22)
    createAllBtn:SetPoint("RIGHT", minusBtn, "LEFT", -30, 0)
    createAllBtn:SetText("Create All")
    createAllBtn:SetFrameLevel((sf:GetFrameLevel() or 1) + 20)
    SkinRedButton(createAllBtn)
    createAllBtn:Disable()
    createAllBtn:Hide()
    f.CreateAllButton = createAllBtn

    -- Craft Watcher Frame (Opción B: Detección reactiva de casteo con validación estricta)
    local watcher = CreateFrame("Frame", nil, f)
    f.craftWatcher = watcher

    local function StopCraftWatcher()
        watcher:UnregisterAllEvents()
        watcher:SetScript("OnEvent", nil)
        watcher.targetUnit = nil
        watcher.expectedSpellName = nil
        watcher.expectedSpellId = nil
        if watcher.timerFrame then
            watcher.timerFrame:SetScript("OnUpdate", nil)
        end
    end
    f.StopCraftWatcher = StopCraftWatcher

    local function StartCraftWatcher(targetUnit, expectedSpellName, expectedSpellId, botKey, effectiveBotName, skillId, waitSec)
        StopCraftWatcher()
        watcher.targetUnit = targetUnit or (NS.CB_FindPartyUnit and NS.CB_FindPartyUnit(effectiveBotName))
        watcher.expectedSpellName = expectedSpellName
        watcher.expectedSpellId = expectedSpellId

        watcher:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        watcher:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
        watcher:RegisterEvent("UNIT_SPELLCAST_FAILED")
        watcher:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")

        watcher:SetScript("OnEvent", function(wSelf, event, unit, spellName, spellRank, lineId, spellId)
            if not f.isCrafting then
                StopCraftWatcher()
                return
            end
            if unit ~= wSelf.targetUnit then return end

            local matches = false
            if wSelf.expectedSpellName and spellName and spellName == wSelf.expectedSpellName then
                matches = true
            elseif wSelf.expectedSpellId and spellId and tonumber(spellId) == tonumber(wSelf.expectedSpellId) then
                matches = true
            end

            if not matches and UnitCastingInfo and wSelf.targetUnit and wSelf.expectedSpellName then
                local curCasting = UnitCastingInfo(wSelf.targetUnit)
                if curCasting and curCasting == wSelf.expectedSpellName then
                    matches = true
                end
            end

            if not matches then return end

            if event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
                StopCraftWatcher()
                if f:IsShown() and f.botKey == botKey then
                    if NS.CB_FetchProfessions then
                        NS.CB_FetchProfessions(botKey, effectiveBotName, true)
                    end
                    if NS.CB_FetchProfessionRecipes then
                        NS.CB_FetchProfessionRecipes(botKey, effectiveBotName, skillId, true)
                    end
                else
                    f.isCrafting = false
                    if f:IsShown() and f.selectedRecipe then
                        SelectRecipe(f, f.selectedRecipe)
                    end
                end
            elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
                StopCraftWatcher()
                f.isCrafting = false
                if f:IsShown() and f.selectedRecipe then
                    SelectRecipe(f, f.selectedRecipe)
                end
            end
        end)

        -- Fallback timer in case unit events don't arrive (e.g. bot >100 yds away)
        if not watcher.timerFrame then
            watcher.timerFrame = CreateFrame("Frame")
        end
        local elapsed = 0
        local maxWait = (waitSec or 3.0) + 1.5
        watcher.timerFrame:SetScript("OnUpdate", function(tSelf, dt)
            elapsed = elapsed + dt
            if elapsed >= maxWait then
                tSelf:SetScript("OnUpdate", nil)
                if f.isCrafting then
                    StopCraftWatcher()
                    if f:IsShown() and f.botKey == botKey then
                        if NS.CB_FetchProfessions then
                            NS.CB_FetchProfessions(botKey, effectiveBotName, true)
                        end
                        if NS.CB_FetchProfessionRecipes then
                            NS.CB_FetchProfessionRecipes(botKey, effectiveBotName, skillId, true)
                        end
                    else
                        f.isCrafting = false
                        if f:IsShown() and f.selectedRecipe then
                            SelectRecipe(f, f.selectedRecipe)
                        end
                    end
                end
            end
        end)
    end

    local EQUIP_SLOT_NAMES = {
        [1]  = "Head",
        [3]  = "Shoulders",
        [5]  = "Chest",
        [6]  = "Waist",
        [7]  = "Legs",
        [8]  = "Feet",
        [9]  = "Wrist",
        [10] = "Hands",
        [11] = "Finger 1",
        [12] = "Finger 2",
        [15] = "Back",
        [16] = "Main Hand",
        [17] = "Off Hand",
    }
    local EQUIP_SLOT_ORDER = { 16, 17, 15, 5, 9, 10, 8, 11, 12, 1, 3, 6, 7 }

    local ENCHANTING_VELLUM_IDS = {
        [37602] = true, -- Armor Vellum
        [39349] = true, -- Armor Vellum II
        [43145] = true, -- Armor Vellum III
        [37603] = true, -- Weapon Vellum
        [39350] = true, -- Weapon Vellum II
        [43146] = true, -- Weapon Vellum III
    }

    local ENCHANTABLE_EQUIP_LOCS = {
        INVTYPE_2HWEAPON       = true,
        INVTYPE_WEAPON         = true,
        INVTYPE_WEAPONMAINHAND = true,
        INVTYPE_WEAPONOFFHAND  = true,
        INVTYPE_SHIELD         = true,
        INVTYPE_HOLDABLE       = true,
        INVTYPE_CLOAK          = true,
        INVTYPE_CHEST          = true,
        INVTYPE_ROBE           = true,
        INVTYPE_WRIST          = true,
        INVTYPE_HAND           = true,
        INVTYPE_FEET           = true,
        INVTYPE_FINGER         = true,
        INVTYPE_HEAD           = true,
        INVTYPE_SHOULDER       = true,
        INVTYPE_WAIST          = true,
        INVTYPE_LEGS           = true,
    }

    local function buildTargetPicker(f, anchorBtn)
        if f.TargetPicker then return f.TargetPicker end

        local picker = CreateFrame("Frame", "CleanBotProfessionsTargetPicker", anchorBtn)
        picker:SetFrameStrata("DIALOG")
        picker:SetPoint("BOTTOMLEFT", anchorBtn, "TOPLEFT", 0, 4)
        picker:SetWidth(270)
        if picker.SetBackdrop then
            picker:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            picker:SetBackdropColor(0.06, 0.06, 0.06, 0.98)
        end
        picker:Hide()
        picker:EnableMouse(true)

        local title = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        title:SetPoint("TOPLEFT", picker, "TOPLEFT", 10, -8)
        title:SetText("SELECT TARGET ITEM")
        title:SetTextColor(1, 0.82, 0)

        local closeBtn = CreateFrame("Button", nil, picker, "UIPanelCloseButton")
        closeBtn:SetSize(20, 20)
        closeBtn:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -2, -2)
        closeBtn:SetScript("OnClick", function() picker:Hide() end)

        local emptyText = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        emptyText:SetPoint("CENTER", picker, "CENTER", 0, -6)
        emptyText:SetText("No enchantable items found")
        emptyText:Hide()
        picker.emptyText = emptyText

        local scrollFrame = CreateFrame("ScrollFrame", "CleanBotTargetPickerScrollFrame", picker)
        scrollFrame:SetPoint("TOPLEFT", picker, "TOPLEFT", 6, -26)
        scrollFrame:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -6, 6)
        scrollFrame:EnableMouseWheel(true)

        local content = CreateFrame("Frame", nil, scrollFrame)
        content:SetWidth(256)
        content:SetHeight(1)
        scrollFrame:SetScrollChild(content)

        local rows = {}
        picker.rows = rows

        scrollFrame:SetScript("OnMouseWheel", function(self, delta)
            local cur = self:GetVerticalScroll() or 0
            local maxScroll = math.max(0, (content:GetHeight() or 0) - (self:GetHeight() or 0))
            local newScroll = math.max(0, math.min(maxScroll, cur - delta * 26))
            self:SetVerticalScroll(newScroll)
        end)

        picker.RefreshItems = function(self)
            local botKey = f.botKey
            local entry = CleanBot_PartyBots and CleanBot_PartyBots[botKey]
            local effectiveBotName = (entry and entry.name) or f.botName or botKey
            local unit = (NS.CB_FindPartyUnit and NS.CB_FindPartyUnit(effectiveBotName)) or (entry and entry.unit)

            local equippedItems = {}
            if unit then
                for _, slotId in ipairs(EQUIP_SLOT_ORDER) do
                    local link = GetInventoryItemLink(unit, slotId)
                    if link then
                        local name, _, quality, _, _, _, _, _, _, texture = GetItemInfo(link)
                        local itemId = tonumber(link:match("item:(%d+)"))
                        if itemId and itemId > 0 then
                            table.insert(equippedItems, {
                                isEquipped = true,
                                slotId     = slotId,
                                targetBag  = 255,
                                targetSlot = slotId - 1,
                                slotName   = EQUIP_SLOT_NAMES[slotId] or ("Slot " .. slotId),
                                itemId     = itemId,
                                link       = link,
                                name       = name or ("Item " .. itemId),
                                quality    = quality or 1,
                                texture    = texture or (GetInventoryItemTexture and GetInventoryItemTexture(unit, slotId)) or "Interface\\Icons\\INV_Misc_QuestionMark",
                            })
                        end
                    end
                end
            end

            local bagItems = {}
            if entry and entry.inventory and entry.inventory.items then
                for _, it in ipairs(entry.inventory.items) do
                    if it.link and it.itemId and it.itemId > 0 then
                        local name, _, quality, _, _, _, _, _, equipLoc, texture = GetItemInfo(it.link)
                        local isVellum = ENCHANTING_VELLUM_IDS[it.itemId]
                        local isEnchantableGear = equipLoc and ENCHANTABLE_EQUIP_LOCS[equipLoc]
                        if isVellum or isEnchantableGear then
                            local bagText = (it.bag == 0) and "Backpack" or string.format("Bag %d", it.bag)
                            if it.count and it.count > 1 then
                                bagText = string.format("%s (x%d)", bagText, it.count)
                            end
                            table.insert(bagItems, {
                                isEquipped = false,
                                targetBag  = it.bag,
                                targetSlot = it.slot,
                                slotName   = bagText,
                                itemId     = it.itemId,
                                link       = it.link,
                                name       = name or (isVellum and "Enchanting Vellum") or ("Item " .. it.itemId),
                                quality    = quality or (isVellum and 1) or 1,
                                texture    = texture or "Interface\\Icons\\INV_Misc_QuestionMark",
                            })
                        end
                    end
                end
            end

            local items = {}
            if #equippedItems > 0 and #bagItems > 0 then
                table.insert(items, { isHeader = true, title = "EQUIPPED" })
                for _, it in ipairs(equippedItems) do table.insert(items, it) end
                table.insert(items, { isHeader = true, title = "INVENTORY" })
                for _, it in ipairs(bagItems) do table.insert(items, it) end
            elseif #equippedItems > 0 then
                table.insert(items, { isHeader = true, title = "EQUIPPED" })
                for _, it in ipairs(equippedItems) do table.insert(items, it) end
            elseif #bagItems > 0 then
                table.insert(items, { isHeader = true, title = "INVENTORY" })
                for _, it in ipairs(bagItems) do table.insert(items, it) end
            end

            local count = #items
            if count == 0 then
                emptyText:Show()
                picker:SetHeight(80)
                scrollFrame:SetHeight(48)
                content:SetHeight(1)
                for _, r in ipairs(rows) do r:Hide() end
                return
            end

            emptyText:Hide()
            local yOffset = 0

            for i = 1, count do
                local itemData = items[i]
                local row = rows[i]
                if not row then
                    row = CreateFrame("Button", nil, content)
                    row:SetPoint("LEFT", content, "LEFT", 2, 0)
                    row:SetPoint("RIGHT", content, "RIGHT", -2, 0)

                    local icon = row:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(20, 20)
                    icon:SetPoint("LEFT", row, "LEFT", 2, 0)
                    row.icon = icon

                    local slotLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                    slotLabel:SetPoint("RIGHT", row, "RIGHT", -4, 0)
                    slotLabel:SetJustifyH("RIGHT")
                    row.slotLabel = slotLabel

                    local nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                    nameLabel:SetPoint("LEFT", icon, "RIGHT", 4, 0)
                    nameLabel:SetPoint("RIGHT", slotLabel, "LEFT", -4, 0)
                    nameLabel:SetJustifyH("LEFT")
                    row.nameLabel = nameLabel

                    local hov = row:CreateTexture(nil, "HIGHLIGHT")
                    hov:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
                    hov:SetBlendMode("ADD")
                    hov:SetAllPoints()
                    hov:SetAlpha(0.4)
                    row.hov = hov

                    row:SetScript("OnEnter", function(rSelf)
                        if rSelf.isHeader then return end
                        if rSelf.itemLink and GameTooltip then
                            GameTooltip:SetOwner(rSelf, "ANCHOR_RIGHT")
                            GameTooltip:SetHyperlink(rSelf.itemLink)
                            GameTooltip:Show()
                        end
                    end)
                    row:SetScript("OnLeave", function()
                        if GameTooltip then GameTooltip:Hide() end
                    end)

                    row:SetScript("OnClick", function(rSelf)
                        if rSelf.isHeader or not picker.recipe then return end
                        local r = picker.recipe
                        local bKey = f.botKey
                        local bEntry = CleanBot_PartyBots and CleanBot_PartyBots[bKey]
                        local bName = (bEntry and bEntry.name) or f.botName or bKey
                        local bUnit = (NS.CB_FindPartyUnit and NS.CB_FindPartyUnit(bName)) or (bEntry and bEntry.unit)
                        if not bUnit then return end

                        local targetItemId = rSelf.itemId
                        local targetBag = rSelf.targetBag
                        local targetSlot = rSelf.targetSlot

                        if rSelf.isEquipped then
                            local freshLink = GetInventoryItemLink(bUnit, rSelf.slotId)
                            local freshItemId = freshLink and tonumber(freshLink:match("item:(%d+)"))
                            if not freshItemId or freshItemId <= 0 then
                                picker:RefreshItems()
                                if NS.CB_Print then
                                    NS.CB_Print(string.format("%s: Selected item is no longer equipped.", bName))
                                end
                                return
                            end
                            targetItemId = freshItemId
                        end

                        picker:Hide()

                        local skillId = r.skillId or (f.currentProf and NS.PROF_NAME_TO_SKILL_ID and (NS.PROF_NAME_TO_SKILL_ID[f.currentProf] or NS.PROF_NAME_TO_SKILL_ID[f.currentProf:lower()]))
                        if not skillId then return end

                        f.isCrafting = true
                        f.CreateButton:Disable()
                        f.CreateButton:SetText("Crafting...")

                        local castDuration = 2.0
                        local expectedSpellName = r.name
                        if GetSpellInfo then
                            local sName, _, _, _, _, _, castTime = GetSpellInfo(r.spellId)
                            if sName and sName ~= "" then expectedSpellName = sName end
                            if castTime and castTime > 0 then castDuration = castTime / 1000 end
                        end
                        local waitSec = castDuration + 0.5

                        local sent = NS.CB_BridgeCraftRecipeTarget and NS.CB_BridgeCraftRecipeTarget(bKey, bName, skillId, r.spellId, targetBag, targetSlot, targetItemId, function(success, reason)
                            if not success then
                                StopCraftWatcher()
                                f.isCrafting = false
                                if f:IsShown() and f.selectedRecipe == r then
                                    SelectRecipe(f, r)
                                end
                                return
                            end
                            StartCraftWatcher(bUnit, expectedSpellName, r.spellId, bKey, bName, skillId, waitSec)
                        end)

                        if not sent then
                            StopCraftWatcher()
                            f.isCrafting = false
                            SelectRecipe(f, r)
                        end
                    end)

                    rows[i] = row
                end

                local rowH = itemData.isHeader and 20 or 26
                row:SetHeight(rowH)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, -yOffset)
                row:SetPoint("RIGHT", content, "RIGHT", -2, 0)
                yOffset = yOffset + rowH

                row.isHeader   = itemData.isHeader
                row.isEquipped = itemData.isEquipped
                row.slotId     = itemData.slotId
                row.targetBag  = itemData.targetBag
                row.targetSlot = itemData.targetSlot
                row.itemId     = itemData.itemId
                row.itemLink   = itemData.link

                if itemData.isHeader then
                    row.icon:Hide()
                    row.slotLabel:Hide()
                    row.nameLabel:ClearAllPoints()
                    row.nameLabel:SetPoint("LEFT", row, "LEFT", 4, 0)
                    row.nameLabel:SetPoint("RIGHT", row, "RIGHT", -4, 0)
                    row.nameLabel:SetText("|cffffd200-- " .. itemData.title .. " --|r")
                    row:EnableMouse(false)
                else
                    row.icon:Show()
                    row.icon:SetTexture(itemData.texture)
                    row.slotLabel:Show()
                    row.slotLabel:SetText(itemData.slotName)
                    row.nameLabel:ClearAllPoints()
                    row.nameLabel:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
                    row.nameLabel:SetPoint("RIGHT", row.slotLabel, "LEFT", -4, 0)
                    row.nameLabel:SetText(itemData.name)
                    local rQual, gQual, bQual = GetItemQualityColor(itemData.quality)
                    if rQual then
                        row.nameLabel:SetTextColor(rQual, gQual, bQual)
                    else
                        row.nameLabel:SetTextColor(1, 1, 1)
                    end
                    row:EnableMouse(true)
                end
                row:Show()
            end

            for i = count + 1, #rows do
                rows[i]:Hide()
            end

            content:SetHeight(math.max(1, yOffset))
            local visibleH = math.min(math.max(48, yOffset), 220)
            picker:SetHeight(38 + visibleH)
            scrollFrame:SetHeight(visibleH)
        end

        picker:RegisterEvent("INSPECT_TALENT_READY")
        picker:RegisterEvent("CHAT_MSG_ADDON")
        picker:SetScript("OnEvent", function(pSelf, pEvent, pPrefix, pMsg)
            if not pSelf:IsShown() then return end
            if pEvent == "INSPECT_TALENT_READY" then
                pSelf:RefreshItems()
            elseif pEvent == "CHAT_MSG_ADDON" and pPrefix == "MBOT" and pMsg then
                if strsub(pMsg, 1, 14) == "INV_EXACT_END~" or strsub(pMsg, 1, 8) == "INV_END~" then
                    pSelf:RefreshItems()
                end
            end
        end)

        picker.ShowPicker = function(pSelf, recipe)
            pSelf.recipe = recipe
            local botKey = f.botKey
            local entry = CleanBot_PartyBots and CleanBot_PartyBots[botKey]
            local effectiveBotName = (entry and entry.name) or f.botName or botKey
            local unit = (NS.CB_FindPartyUnit and NS.CB_FindPartyUnit(effectiveBotName)) or (entry and entry.unit)
            if unit and NotifyInspect and (CheckInteractDistance == nil or CheckInteractDistance(unit, 1)) then
                NotifyInspect(unit)
            end
            if botKey and effectiveBotName and NS.CB_FetchInventory then
                NS.CB_FetchInventory(botKey, effectiveBotName)
            end
            pSelf:RefreshItems()
            scrollFrame:SetVerticalScroll(0)
            pSelf:Show()
        end

        f.TargetPicker = picker
        return picker
    end

    createBtn:SetScript("OnClick", function(self)
        if f.isCrafting then return end
        local r = f.selectedRecipe
        if not r or not r.spellId then return end
        if not (r.numAvailable and r.numAvailable > 0) then return end

        local hasItem = r.itemId and r.itemId > 0
        if not hasItem then
            local picker = buildTargetPicker(f, createBtn)
            if picker:IsShown() then
                picker:Hide()
            else
                picker:ShowPicker(r)
            end
            return
        end

        local botKey = f.botKey
        local entry = CleanBot_PartyBots and CleanBot_PartyBots[botKey]
        local effectiveBotName = (entry and entry.name) or f.botName or botKey
        if not effectiveBotName then return end

        local skillId = r.skillId or (f.currentProf and NS.PROF_NAME_TO_SKILL_ID and (NS.PROF_NAME_TO_SKILL_ID[f.currentProf] or NS.PROF_NAME_TO_SKILL_ID[f.currentProf:lower()]))
        if not skillId then return end

        f.isCrafting = true
        self:Disable()
        self:SetText("Crafting...")

        local castDuration = 2.0
        local expectedSpellName = r.name
        if GetSpellInfo then
            local sName, _, _, _, _, _, castTime = GetSpellInfo(r.spellId)
            if sName and sName ~= "" then
                expectedSpellName = sName
            end
            if castTime and castTime > 0 then
                castDuration = castTime / 1000
            end
        end
        local waitSec = castDuration + 0.5
        local targetUnit = NS.CB_FindPartyUnit and NS.CB_FindPartyUnit(effectiveBotName)

        local sent = NS.CB_BridgeCraftRecipe and NS.CB_BridgeCraftRecipe(botKey, effectiveBotName, skillId, r.spellId, r.itemId, function(success, reason)
            if not success then
                StopCraftWatcher()
                f.isCrafting = false
                if f:IsShown() and f.selectedRecipe == r then
                    SelectRecipe(f, r)
                end
                return
            end

            -- Bot started casting; activate reactive watcher + fallback timer
            StartCraftWatcher(targetUnit, expectedSpellName, r.spellId, botKey, effectiveBotName, skillId, waitSec)
        end)

        if not sent then
            StopCraftWatcher()
            f.isCrafting = false
            SelectRecipe(f, r)
        end
    end)

    createAllBtn:SetScript("OnClick", function()
        -- Reserved for future polling sequencer
    end)

    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(self, event)
        if event == "GET_ITEM_INFO_RECEIVED" and self:IsShown() and self.rawRecipes then
            self.recipeTree = BuildRecipeTree(self.rawRecipes)
            RefreshRecipeList(self)
            if self.selectedRecipe then
                SelectRecipe(self, self.selectedRecipe)
            end
        end
    end)

    local oldOnHide = f:GetScript("OnHide")
    f:SetScript("OnHide", function(self)
        if oldOnHide then oldOnHide(self) end
        if f.TargetPicker then
            f.TargetPicker:Hide()
        end
        if f.StopCraftWatcher then
            f.StopCraftWatcher()
        end
        f.isCrafting = false
    end)

    NS.botProfessionsFrame = f
    return f
end

local function UpdateRankBar(f, profName)
    if not f or not f.RankBar then return end
    profName = profName or f.currentProf or "Engineering"
    local prof = GetProfConfig(profName)
    if not prof then return end

    local entry = CleanBot_PartyBots and f.botKey and CleanBot_PartyBots[f.botKey]
    local curRank, maxRank = 0, 0
    local skillId = NS.PROF_NAME_TO_SKILL_ID and (NS.PROF_NAME_TO_SKILL_ID[profName] or NS.PROF_NAME_TO_SKILL_ID[profName:lower()])
    if entry and entry.professions then
        for _, p in ipairs(entry.professions) do
            if p.key == profName or p.name == profName or (p.name and p.name:lower() == profName:lower()) or (p.key and p.key:lower() == profName:lower()) or (skillId and p.skillId == skillId) then
                curRank = p.cur or 0
                maxRank = p.max or 0
                skillId = p.skillId or skillId
                break
            end
        end
    end
    if skillId then
        f.currentSkillId = skillId
    end

    -- Chat link button
    if f.linkBtn then
        f.linkBtn:SetScript("OnClick", function()
            if NS.CB_Print then
                NS.CB_Print(string.format("%s (%d/%d)", prof.title or profName, curRank, maxRank))
            end
        end)
    end

    local rb = f.RankBar
    local rankFrac = (maxRank > 0) and (curRank / maxRank) or 0
    if rankFrac > 1 then rankFrac = 1 end
    if rankFrac < 0 then rankFrac = 0 end

    local generic = (f.opts and f.opts.genericBar) or not prof.flip
    rb._genericFill = generic

    local animate = (rb._ratio ~= nil) and (rb._rankShown ~= nil)
        and (rb._profKey == profName) and (rb._botKey == f.botKey)
        and (rb._maxRank == maxRank)
        and (rb._genericFill == generic)
        and (rb._ratio ~= rankFrac)
        and (not rb._snapNext)
        and f:IsShown()

    rb._snapNext = nil
    rb._profKey = profName
    rb._botKey = f.botKey
    rb._maxRank = maxRank

    if rb.fill then
        if generic then
            StopFlipAnimation(rb.fill)
            rb._flipping = false
            rb._flipTexture = nil
            rb.fill:SetTexCoord(0, 1, 0, 1)
            rb.fill:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
            rb.fill:SetVertexColor(0.12, 0.75, 0.22, 1)
            rb._flareInfo = nil
            if rb.flare then rb.flare:Hide() end
        elseif prof.flip then
            rb.fill:SetVertexColor(1, 1, 1, 1)
            if rb._flipTexture ~= prof.flip or not rb._flipping then
                StartFlipAnimation(rb.fill, prof.flip, prof, rankFrac)
                rb._flipping = true
                rb._flipTexture = prof.flip
            end
            rb._flareInfo = { top = prof.top, flip = prof.flip }
            if rb.flare then
                rb.flare:SetTexture(prof.flip)
            end
        else
            StopFlipAnimation(rb.fill)
            rb._flipping = false
            rb._flipTexture = nil
            rb._flareInfo = nil
            if rb.flare then rb.flare:Hide() end
        end
    end

    setFillFrac(rb, rankFrac, curRank, maxRank, animate)
end

-- ── Render Frame ─────────────────────────────────────────────────────────
NS.CB_RenderProfessions = function(f, profName)
    if not f then return end
    profName = profName or f.currentProf or "Engineering"
    local prof = GetProfConfig(profName)
    if not prof then return end
    profName = prof.title or profName
    if f.currentProf ~= profName then
        if f.RankBar then
            f.RankBar._snapNext = true
        end
        f.selectedRecipe = nil
        ResetFilters(f)
    end
    f.currentProf = profName

    local entry = CleanBot_PartyBots and f.botKey and CleanBot_PartyBots[f.botKey]
    UpdateRankBar(f, profName)
    local skillId = f.currentSkillId

    -- Window title: "Profession (BotName)" (ej: "Engineering (Pepe)")
    if f.title then
        local bName = (entry and entry.name) or f.botName or "Bot"
        local botClass = (entry and entry.class)
        local c = botClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[botClass]

        local formattedBot = c and string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, bName) or bName
        f.title:SetText(string.format("%s (%s)", prof.title or profName, formattedBot))
        if f.headerBtn then
            local tw = f.title:GetStringWidth() or 100
            f.headerBtn:SetWidth(tw + 25)
        end
        if f.headerArrow then
            local isExpanded = f.ProfDropdown and f.ProfDropdown:IsShown()
            ApplyAtlas(f.headerArrow, isExpanded and ATLAS.catExpand or ATLAS.catCollapse)
        end
    end

    -- Portrait icon
    if f.portrait and prof.portrait then
        f.portrait:SetTexture(prof.portrait)
        if f.portrait.SetMask then
            f.portrait:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        end
    end

    -- Schematic background
    if f.SchematicForm and f.SchematicForm.bg and prof.bg then
        f.SchematicForm.bg:SetTexture(prof.bg)
        f.SchematicForm.bg:SetTexCoord(0.000977, 0.660156, 0.000977, 0.536133)
    end

    -- Query / Render recipes
    local cachedRecipes = nil
    if entry and entry.professionRecipes and skillId then
        local c = entry.professionRecipes[skillId]
        cachedRecipes = c and c.recipes
    end

    if cachedRecipes then
        f.rawRecipes = cachedRecipes
        f.recipeTree = BuildRecipeTree(cachedRecipes)
        RefreshRecipeList(f)

        local targetRecipe = nil
        local prevSpellId = f.selectedRecipe and f.selectedRecipe.spellId
        local prevName = f.selectedRecipe and f.selectedRecipe.name
        if f.recipeTree and (prevSpellId or prevName) then
            for _, cat in ipairs(f.recipeTree) do
                for _, r in ipairs(cat.recipes or {}) do
                    if (prevSpellId and r.spellId == prevSpellId) or (prevName and r.name == prevName) then
                        targetRecipe = r
                        break
                    end
                end
                if targetRecipe then break end
            end
        end

        SelectRecipe(f, targetRecipe)
    else
        f.rawRecipes = nil
        f.recipeTree = {}
        RefreshRecipeList(f)
        SelectRecipe(f, nil)
    end

    if skillId and NS.CB_FetchProfessionRecipes then
        NS.CB_FetchProfessionRecipes(f.botKey, f.botName, skillId)
    end
end

-- ── Callbacks for Bridge events ───────────────────────────────────────────
NS.CB_OnProfessionsUpdated = function(key)
    local f = NS.botProfessionsFrame
    if f and f:IsShown() and f.botKey == key then
        if f.ProfDropdown and f.ProfDropdown.Refresh then
            f.ProfDropdown.Refresh()
        end
        local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
        if entry and entry.professions and #entry.professions > 0 then
            local currentValid = false
            if f.currentProf then
                for _, p in ipairs(entry.professions) do
                    if p.key == f.currentProf or p.name == f.currentProf or (p.name and p.name:lower() == f.currentProf:lower()) or (p.key and p.key:lower() == f.currentProf:lower()) then
                        currentValid = true
                        break
                    end
                end
            end
            local targetProf = currentValid and f.currentProf or (entry.professions[1].key or entry.professions[1].name)
            if currentValid and f.currentProf then
                UpdateRankBar(f, targetProf)
            else
                NS.CB_RenderProfessions(f, targetProf)
            end
        end
    end
end

NS.CB_OnProfessionRecipesLoaded = function(key, skillId, recipes)
    local f = NS.botProfessionsFrame
    if f and f:IsShown() and f.botKey == key and f.currentSkillId == skillId then
        f.isCrafting = false
        f.rawRecipes = recipes
        f.recipeTree = BuildRecipeTree(recipes)
        RefreshRecipeList(f)

        local targetRecipe = nil
        local prevSpellId = f.selectedRecipe and f.selectedRecipe.spellId
        local prevName = f.selectedRecipe and f.selectedRecipe.name
        if f.recipeTree and (prevSpellId or prevName) then
            for _, cat in ipairs(f.recipeTree) do
                for _, r in ipairs(cat.recipes or {}) do
                    if (prevSpellId and r.spellId == prevSpellId) or (prevName and r.name == prevName) then
                        targetRecipe = r
                        break
                    end
                end
                if targetRecipe then break end
            end
        end

        SelectRecipe(f, targetRecipe)
    end
end

-- ── Open / Toggle Entry Point ─────────────────────────────────────────────
NS.CB_ToggleProfessions = function(key, botName, anchor)
    local f = NS.CB_GetProfessionsFrame(key, botName)
    if not f then return end

    if f:IsShown() and f.botKey == key then
        f:Hide()
        return
    end

    if (f.botKey ~= key or not f:IsShown()) and f.RankBar then
        f.RankBar._snapNext = true
    end
    if f.botKey ~= key then
        f.selectedRecipe = nil
    end
    f.botKey  = key
    f.botName = botName or key

    if anchor == "CENTER" then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    elseif not f:GetPoint() then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end

    if NS.CB_FetchProfessions then
        NS.CB_FetchProfessions(key, botName)
    end

    local entry = CleanBot_PartyBots and CleanBot_PartyBots[key]
    local targetProf = f.currentProf
    if entry and entry.professions and #entry.professions > 0 then
        local found = false
        if targetProf then
            for _, p in ipairs(entry.professions) do
                if p.key == targetProf or p.name == targetProf then
                    found = true
                    break
                end
            end
        end
        if not found then
            targetProf = entry.professions[1].key or entry.professions[1].name
        end
    end

    f:Show()
    NS.CB_RenderProfessions(f, targetProf)
end

-- ── Button Factory for Equip Panel ────────────────────────────────────────
NS.CB_CreateProfessionsButton = function(slot, model, slotSize)
    local btn = NS.CB_CreateIconButton(model, "CleanBotProfessionsBtn_" .. slot.index,
        "Interface\\Icons\\Trade_Engineering", slotSize)

    -- Anchor immediately to the left of quest button (balancing with Bag/Spellbook on the left)
    if slot.questBtn then
        btn:SetPoint("RIGHT", slot.questBtn, "LEFT", -4, 0)
        btn:SetPoint("TOP",   slot.questBtn, "TOP",   0, 0)
    elseif slot.spellbookBtn then
        btn:SetPoint("LEFT", slot.spellbookBtn, "RIGHT", 4, 0)
        btn:SetPoint("TOP",  slot.spellbookBtn, "TOP",   0, 0)
    elseif slot.bagBtn then
        btn:SetPoint("LEFT", slot.bagBtn, "RIGHT", 4, 0)
        btn:SetPoint("TOP",  slot.bagBtn, "TOP",   0, 0)
    else
        btn:SetPoint("RIGHT", slot.equipSlots[14], "LEFT", -6, 0)
        btn:SetPoint("TOP",   slot.equipSlots[16], "TOP",  0, 0)
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
        NS.CB_ToggleProfessions(key, botName)
    end)
    NS.CB_SetTooltip(btn, function()
        local isBridge = not NS.CB_EffectiveBridgeState or (NS.CB_EffectiveBridgeState() == "present")
        return isBridge and "Professions" or "Professions (Requires Bridge)"
    end, function()
        local isBridge = not NS.CB_EffectiveBridgeState or (NS.CB_EffectiveBridgeState() == "present")
        if not isBridge then
            return "|cffff2020Server Requirement:|r\nRequires mod-multibot-bridge installed on the server."
        end
        return "View this bot's professions and craft items."
    end)

    slot.professionsBtn = btn
end
