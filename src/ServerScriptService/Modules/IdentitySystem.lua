--[[
    IdentitySystem
    ──────────────
    Player identity and progression layer. Aggregates data from StyleDNA,
    ReputationSystem, and DynamicsSystem into a single queryable profile;
    adds archetypes, earned titles, and career stats that those systems don't track.

    This module is a read-only leaf in the dependency graph — it never writes to
    PlayerData or to any other system's state. Its own storage is session-scoped.

    ── Archetypes ────────────────────────────────────────────────────────────────
    A single archetype label is assigned to each player by evaluating a
    priority-ordered list of conditions against their current state. The first
    matching archetype is returned; "New Face" is the guaranteed fallback.

    Archetype conditions read: dominantStyle, topStyleScore, roundsAnalyzed,
    repScore, repTier, streaks (from DynamicsSystem), careerStats.

    ── Titles ────────────────────────────────────────────────────────────────────
    Titles are milestone-based: once earned they are never lost (within a session).
    They are awarded by UpdateAfterRound() and stored in _earnedTitles[userId].
    GetActiveTitle() returns the highest-priority earned title; GetEarnedTitles()
    returns the full earned list in priority order for profile / UI display.

    ── Career stats ─────────────────────────────────────────────────────────────
    Eight lightweight session counters per player. These complement MatchHistory
    (which is capped at the last 10 rounds) with totals and all-time bests that
    would be expensive to re-derive from the ring buffer.

    CareerStats schema:
    {
        roundsPlayed      : number,   -- all rounds this session
        totalWins         : number,   -- rank-1 finishes
        totalTopFinishes  : number,   -- top-3 finishes (rank ≤ min(3, totalPlayers))
        bestFinalScore    : number,   -- highest single-round final score (0–10)
        bestVoteRound     : number,   -- highest single-round player-vote average (0–5)
        longestWinStreak  : number,   -- peak winStreak seen this session
        longestTopStreak  : number,   -- peak topStreak seen this session
        longestLossStreak : number,   -- peak lossStreak seen this session
    }

    ── IdentityProfile (returned by GetProfile) ─────────────────────────────────
    {
        userId        : number,
        archetype     : string,    -- e.g. "The Champion"
        activeTitle   : string,    -- highest-priority earned title, "" if none
        earnedTitles  : string[],  -- all earned title display strings, priority order
        careerStats   : CareerStats,
        -- live read-through — no duplication of storage:
        dominantStyle : string,    -- from PlayerData.StyleDNA
        styleLabel    : string,    -- from StyleDNA.GetStyleLabel
        repScore      : number,    -- from PlayerData.ReputationScore (0–100)
        repTier       : string,    -- from ReputationSystem.GetReputation
        streaks       : StreakProfile | nil,  -- from DynamicsSystem.GetStreakProfile
    }

    ── Dependencies (injected via Init) ─────────────────────────────────────────
        StyleDNA, ReputationSystem, DynamicsSystem, PlayerDataManager, Logger

    ── Public API ────────────────────────────────────────────────────────────────
        IdentitySystem.Init(styleDNA, reputationSystem, dynamicsSystem,
                            playerDataManager, logger)
        IdentitySystem.UpdateAfterRound(player, result, totalPlayers)
        IdentitySystem.GetProfile(player)        -> IdentityProfile | nil
        IdentitySystem.GetCareerStats(userId)    -> CareerStats | nil
        IdentitySystem.GetActiveTitle(userId)    -> string
        IdentitySystem.GetEarnedTitles(userId)   -> string[]
--]]

local IdentitySystem = {}

-- ── Archetype definitions ─────────────────────────────────────────────────────
-- Evaluated in priority order; first matching archetype is returned.
-- ctx fields: dominantStyle, topStyleScore, roundsAnalyzed, repScore, repTier,
--             streaks (StreakProfile|nil), careerStats (CareerStats)

