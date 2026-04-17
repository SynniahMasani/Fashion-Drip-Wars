--[[
    SabotageSystem
    ──────────────
    Validates and applies sabotage actions sent by clients.

    ── Sabotage types ────────────────────────────────────────────────────────────
    ┌─────────────────────┬──────────────────────────────────────────────────────┐
    │ OFFENSIVE                                                                  │
    ├─────────────────────┬──────────────────────────────────────────────────────┤
    │ PAINT_RANDOMIZER    │ Overwrites target colours on their next submission.  │
    │ TEMPORARY_STUN      │ Blocks outfit submission for STUN_DURATION seconds.  │
    │ STYLE_SCRAMBLE      │ Replaces target's StyleTags with 1-2 random valid   │
    │                     │ StyleDNA tags on their next submission.              │
    │ OUTFIT_CURSE        │ Silently removes one random filled slot on the       │
    │                     │ target's next submission.                            │
    ├─────────────────────┬──────────────────────────────────────────────────────┤
    │ DEFENSIVE (self-target only)                                               │
    ├─────────────────────┬──────────────────────────────────────────────────────┤
    │ MIRROR_SHIELD       │ Next incoming offensive sabotage is intercepted.     │
    │                     │ Attacker's cooldown is consumed; their per-round     │
    │                     │ charge is refunded (intercept ≠ full block).        │
    │ CLEANSE             │ Removes all active offensive effects immediately.    │
    └─────────────────────┴──────────────────────────────────────────────────────┘

    Effects fire SabotageApplied to the TARGET's client for UI feedback.
    MIRROR_SHIELD fires ShieldTriggered to the shielded player's client.

    ── Frustration controls ─────────────────────────────────────────────────────
    • Per-type cooldown: enforced per initiator per sabotage type.
    • maxPerRound cap: each type can only be used once per round per player.
    • MAX_CONCURRENT_EFFECTS: a target cannot have more than this many active
      offensive effects at once (stacking limit).
    • IMMUNITY_WINDOW: after a successful offensive sabotage, the same type
      cannot be applied to the same target again for this many seconds.

    ── Dependencies (injected via Init) ─────────────────────────────────────────
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
    PAINT_RANDOMIZER = { cooldown = 45,  targetMode = "opponent", description = "Randomises the target's outfit colours." },
    TEMPORARY_STUN   = { cooldown = 60,  targetMode = "opponent", description = "Blocks outfit submission for 10 seconds." },
    STYLE_SCRAMBLE   = { cooldown = 60,  targetMode = "opponent", description = "Scrambles outfit style tags. (Phase 2)" },
    MATERIAL_STEAL   = { cooldown = 90,  targetMode = "opponent", description = "Steals a material from inventory. (Phase 2)" },
    MIRROR_SHIELD    = { cooldown = 45,  targetMode = "self",     description = "Blocks/reflects incoming sabotage. (Phase 2)" },
    CLEANSE          = { cooldown = 45,  targetMode = "self",     description = "Clears active negative effects. (Phase 2)" },
}

-- Canonical list of offensive effect keys used for stacking limits and CLEANSE.
local OFFENSIVE_EFFECT_KEYS = {
    "PAINT_RANDOMIZER",
    "TEMPORARY_STUN",
    "STYLE_SCRAMBLE",
    "OUTFIT_CURSE",
}

local STUN_DURATION          = 10   -- seconds a TEMPORARY_STUN blocks submissions
local MAX_CONCURRENT_EFFECTS = 2    -- max simultaneous offensive effects on one target
local IMMUNITY_WINDOW        = 45   -- seconds before the same type can be re-applied to the same target

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil
local _remotes           = nil
local _playersService    = nil
local _isRunning         = false

-- { [userId]: { [sabotageType]: lastUsedClock } }
local _cooldowns = {}

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

local function roundUsesRemaining(userId, sabotageType)
    local typeInfo = SABOTAGE_TYPES[sabotageType]
    local uses = (_roundUses[userId] or {})[sabotageType] or 0
    return math.max(0, typeInfo.maxPerRound - uses)
end

local function recordCooldown(userId, sabotageType)
    if not _cooldowns[userId] then _cooldowns[userId] = {} end
    _cooldowns[userId][sabotageType] = os.clock()
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

local function applyStyleScramble(player, targetUserId)
    -- Store a sentinel; OutfitSystem resolves the actual tag replacement on submission.
    _playerDataManager.SetEffect(targetUserId, "STYLE_SCRAMBLE", { pending = true })

    local targetPlayer = _playersService:GetPlayerByUserId(targetUserId)
    if targetPlayer then
        _remotes.SabotageApplied:FireClient(targetPlayer, "STYLE_SCRAMBLE", {})
    end

    _logger.info("SabotageSystem",
        player.Name .. " used STYLE_SCRAMBLE on UserId " .. tostring(targetUserId))
end

local function applyOutfitCurse(player, targetUserId)
    -- Store a sentinel; OutfitSystem removes a random slot on submission.
    _playerDataManager.SetEffect(targetUserId, "OUTFIT_CURSE", { pending = true })

    local targetPlayer = _playersService:GetPlayerByUserId(targetUserId)
    if targetPlayer then
        _remotes.SabotageApplied:FireClient(targetPlayer, "OUTFIT_CURSE", {})
    end

    _logger.info("SabotageSystem",
        player.Name .. " used OUTFIT_CURSE on UserId " .. tostring(targetUserId))
end

local function applyMirrorShield(player)
    _playerDataManager.SetEffect(player.UserId, "MIRROR_SHIELD", { active = true })
    _logger.info("SabotageSystem",
        player.Name .. " activated MIRROR_SHIELD.")
end

local function applyCleanse(player)
    for _, effectKey in ipairs(OFFENSIVE_EFFECT_KEYS) do
        _playerDataManager.ClearEffect(player.UserId, effectKey)
    end
    _logger.info("SabotageSystem",
        player.Name .. " used CLEANSE – all offensive effects removed.")
end

--- Dispatches to the correct effect implementation.
local function applyEffect(player, sabotageType, targetUserId)
    if sabotageType == "PAINT_RANDOMIZER" then
        applyPaintRandomizer(player, targetUserId)
    elseif sabotageType == "TEMPORARY_STUN" then
        applyTemporaryStun(player, targetUserId)
    elseif sabotageType == "STYLE_SCRAMBLE" then
        applyStyleScramble(player, targetUserId)
    elseif sabotageType == "OUTFIT_CURSE" then
        applyOutfitCurse(player, targetUserId)
    elseif sabotageType == "MIRROR_SHIELD" then
        applyMirrorShield(player)
    elseif sabotageType == "CLEANSE" then
        applyCleanse(player)
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
    _cooldowns      = {}
    _roundUses      = {}
    _targetImmunity = {}
    _isRunning      = false
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

    -- Target must have a PlayerData record (still in the game)
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
    if typeInfo.selfTarget and player.UserId ~= targetUserId then
        return false, "This ability can only target yourself."
    end

    -- Cooldown check
    local remaining = cooldownRemaining(player.UserId, sabotageType)
    if remaining > 0 then
        _logger.warn("SabotageSystem",
            player.Name .. " on cooldown for " .. sabotageType
            .. " (" .. string.format("%.1f", remaining) .. "s left)")
        return false, string.format("Sabotage on cooldown (%.0fs remaining).", remaining)
    end

    -- Per-round use cap
    if roundUsesRemaining(player.UserId, sabotageType) <= 0 then
        _logger.warn("SabotageSystem",
            player.Name .. " has exhausted " .. sabotageType .. " uses for this round.")
        return false, "You have already used this ability this round."
    end

    -- ── Offensive-only checks ────────────────────────────────────────────────
    if typeInfo.category == "OFFENSIVE" then

        -- MIRROR_SHIELD intercept: attacker's cooldown IS consumed but not round charge
        if checkMirrorShield(player, targetUserId, sabotageType) then
            recordCooldown(player.UserId, sabotageType)
            -- round charge NOT consumed — attacker can retry after cooldown expires
            return true, nil
        end

        -- Immunity window: same type cannot hit the same target twice quickly
        if isImmune(targetUserId, sabotageType) then
            _logger.warn("SabotageSystem",
                "UserId " .. tostring(targetUserId)
                .. " is immune to " .. sabotageType .. " (immunity window active).")
            return false, "Target is currently immune to that ability."
        end

        -- Stacking limit: cap concurrent offensive effects on a single target
        if countActiveOffensiveEffects(targetUserId) >= MAX_CONCURRENT_EFFECTS then
            _logger.warn("SabotageSystem",
                "UserId " .. tostring(targetUserId)
                .. " already has " .. MAX_CONCURRENT_EFFECTS .. " active effects – stacking rejected.")
            return false, "Target already has too many active effects."
        end
    end

    -- All checks passed – commit
    recordCooldown(player.UserId, sabotageType)
    recordRoundUse(player.UserId, sabotageType)
    if typeInfo.category == "OFFENSIVE" then
        recordImmunity(targetUserId, sabotageType)
    end
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

--- Returns sabotage metadata for a type, or nil if unknown.
--- Shape: { cooldown: number, targetMode: "self"|"opponent", description: string }
--- @param sabotageType string
--- @return table|nil
function SabotageSystem.GetSabotageTypeMeta(sabotageType)
    return SABOTAGE_TYPES[sabotageType]
end

return SabotageSystem
