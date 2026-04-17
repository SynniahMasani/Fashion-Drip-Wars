--[[
    MetaSystem
    ──────────
    Tracks server-wide style-category usage across rounds to detect dominant
    strategies and apply dynamic score modifiers that reward variety.

    ── Data model ───────────────────────────────────────────────────────────────
    Two lightweight counters per style category (no per-player storage):

        _historyCounts  – decayed weighted sum of completed rounds.
                          Multiplied by DECAY_FACTOR at the end of every round
                          so older data fades naturally without explicit resets.
        _roundBuffer    – current round's outfit contributions.
                          Reset to zero at the start of every round.
                          Merged into _historyCounts by FinalizeRound().

    The total server-wide storage is 8 numbers. No DataStore needed.

    ── Usage detection ──────────────────────────────────────────────────────────
    After FinalizeRound(), each style's share of _historyCounts determines
    its status:

        share > OVERUSE_THRESHOLD (0.40)  → Overused   → OVERUSE_PENALTY  (−0.50)
        share < UNDERUSE_THRESHOLD (0.15) → Underused  → UNDERUSE_BONUS   (+0.40)
        otherwise                         → Neutral    →  0

    At equal usage (25 % each) no style is flagged.  A style needs to capture
    40 %+ of recent outfits before being penalised.

    ── Decay system ─────────────────────────────────────────────────────────────
    DECAY_FACTOR = 0.80.  After N rounds of no usage, a style's contribution
    decays to 0.80^N of its original value:
        1 round back  → 80 %
        3 rounds back → 51 %
        5 rounds back → 33 %
        10 rounds back → 11 %
    The system self-corrects within ~5 rounds of a style shift.

    ── Outfit style analysis ────────────────────────────────────────────────────
    UpdateGlobalStyleData reads OutfitData.StyleTags and maps each tag to a
    primary style category via TAG_TO_STYLE.
    To avoid compounding from duplicate/redundant tags, each outfit contributes
    exactly 1.0 total meta weight:
      • recognised styles   → split evenly across unique mapped categories
      • no recognised tags  → 0.25 to each category (balanced baseline)
    This keeps per-outfit influence bounded and consistent.

    ── Integration ──────────────────────────────────────────────────────────────
    JudgeSystem calls GetStyleModifier(player.DominantStyle) inside ScoreOutfit
    and applies it to the final AI score.  Because AI scores feed into
    RoundManager at 40 % weight, the modifier propagates to the final combined
    score without double-counting.

    Dependencies (injected via Init):
        Logger

    Public API:
        MetaSystem.Init(logger)
        MetaSystem.UpdateGlobalStyleData(outfitData)
        MetaSystem.GetStyleModifier(styleType)     -> number
        MetaSystem.FinalizeRound()
        MetaSystem.GetMetaSnapshot()               -> MetaSnapshot
        MetaSystem.GetAllStyleStatuses()           -> { [string]: string }
--]]

local MetaSystem = {}

-- ── Style categories ──────────────────────────────────────────────────────────

local STYLES = { "Streetwear", "Luxury", "Casual", "Experimental" }

-- ── Tag → primary style category ─────────────────────────────────────────────
-- Maps every outfit StyleTag to its dominant category.
-- Secondary effects (e.g. Dark also touches Experimental) are intentionally
-- ignored here — we want a single clear signal per tag, not the full StyleDNA
-- weighting.  Expand this table alongside TAG_WEIGHTS in StyleDNA.

