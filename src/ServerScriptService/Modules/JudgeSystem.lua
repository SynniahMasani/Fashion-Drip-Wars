--[[
    JudgeSystem
    ───────────
    Replaces the static AIJudge with a personality-driven panel that scores
    outfits through the lens of individual style preferences.

    Each round 2–3 judges are randomly selected from the catalogue.  Every
    judge has FavoriteStyles, DislikedStyles (drawn from the four StyleDNA
    buckets), and a BiasStrength that scales how strongly those tastes push
    the score up or down.

    ── Per-judge scoring ────────────────────────────────────────────────────────
    For each judge on the panel:

        outfitBonus = outfit completeness signal            (max QUALITY_MAX = 0.50)
        styleNet    = (StyleMatch - StyleMismatch)          (net in [-1, 1])
                      × BiasStrength × BIAS_SCALE           (max swing = ±2.50)
        judgeScore  = clamp(baseRandom + outfitBonus + styleNet,  1.0, 10.0)

    where:
        baseRandom   ∈ [BASE_MIN, BASE_MAX]  (4.5 – 7.5)
        StyleMatch   = sum of normalised StyleDNA weights for FavoriteStyles
        StyleMismatch= sum of normalised StyleDNA weights for DislikedStyles

    Players with no StyleDNA history (all scores = 0) receive no bias
    adjustment — styleNet = 0 until they have accumulated data.

    ── Panel aggregation ────────────────────────────────────────────────────────
        panelAvg     = arithmetic mean of all judgeScores
        materialBonus= MaterialSystem.ComputeTotalBonus(outfit.Materials, theme)
        finalAIScore = clamp(panelAvg + materialBonus,  1.0, 10.0)

    Materials are applied after averaging — they are objective quality signals
    independent of any judge's taste.

    ── Voting integration ───────────────────────────────────────────────────────
    RoundManager combines scores as:
        final = playerVote × 0.60 + aiScore × 0.40
    The AI panel therefore contributes at most 40 % of the final result.

    ── Expandability ────────────────────────────────────────────────────────────
    To add a new judge: append one entry to JUDGES.  Panel selection and
    scoring are generic — no other code changes required.  BiasStrength can
    be adjusted per-season for "meta shifts" (e.g., a luxury-heavy season).

    Dependencies (injected via Init):
        StyleDNA, MaterialSystem, ThemeSystem, MetaSystem, Logger

    JudgeDef:
    {
        name        : string,
        personality : string,   -- flavour text for future client display
        Preferences : {
            FavoriteStyles : string[],  -- subset of {Streetwear, Luxury, Casual, Experimental}
            DislikedStyles : string[],
        },
        BiasStrength: number,   -- 0 = perfectly neutral, 1 = maximally biased
    }

    Public API:
        JudgeSystem.Init(styleDNA, materialSystem, themeSystem, metaSystem, logger)
        JudgeSystem.SelectJudgesForRound()           -> JudgeDef[]
        JudgeSystem.GetJudgesForRound()              -> JudgeDef[]
        JudgeSystem.ScoreOutfit(player, outfitData)  -> number  (1.0 – 10.0)
        JudgeSystem.GetAllJudges()                   -> JudgeDef[]
--]]

local JudgeSystem = {}

-- ── Judge catalogue ───────────────────────────────────────────────────────────
-- Append new entries here to expand the pool; no other code needs to change.
-- FavoriteStyles / DislikedStyles must be subsets of the four StyleDNA buckets:
--   Streetwear | Luxury | Casual | Experimental

local JUDGES = {
    {
        name        = "Viktor",
        personality = "Old-money luxury editor who considers streetwear beneath him.",
        Preferences = {
            FavoriteStyles = { "Luxury" },
            DislikedStyles = { "Casual", "Streetwear" },
        },
        BiasStrength = 0.90,
    },
    {
        name        = "Nova",
        personality = "Avant-garde art-school dropout obsessed with the unexpected.",
        Preferences = {
            FavoriteStyles = { "Experimental", "Streetwear" },
            DislikedStyles = { "Luxury" },
        },
        BiasStrength = 0.80,
    },
    {
        name        = "Celeste",
        personality = "Polished fashion director with an eye for refined minimalism.",
        Preferences = {
            FavoriteStyles = { "Luxury", "Casual" },
            DislikedStyles = { "Experimental" },
        },
        BiasStrength = 0.70,
    },
    {
        name        = "Remy",
        personality = "Street-culture archivist who lives for hype and authenticity.",
        Preferences = {
            FavoriteStyles = { "Streetwear", "Experimental" },
            DislikedStyles = { "Luxury" },
        },
        BiasStrength = 0.85,
    },
    {
        name        = "Sage",
        personality = "Laid-back lifestyle influencer who prizes wearable comfort.",
        Preferences = {
            FavoriteStyles = { "Casual", "Experimental" },
            DislikedStyles = { "Streetwear" },
        },
        BiasStrength = 0.60,
    },
    {
        name        = "Dominique",
        personality = "Ruthless couture critic who finds anything un-luxurious offensive.",
        Preferences = {
            FavoriteStyles = { "Luxury" },
            DislikedStyles = { "Casual", "Experimental" },
        },
        BiasStrength = 0.95,
    },
    {
        name        = "Kai",
        personality = "Youth-culture correspondent covering drops and collabs.",
        Preferences = {
            FavoriteStyles = { "Streetwear", "Casual" },
            DislikedStyles = { "Experimental" },
        },
        BiasStrength = 0.75,
    },
    {
        name        = "Iris",
        personality = "Futurist designer who sees every outfit as a conceptual statement.",
        Preferences = {
            FavoriteStyles = { "Experimental", "Luxury" },
            DislikedStyles = { "Streetwear" },
        },
        BiasStrength = 0.80,
    },
}

