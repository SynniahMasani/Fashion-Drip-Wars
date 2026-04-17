--[[
    PlayerDataManager
    ─────────────────
    Manages in-memory PlayerData records for every active player.
    No DataStore connections yet – all data is session-only.

    Dependencies (injected via Init):
        Logger

    PlayerData schema:
    {
        UserId             : number,
        CurrentOutfit      : table | nil,   -- set by OutfitSystem each round
        StyleDNA           : {              -- managed by StyleDNA module
            StyleScores    : { Streetwear, Luxury, Casual, Experimental },
            DominantStyle  : string,        -- "None" until first analysis
            RoundsAnalyzed : number,
        },
        MaterialsInventory : table,         -- placeholder; populated in Phase 2
        ReputationScore    : number,        -- 0-100 normalised; managed by ReputationSystem
        MatchHistory       : table,         -- last 10 MatchSummary records (FIFO ring buffer)
        ActiveEffects      : table,         -- { [effectType: string]: effectData }
                                            -- e.g. TEMPORARY_STUN, PAINT_RANDOMIZER
    }

    Public API:
        PlayerDataManager.Init(logger)
        PlayerDataManager.CreatePlayerData(player)          -> PlayerData
        PlayerDataManager.GetPlayerData(userId)             -> PlayerData | nil
        PlayerDataManager.SetPlayerData(userId, key, value) -> boolean
        PlayerDataManager.RemovePlayerData(userId)
        PlayerDataManager.GetAllData()                      -> {[userId]: PlayerData}
        -- NOTE: GetAllData returns a shallow map copy. The values are still
        -- references to the live PlayerData tables — mutations to them DO affect
        -- the store.  Treat returned tables as read-only unless you need to write
        -- via SetPlayerData/SetEffect/ClearEffect.
        -- ActiveEffects helpers (thin wrappers over PlayerData.ActiveEffects):
        PlayerDataManager.SetEffect(userId, effectType, effectData) -> boolean
        PlayerDataManager.GetEffect(userId, effectType)     -> any | nil
        PlayerDataManager.ClearEffect(userId, effectType)   -> boolean
        PlayerDataManager.ClearAllEffects(userId)           -> boolean
--]]

local PlayerDataManager = {}

-- ── Private state ────────────────────────────────────────────────────────────

local _logger = nil
local _store  = {} -- [userId: number] -> PlayerData

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function newPlayerData(userId)
    return {
        UserId        = userId,
        CurrentOutfit = nil,
        StyleDNA      = {
            StyleScores = {
                Streetwear   = 0,
                Luxury       = 0,
                Casual       = 0,
                Experimental = 0,
            },
            DominantStyle  = "None",
            RoundsAnalyzed = 0,
        },
        MaterialsInventory = {},
        ReputationScore    = 0,
        MatchHistory       = {},
        ActiveEffects      = {},
    }
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module. Must be called before any other function.
--- @param logger  table
function PlayerDataManager.Init(logger)
    _logger = logger
    _logger.info("PlayerDataManager", "Initialized.")
end

--- Creates a default PlayerData record for a joining player.
--- Returns the existing record (with a warning) if one already exists.
--- @param player  Player
--- @return PlayerData
function PlayerDataManager.CreatePlayerData(player)
    local userId = player.UserId
    if _store[userId] then
        _logger.warn("PlayerDataManager", "Data already exists for " .. player.Name
            .. " (UserId: " .. userId .. ") – returning existing record.")
        return _store[userId]
    end

    _store[userId] = newPlayerData(userId)
    _logger.info("PlayerDataManager", "Created PlayerData for " .. player.Name
        .. " (UserId: " .. userId .. ")")
    return _store[userId]
end

--- Returns the PlayerData for a given UserId, or nil if not found.
--- @param userId  number
--- @return PlayerData | nil
function PlayerDataManager.GetPlayerData(userId)
    return _store[userId]
end

--- Sets a top-level field on a player's PlayerData record.
--- Returns true on success, false if the record doesn't exist.
--- @param userId  number
--- @param key     string
--- @param value   any
--- @return boolean
function PlayerDataManager.SetPlayerData(userId, key, value)
    local data = _store[userId]
    if not data then
        _logger.error("PlayerDataManager", "SetPlayerData: no record for UserId " .. tostring(userId))
        return false
    end
    data[key] = value
    return true
end

--- Removes the PlayerData record for a leaving player.
--- @param userId  number
function PlayerDataManager.RemovePlayerData(userId)
    if _store[userId] then
        _store[userId] = nil
        _logger.info("PlayerDataManager", "Removed PlayerData for UserId " .. tostring(userId))
    else
        _logger.warn("PlayerDataManager",
            "RemovePlayerData: no record found for UserId " .. tostring(userId))
    end
end

--- Returns a shallow map of the entire store.  The map itself is a new table,
--- but the PlayerData values inside it are live references — mutations to those
--- tables affect the store.  Treat returned values as read-only.
--- @return {[number]: PlayerData}
function PlayerDataManager.GetAllData()
    local snapshot = {}
    for userId, data in pairs(_store) do
        snapshot[userId] = data
    end
    return snapshot
end

-- ── Active-effect helpers ────────────────────────────────────────────────────
-- These are thin wrappers over PlayerData.ActiveEffects so callers don't
-- need to reach into the nested table directly.

--- Stores (or overwrites) a named effect on a player's record.
--- effectData can be any value (table, number, bool, …).
--- @param userId      number
--- @param effectType  string  e.g. "TEMPORARY_STUN", "PAINT_RANDOMIZER"
--- @param effectData  any
--- @return boolean
function PlayerDataManager.SetEffect(userId, effectType, effectData)
    local data = _store[userId]
    if not data then
        _logger.error("PlayerDataManager", "SetEffect: no record for UserId " .. tostring(userId))
        return false
    end
    data.ActiveEffects[effectType] = effectData
    return true
end

--- Returns the effect data for a named effect, or nil if not present.
--- @param userId      number
--- @param effectType  string
--- @return any | nil
function PlayerDataManager.GetEffect(userId, effectType)
    local data = _store[userId]
    if not data then return nil end
    return data.ActiveEffects[effectType]
end

--- Removes a named effect from a player's record.
--- Returns true on success, false if the record doesn't exist.
--- @param userId      number
--- @param effectType  string
--- @return boolean
function PlayerDataManager.ClearEffect(userId, effectType)
    local data = _store[userId]
    if not data then
        _logger.error("PlayerDataManager", "ClearEffect: no record for UserId " .. tostring(userId))
        return false
    end
    data.ActiveEffects[effectType] = nil
    return true
end

--- Removes ALL active effects from a player's record.
--- Used at round-start to ensure no sabotage effects bleed across rounds.
--- Returns true on success, false if the record doesn't exist.
--- @param userId  number
--- @return boolean
function PlayerDataManager.ClearAllEffects(userId)
    local data = _store[userId]
    if not data then
        _logger.warn("PlayerDataManager",
            "ClearAllEffects: no record for UserId " .. tostring(userId))
        return false
    end
    data.ActiveEffects = {}
    return true
end

return PlayerDataManager
