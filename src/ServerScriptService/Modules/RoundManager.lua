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
        themeSystem, runwaySystem, judgeSystem, metaSystem, audienceSystem,
        styleDNA, reputationSystem, performanceSystem, playerDataManager, logger, remotes

    Public API:
        RoundManager.Init(deps)
        RoundManager.Start()
        RoundManager.Stop()
        RoundManager.StartRound(players)
        RoundManager.GetCurrentState()              -> string
        RoundManager.GetRoundNumber()               -> number
        RoundManager.HandlePlayerLeft(userId)       -- call from GameController PlayerRemoving
        RoundManager.IsPlayerInActiveRound(userId)  -> boolean
        RoundManager.GetActiveRoundPlayers()        -> Player[]
        RoundManager.State                          -> { IDLE, LOBBY, THEME_SELECTION,
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

-- ── Cross-round dynamics constants ───────────────────────────────────────────
-- Mirrors the META_SHAKEUP extra penalty in DynamicsSystem so it is visible
-- here alongside the rest of the scoring formula.
local SHAKEUP_EXTRA_PENALTY = -0.50

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
local _roundPlayers = {}   -- Player[] round-start ordering source; not authoritative for live membership
-- Live membership set: entries are removed as players disconnect mid-round so
-- systems can quickly test whether a userId is still an active participant.
local _activePlayerSet = {}  -- { [userId: number]: Player }

-- EventResult from DynamicsSystem for the current round; set in phaseThemeSelection,
-- consumed in phaseResults scoring, nil between rounds.
local _currentEvent = nil

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function cancelPhaseTimer()
    if _phaseThread then
        task.cancel(_phaseThread)
        _phaseThread = nil
    end
end

--- Returns round participants that are still active, preserving round-start order.
--- This is the authoritative participant list for active-phase logic.
--- @return Player[]
local function getLiveRoundPlayers()
    local result = {}
    for _, player in ipairs(_roundPlayers) do
        if player and _activePlayerSet[player.UserId] and player.Parent then
            table.insert(result, player)
        end
    end
    return result
end

--- Ends the current round early when no active participants remain.
--- Safe early-termination avoids runway/voting/results executing on stale data.
--- @param reason string
local function terminateRoundNoParticipants(reason)
    cancelPhaseTimer()
    _d.outfitSystem.Stop()
    if _d.votingSystem.IsVotingOpen() then
        _d.votingSystem.CloseVoting()
    end
    _d.votingSystem.Stop()
    _d.sabotageSystem.Stop()
    _d.runwaySystem.Stop()
    setState(RoundManager.State.IDLE, 0)
    _d.logger.info("RoundManager",
        "Round #" .. _roundNumber .. " ended early (no active participants): " .. reason)
end

--- Lightweight outfit score (0–10) for real-time audience updates during runway.
--- Considers slot fill, accessory count, and material count only — no StyleDNA
--- or judge bias — so it is fast and doesn't duplicate phaseResults scoring.
--- Slots (max 4) → up to 5 pts | Accessories (max 5) → up to 3 pts | Materials (max 3) → up to 2 pts
local function quickOutfitScore(outfit)
    if not outfit then return 0 end
    local slots = 0
    for _, slot in ipairs({ "HeadId", "TopId", "BottomId", "ShoesId" }) do
        if outfit[slot] then slots = slots + 1 end
    end
    local accs = (type(outfit.AccessoryIds) == "table") and #outfit.AccessoryIds or 0
    local mats = (type(outfit.Materials)    == "table") and #outfit.Materials    or 0
    return math.min(10,
        slots * 1.25
        + math.min(accs, 5) * 0.60
        + math.min(mats, 3) * 0.67)
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

    -- Select event type for this round based on recent streaks and meta trends.
    -- Modifiers are applied during phaseResults scoring; logs event name here.
    local metaStatuses = _d.metaSystem.GetAllStyleStatuses()
    _currentEvent = _d.dynamicsSystem.SelectEvent(metaStatuses)
    if _currentEvent.type ~= "NONE" then
        _d.logger.info("RoundManager",
            "Event round: [" .. _currentEvent.type .. "] – " .. _currentEvent.description)
        -- Extension point: fire _d.remotes.EventRoundAnnounced when client UI is ready
    end

    _phaseThread = task.delay(DURATION.THEME_SELECTION, phaseDressing)
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseDressing = function()
    setState(RoundManager.State.DRESSING, DURATION.DRESSING)

    local livePlayers = getLiveRoundPlayers()
    if #livePlayers == 0 then
        terminateRoundNoParticipants("before dressing start")
        return
    end

    -- Clear last round's outfits and performance records so stale data can't carry over
    _d.outfitSystem.ClearRoundOutfits(livePlayers)
    _d.performanceSystem.ClearRound()

    -- Flush round-scoped sabotage effects (e.g. PAINT_RANDOMIZER that was set
    -- but never consumed because the player never submitted an outfit, or a
    -- TEMPORARY_STUN whose timer crossed a round boundary).
    for _, player in ipairs(livePlayers) do
        _d.playerDataManager.ClearAllEffects(player.UserId)
    end

    _d.outfitSystem.Start()
    _d.sabotageSystem.Start()

    _d.logger.info("RoundManager",
        "Dressing phase – " .. DURATION.DRESSING .. "s on the clock.")

    _phaseThread = task.delay(DURATION.DRESSING, function()
        _d.outfitSystem.Stop()
        if #getLiveRoundPlayers() == 0 then
            terminateRoundNoParticipants("all players left during dressing")
            return
        end
        phaseRunway()
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseRunway = function()
    local livePlayers = getLiveRoundPlayers()
    if #livePlayers == 0 then
        terminateRoundNoParticipants("before runway start")
        return
    end

    setState(RoundManager.State.RUNWAY, 0)  -- duration is player-count dependent
    _d.audienceSystem.StartRunway()
    _d.logger.info("RoundManager", "Runway phase starting.")

    -- RunwaySystem drives timing internally; calls the callbacks per turn and on completion
    _d.runwaySystem.StartRunway(
        livePlayers,
        function(player)  -- onTurnStarted: update audience and open performance windows
            local outfit = _d.outfitSystem.GetPlayerOutfit(player.UserId)
            local score  = quickOutfitScore(outfit)
            _d.audienceSystem.UpdateAudience(player, score)
            _d.performanceSystem.StartPerformance(player)
        end,
        function()  -- onComplete: advance to voting
            phaseVoting()
        end
    )
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseVoting = function()
    local livePlayers = getLiveRoundPlayers()
    if #livePlayers == 0 then
        terminateRoundNoParticipants("before voting start")
        return
    end

    setState(RoundManager.State.VOTING, DURATION.VOTING)

    _d.votingSystem.Start()
    _d.votingSystem.OpenVoting(livePlayers, livePlayers)
    _d.logger.info("RoundManager", "Voting phase – " .. DURATION.VOTING .. "s.")

    _phaseThread = task.delay(DURATION.VOTING, phaseResults)
end

-- ─────────────────────────────────────────────────────────────────────────────

phaseResults = function()
    _d.votingSystem.CloseVoting()
    local livePlayers = getLiveRoundPlayers()
    if #livePlayers == 0 then
        terminateRoundNoParticipants("before results scoring")
        return
    end

    setState(RoundManager.State.RESULTS, DURATION.RESULTS)

    local voteTally = _d.votingSystem.TallyVotes()  -- []{userId,voteCount,totalStars,average}

    -- Build a lookup: userId -> average player vote
    local avgByPlayer = {}
    for _, entry in ipairs(voteTally) do
        avgByPlayer[entry.userId] = entry.average
    end

    -- Record this round's outfit styles in the meta buffer (before scoring so
    -- GetStyleModifier reads only historical data, not this round's submissions)
    for _, p in ipairs(livePlayers) do
        local o = _d.outfitSystem.GetPlayerOutfit(p.UserId)
        if o then _d.metaSystem.UpdateGlobalStyleData(o) end
    end

    -- Audience hype multiplier is global (same for all players this round).
    -- Fetched once here to avoid repeated log calls inside the loop.
    local hyped = _d.audienceSystem.GetHypeMultiplier()

    -- Combine player votes with JudgeSystem panel scores (AI = 40% of final)
    local finalResults = {}
    for _, player in ipairs(livePlayers) do
        local userId    = player.UserId
        local outfit    = _d.outfitSystem.GetPlayerOutfit(userId)
        local aiScore   = _d.judgeSystem.ScoreOutfit(player, outfit)
        local pVoteAvg  = avgByPlayer[userId] or 0
        local perfScore = _d.performanceSystem.GetPerformanceScore(player)

        -- Event: STREAK_GAUNTLET – dominant players face a stricter judging bar.
        -- Pressure is 0 in all other event types and in normal rounds.
        local judgePressure = _d.dynamicsSystem.GetJudgePressure(userId, _currentEvent)
        if judgePressure ~= 0 then
            aiScore = math.max(1.0, aiScore + judgePressure)
        end

        -- Event: META_SHAKEUP – players whose DominantStyle matches the flagged style
        -- take an extra AI score penalty on top of MetaSystem's own OVERUSE_PENALTY.
        if _currentEvent and _currentEvent.type == "META_SHAKEUP" then
            local pData    = _d.playerDataManager.GetPlayerData(userId)
            local domStyle = pData and pData.StyleDNA and pData.StyleDNA.DominantStyle or "None"
            if domStyle == _currentEvent.data.shakeupStyle then
                aiScore = math.max(1.0, aiScore + SHAKEUP_EXTRA_PENALTY)
            end
        end

        -- Weighted formula: 60% player vote (normalised to 10-pt scale) + 40% AI,
        -- plus performance bonus (0–3) and underdog bonus, then scaled by hype multiplier.
        -- Underdog bonus is 0 for non-qualifying players so it has no effect in normal play.
        local normVote      = (pVoteAvg / 5) * 10
        local base          = normVote * 0.6 + aiScore * 0.4
        local underdogBonus = _d.dynamicsSystem.GetUnderdogBonus(userId, _currentEvent)
        local final = math.floor(math.min(10.0, (base + perfScore + underdogBonus) * hyped) * 10 + 0.5) / 10

        table.insert(finalResults, {
            userId        = userId,
            name          = player.Name,
            aiScore       = aiScore,
            playerVote    = pVoteAvg,
            perfScore     = perfScore,
            finalScore    = final,
            underdogBonus = underdogBonus,
            judgePressure = judgePressure,
        })
    end

    table.sort(finalResults, function(a, b)
        return a.finalScore > b.finalScore
    end)

    -- Build a UserId → Player lookup so we can pass Player objects to subsystems
    local playerById = {}
    for _, player in ipairs(livePlayers) do
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
            -- Only update reputation for players whose data is still present.
            -- Players who left mid-round had their PlayerData removed in GameController;
            -- skip them here to avoid the warn-and-return path in ReputationSystem.
            if not _d.playerDataManager.GetPlayerData(result.userId) then
                _d.logger.info("RoundManager",
                    player.Name .. " left mid-round – reputation update skipped.")
                result.reputation = 0
                result.repTier    = "Newcomer"
            else
                local roundResult = {
                    userId       = result.userId,
                    rank         = rank,
                    totalPlayers = #livePlayers,
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
        end

        _d.logger.info("RoundManager", string.format(
            "  #%d %-20s  Final: %.1f  (AI: %.1f | Vote: %.1f | Perf: %.2f | Udog: +%.2f | Rep: %.1f [%s])",
            rank, result.name, result.finalScore,
            result.aiScore, result.playerVote, result.perfScore or 0,
            result.underdogBonus or 0,
            result.reputation or 0, result.repTier or "?"))
    end

    -- Record round results in DynamicsSystem so streaks are up to date for the
    -- NEXT round's SelectEvent() call.  Must run after ranks are assigned.
    _d.dynamicsSystem.RecordRoundResults(finalResults)

    -- Final Style DNA refresh: ensures DominantStyle reflects the full round,
    -- even for players who never submitted an outfit this round (score = 0).
    for _, player in ipairs(livePlayers) do
        _d.styleDNA.RecalculateDominantStyle(player.UserId)
    end

    -- Update identity profiles (career stats, title awards) after both streaks and
    -- StyleDNA are settled so archetypes and title checks see current state.
    -- playerById is still in scope from the reputation loop above.
    -- Players who left mid-round are guarded by the GetPlayerData check inside
    -- UpdateAfterRound, consistent with the reputation-update guard above.
    local totalRoundPlayers = #finalResults
    for _, result in ipairs(finalResults) do
        local player = playerById[result.userId]
        if player then
            _d.identitySystem.UpdateAfterRound(player, result, totalRoundPlayers)
        end
    end

    -- Broadcast results to all clients
    _d.remotes.RoundResults:FireAllClients(finalResults)
    _d.logger.info("RoundManager", "Round #" .. _roundNumber .. " results broadcast.")

    -- Finalize meta: decay history and merge this round's buffer.
    -- Must run after all ScoreOutfit calls so the buffer doesn't influence
    -- the scores it just produced.
    _d.metaSystem.FinalizeRound()

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
---   themeSystem, runwaySystem, judgeSystem, metaSystem, audienceSystem,
---   styleDNA, reputationSystem, performanceSystem, dynamicsSystem, identitySystem,
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

    -- Build the live participant set (pruned on disconnect via HandlePlayerLeft)
    _activePlayerSet = {}
    for _, player in ipairs(players) do
        _activePlayerSet[player.UserId] = player
    end

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

--- Called by GameController's PlayerRemoving handler.
--- Removes the player from the live participant set so systems that call
--- IsPlayerInActiveRound (e.g. sabotage checks) see them as gone immediately.
--- @param userId  number
function RoundManager.HandlePlayerLeft(userId)
    if _activePlayerSet[userId] then
        _activePlayerSet[userId] = nil
        _d.logger.info("RoundManager",
            "UserId " .. tostring(userId) .. " removed from active round participant set.")
    end
end

--- Returns true while a round is active and the given player is still a participant.
--- Returns false when no round is in progress or the player disconnected.
--- @param userId  number
--- @return boolean
function RoundManager.IsPlayerInActiveRound(userId)
    return _activePlayerSet[userId] ~= nil
end

--- Returns a list of players who are still actively participating in the current round.
--- Excludes any player who disconnected after the round began.
--- Returns an empty table when no round is in progress.
--- @return Player[]
function RoundManager.GetActiveRoundPlayers()
    return getLiveRoundPlayers()
end

return RoundManager
