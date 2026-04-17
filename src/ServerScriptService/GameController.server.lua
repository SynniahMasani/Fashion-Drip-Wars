--[[
    GameController  (Server Script – single entry point)
    ─────────────────────────────────────────────────────
    Boots the server by initialising all systems in dependency order,
    wiring RemoteEvent handlers, and starting the RoundManager.

    Dependency graph (no cycles):
        Logger
          └─ PlayerDataManager(Logger)
               ├─ ThemeSystem(Logger)
               ├─ MetaSystem(Logger)
               ├─ AudienceSystem(Logger)
               ├─ PerformanceSystem(Logger, Remotes)
               ├─ DynamicsSystem(Logger)
               ├─ MaterialSystem(PlayerDataManager, Logger)
               ├─ ReputationSystem(PlayerDataManager, Logger)
               ├─ StyleDNA(PlayerDataManager, Logger)
               │    └─ JudgeSystem(StyleDNA, MaterialSystem, ThemeSystem, MetaSystem, Logger)
               ├─ OutfitSystem(PlayerDataManager, StyleDNA, MaterialSystem, Logger)
               ├─ VotingSystem(PlayerDataManager, Logger)
               ├─ SabotageSystem(PlayerDataManager, Logger, Remotes, Players)
               ├─ RunwaySystem(Logger, Remotes)
               └─ RoundManager({all above, Remotes})

    Server-authoritative rules enforced here:
        • SubmitOutfit  – phase check + stun check before forwarding
        • SubmitVote    – phase check before forwarding
        • UseSabotage   – phase check before forwarding
        • TriggerAction – phase check (RUNWAY only) before forwarding
        • StartRound    – admin-only gate (see ADMIN_USER_IDS below); IDLE guard is
                          also enforced by RoundManager internally
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
local MetaSystem        = loadModule("MetaSystem")
local AudienceSystem    = loadModule("AudienceSystem")
local PerformanceSystem = loadModule("PerformanceSystem")
local DynamicsSystem    = loadModule("DynamicsSystem")
local JudgeSystem       = loadModule("JudgeSystem")
local StyleDNA          = loadModule("StyleDNA")
local OutfitSystem      = loadModule("OutfitSystem")
local VotingSystem      = loadModule("VotingSystem")
local SabotageSystem    = loadModule("SabotageSystem")
local RunwaySystem      = loadModule("RunwaySystem")
local MaterialSystem    = loadModule("MaterialSystem")
local ReputationSystem  = loadModule("ReputationSystem")
local RoundManager      = loadModule("RoundManager")

-- ── Admin authorization ───────────────────────────────────────────────────────
-- Only UserIds listed here may fire StartRound from a client.
-- An empty set means no client can trigger a round start remotely; use the
-- server-side TestScenario or an auto-start loop instead.
-- Populate with real admin UserId numbers before shipping.
local ADMIN_USER_IDS = {}  -- e.g. { [12345678] = true, [87654321] = true }

-- ── Remotes ───────────────────────────────────────────────────────────────────

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- ── Initialise systems (dependency-first order) ───────────────────────────────

Logger.info("GameController", "========================================")
Logger.info("GameController", "   Fashion Drip Wars – Server Boot")
Logger.info("GameController", "========================================")

PlayerDataManager.Init(Logger)
ThemeSystem.Init(Logger)
MetaSystem.Init(Logger)
AudienceSystem.Init(Logger)
PerformanceSystem.Init(Logger, Remotes)
DynamicsSystem.Init(Logger)
MaterialSystem.Init(PlayerDataManager, Logger)
ReputationSystem.Init(PlayerDataManager, Logger)
StyleDNA.Init(PlayerDataManager, Logger)
JudgeSystem.Init(StyleDNA, MaterialSystem, ThemeSystem, MetaSystem, Logger)
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
    judgeSystem       = JudgeSystem,
    metaSystem        = MetaSystem,
    audienceSystem    = AudienceSystem,
    performanceSystem = PerformanceSystem,
    dynamicsSystem    = DynamicsSystem,
    styleDNA          = StyleDNA,
    reputationSystem  = ReputationSystem,
    playerDataManager = PlayerDataManager,
    logger            = Logger,
    remotes           = Remotes,
})

Logger.info("GameController", "All systems initialized.")

-- ── Remote: StartRound ────────────────────────────────────────────────────────
-- Restricted to admin UserId(s) in ADMIN_USER_IDS.  Any other client firing
-- this event is silently rejected to avoid leaking information about the check.

Remotes.StartRound.OnServerEvent:Connect(function(player)
    if not ADMIN_USER_IDS[player.UserId] then
        Logger.warn("GameController",
            player.Name .. " attempted StartRound without authorization – rejected.")
        return
    end
    Logger.info("GameController", player.Name .. " [ADMIN] requested StartRound.")
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

    -- Both initiator and target must be active round participants.
    -- Checked here rather than inside SabotageSystem to keep the circular-dep
    -- boundary clean (SabotageSystem is a dep of RoundManager, not vice-versa).
    if not RoundManager.IsPlayerInActiveRound(player.UserId) then
        Logger.warn("GameController",
            player.Name .. " is not an active round participant – sabotage rejected.")
        return
    end
    if not RoundManager.IsPlayerInActiveRound(targetUserId) then
        Logger.warn("GameController",
            "Sabotage target UserId " .. tostring(targetUserId)
            .. " is not an active round participant – rejected.")
        return
    end

    local ok, err = SabotageSystem.ValidateSabotage(player, sabotageType, targetUserId)
    if not ok then
        Logger.warn("GameController",
            "Sabotage rejected for " .. player.Name .. ": " .. tostring(err))
        -- TODO Phase 2: fire error event back to client
    end
end)

-- ── Remote: TriggerAction ─────────────────────────────────────────────────────
-- Client fires with no arguments when the player wants to act during a runway
-- performance window.  Server evaluates timing authoritatively; the client's
-- clock is never trusted.  Only accepted during the RUNWAY phase.

Remotes.TriggerAction.OnServerEvent:Connect(function(player)
    if RoundManager.GetCurrentState() ~= RoundManager.State.RUNWAY then
        Logger.warn("GameController",
            player.Name .. " fired TriggerAction outside RUNWAY phase – rejected.")
        return
    end
    PerformanceSystem.RegisterAction(player)
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
    -- Remove from the live round participant set before wiping PlayerData so
    -- any concurrent sabotage/vote handlers see the player as gone immediately.
    RoundManager.HandlePlayerLeft(player.UserId)
    PlayerDataManager.RemovePlayerData(player.UserId)
end)

-- Catch players who joined before this script finished loading
for _, player in ipairs(Players:GetPlayers()) do
    PlayerDataManager.CreatePlayerData(player)
end

-- ── Start ─────────────────────────────────────────────────────────────────────

RoundManager.Start()
Logger.info("GameController", "Fashion Drip Wars is online and ready.")