local TAG_TO_STYLE = {
    -- ── Streetwear ────────────────────────────────────────────────────────────
    Streetwear   = "Streetwear",
    Hype         = "Streetwear",
    Urban        = "Streetwear",
    Dark         = "Streetwear",
    Techwear     = "Streetwear",
    Sporty       = "Streetwear",
    Cool         = "Streetwear",

    -- ── Luxury ────────────────────────────────────────────────────────────────
    Elegant      = "Luxury",
    Glamorous    = "Luxury",
    Formal       = "Luxury",
    Minimalist   = "Luxury",
    Historical   = "Luxury",
    Cultural     = "Luxury",
    Intellectual = "Luxury",
    Vintage      = "Luxury",

    -- ── Casual ────────────────────────────────────────────────────────────────
    Casual       = "Casual",
    Soft         = "Casual",
    Cute         = "Casual",
    Fun          = "Casual",
    Feminine     = "Casual",
    Nature       = "Casual",
    Earthy       = "Casual",
    Bohemian     = "Casual",
    Playful      = "Casual",
    Retro        = "Casual",

    -- ── Experimental ─────────────────────────────────────────────────────────
    Experimental = "Experimental",
    Eclectic     = "Experimental",
    Colourful    = "Experimental",
    Bold         = "Experimental",
    Fantasy      = "Experimental",
    Futuristic   = "Experimental",
    ["Sci-Fi"]   = "Experimental",
    Exotic       = "Experimental",
}

-- ── Constants ────────────────────────────────────────────────────────────────

local DECAY_FACTOR        = 0.80   -- weight applied to history at end of each round
local OVERUSE_THRESHOLD   = 0.40   -- share above this  → Overused
local UNDERUSE_THRESHOLD  = 0.15   -- share below this  → Underused
local OVERUSE_PENALTY     = -0.50  -- score modifier for overused style
local UNDERUSE_BONUS      =  0.40  -- score modifier for underused style

-- ── Private state ────────────────────────────────────────────────────────────

local _logger = nil

-- Accumulated weighted history (persists across rounds, decays each round)
local _historyCounts = { Streetwear = 0, Luxury = 0, Casual = 0, Experimental = 0 }

-- Current round's contributions (reset each round)
local _roundBuffer   = { Streetwear = 0, Luxury = 0, Casual = 0, Experimental = 0 }

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function resetBuffer()
    for _, cat in ipairs(STYLES) do
        _roundBuffer[cat] = 0
    end
end

--- Computes the total of all values in a counts table.
local function total(counts)
    local s = 0
    for _, cat in ipairs(STYLES) do s = s + counts[cat] end
    return s
end

--- Maps a share (0-1) to its status string.
local function resolveStatus(share)
    if share > OVERUSE_THRESHOLD   then return "Overused"   end
    if share < UNDERUSE_THRESHOLD  then return "Underused"  end
    return "Neutral"
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param logger  table
function MetaSystem.Init(logger)
    _logger = logger
    _logger.info("MetaSystem",
        "Initialized.  Decay: " .. DECAY_FACTOR
        .. "  Overuse: >" .. (OVERUSE_THRESHOLD  * 100) .. "%"
        .. "  Underuse: <" .. (UNDERUSE_THRESHOLD * 100) .. "%")
end

--- Records one outfit's style contribution into the current round's buffer.
--- Safe to call with nil (no-op) — does not mutate historical data.
--- Call once per outfit during phaseResults before scoring begins.
---
--- Outfits with recognised tags contribute a total of 1.0 split across unique
--- mapped styles. Outfits with no recognised tags contribute a balanced
--- baseline (0.25 to each category) so every submission participates.
---
--- @param outfitData  table | nil
function MetaSystem.UpdateGlobalStyleData(outfitData)
    if not outfitData then return end

    local uniqueStyles = {}

    if type(outfitData.StyleTags) == "table" then
        for _, tag in ipairs(outfitData.StyleTags) do
            local style = TAG_TO_STYLE[tag]
            if style then
                uniqueStyles[style] = true
            end
        end
    end

    local styleCount = 0
    for _ in pairs(uniqueStyles) do
        styleCount = styleCount + 1
    end

    -- Outfit with no recognised tags: balanced contribution so nothing gets
    -- inflated by silent submissions
    if styleCount == 0 then
        for _, cat in ipairs(STYLES) do
            _roundBuffer[cat] = _roundBuffer[cat] + 0.25
        end
        return
    end

    -- Recognised tags: one full contribution split across unique styles.
    local share = 1 / styleCount
    for style in pairs(uniqueStyles) do
        _roundBuffer[style] = _roundBuffer[style] + share
    end
