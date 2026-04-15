--[[
    ReputationSystem
    ────────────────
    Tracks player performance quality over time and exposes a normalised
    0-100 reputation score suitable for future matchmaking and vote weighting.

    ── Score architecture ────────────────────────────────────────────────────────
    Each round a player participates in produces a RoundScore (0-100):

        RoundScore = placement × 0.45 + trimmedVote × 0.35 + aiScore × 0.20

    where:
        placement   = (1 - (rank-1)/(totalPlayers-1)) × 100   [0=last, 100=first]
        trimmedVote = trimmedAverage(rawVotes) / 5 × 100       [0-5 stars → 0-100]
        aiScore     = aiScore / 10 × 100                       [0-10 AI → 0-100]

    ReputationScore is the consistency-adjusted exponential moving average of
    the last MAX_HISTORY RoundScores, with more recent rounds weighted higher.

    ── Anti-abuse ───────────────────────────────────────────────────────────────
    1. Trimmed mean: votes beyond 1.5 × σ of the vote set are dropped before
       averaging.  Falls back to raw mean when fewer than 3 votes are available.

    2. Extreme-vote penalty: if all received votes are 1s ("pile-on attack"),
       or all are 5s ("boosting ring"), or all are exclusively 1/5 with no
       middle values, a pattern flag is set and the vote contribution to
       RoundScore is reduced (50% / 70% / 75% of face value respectively).

    3. Consistency modifier: players whose last five RoundScores have high
       standard deviation receive a small multiplier reduction (max -10%).
       Consistent performers are implicitly rewarded.

    ── Persistence compatibility ─────────────────────────────────────────────────
    PlayerData.MatchHistory is an array of MatchSummary tables.  Every field
    is a plain Lua primitive (number / boolean / string) — safe for DataStore.

    ── MatchSummary schema ───────────────────────────────────────────────────────
    {
        roundNumber   : number,
        rank          : number,
        totalPlayers  : number,
        finalScore    : number,   -- weighted 0-10 from RoundManager
        playerVote    : number,   -- raw average votes received (0-5)
        trimmedVote   : number,   -- abuse-trimmed average (0-5)
        aiScore       : number,   -- AI judge score (0-10)
        roundScore    : number,   -- 0-100 score computed this round
        abuseDetected : boolean,
        timestamp     : number,   -- os.time()
    }

    Dependencies (injected via Init):
        PlayerDataManager, Logger

    Public API:
        ReputationSystem.Init(playerDataManager, logger)
        ReputationSystem.UpdateReputation(player, roundResult)
        ReputationSystem.GetReputation(player) -> ReputationProfile

    roundResult input (assembled by RoundManager):
    {
        userId       : number,
        rank         : number,
        totalPlayers : number,
        finalScore   : number,   -- 0-10
        playerVote   : number,   -- 0-5 (raw average already computed by VotingSystem)
        aiScore      : number,   -- 0-10
        rawVotes     : number[], -- individual star ratings this player received
        roundNumber  : number,
    }

    ReputationProfile:
    {
        score        : number,   -- 0-100, one decimal place
        tier         : string,   -- "Newcomer" … "Legend"
        matchHistory : MatchSummary[],
    }
--]]

local ReputationSystem = {}

-- ── Constants ────────────────────────────────────────────────────────────────

local MAX_HISTORY      = 10    -- rounds of history retained
local HISTORY_DECAY    = 0.85  -- older match weight multiplier (per round back)

-- Round-score component weights (must sum to 1.0)
local W_PLACEMENT = 0.45
local W_VOTE      = 0.35
local W_AI        = 0.20

-- Reputation tiers (ordered highest first)
local TIERS = {
    { minScore = 85, name = "Legend"   },
    { minScore = 70, name = "Elite"    },
    { minScore = 55, name = "Rising"   },
    { minScore = 40, name = "Solid"    },
    { minScore = 20, name = "Emerging" },
    { minScore =  0, name = "Newcomer" },
}

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil

-- ── Math helpers ─────────────────────────────────────────────────────────────

local function round1dp(n)
    return math.floor(n * 10 + 0.5) / 10
end

local function clamp(n, lo, hi)
    return math.max(lo, math.min(hi, n))
end

--- Arithmetic mean of a numeric array.  Returns 0 for empty arrays.
local function mean(t)
    if #t == 0 then return 0 end
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s / #t
end

