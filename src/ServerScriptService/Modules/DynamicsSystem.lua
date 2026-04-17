--[[
    DynamicsSystem
    ──────────────
    Cross-round dynamics: per-player streak tracking, bounded underdog bonuses,
    winner pressure, and server-side event round selection.

    All data is session-scoped (not persisted). No DataStore needed.

    ── Streak definitions ────────────────────────────────────────────────────────
        winStreak   : consecutive rounds finishing 1st place
        lossStreak  : consecutive rounds finishing last place (rank = totalPlayers)
        topStreak   : consecutive rounds finishing in the top 3 positions
    Each streak type is independent; finishing 2nd does not reset lossStreak.

    ── Event types ───────────────────────────────────────────────────────────────
    Exactly one event (or NONE) is selected per round at the start of
    phaseThemeSelection and stored by RoundManager for use during scoring.
    Priority order: STREAK_GAUNTLET → UNDERDOG_UPRISING → META_SHAKEUP → NONE.

        NONE              – standard round; no modifiers applied.

        STREAK_GAUNTLET   – triggered when any player has winStreak ≥ WIN_STREAK_GAUNTLET.
                            Players with winStreak ≥ WIN_STREAK_PRESSURE receive a judge
                            pressure penalty on their AI score this round.

        UNDERDOG_UPRISING – triggered when any player has lossStreak ≥ LOSS_STREAK_EVENT.
                            Underdog bonuses are doubled for all qualifying players.

        META_SHAKEUP      – triggered when a style category has been Overused for
                            ≥ SHAKEUP_ROUNDS consecutive rounds. Players whose DominantStyle
                            matches the flagged style receive an extra AI score penalty.

    ── Modifier bounds (all values on the 0–10 AI-score scale) ──────────────────
        Underdog bonus (normal)    : +0.15 per loss-streak level above 1, max +0.45
        Underdog bonus (uprising)  : doubled, max +0.90
        Judge pressure (gauntlet)  : −0.50 to aiScore for winStreak ≥ WIN_STREAK_PRESSURE
        Meta shakeup extra penalty : −0.50 to aiScore (stacks with MetaSystem's OVERUSE_PENALTY)
        AI scores are clamped to [1.0, 10.0] after modifiers; final scores capped at 10.0.

    ── Dependencies (injected via Init) ─────────────────────────────────────────
        Logger

    ── Public API ────────────────────────────────────────────────────────────────
        DynamicsSystem.Init(logger)
        DynamicsSystem.SelectEvent(metaStatuses) -> EventResult
        DynamicsSystem.RecordRoundResults(finalResults)
        DynamicsSystem.GetUnderdogBonus(userId, event)    -> number
        DynamicsSystem.GetJudgePressure(userId, event)    -> number
        DynamicsSystem.GetStreakProfile(userId)            -> StreakProfile | nil
        DynamicsSystem.GetStreakLeaders()                  -> { userId, winStreak }[]

    EventResult schema:
    {
        type        : string,  -- DynamicsSystem.Event constant
        description : string,  -- human-readable; safe to broadcast to clients
        data        : table,   -- type-specific payload (e.g. shakeupStyle, winStreak)
    }
--]]

local DynamicsSystem = {}

-- ── Event type constants ──────────────────────────────────────────────────────

DynamicsSystem.Event = {
    NONE              = "NONE",
    STREAK_GAUNTLET   = "STREAK_GAUNTLET",
    UNDERDOG_UPRISING = "UNDERDOG_UPRISING",
    META_SHAKEUP      = "META_SHAKEUP",
}

-- ── Streak thresholds ─────────────────────────────────────────────────────────

local WIN_STREAK_GAUNTLET  = 3   -- winStreak ≥ this → STREAK_GAUNTLET event eligible
local WIN_STREAK_PRESSURE  = 2   -- winStreak ≥ this → judge pressure active during gauntlet
local LOSS_STREAK_EVENT    = 3   -- lossStreak ≥ this → UNDERDOG_UPRISING event eligible
local LOSS_STREAK_UNDERDOG = 2   -- lossStreak ≥ this → underdog bonus active (any round)
local SHAKEUP_ROUNDS       = 2   -- style must be Overused for this many consecutive rounds

-- ── Modifier values ───────────────────────────────────────────────────────────

-- Underdog bonus: added to (base + perfScore) before the hype multiplier.
local UNDERDOG_PER_LEVEL    = 0.15  -- per loss-streak level above 1
local UNDERDOG_MAX_NORMAL   = 0.45  -- normal-round cap (effective at lossStreak = 4+)
local UNDERDOG_MAX_EVENT    = 0.90  -- cap during UNDERDOG_UPRISING (doubled)

-- Judge pressure: direct subtraction from aiScore for dominant players.
local PRESSURE_PENALTY      = -0.50

-- Meta shakeup: additional AI score penalty stacked on MetaSystem's OVERUSE_PENALTY.
local SHAKEUP_EXTRA_PENALTY = -0.50

-- ── Private state ─────────────────────────────────────────────────────────────

local _logger = nil

-- { [userId]: { winStreak, lossStreak, topStreak, roundsPlayed } }
local _streaks = {}

-- Tracks consecutive rounds each style has been Overused.
-- Updated once per round inside SelectEvent().
local _styleOveruseStreak = {
    Streetwear   = 0,
    Luxury       = 0,
    Casual       = 0,
    Experimental = 0,
}

-- ── Internal helpers ──────────────────────────────────────────────────────────

local function getOrCreate(userId)
    if not _streaks[userId] then
        _streaks[userId] = { winStreak = 0, lossStreak = 0, topStreak = 0, roundsPlayed = 0 }
    end
    return _streaks[userId]
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param logger  table
function DynamicsSystem.Init(logger)
    _logger = logger
    _logger.info("DynamicsSystem", "Initialized.")
end

--- Evaluates current streak and meta state, selects an event type for the round,
--- and returns an EventResult. Call once per round in phaseThemeSelection.
---
--- metaStatuses is the output of MetaSystem.GetAllStyleStatuses() — a table mapping
--- style names to "Overused" | "Neutral" | "Underused". Passing nil is safe (no-op).
--- The function updates _styleOveruseStreak regardless of which event is selected.
---
--- @param metaStatuses  { [string]: string } | nil
--- @return EventResult
function DynamicsSystem.SelectEvent(metaStatuses)
    metaStatuses = metaStatuses or {}

    -- Always update overuse streak counters so history accumulates correctly
    -- even in rounds where a different event type wins the selection.
    for style in pairs(_styleOveruseStreak) do
        if metaStatuses[style] == "Overused" then
            _styleOveruseStreak[style] = _styleOveruseStreak[style] + 1
        else
            _styleOveruseStreak[style] = 0
        end
    end

    -- ── Priority 1: STREAK_GAUNTLET ───────────────────────────────────────────
    -- Any player on a long win streak makes this the featured event.
    for userId, s in pairs(_streaks) do
        if s.winStreak >= WIN_STREAK_GAUNTLET then
            local event = {
                type        = DynamicsSystem.Event.STREAK_GAUNTLET,
                description = "A dominant player is on a win streak – judges raise the bar.",
                data        = { triggerUserId = userId, winStreak = s.winStreak },
            }
            _logger.info("DynamicsSystem",
                "STREAK_GAUNTLET – UserId " .. tostring(userId)
                .. " on " .. s.winStreak .. "-round win streak.")
            return event
        end
    end

    -- ── Priority 2: UNDERDOG_UPRISING ─────────────────────────────────────────
    -- Any player on a long loss streak inverts pressure toward the top.
    for userId, s in pairs(_streaks) do
        if s.lossStreak >= LOSS_STREAK_EVENT then
            local event = {
                type        = DynamicsSystem.Event.UNDERDOG_UPRISING,
                description = "A struggling player is overdue for a comeback – underdogs receive a boost.",
                data        = { triggerUserId = userId, lossStreak = s.lossStreak },
            }
            _logger.info("DynamicsSystem",
                "UNDERDOG_UPRISING – UserId " .. tostring(userId)
                .. " on " .. s.lossStreak .. "-round loss streak.")
            return event
        end
    end

    -- ── Priority 3: META_SHAKEUP ──────────────────────────────────────────────
    -- A style category has been dominant for too long.
    for style, streak in pairs(_styleOveruseStreak) do
        if streak >= SHAKEUP_ROUNDS then
            local event = {
                type        = DynamicsSystem.Event.META_SHAKEUP,
                description = style .. " has dominated the meta – judges grow tired of it.",
                data        = { shakeupStyle = style, overuseStreak = streak },
            }
            _logger.info("DynamicsSystem",
                "META_SHAKEUP – " .. style .. " Overused for "
                .. streak .. " consecutive rounds.")
            return event
        end
    end

    -- ── No special conditions met ─────────────────────────────────────────────
    return { type = DynamicsSystem.Event.NONE, description = "Standard round.", data = {} }
end

--- Updates all players' streak records after a round's final rankings are known.
--- Call this in phaseResults after ranks are assigned but before broadcasting.
--- @param finalResults  table[]  sorted by rank; each entry must have .userId, .rank, .name
function DynamicsSystem.RecordRoundResults(finalResults)
    if #finalResults == 0 then return end
    local totalPlayers = #finalResults

    for _, result in ipairs(finalResults) do
        local s = getOrCreate(result.userId)
        s.roundsPlayed = s.roundsPlayed + 1

        -- Win streak: only rank 1 maintains it; any other rank resets to 0
        if result.rank == 1 then
            s.winStreak = s.winStreak + 1
        else
            s.winStreak = 0
        end

        -- Loss streak: only last place maintains it; any improvement resets to 0
        if totalPlayers > 1 and result.rank == totalPlayers then
            s.lossStreak = s.lossStreak + 1
        else
            s.lossStreak = 0
        end

        -- Top-3 streak: rank > 3 resets it
        if result.rank <= math.min(3, totalPlayers) then
            s.topStreak = s.topStreak + 1
        else
            s.topStreak = 0
        end
    end

    -- Log only players with notable streaks to keep output clean
    for _, result in ipairs(finalResults) do
        local s = _streaks[result.userId]
        if s and (s.winStreak >= 2 or s.lossStreak >= 2 or s.topStreak >= 3) then
            _logger.info("DynamicsSystem", string.format(
                "  %-20s  W:%d  L:%d  Top3:%d  (#%d played)",
                result.name or tostring(result.userId),
                s.winStreak, s.lossStreak, s.topStreak, s.roundsPlayed))
        end
    end
end

--- Returns the underdog score bonus for a player, scaled by their loss streak.
--- Added to (base + perfScore) before the hype multiplier in RoundManager.
--- Returns 0 for players below the loss-streak threshold.
--- @param userId  number
--- @param event   EventResult | nil
--- @return number  0–0.45 normally; 0–0.90 during UNDERDOG_UPRISING
function DynamicsSystem.GetUnderdogBonus(userId, event)
    local s = _streaks[userId]
    if not s or s.lossStreak < LOSS_STREAK_UNDERDOG then return 0 end

    local levels  = s.lossStreak - 1
    local isEvent = event and event.type == DynamicsSystem.Event.UNDERDOG_UPRISING
    local cap     = isEvent and UNDERDOG_MAX_EVENT or UNDERDOG_MAX_NORMAL
    return math.min(levels * UNDERDOG_PER_LEVEL, cap)
end

--- Returns the judge pressure modifier for a player's AI score.
--- Only negative in STREAK_GAUNTLET rounds for players with significant win streaks.
--- Returns 0 in all other cases — no silent penalties.
--- @param userId  number
--- @param event   EventResult | nil
--- @return number  0 or PRESSURE_PENALTY (−0.50)
function DynamicsSystem.GetJudgePressure(userId, event)
    if not event or event.type ~= DynamicsSystem.Event.STREAK_GAUNTLET then return 0 end
    local s = _streaks[userId]
    if not s or s.winStreak < WIN_STREAK_PRESSURE then return 0 end
    return PRESSURE_PENALTY
end

--- Returns the streak profile for a player, or nil if they have no history this session.
--- @param userId  number
--- @return StreakProfile | nil
function DynamicsSystem.GetStreakProfile(userId)
    local s = _streaks[userId]
    if not s then return nil end
    return {
        winStreak    = s.winStreak,
        lossStreak   = s.lossStreak,
        topStreak    = s.topStreak,
        roundsPlayed = s.roundsPlayed,
    }
end

--- Returns all players currently on a notable win streak (≥ WIN_STREAK_PRESSURE),
--- sorted by winStreak descending.  Useful for sabotage targeting hints.
--- @return { userId: number, winStreak: number }[]
function DynamicsSystem.GetStreakLeaders()
    local leaders = {}
    for userId, s in pairs(_streaks) do
        if s.winStreak >= WIN_STREAK_PRESSURE then
            table.insert(leaders, { userId = userId, winStreak = s.winStreak })
        end
    end
    table.sort(leaders, function(a, b) return a.winStreak > b.winStreak end)
    return leaders
end

return DynamicsSystem
