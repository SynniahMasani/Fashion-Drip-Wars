--[[
    MaterialSystem
    ──────────────
    Manages the material catalogue and each player's MaterialsInventory.

    Materials are gameplay-affecting outfit components that grant a score bonus
    to the AI judge.  Each definition carries a Rarity tier, a ScoreModifier
    (flat bonus on the 0–10 AI-judge scale), and an optional ThemeAffinity list.

    ── Scoring ───────────────────────────────────────────────────────────────────
    For every material included in a submitted outfit:

        bonus = ScoreModifier
              + AFFINITY_BONUS  (only when the active theme shares at least one
                                 tag with the material's ThemeAffinity list)

    The total material contribution across all materials in an outfit is capped
    at MAX_MATERIAL_BONUS (2.0) to prevent degenerate stacking.  Final score
    clamping to [1.0, 10.0] is performed by AIJudge.

    ── Per-outfit rules ─────────────────────────────────────────────────────────
    • Up to MAX_MATERIALS_PER_OUTFIT (3) unique materials per outfit.
    • Each material name may appear at most once per outfit.
    • The player must own ≥1 unit of every listed material (server-authoritative).
    • Materials are consumed (decremented by 1) on successful outfit submission.
    • Outfits with no Materials field (or an empty list) are fully valid.

    ── Expandability ────────────────────────────────────────────────────────────
    To add a new material: append one entry to MATERIAL_DEFS.  No other code
    change is needed anywhere in the codebase.  Phase 2 crafting calls
    AddMaterial to grant crafted items to players.

    MaterialDef:
    {
        name          : string,
        rarity        : string,    -- "Common" | "Uncommon" | "Rare" | "Legendary"
        scoreModifier : number,    -- flat AI-score bonus (0–10 scale)
        themeAffinity : string[]   -- theme tags that activate AFFINITY_BONUS;
                                   -- nil means no affinity (no extra bonus possible)
    }

    Dependencies (injected via Init):
        PlayerDataManager, Logger

    Public API:
        MaterialSystem.Init(playerDataManager, logger)
        MaterialSystem.AddMaterial(player, materialName, amount)  -> boolean
        MaterialSystem.UseMaterial(player, materialName)          -> boolean, string|nil
        MaterialSystem.HasMaterial(player, materialName, amount)  -> boolean
        MaterialSystem.GetInventory(player)                       -> { [string]: number } | nil
        MaterialSystem.GetMaterialDef(materialName)               -> MaterialDef | nil
        MaterialSystem.GetScoreBonus(materialName, theme)         -> number
        MaterialSystem.GetAllMaterials()                          -> { [string]: MaterialDef }

    Internal helpers (used by OutfitSystem):
        MaterialSystem.ValidateOutfitMaterials(player, materials) -> boolean, string|nil
        MaterialSystem.ConsumeOutfitMaterials(player, materials)
        MaterialSystem.ComputeTotalBonus(materials, theme)        -> number
--]]

local MaterialSystem = {}

-- ── Material catalogue ────────────────────────────────────────────────────────
-- Append new rows here to extend the system; no other file needs to change.
-- ScoreModifiers are on the 0–10 AI-judge scale; AFFINITY_BONUS stacks on top.

local MATERIAL_DEFS = {
    -- ── Common ────────────────────────────────────────────────────────────────
    Silk = {
        name          = "Silk",
        rarity        = "Common",
        scoreModifier = 0.30,
        themeAffinity = { "Elegant", "Formal", "Glamorous" },
    },
    BambooLinen = {
        name          = "BambooLinen",
        rarity        = "Common",
        scoreModifier = 0.25,
        themeAffinity = { "Nature", "Bohemian", "Earthy", "Casual" },
    },
    CottonCanvas = {
        name          = "CottonCanvas",
        rarity        = "Common",
        scoreModifier = 0.20,
        themeAffinity = nil,  -- no affinity; equally useful in any theme
    },

    -- ── Uncommon ─────────────────────────────────────────────────────────────
    NeonFiber = {
        name          = "NeonFiber",
        rarity        = "Uncommon",
        scoreModifier = 0.50,
        themeAffinity = { "Futuristic", "Sci-Fi", "Techwear", "Bold", "Colourful" },
    },
    Velvet = {
        name          = "Velvet",
        rarity        = "Uncommon",
        scoreModifier = 0.40,
        themeAffinity = { "Elegant", "Formal", "Glamorous", "Historical" },
    },
    GoldenBrocade = {
        name          = "GoldenBrocade",
        rarity        = "Uncommon",
        scoreModifier = 0.45,
        themeAffinity = { "Historical", "Elegant", "Formal", "Exotic" },
    },

    -- ── Rare ──────────────────────────────────────────────────────────────────
    CrystalWeave = {
        name          = "CrystalWeave",
        rarity        = "Rare",
        scoreModifier = 0.70,
        themeAffinity = { "Cool", "Elegant", "Fantasy", "Minimalist" },
    },
    ObsidianThread = {
        name          = "ObsidianThread",
        rarity        = "Rare",
        scoreModifier = 0.75,
        themeAffinity = { "Dark", "Minimalist", "Streetwear" },
    },
    ChromePlex = {
        name          = "ChromePlex",
        rarity        = "Rare",
        scoreModifier = 0.70,
        themeAffinity = { "Futuristic", "Sci-Fi", "Retro", "Techwear" },
    },

    -- ── Legendary ─────────────────────────────────────────────────────────────
    AuroraFabric = {
        name          = "AuroraFabric",
        rarity        = "Legendary",
        scoreModifier = 1.20,
        themeAffinity = nil,  -- no affinity; the raw modifier is the reward
    },
    StardustMesh = {
        name          = "StardustMesh",
        rarity        = "Legendary",
        scoreModifier = 1.00,
        themeAffinity = { "Fantasy", "Futuristic", "Sci-Fi" },
    },
}

-- ── Constants ────────────────────────────────────────────────────────────────

local AFFINITY_BONUS           = 0.30  -- added when theme tag matches affinity
local MAX_MATERIAL_BONUS       = 2.00  -- total bonus cap across all materials per outfit
local MAX_MATERIALS_PER_OUTFIT = 3     -- maximum unique materials in one outfit

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil

-- ── Internal helpers ─────────────────────────────────────────────────────────

--- Returns true when the theme shares at least one tag with a material's affinity list.
--- @param affinity  string[] | nil
--- @param theme     table | nil
--- @return boolean
local function themeMatches(affinity, theme)
    if not affinity or not theme or not theme.tags then return false end
    local themeSet = {}
    for _, tag in ipairs(theme.tags) do themeSet[tag] = true end
    for _, tag in ipairs(affinity) do
        if themeSet[tag] then return true end
    end
    return false
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param playerDataManager  table
--- @param logger             table
function MaterialSystem.Init(playerDataManager, logger)
    _playerDataManager = playerDataManager
    _logger            = logger

    local count = 0
    for _ in pairs(MATERIAL_DEFS) do count = count + 1 end
    _logger.info("MaterialSystem",
        "Initialized with " .. count .. " material definitions.")
end

--- Grants `amount` units of a named material to a player's inventory.
--- Creates the inventory entry if it doesn't exist.
--- Returns false (with a warning) when the material name is unknown or amount < 1.
--- @param player       Player
--- @param materialName string
--- @param amount       number  positive integer
--- @return boolean
function MaterialSystem.AddMaterial(player, materialName, amount)
    amount = math.floor(amount or 1)
    if amount < 1 then
        _logger.warn("MaterialSystem",
            "AddMaterial: amount must be >= 1 (got " .. tostring(amount) .. ").")
        return false
    end
    if not MATERIAL_DEFS[materialName] then
        _logger.warn("MaterialSystem",
            "AddMaterial: unknown material '" .. tostring(materialName) .. "'.")
        return false
    end

    local data = _playerDataManager.GetPlayerData(player.UserId)
    if not data then
        _logger.error("MaterialSystem",
            "AddMaterial: no PlayerData for " .. player.Name)
        return false
    end

    local inv = data.MaterialsInventory
    inv[materialName] = (inv[materialName] or 0) + amount

    _logger.info("MaterialSystem", string.format(
        "+%d %s  →  %s  (total: %d)",
        amount, materialName, player.Name, inv[materialName]))
    return true
end

--- Decrements a player's inventory by 1 unit for the given material.
--- Returns (true, nil) on success, or (false, errorMsg) on any failure.
--- Removes the inventory key entirely when the count reaches zero.
--- @param player       Player
--- @param materialName string
--- @return boolean, string|nil
function MaterialSystem.UseMaterial(player, materialName)
    if not MATERIAL_DEFS[materialName] then
        return false, "Unknown material: " .. tostring(materialName)
    end

    local data = _playerDataManager.GetPlayerData(player.UserId)
    if not data then
        return false, "PlayerData not found."
    end

    local inv   = data.MaterialsInventory
    local owned = inv[materialName] or 0
    if owned < 1 then
        return false,
            "Insufficient " .. materialName .. " (have " .. owned .. ", need 1)."
    end

    inv[materialName] = owned - 1
    if inv[materialName] == 0 then
        inv[materialName] = nil   -- keep the table clean
    end

    _logger.info("MaterialSystem", string.format(
        "%s used 1x %s  (remaining: %d)",
        player.Name, materialName, inv[materialName] or 0))
    return true, nil
end

--- Returns true when the player owns at least `amount` units of the material.
--- @param player       Player
--- @param materialName string
--- @param amount       number  defaults to 1
--- @return boolean
function MaterialSystem.HasMaterial(player, materialName, amount)
    amount = amount or 1
    local data = _playerDataManager.GetPlayerData(player.UserId)
    if not data then return false end
    return (data.MaterialsInventory[materialName] or 0) >= amount
end

--- Returns a shallow copy of the player's MaterialsInventory.
--- Returns nil when the player has no PlayerData record.
--- @param player  Player
--- @return { [string]: number } | nil
function MaterialSystem.GetInventory(player)
    local data = _playerDataManager.GetPlayerData(player.UserId)
    if not data then return nil end
    local copy = {}
    for mat, qty in pairs(data.MaterialsInventory) do
        copy[mat] = qty
    end
    return copy
end

--- Returns the MaterialDef for a given name, or nil if unknown.
--- @param materialName  string
--- @return MaterialDef | nil
function MaterialSystem.GetMaterialDef(materialName)
    return MATERIAL_DEFS[materialName]
end

--- Returns the score bonus a single material contributes for the given theme.
--- Includes AFFINITY_BONUS when the theme shares a tag with the material's affinity.
--- Returns 0 for unknown material names (safe during iteration).
--- @param materialName  string
--- @param theme         table | nil  ThemeSystem.GetCurrentTheme() result
--- @return number
function MaterialSystem.GetScoreBonus(materialName, theme)
    local def = MATERIAL_DEFS[materialName]
    if not def then return 0 end
    local bonus = def.scoreModifier
    if themeMatches(def.themeAffinity, theme) then
        bonus = bonus + AFFINITY_BONUS
    end
    return bonus
end

--- Returns the full material catalogue.
--- Treat as read-only; do not mutate the returned table.
--- @return { [string]: MaterialDef }
function MaterialSystem.GetAllMaterials()
    return MATERIAL_DEFS
end

-- ── Outfit-level helpers (used by OutfitSystem and AIJudge) ──────────────────

--- Validates that an outfit's material list is well-formed and affordable.
--- Does NOT consume any materials.
--- @param player     Player
--- @param materials  string[] | nil
--- @return boolean, string|nil
function MaterialSystem.ValidateOutfitMaterials(player, materials)
    if not materials or #materials == 0 then return true, nil end

    if #materials > MAX_MATERIALS_PER_OUTFIT then
        return false, "Too many materials (max "
            .. MAX_MATERIALS_PER_OUTFIT .. ", got " .. #materials .. ")."
    end

    local seen = {}
    for _, matName in ipairs(materials) do
        if type(matName) ~= "string" then
            return false, "Material names must be strings."
        end
        if not MATERIAL_DEFS[matName] then
            return false, "Unknown material: " .. matName
        end
        if seen[matName] then
            return false, "Duplicate material '" .. matName
                .. "' (each material may be used at most once per outfit)."
        end
        seen[matName] = true

        if not MaterialSystem.HasMaterial(player, matName, 1) then
            return false, "Insufficient quantity of: " .. matName
        end
    end

    return true, nil
end

--- Consumes 1 unit of each material in the list.
--- Call only after ValidateOutfitMaterials returns true (no partial-failure
--- recovery is attempted here; the caller owns the guard).
--- @param player     Player
--- @param materials  string[] | nil
function MaterialSystem.ConsumeOutfitMaterials(player, materials)
    if not materials or #materials == 0 then return end
    for _, matName in ipairs(materials) do
        MaterialSystem.UseMaterial(player, matName)
    end
    _logger.info("MaterialSystem", string.format(
        "%s consumed material(s): %s",
        player.Name, table.concat(materials, ", ")))
end

--- Returns the total score bonus for an outfit's material list, capped at
--- MAX_MATERIAL_BONUS.  Safe to call with a nil or empty list.
--- @param materials  string[] | nil
--- @param theme      table | nil
--- @return number
function MaterialSystem.ComputeTotalBonus(materials, theme)
    if not materials or #materials == 0 then return 0 end
    local total = 0
    for _, matName in ipairs(materials) do
        total = total + MaterialSystem.GetScoreBonus(matName, theme)
    end
    return math.min(total, MAX_MATERIAL_BONUS)
end

return MaterialSystem
