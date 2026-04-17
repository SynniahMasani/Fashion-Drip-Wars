--[[
    AIJudge  *** SUPERSEDED — DO NOT USE ***
    ────────────────────────────────────────
    This module has been replaced by JudgeSystem (Modules/JudgeSystem.lua),
    which provides a personality-driven panel of judges with StyleDNA affinity,
    material bonuses, and meta-shift modifiers.

    GameController no longer loads AIJudge.  This file is retained for reference
    only.  It will be removed in a future cleanup pass.

    Original purpose:
        Phase 0 randomised scorer (3.0 – 9.5) with stub material bonuses.

    Replaced by:
        JudgeSystem.Init(styleDNA, materialSystem, themeSystem, metaSystem, logger)
        JudgeSystem.SelectJudgesForRound()
        JudgeSystem.ScoreOutfit(player, outfitData) -> number (1.0 – 10.0)
--]]

local AIJudge = {}

-- ── Constants ────────────────────────────────────────────────────────────────

local BASE_MIN   = 3.0  -- floor for a submitted outfit
local BASE_MAX   = 9.5  -- ceiling before bonuses
local EMPTY_SCORE = 1.5 -- score when no outfit was submitted

-- ── Private state ────────────────────────────────────────────────────────────

local _materialSystem = nil
local _logger         = nil

-- ── Internal helpers ─────────────────────────────────────────────────────────

--- Checks whether two string arrays share any element (used for tag matching).
local function tagsIntersect(outfitTags, themeTags)
    if not outfitTags or not themeTags then return false end
    local set = {}
    for _, t in ipairs(themeTags) do set[t] = true end
    for _, t in ipairs(outfitTags) do
        if set[t] then return true end
    end
    return false
end

--- Counts non-nil fields in the outfit's slot table.
local function countFilledSlots(outfitData)
    local slots = { "HeadId", "TopId", "BottomId", "ShoesId" }
    local count = 0
    for _, slot in ipairs(slots) do
        if outfitData[slot] then count = count + 1 end
    end
    return count
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param materialSystem  table  MaterialSystem module reference
--- @param logger          table
function AIJudge.Init(materialSystem, logger)
    _materialSystem = materialSystem
    _logger         = logger
    _logger.info("AIJudge", "Initialized.")
end

--- Scores a player's outfit. Returns a value in [1.0, 10.0].
--- @param outfitData  table | nil  PlayerData.CurrentOutfit
--- @param theme       table | nil  ThemeSystem.GetCurrentTheme() result
--- @return number
function AIJudge.ScoreOutfit(outfitData, theme)
    -- Empty outfit: heavy penalty
    if not outfitData then
        _logger.info("AIJudge", "No outfit submitted – score: " .. EMPTY_SCORE)
        return EMPTY_SCORE
    end

    -- Base random score
    local score = BASE_MIN + math.random() * (BASE_MAX - BASE_MIN)

    -- ── Phase 1 bonus hooks ──────────────────────────────────────────────────
    -- Uncomment and implement each block when the associated data is available.

    -- [1] Theme tag match: +0.5 if outfit style tags overlap with theme tags
    -- if theme and tagsIntersect(outfitData.StyleTags, theme.tags) then
    --     score = score + 0.5
    -- end

    -- [2] Slot completeness: +0.15 per filled slot (head, top, bottom, shoes)
    -- local filled = countFilledSlots(outfitData)
    -- score = score + (filled * 0.15)

    -- [3] Accessory bonus: +0.1 per accessory up to 3
    -- local accCount = outfitData.AccessoryIds and math.min(#outfitData.AccessoryIds, 3) or 0
    -- score = score + (accCount * 0.1)

    -- [4] Colour harmony: +0.3 if primary and secondary colours are complementary
    -- (requires Color3 analysis helper – implement in Phase 1)

    -- [5] Rarity bonus: +0.2 if any item is a limited-edition catalogue entry
    -- (requires catalogue metadata lookup – implement in Phase 1)
    -- ────────────────────────────────────────────────────────────────────────

    -- ── Material bonus ───────────────────────────────────────────────────────
    -- Materials were validated and consumed at submission time; here we just
    -- look up the bonus by name – no inventory access needed.
    local matBonus = _materialSystem.ComputeTotalBonus(outfitData.Materials, theme)
    if matBonus > 0 then
        score = score + matBonus
        _logger.info("AIJudge", string.format(
            "Material bonus: +%.2f from [%s]",
            matBonus, table.concat(outfitData.Materials, ", ")))
    end
    -- ────────────────────────────────────────────────────────────────────────

    -- Clamp to [1.0, 10.0] and round to one decimal
    score = math.max(1.0, math.min(10.0, score))
    score = math.floor(score * 10 + 0.5) / 10

    _logger.info("AIJudge", "Score: " .. score
        .. (theme and ('  [theme: "' .. theme.name .. '"]') or ""))
    return score
end

return AIJudge
