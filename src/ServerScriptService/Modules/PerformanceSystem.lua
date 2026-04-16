--[[
    PerformanceSystem
    ─────────────────
    Adds skill expression to the runway phase through timed action windows.

    During each player's runway turn the server opens WINDOW_COUNT action
    windows at regular intervals.  Each window lasts WINDOW_DURATION seconds.
    When the player fires the TriggerAction RemoteEvent, the server evaluates
    timing server-authoritatively:

        Elapsed from window open    Rating     Base bonus
        ──────────────────────────────────────────────────
        ≤ PERFECT_THRESHOLD (0.25s) Perfect    SCORE_PERFECT (1.00)
        ≤ GOOD_THRESHOLD    (0.75s) Good       SCORE_GOOD    (0.50)
        > GOOD_THRESHOLD or closed  Miss       0

    ── Combo system ─────────────────────────────────────────────────────────────
    Consecutive Perfect or Good hits increase a multiplier:

        comboMultiplier = clamp(1.0 + (hits − 1) × COMBO_INCREMENT, 1.0, COMBO_MAX)
                                                  (increment = 0.25, max = 2.0)

    A Miss resets the streak to 0 (multiplier back to 1.0) but never subtracts
    from the accumulated score.

    ── Per-turn score cap ────────────────────────────────────────────────────────
    Total performance score is capped at MAX_PERF_SCORE (3.0).

    Maximum achievable (3 Perfect hits, full combo):
        hit 1: 1.00 × 1.00 = 1.00
        hit 2: 1.00 × 1.25 = 1.25
        hit 3: 1.00 × 1.50 = 1.50   → raw 3.75 → clamped to 3.00

    ── Anti-spam ────────────────────────────────────────────────────────────────
    A player may fire TriggerAction at most MAX_ACTIONS times per turn (equals
    WINDOW_COUNT).  Additional calls are silently dropped with a warn log.

    ── Remote events ────────────────────────────────────────────────────────────
    ActionWindowOpened  server → client (specific)  (windowIndex: number, total: number)
    ActionWindowClosed  server → client (specific)  (windowIndex: number)
    ActionResult        server → client (specific)  (rating: string, bonus: number, combo: number)
    TriggerAction       client → server             handled in GameController

    ── Integration ──────────────────────────────────────────────────────────────
    RoundManager.phaseRunway  – calls StartPerformance(player) in onTurnStarted
    RoundManager.phaseDressing – calls ClearRound() at phase start
    RoundManager.phaseResults  – calls GetPerformanceScore(player) per player;
                                  performance bonus is added before hype multiply

    Dependencies (injected via Init):
        Logger, Remotes

    Public API:
        PerformanceSystem.Init(logger, remotes)
        PerformanceSystem.StartPerformance(player)
        PerformanceSystem.RegisterAction(player)      → (rating: string, bonus: number)
        PerformanceSystem.GetPerformanceScore(player) → number  (0 – MAX_PERF_SCORE)
        PerformanceSystem.ClearRound()
        PerformanceSystem.IsPlayerTurn(player)        → boolean
--]]

local PerformanceSystem = {}

-- ── Constants ────────────────────────────────────────────────────────────────

-- Window scheduling (relative to each turn start)
local WINDOW_COUNT    = 3     -- action windows opened per runway turn
local WINDOW_INTERVAL = 2.5   -- seconds between window openings
local WINDOW_DURATION = 1.0   -- seconds a window stays open

-- Timing thresholds (elapsed seconds from window open)
local PERFECT_THRESHOLD = 0.25
local GOOD_THRESHOLD    = 0.75

-- Base point values
local SCORE_PERFECT = 1.00
local SCORE_GOOD    = 0.50

-- Combo multiplier growth
local COMBO_INCREMENT = 0.25  -- added per consecutive hit
local COMBO_MAX       = 2.0   -- multiplier ceiling

-- Anti-spam: must not exceed WINDOW_COUNT actions per turn
local MAX_ACTIONS = WINDOW_COUNT

