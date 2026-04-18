--[[
    GameDataClient  (ModuleScript – StarterPlayerScripts/Modules)
    ──────────────────────────────────────────────────────────────
    Client-side read-only cache for server-authoritative session data.

    The server drives all state; this module only observes.  It is populated
    through two channels:

        Pull  – RemoteFunction InvokeServer calls at phase-transition boundaries.
        Push  – OnClientEvent handlers that update the cache immediately when
                the server broadcasts state-change events.

    ── Cached state ─────────────────────────────────────────────────────────────
        Profile           : IdentityProfile | nil
                            archetype, activeTitle, earnedTitles, careerStats,
                            dominantStyle, styleLabel, repScore, repTier, streaks
        DynamicsSummary   : { streaks, currentEvent, streakLeaders } | nil
        SabotageProfile   : { types: { [typeName]: { cooldownLeft, usesLeft,
                              category, selfTarget, description } } } | nil
        CurrentPhase      : string   ("IDLE" until first PhaseChanged)
        IntermissionEndsAt: number | nil  (os.clock() deadline; nil when inactive)
        LastRoundResult   : table | nil   (local player's entry from last RoundResults)

    ── Signals ───────────────────────────────────────────────────────────────────
        All signals are BindableEvents.  Connect to the .Event RBXScriptSignal:
            GameDataClient.ProfileChanged.Event:Connect(fn)
            GameDataClient.DynamicsChanged.Event:Connect(fn)    -- fires when event also changes
            GameDataClient.SabotageChanged.Event:Connect(fn)
            GameDataClient.EventChanged.Event:Connect(fn)       -- fires for event-only updates
            GameDataClient.PhaseChanged.Event:Connect(fn(stateName, duration))
            GameDataClient.RoundResultsReceived.Event:Connect(fn(localResult))

    ── Refresh schedule ─────────────────────────────────────────────────────────
        Init()            → all three Pull refreshes spawned in parallel
        DRESSING phase    → refresh SabotageProfile (round effects/cooldowns reset)
        RESULTS phase     → refresh Profile + DynamicsSummary (scoring just settled)
        IDLE phase        → clear CurrentEvent (round is over)
        EventRoundAnnounced push → update CurrentEvent immediately (no round-trip)
        RoundResults push → cache local player's result, re-check DynamicsSummary

    ── Public API ────────────────────────────────────────────────────────────────
        GameDataClient.Init()
        GameDataClient.GetProfile()              -> IdentityProfile | nil
        GameDataClient.GetDynamicsSummary()      -> table | nil
        GameDataClient.GetSabotageProfile()      -> table | nil
        GameDataClient.GetCurrentEvent()         -> EventResult | nil
        GameDataClient.GetCurrentPhase()         -> string
        GameDataClient.GetIntermissionTimeLeft() -> number  (0 when not active)
        GameDataClient.GetLastRoundResult()      -> table | nil
--]]

local GameDataClient = {}

-- ── Services ──────────────────────────────────────────────────────────────────

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ── Remotes ───────────────────────────────────────────────────────────────────

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function waitRemote(name)
    return Remotes:WaitForChild(name)
end

-- ── Signals (BindableEvents) ──────────────────────────────────────────────────

GameDataClient.ProfileChanged      = Instance.new("BindableEvent")
GameDataClient.DynamicsChanged     = Instance.new("BindableEvent")
GameDataClient.SabotageChanged     = Instance.new("BindableEvent")
GameDataClient.EventChanged        = Instance.new("BindableEvent")
GameDataClient.PhaseChanged        = Instance.new("BindableEvent")
GameDataClient.RoundResultsReceived = Instance.new("BindableEvent")

-- ── Cached state ──────────────────────────────────────────────────────────────

local _profile             = nil
local _dynamicsSummary     = nil
local _sabotageProfile     = nil
local _currentPhase        = "IDLE"
local _intermissionEndsAt  = nil
local _lastRoundResult     = nil

-- RemoteFunction references (set in Init before any refresh is called)
local _rfProfile   = nil
local _rfDynamics  = nil
local _rfSabotage  = nil

-- ── Internal helpers ──────────────────────────────────────────────────────────

local function refreshProfile()
    local ok, result = pcall(function()
        return _rfProfile:InvokeServer()
    end)
    if ok then
        _profile = result
        GameDataClient.ProfileChanged:Fire()
    end
end

local function refreshDynamics()
    local ok, result = pcall(function()
        return _rfDynamics:InvokeServer()
    end)
    if ok then
        _dynamicsSummary = result
        -- DynamicsSummary embeds currentEvent; fire both change signals
        GameDataClient.DynamicsChanged:Fire()
        GameDataClient.EventChanged:Fire()
    end
end

local function refreshSabotage()
    local ok, result = pcall(function()
        return _rfSabotage:InvokeServer()
    end)
    if ok then
        _sabotageProfile = result
        GameDataClient.SabotageChanged:Fire()
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Returns the cached IdentityProfile, or nil before the first server response.
--- Fields: archetype, activeTitle, earnedTitles[], careerStats, dominantStyle,
---         styleLabel, repScore, repTier, streaks.
--- @return table | nil
function GameDataClient.GetProfile()
    return _profile
end

--- Returns the cached DynamicsSummary, or nil before the first server response.
--- Fields: streaks (StreakProfile|nil), currentEvent (EventResult|nil),
---         streakLeaders ({userId, winStreak}[]).
--- @return table | nil
function GameDataClient.GetDynamicsSummary()
    return _dynamicsSummary
end

--- Returns the cached SabotageProfile, or nil before the first server response.
--- Fields: types table keyed by sabotage type name; each entry has:
---         cooldownLeft (seconds), usesLeft (number), category, selfTarget, description.
--- @return table | nil
function GameDataClient.GetSabotageProfile()
    return _sabotageProfile
end

--- Returns the current EventResult from DynamicsSummary, or nil in IDLE / normal rounds.
--- Kept consistent with DynamicsSummary.currentEvent at all times.
--- @return EventResult | nil
function GameDataClient.GetCurrentEvent()
    return _dynamicsSummary and _dynamicsSummary.currentEvent or nil
end

--- Returns the last PhaseChanged state name broadcast by the server.
--- "IDLE" until the first PhaseChanged event arrives.
--- @return string
function GameDataClient.GetCurrentPhase()
    return _currentPhase
end

--- Returns seconds remaining in the current intermission, or 0.
--- @return number
function GameDataClient.GetIntermissionTimeLeft()
    if not _intermissionEndsAt then return 0 end
    return math.max(0, _intermissionEndsAt - os.clock())
end

--- Returns the local player's result entry from the most recent RoundResults broadcast,
--- or nil before the first completed round.
--- Fields: userId, name, rank, finalScore, aiScore, playerVote, perfScore,
---         underdogBonus, judgePressure, reputation, repTier.
--- @return table | nil
function GameDataClient.GetLastRoundResult()
    return _lastRoundResult
end

-- ── Init ──────────────────────────────────────────────────────────────────────

--- Initialises remote references, wires push-event listeners, and performs the
--- first cache population.  Call exactly once from the loader LocalScript.
function GameDataClient.Init()
    -- ── Acquire remotes ───────────────────────────────────────────────────────
    _rfProfile  = waitRemote("RequestProfile")
    _rfDynamics = waitRemote("RequestDynamicsSummary")
    _rfSabotage = waitRemote("RequestSabotageProfile")

    local evPhaseChanged        = waitRemote("PhaseChanged")
    local evRoundResults        = waitRemote("RoundResults")
    local evIntermissionStarted = waitRemote("IntermissionStarted")
    local evEventRoundAnnounced = waitRemote("EventRoundAnnounced")

    -- ── Push: PhaseChanged ────────────────────────────────────────────────────
    -- Drives selective cache refreshes so the client always reflects the phase
    -- that just started without hammering the server every tick.
    evPhaseChanged.OnClientEvent:Connect(function(stateName, duration)
        _currentPhase = stateName

        if stateName == "DRESSING" then
            -- New round: sabotage effects and round-use counters have been reset
            -- on the server, so fetch updated cooldown/availability state.
            task.spawn(refreshSabotage)

        elseif stateName == "RESULTS" then
            -- Scoring is settled; refresh both profile (career stats, titles) and
            -- dynamics (streaks updated by DynamicsSystem.RecordRoundResults).
            task.spawn(refreshProfile)
            task.spawn(refreshDynamics)

        elseif stateName == "IDLE" then
            -- Round is fully over; clear the event so UI banners disappear.
            if _dynamicsSummary then
                _dynamicsSummary.currentEvent = nil
            end
            _intermissionEndsAt = nil
            GameDataClient.EventChanged:Fire()
        end

        GameDataClient.PhaseChanged:Fire(stateName, duration)
    end)

    -- ── Push: EventRoundAnnounced ─────────────────────────────────────────────
    -- Server pushes event info at THEME_SELECTION without waiting to be asked.
    -- Update the cache immediately so late-joining players who call GetCurrentEvent
    -- via RequestCurrentEvent also see a consistent value.
    evEventRoundAnnounced.OnClientEvent:Connect(function(eventType, description, data)
        local eventResult = { type = eventType, description = description, data = data }
        if _dynamicsSummary then
            _dynamicsSummary.currentEvent = eventResult
        else
            -- DynamicsSummary not yet populated; seed a minimal wrapper so
            -- GetCurrentEvent() doesn't return nil unexpectedly.
            _dynamicsSummary = { streaks = nil, currentEvent = eventResult, streakLeaders = {} }
        end
        GameDataClient.EventChanged:Fire()
        GameDataClient.DynamicsChanged:Fire()
    end)

    -- ── Push: RoundResults ────────────────────────────────────────────────────
    -- Extract the local player's result for easy access.  The RESULTS-phase
    -- refreshProfile/refreshDynamics spawned above will update career stats and
    -- streaks shortly after; this provides immediate access to raw scores.
    evRoundResults.OnClientEvent:Connect(function(results)
        local localUserId = Players.LocalPlayer.UserId
        for _, entry in ipairs(results) do
            if entry.userId == localUserId then
                _lastRoundResult = entry
                GameDataClient.RoundResultsReceived:Fire(entry)
                break
            end
        end
    end)

    -- ── Push: IntermissionStarted ─────────────────────────────────────────────
    evIntermissionStarted.OnClientEvent:Connect(function(durationSeconds)
        _intermissionEndsAt = os.clock() + durationSeconds
    end)

    -- ── Initial cache population ──────────────────────────────────────────────
    -- All three refreshes are independent; spawn in parallel.
    -- Each is pcall-safe so a single server hiccup doesn't leave everything nil.
    task.spawn(refreshProfile)
    task.spawn(refreshDynamics)
    task.spawn(refreshSabotage)
end

return GameDataClient