local ARCHETYPES = {
    {
        -- Three wins AND recognised by judges/community consistently
        name  = "The Champion",
        check = function(ctx)
            return ctx.careerStats.totalWins >= 3
                and (ctx.repTier == "Elite" or ctx.repTier == "Legend")
        end,
    },
    {
        -- Audience loves them regardless of style or rank
        name  = "The Crowd's Darling",
        check = function(ctx)
            return ctx.careerStats.bestVoteRound >= 4.0
                and ctx.careerStats.roundsPlayed  >= 3
        end,
    },
    {
        -- Risk-taker with recognised reputation
        name  = "The Trendsetter",
        check = function(ctx)
            return ctx.dominantStyle == "Experimental" and ctx.repScore >= 55
        end,
    },
    {
        -- Luxury aesthetic with solid standing
        name  = "The Connoisseur",
        check = function(ctx)
            return ctx.dominantStyle == "Luxury" and ctx.repScore >= 40
        end,
    },
    {
        -- Street / experimental identity with a streak of strong placements
        name  = "The Runway Rebel",
        check = function(ctx)
            return (ctx.dominantStyle == "Experimental" or ctx.dominantStyle == "Streetwear")
                and ctx.streaks ~= nil and ctx.streaks.topStreak >= 3
        end,
    },
    {
        -- Clear single-style identity, meaningfully developed over time
        name  = "The Purist",
        check = function(ctx)
            return ctx.dominantStyle ~= "Mixed"
                and ctx.dominantStyle ~= "None"
                and ctx.topStyleScore  >= 30
                and ctx.roundsAnalyzed >= 5
        end,
    },
    {
        -- Genuinely varied aesthetic, not just undecided
        name  = "The Shapeshifter",
        check = function(ctx)
            return ctx.dominantStyle == "Mixed" and ctx.careerStats.roundsPlayed >= 4
        end,
    },
    {
        -- Currently on a losing skid (sympathetic framing, not punishment)
        name  = "The Underdog",
        check = function(ctx)
            return ctx.streaks ~= nil and ctx.streaks.lossStreak >= 2
        end,
    },
    {
        -- Volume player with a long session history
        name  = "The Grinder",
        check = function(ctx)
            return ctx.careerStats.roundsPlayed >= 8
        end,
    },
    {
        -- Early career, showing up consistently
        name  = "The Rising Star",
        check = function(ctx)
            return ctx.careerStats.roundsPlayed >= 2 and ctx.repScore >= 15
        end,
    },
    {
        -- Guaranteed fallback; matches every player
        name  = "New Face",
        check = function(_ctx) return true end,
    },
}

-- ── Title definitions ─────────────────────────────────────────────────────────
-- Titles are earned once and never revoked within a session.
-- Listed in display-priority order: GetActiveTitle returns the first earned entry.
-- Add new titles at the appropriate priority position; no other code changes needed.

local TITLE_DEFS = {
    {
        key     = "FASHION_LEGEND",
        display = "Fashion Legend",
        earn    = function(ctx) return ctx.repTier == "Legend" end,
    },
    {
        key     = "ELITE",
        display = "Elite Dresser",
        earn    = function(ctx) return ctx.repTier == "Elite" end,
    },
    {
        key     = "CHAMPION",
        display = "Champion",
        earn    = function(ctx) return ctx.careerStats.totalWins >= 3 end,
    },
    {
        key     = "STREAK_MASTER",
        display = "Streak Master",
        earn    = function(ctx) return ctx.careerStats.longestWinStreak >= 3 end,
    },
    {
        key     = "CONSISTENT",
        display = "Consistent Contender",
        earn    = function(ctx) return ctx.careerStats.longestTopStreak >= 5 end,
    },
    {
        key     = "CROWD_DARLING",
        display = "Crowd's Darling",
        earn    = function(ctx) return ctx.careerStats.bestVoteRound >= 4.0 end,
    },
    {
        key     = "FIRST_WIN",
        display = "First Win",
        earn    = function(ctx) return ctx.careerStats.totalWins >= 1 end,
    },
    {
        key     = "STYLE_EXPERT",
        display = "Style Expert",
        earn    = function(ctx) return ctx.careerStats.roundsPlayed >= 10 end,
    },
    {
        key     = "FASHION_STUDENT",
        display = "Fashion Student",
        earn    = function(ctx) return ctx.careerStats.roundsPlayed >= 5 end,
    },
    {
        key     = "FIRST_STEPS",
        display = "First Steps",
        earn    = function(ctx) return ctx.careerStats.roundsPlayed >= 1 end,
    },
}