-- Score ceiling applied before returning to RoundManager
local MAX_PERF_SCORE = 3.0

-- ── Private state ────────────────────────────────────────────────────────────

local _logger  = nil
local _remotes = nil

-- Active turn (nil when no player is currently on the runway).
-- Fields:
--   player          Player      the player walking now
--   userId          number
--   windowActive    boolean     true while a timing window is open
--   windowOpenTime  number      os.clock() when the current window opened
--   windowIndex     number      which window (1…WINDOW_COUNT) is open
--   actionsUsed     number      anti-spam counter
--   consecutiveHits number      current combo streak
--   comboMultiplier number
--   score           number      accumulated raw score (pre-cap)
--   schedThread     thread      task thread running the window loop
local _activeTurn = nil

-- Completed per-player scores (persist until ClearRound).
-- { [userId: number]: number }  (capped at MAX_PERF_SCORE)
local _scores = {}

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function cancelActiveTurn()
    if _activeTurn and _activeTurn.schedThread then
        task.cancel(_activeTurn.schedThread)
    end
    _activeTurn = nil
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param logger   table  Logger reference
--- @param remotes  table  ReplicatedStorage.Remotes folder reference
function PerformanceSystem.Init(logger, remotes)
    _logger  = logger
    _remotes = remotes
    _logger.info("PerformanceSystem", "Initialized.")
end

