--[[
    TestScenario  (Server Script – debug only)
    ──────────────────────────────────────────
    Simulates a complete round end-to-end without a real client.
    Set DEBUG_MODE = true to activate; leave false in production.

    What it does:
        1.  Waits for at least MIN_PLAYERS to join.
        2.  Fires StartRound via the server-side API directly (bypasses Remote).
        3.  After DRESSING opens, submits a mock outfit for each player.
        4.  After RUNWAY, submits mock votes for each player.
        5.  Logs the final results table.

    This script deliberately uses internal module APIs (not RemoteEvents) so
    it can simulate a full round without needing a game client running.

    DO NOT ship this script in production – delete or disable it before launch.
--]]

local DEBUG_MODE = true  -- ← toggle here
if not DEBUG_MODE then return end

-- ── Services & modules ────────────────────────────────────────────────────────

local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

local Modules = ServerScriptService:WaitForChild("Modules")
local function loadModule(name) return require(Modules:WaitForChild(name)) end

local Logger            = loadModule("Logger")
local PlayerDataManager = loadModule("PlayerDataManager")
local OutfitSystem      = loadModule("OutfitSystem")
local VotingSystem      = loadModule("VotingSystem")
local SabotageSystem    = loadModule("SabotageSystem")
local RoundManager      = loadModule("RoundManager")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- ── Config ────────────────────────────────────────────────────────────────────

local MIN_PLAYERS  = 1    -- minimum players before auto-starting
local POLL_INTERVAL = 2   -- seconds between player-count checks

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Builds a mock outfit table that looks like a real client submission.
local function mockOutfit(playerName)
    return {
        HeadId         = 10000 + math.random(1, 999),
        TopId          = 20000 + math.random(1, 999),
        BottomId       = 30000 + math.random(1, 999),
        ShoesId        = 40000 + math.random(1, 999),
        AccessoryIds   = { 50000 + math.random(1, 99) },
        ColorPrimary   = { r = math.random(), g = math.random(), b = math.random() },
        ColorSecondary = { r = math.random(), g = math.random(), b = math.random() },
        StyleTags      = { "Casual", "Bold" },
        _submittedBy   = playerName,  -- for logging only; server strips unknown keys
    }
end

--- Waits until the RoundManager enters the target state, polling every interval.
local function waitForState(targetState, timeoutSeconds)
    local elapsed = 0
    local interval = 0.5
    while RoundManager.GetCurrentState() ~= targetState do
        task.wait(interval)
        elapsed = elapsed + interval
        if elapsed >= timeoutSeconds then
            Logger.warn("TestScenario",
                "Timeout waiting for state: " .. targetState)
            return false
        end
    end
    return true
end

-- ── Main test routine ─────────────────────────────────────────────────────────

