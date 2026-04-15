--[[
    OutfitSystem
    ────────────
    Handles server-side outfit validation and assignment for the DRESSING phase.
    Clients fire SubmitOutfit → GameController → OutfitSystem.ValidateAndSetOutfit().

    Server-authoritative behaviours:
    • Rejects submissions outside the DRESSING phase (GameController enforces this).
    • Applies any active PAINT_RANDOMIZER effect (stored in PlayerData.ActiveEffects),
      overriding the colours the client submitted.
    • Clears the PAINT_RANDOMIZER effect after it has been consumed.

    OutfitData structure (sent by client):
    {
        HeadId         : number | nil,
        TopId          : number | nil,
        BottomId       : number | nil,
        ShoesId        : number | nil,
        AccessoryIds   : number[],          -- up to 5 entries
        ColorPrimary   : { r, g, b },       -- 0..1 components
        ColorSecondary : { r, g, b },
        StyleTags      : string[],          -- e.g. {"Casual", "Streetwear"}
    }

    Dependencies (injected via Init):
        PlayerDataManager, Logger

    Public API:
        OutfitSystem.Init(playerDataManager, logger)
        OutfitSystem.Start()
        OutfitSystem.Stop()
        OutfitSystem.ValidateAndSetOutfit(player, outfitData) -> (bool, string|nil)
        OutfitSystem.GetPlayerOutfit(userId)                  -> table | nil
        OutfitSystem.ClearRoundOutfits(players)
--]]

local OutfitSystem = {}

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil
local _isRunning         = false

-- ── Internal validation ───────────────────────────────────────────────────────

--- Validates the basic structure of an outfit submission.
--- Phase 1: add item-ID ownership checks, slot-count limits, banned IDs.
--- @param outfitData  any
--- @return boolean, string|nil
local function validateOutfit(outfitData)
    if type(outfitData) ~= "table" then
        return false, "outfitData must be a table, got " .. type(outfitData)
    end

    -- AccessoryIds must be a table if provided
    if outfitData.AccessoryIds ~= nil and type(outfitData.AccessoryIds) ~= "table" then
        return false, "AccessoryIds must be a table."
    end

    -- Clamp accessory count to 5
    if outfitData.AccessoryIds and #outfitData.AccessoryIds > 5 then
        return false, "Cannot equip more than 5 accessories."
    end

    -- StyleTags must be a table if provided
    if outfitData.StyleTags ~= nil and type(outfitData.StyleTags) ~= "table" then
        return false, "StyleTags must be a table."
    end

    -- TODO Phase 1: verify HeadId / TopId / BottomId / ShoesId are valid catalogue IDs
    -- TODO Phase 1: verify player owns the items in their inventory

    return true, nil
end

--- Applies an active PAINT_RANDOMIZER effect to the outfit, replacing its colours.
--- Clears the effect from PlayerData after consumption (one-shot use).
--- @param userId     number
--- @param outfitData table  Modified in-place
local function applyPaintRandomizer(userId, outfitData)
    local paint = _playerDataManager.GetEffect(userId, "PAINT_RANDOMIZER")
    if not paint then return end

    outfitData.ColorPrimary   = { r = paint.r1, g = paint.g1, b = paint.b1 }
    outfitData.ColorSecondary = { r = paint.r2, g = paint.g2, b = paint.b2 }
    _playerDataManager.ClearEffect(userId, "PAINT_RANDOMIZER")

    _logger.info("OutfitSystem",
        "PAINT_RANDOMIZER consumed for UserId " .. tostring(userId)
        .. " – colours overridden.")
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param playerDataManager  table
--- @param logger             table
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

--- Validates an outfit from a client, applies any sabotage effects, then persists it.
--- Returns (true, nil) on success, or (false, errorMsg) on rejection.
--- @param player      Player
--- @param outfitData  table
--- @return boolean, string|nil
function OutfitSystem.ValidateAndSetOutfit(player, outfitData)
    if not _isRunning then
        return false, "Outfit submissions are currently closed."
    end

    local valid, err = validateOutfit(outfitData)
    if not valid then
        _logger.warn("OutfitSystem",
            "Invalid outfit from " .. player.Name .. ": " .. tostring(err))
        return false, err
    end

    -- Server enforces active sabotage effects before storing the outfit
    applyPaintRandomizer(player.UserId, outfitData)

    local ok = _playerDataManager.SetPlayerData(player.UserId, "CurrentOutfit", outfitData)
    if not ok then
        _logger.error("OutfitSystem",
            "Failed to persist outfit for " .. player.Name .. " – PlayerData not found.")
        return false, "PlayerData record not found."
    end

    _logger.info("OutfitSystem", "Outfit accepted for " .. player.Name)
    return true, nil
end

--- Returns the stored outfit for a player (server read-only).
--- @param userId  number
--- @return table | nil
function OutfitSystem.GetPlayerOutfit(userId)
    local data = _playerDataManager.GetPlayerData(userId)
    return data and data.CurrentOutfit or nil
end

--- Clears CurrentOutfit for all given players at the start of a new round.
--- @param players  Player[]
function OutfitSystem.ClearRoundOutfits(players)
    for _, player in ipairs(players) do
        _playerDataManager.SetPlayerData(player.UserId, "CurrentOutfit", nil)
    end
    _logger.info("OutfitSystem", "Cleared outfits for " .. #players .. " player(s).")
end

return OutfitSystem
