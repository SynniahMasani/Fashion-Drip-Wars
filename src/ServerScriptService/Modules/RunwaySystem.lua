--[[
    RunwaySystem
    ────────────
    Queues players for the runway phase and drives their walk turns in order.
    Each player gets TURN_DURATION seconds on the runway, then the next
    player is called automatically. Fires RunwayTurnStarted to all clients
    so each client's camera / UI can follow the correct player.

    Shuffle: the queue is Fisher-Yates shuffled each round so the walk order
    varies. A disconnected player is detected and skipped automatically.

    Dependencies (injected via Init):
        Logger, Remotes (ReplicatedStorage.Remotes folder reference)

    Public API:
        RunwaySystem.Init(logger, remotes)
        RunwaySystem.StartRunway(players, onComplete)
        RunwaySystem.SkipCurrent()
        RunwaySystem.Stop()
        RunwaySystem.GetCurrentUserId() -> number | nil
        RunwaySystem.IsRunning()        -> boolean
--]]

local RunwaySystem = {}

-- ── Constants ────────────────────────────────────────────────────────────────

local TURN_DURATION = 10 -- seconds each player occupies the runway

-- ── Private state ────────────────────────────────────────────────────────────

local _logger    = nil
local _remotes   = nil
local _isRunning = false

local _queue        = {} -- ordered array of Player objects (shuffled)
local _currentIndex = 0  -- index of the player currently on the runway
local _turnThread   = nil -- cancellable task thread for the current turn
local _advanceTurn  = nil -- forward-declared so SkipCurrent can call it

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function cancelTurnTimer()
    if _turnThread then
        task.cancel(_turnThread)
        _turnThread = nil
    end
end

local function shuffleInPlace(t)
    for i = #t, 2, -1 do
        local j = math.random(1, i)
        t[i], t[j] = t[j], t[i]
    end
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param logger   table  Logger reference
--- @param remotes  table  ReplicatedStorage.Remotes folder reference
function RunwaySystem.Init(logger, remotes)
    _logger  = logger
    _remotes = remotes
    _logger.info("RunwaySystem", "Initialized.")
end

--- Begins the runway sequence for a list of players.
--- Fires RunwayTurnStarted(userId, turnIndex, totalPlayers) for each turn.
--- Calls onComplete() when every player has walked (or been skipped).
--- @param players    Player[]
--- @param onComplete function  Called with no arguments when the runway ends
function RunwaySystem.StartRunway(players, onComplete)
    cancelTurnTimer()

    -- Build and shuffle the queue
    _queue = {}
    for _, player in ipairs(players) do
        table.insert(_queue, player)
    end
    shuffleInPlace(_queue)

    _currentIndex = 0
    _isRunning    = true

    _logger.info("RunwaySystem", "Runway starting – " .. #_queue .. " player(s) in queue.")

    -- Define advanceTurn at module scope so SkipCurrent can invoke it
    _advanceTurn = function()
        _currentIndex = _currentIndex + 1

        -- End of queue
        if _currentIndex > #_queue then
            _isRunning = false
            _logger.info("RunwaySystem", "Runway complete.")
            if onComplete then
                task.spawn(onComplete)
            end
            return
        end

        local currentPlayer = _queue[_currentIndex]

        -- Auto-skip players who left mid-round
        if not currentPlayer or not currentPlayer.Parent then
            _logger.info("RunwaySystem",
                "Player at index " .. _currentIndex .. " disconnected – skipping.")
            _advanceTurn()
            return
        end

        _logger.info("RunwaySystem",
            "Runway turn: " .. currentPlayer.Name
            .. " (" .. _currentIndex .. "/" .. #_queue .. ")")

        -- Notify all clients: (userId, turnIndex, totalPlayers)
        _remotes.RunwayTurnStarted:FireAllClients(
            currentPlayer.UserId,
            _currentIndex,
            #_queue
        )

        -- Schedule next turn
        _turnThread = task.delay(TURN_DURATION, _advanceTurn)
    end

    _advanceTurn()
end

--- Immediately ends the current player's turn and advances to the next.
--- Useful for admin overrides or disconnection handling.
function RunwaySystem.SkipCurrent()
    if not _isRunning then
        _logger.warn("RunwaySystem", "SkipCurrent called but runway is not running.")
        return
    end
    _logger.info("RunwaySystem", "Skipping current runway turn.")
    cancelTurnTimer()
    if _advanceTurn then
        task.spawn(_advanceTurn)
    end
end

--- Halts the runway immediately and clears all state.
function RunwaySystem.Stop()
    cancelTurnTimer()
    _queue        = {}
    _currentIndex = 0
    _isRunning    = false
    _advanceTurn  = nil
    _logger.info("RunwaySystem", "Stopped.")
end

--- Returns the UserId of the player currently on the runway, or nil.
--- @return number | nil
function RunwaySystem.GetCurrentUserId()
    if not _isRunning then return nil end
    local player = _queue[_currentIndex]
    return player and player.UserId or nil
end

--- Returns whether a runway sequence is currently in progress.
--- @return boolean
function RunwaySystem.IsRunning()
    return _isRunning
end

return RunwaySystem
