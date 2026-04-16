--[[
    RoundManager
    ────────────
    Drives the complete per-round gameplay loop as a state machine.

    State machine:
        IDLE → LOBBY → THEME_SELECTION → DRESSING → RUNWAY → VOTING → RESULTS → IDLE

    Every state transition:
        1. Updates _currentState
        2. Fires PhaseChanged(stateName, phaseDurationSeconds) to ALL clients
        3. Schedules the next transition with task.delay (cancellable)

    The only external call needed to start a round is StartRound(players).
    All internal transitions are automatic.

    Phase durations (seconds):
        LOBBY          : 10   (waiting room / countdown)
        THEME_SELECTION:  5   (theme reveal)
        DRESSING       : 180  (3-minute outfit phase)
        RUNWAY         : dynamic (RunwaySystem drives it; ~10s per player)
        VOTING         : 30
        RESULTS        : 15

    Dependencies (injected via Init as a single deps table):
        outfitSystem, votingSystem, sabotageSystem,
        themeSystem, runwaySystem, judgeSystem, styleDNA, reputationSystem,
        playerDataManager, logger, remotes

    Public API:
        RoundManager.Init(deps)
        RoundManager.Start()
        RoundManager.Stop()
        RoundManager.StartRound(players)
        RoundManager.GetCurrentState()  -> string
        RoundManager.GetRoundNumber()   -> number
        RoundManager.State              -> { IDLE, LOBBY, THEME_SELECTION,
                                             DRESSING, RUNWAY, VOTING, RESULTS }
--]]

local RoundManager = {}

-- ── State enum ───────────────────────────────────────────────────────────────

RoundManager.State = {
    IDLE             = "IDLE",
    LOBBY            = "LOBBY",
    THEME_SELECTION  = "THEME_SELECTION",
    DRESSING         = "DRESSING",
    RUNWAY           = "RUNWAY",
    VOTING           = "VOTING",
    RESULTS          = "RESULTS",
}

-- ── Phase durations ───────────────────────────────────────────────────────────

local DURATION = {
    LOBBY           = 10,
    THEME_SELECTION = 5,
    DRESSING        = 180,
    VOTING          = 30,
    RESULTS         = 15,
}

-- ── Private state ────────────────────────────────────────────────────────────

local _d            = {}   -- deps table (set by Init)
local _isRunning    = false
local _currentState = RoundManager.State.IDLE
local _roundNumber  = 0
local _phaseThread  = nil  -- cancellable task thread for timed transitions
local _roundPlayers = {}   -- Player[] for the active round

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function cancelPhaseTimer()
    if _phaseThread then
        task.cancel(_phaseThread)
        _phaseThread = nil
    end
end

--- Transitions to a new state and broadcasts to all clients.
--- phaseDuration is informational for the client timer UI; pass 0 for
--- phases whose duration is driven externally (RUNWAY).
local function setState(newState, phaseDuration)
    _d.logger.info("RoundManager",
        "Phase: " .. _currentState .. " → " .. newState)
    _currentState = newState
    _d.remotes.PhaseChanged:FireAllClients(newState, phaseDuration or 0)
end

-- ── Phase functions (forward-declared so they can reference each other) ───────

local phaseLobby, phaseThemeSelection, phaseDressing,
      phaseRunway, phaseVoting, phaseResults

-- ─────────────────────────────────────────────────────────────────────────────

