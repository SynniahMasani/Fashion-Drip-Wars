--[[
    SabotageSystem
    ──────────────
    Validates and applies sabotage actions sent by clients.

    Implemented effects:
    ┌─────────────────────┬────────────────────────────────────────────────────┐
    │ PAINT_RANDOMIZER    │ Overwrites the target's outfit colours with random │
    │                     │ values stored in PlayerData.ActiveEffects. Applied │
    │                     │ by OutfitSystem the next time the target submits.  │
    ├─────────────────────┼────────────────────────────────────────────────────┤
    │ TEMPORARY_STUN      │ Blocks the target's outfit submissions for         │
    │                     │ STUN_DURATION seconds. GameController enforces     │
    │                     │ the block by reading PlayerData.ActiveEffects.     │
    └─────────────────────┴────────────────────────────────────────────────────┘

    Both effects fire SabotageApplied to the TARGET's client so their UI can
    show the visual feedback (colour flicker, stun animation, etc.).

    Stub effects (structure only, no gameplay yet):
        STYLE_SCRAMBLE, MATERIAL_STEAL

    All effects are per-type cooldown tracked. The SABOTAGE_TYPES table drives
    both the whitelist and cooldown durations – add new types there only.

    Dependencies (injected via Init):
        PlayerDataManager, Logger, Remotes, PlayersService

    Public API:
        SabotageSystem.Init(playerDataManager, logger, remotes, playersService)
        SabotageSystem.Start()
        SabotageSystem.Stop()
        SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId) -> (bool, string|nil)
        SabotageSystem.GetSabotageTypes() -> string[]
--]]

local SabotageSystem = {}

-- ── Sabotage type registry ────────────────────────────────────────────────────
-- Add new types here; the rest of the module stays unchanged.

local SABOTAGE_TYPES = {
    PAINT_RANDOMIZER = { cooldown = 45,  description = "Randomises the target's outfit colours." },
    TEMPORARY_STUN   = { cooldown = 60,  description = "Blocks outfit submission for 10 seconds." },
    STYLE_SCRAMBLE   = { cooldown = 60,  description = "Scrambles outfit style tags. (Phase 2)" },
    MATERIAL_STEAL   = { cooldown = 90,  description = "Steals a material from inventory. (Phase 2)" },
}

local STUN_DURATION = 10 -- seconds a stun remains active

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil
local _remotes           = nil
local _playersService    = nil
local _isRunning         = false

--- Per-player, per-type cooldown timestamps.
--- { [userId: number]: { [sabotageType: string]: lastUsedClock: number } }
local _cooldowns = {}

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function cooldownRemaining(userId, sabotageType)
    local perType = _cooldowns[userId]
    if not perType then return 0 end
    local lastUsed = perType[sabotageType]
    if not lastUsed then return 0 end
    local cd = SABOTAGE_TYPES[sabotageType].cooldown
    return math.max(0, cd - (os.clock() - lastUsed))
end

local function recordUsage(userId, sabotageType)
    if not _cooldowns[userId] then _cooldowns[userId] = {} end
    _cooldowns[userId][sabotageType] = os.clock()
end

--- Generates a random 0–1 colour component table.
local function randomColor()
    return { r = math.random(), g = math.random(), b = math.random() }
end

-- ── Effect implementations ────────────────────────────────────────────────────

local function applyPaintRandomizer(player, targetUserId)
    local c1, c2 = randomColor(), randomColor()

    -- Store forced colours in PlayerData; OutfitSystem reads and applies them
    -- on the target's next outfit submission.
    _playerDataManager.SetEffect(targetUserId, "PAINT_RANDOMIZER", {
        r1 = c1.r, g1 = c1.g, b1 = c1.b,
        r2 = c2.r, g2 = c2.g, b2 = c2.b,
    })

    -- Notify the target's client for visual feedback
    local targetPlayer = _playersService:GetPlayerByUserId(targetUserId)
    if targetPlayer then
        _remotes.SabotageApplied:FireClient(targetPlayer, "PAINT_RANDOMIZER", {
            primary   = c1,
            secondary = c2,
        })
    end

    _logger.info("SabotageSystem",
        player.Name .. " used PAINT_RANDOMIZER on UserId " .. tostring(targetUserId))
end

