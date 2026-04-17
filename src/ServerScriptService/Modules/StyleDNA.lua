--[[
    StyleDNA
    ────────
    Tracks how each player expresses their personal style over time.
    Every successful outfit submission is analysed and points are
    accumulated into four style score buckets. A DominantStyle and a
    tiered label are derived from the accumulated totals.

    Analysis inputs (all server-side from the stored OutfitData):
        1. Colour palette   – brightness + saturation of ColorPrimary/Secondary
        2. StyleTags        – explicit style hints on the outfit (direct mapping)
        3. Slot completeness – how many clothing slots (head/top/bottom/shoes) filled
        4. Accessories      – quantity signals personality intensity

    DataStore compatibility:
        PlayerData.StyleDNA contains only plain Lua primitives (numbers, strings,
        nested tables of same). No userdata, no functions. Safe for DataStoreService.

    Score accumulation:
        Scores grow additively each round. They are never reset, giving a long-term
        record of style identity. "Mixed" is declared when the two highest scores
        are within 20% of each other.

    Dependencies (injected via Init):
        PlayerDataManager, Logger

    Public API:
        StyleDNA.Init(playerDataManager, logger)
        StyleDNA.UpdateStyleDNA(player, outfitData)
        StyleDNA.RecalculateDominantStyle(userId)
        StyleDNA.GetPlayerStyle(player)  -> StyleProfile
        StyleDNA.GetStyleLabel(userId)   -> string

    StyleProfile:
    {
        StyleScores    : { Streetwear, Luxury, Casual, Experimental },
        DominantStyle  : string,   -- "Streetwear"|"Luxury"|"Casual"|"Experimental"|"Mixed"|"None"
        Label          : string,   -- tiered display label, e.g. "Drip Dealer"
        RoundsAnalyzed : number,
    }
--]]

local StyleDNA = {}

-- ── Style categories ──────────────────────────────────────────────────────────

local CATEGORIES = { "Streetwear", "Luxury", "Casual", "Experimental" }

local function newDelta()
    return { Streetwear = 0, Luxury = 0, Casual = 0, Experimental = 0 }
end

local function addTo(base, delta)
    for _, cat in ipairs(CATEGORIES) do
        base[cat] = base[cat] + (delta[cat] or 0)
    end
end

-- ── Tag → style weight table ─────────────────────────────────────────────────
-- Covers every tag used in ThemeSystem.THEMES and the outfit StyleTags field.
-- Add new tags here as the game expands; no other code needs to change.

local TAG_WEIGHTS = {
    -- ── Streetwear axis ──────────────────────────────────────────────────────
    Streetwear   = { Streetwear = 3 },
    Hype         = { Streetwear = 2 },
    Urban        = { Streetwear = 2 },
    Dark         = { Streetwear = 2, Experimental = 1 },
    Techwear     = { Streetwear = 1, Experimental = 2 },
    Sporty       = { Streetwear = 1, Casual = 1 },
    Cool         = { Streetwear = 1, Experimental = 1 },

    -- ── Luxury axis ──────────────────────────────────────────────────────────
    Elegant      = { Luxury = 3 },
    Glamorous    = { Luxury = 3 },
    Formal       = { Luxury = 2 },
    Minimalist   = { Luxury = 2, Casual = 1 },
    Historical   = { Luxury = 1, Casual = 1 },
    Cultural     = { Luxury = 1, Experimental = 1 },
    Intellectual = { Luxury = 1, Casual = 1 },
    Vintage      = { Luxury = 1, Casual = 1 },
    Retro        = { Casual = 1, Experimental = 1 },

    -- ── Casual axis ───────────────────────────────────────────────────────────
    Casual       = { Casual = 3 },
    Soft         = { Casual = 2 },
    Cute         = { Casual = 2 },
    Fun          = { Casual = 2 },
    Feminine     = { Casual = 1, Luxury = 1 },
    Nature       = { Casual = 1 },
    Earthy       = { Casual = 2 },
    Bohemian     = { Casual = 2, Experimental = 1 },
    Playful      = { Casual = 2, Experimental = 1 },

    -- ── Experimental axis ────────────────────────────────────────────────────
    Experimental = { Experimental = 3 },
    Eclectic     = { Experimental = 3 },
    Colourful    = { Experimental = 3 },
    Bold         = { Experimental = 2 },
    Fantasy      = { Experimental = 2, Casual = 1 },
    Futuristic   = { Experimental = 2, Streetwear = 1 },
    ["Sci-Fi"]   = { Experimental = 3 },
    Exotic       = { Experimental = 2 },
}

