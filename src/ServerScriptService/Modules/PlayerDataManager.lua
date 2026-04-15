--[[
    PlayerDataManager
    ─────────────────
    Manages in-memory PlayerData records for every active player.
    No DataStore connections in Phase 0 – all data lives in _store.

    Dependencies (injected via Init):
        Logger

    PlayerData schema:
    {
        UserId             : number,
        CurrentOutfit      : table | nil,   -- set by OutfitSystem
        StyleDNA           : table,         -- placeholder, populated later
        MaterialsInventory : table,         -- empty table, populated later
        ReputationScore    : number,        -- default 0
    }

    Public API:
        PlayerDataManager.Init(logger)
        PlayerDataManager.CreatePlayerData(player)  -> PlayerData
        PlayerDataManager.GetPlayerData(userId)     -> PlayerData | nil
        PlayerDataManager.SetPlayerData(userId, key, value) -> boolean
        PlayerDataManager.RemovePlayerData(userId)
        PlayerDataManager.GetAllData()              -> {[userId]: PlayerData}
--]]

local PlayerDataManager = {}

-- ── Private state ────────────────────────────────────────────────────────────

local _logger = nil
local _store  = {} -- [userId: number] -> PlayerData

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function newPlayerData(userId)
    return {
        UserId             = userId,
        CurrentOutfit      = nil,
        StyleDNA           = {},
        MaterialsInventory = {},
        ReputationScore    = 0,
    }
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module. Must be called before any other function.
--- @param logger  table  Logger module reference
function PlayerDataManager.Init(logger)
    _logger = logger
    _logger.info("PlayerDataManager", "Initialized.")
end

--- Creates a default PlayerData record for a joining player.
--- Returns the existing record if one already exists.
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

--- Sets a single field on a player's PlayerData record.
--- Returns true on success, false if no record exists.
--- @param userId  number
--- @param key     string   Field name (must be a valid PlayerData key)
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
        _logger.warn("PlayerDataManager", "RemovePlayerData: no record found for UserId " .. tostring(userId))
    end
end

--- Returns a shallow snapshot of the entire store (keyed by UserId).
--- Mutations to the returned table do NOT affect the internal store.
--- @return {[number]: PlayerData}
function PlayerDataManager.GetAllData()
    local snapshot = {}
    for userId, data in pairs(_store) do
        snapshot[userId] = data
    end
    return snapshot
end

return PlayerDataManager
