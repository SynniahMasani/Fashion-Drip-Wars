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

    All effects are per-type cooldown + per-round use-cap tracked. The
    SABOTAGE_TYPES table drives validation and metadata lookup.

    Dependencies (injected via Init):
        PlayerDataManager, Logger, Remotes, PlayersService

    ── Public API ────────────────────────────────────────────────────────────────
        SabotageSystem.Init(playerDataManager, logger, remotes, playersService)
        SabotageSystem.Start()
        SabotageSystem.Stop()
        SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId) -> (bool, string|nil)
        SabotageSystem.GetSabotageTypes() -> string[]
        SabotageSystem.GetSabotageTypeMeta(sabotageType) -> table|nil
--]]

local SabotageSystem = {}

-- ── Sabotage type registry ────────────────────────────────────────────────────
-- Add new types here; the rest of the module stays unchanged.

local SABOTAGE_TYPES = {
    PAINT_RANDOMIZER = { cooldown = 45, maxPerRound = 2, category = "offensive", targetMode = "opponent", description = "Randomises the target's outfit colours." },
    TEMPORARY_STUN   = { cooldown = 60, maxPerRound = 2, category = "offensive", targetMode = "opponent", description = "Blocks outfit submission for 10 seconds." },
    STYLE_SCRAMBLE   = { cooldown = 60, maxPerRound = 1, category = "offensive", targetMode = "opponent", description = "Scrambles outfit style tags. (Phase 2)" },
    MATERIAL_STEAL   = { cooldown = 90, maxPerRound = 1, category = "offensive", targetMode = "opponent", description = "Steals a material from inventory. (Phase 2)" },
    MIRROR_SHIELD    = { cooldown = 45, maxPerRound = 2, category = "defensive", targetMode = "self",     description = "Blocks/reflects incoming sabotage." },
    CLEANSE          = { cooldown = 45, maxPerRound = 2, category = "defensive", targetMode = "self",     description = "Clears active negative effects + grants short immunity." },
}

local STUN_DURATION = 10 -- seconds a stun remains active
local MIRROR_SHIELD_DURATION = 25
local IMMUNITY_DURATION = 8

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil
local _remotes           = nil
local _playersService    = nil
local _isRunning         = false

-- { [userId]: { [sabotageType]: lastUsedClock } }
local _cooldowns = {}
--- Per-player, per-type count in the current round.
--- { [userId: number]: { [sabotageType: string]: number } }
local _roundUses = {}

-- { [userId]: { [sabotageType]: usesThisRound } }  reset in Stop()
local _roundUses = {}

-- { [targetUserId]: { [sabotageType]: immunityExpiresAt } }  reset in Stop()
local _targetImmunity = {}

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function cooldownRemaining(userId, sabotageType)
    local perType = _cooldowns[userId]
    if not perType then return 0 end
    local lastUsed = perType[sabotageType]
    if not lastUsed then return 0 end
    local cd = SABOTAGE_TYPES[sabotageType].cooldown
    return math.max(0, cd - (os.clock() - lastUsed))
end

local function roundUsesRemaining(userId, sabotageType, sabotageDef)
    local perType = _roundUses[userId]
    local used = perType and perType[sabotageType] or 0
    return math.max(0, sabotageDef.maxPerRound - used)
end

local function recordUsage(userId, sabotageType)
    if not _cooldowns[userId] then _cooldowns[userId] = {} end
    _cooldowns[userId][sabotageType] = os.clock()
    if not _roundUses[userId] then _roundUses[userId] = {} end
    _roundUses[userId][sabotageType] = (_roundUses[userId][sabotageType] or 0) + 1
end

local function recordRoundUse(userId, sabotageType)
    if not _roundUses[userId] then _roundUses[userId] = {} end
    _roundUses[userId][sabotageType] = (_roundUses[userId][sabotageType] or 0) + 1
end

local function recordImmunity(targetUserId, sabotageType)
    if not _targetImmunity[targetUserId] then _targetImmunity[targetUserId] = {} end
    _targetImmunity[targetUserId][sabotageType] = os.clock() + IMMUNITY_WINDOW
end

local function isImmune(targetUserId, sabotageType)
    local perTarget = _targetImmunity[targetUserId]
    if not perTarget then return false end
    local expiresAt = perTarget[sabotageType]
    if not expiresAt then return false end
    return os.clock() < expiresAt
end

--- Counts how many offensive effects are currently active on a target.
local function countActiveOffensiveEffects(targetUserId)
    local count = 0
    for _, effectKey in ipairs(OFFENSIVE_EFFECT_KEYS) do
        local effect = _playerDataManager.GetEffect(targetUserId, effectKey)
        if effect then
            -- TEMPORARY_STUN has an expiresAt; check it hasn't expired
            if effectKey == "TEMPORARY_STUN" then
                if os.clock() < effect.expiresAt then
                    count = count + 1
                end
            else
                count = count + 1
            end
        end
    end
    return count
