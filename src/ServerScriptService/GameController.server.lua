--[[
    GameController  (Server Script – single entry point)
    ─────────────────────────────────────────────────────
    Boots the game server by:
        1. Loading all modules in dependency order
        2. Calling Init() on each (dependency injection)
        3. Wiring player join/leave events
        4. Wiring RemoteEvent handlers (server-authoritative validation)
        5. Starting the RoundManager

    Dependency graph (no cycles):
        Logger
          └─ PlayerDataManager(Logger)
               ├─ OutfitSystem(PlayerDataManager, Logger)
               ├─ VotingSystem(PlayerDataManager, Logger)
               └─ SabotageSystem(PlayerDataManager, Logger)
                    └─ RoundManager(Outfit, Voting, Sabotage, Logger)
--]]

-- ── Services ─────────────────────────────────────────────────────────────────

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- ── Module references ─────────────────────────────────────────────────────────

local Modules = ServerScriptService:WaitForChild("Modules")

local Logger             = require(Modules:WaitForChild("Logger"))
local PlayerDataManager  = require(Modules:WaitForChild("PlayerDataManager"))
local OutfitSystem       = require(Modules:WaitForChild("OutfitSystem"))
local VotingSystem       = require(Modules:WaitForChild("VotingSystem"))
local SabotageSystem     = require(Modules:WaitForChild("SabotageSystem"))
local RoundManager       = require(Modules:WaitForChild("RoundManager"))

-- ── Initialisation (dependency-first order) ───────────────────────────────────

Logger.info("GameController", "========================================")
Logger.info("GameController", "   Fashion Drip Wars – Server Boot")
Logger.info("GameController", "========================================")

PlayerDataManager.Init(Logger)
OutfitSystem.Init(PlayerDataManager, Logger)
VotingSystem.Init(PlayerDataManager, Logger)
SabotageSystem.Init(PlayerDataManager, Logger)
RoundManager.Init(OutfitSystem, VotingSystem, SabotageSystem, Logger)

Logger.info("GameController", "All systems initialized.")

-- ── RemoteEvent wiring ────────────────────────────────────────────────────────

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

--[[
    StartRound
    Client → Server: player requests a round to start.
    Phase 0: any player can trigger (admin gating added in Phase 1).
--]]
Remotes.StartRound.OnServerEvent:Connect(function(player)
    Logger.info("GameController", player.Name .. " requested StartRound.")
    -- TODO Phase 1: gate on admin role / game-state prerequisites
    RoundManager.StartRound(Players:GetPlayers())
end)

--[[
    SubmitOutfit
    Client → Server: player submits their outfit for the current round.
    Accepted only during the DRESSING phase; all validation server-side.
--]]
Remotes.SubmitOutfit.OnServerEvent:Connect(function(player, outfitData)
    if RoundManager.GetCurrentState() ~= RoundManager.State.DRESSING then
        Logger.warn("GameController", player.Name
            .. " submitted outfit outside DRESSING phase – rejected.")
        return
    end

    local success, err = OutfitSystem.ValidateAndSetOutfit(player, outfitData)
    if not success then
        Logger.warn("GameController", "Outfit rejected for " .. player.Name
            .. ": " .. tostring(err))
        -- TODO Phase 1: fire a RemoteFunction / error event back to client
    end
end)

--[[
    SubmitVote
    Client → Server: player votes for a target during VOTING phase.
    VotingSystem enforces eligibility, one-vote limit, and no self-voting.
--]]
Remotes.SubmitVote.OnServerEvent:Connect(function(voter, targetUserId)
    if RoundManager.GetCurrentState() ~= RoundManager.State.VOTING then
        Logger.warn("GameController", voter.Name
            .. " submitted vote outside VOTING phase – rejected.")
        return
    end

    local success, err = VotingSystem.SubmitVote(voter, targetUserId)
    if not success then
        Logger.warn("GameController", "Vote rejected for " .. voter.Name
            .. ": " .. tostring(err))
        -- TODO Phase 1: fire error event back to client
    end
end)

--[[
    UseSabotage
    Client → Server: player requests a sabotage action during DRESSING phase.
    SabotageSystem validates type, cooldown, and target existence.
--]]
Remotes.UseSabotage.OnServerEvent:Connect(function(player, sabotageType, targetUserId)
    if RoundManager.GetCurrentState() ~= RoundManager.State.DRESSING then
        Logger.warn("GameController", player.Name
            .. " attempted sabotage outside DRESSING phase – rejected.")
        return
    end

    local success, err = SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId)
    if not success then
        Logger.warn("GameController", "Sabotage rejected for " .. player.Name
            .. ": " .. tostring(err))
        -- TODO Phase 1: fire error event back to client
    end
end)

-- ── Player lifecycle ──────────────────────────────────────────────────────────

Players.PlayerAdded:Connect(function(player)
    Logger.info("GameController",
        "Player joined: " .. player.Name .. " (UserId: " .. player.UserId .. ")")
    PlayerDataManager.CreatePlayerData(player)
end)

Players.PlayerRemoving:Connect(function(player)
    Logger.info("GameController",
        "Player left: " .. player.Name .. " (UserId: " .. player.UserId .. ")")
    PlayerDataManager.RemovePlayerData(player.UserId)
end)

-- Catch any players who joined before this script finished loading
for _, player in ipairs(Players:GetPlayers()) do
    PlayerDataManager.CreatePlayerData(player)
end

-- ── Start ─────────────────────────────────────────────────────────────────────

RoundManager.Start()
Logger.info("GameController", "Fashion Drip Wars is online and ready.")
