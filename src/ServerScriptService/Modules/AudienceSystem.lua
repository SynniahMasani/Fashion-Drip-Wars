--[[
    AudienceSystem
    ──────────────
    Tracks the crowd's emotional state during the runway phase and produces a
    score multiplier that reflects how engaged the audience was by the time
    results are calculated.

    ── State ─────────────────────────────────────────────────────────────────────
    HypeLevel    (0–100): how excited the audience is right now.
                 Starts at BASE_HYPE (50 – neutral crowd).
                 Strong outfits push it up; weak outfits push it down.

    InterestLevel (0–100): how attentive the audience is.
                 Starts at BASE_INTEREST (65 – slightly engaged).
                 Strong outfits re-engage; weak outfits accelerate boredom.
                 Acts as a MULTIPLIER on how much HypeLevel moves each turn
                 — an attentive crowd reacts more strongly in both directions.

    ── Per-turn update (UpdateAudience) ─────────────────────────────────────────
    outfitScore (0–10) is bucketed into three tiers:

        Strong   (>= SCORE_STRONG  = 7.0)  →  HypeLevel += DELTA_STRONG × interest
        Average  (>= SCORE_AVERAGE = 4.0)  →  HypeLevel += DELTA_AVERAGE × interest
        Weak     (<  SCORE_AVERAGE      )  →  HypeLevel += DELTA_WEAK   × interest

    Interest modulates hype change:  interestMod = InterestLevel / 100
    Both Hype and Interest are clamped to [0, 100] after every update.

    ── HypeMultiplier ────────────────────────────────────────────────────────────
    Applied to the final combined score in RoundManager:

        HypeLevel ≥ 85  →  × 1.10  (crowd is ELECTRIC)
        HypeLevel ≥ 65  →  × 1.05  (crowd is energized)
        HypeLevel ≥ 40  →  × 1.00  (crowd is neutral)
        HypeLevel ≥ 20  →  × 0.97  (crowd is distracted)
        HypeLevel ≥  0  →  × 0.93  (crowd is bored / hostile)

    The maximum swing in final score from this system is ±10 % — a deliberate
    cap so audience state influences but never dominates the outcome.

    ── Animation hook stubs ──────────────────────────────────────────────────────
    Phase 2 visual system should call RegisterReactionHook(tier, callback).
    Callbacks receive (player, hypeLevel, interestLevel) and can drive
    animations, sound effects, chat cheer messages, etc.

    Dependencies (injected via Init):
        Logger

    Public API:
        AudienceSystem.Init(logger)
        AudienceSystem.StartRunway()
        AudienceSystem.UpdateAudience(player, outfitScore)
        AudienceSystem.GetHypeMultiplier()                 -> number
        AudienceSystem.GetAudienceState()                  -> AudienceState
        AudienceSystem.RegisterReactionHook(tier, fn)      -- Phase 2 only
--]]

local AudienceSystem = {}

-- ── Constants ────────────────────────────────────────────────────────────────

-- Starting levels
local BASE_HYPE     = 50   -- neutral crowd
local BASE_INTEREST = 65   -- slightly engaged

-- Outfit score thresholds (0-10 scale, matching AI judge output)
local SCORE_STRONG  = 7.0
local SCORE_AVERAGE = 4.0

-- Hype deltas (before interest modulation)
local DELTA_STRONG  =  12   -- crowd gets excited
local DELTA_AVERAGE =   2   -- mild positive reaction
local DELTA_WEAK    = -10   -- crowd disappointed

-- Interest changes per turn
local INTEREST_GAIN_STRONG = 5    -- strong outfits re-engage the crowd
local INTEREST_DECAY_BASE  = 2    -- natural attention drain every turn
local INTEREST_LOSS_WEAK   = 5    -- weak outfits accelerate boredom

-- Interest floor — the crowd never completely zones out
local MIN_INTEREST  = 20
local MIN_MULTIPLIER = 0.93
local MAX_MULTIPLIER = 1.10

-- HypeMultiplier tier table (ordered highest first)
local HYPE_TIERS = {
    { threshold = 85, multiplier = 1.10, label = "ELECTRIC"   },
    { threshold = 65, multiplier = 1.05, label = "Energized"  },
    { threshold = 40, multiplier = 1.00, label = "Neutral"    },
    { threshold = 20, multiplier = 0.97, label = "Distracted" },
    { threshold =  0, multiplier = 0.93, label = "Bored"      },
}

-- ── Private state ────────────────────────────────────────────────────────────

local _logger        = nil
local _hypeLevel     = BASE_HYPE
local _interestLevel = BASE_INTEREST

-- Phase 2 animation hooks: { ["Strong"|"Average"|"Weak"]: fn[] }
local _reactionHooks = { Strong = {}, Average = {}, Weak = {} }

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

