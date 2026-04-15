--[[
    SabotageSystem
    ──────────────
    Validates and dispatches sabotage actions sent by clients.
    Enforces: action type whitelist, cooldowns per (player, type), target
    existence, no self-targeting. Actual gameplay effects are stubbed –
    they will be wired to OutfitSystem / PlayerDataManager in Phase 1.

    Dependencies (injected via Init):
        PlayerDataManager, Logger

    Public API:
        SabotageSystem.Init(playerDataManager, logger)
        SabotageSystem.Start()
        SabotageSystem.Stop()
        SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId) -> (bool, string|nil)
        SabotageSystem.GetSabotageTypes()  -> string[]
--]]

local SabotageSystem = {}

-- ── Constants ────────────────────────────────────────────────────────────────

--- All recognised sabotage action types.
--- Add new entries here as gameplay expands in Phase 1+.
local SABOTAGE_TYPES = {
    COLOR_SPLASH   = "COLOR_SPLASH",    -- forces a random colour change on target
    STYLE_SCRAMBLE = "STYLE_SCRAMBLE",  -- randomises target's outfit slots
    MATERIAL_STEAL = "MATERIAL_STEAL",  -- steals a material from target's inventory
}

local COOLDOWN_SECONDS = 30 -- global default; per-type overrides can be added later

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil
local _isRunning         = false

--- Cooldown tracking.  { [userId: number]: { [sabotageType: string]: lastUsedClock: number } }
local _cooldowns = {}

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function isValidType(sabotageType)
    return SABOTAGE_TYPES[sabotageType] ~= nil
end

--- Returns seconds remaining on a cooldown, or 0 if ready.
local function cooldownRemaining(userId, sabotageType)
    local perType = _cooldowns[userId]
    if not perType then return 0 end
    local lastUsed = perType[sabotageType]
    if not lastUsed then return 0 end
    return math.max(0, COOLDOWN_SECONDS - (os.clock() - lastUsed))
end

local function recordUsage(userId, sabotageType)
    _cooldowns[userId] = _cooldowns[userId] or {}
    _cooldowns[userId][sabotageType] = os.clock()
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module. Must be called before Start().
--- @param playerDataManager  table
--- @param logger             table
function SabotageSystem.Init(playerDataManager, logger)
    _playerDataManager = playerDataManager
    _logger            = logger
    _logger.info("SabotageSystem", "Initialized.")
end

--- Arms the system so sabotage requests are accepted.
function SabotageSystem.Start()
    _isRunning = true
    _logger.info("SabotageSystem", "Started.")
end

--- Disarms the system and clears all cooldown records.
function SabotageSystem.Stop()
    _cooldowns = {}
    _isRunning = false
    _logger.info("SabotageSystem", "Stopped.")
end

--- Validates a sabotage request from a client.
--- On success, records cooldown and calls the effect stub.
--- Returns (true, nil) or (false, errorMsg).
--- @param player        Player
--- @param sabotageType  string   Must be a key in SABOTAGE_TYPES
--- @param targetUserId  number
--- @return boolean, string|nil
function SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId)
    if not _isRunning then
        return false, "SabotageSystem is not running."
    end

    -- Type whitelist check
    if not isValidType(sabotageType) then
        _logger.warn("SabotageSystem", "Unknown sabotage type '" .. tostring(sabotageType)
            .. "' from " .. player.Name)
        return false, "Unknown sabotage type."
    end

    -- Initiator must have an active PlayerData record
    if not _playerDataManager.GetPlayerData(player.UserId) then
        _logger.error("SabotageSystem", "No PlayerData for initiator " .. player.Name)
        return false, "PlayerData not found for initiator."
    end

    -- Target must have an active PlayerData record
    if not _playerDataManager.GetPlayerData(targetUserId) then
        _logger.warn("SabotageSystem", "Sabotage target UserId " .. tostring(targetUserId)
            .. " not found.")
        return false, "Target player not found."
    end

    -- No self-targeting
    if player.UserId == targetUserId then
        return false, "Cannot sabotage yourself."
    end

    -- Cooldown check
    local remaining = cooldownRemaining(player.UserId, sabotageType)
    if remaining > 0 then
        _logger.warn("SabotageSystem", player.Name .. " on cooldown for "
            .. sabotageType .. " (" .. string.format("%.1f", remaining) .. "s left)")
        return false, string.format("Sabotage on cooldown (%.0fs remaining).", remaining)
    end

    -- All checks passed
    recordUsage(player.UserId, sabotageType)
    SabotageSystem._applyEffect(player, sabotageType, targetUserId)
    return true, nil
end

--- Applies the sabotage effect. Stubbed in Phase 0; wired to gameplay in Phase 1.
--- @param player        Player
--- @param sabotageType  string
--- @param targetUserId  number
function SabotageSystem._applyEffect(player, sabotageType, targetUserId)
    _logger.info("SabotageSystem",
        player.Name .. " used [" .. sabotageType .. "] on UserId "
        .. tostring(targetUserId) .. " – effect stub (Phase 1)")
    -- TODO Phase 1: route to OutfitSystem / PlayerDataManager based on sabotageType
end

--- Returns the list of registered sabotage type names.
--- @return string[]
function SabotageSystem.GetSabotageTypes()
    local list = {}
    for typeName in pairs(SABOTAGE_TYPES) do
        table.insert(list, typeName)
    end
    table.sort(list)
    return list
end

return SabotageSystem