-- ── Tiered display labels ─────────────────────────────────────────────────────
-- Entries must be ordered highest minScore first.

local LABELS = {
    Streetwear = {
        { minScore = 60, label = "Hype Architect"    },
        { minScore = 30, label = "Drip Dealer"        },
        { minScore = 10, label = "Street Scout"       },
        { minScore = 0,  label = "Curb Crawler"       },
    },
    Luxury = {
        { minScore = 60, label = "Couture Crown"      },
        { minScore = 30, label = "Velvet Vision"      },
        { minScore = 10, label = "Gilt Gazer"         },
        { minScore = 0,  label = "Aspiring Elite"     },
    },
    Casual = {
        { minScore = 60, label = "Comfort Icon"       },
        { minScore = 30, label = "Chill Curator"      },
        { minScore = 10, label = "Laid-Back Legend"   },
        { minScore = 0,  label = "Easy Rider"         },
    },
    Experimental = {
        { minScore = 60, label = "Avant-Garde Alien"  },
        { minScore = 30, label = "Chaos Creator"      },
        { minScore = 10, label = "Rule Bender"        },
        { minScore = 0,  label = "Curious Dresser"    },
    },
    Mixed = {
        { minScore = 0,  label = "Style Shapeshifter" },
    },
    None = {
        { minScore = 0,  label = "Style Seeker"       },
    },
}

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil

local EMPTY_STYLE_PROFILE = {
    StyleScores = {
        Streetwear   = 0,
        Luxury       = 0,
        Casual       = 0,
        Experimental = 0,
    },
    DominantStyle  = "None",
    Label          = "Style Seeker",
    RoundsAnalyzed = 0,
}

local function copyEmptyProfile()
    return {
        StyleScores = {
            Streetwear   = EMPTY_STYLE_PROFILE.StyleScores.Streetwear,
            Luxury       = EMPTY_STYLE_PROFILE.StyleScores.Luxury,
            Casual       = EMPTY_STYLE_PROFILE.StyleScores.Casual,
            Experimental = EMPTY_STYLE_PROFILE.StyleScores.Experimental,
        },
        DominantStyle  = EMPTY_STYLE_PROFILE.DominantStyle,
        Label          = EMPTY_STYLE_PROFILE.Label,
        RoundsAnalyzed = EMPTY_STYLE_PROFILE.RoundsAnalyzed,
    }
end

-- ── Analysis helpers ──────────────────────────────────────────────────────────

--- Derives style points from a single {r, g, b} colour (all components 0..1).
--- Returns a delta table.
local function analyzeColor(r, g, b)
    local delta = newDelta()
    if not (r and g and b) then return delta end

    local brightness  = (r + g + b) / 3
    local maxC        = math.max(r, g, b)
    local minC        = math.min(r, g, b)
    local saturation  = maxC > 0 and ((maxC - minC) / maxC) or 0

    -- Dark colours  → Streetwear
    if brightness < 0.20 then
        delta.Streetwear = delta.Streetwear + 2
    end

    -- Pure white / light grey / silver  → Luxury
    if brightness > 0.80 and saturation < 0.15 then
        delta.Luxury = delta.Luxury + 2
    end

    -- Vivid, highly saturated  → Experimental
    if saturation > 0.70 then
        delta.Experimental = delta.Experimental + 3
    elseif saturation > 0.45 then
        delta.Experimental = delta.Experimental + 1
    end

    -- Muted mid-tones  → Casual
    if brightness >= 0.30 and brightness <= 0.65 and saturation < 0.35 then
        delta.Casual = delta.Casual + 2
    end

    -- Near-achromatic (greyscale family)  → Luxury (clean, minimalist)
    if saturation < 0.10 then
        delta.Luxury = delta.Luxury + 1
    end

    return delta
