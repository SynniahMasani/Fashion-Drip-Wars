--[[
    OutfitSystem
    ────────────
    Handles server-side outfit validation and assignment.
    Clients fire SubmitOutfit → GameController → OutfitSystem.ValidateAndSetOutfit().
    All final state mutations go through PlayerDataManager; clients never write
    directly to server data.

    Dependencies (injected via Init):
        PlayerDataManager, Logger

    Public API:
        OutfitSystem.Init(playerDataManager, logger)
        OutfitSystem.Start()
        OutfitSystem.Stop()
        OutfitSystem.ValidateAndSetOutfit(player, outfitData) -> (bool, string|nil)
        OutfitSystem.GetPlayerOutfit(userId)                  -> table | nil
--]]

local OutfitSystem = {}

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil
local _isRunning         = false

-- ── Internal validation ───────────────────────────────────────────────────────

--- Validates the structure of an outfit submission.
--- Extend with real rules (item IDs, slot limits, banned items) in Phase 1.
--- @param outfitData  any
--- @return boolean, string|nil  (valid, errorMsg)
local function validateOutfit(outfitData)
    if type(outfitData) ~= "table" then
        return false, "outfitData must be a table, got " .. type(outfitData)
    end
    -- Phase 1: validate item IDs, slot counts, ownership, banned catalogue IDs…
    return true, nil
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module. Must be called before Start().
--- @param playerDataManager  table  PlayerDataManager reference
--- @param logger             table  Logger reference
function OutfitSystem.Init(playerDataManager, logger)
    _playerDataManager = playerDataManager
    _logger            = logger
    _logger.info("OutfitSystem", "Initialized.")
end

--- Opens outfit submission for the current round.
function OutfitSystem.Start()
    _isRunning = true
    _logger.info("OutfitSystem", "Started – outfit submissions open.")
end

--- Closes outfit submission (called when the DRESSING phase ends).
function OutfitSystem.Stop()
    _isRunning = false
    _logger.info("OutfitSystem", "Stopped – outfit submissions closed.")
end

--- Validates an outfit submitted by a client, then persists it if valid.
--- Returns (true, nil) on success or (false, errorMsg) on failure.
--- @param player      Player
--- @param outfitData  table  Raw data sent by the client
--- @return boolean, string|nil
function OutfitSystem.ValidateAndSetOutfit(player, outfitData)
    if not _isRunning then
        return false, "Outfit submissions are currently closed."
    end

    local valid, err = validateOutfit(outfitData)
    if not valid then
        _logger.warn("OutfitSystem", "Invalid outfit from " .. player.Name .. ": " .. tostring(err))
        return false, err
    end

    local ok = _playerDataManager.SetPlayerData(player.UserId, "CurrentOutfit", outfitData)
    if not ok then
        _logger.error("OutfitSystem", "Failed to persist outfit for " .. player.Name
            .. " – PlayerData not found.")
        return false, "PlayerData record not found."
    end

    _logger.info("OutfitSystem", "Outfit accepted for " .. player.Name)
    return true, nil
end

--- Returns the current outfit for a player (server-side read only).
--- @param userId  number
--- @return table | nil
function OutfitSystem.GetPlayerOutfit(userId)
    local data = _playerDataManager.GetPlayerData(userId)
    return data and data.CurrentOutfit or nil
end

return OutfitSystem
