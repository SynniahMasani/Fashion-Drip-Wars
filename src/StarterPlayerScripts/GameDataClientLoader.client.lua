--[[
    GameDataClientLoader  (LocalScript – StarterPlayerScripts)
    ────────────────────────────────────────────────────────────
    Bootstraps the GameDataClient module so its cache and signals are live
    for any other LocalScript or UI script that requires it later.

    Usage from any other client script:
        local GameDataClient = require(
            game:GetService("Players").LocalPlayer.PlayerScripts.Modules.GameDataClient)
        -- All getters and signals are ready immediately (Init already called).
        -- Connect to signals:
        GameDataClient.ProfileChanged.Event:Connect(function() ... end)
        -- Or read synchronously:
        local profile = GameDataClient.GetProfile()  -- may be nil on first frame
--]]

local PlayerScripts  = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts")
local GameDataClient = require(PlayerScripts:WaitForChild("Modules"):WaitForChild("GameDataClient"))

GameDataClient.Init()