--- Resolves the HypeTier entry for a given hype level.
local function resolveTier(hype)
    for _, tier in ipairs(HYPE_TIERS) do
        if hype >= tier.threshold then
            return tier
        end
    end
    return HYPE_TIERS[#HYPE_TIERS]  -- fallback: lowest tier
end

--- Fires all registered hooks for a given tier name.
--- Called after every UpdateAudience.  No-op until Phase 2 hooks are registered.
--- @param tierName  string  "Strong" | "Average" | "Weak"
--- @param player    Player
local function fireHooks(tierName, player)
    local hooks = _reactionHooks[tierName]
    if not hooks then return end
    for _, fn in ipairs(hooks) do
        -- pcall so a broken hook never interrupts the runway
        local ok, err = pcall(fn, player, _hypeLevel, _interestLevel)
        if not ok then
            _logger.warn("AudienceSystem",
                "Reaction hook error (" .. tierName .. "): " .. tostring(err))
        end
    end
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param logger  table
function AudienceSystem.Init(logger)
    _logger = logger
    _logger.info("AudienceSystem", "Initialized.")
end

--- Resets HypeLevel and InterestLevel to their starting values for a new round.
--- Call at the beginning of phaseRunway.
function AudienceSystem.StartRunway()
    _hypeLevel     = BASE_HYPE
    _interestLevel = BASE_INTEREST
    _logger.info("AudienceSystem", string.format(
        "Runway started – Hype: %d  Interest: %d", _hypeLevel, _interestLevel))
end

--- Updates audience state based on one player's runway performance.
--- outfitScore is on the 0–10 scale used by JudgeSystem and the outfit
--- evaluator in RoundManager.
--- @param player      Player
--- @param outfitScore number  0–10
function AudienceSystem.UpdateAudience(player, outfitScore)
    outfitScore = clamp(tonumber(outfitScore) or 0, 0, 10)
    local interestMod  = _interestLevel / 100  -- scale [0, 1]

    local hypeDelta
    local interestDelta
    local tierName

    if outfitScore >= SCORE_STRONG then
        hypeDelta     = DELTA_STRONG * interestMod
        interestDelta = INTEREST_GAIN_STRONG - INTEREST_DECAY_BASE   -- net +3
        tierName      = "Strong"
    elseif outfitScore >= SCORE_AVERAGE then
        hypeDelta     = DELTA_AVERAGE * interestMod
        interestDelta = -INTEREST_DECAY_BASE                          -- net -2
        tierName      = "Average"
    else
        hypeDelta     = DELTA_WEAK * interestMod
        interestDelta = -(INTEREST_LOSS_WEAK + INTEREST_DECAY_BASE)   -- net -7
        tierName      = "Weak"
    end

    local prevHype     = _hypeLevel
    _hypeLevel         = clamp(math.floor(_hypeLevel     + hypeDelta     + 0.5), 0, 100)
    _interestLevel     = clamp(math.floor(_interestLevel + interestDelta + 0.5), MIN_INTEREST, 100)

    local tier = resolveTier(_hypeLevel)
    _logger.info("AudienceSystem", string.format(
        "%-20s  score: %.1f [%s]  Hype: %d → %d  Interest: %d  [%s]",
        player.Name, outfitScore, tierName,
        prevHype, _hypeLevel, _interestLevel, tier.label))

    -- ── Phase 2 animation hook stub ───────────────────────────────────────────
    -- Registered visual/audio systems receive (player, hypeLevel, interestLevel)
    -- so they can trigger cheers, animations, camera cuts, etc.
    fireHooks(tierName, player)
end

--- Returns the hype multiplier to apply to the final round score.
--- Call after the runway phase ends (all players have walked).
--- @return number  value in [0.93, 1.10]
function AudienceSystem.GetHypeMultiplier()
    local tier = resolveTier(_hypeLevel)
    local multiplier = clamp(tier.multiplier, MIN_MULTIPLIER, MAX_MULTIPLIER)
    _logger.info("AudienceSystem", string.format(
        "GetHypeMultiplier → %.2f  (Hype: %d [%s]  Interest: %d)",
        multiplier, _hypeLevel, tier.label, _interestLevel))
    return multiplier
end

--- Returns a snapshot of the current audience state for logging or broadcasting.
--- AudienceState: { hypeLevel, interestLevel, multiplier, label }
--- @return table
function AudienceSystem.GetAudienceState()
    local tier = resolveTier(_hypeLevel)
    local multiplier = clamp(tier.multiplier, MIN_MULTIPLIER, MAX_MULTIPLIER)
    return {
        hypeLevel     = _hypeLevel,
        interestLevel = _interestLevel,
        multiplier    = multiplier,
        label         = tier.label,
    }
end

--- Registers a callback that fires each time a player walks the runway.
--- Callbacks receive (player: Player, hypeLevel: number, interestLevel: number).
--- tierName: "Strong" | "Average" | "Weak"
--- No-op until Phase 2; safe to call now for pre-wiring.
--- @param tierName  string
--- @param fn        function
function AudienceSystem.RegisterReactionHook(tierName, fn)
    if not _reactionHooks[tierName] then
        _logger.warn("AudienceSystem",
            "RegisterReactionHook: unknown tier '" .. tostring(tierName) .. "'")
        return
    end
    table.insert(_reactionHooks[tierName], fn)
    _logger.info("AudienceSystem",
        "Reaction hook registered for tier: " .. tierName)
end

return AudienceSystem