end

--- Analyses both colour channels from the outfit and returns combined delta.
local function analyzeColors(outfitData)
    local delta = newDelta()
    local p = outfitData.ColorPrimary
    local s = outfitData.ColorSecondary
    if p then addTo(delta, analyzeColor(p.r, p.g, p.b)) end
    if s then addTo(delta, analyzeColor(s.r, s.g, s.b)) end
    return delta
end

--- Maps StyleTags array to style points via TAG_WEIGHTS.
local function analyzeTags(outfitData)
    local delta = newDelta()
    if type(outfitData.StyleTags) ~= "table" then return delta end
    for _, tag in ipairs(outfitData.StyleTags) do
        local weights = TAG_WEIGHTS[tag]
        if weights then
            for _, cat in ipairs(CATEGORIES) do
                delta[cat] = delta[cat] + (weights[cat] or 0)
            end
        end
    end
    return delta
end

--- Derives points from how many clothing slots are occupied.
local function analyzeSlots(outfitData)
    local delta = newDelta()
    local slots = { "HeadId", "TopId", "BottomId", "ShoesId" }
    local filled = 0
    for _, slot in ipairs(slots) do
        if outfitData[slot] then filled = filled + 1 end
    end
    if filled == 4 then
        delta.Luxury = delta.Luxury + 1        -- fully dressed → polished
    elseif filled <= 1 then
        delta.Experimental = delta.Experimental + 2  -- barely dressed → rule-breaker
    end
    return delta
end

--- Derives points from accessory count.
local function analyzeAccessories(outfitData)
    local delta = newDelta()
    local count = (type(outfitData.AccessoryIds) == "table")
        and #outfitData.AccessoryIds or 0
    if count == 0 then
        delta.Luxury  = delta.Luxury + 1   -- clean / no-accessory look
        delta.Casual  = delta.Casual  + 1
    elseif count == 1 then
        delta.Luxury  = delta.Luxury + 2   -- single statement piece
    elseif count <= 3 then
        delta.Streetwear = delta.Streetwear + 1
    else
        delta.Experimental = delta.Experimental + 3  -- stacked accessories
        delta.Streetwear   = delta.Streetwear   + 1
    end
    return delta
end

--- Runs all four analysis passes and returns one combined delta.
local function analyzeOutfit(outfitData)
    local delta = newDelta()
    addTo(delta, analyzeColors(outfitData))
    addTo(delta, analyzeTags(outfitData))
    addTo(delta, analyzeSlots(outfitData))
    addTo(delta, analyzeAccessories(outfitData))
    return delta
end

--- Formats a delta table into a compact log string.
local function fmtDelta(d)
    return string.format(
        "SW+%d LX+%d CA+%d EX+%d",
        d.Streetwear, d.Luxury, d.Casual, d.Experimental)
end

--- Formats StyleScores into a compact log string.
local function fmtScores(s)
    return string.format(
        "SW:%d LX:%d CA:%d EX:%d",
        s.Streetwear, s.Luxury, s.Casual, s.Experimental)
end

-- ── DominantStyle calculation ─────────────────────────────────────────────────