end

--- Returns the score modifier for a given style category based on server-wide
--- usage history from completed rounds.
---
--- Returns 0 when:
---   • styleType is "None", "Mixed", or not one of the four categories
---   • No historical data has accumulated yet (first round)
---
--- @param styleType  string  One of: Streetwear | Luxury | Casual | Experimental
--- @return number  OVERUSE_PENALTY, UNDERUSE_BONUS, or 0
function MetaSystem.GetStyleModifier(styleType)
    if not styleType
        or styleType == "None"
        or styleType == "Mixed" then
        return 0
    end

    local t = total(_historyCounts)
    if t == 0 then return 0 end  -- no history yet; no modifier

    local share = (_historyCounts[styleType] or 0) / t

    if share > OVERUSE_THRESHOLD  then return OVERUSE_PENALTY end
    if share < UNDERUSE_THRESHOLD then return UNDERUSE_BONUS  end
    return 0
end

--- Finalises the current round:
---   1. Applies DECAY_FACTOR to _historyCounts (older data fades).
---   2. Merges _roundBuffer into _historyCounts.
---   3. Resets _roundBuffer for the next round.
---   4. Logs the updated state.
---
--- Call once at the end of phaseResults, after all scoring is complete.
function MetaSystem.FinalizeRound()
    -- Step 1: decay history
    for _, cat in ipairs(STYLES) do
        _historyCounts[cat] = _historyCounts[cat] * DECAY_FACTOR
    end

    -- Step 2: merge this round's buffer
    for _, cat in ipairs(STYLES) do
        _historyCounts[cat] = _historyCounts[cat] + _roundBuffer[cat]
    end

    -- Step 3: reset buffer
    resetBuffer()

    -- Step 4: log updated status
    local t = total(_historyCounts)
    if t > 0 then
        local parts = {}
        for _, cat in ipairs(STYLES) do
            local share  = _historyCounts[cat] / t
            local status = resolveStatus(share)
            table.insert(parts, string.format(
                "%s %.0f%%%s",
                cat, share * 100,
                status ~= "Neutral" and (" [" .. status .. "]") or ""))
        end
        _logger.info("MetaSystem", "Meta update → " .. table.concat(parts, "  |  "))
    else
        _logger.info("MetaSystem", "FinalizeRound: no style data recorded yet.")
    end
end

--- Returns a snapshot of the current meta state for logging or broadcasting.
--- MetaSnapshot: { [style]: { share: number, status: string, modifier: number } }
--- @return table
function MetaSystem.GetMetaSnapshot()
    local snapshot = {}
    local t = total(_historyCounts)

    for _, cat in ipairs(STYLES) do
        local share   = (t > 0) and (_historyCounts[cat] / t) or 0.25
        local status  = resolveStatus(share)
        local modifier = MetaSystem.GetStyleModifier(cat)
        snapshot[cat] = {
            share    = math.floor(share * 1000 + 0.5) / 1000,  -- 3 decimal places
            status   = status,
            modifier = modifier,
        }
    end
    return snapshot
end

--- Returns a compact {style → status} table.
--- Useful for future client broadcasts or matchmaking awareness.
--- @return { [string]: string }   "Overused" | "Neutral" | "Underused"
function MetaSystem.GetAllStyleStatuses()
    local statuses = {}
    local t = total(_historyCounts)
    for _, cat in ipairs(STYLES) do
        local share = (t > 0) and (_historyCounts[cat] / t) or 0.25
        statuses[cat] = resolveStatus(share)
    end
    return statuses
end

return MetaSystem