-- ── Private state ─────────────────────────────────────────────────────────────

local _styleDNA          = nil
local _reputationSystem  = nil
local _dynamicsSystem    = nil
local _playerDataManager = nil
local _logger            = nil

-- Session-scoped; keyed by userId.
local _careerStats  = {}  -- { [userId]: CareerStats }
local _earnedTitles = {}  -- { [userId]: { [titleKey: string]: true } }

-- ── Internal helpers ──────────────────────────────────────────────────────────

local function newCareerStats()
    return {
        roundsPlayed      = 0,
        totalWins         = 0,
        totalTopFinishes  = 0,
        bestFinalScore    = 0,
        bestVoteRound     = 0,
        longestWinStreak  = 0,
        longestTopStreak  = 0,
        longestLossStreak = 0,
    }
end

local function getOrCreateStats(userId)
    if not _careerStats[userId] then
        _careerStats[userId] = newCareerStats()
    end
    return _careerStats[userId]
end

local function getOrCreateTitles(userId)
    if not _earnedTitles[userId] then
        _earnedTitles[userId] = {}
    end
    return _earnedTitles[userId]
end

--- Assembles the evaluation context used by all archetype and title check functions.
--- Returns nil when the player has no PlayerData record (handles disconnects).
--- @param player  Player
--- @return table | nil
local function buildCtx(player)
    local pData = _playerDataManager.GetPlayerData(player.UserId)
    if not pData then return nil end

    local dna        = pData.StyleDNA
    local dominant   = dna.DominantStyle or "None"
    local topScore   = (dominant ~= "None" and dominant ~= "Mixed")
                           and (dna.StyleScores[dominant] or 0) or 0
    local repProfile = _reputationSystem.GetReputation(player)

    return {
        dominantStyle  = dominant,
        topStyleScore  = topScore,
        roundsAnalyzed = dna.RoundsAnalyzed or 0,
        repScore       = pData.ReputationScore or 0,
        repTier        = repProfile and repProfile.tier or "Newcomer",
        streaks        = _dynamicsSystem.GetStreakProfile(player.UserId),
        careerStats    = getOrCreateStats(player.UserId),
    }
end

--- Resolves archetype by walking ARCHETYPES in priority order.
local function resolveArchetype(ctx)
    for _, arch in ipairs(ARCHETYPES) do
        if arch.check(ctx) then return arch.name end
    end
    return "New Face"
end

--- Awards any titles whose earn condition is now satisfied and logs new ones.
local function checkAndAwardTitles(player, ctx)
    local earned  = getOrCreateTitles(player.UserId)
    local newOnes = {}

    for _, def in ipairs(TITLE_DEFS) do
        if not earned[def.key] and def.earn(ctx) then
            earned[def.key] = true
            table.insert(newOnes, def.display)
        end
    end

    if #newOnes > 0 then
        _logger.info("IdentitySystem",
            player.Name .. " earned title(s): " .. table.concat(newOnes, ", "))
    end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Initialises the module with all dependencies.
--- @param styleDNA          table  StyleDNA module
--- @param reputationSystem  table  ReputationSystem module
--- @param dynamicsSystem    table  DynamicsSystem module
--- @param playerDataManager table  PlayerDataManager module
--- @param logger            table
function IdentitySystem.Init(styleDNA, reputationSystem, dynamicsSystem, playerDataManager, logger)
    _styleDNA          = styleDNA
    _reputationSystem  = reputationSystem
    _dynamicsSystem    = dynamicsSystem
    _playerDataManager = playerDataManager
    _logger            = logger
    _logger.info("IdentitySystem", "Initialized.")
end