task.spawn(function()
    Logger.info("TestScenario", "=== TEST MODE ACTIVE ===")
    Logger.info("TestScenario",
        "Waiting for at least " .. MIN_PLAYERS .. " player(s)...")

    -- Wait for minimum player count
    while #Players:GetPlayers() < MIN_PLAYERS do
        task.wait(POLL_INTERVAL)
    end

    local players = Players:GetPlayers()
    Logger.info("TestScenario",
        "Starting test round with " .. #players .. " player(s).")

    -- ── Step 1: Start round ──────────────────────────────────────────────────
    RoundManager.StartRound(players)

    -- ── Step 2: Submit mock outfits during DRESSING ──────────────────────────
    Logger.info("TestScenario", "Waiting for DRESSING phase...")
    if not waitForState("DRESSING", 30) then return end

    task.wait(1)  -- small delay to mimic player think time

    for _, player in ipairs(players) do
        local outfit = mockOutfit(player.Name)
        local ok, err = OutfitSystem.ValidateAndSetOutfit(player, outfit)
        if ok then
            Logger.info("TestScenario", player.Name .. " outfit submitted.")
        else
            Logger.warn("TestScenario", player.Name .. " outfit rejected: " .. tostring(err))
        end
    end

    -- ── Step 3: (Optional) Trigger a sabotage between players ────────────────
    if #players >= 2 then
        local initiator = players[1]
        local target    = players[2]
        local ok, err = SabotageSystem.ValidateSabotage(
            initiator, "PAINT_RANDOMIZER", target.UserId)
        if ok then
            Logger.info("TestScenario",
                initiator.Name .. " paint-randomized " .. target.Name)
            -- Re-submit target's outfit so the randomizer is consumed
            local outfit2 = mockOutfit(target.Name)
            OutfitSystem.ValidateAndSetOutfit(target, outfit2)
        else
            Logger.warn("TestScenario", "Sabotage failed: " .. tostring(err))
        end
    end

    -- ── Step 4: Submit mock votes during VOTING ──────────────────────────────
    Logger.info("TestScenario", "Waiting for VOTING phase...")
    if not waitForState("VOTING", 220) then return end  -- allow full dressing + runway

    task.wait(1)

    -- Each player votes for the next player in the list (wrap-around)
    for i, voter in ipairs(players) do
        local targetIdx   = (i % #players) + 1
        local targetPlayer = players[targetIdx]
        local stars = math.random(3, 5)
        local ok, err = VotingSystem.SubmitVote(voter, targetPlayer.UserId, stars)
        if ok then
            Logger.info("TestScenario",
                voter.Name .. " gave " .. stars .. " stars to " .. targetPlayer.Name)
        else
            Logger.warn("TestScenario",
                "Vote rejected (" .. voter.Name .. "): " .. tostring(err))
        end
    end

    -- ── Step 5: Wait for RESULTS and log the summary ─────────────────────────
    Logger.info("TestScenario", "Waiting for RESULTS phase...")
    if not waitForState("RESULTS", 60) then return end

    Logger.info("TestScenario", "=== TEST SCENARIO COMPLETE ===")
    Logger.info("TestScenario", "Round #" .. RoundManager.GetRoundNumber() .. " finished.")

    -- Print reputation leaderboard from PlayerData
    local allData = PlayerDataManager.GetAllData()
    local board = {}
    for _, player in ipairs(players) do
        local data = allData[player.UserId]
        if data then
            table.insert(board, { name = player.Name, rep = data.ReputationScore })
        end
    end
    table.sort(board, function(a, b) return a.rep > b.rep end)
    Logger.info("TestScenario", "── Reputation Leaderboard ──")
    for i, entry in ipairs(board) do
        Logger.info("TestScenario",
            string.format("  %d. %-20s  Rep: %d", i, entry.name, entry.rep))
    end
    Logger.info("TestScenario", "─────────────────────────────")
end)

--[[
    ── EXPECTED CONSOLE OUTPUT (2 players: Alice, Bob) ─────────────────────────

    [FashionDripWars] [INFO] [TestScenario] === TEST MODE ACTIVE ===
    [FashionDripWars] [INFO] [TestScenario] Starting test round with 2 player(s).
    [FashionDripWars] [INFO] [RoundManager] === Round #1 START ===  Players: 2
    [FashionDripWars] [INFO] [RoundManager] Phase: IDLE → LOBBY
    [FashionDripWars] [INFO] [RoundManager] Phase: LOBBY → THEME_SELECTION
    [FashionDripWars] [INFO] [ThemeSystem]  Theme selected: "Cyberpunk Neon"
    [FashionDripWars] [INFO] [RoundManager] Phase: THEME_SELECTION → DRESSING
    [FashionDripWars] [INFO] [TestScenario] Alice outfit submitted.
    [FashionDripWars] [INFO] [TestScenario] Bob outfit submitted.
    [FashionDripWars] [INFO] [TestScenario] Alice paint-randomized Bob
    [FashionDripWars] [INFO] [OutfitSystem] PAINT_RANDOMIZER consumed for Bob – colours overridden.
    [FashionDripWars] [INFO] [RoundManager] Phase: DRESSING → RUNWAY
    [FashionDripWars] [INFO] [RunwaySystem] Runway turn: Bob (1/2)
    [FashionDripWars] [INFO] [RunwaySystem] Runway turn: Alice (2/2)
    [FashionDripWars] [INFO] [RunwaySystem] Runway complete.
    [FashionDripWars] [INFO] [RoundManager] Phase: RUNWAY → VOTING
    [FashionDripWars] [INFO] [TestScenario] Alice gave 4 stars to Bob
    [FashionDripWars] [INFO] [TestScenario] Bob gave 5 stars to Alice
    [FashionDripWars] [INFO] [RoundManager] Phase: VOTING → RESULTS
    [FashionDripWars] [INFO] [RoundManager]   #1 Alice   Final: 8.1  (AI: 7.3 | Vote: 5.0 | Rep +10)
    [FashionDripWars] [INFO] [RoundManager]   #2 Bob     Final: 7.4  (AI: 6.8 | Vote: 4.0 | Rep +6)
    [FashionDripWars] [INFO] [RoundManager] Round #1 results broadcast.
    [FashionDripWars] [INFO] [TestScenario] === TEST SCENARIO COMPLETE ===
    [FashionDripWars] [INFO] [TestScenario] ── Reputation Leaderboard ──
    [FashionDripWars] [INFO] [TestScenario]   1. Alice               Rep: 10
    [FashionDripWars] [INFO] [TestScenario]   2. Bob                 Rep: 6
    ────────────────────────────────────────────────────────────────────────────
    Note: AI scores, vote stars, and theme are random – exact values will vary.
--]]