phaseLobby = function()
    setState(RoundManager.State.LOBBY, DURATION.LOBBY)
    _d.logger.info("RoundManager",
        "Lobby open – " .. DURATION.LOBBY .. "s before theme reveal. "
        .. #_roundPlayers .. " player(s).")

    _phaseThread = task.delay(DURATION.LOBBY, phaseThemeSelection)
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseThemeSelection = function()
    setState(RoundManager.State.THEME_SELECTION, DURATION.THEME_SELECTION)

    local theme = _d.themeSystem.SelectTheme()
    -- Broadcast: (themeName, themeDescription, themeTags[])
    _d.remotes.ThemeSelected:FireAllClients(theme.name, theme.description, theme.tags)
    _d.logger.info("RoundManager", 'Theme: "' .. theme.name .. '"')

    -- Select the judging panel now that the theme is known
    _d.judgeSystem.SelectJudgesForRound()

    _phaseThread = task.delay(DURATION.THEME_SELECTION, phaseDressing)
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseDressing = function()
    setState(RoundManager.State.DRESSING, DURATION.DRESSING)

    -- Clear last round's outfits so stale data can't carry over
    _d.outfitSystem.ClearRoundOutfits(_roundPlayers)
    _d.outfitSystem.Start()
    _d.sabotageSystem.Start()

    _d.logger.info("RoundManager",
        "Dressing phase – " .. DURATION.DRESSING .. "s on the clock.")

    _phaseThread = task.delay(DURATION.DRESSING, function()
        _d.outfitSystem.Stop()
        phaseRunway()
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseRunway = function()
    setState(RoundManager.State.RUNWAY, 0)  -- duration is player-count dependent
    _d.logger.info("RoundManager", "Runway phase starting.")

    -- RunwaySystem drives timing internally; calls the callback when done
    _d.runwaySystem.StartRunway(_roundPlayers, function()
        phaseVoting()
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseVoting = function()
    setState(RoundManager.State.VOTING, DURATION.VOTING)

    _d.votingSystem.Start()
    _d.votingSystem.OpenVoting(_roundPlayers, _roundPlayers)
    _d.logger.info("RoundManager", "Voting phase – " .. DURATION.VOTING .. "s.")

    _phaseThread = task.delay(DURATION.VOTING, phaseResults)
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseResults = function()
    _d.votingSystem.CloseVoting()
    setState(RoundManager.State.RESULTS, DURATION.RESULTS)

    local voteTally = _d.votingSystem.TallyVotes()  -- []{userId,voteCount,totalStars,average}

    -- Build a lookup: userId -> average player vote
    local avgByPlayer = {}
    for _, entry in ipairs(voteTally) do
        avgByPlayer[entry.userId] = entry.average
    end

    -- Combine player votes with JudgeSystem panel scores (AI = 40% of final)
    local finalResults = {}
    for _, player in ipairs(_roundPlayers) do
        local userId    = player.UserId
        local outfit    = _d.outfitSystem.GetPlayerOutfit(userId)
        local aiScore   = _d.judgeSystem.ScoreOutfit(player, outfit)
        local pVoteAvg  = avgByPlayer[userId] or 0

        -- Weighted formula: 60% player vote (normalised to 10-pt scale) + 40% AI
        local normVote  = (pVoteAvg / 5) * 10
        local final     = math.floor((normVote * 0.6 + aiScore * 0.4) * 10 + 0.5) / 10

        table.insert(finalResults, {
            userId     = userId,
            name       = player.Name,
            aiScore    = aiScore,
            playerVote = pVoteAvg,
            finalScore = final,
        })
    end

    table.sort(finalResults, function(a, b)
        return a.finalScore > b.finalScore
    end)

    -- Build a UserId → Player lookup so we can pass Player objects to subsystems
    local playerById = {}
    for _, player in ipairs(_roundPlayers) do
        playerById[player.UserId] = player
    end

    -- Pull individual star-rating arrays before VotingSystem.Stop() clears them.
    -- Shape: { [targetUserId: number]: number[] }
    local rawVoteMap = _d.votingSystem.GetAllRawVotes()

    -- Assign ranks, update Reputation, include rep score in broadcast payload
    for rank, result in ipairs(finalResults) do
        result.rank = rank

        local player = playerById[result.userId]
        if player then
            local roundResult = {
                userId       = result.userId,
                rank         = rank,
                totalPlayers = #_roundPlayers,
                finalScore   = result.finalScore,
                playerVote   = result.playerVote,
                aiScore      = result.aiScore,
                rawVotes     = rawVoteMap[result.userId] or {},
                roundNumber  = _roundNumber,
            }
            _d.reputationSystem.UpdateReputation(player, roundResult)

            local repProfile = _d.reputationSystem.GetReputation(player)
            result.reputation = repProfile and repProfile.score or 0
            result.repTier    = repProfile and repProfile.tier  or "Newcomer"
        end

        _d.logger.info("RoundManager", string.format(
            "  #%d %-20s  Final: %.1f  (AI: %.1f | Vote: %.1f | Rep: %.1f [%s])",
            rank, result.name, result.finalScore,
            result.aiScore, result.playerVote,
            result.reputation or 0, result.repTier or "?"))
    end

    -- Final Style DNA refresh: ensures DominantStyle reflects the full round,
    -- even for players who never submitted an outfit this round (score = 0).
    for _, player in ipairs(_roundPlayers) do
        _d.styleDNA.RecalculateDominantStyle(player.UserId)
    end

    -- Broadcast results to all clients
    _d.remotes.RoundResults:FireAllClients(finalResults)
    _d.logger.info("RoundManager", "Round #" .. _roundNumber .. " results broadcast.")

    -- Clean up subsystems
    _d.votingSystem.Stop()
    _d.sabotageSystem.Stop()

    _phaseThread = task.delay(DURATION.RESULTS, function()
        setState(RoundManager.State.IDLE, 0)
        _d.logger.info("RoundManager", "=== Round #" .. _roundNumber .. " COMPLETE ===")
    end)
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module with all dependencies.
--- @param deps table {
---   outfitSystem, votingSystem, sabotageSystem,
---   themeSystem, runwaySystem, judgeSystem, styleDNA, reputationSystem,
---   playerDataManager, logger, remotes
--- }
function RoundManager.Init(deps)
    _d = deps
    _d.logger.info("RoundManager", "Initialized.")
end

--- Arms the manager so StartRound() will be accepted.
function RoundManager.Start()
    _isRunning = true
    _d.logger.info("RoundManager", "Started. Awaiting first round.")
end

--- Cleanly shuts down, stopping any in-progress round.
function RoundManager.Stop()
    cancelPhaseTimer()
    if _currentState ~= RoundManager.State.IDLE then
        _d.outfitSystem.Stop()
        _d.votingSystem.Stop()
        _d.sabotageSystem.Stop()
        _d.runwaySystem.Stop()
    end
    _isRunning    = false
    _currentState = RoundManager.State.IDLE
    _d.logger.info("RoundManager", "Stopped.")
end

--- Kicks off a new round for the given player list.
--- No-ops (with a warning) if the manager is stopped or a round is active.
--- @param players  Player[]
function RoundManager.StartRound(players)
    if not _isRunning then
        _d.logger.warn("RoundManager", "StartRound called while manager is stopped.")
        return
    end
    if _currentState ~= RoundManager.State.IDLE then
        _d.logger.warn("RoundManager",
            "StartRound called during active round (state: " .. _currentState .. ").")
        return
    end
    if #players < 1 then
        _d.logger.warn("RoundManager", "StartRound called with no players – aborting.")
        return
    end

    _roundNumber  = _roundNumber + 1
    _roundPlayers = players

    _d.logger.info("RoundManager",
        "=== Round #" .. _roundNumber .. " START ==="
        .. "  Players: " .. #players)

    phaseLobby()
end

--- Returns the current state string (one of RoundManager.State).
--- @return string
function RoundManager.GetCurrentState()
    return _currentState
end

--- Returns the count of rounds started this server session.
--- @return number
function RoundManager.GetRoundNumber()
    return _roundNumber
end

return RoundManager