--- Begins a performance session for the given player.
--- If another player's session is still active it is flushed first, so the
--- previous player's score is saved before the new turn starts.
--- @param player  Player
function PerformanceSystem.StartPerformance(player)
    -- Flush any in-progress turn (the previous player's turn just ended)
    if _activeTurn then
        local prevId    = _activeTurn.userId
        local prevName  = _activeTurn.player.Name
        local prevScore = math.min(MAX_PERF_SCORE, _activeTurn.score)
        _scores[prevId] = prevScore
        _logger.info("PerformanceSystem", string.format(
            "%s runway performance complete – score: %.2f  (implicit flush)",
            prevName, prevScore))
        cancelActiveTurn()
    end

    local state = {
        player          = player,
        userId          = player.UserId,
        windowActive    = false,
        windowOpenTime  = 0,
        windowIndex     = 0,
        actionsUsed     = 0,
        consecutiveHits = 0,
        comboMultiplier = 1.0,
        score           = 0,
        schedThread     = nil,
    }
    _activeTurn = state

    _logger.info("PerformanceSystem", string.format(
        "%s performance started – %d action window(s) scheduled.",
        player.Name, WINDOW_COUNT))

    -- Launch the window scheduler.
    -- The identity check (_activeTurn.userId == player.UserId) guards against
    -- the unlikely race where a new turn starts while this loop is still running.
    state.schedThread = task.spawn(function()
        for i = 1, WINDOW_COUNT do
            task.wait(WINDOW_INTERVAL)
            if not _activeTurn or _activeTurn.userId ~= player.UserId then break end

            -- Open window
            state.windowIndex    = i
            state.windowOpenTime = os.clock()
            state.windowActive   = true

            _remotes.ActionWindowOpened:FireClient(player, i, WINDOW_COUNT)
            _logger.info("PerformanceSystem", string.format(
                "%s – window %d/%d open (%.1fs to react)",
                player.Name, i, WINDOW_COUNT, WINDOW_DURATION))

            task.wait(WINDOW_DURATION)
            if not _activeTurn or _activeTurn.userId ~= player.UserId then break end

            if state.windowActive then
                -- Player did not act; close window, break combo
                state.windowActive   = false
                state.consecutiveHits = 0
                state.comboMultiplier = 1.0
                _remotes.ActionWindowClosed:FireClient(player, i)
                _logger.info("PerformanceSystem", string.format(
                    "%s – window %d/%d missed (no action) – combo reset",
                    player.Name, i, WINDOW_COUNT))
            end
        end
    end)
end

--- Called from GameController's TriggerAction handler.
--- Evaluates timing server-authoritatively and updates the player's score.
--- timingData from the client is intentionally ignored; the server holds the clock.
---
--- @param player      Player
--- @return string     rating  "Perfect" | "Good" | "Miss" | "NoWindow" | "Blocked"
--- @return number     bonus   points awarded this action (0 on miss/block)
function PerformanceSystem.RegisterAction(player)
    if not _activeTurn or _activeTurn.userId ~= player.UserId then
        _logger.warn("PerformanceSystem",
            player.Name .. " fired TriggerAction but it is not their runway turn – ignored.")
        return "Blocked", 0
    end

    local state = _activeTurn

    -- Anti-spam guard
    if state.actionsUsed >= MAX_ACTIONS then
        _logger.warn("PerformanceSystem", string.format(
            "%s exceeded MAX_ACTIONS (%d) – action dropped.",
            player.Name, MAX_ACTIONS))
        return "Blocked", 0
    end
    state.actionsUsed = state.actionsUsed + 1

    -- No open window
    if not state.windowActive then
        state.consecutiveHits = 0
        state.comboMultiplier = 1.0
        _remotes.ActionResult:FireClient(player, "Miss", 0, 0)
        _logger.info("PerformanceSystem", player.Name .. " acted outside window – Miss / combo reset")
        return "Miss", 0
    end

    -- Evaluate timing (server-authoritative)
    local elapsed = os.clock() - state.windowOpenTime
    state.windowActive = false  -- consume the window

    local rating, baseBonus
    if elapsed <= PERFECT_THRESHOLD then
        rating    = "Perfect"
        baseBonus = SCORE_PERFECT
    elseif elapsed <= GOOD_THRESHOLD then
        rating    = "Good"
        baseBonus = SCORE_GOOD
    else
        rating    = "Miss"
        baseBonus = 0
    end

    if baseBonus > 0 then
        -- Successful hit: advance combo
        state.consecutiveHits = state.consecutiveHits + 1
        state.comboMultiplier = math.min(COMBO_MAX,
            1.0 + (state.consecutiveHits - 1) * COMBO_INCREMENT)

        local bonus = baseBonus * state.comboMultiplier
        state.score = state.score + bonus

        _logger.info("PerformanceSystem", string.format(
            "%s [%s]  elapsed: %.3fs  %.2f × %.2f = %.2f  combo: %d  running total: %.2f",
            player.Name, rating, elapsed,
            baseBonus, state.comboMultiplier, bonus,
            state.consecutiveHits, state.score))

        _remotes.ActionResult:FireClient(player, rating, bonus, state.consecutiveHits)
        return rating, bonus
    else
        -- Miss: break combo, no deduction
        state.consecutiveHits = 0
        state.comboMultiplier = 1.0

        _logger.info("PerformanceSystem", string.format(
            "%s [Miss]  elapsed: %.3fs  combo reset",
            player.Name, elapsed))

        _remotes.ActionResult:FireClient(player, "Miss", 0, 0)
        return "Miss", 0
    end
end

--- Returns the finalised performance score for a player this round.
--- If the player is still the active turn (last player in the queue) their
--- session is flushed here so the score is always available at results time.
--- Returns 0 for any player who had no performance session this round.
--- @param player  Player
--- @return number  0 – MAX_PERF_SCORE
function PerformanceSystem.GetPerformanceScore(player)
    -- Flush the last active player if needed
    if _activeTurn and _activeTurn.userId == player.UserId then
        _scores[player.UserId] = math.min(MAX_PERF_SCORE, _activeTurn.score)
        cancelActiveTurn()
    end
    return _scores[player.UserId] or 0
end

--- Clears all performance records and cancels any active session.
--- Call at the start of phaseDressing so stale data never bleeds across rounds.
function PerformanceSystem.ClearRound()
    cancelActiveTurn()
    _scores = {}
    _logger.info("PerformanceSystem", "Round performance records cleared.")
end

--- Returns whether a runway turn is currently active for the given player.
--- @param player  Player
--- @return boolean
function PerformanceSystem.IsPlayerTurn(player)
    return _activeTurn ~= nil and _activeTurn.userId == player.UserId
end

return PerformanceSystem