--- Looks up the tiered label for a given dominant style and its top score.
local function resolveLabel(dominantStyle, topScore)
    local tiers = LABELS[dominantStyle] or LABELS["None"]
    for _, tier in ipairs(tiers) do
        if topScore >= tier.minScore then
            return tier.label
        end
    end
    return tiers[#tiers].label  -- fallback to lowest tier
end

local function resolveProfile(userId)
    local data = _playerDataManager.GetPlayerData(userId)
    if not data or not data.StyleDNA then
        return nil, copyEmptyProfile()
    end

    local dna      = data.StyleDNA
    local dominant = dna.DominantStyle or "None"
    local topScore = (dominant ~= "None" and dominant ~= "Mixed")
        and (dna.StyleScores[dominant] or 0) or 0

    return data, {
        StyleScores = {
            Streetwear   = dna.StyleScores.Streetwear or 0,
            Luxury       = dna.StyleScores.Luxury or 0,
            Casual       = dna.StyleScores.Casual or 0,
            Experimental = dna.StyleScores.Experimental or 0,
        },
        DominantStyle  = dominant,
        Label          = resolveLabel(dominant, topScore),
        RoundsAnalyzed = dna.RoundsAnalyzed or 0,
    }
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param playerDataManager  table
--- @param logger             table
function StyleDNA.Init(playerDataManager, logger)
    _playerDataManager = playerDataManager
    _logger            = logger
    _logger.info("StyleDNA", "Initialized.")
end

--- Analyses an outfit, adds points to StyleScores, and updates DominantStyle.
--- Should be called by OutfitSystem after a valid outfit is persisted.
--- @param player     Player
--- @param outfitData table  The final (server-side) outfit stored in PlayerData
function StyleDNA.UpdateStyleDNA(player, outfitData)
    local data = _playerDataManager.GetPlayerData(player.UserId)
    if not data then
        _logger.warn("StyleDNA",
            "UpdateStyleDNA: no PlayerData for " .. player.Name)
        return
    end

    local dna   = data.StyleDNA
    local delta = analyzeOutfit(outfitData)

    -- Accumulate
    for _, cat in ipairs(CATEGORIES) do
        dna.StyleScores[cat] = dna.StyleScores[cat] + delta[cat]
    end
    dna.RoundsAnalyzed = dna.RoundsAnalyzed + 1

    -- Refresh dominant style immediately
    StyleDNA.RecalculateDominantStyle(player.UserId)

    _logger.info("StyleDNA",
        player.Name
        .. "  δ[" .. fmtDelta(delta) .. "]"
        .. "  Σ[" .. fmtScores(dna.StyleScores) .. "]"
        .. "  → " .. dna.DominantStyle)
end

--- Recalculates DominantStyle from current StyleScores without adding new points.
--- Call this at the end of each round to guarantee consistency.
--- @param userId  number
function StyleDNA.RecalculateDominantStyle(userId)
    local data = _playerDataManager.GetPlayerData(userId)
    if not data then return end

    local scores = data.StyleDNA.StyleScores

    -- Find top and second-top scores
    local topStyle, topScore, secondScore = "None", 0, 0
    for _, cat in ipairs(CATEGORIES) do
        local s = scores[cat]
        if s > topScore then
            secondScore = topScore
            topScore    = s
            topStyle    = cat
        elseif s > secondScore then
            secondScore = s
        end
    end

    if topScore == 0 then
        data.StyleDNA.DominantStyle = "None"
        return
    end

    -- "Mixed" when two styles are within 20% of each other
    if secondScore > 0 and topScore < secondScore * 1.25 then
        data.StyleDNA.DominantStyle = "Mixed"
        return
    end

    data.StyleDNA.DominantStyle = topStyle
end

--- Returns the resolved style label for a given player (for UI display).
--- @param userId  number
--- @return string
function StyleDNA.GetStyleLabel(userId)
    local _, profile = resolveProfile(userId)
    return profile.Label
end

--- Returns a full StyleProfile table ready for UI consumption or DataStore save.
--- Accepts Player or userId for robust profile queries even when player object
--- is unavailable (e.g. post-leave server profile lookups).
--- @param playerOrUserId  Player|number
--- @return StyleProfile | nil
function StyleDNA.GetPlayerStyle(playerOrUserId)
    local userId = type(playerOrUserId) == "number"
        and playerOrUserId
        or (playerOrUserId and playerOrUserId.UserId)
    if not userId then
        _logger.warn("StyleDNA", "GetPlayerStyle: invalid player/userId argument.")
        return copyEmptyProfile()
    end

    local data, profile = resolveProfile(userId)
    if not data then
        _logger.info("StyleDNA",
            "GetPlayerStyle: no PlayerData for UserId " .. tostring(userId)
            .. " – returning empty profile.")
    end
    return profile
end

return StyleDNA