end

--- Generates a random 0–1 colour component table.
local function randomColor()
    return { r = math.random(), g = math.random(), b = math.random() }
end

-- ── MIRROR_SHIELD intercept ───────────────────────────────────────────────────

--- Returns true if the target has an active MIRROR_SHIELD.
--- If so, consumes the shield, notifies the shielded player, and returns true.
--- The caller must still consume the attacker's cooldown (not their round charge).
--- @param attacker      Player
--- @param targetUserId  number
--- @param sabotageType  string
--- @return boolean  shieldFired
local function checkMirrorShield(attacker, targetUserId, sabotageType)
    local shield = _playerDataManager.GetEffect(targetUserId, "MIRROR_SHIELD")
    if not shield then return false end

    -- Consume the shield (one-shot)
    _playerDataManager.ClearEffect(targetUserId, "MIRROR_SHIELD")

    local targetPlayer = _playersService:GetPlayerByUserId(targetUserId)
    if targetPlayer then
        _remotes.ShieldTriggered:FireClient(targetPlayer, sabotageType, attacker.Name)
    end

    _logger.info("SabotageSystem",
        "MIRROR_SHIELD intercepted " .. sabotageType
        .. " from " .. attacker.Name
        .. " on UserId " .. tostring(targetUserId))
    return true
end

-- ── Effect implementations ────────────────────────────────────────────────────

local function applyPaintRandomizer(player, targetUserId)
    local c1, c2 = randomColor(), randomColor()
    _playerDataManager.SetEffect(targetUserId, "PAINT_RANDOMIZER", {
        r1 = c1.r, g1 = c1.g, b1 = c1.b,
        r2 = c2.r, g2 = c2.g, b2 = c2.b,
    })

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
    _playerDataManager.SetEffect(targetUserId, "TEMPORARY_STUN", {
        expiresAt = expiresAt,
    })

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

local function applyMirrorShield(player, targetUserId)
    local expiresAt = os.clock() + MIRROR_SHIELD_DURATION
    _playerDataManager.SetEffect(targetUserId, "MIRROR_SHIELD", {
        expiresAt = expiresAt,
    })
    _remotes.SabotageApplied:FireClient(player, "MIRROR_SHIELD", {
        duration = MIRROR_SHIELD_DURATION,
    })
    _logger.info("SabotageSystem",
        player.Name .. " activated MIRROR_SHIELD for " .. MIRROR_SHIELD_DURATION .. "s")
end

