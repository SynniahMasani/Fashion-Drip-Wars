--[[
    GameController  (Server Script – single entry point)
    ─────────────────────────────────────────────────────
    Boots the server by initialising all systems in dependency order,
    wiring RemoteEvent handlers, and starting the RoundManager.

    Dependency graph (no cycles):
        Logger
          └─ PlayerDataManager(Logger)
               ├─ ThemeSystem(Logger)
               ├─ AIJudge(Logger)
               ├─ StyleDNA(PlayerDataManager, Logger)
               ├─ OutfitSystem(PlayerDataManager, StyleDNA, Logger)
               ├─ VotingSystem(PlayerDataManager, Logger)
               ├─ SabotageSystem(PlayerDataManager, Logger, Remotes, Players)
               ├─ RunwaySystem(Logger, Remotes)
               └─ RoundManager({all above + StyleDNA, Remotes})

    Server-authoritative rules enforced here:
        • SubmitOutfit  – phase check + stun check before forwarding
        • SubmitVote    – phase check before forwarding
        • UseSabotage   – phase check before forwarding
        • StartRound    – only valid from IDLE (RoundManager guards internally)
--]]

-- ── Roblox Services ───────────────────────────────────────────────────────────

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- ── Module loader ─────────────────────────────────────────────────────────────

local Modules = ServerScriptService:WaitForChild("Modules")

local function loadModule(name)
    return require(Modules:WaitForChild(name))
end

-- ── Load all modules ──────────────────────────────────────────────────────────

local Logger            = loadModule("Logger")
local PlayerDataManager = loadModule("PlayerDataManager")
local ThemeSystem       = loadModule("ThemeSystem")
local AIJudge           = loadModule("AIJudge")
local StyleDNA          = loadModule("StyleDNA")
local OutfitSystem      = loadModule("OutfitSystem")
local VotingSystem      = loadModule("VotingSystem")
local SabotageSystem    = loadModule("SabotageSystem")
local RunwaySystem      = loadModule("RunwaySystem")
local MaterialSystem    = loadModule("MaterialSystem")
local ReputationSystem  = loadModule("ReputationSystem")
local RoundManager      = loadModule("RoundManager")

-- ── Remotes ───────────────────────────────────────────────────────────────────

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- ── Initialise systems (dependency-first order) ───────────────────────────────

Logger.info("GameController", "========================================")
Logger.info("GameController", "   Fashion Drip Wars – Server Boot")
Logger.info("GameController", "========================================")

PlayerDataManager.Init(Logger)
ThemeSystem.Init(Logger)
MaterialSystem.Init(PlayerDataManager, Logger)
AIJudge.Init(MaterialSystem, Logger)
ReputationSystem.Init(PlayerDataManager, Logger)
StyleDNA.Init(PlayerDataManager, Logger)
OutfitSystem.Init(PlayerDataManager, StyleDNA, MaterialSystem, Logger)
VotingSystem.Init(PlayerDataManager, Logger)
SabotageSystem.Init(PlayerDataManager, Logger, Remotes, Players)
RunwaySystem.Init(Logger, Remotes)

RoundManager.Init({
    outfitSystem      = OutfitSystem,
    votingSystem      = VotingSystem,
    sabotageSystem    = SabotageSystem,
    themeSystem       = ThemeSystem,
    runwaySystem      = RunwaySystem,
    aiJudge           = AIJudge,
    styleDNA          = StyleDNA,
    reputationSystem  = ReputationSystem,
    playerDataManager = PlayerDataManager,
    logger            = Logger,
    remotes           = Remotes,
})

Logger.info("GameController", "All systems initialized.")

-- ── Remote: StartRound ────────────────────────────────────────────────────────
-- Client fires this to request a round start (admin gating added in Phase 2).

Remotes.StartRound.OnServerEvent:Connect(function(player)
    Logger.info("GameController", player.Name .. " requested StartRound.")
    -- TODO Phase 2: verify player is admin or game-mode allows player-initiated rounds
    RoundManager.StartRound(Players:GetPlayers())
end)

-- ── Remote: SubmitOutfit ──────────────────────────────────────────────────────
-- Client fires with { HeadId, TopId, BottomId, ShoesId, AccessoryIds,
--                     ColorPrimary, ColorSecondary, StyleTags }.

Remotes.SubmitOutfit.OnServerEvent:Connect(function(player, outfitData)
    -- Phase gate
    if RoundManager.GetCurrentState() ~= RoundManager.State.DRESSING then
        Logger.warn("GameController",
            player.Name .. " submitted outfit outside DRESSING phase – rejected.")
        return
    end

    -- Stun check: read from PlayerData.ActiveEffects (written by SabotageSystem)
    local stunEffect = PlayerDataManager.GetEffect(player.UserId, "TEMPORARY_STUN")
    if stunEffect then
        if os.clock() < stunEffect.expiresAt then
            Logger.warn("GameController",
                player.Name .. " is stunned – outfit submission blocked.")
            return
        else
            -- Stun expired naturally; clean it up
            PlayerDataManager.ClearEffect(player.UserId, "TEMPORARY_STUN")
        end
    end

    local ok, err = OutfitSystem.ValidateAndSetOutfit(player, outfitData)
    if not ok then
        Logger.warn("GameController",
            "Outfit rejected for " .. player.Name .. ": " .. tostring(err))
        -- TODO Phase 2: fire an error RemoteEvent back to the client
    end
end)

-- ── Remote: SubmitVote ────────────────────────────────────────────────────────
-- Client fires with (targetUserId: number, starRating: number 1-5).

Remotes.SubmitVote.OnServerEvent:Connect(function(voter, targetUserId, starRating)
    -- Phase gate
    if RoundManager.GetCurrentState() ~= RoundManager.State.VOTING then
        Logger.warn("GameController",
            voter.Name .. " submitted vote outside VOTING phase – rejected.")
        return
    end

    local ok, err = VotingSystem.SubmitVote(voter, targetUserId, starRating)
    if not ok then
        Logger.warn("GameController",
            "Vote rejected for " .. voter.Name .. ": " .. tostring(err))
        -- TODO Phase 2: fire error event back to client
    end
end)

-- ── Remote: UseSabotage ───────────────────────────────────────────────────────
-- Client fires with (sabotageType: string, targetUserId: number).
-- Only allowed during DRESSING phase.

Remotes.UseSabotage.OnServerEvent:Connect(function(player, sabotageType, targetUserId)
    -- Phase gate
    if RoundManager.GetCurrentState() ~= RoundManager.State.DRESSING then
        Logger.warn("GameController",
            player.Name .. " attempted sabotage outside DRESSING phase – rejected.")
        return
    end

    local ok, err = SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId)
    if not ok then
        Logger.warn("GameController",
            "Sabotage rejected for " .. player.Name .. ": " .. tostring(err))
        -- TODO Phase 2: fire error event back to client
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

-- Catch players who joined before this script finished loading
for _, player in ipairs(Players:GetPlayers()) do
    PlayerDataManager.CreatePlayerData(player)
end

-- ── Start ─────────────────────────────────────────────────────────────────────

RoundManager.Start()
Logger.info("GameController", "Fashion Drip Wars is online and ready.")
