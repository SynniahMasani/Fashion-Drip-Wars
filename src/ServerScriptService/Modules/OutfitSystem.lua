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
        Materials      : string[],          -- up to 3 material names; player must own each
    }

    Dependencies (injected via Init):
        PlayerDataManager, StyleDNA, MaterialSystem, Logger

    Public API:
        OutfitSystem.Init(playerDataManager, styleDNA, materialSystem, logger)
        OutfitSystem.Start()
        OutfitSystem.Stop()
        OutfitSystem.ValidateAndSetOutfit(player, outfitData) -> (bool, string|nil)
        OutfitSystem.GetPlayerOutfit(userId)                  -> table | nil
        OutfitSystem.ClearRoundOutfits(players)
--]]

local OutfitSystem = {}

-- ── Constants ────────────────────────────────────────────────────────────────

local MAX_ACCESSORIES = 5
local MAX_MATERIALS   = 3   -- must match MaterialSystem.MAX_MATERIALS_PER_OUTFIT
local MAX_STYLE_TAGS  = 10

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _styleDNA          = nil
local _materialSystem    = nil
local _logger            = nil
local _isRunning         = false

-- ── Internal validation ───────────────────────────────────────────────────────

--- Validates a color sub-table: must have r, g, b as numbers in [0, 1].
--- @param c          any
--- @param fieldName  string  used in the error message
--- @return boolean, string|nil
local function validateColor(c, fieldName)
    if c == nil then return true, nil end  -- colors are optional
    if type(c) ~= "table" then
        return false, fieldName .. " must be a table with r/g/b fields."
    end
    for _, ch in ipairs({ "r", "g", "b" }) do
        local v = c[ch]
        if type(v) ~= "number" or v < 0 or v > 1 then
            return false,
                fieldName .. "." .. ch .. " must be a number in [0, 1]."
        end
    end
    return true, nil
end

--- Deep-validates an outfit payload from a client.
--- Rejects wrong types, oversized arrays, non-numeric IDs, non-string tags.
--- Phase 2: add item-ID catalogue ownership checks here.
--- @param outfitData  any
--- @return boolean, string|nil
local function validateOutfit(outfitData)
    if type(outfitData) ~= "table" then
        return false, "outfitData must be a table, got " .. type(outfitData)
    end

    -- Slot IDs must be positive integers or nil
    for _, slot in ipairs({ "HeadId", "TopId", "BottomId", "ShoesId" }) do
        local v = outfitData[slot]
        if v ~= nil and (type(v) ~= "number" or v <= 0 or v ~= math.floor(v)) then
            return false, slot .. " must be a positive integer or nil."
        end
    end

    -- AccessoryIds: table of numbers, max MAX_ACCESSORIES
    if outfitData.AccessoryIds ~= nil then
        if type(outfitData.AccessoryIds) ~= "table" then
            return false, "AccessoryIds must be a table."
        end
        if #outfitData.AccessoryIds > MAX_ACCESSORIES then
            return false, "Cannot equip more than " .. MAX_ACCESSORIES .. " accessories."
        end
        for i, v in ipairs(outfitData.AccessoryIds) do
            if type(v) ~= "number" or v <= 0 or v ~= math.floor(v) then
                return false, "AccessoryIds[" .. i .. "] must be a positive integer."
            end
        end
    end

    -- Materials: table of strings, max MAX_MATERIALS
    if outfitData.Materials ~= nil then
        if type(outfitData.Materials) ~= "table" then
            return false, "Materials must be a table."
        end
        if #outfitData.Materials > MAX_MATERIALS then
            return false, "Cannot use more than " .. MAX_MATERIALS .. " materials."
        end
        for i, v in ipairs(outfitData.Materials) do
            if type(v) ~= "string" or #v == 0 then
                return false, "Materials[" .. i .. "] must be a non-empty string."
            end
        end
    end

    -- StyleTags: table of strings, max MAX_STYLE_TAGS
    if outfitData.StyleTags ~= nil then
        if type(outfitData.StyleTags) ~= "table" then
            return false, "StyleTags must be a table."
        end
        if #outfitData.StyleTags > MAX_STYLE_TAGS then
            return false, "Too many StyleTags (max " .. MAX_STYLE_TAGS .. ")."
        end
        for i, v in ipairs(outfitData.StyleTags) do
            if type(v) ~= "string" or #v == 0 then
                return false, "StyleTags[" .. i .. "] must be a non-empty string."
            end
        end
    end

    -- Colors: must have valid r/g/b fields
    local ok, err = validateColor(outfitData.ColorPrimary,   "ColorPrimary")
    if not ok then return false, err end
    ok, err       = validateColor(outfitData.ColorSecondary, "ColorSecondary")
    if not ok then return false, err end

    -- TODO Phase 2: verify HeadId / TopId / BottomId / ShoesId are valid catalogue IDs
    -- TODO Phase 2: verify player owns the items in their inventory

    return true, nil
