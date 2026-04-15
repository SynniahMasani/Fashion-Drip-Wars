--[[
    VotingSystem
    ────────────
    Manages a single voting session per round: open → record → tally → close.

    Vote model: each eligible voter gives a 1–5 star rating to exactly ONE
    target player. All rules are enforced server-side:
        • Voting must be open
        • Voter must be in the eligible list
        • Target must be in the eligible list
        • No self-voting
        • One vote per player per round (first submission wins)
        • Star rating must be an integer in [1, 5]

    Tally: returns per-target vote count and average star rating.

    Dependencies (injected via Init):
        PlayerDataManager, Logger

    VoteResult structure:
    {
        userId    : number,
        voteCount : number,
        totalStars: number,
        average   : number,   -- rounded to 1 decimal place
    }

    Public API:
        VotingSystem.Init(playerDataManager, logger)
        VotingSystem.Start()
        VotingSystem.Stop()
        VotingSystem.OpenVoting(voters, targets)
        VotingSystem.SubmitVote(voter, targetUserId, starRating) -> (bool, string|nil)
        VotingSystem.TallyVotes()      -> VoteResult[]
        VotingSystem.GetAllRawVotes()  -> { [targetUserId]: number[] }
        VotingSystem.CloseVoting()
        VotingSystem.IsVotingOpen()    -> boolean
--]]

local VotingSystem = {}

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil
local _isRunning         = false

-- Per-session (reset each round via resetSession)
local _votingOpen      = false
local _eligibleVoters  = {} -- { [userId]: true }
local _eligibleTargets = {} -- { [userId]: true }

-- _votes[voterUserId] = { targetUserId: number, stars: number }
local _votes = {}

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function resetSession()
    _votingOpen      = false
    _eligibleVoters  = {}
    _eligibleTargets = {}
    _votes           = {}
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module.
--- @param playerDataManager  table
--- @param logger             table
function VotingSystem.Init(playerDataManager, logger)
    _playerDataManager = playerDataManager
    _logger            = logger
    _logger.info("VotingSystem", "Initialized.")
end

--- Arms the system so SubmitVote calls are accepted.
function VotingSystem.Start()
    _isRunning = true
    _logger.info("VotingSystem", "Started.")
end

--- Disarms the system and clears all session state.
function VotingSystem.Stop()
    resetSession()
    _isRunning = false
    _logger.info("VotingSystem", "Stopped.")
end

--- Opens a voting session for specified voter/target lists.
--- @param voters   Player[]  Eligible voters
--- @param targets  Player[]  Players that can be voted for
function VotingSystem.OpenVoting(voters, targets)
    if _votingOpen then
        _logger.warn("VotingSystem", "OpenVoting called while session already open – ignoring.")
        return
    end

    resetSession()

    for _, player in ipairs(voters)  do _eligibleVoters[player.UserId]  = true end
    for _, player in ipairs(targets) do _eligibleTargets[player.UserId] = true end

    _votingOpen = true
    _logger.info("VotingSystem",
        "Voting opened. Voters: " .. #voters .. ", Targets: " .. #targets)
end

--- Records a 1–5 star vote from a client (server-authoritative).
--- Returns (true, nil) on success or (false, errorMsg) on any rejection.
--- @param voter        Player
--- @param targetUserId number
--- @param starRating   number  Must be an integer in [1, 5]
--- @return boolean, string|nil
function VotingSystem.SubmitVote(voter, targetUserId, starRating)
    if not _isRunning then
        return false, "VotingSystem is not running."
    end
    if not _votingOpen then
        return false, "Voting is not currently open."
    end

    -- Validate star rating
    starRating = tonumber(starRating)
    if not starRating then
        return false, "Star rating must be a number."
    end
    starRating = math.floor(starRating + 0.5)  -- round to nearest integer
    if starRating < 1 or starRating > 5 then
        return false, "Star rating must be between 1 and 5."
    end

    local voterId = voter.UserId

    if not _eligibleVoters[voterId] then
        _logger.warn("VotingSystem", voter.Name .. " is not eligible to vote.")
        return false, "Not eligible to vote."
    end
    if not _eligibleTargets[targetUserId] then
        _logger.warn("VotingSystem",
            "Invalid vote target UserId: " .. tostring(targetUserId))
        return false, "Invalid vote target."
    end
    if voterId == targetUserId then
        return false, "Cannot vote for yourself."
    end
    if _votes[voterId] then
        _logger.warn("VotingSystem", voter.Name .. " attempted to vote more than once.")
        return false, "You have already voted this round."
    end

    _votes[voterId] = { targetUserId = targetUserId, stars = starRating }
    _logger.info("VotingSystem",
        voter.Name .. " gave " .. starRating .. " star(s) to UserId "
        .. tostring(targetUserId))
    return true, nil
end

--- Tallies votes and returns results sorted by average star rating (descending).
--- Safe to call before CloseVoting for live leaderboards.
--- @return VoteResult[]
function VotingSystem.TallyVotes()
    -- Accumulate per-target totals
    local tally = {} -- [targetUserId] -> { total, count }
    for _, vote in pairs(_votes) do
        local t = vote.targetUserId
        if not tally[t] then tally[t] = { total = 0, count = 0 } end
        tally[t].total = tally[t].total + vote.stars
        tally[t].count = tally[t].count + 1
    end

    -- Build result list
    local results = {}
    for userId, data in pairs(tally) do
        local avg = data.total / data.count
        avg = math.floor(avg * 10 + 0.5) / 10  -- round to 1 decimal
        table.insert(results, {
            userId     = userId,
            voteCount  = data.count,
            totalStars = data.total,
            average    = avg,
        })
    end

    table.sort(results, function(a, b) return a.average > b.average end)

    _logger.info("VotingSystem",
        "Votes tallied. " .. #results .. " player(s) received votes.")
    return results
end

--- Returns a map of every target's individual star ratings for this session.
--- Call this after CloseVoting() and before Stop() (Stop() clears _votes).
--- Used by ReputationSystem to perform trimmed-mean and anti-abuse analysis.
--- @return { [targetUserId: number]: number[] }
function VotingSystem.GetAllRawVotes()
    local result = {}
    for _, vote in pairs(_votes) do
        local tid = vote.targetUserId
        if not result[tid] then result[tid] = {} end
        table.insert(result[tid], vote.stars)
    end
    return result
end

--- Closes the current voting session (tallied data is preserved until Stop()).
function VotingSystem.CloseVoting()
    if not _votingOpen then
        _logger.warn("VotingSystem", "CloseVoting called but no session was open.")
        return
    end
    _votingOpen = false
    _logger.info("VotingSystem", "Voting closed.")
end

--- Returns true if voting is currently accepting submissions.
--- @return boolean
function VotingSystem.IsVotingOpen()
    return _votingOpen
end

return VotingSystem