local function applyTemporaryStun(player, targetUserId)
    local expiresAt = os.clock() + STUN_DURATION

    -- Store stun expiry; GameController checks this before forwarding SubmitOutfit
    _playerDataManager.SetEffect(targetUserId, "TEMPORARY_STUN", {
        expiresAt = expiresAt,
    })

    -- Notify the target's client so they see the stun UI
    local targetPlayer = _playersService:GetPlayerByUserId(targetUserId)
    if targetPlayer then
        _remotes.SabotageApplied:FireClient(targetPlayer, "TEMPORARY_STUN", {
            duration = STUN_DURATION,
        })
    end

    _logger.info("SabotageSystem",
        player.Name .. " stunned UserId " .. tostring(targetUserId)
        .. " for " .. STUN_DURATION .. "s")
end

--- Dispatches to the correct effect implementation.
local function applyEffect(player, sabotageType, targetUserId)
    if sabotageType == "PAINT_RANDOMIZER" then
        applyPaintRandomizer(player, targetUserId)
    elseif sabotageType == "TEMPORARY_STUN" then
        applyTemporaryStun(player, targetUserId)
    else
        -- Stub: log only until Phase 2 implements the effect
        _logger.info("SabotageSystem",
            player.Name .. " used [" .. sabotageType .. "] on UserId "
            .. tostring(targetUserId) .. " (effect stub – Phase 2)")
    end
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param playerDataManager  table
--- @param logger             table
--- @param remotes            table   ReplicatedStorage.Remotes reference
--- @param playersService     table   game:GetService("Players") reference
function SabotageSystem.Init(playerDataManager, logger, remotes, playersService)
    _playerDataManager = playerDataManager
    _logger            = logger
    _remotes           = remotes
    _playersService    = playersService
    _logger.info("SabotageSystem", "Initialized.")
end

--- Arms the system so sabotage requests are accepted.
function SabotageSystem.Start()
    _isRunning = true
    _logger.info("SabotageSystem", "Started.")
end

--- Disarms the system and clears all cooldown records for this round.
function SabotageSystem.Stop()
    _cooldowns = {}
    _isRunning = false
    _logger.info("SabotageSystem", "Stopped.")
end

--- Validates and, if valid, applies a sabotage action.
--- Returns (true, nil) on success or (false, errorMsg) on rejection.
--- @param player        Player
--- @param sabotageType  string
--- @param targetUserId  number
--- @return boolean, string|nil
function SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId)
    if not _isRunning then
        return false, "SabotageSystem is not running."
    end

    -- Whitelist check
    if not SABOTAGE_TYPES[sabotageType] then
        _logger.warn("SabotageSystem",
            "Unknown sabotage type '" .. tostring(sabotageType)
            .. "' from " .. player.Name)
        return false, "Unknown sabotage type."
    end

    -- Initiator must have a PlayerData record
    if not _playerDataManager.GetPlayerData(player.UserId) then
        _logger.error("SabotageSystem", "No PlayerData for " .. player.Name)
        return false, "PlayerData not found for initiator."
    end

    -- Target must have a PlayerData record (i.e. still in the game)
    if not _playerDataManager.GetPlayerData(targetUserId) then
        _logger.warn("SabotageSystem",
            "Sabotage target UserId " .. tostring(targetUserId) .. " not found.")
        return false, "Target player not found."
    end

    -- No self-targeting
    if player.UserId == targetUserId then
        return false, "Cannot sabotage yourself."
    end

    -- Cooldown check
    local remaining = cooldownRemaining(player.UserId, sabotageType)
    if remaining > 0 then
        _logger.warn("SabotageSystem",
            player.Name .. " on cooldown for " .. sabotageType
            .. " (" .. string.format("%.1f", remaining) .. "s left)")
        return false, string.format("Sabotage on cooldown (%.0fs remaining).", remaining)
    end

    -- Redundant active-effect check: reject if the same effect is already pending
    -- on the target to prevent wasted slots and confusing UI states.
    if sabotageType == "TEMPORARY_STUN" then
        local existing = _playerDataManager.GetEffect(targetUserId, "TEMPORARY_STUN")
        if existing and os.clock() < existing.expiresAt then
            _logger.warn("SabotageSystem",
                "TEMPORARY_STUN already active on UserId "
                .. tostring(targetUserId) .. " – rejected.")
            return false, "Target is already stunned."
        end
    elseif sabotageType == "PAINT_RANDOMIZER" then
        local existing = _playerDataManager.GetEffect(targetUserId, "PAINT_RANDOMIZER")
        if existing then
            _logger.warn("SabotageSystem",
                "PAINT_RANDOMIZER already pending on UserId "
                .. tostring(targetUserId) .. " – rejected.")
            return false, "Target already has a pending paint effect."
        end
    end

    -- All checks passed – commit
    recordUsage(player.UserId, sabotageType)
    applyEffect(player, sabotageType, targetUserId)
    return true, nil
end

--- Returns an alphabetically sorted list of registered sabotage type names.
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
