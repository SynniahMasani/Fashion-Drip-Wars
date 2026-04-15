--[[
    VotingSystem
    ────────────
    Manages a single voting session per round: open → record → tally → close.
    Enforces all rules server-side: eligibility, one-vote-per-player, no
    self-voting. Clients only send a request; the server decides validity.

    Dependencies (injected via Init):
        PlayerDataManager, Logger

    Public API:
        VotingSystem.Init(playerDataManager, logger)
        VotingSystem.Start()
        VotingSystem.Stop()
        VotingSystem.OpenVoting(voters, targets)
        VotingSystem.SubmitVote(voter, targetUserId)  -> (bool, string|nil)
        VotingSystem.TallyVotes()                     -> VoteResult[]
        VotingSystem.CloseVoting()
        VotingSystem.IsVotingOpen()                   -> boolean

    VoteResult:
    {
        userId    : number,
        voteCount : number,
    }
--]]

local VotingSystem = {}

-- ── Private state ────────────────────────────────────────────────────────────

local _playerDataManager = nil
local _logger            = nil
local _isRunning         = false

-- Per-session state – fully reset by resetSession()
local _votingOpen      = false
local _eligibleVoters  = {} -- { [userId: number]: true }
local _eligibleTargets = {} -- { [userId: number]: true }
local _votes           = {} -- { [voterUserId: number]: targetUserId: number }

-- ── Internal helpers ─────────────────────────────────────────────────────────

local function resetSession()
    _votingOpen      = false
    _eligibleVoters  = {}
    _eligibleTargets = {}
    _votes           = {}
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module. Must be called before Start().
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

--- Disarms the system, clears any open session, resets all state.
function VotingSystem.Stop()
    resetSession()
    _isRunning = false
    _logger.info("VotingSystem", "Stopped.")
end

--- Opens a new voting session.
--- @param voters   Player[]  Players permitted to cast votes
--- @param targets  Player[]  Players that can receive votes
function VotingSystem.OpenVoting(voters, targets)
    if _votingOpen then
        _logger.warn("VotingSystem", "OpenVoting called while session already open – ignoring.")
        return
    end

    resetSession()

    for _, player in ipairs(voters) do
        _eligibleVoters[player.UserId] = true
    end
    for _, player in ipairs(targets) do
        _eligibleTargets[player.UserId] = true
    end

    _votingOpen = true
    _logger.info("VotingSystem", "Voting opened. Eligible voters: " .. #voters
        .. ", eligible targets: " .. #targets)
end

--- Records a vote from a client. All validation happens here (server-authoritative).
--- Returns (true, nil) on success, or (false, errorMsg) on any rejection.
--- @param voter        Player
--- @param targetUserId number
--- @return boolean, string|nil
function VotingSystem.SubmitVote(voter, targetUserId)
    if not _isRunning then
        return false, "VotingSystem is not running."
    end
    if not _votingOpen then
        return false, "Voting is not currently open."
    end

    local voterId = voter.UserId

    if not _eligibleVoters[voterId] then
        _logger.warn("VotingSystem", voter.Name .. " is not eligible to vote.")
        return false, "Not eligible to vote."
    end
    if not _eligibleTargets[targetUserId] then
        _logger.warn("VotingSystem", "Invalid vote target UserId: " .. tostring(targetUserId))
        return false, "Invalid vote target."
    end
    if voterId == targetUserId then
        return false, "Cannot vote for yourself."
    end
    if _votes[voterId] then
        _logger.warn("VotingSystem", voter.Name .. " attempted to vote more than once.")
        return false, "You have already voted."
    end

    _votes[voterId] = targetUserId
    _logger.info("VotingSystem", voter.Name .. " voted for UserId " .. tostring(targetUserId))
    return true, nil
end

--- Tallies all recorded votes and returns results sorted by vote count (descending).
--- Safe to call before CloseVoting (e.g. for live leaderboards).
--- @return { userId: number, voteCount: number }[]
function VotingSystem.TallyVotes()
    local tally = {} -- [targetUserId] -> count
    for _, targetUserId in pairs(_votes) do
        tally[targetUserId] = (tally[targetUserId] or 0) + 1
    end

    local results = {}
    for userId, count in pairs(tally) do
        table.insert(results, { userId = userId, voteCount = count })
    end
    table.sort(results, function(a, b)
        return a.voteCount > b.voteCount
    end)

    _logger.info("VotingSystem", "Votes tallied. "
        .. #results .. " player(s) received at least one vote.")
    return results
end

--- Closes the current voting session (votes are preserved for TallyVotes).
function VotingSystem.CloseVoting()
    if not _votingOpen then
        _logger.warn("VotingSystem", "CloseVoting called but no session was open.")
        return
    end
    _votingOpen = false
    _logger.info("VotingSystem", "Voting closed.")
end

--- Returns whether a voting session is currently accepting votes.
--- @return boolean
function VotingSystem.IsVotingOpen()
    return _votingOpen
end

return VotingSystem