local function applyCleanse(player, targetUserId)
    local cleared = {}
    for _, effectName in ipairs({ "TEMPORARY_STUN", "PAINT_RANDOMIZER", "STYLE_SCRAMBLE" }) do
        if _playerDataManager.GetEffect(targetUserId, effectName) then
            _playerDataManager.ClearEffect(targetUserId, effectName)
            table.insert(cleared, effectName)
        end
    end
    _playerDataManager.SetEffect(targetUserId, "IMMUNITY_WINDOW", {
        expiresAt = os.clock() + IMMUNITY_DURATION,
    })
    _remotes.SabotageApplied:FireClient(player, "CLEANSE", {
        removedEffects = cleared,
        immunityDuration = IMMUNITY_DURATION,
    })
    _logger.info("SabotageSystem",
        player.Name .. " used CLEANSE (cleared: " .. (#cleared > 0 and table.concat(cleared, ", ") or "none")
        .. ", immunity: " .. IMMUNITY_DURATION .. "s)")
end

--- Dispatches to the correct effect implementation.
local function applyEffect(player, sabotageType, targetUserId)
    if sabotageType == "PAINT_RANDOMIZER" then
        applyPaintRandomizer(player, targetUserId)
    elseif sabotageType == "TEMPORARY_STUN" then
        applyTemporaryStun(player, targetUserId)
    elseif sabotageType == "MIRROR_SHIELD" then
        applyMirrorShield(player, targetUserId)
    elseif sabotageType == "CLEANSE" then
        applyCleanse(player, targetUserId)
    else
        -- Phase 3 stub
        _logger.info("SabotageSystem",
            player.Name .. " used [" .. sabotageType .. "] on UserId "
            .. tostring(targetUserId) .. " (stub – Phase 3)")
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

--- Disarms the system and clears all per-round tracking tables.
function SabotageSystem.Stop()
    _cooldowns = {}
    _roundUses = {}
    _isRunning = false
    _logger.info("SabotageSystem", "Stopped.")
end

--- Validates and, if valid, applies a sabotage action.
--- Returns (true, nil) on success or (false, errorMsg) on rejection.
--- Note: for DEFENSIVE types (MIRROR_SHIELD, CLEANSE), targetUserId should be
--- the initiator's own UserId; GameController enforces IsPlayerInActiveRound for both.
--- @param player        Player
--- @param sabotageType  string
--- @param targetUserId  number
--- @return boolean, string|nil
function SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId)
    if not _isRunning then
        return false, "SabotageSystem is not running."
    end

    local sabotageDef = SABOTAGE_TYPES[sabotageType]

    -- Whitelist check
    if not sabotageDef then
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

    targetUserId = tonumber(targetUserId)
    if not targetUserId then
        return false, "Invalid target userId."
    end

    -- Target must have a PlayerData record (i.e. still in the game)
    if not _playerDataManager.GetPlayerData(targetUserId) then
        _logger.warn("SabotageSystem",
            "Sabotage target UserId " .. tostring(targetUserId) .. " not found.")
        return false, "Target player not found."
    end

    -- Targeting-mode check (server-authoritative).
    -- Defensive/self-target sabotage must target the initiator only.
    -- Offensive sabotage must target a different player.
    if sabotageDef.targetMode == "self" then
        if targetUserId ~= player.UserId then
            return false, "This sabotage must target yourself."
        end
    elseif player.UserId == targetUserId then
        return false, "Cannot target yourself with this sabotage."
    end

    local usesRemaining = roundUsesRemaining(player.UserId, sabotageType, sabotageDef)
    if usesRemaining <= 0 then
        _logger.warn("SabotageSystem",
            player.Name .. " reached per-round cap for " .. sabotageType)
        return false, "No uses remaining for this sabotage this round."
    end

    -- Cooldown check
    local remaining = cooldownRemaining(player.UserId, sabotageType)
    if remaining > 0 then
        _logger.warn("SabotageSystem",
            player.Name .. " on cooldown for " .. sabotageType
            .. " (" .. string.format("%.1f", remaining) .. "s left)")
        return false, string.format("Sabotage on cooldown (%.0fs remaining).", remaining)
    end

    local effectiveTargetUserId = targetUserId

    -- Defensive intercept: active mirror shield reflects offensive sabotage.
    if sabotageDef.category == "offensive" then
        local shield = _playerDataManager.GetEffect(targetUserId, "MIRROR_SHIELD")
        if shield and shield.expiresAt and os.clock() < shield.expiresAt then
            _playerDataManager.ClearEffect(targetUserId, "MIRROR_SHIELD")
            effectiveTargetUserId = player.UserId
            _logger.info("SabotageSystem",
                "MIRROR_SHIELD intercepted " .. sabotageType
                .. " from " .. player.Name .. " and reflected it.")
        end

        local immunity = _playerDataManager.GetEffect(effectiveTargetUserId, "IMMUNITY_WINDOW")
        if immunity and immunity.expiresAt and os.clock() < immunity.expiresAt then
            return false, "Target is temporarily immune to sabotage."
        end
    elseif sabotageType == "MIRROR_SHIELD" then
        local existing = _playerDataManager.GetEffect(targetUserId, "MIRROR_SHIELD")
        if existing and existing.expiresAt and os.clock() < existing.expiresAt then
            return false, "Mirror Shield is already active."
        end
    elseif sabotageType == "CLEANSE" then
        local immunity = _playerDataManager.GetEffect(targetUserId, "IMMUNITY_WINDOW")
        if immunity and immunity.expiresAt and os.clock() < immunity.expiresAt then
            return false, "Cleanse immunity is already active."
        end
    end

    -- Redundant active-effect check: reject if the same effect is already pending
    -- on the target to prevent wasted slots and confusing UI states.
    if sabotageType == "TEMPORARY_STUN" and sabotageDef.category == "offensive" then
        local existing = _playerDataManager.GetEffect(effectiveTargetUserId, "TEMPORARY_STUN")
        if existing and os.clock() < existing.expiresAt then
            _logger.warn("SabotageSystem",
                "TEMPORARY_STUN already active on UserId "
                .. tostring(effectiveTargetUserId) .. " – rejected.")
            return false, "Target is already stunned."
        end
    elseif sabotageType == "PAINT_RANDOMIZER" and sabotageDef.category == "offensive" then
        local existing = _playerDataManager.GetEffect(effectiveTargetUserId, "PAINT_RANDOMIZER")
        if existing then
            _logger.warn("SabotageSystem",
                "PAINT_RANDOMIZER already pending on UserId "
                .. tostring(effectiveTargetUserId) .. " – rejected.")
            return false, "Target already has a pending paint effect."
        end
    end

    -- All checks passed – commit
    recordUsage(player.UserId, sabotageType)
    applyEffect(player, sabotageType, effectiveTargetUserId)
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

--- Returns sabotage metadata for a type, or nil if unknown.
--- Shape: { cooldown, maxPerRound, category, targetMode, description }
--- @param sabotageType string
--- @return table|nil
function SabotageSystem.GetSabotageTypeMeta(sabotageType)
    return SABOTAGE_TYPES[sabotageType]
end

return SabotageSystem