--- Updates career stats and checks for newly earned titles after a round.
--- Must be called AFTER DynamicsSystem.RecordRoundResults() and
--- StyleDNA.RecalculateDominantStyle() so all source data is current.
---
--- @param player       Player
--- @param result       table   { rank, finalScore, playerVote, ... } — one entry from finalResults
--- @param totalPlayers number  total players in this round (= #finalResults)
function IdentitySystem.UpdateAfterRound(player, result, totalPlayers)
    local userId = player.UserId
    if not _playerDataManager.GetPlayerData(userId) then return end

    local stats = getOrCreateStats(userId)

    stats.roundsPlayed = stats.roundsPlayed + 1

    if result.rank == 1 then
        stats.totalWins = stats.totalWins + 1
    end

    if result.rank <= math.min(3, totalPlayers) then
        stats.totalTopFinishes = stats.totalTopFinishes + 1
    end

    local score = result.finalScore or 0
    if score > stats.bestFinalScore then
        stats.bestFinalScore = score
    end

    local vote = result.playerVote or 0
    if vote > stats.bestVoteRound then
        stats.bestVoteRound = vote
    end

    -- Snapshot all-time peak streak values from DynamicsSystem, which has already
    -- updated _streaks for this round. This gives career bests beyond the last-10
    -- ring buffer that MatchHistory provides.
    local streaks = _dynamicsSystem.GetStreakProfile(userId)
    if streaks then
        if streaks.winStreak  > stats.longestWinStreak  then stats.longestWinStreak  = streaks.winStreak  end
        if streaks.topStreak  > stats.longestTopStreak  then stats.longestTopStreak  = streaks.topStreak  end
        if streaks.lossStreak > stats.longestLossStreak then stats.longestLossStreak = streaks.lossStreak end
    end

    -- Award newly qualifying titles now that stats and streaks are current
    local ctx = buildCtx(player)
    if ctx then
        checkAndAwardTitles(player, ctx)
    end
end

--- Returns the full identity profile for a player, or nil if they have no PlayerData.
--- The profile aggregates live data from existing systems; no values are duplicated
--- in IdentitySystem's own storage.
--- @param player  Player
--- @return IdentityProfile | nil
function IdentitySystem.GetProfile(player)
    local pData = _playerDataManager.GetPlayerData(player.UserId)
    if not pData then
        _logger.warn("IdentitySystem", "GetProfile: no PlayerData for " .. player.Name)
        return nil
    end

    local ctx = buildCtx(player)
    if not ctx then return nil end

    -- Collect all earned title display strings in priority order
    local earned      = getOrCreateTitles(player.UserId)
    local earnedList  = {}
    local activeTitle = ""
    for _, def in ipairs(TITLE_DEFS) do
        if earned[def.key] then
            table.insert(earnedList, def.display)
            if activeTitle == "" then
                activeTitle = def.display  -- highest-priority earned title
            end
        end
    end

    return {
        userId        = player.UserId,
        archetype     = resolveArchetype(ctx),
        activeTitle   = activeTitle,
        earnedTitles  = earnedList,
        careerStats   = getOrCreateStats(player.UserId),
        -- live read-through: not stored here, avoids duplication
        dominantStyle = ctx.dominantStyle,
        styleLabel    = _styleDNA.GetStyleLabel(player.UserId),
        repScore      = ctx.repScore,
        repTier       = ctx.repTier,
        streaks       = ctx.streaks,
    }
end

--- Returns the raw career stats for a given player, or nil if they haven't played yet.
--- @param userId  number
--- @return CareerStats | nil
function IdentitySystem.GetCareerStats(userId)
    return _careerStats[userId]
end

--- Returns the display string of the highest-priority earned title, or "" if none.
--- @param userId  number
--- @return string
function IdentitySystem.GetActiveTitle(userId)
    local earned = _earnedTitles[userId]
    if not earned then return "" end
    for _, def in ipairs(TITLE_DEFS) do
        if earned[def.key] then return def.display end
    end
    return ""
end

--- Returns all earned title display strings in priority order.
--- @param userId  number
--- @return string[]
function IdentitySystem.GetEarnedTitles(userId)
    local earned = _earnedTitles[userId]
    if not earned then return {} end
    local list = {}
    for _, def in ipairs(TITLE_DEFS) do
        if earned[def.key] then
            table.insert(list, def.display)
        end
    end
    return list
end

return IdentitySystem