--- Population standard deviation of a numeric array.  Returns 0 for ≤1 items.
local function stdDev(t)
    if #t <= 1 then return 0 end
    local m = mean(t)
    local variance = 0
    for _, v in ipairs(t) do variance = variance + (v - m)^2 end
    return math.sqrt(variance / #t)
end

-- ── Anti-abuse: vote trimming ─────────────────────────────────────────────────

--- Detects suspicious all-extreme voting patterns in a raw vote array.
--- Returns (abuseDetected: boolean, voteMultiplier: number).
--- The multiplier reduces how much the vote component counts toward RoundScore.
local function detectAbuse(votes)
    if #votes < 2 then return false, 1.0 end

    local allOne  = true
    local allFive = true
    local allEdge = true   -- only 1s and 5s, no middle values

    for _, v in ipairs(votes) do
        if v ~= 1 then allOne  = false end
        if v ~= 5 then allFive = false end
        if v ~= 1 and v ~= 5 then allEdge = false end
    end

    if allOne then
        -- All 1-star: possible pile-on / targeted harassment
        return true, 0.50
    elseif allFive then
        -- All 5-star: possible boosting / friend ring
        return true, 0.70
    elseif allEdge then
        -- Only 1s and 5s: polarised / suspicious
        return true, 0.75
    end

    return false, 1.0
end

--- Returns the trimmed mean of a vote array.
--- Votes more than 1.5 × σ from the mean are excluded.
--- Falls back to the raw mean when fewer than 3 votes exist or when trimming
--- would remove more than half the sample.
--- @param votes  number[]
--- @return number  trimmedMean (same scale as inputs)
local function trimmedMean(votes)
    if #votes == 0 then return 0 end
    if #votes <= 2  then return mean(votes) end   -- not enough data to trim

    local m   = mean(votes)
    local sd  = stdDev(votes)
    local threshold = math.max(1.5 * sd, 0.5)    -- never trim within 0.5 of mean

    local kept = {}
    for _, v in ipairs(votes) do
        if math.abs(v - m) <= threshold then
            table.insert(kept, v)
        end
    end

    -- Require at least 50% of original votes to remain
    if #kept < math.ceil(#votes * 0.5) then
        return m    -- fall back to raw mean
    end

    return mean(kept)
end

-- ── Reputation calculation ────────────────────────────────────────────────────

--- Computes a 0-100 RoundScore for a single round result.
--- @param rank          number
--- @param totalPlayers  number
--- @param tVote         number  trimmed-average star rating (0-5)
--- @param voteMultiplier number  abuse penalty multiplier (0-1)
--- @param aiScore       number  AI judge score (0-10)
--- @return number  RoundScore 0-100
local function computeRoundScore(rank, totalPlayers, tVote, voteMultiplier, aiScore)
    -- Placement: 1.0 when rank=1, 0.0 when rank=last
    local placement = totalPlayers > 1
        and (1 - (rank - 1) / (totalPlayers - 1))
        or  1.0

    -- Normalise each component to [0, 1]
    local placeNorm = placement
    local voteNorm  = (tVote / 5) * voteMultiplier
    local aiNorm    = aiScore / 10

    local raw = (placeNorm * W_PLACEMENT + voteNorm * W_VOTE + aiNorm * W_AI) * 100
    return clamp(round1dp(raw), 0, 100)
end

--- Returns a [0, 1] consistency multiplier based on the standard deviation of
--- the last 5 round scores.  Low variance → multiplier close to 1.0.
--- Max penalty is -10% (multiplier floor = 0.90).
--- @param history  MatchSummary[]
--- @return number
local function consistencyMultiplier(history)
    local n = math.min(#history, 5)
    if n < 2 then return 1.0 end

    local recent = {}
    for i = #history - n + 1, #history do
        table.insert(recent, history[i].roundScore)
    end

    local sd            = stdDev(recent)
    local normalizedSd  = clamp(sd / 50, 0, 1)   -- 50-pt spread = fully inconsistent
    return 1.0 - normalizedSd * 0.10              -- [0.90, 1.00]
end

--- Computes the final 0-100 ReputationScore from the full match history.
--- More recent matches are weighted more heavily via HISTORY_DECAY.
--- @param history  MatchSummary[]
--- @return number  normalised score 0-100
local function recalcReputation(history)
    if #history == 0 then return 0 end

    local weightedSum = 0
    local weightTotal = 0
    local n           = #history

    for i = n, 1, -1 do
        local age    = n - i                        -- 0 = most recent
        local weight = HISTORY_DECAY ^ age
        weightedSum  = weightedSum + history[i].roundScore * weight
        weightTotal  = weightTotal + weight
    end

    local base         = weightedSum / weightTotal
    local consistency  = consistencyMultiplier(history)

    return clamp(round1dp(base * consistency), 0, 100)
end

--- Returns the tier name for a given reputation score.
local function resolveTier(score)
    for _, tier in ipairs(TIERS) do
        if score >= tier.minScore then
            return tier.name
        end
    end
    return "Newcomer"
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param playerDataManager  table
--- @param logger             table
function ReputationSystem.Init(playerDataManager, logger)
    _playerDataManager = playerDataManager
    _logger            = logger
    _logger.info("ReputationSystem", "Initialized.")
end

--- Processes a round result for one player:
---   1. Trims and abuse-checks their received votes.
---   2. Computes a RoundScore.
---   3. Appends a MatchSummary to MatchHistory (capped at MAX_HISTORY).
---   4. Recalculates ReputationScore from the updated history.
---   5. Writes the result back to PlayerData.
---
--- @param player       Player
--- @param roundResult  table  (see module header for schema)
function ReputationSystem.UpdateReputation(player, roundResult)
    local data = _playerDataManager.GetPlayerData(player.UserId)
    if not data then
        _logger.warn("ReputationSystem",
            "UpdateReputation: no PlayerData for " .. player.Name)
        return
    end

    -- ── Step 1: abuse detection + trimmed vote ────────────────────────────────
    local rawVotes = roundResult.rawVotes or {}
    local abuseDetected, voteMultiplier = detectAbuse(rawVotes)
    local tVote = trimmedMean(rawVotes)             -- 0-5

    if abuseDetected then
        _logger.warn("ReputationSystem",
            "Suspicious vote pattern for " .. player.Name
            .. " – multiplier reduced to " .. string.format("%.0f%%", voteMultiplier * 100))
    end

    -- ── Step 2: compute round score ───────────────────────────────────────────
    local roundScore = computeRoundScore(
        roundResult.rank,
        roundResult.totalPlayers,
        tVote,
        voteMultiplier,
        roundResult.aiScore
    )

    -- ── Step 3: build MatchSummary and append to history ─────────────────────
    local summary = {
        roundNumber   = roundResult.roundNumber,
        rank          = roundResult.rank,
        totalPlayers  = roundResult.totalPlayers,
        finalScore    = roundResult.finalScore,
        playerVote    = roundResult.playerVote,
        trimmedVote   = round1dp(tVote),
        aiScore       = roundResult.aiScore,
        roundScore    = roundScore,
        abuseDetected = abuseDetected,
        timestamp     = os.time(),
    }

    local history = data.MatchHistory
    table.insert(history, summary)

    -- Keep only the most recent MAX_HISTORY entries
    while #history > MAX_HISTORY do
        table.remove(history, 1)
    end

    -- ── Step 4: recalculate reputation ────────────────────────────────────────
    local newScore = recalcReputation(history)
    data.ReputationScore = newScore

    -- ── Step 5: log ───────────────────────────────────────────────────────────
    _logger.info("ReputationSystem", string.format(
        "%-20s  #%d/%d  RoundScore: %.1f  Rep: %.1f → %.1f  [%s]%s",
        player.Name,
        roundResult.rank,
        roundResult.totalPlayers,
        roundScore,
        -- previous score is already overwritten; log new value twice with arrow
        newScore, newScore,
        resolveTier(newScore),
        abuseDetected and "  ⚠ abuse" or ""))
end

--- Returns the reputation profile for a player.
--- Returns nil if no PlayerData record exists.
--- @param player  Player
--- @return ReputationProfile | nil
function ReputationSystem.GetReputation(player)
    local data = _playerDataManager.GetPlayerData(player.UserId)
    if not data then
        _logger.warn("ReputationSystem",
            "GetReputation: no PlayerData for " .. player.Name)
        return nil
    end

    local score = data.ReputationScore
    return {
        score        = score,
        tier         = resolveTier(score),
        matchHistory = data.MatchHistory,
    }
end

return ReputationSystem