-- ── Constants ────────────────────────────────────────────────────────────────

local BASE_MIN    = 4.5   -- random score floor before bias adjustments
local BASE_MAX    = 7.5   -- random score ceiling before bias adjustments
local BIAS_SCALE  = 2.5   -- maximum points a bias swing can add or subtract
local QUALITY_MAX = 0.50  -- maximum outfit-completeness bonus (style-neutral)
local MIN_JUDGES  = 2
local MAX_JUDGES  = 3

-- ── Private state ────────────────────────────────────────────────────────────

local _styleDNA       = nil
local _materialSystem = nil
local _themeSystem    = nil
local _metaSystem     = nil
local _logger         = nil
local _panelForRound  = {}   -- JudgeDef[] selected at the top of each round

-- ── Internal helpers ─────────────────────────────────────────────────────────

--- Fisher-Yates in-place shuffle.
local function shuffle(t)
    for i = #t, 2, -1 do
        local j  = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

--- Returns how many of the four clothing slots (Head/Top/Bottom/Shoes) are filled.
local function countFilledSlots(outfitData)
    local n = 0
    for _, slot in ipairs({ "HeadId", "TopId", "BottomId", "ShoesId" }) do
        if outfitData[slot] then n = n + 1 end
    end
    return n
end

--- Returns a style-neutral completeness bonus in [0, QUALITY_MAX].
--- Slot fill contributes 60 %; accessory count (capped at 3) contributes 40 %.
--- @param outfitData  table
--- @return number
local function outfitCompleteness(outfitData)
    local slotFill = countFilledSlots(outfitData) / 4
    local accCount = outfitData.AccessoryIds
        and math.min(#outfitData.AccessoryIds, 3) or 0
    local accFill  = accCount / 3
    return (slotFill * 0.6 + accFill * 0.4) * QUALITY_MAX
end

--- Scores one outfit through a single judge's preferences.
--- styleWeight is a pre-normalised map of StyleDNA bucket → proportion (0-1).
--- An empty styleWeight (new player, no data) yields no bias — only base + quality.
--- @param judge        JudgeDef
--- @param styleWeight  { [string]: number }
--- @param outfitData   table
--- @return number  raw (unclamped) judge score
local function scoreThroughJudge(judge, styleWeight, outfitData)
    local baseScore = BASE_MIN + math.random() * (BASE_MAX - BASE_MIN)

    -- Style-neutral quality signal
    local qualityBonus = outfitCompleteness(outfitData)

    -- StyleDNA affinity signals
    local styleMatch    = 0
    local styleMismatch = 0
    for _, fav in ipairs(judge.Preferences.FavoriteStyles) do
        styleMatch = styleMatch + (styleWeight[fav] or 0)
    end
    for _, dis in ipairs(judge.Preferences.DislikedStyles) do
        styleMismatch = styleMismatch + (styleWeight[dis] or 0)
    end

    -- Formula: BaseScore + (StyleMatch × BiasStrength) - (StyleMismatch × BiasStrength)
    -- scaled so the total swing fits the 1-10 axis.
    local styleNet = (styleMatch - styleMismatch) * judge.BiasStrength * BIAS_SCALE

    return baseScore + qualityBonus + styleNet
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param styleDNA       table  StyleDNA module reference
--- @param materialSystem table  MaterialSystem module reference
--- @param themeSystem    table  ThemeSystem module reference
--- @param metaSystem     table  MetaSystem module reference
--- @param logger         table
function JudgeSystem.Init(styleDNA, materialSystem, themeSystem, metaSystem, logger)
    _styleDNA       = styleDNA
    _materialSystem = materialSystem
    _themeSystem    = themeSystem
    _metaSystem     = metaSystem
    _logger         = logger
    _logger.info("JudgeSystem",
        "Initialized with " .. #JUDGES .. " judges in the catalogue.")
end

--- Randomly selects MIN_JUDGES–MAX_JUDGES judges for the current round.
--- Call once per round (RoundManager calls this during THEME_SELECTION).
--- @return JudgeDef[]
function JudgeSystem.SelectJudgesForRound()
    -- Shallow-copy so the shuffle doesn't mutate the master catalogue order
    local pool = {}
    for _, judge in ipairs(JUDGES) do
        table.insert(pool, judge)
    end
    shuffle(pool)

    local count = math.random(MIN_JUDGES, MAX_JUDGES)
    _panelForRound = {}
    for i = 1, math.min(count, #pool) do
        table.insert(_panelForRound, pool[i])
    end

    local names = {}
    for _, j in ipairs(_panelForRound) do
        table.insert(names, j.name)
    end
    _logger.info("JudgeSystem",
        "Panel selected (" .. #_panelForRound .. " judges): "
        .. table.concat(names, ", "))

    return _panelForRound
end

--- Returns the panel selected for the current round.
--- Returns an empty table before the first SelectJudgesForRound call.
--- @return JudgeDef[]
function JudgeSystem.GetJudgesForRound()
    return _panelForRound
end

--- Scores a player's outfit through the current panel and returns a value
--- in [1.0, 10.0].
---
--- Scoring pipeline:
---   1. Build a normalised StyleDNA weight map from the player's history.
---   2. Score the outfit through every judge on the panel (base + quality + bias).
---   3. Average the judge scores.
---   4. Add any material bonuses (theme-affinity-aware).
---   5. Clamp and return.
---
--- Falls back to a full-panel scoring if SelectJudgesForRound was never called.
--- Returns 1.5 immediately for players who submitted no outfit.
---
--- @param player     Player
--- @param outfitData table | nil  PlayerData.CurrentOutfit
--- @return number
function JudgeSystem.ScoreOutfit(player, outfitData)
    if not outfitData then
        _logger.info("JudgeSystem",
            player.Name .. " submitted no outfit – score: 1.5")
        return 1.5
    end

    -- ── Build normalised StyleDNA weight map ──────────────────────────────────
    local styleWeight  = {}
    local styleProfile = _styleDNA.GetPlayerStyle(player)
    if styleProfile and styleProfile.StyleScores then
        local total = 0
        for _, v in pairs(styleProfile.StyleScores) do total = total + v end
        if total > 0 then
            for style, score in pairs(styleProfile.StyleScores) do
                styleWeight[style] = score / total
            end
        end
    end

    -- ── Score through each judge on the panel ─────────────────────────────────
    local panel = (_panelForRound and #_panelForRound > 0) and _panelForRound or JUDGES
    if not (_panelForRound and #_panelForRound > 0) then
        _logger.warn("JudgeSystem",
            "ScoreOutfit called before SelectJudgesForRound – scoring with full catalogue.")
    end

    local judgeScores = {}
    for _, judge in ipairs(panel) do
        local raw     = scoreThroughJudge(judge, styleWeight, outfitData)
        local clamped = math.max(1.0, math.min(10.0, raw))
        clamped = math.floor(clamped * 10 + 0.5) / 10
        table.insert(judgeScores, clamped)

        _logger.info("JudgeSystem", string.format(
            "  %-12s → %.1f  (%s | DNA: %s)",
            judge.name, clamped, player.Name,
            styleProfile and styleProfile.DominantStyle or "None"))
    end

    -- Arithmetic mean of judge scores
    local sum = 0
    for _, s in ipairs(judgeScores) do sum = sum + s end
    local panelAvg = sum / #judgeScores

    -- ── Apply material bonuses ────────────────────────────────────────────────
    local theme    = _themeSystem.GetCurrentTheme()
    local matBonus = _materialSystem.ComputeTotalBonus(outfitData.Materials, theme)
    if matBonus > 0 then
        _logger.info("JudgeSystem", string.format(
            "  Material bonus: +%.2f from [%s]",
            matBonus, table.concat(outfitData.Materials, ", ")))
    end

    -- ── Meta shift modifier ───────────────────────────────────────────────────
    -- Penalises overused styles and rewards underused ones based on server-wide
    -- usage history.  Only applied when the player has a clear dominant style
    -- (Mixed/None receive no modifier — their impact is already balanced).
    local dominantStyle = styleProfile and styleProfile.DominantStyle or "None"
    local metaMod       = _metaSystem.GetStyleModifier(dominantStyle)
    if metaMod ~= 0 then
        local metaStatus = metaMod < 0 and "Overused" or "Underused"
        _logger.info("JudgeSystem", string.format(
            "  Meta: %+.2f  [%s → %s]",
            metaMod, dominantStyle, metaStatus))
    end
    -- ─────────────────────────────────────────────────────────────────────────

    local finalScore = math.max(1.0, math.min(10.0, panelAvg + matBonus + metaMod))
    finalScore = math.floor(finalScore * 10 + 0.5) / 10

    _logger.info("JudgeSystem", string.format(
        "%s  panel avg: %.1f  mat: %+.2f  meta: %+.2f  →  AI score: %.1f",
        player.Name, panelAvg, matBonus, metaMod, finalScore))

    return finalScore
end

--- Returns the full judge catalogue.  Treat as read-only; do not mutate.
--- @return JudgeDef[]
function JudgeSystem.GetAllJudges()
    return JUDGES
end

return JudgeSystem
