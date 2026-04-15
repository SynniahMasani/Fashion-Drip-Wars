--[[
    ThemeSystem
    ───────────
    Maintains a catalogue of round themes and randomly selects one per round.
    Uses a no-repeat pool: every theme is used once before any repeats occur.
    Designed to scale to 150+ entries – just append to THEMES.

    Dependencies (injected via Init):
        Logger

    Theme structure:
    {
        name        : string,
        description : string,
        tags        : string[],   -- style hints for AI scoring in Phase 1
    }

    Public API:
        ThemeSystem.Init(logger)
        ThemeSystem.SelectTheme()     -> Theme
        ThemeSystem.GetCurrentTheme() -> Theme | nil
        ThemeSystem.GetAllThemes()    -> Theme[]
--]]

local ThemeSystem = {}

-- ── Theme catalogue ──────────────────────────────────────────────────────────
-- 24 themes for launch; add more rows to expand without touching any other code.

local THEMES = {
    { name = "Cyberpunk Neon",       description = "Neon-lit tech-wear for a dystopian megacity.",             tags = {"Futuristic", "Dark", "Techwear"} },
    { name = "Royal Court",          description = "Regal gowns and armour fit for a medieval throne.",         tags = {"Elegant", "Historical", "Formal"} },
    { name = "Streetwear Royalty",   description = "High-end street fashion with a crown to match.",            tags = {"Casual", "Streetwear", "Hype"} },
    { name = "Ocean Depths",         description = "Flowing blues and deep-sea creature inspiration.",           tags = {"Nature", "Fantasy", "Cool"} },
    { name = "Galactic Explorer",    description = "Space-suit couture for interstellar fashionistas.",          tags = {"Futuristic", "Sci-Fi", "Bold"} },
    { name = "Vintage Hollywood",    description = "Golden-age glamour straight off the silver screen.",         tags = {"Retro", "Elegant", "Formal"} },
    { name = "Jungle Monarch",       description = "Wild patterns and natural textures from the rainforest.",    tags = {"Nature", "Bold", "Exotic"} },
    { name = "Pastel Dream",         description = "Soft pastels and dreamy silhouettes.",                      tags = {"Soft", "Cute", "Feminine"} },
    { name = "Dark Academia",        description = "Scholarly layers with mysterious, gothic undertones.",       tags = {"Dark", "Intellectual", "Vintage"} },
    { name = "Y2K Revival",          description = "Early 2000s butterfly clips, chrome, and low-rise fits.",   tags = {"Retro", "Playful", "Casual"} },
    { name = "Samurai Chic",         description = "Ancient warrior aesthetics reimagined in modern cuts.",      tags = {"Historical", "Bold", "Cultural"} },
    { name = "Cottagecore",          description = "Floral prints, lace, and pastoral simplicity.",              tags = {"Soft", "Nature", "Feminine"} },
    { name = "Urban Ninja",          description = "All-black utilitarian stealth wear.",                        tags = {"Dark", "Streetwear", "Minimalist"} },
    { name = "Desert Nomad",         description = "Earthy tones and flowing layers for the open sand.",         tags = {"Nature", "Earthy", "Bohemian"} },
    { name = "Ice Palace",           description = "Crisp whites, silvers, and crystalline accents.",            tags = {"Cool", "Elegant", "Minimalist"} },
    { name = "Tropical Fiesta",      description = "Bright prints, fruit motifs, and island vibes.",             tags = {"Colourful", "Casual", "Fun"} },
    { name = "Mecha Pilot",          description = "Armoured cockpit aesthetic with industrial hardware.",       tags = {"Futuristic", "Sci-Fi", "Bold"} },
    { name = "Witch's Wardrobe",     description = "Mystical layers, star prints, and enchanted accessories.",  tags = {"Fantasy", "Dark", "Bohemian"} },
    { name = "Red Carpet Gala",      description = "Showstopping formal wear for the biggest night.",            tags = {"Elegant", "Formal", "Glamorous"} },
    { name = "Retro Sportswear",     description = "80s athletic colour-blocking and chunky trainers.",          tags = {"Retro", "Casual", "Sporty"} },
    { name = "Vampire Aristocrat",   description = "Dark velvet, lace cravats, and blood-red accents.",         tags = {"Dark", "Elegant", "Fantasy"} },
    { name = "Harajuku Pop",         description = "Chaotic, layered street fashion from Tokyo's Harajuku.",    tags = {"Colourful", "Eclectic", "Cultural"} },
    { name = "Steampunk Inventor",   description = "Brass gears, goggles, and Victorian-industrial fusion.",    tags = {"Historical", "Futuristic", "Eclectic"} },
    { name = "Neon Sportswear",      description = "High-vis athletic wear built for a sport rave.",             tags = {"Colourful", "Sporty", "Bold"} },
}

-- ── Private state ────────────────────────────────────────────────────────────

local _logger       = nil
local _currentTheme = nil
local _usedIndices  = {} -- tracks which themes have been used in this cycle

-- ── Public API ───────────────────────────────────────────────────────────────

--- Initialises the module. Must be called before SelectTheme().
--- @param logger  table
function ThemeSystem.Init(logger)
    _logger = logger
    _logger.info("ThemeSystem", "Initialized with " .. #THEMES .. " themes.")
end

--- Randomly picks a theme, avoiding repeats until every theme has been used.
--- Resets the pool automatically when all themes have appeared once.
--- @return Theme
function ThemeSystem.SelectTheme()
    -- Build the available pool from unused indices
    local pool = {}
    for i = 1, #THEMES do
        if not _usedIndices[i] then
            table.insert(pool, i)
        end
    end

    -- Full cycle complete – start fresh
    if #pool == 0 then
        _usedIndices = {}
        for i = 1, #THEMES do
            table.insert(pool, i)
        end
        _logger.info("ThemeSystem", "All " .. #THEMES .. " themes used – reshuffling pool.")
    end

    local chosenIdx = pool[math.random(1, #pool)]
    _usedIndices[chosenIdx] = true
    _currentTheme = THEMES[chosenIdx]

    _logger.info("ThemeSystem", 'Theme selected: "' .. _currentTheme.name .. '"')
    return _currentTheme
end

--- Returns the theme for the current round, or nil before the first selection.
--- @return Theme | nil
function ThemeSystem.GetCurrentTheme()
    return _currentTheme
end

--- Returns the full catalogue (read-only reference – do not mutate).
--- @return Theme[]
function ThemeSystem.GetAllThemes()
    return THEMES
end

return ThemeSystem