end

--- Copies a flat array of primitives into a new table.
local function copyArray(t)
    if not t then return nil end
    local out = {}
    for i, v in ipairs(t) do out[i] = v end
    return out
end

--- Copies a color sub-table into a new table.
local function copyColor(c)
    if not c then return nil end
    return { r = c.r, g = c.g, b = c.b }
end

--- Builds a new server-owned outfit table from a validated raw payload.
--- Prevents mutations (e.g. PAINT_RANDOMIZER) from touching the client's
--- original table reference and blocks injection of unexpected keys.
--- @param raw  table  already-validated client payload
--- @return table
local function sanitizeOutfit(raw)
    return {
        HeadId         = raw.HeadId,
        TopId          = raw.TopId,
        BottomId       = raw.BottomId,
        ShoesId        = raw.ShoesId,
        AccessoryIds   = copyArray(raw.AccessoryIds),
        Materials      = copyArray(raw.Materials),
        StyleTags      = copyArray(raw.StyleTags),
        ColorPrimary   = copyColor(raw.ColorPrimary),
        ColorSecondary = copyColor(raw.ColorSecondary),
    }
end

--- Applies an active PAINT_RANDOMIZER effect to the outfit, replacing its colours.
--- Clears the effect from PlayerData after consumption (one-shot use).
--- outfitData here is already a server-owned sanitized table, safe to mutate.
--- @param userId     number
--- @param outfitData table  sanitized server-side outfit; modified in-place
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
--- @param styleDNA           table  StyleDNA module reference
--- @param materialSystem     table  MaterialSystem module reference
--- @param logger             table
function OutfitSystem.Init(playerDataManager, styleDNA, materialSystem, logger)
    _playerDataManager = playerDataManager
    _styleDNA          = styleDNA
    _materialSystem    = materialSystem
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

    -- Validate material ownership and list constraints (no inventory changes yet)
    local matsOk, matsErr =
        _materialSystem.ValidateOutfitMaterials(player, outfitData.Materials)
    if not matsOk then
        _logger.warn("OutfitSystem",
            "Material validation failed for " .. player.Name .. ": " .. matsErr)
        return false, matsErr
    end

    -- Sanitize: copy validated fields into a new server-owned table so that
    -- subsequent mutations (paint randomizer) never touch the client's data.
    local outfit = sanitizeOutfit(outfitData)

    -- Server enforces active sabotage effects before storing the outfit
    applyPaintRandomizer(player.UserId, outfit)

    local ok = _playerDataManager.SetPlayerData(player.UserId, "CurrentOutfit", outfit)
    if not ok then
        _logger.error("OutfitSystem",
            "Failed to persist outfit for " .. player.Name .. " – PlayerData not found.")
        return false, "PlayerData record not found."
    end

    -- Consume materials now that the outfit is persisted (no waste on data errors)
    _materialSystem.ConsumeOutfitMaterials(player, outfit.Materials)

    -- Analyse the final (post-sabotage) outfit and update the player's Style DNA.
    -- Called after applyPaintRandomizer so DNA reflects server-authoritative colours.
    _styleDNA.UpdateStyleDNA(player, outfit)

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
