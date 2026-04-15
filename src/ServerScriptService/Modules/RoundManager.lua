--[[
    RoundManager
    ────────────
    Orchestrates the lifecycle of a single game round via a state machine.
    Drives OutfitSystem → VotingSystem → SabotageSystem in sequence.
    No timer-based transitions yet – phases are advanced by explicit calls
    (timers will be added in Phase 1).

    State machine:
        IDLE → DRESSING → VOTING → RESULTS → IDLE

    Dependencies (injected via Init):
        OutfitSystem, VotingSystem, SabotageSystem, Logger

    Public API:
        RoundManager.Init(outfitSystem, votingSystem, sabotageSystem, logger)
        RoundManager.Start()
        RoundManager.Stop()
        RoundManager.StartRound(players)
        RoundManager.BeginVoting(players)
        RoundManager.EndRound()
        RoundManager.GetCurrentState()  -> string
        RoundManager.GetRoundNumber()   -> number
        RoundManager.State              -> { IDLE, DRESSING, VOTING, RESULTS }
--]]

local RoundManager = {}

-- ── State enum ───────────────────────────────────────────────────────────────

RoundManager.State = {
    IDLE     = "IDLE",
    DRESSING = "DRESSING",
    VOTING   = "VOTING",
    RESULTS  = "RESULTS",
}

-- ── Private state ────────────────────────────────────────────────────────────

local _outfitSystem   = nil
local _votingSystem   = nil
local _sabotageSystem = nil
local _logger         = nil

local _isRunning    = false
local _currentState = RoundManager.State.IDLE
local _roundNumber  = 0

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function setState(newState)
    _logger.info("RoundManager",
        "State transition: " .. tostring(_currentState) .. " → " .. tostring(newState))
    _currentState = newState
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module with its dependencies.
--- @param outfitSystem   table
--- @param votingSystem   table
--- @param sabotageSystem table
--- @param logger         table
function RoundManager.Init(outfitSystem, votingSystem, sabotageSystem, logger)
    _outfitSystem   = outfitSystem
    _votingSystem   = votingSystem
    _sabotageSystem = sabotageSystem
    _logger         = logger
    _logger.info("RoundManager", "Initialized.")
end

--- Arms the manager so StartRound can be called.
function RoundManager.Start()
    _isRunning = true
    _logger.info("RoundManager", "Started. Awaiting first round.")
end

--- Gracefully stops the manager, ending any in-progress round first.
function RoundManager.Stop()
    if _currentState ~= RoundManager.State.IDLE then
        _logger.info("RoundManager", "Stopping mid-round – forcing EndRound.")
        RoundManager.EndRound()
    end
    _isRunning    = false
    _currentState = RoundManager.State.IDLE
    _logger.info("RoundManager", "Stopped.")
end

--- Begins a new round and opens the DRESSING phase.
--- No-ops with a warning if a round is already active.
--- @param players  Player[]  All participating players
function RoundManager.StartRound(players)
    if not _isRunning then
        _logger.warn("RoundManager", "StartRound called while manager is not running.")
        return
    end
    if _currentState ~= RoundManager.State.IDLE then
        _logger.warn("RoundManager", "StartRound called during active round (state: "
            .. _currentState .. ") – ignoring.")
        return
    end

    _roundNumber = _roundNumber + 1
    _logger.info("RoundManager", "Round #" .. _roundNumber .. " starting with "
        .. #players .. " player(s).")

    _outfitSystem.Start()
    _sabotageSystem.Start()
    setState(RoundManager.State.DRESSING)

    _logger.info("RoundManager", "Round #" .. _roundNumber
        .. " in DRESSING phase. Players may now submit outfits.")
    -- TODO Phase 1: schedule BeginVoting after a timer expires.
end

--- Closes outfit submission and opens the VOTING phase.
--- @param players  Player[]  Voters and vote targets (typically the same list)
function RoundManager.BeginVoting(players)
    if _currentState ~= RoundManager.State.DRESSING then
        _logger.warn("RoundManager", "BeginVoting called outside DRESSING state (current: "
            .. _currentState .. ") – ignoring.")
        return
    end

    _outfitSystem.Stop()
    _votingSystem.Start()
    _votingSystem.OpenVoting(players, players)
    setState(RoundManager.State.VOTING)

    _logger.info("RoundManager", "Round #" .. _roundNumber .. " in VOTING phase.")
    -- TODO Phase 1: schedule EndRound after a timer expires.
end

--- Tallies votes, transitions through RESULTS, resets all subsystems, returns to IDLE.
function RoundManager.EndRound()
    if _currentState == RoundManager.State.IDLE then
        _logger.warn("RoundManager", "EndRound called with no active round – ignoring.")
        return
    end

    local results = {}
    if _currentState == RoundManager.State.VOTING then
        _votingSystem.CloseVoting()
        results = _votingSystem.TallyVotes()
    end

    setState(RoundManager.State.RESULTS)
    _logger.info("RoundManager", "Round #" .. _roundNumber
        .. " results ready. " .. #results .. " player(s) received votes.")

    -- TODO Phase 1: fire RemoteEvent to broadcast results + update ReputationScore

    -- Shut down subsystems
    _votingSystem.Stop()
    _sabotageSystem.Stop()

    setState(RoundManager.State.IDLE)
    _logger.info("RoundManager", "Round #" .. _roundNumber .. " complete.")
end

--- Returns the current state string (one of RoundManager.State).
--- @return string
function RoundManager.GetCurrentState()
    return _currentState
end

--- Returns the number of rounds that have been started this session.
--- @return number
function RoundManager.GetRoundNumber()
    return _roundNumber
end

return RoundManager
