--[[
    Logger
    ──────
    Shared logging utility. No dependencies.
    All other modules receive this via dependency injection from GameController.

    Usage:
        Logger.info("MySystem", "Something happened")
        Logger.warn("MySystem", "Something looks wrong")
        Logger.error("MySystem", "Something failed")
--]]

local Logger = {}

local LOG_PREFIX = "[FashionDripWars]"

-- ── Public API ──────────────────────────────────────────────────────────────

--- Logs an informational message.
--- @param system   string  Name of the calling system (e.g. "RoundManager")
--- @param message  string  Message to log
function Logger.info(system, message)
    print(string.format("%s [INFO] [%s] %s", LOG_PREFIX, tostring(system), tostring(message)))
end

--- Logs a warning. Does not halt execution.
--- @param system   string
--- @param message  string
function Logger.warn(system, message)
    warn(string.format("%s [WARN] [%s] %s", LOG_PREFIX, tostring(system), tostring(message)))
end

--- Logs an error. Does not halt execution (use warn internally so the game
--- keeps running; callers decide whether to abort).
--- @param system   string
--- @param message  string
function Logger.error(system, message)
    warn(string.format("%s [ERROR] [%s] %s", LOG_PREFIX, tostring(system), tostring(message)))
end

return Logger
