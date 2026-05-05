-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):NewAddon("EmpireManager", "AceConsole-3.0", "AceEvent-3.0")
EmpireManager.version = C_AddOns.GetAddOnMetadata("EmpireManager", "Version") or "?"
EmpireManager.description = C_AddOns.GetAddOnMetadata("EmpireManager", "Notes") or ""

-- DB defaults
local DB_DEFAULTS = {
    global = {
        registry = {}, -- keyed by UnitGUID("player")
        storageAssignments = {}, -- array of { profession, type, tabs?, char?, guild?, expansions? }
        storageCapacity = {
            warbandbank = {}, -- [tabIndex] = { total, used }
            guildbank = {}, -- [guildName] = { [tabIndex] = { total, used } }
            charbank = {}, -- [guid] = { [tabIndex] = { total, used } }
        },
        schemaVersion = 1,
        lastReset = 0,
        lastWeeklyReset = 0,
        uiStatus = {}, -- persists dashboard frame position/size
        charBlacklist = {}, -- [guid] = "Name - Realm"; excluded from data collection
        keepList = {}, -- [itemID] = "Item Name"; protected from all triage actions (vendor, mail, stash)
        vendorWhitelist = {}, -- [itemID] = "Item Name"; always vendored regardless of rules
        stats = {}, -- cumulative operation counters (goldVendored, itemsVendored, itemsStashed, itemsMailed)
        options = {
            defaultVendorThreshold = 0, -- copper; applied to new characters
            minimapButton = true, -- show minimap icon
            escToClose = true, -- register frames with UISpecialFrames
            chatMessages = true, -- print bulk-op status to chat (errors always show)
            verboseMessages = false, -- print internal progress lines (restacking, snapshots, "depositing..." intent)
            showHints = true, -- print [Hint] lines (upgradeable bags, unpurchased tabs, etc.)
            popupOnBank = true, -- triage reminder on bank open
            popupOnGuildBank = true, -- misplaced scan on guild bank open
            popupOnMailbox = true, -- routable reminder on mailbox open
            popupOnVendor = true, -- open triage overlay on vendor open
            skipEquipmentSets = true, -- protect gear in equipment sets from vendor rules
            pawnVendorBop = false, -- vendor soulbound non-upgrades via Pawn
            vendorBopIlvl = false, -- vendor soulbound gear with lower ilvl than equipped
            vendorIlvlCeiling = 0, -- iLvl ceiling for BoP vendor checks; gear at or above is kept (0 = disabled)
            confirmVendorQuality = true, -- show confirmation dialog before vendoring uncommon+ gear
            disenchantRouting = false, -- route low-value BoE to enchanter instead of AH
            disenchantThreshold = 0, -- copper; fallback threshold when TSM unavailable
            clampToScreen = true, -- keep addon windows inside the screen bounds
        },
    },
    char = {
        assignments = {}, -- roleKey → { profKey = true, ... }; simple roles = {}
        storageNote = "",
        sortOrder = 0, -- custom sort priority for dashboard grid (lower = higher)
        auctioneerKeepBOE = true, -- Auctioneer: keep BoE equipment instead of routing
        enchanterKeepDE = true, -- Enchanter: keep vendor gear for disenchanting
        keepOwnProfMatsInBank = false, -- Keep own profession materials in character bank
        keepOwnProfMatsInBags = false, -- Keep own profession materials in bags
        keepOwnProfMatsInBagsLatestOnly = false, -- Sub-option: only apply Keep-in-Bags to latest-expansion mats
        stashOldQuestItems = true, -- Route soulbound Quest items from previous expansions to own bank
    },
}

function EmpireManager:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("EmpireManagerDB", DB_DEFAULTS)

    -- Ensure nested saved-data tables exist (AceDB defaults don't materialize them)
    if not rawget(self.db.global, "charBlacklist") then
        self.db.global.charBlacklist = {}
    end
    if not rawget(self.db.global, "keepList") then
        self.db.global.keepList = {}
    end
    if not rawget(self.db.global, "vendorWhitelist") then
        self.db.global.vendorWhitelist = {}
    end

    -- Resolve legacy Keep/Vendor conflicts: items on BOTH lists. Keep List wins
    -- in classification, so remove conflicting entries from the Vendor List.
    -- New code blocks the conflict at add-time; this only matters for saved data
    -- created before that gate existed.
    do
        local removed = 0
        local kl = self.db.global.keepList
        local vl = self.db.global.vendorWhitelist
        if kl and vl then
            for itemID in pairs(kl) do
                if vl[itemID] then
                    vl[itemID] = nil
                    removed = removed + 1
                end
            end
        end
        if removed > 0 then
            self:Print(
                string.format(
                    "Resolved %d Keep/Vendor List conflict%s (kept on Keep List).",
                    removed,
                    removed == 1 and "" or "s"
                )
            )
        end
    end
    if not rawget(self.db.global, "stats") then
        self.db.global.stats = {
            goldVendored = 0,
            itemsVendored = 0,
            itemsStashed = 0,
            itemsMailed = 0,
        }
    end

    -- Migrate storage assignments: resolve stale API-stub keys to real GUIDs
    local registry = self.db.global.registry or {}
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.char and asn.char:sub(1, 4) == "API-" then
            local stubName = asn.char:sub(5):match("^(.+)-(.+)$")
            if stubName then
                for guid, entry in pairs(registry) do
                    if
                        guid:sub(1, 4) ~= "API-"
                        and entry.name
                        and entry.realm
                        and (entry.name .. "-" .. entry.realm) == asn.char:sub(5)
                    then
                        asn.char = guid
                        break
                    end
                end
            end
        end
    end

    self:RegisterChatCommand("em", "SlashHandler")

    -- Native WoW Settings panel (Interface → AddOns → EmpireManager)
    -- Landing page = About info; subcategories for settings sections
    local aboutFrame = CreateFrame("Frame")
    aboutFrame:SetSize(600, 400)
    aboutFrame:Hide()

    local category = Settings.RegisterCanvasLayoutCategory(aboutFrame, "EmpireManager")
    self.settingsCategoryID = category:GetID()

    -- Build About content on the canvas frame
    local function BuildAboutContent(parent)
        local LOGO_SIZE = 96
        local TEXT_LEFT = 16 + LOGO_SIZE + 12 -- logo width + gap

        local logo = parent:CreateTexture(nil, "ARTWORK")
        logo:SetTexture("Interface\\AddOns\\EmpireManager\\textures\\logo256")
        logo:SetSize(LOGO_SIZE, LOGO_SIZE)
        logo:SetPoint("TOPLEFT", 16, -10)

        -- Text column starts slightly above the logo's top edge (matches About page)
        local y = -8

        local title = parent:CreateTexture(nil, "ARTWORK")
        title:SetTexture("Interface\\AddOns\\EmpireManager\\textures\\em")
        title:SetSize(192, 48)
        title:SetPoint("TOPLEFT", TEXT_LEFT, y - 4)
        y = y - 52

        local ver = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        ver:SetPoint("TOPLEFT", TEXT_LEFT, y)
        ver:SetText("Version " .. (self.version or "?"))
        ver:SetTextColor(0.91, 0.85, 0.66)
        y = y - 18

        local author = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        author:SetPoint("TOPLEFT", TEXT_LEFT, y)
        author:SetText("|cffe8d9a8Author:|r  l0neshad0w")
        y = y - 24

        -- Drop below the logo before the description block
        if y > -10 - LOGO_SIZE then
            y = -10 - LOGO_SIZE - 8
        end

        local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        desc:SetPoint("TOPLEFT", 16, y)
        desc:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
        desc:SetJustifyH("LEFT")
        desc:SetText(self.description)
        desc:SetTextColor(0.8, 0.8, 0.8)
        y = y - 36

        -- Statistics
        local function FmtNum(n)
            n = n or 0
            local s = tostring(math.floor(n))
            return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
        end

        local gStats = self.db.global.stats or {}
        local sStats = self._sessionStats or {}

        local statDefs = {
            {
                key = "goldVendored",
                label = "Gold from Vendors",
                icon = "Interface\\Icons\\INV_Misc_Coin_17",
                fmt = "gold",
            },
            {
                key = "itemsVendored",
                label = "Items Vendored",
                icon = "Interface\\Icons\\INV_Misc_Bag_10",
                fmt = "num",
            },
            {
                key = "itemsStashed",
                label = "Items Deposited to Bank",
                icon = "Interface\\Icons\\INV_Misc_Bag_07",
                fmt = "num",
            },
            {
                key = "itemsMailed",
                label = "Items Mailed",
                icon = "Interface\\Icons\\INV_Letter_15",
                fmt = "num",
            },
        }

        local STAT_LABEL_X = 16
        local STAT_LABEL_WIDTH = 220
        local STAT_SESSION_X = STAT_LABEL_X + STAT_LABEL_WIDTH
        local STAT_ALLTIME_X = STAT_SESSION_X + 120
        local STAT_COL_WIDTH = 100

        local statHdr = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        statHdr:SetPoint("TOPLEFT", STAT_LABEL_X, y)
        statHdr:SetText("|cffffff88Statistics|r")
        y = y - 18

        local hdrSession = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        hdrSession:SetPoint("TOPLEFT", STAT_SESSION_X, y)
        hdrSession:SetWidth(STAT_COL_WIDTH)
        hdrSession:SetJustifyH("RIGHT")
        hdrSession:SetText("|cff88ccffThis Session|r")

        local hdrAll = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        hdrAll:SetPoint("TOPLEFT", STAT_ALLTIME_X, y)
        hdrAll:SetWidth(STAT_COL_WIDTH)
        hdrAll:SetJustifyH("RIGHT")
        hdrAll:SetText("|cffffcc00All Time|r")
        y = y - 18

        for _, stat in ipairs(statDefs) do
            local sVal = sStats[stat.key] or 0
            local gVal = gStats[stat.key] or 0
            local sFmt = stat.fmt == "gold" and self:FormatGold(sVal) or FmtNum(sVal)
            local gFmt = stat.fmt == "gold" and self:FormatGold(gVal) or FmtNum(gVal)

            local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            lbl:SetPoint("TOPLEFT", STAT_LABEL_X, y)
            lbl:SetWidth(STAT_LABEL_WIDTH)
            lbl:SetJustifyH("LEFT")
            lbl:SetText(string.format("  |T%s:14:14|t  |cffe8d9a8%s|r", stat.icon, stat.label))

            local sFs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            sFs:SetPoint("TOPLEFT", STAT_SESSION_X, y)
            sFs:SetWidth(STAT_COL_WIDTH)
            sFs:SetJustifyH("RIGHT")
            sFs:SetText("|cff88ccff" .. sFmt .. "|r")

            local gFs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            gFs:SetPoint("TOPLEFT", STAT_ALLTIME_X, y)
            gFs:SetWidth(STAT_COL_WIDTH)
            gFs:SetJustifyH("RIGHT")
            gFs:SetText("|cffffffff" .. gFmt .. "|r")

            y = y - 18
        end

        y = y - 8

        -- Slash commands
        local CMD_LABEL_WIDTH = 170
        local cmdHdr = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cmdHdr:SetPoint("TOPLEFT", 16, y)
        cmdHdr:SetText("|cffffff88Slash Commands|r")
        y = y - 20

        local commands = {
            { cmd = "/em", desc = "Open the Dashboard" },
            { cmd = "/em config", desc = "Configure the current character" },
            { cmd = "/em triage", desc = "Open Bag Triage overlay" },
            { cmd = "/em options", desc = "Open this settings panel" },
            { cmd = "/em purge <name>", desc = "Remove a character from the registry" },
            { cmd = "/em keeplist", desc = "Open the Keep List window" },
            { cmd = "/em vendorw", desc = "Open the vendor whitelist window" },
            { cmd = "/em charb", desc = "Open the character blacklist window" },
            { cmd = "/em help", desc = "Show all commands in chat" },
        }
        for _, c in ipairs(commands) do
            local cmdFs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            cmdFs:SetPoint("TOPLEFT", 20, y)
            cmdFs:SetWidth(CMD_LABEL_WIDTH)
            cmdFs:SetJustifyH("LEFT")
            cmdFs:SetText("|cffffd100" .. c.cmd .. "|r")

            local descFs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            descFs:SetPoint("TOPLEFT", 20 + CMD_LABEL_WIDTH, y)
            descFs:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
            descFs:SetJustifyH("LEFT")
            descFs:SetText(c.desc)
            descFs:SetTextColor(0.8, 0.8, 0.8)

            y = y - 16
        end
    end
    BuildAboutContent(aboutFrame)

    -- Helper: register a boolean option backed by db.global.options.
    -- Returns (setting, initializer). Pass the parent's initializer as
    -- `parentInitializer` to render this option as an indented sub-option that
    -- auto-disables when the parent is unchecked (Blizzard pattern).
    local function AddCheckbox(cat, key, name, tooltip, onChange, parentInitializer)
        local setting = Settings.RegisterProxySetting(
            cat,
            "EM_" .. key,
            Settings.VarType.Boolean,
            name,
            DB_DEFAULTS.global.options[key],
            function()
                return self.db.global.options[key]
            end,
            function(val)
                self.db.global.options[key] = val
                if onChange then
                    onChange(val)
                end
            end
        )
        local initializer = Settings.CreateCheckbox(cat, setting, tooltip)
        if parentInitializer and initializer and initializer.SetParentInitializer then
            initializer:SetParentInitializer(parentInitializer)
        end
        return setting, initializer
    end

    -- Helper: register a numeric slider backed by db.global.options
    local function AddSlider(cat, key, name, tooltip, minVal, maxVal, step, formatter, onChange)
        local setting = Settings.RegisterProxySetting(
            cat,
            "EM_" .. key,
            Settings.VarType.Number,
            name,
            DB_DEFAULTS.global.options[key],
            function()
                return self.db.global.options[key]
            end,
            function(val)
                self.db.global.options[key] = val
                if onChange then
                    onChange(val)
                end
            end
        )
        local options = Settings.CreateSliderOptions(minVal, maxVal, step)
        if formatter then
            options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
        end
        Settings.CreateSlider(cat, setting, options, tooltip)
        return setting
    end

    ---------------------------------------------------------------------------
    -- Subcategory: General
    ---------------------------------------------------------------------------
    local generalCat = Settings.RegisterVerticalLayoutSubcategory(category, "General")

    AddCheckbox(
        generalCat,
        "minimapButton",
        "Minimap Button",
        "Show a minimap icon to open the dashboard.",
        function(val)
            if self.minimapIcon then
                self.db.global.minimapIcon.hide = not val
                if val then
                    self.minimapIcon:Show("EmpireManager")
                else
                    self.minimapIcon:Hide("EmpireManager")
                end
            end
        end
    )

    AddCheckbox(
        generalCat,
        "escToClose",
        "ESC to Close",
        "Allow the Escape key to close EmpireManager windows.",
        function()
            self:UpdateEscBehavior()
        end
    )

    AddCheckbox(
        generalCat,
        "clampToScreen",
        "Clamp Windows to Screen",
        "Keep EmpireManager windows from being dragged off the visible screen area.",
        function()
            self:UpdateClampToScreen()
        end
    )

    local _, chatMsgsInit = AddCheckbox(
        generalCat,
        "chatMessages",
        "Chat Messages",
        "Print bulk-operation status updates (triage, mail, deposit, reorganize) to the chat frame. Errors and command responses are always shown."
    )

    AddCheckbox(
        generalCat,
        "verboseMessages",
        "Verbose Messages",
        'Also print internal progress lines like "Restacking bags", "Depositing N items...", and capacity snapshot confirmations.',
        nil,
        chatMsgsInit
    )

    AddCheckbox(
        generalCat,
        "showHints",
        "Show Hints",
        "Print [Hint] lines like upgradeable bag reminders and unpurchased bank tab notices.",
        nil,
        chatMsgsInit
    )

    -- Always Compare Items (CVar, not stored in our DB)
    do
        local setting = Settings.RegisterProxySetting(
            generalCat,
            "EM_alwaysCompareItems",
            Settings.VarType.Boolean,
            "Always Compare Items",
            false,
            function()
                return GetCVarBool("alwaysCompareItems")
            end,
            function(val)
                SetCVar("alwaysCompareItems", val and "1" or "0")
            end
        )
        Settings.CreateCheckbox(
            generalCat,
            setting,
            "Automatically show comparison tooltips when hovering over items. Hold Shift to compare when disabled."
        )
    end

    ---------------------------------------------------------------------------
    -- Subcategory: Triage
    ---------------------------------------------------------------------------
    local triageCat, triageLayout = Settings.RegisterVerticalLayoutSubcategory(category, "Triage")

    -- Live-refresh the triage window when classification-affecting options change.
    local function triageRefresh()
        if self.OnTriageOptionChanged then
            self:OnTriageOptionChanged()
        end
    end

    -- Section: Rules
    triageLayout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Rules"))

    AddSlider(
        triageCat,
        "defaultVendorThreshold",
        "Default Vendor Threshold",
        "Common-quality items with a per-item vendor price at or below this value are flagged as junk. Crafting materials, trade goods, consumables, and recipes are excluded. Set to 0 to disable.",
        0,
        1000000,
        1000,
        function(val)
            local g = math.floor(val / 10000)
            local s = math.floor((val % 10000) / 100)
            local c = val % 100
            local parts = {}
            if g > 0 then
                parts[#parts + 1] = g .. "g"
            end
            if s > 0 then
                parts[#parts + 1] = s .. "s"
            end
            if c > 0 or #parts == 0 then
                parts[#parts + 1] = c .. "c"
            end
            return table.concat(parts, " ")
        end,
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "disenchantRouting",
        "Disenchant Routing",
        "Route BoE gear to your Enchanting Artisan when disenchanting is more profitable than selling on the AH. Uses TSM price data when available.",
        triageRefresh
    )

    AddSlider(
        triageCat,
        "disenchantThreshold",
        "Disenchant Threshold",
        "When TSM is not available, BoE gear with per-unit sell price below this value is routed to the Enchanting Artisan. Set to 0 to disable.",
        0,
        1000000,
        1000,
        function(val)
            local g = math.floor(val / 10000)
            local s = math.floor((val % 10000) / 100)
            local c = val % 100
            local parts = {}
            if g > 0 then
                parts[#parts + 1] = g .. "g"
            end
            if s > 0 then
                parts[#parts + 1] = s .. "s"
            end
            if c > 0 or #parts == 0 then
                parts[#parts + 1] = c .. "c"
            end
            return table.concat(parts, " ")
        end,
        triageRefresh
    )

    -- Section: Equipment
    triageLayout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Vendor"))

    AddCheckbox(
        triageCat,
        "skipEquipmentSets",
        "Protect 'Equipment Set' Items",
        "Skip vendoring soulbound gear that belongs to any saved equipment set.",
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "pawnVendorBop",
        "BoP Non-Upgrades (Pawn)",
        "Flag soulbound gear that Pawn considers not an upgrade as vendorable. Requires the Pawn addon.",
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "vendorBopIlvl",
        "BoP Lower iLvl",
        "Flag soulbound equippable gear as vendorable when its item level is lower than the equipped item in the same slot. Pawn takes priority when both are enabled.",
        triageRefresh
    )

    AddSlider(
        triageCat,
        "vendorIlvlCeiling",
        "Keep Above iLvl",
        "Soulbound equippable gear at or above this item level is kept regardless of Pawn/iLvl vendor checks. Set to 0 to disable.",
        0,
        300,
        1,
        function(val)
            if val == 0 then
                return "Disabled"
            end
            return tostring(val)
        end,
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "confirmVendorQuality",
        "Confirm Before Selling Quality Gear",
        "Show a confirmation dialog before vendoring uncommon (green) or higher quality items. Junk and common items vendor silently."
    )

    -- Section: Actions
    triageLayout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Actions"))

    AddCheckbox(
        triageCat,
        "popupOnBank",
        "Open on Bank/Warband Open",
        "Auto-open the triage overlay when opening the Bank or Warband Bank (if deposit items exist)."
    )

    AddCheckbox(
        triageCat,
        "popupOnGuildBank",
        "Open on Guild Bank Open",
        "Auto-open the triage overlay when opening the Guild Bank (if deposit items exist)."
    )

    AddCheckbox(
        triageCat,
        "popupOnMailbox",
        "Open on Mailbox Open",
        "Auto-open the Triage overlay when opening a Mailbox (if routable items exist)."
    )

    AddCheckbox(
        triageCat,
        "popupOnVendor",
        "Open on Vendor Open",
        "Automatically open the Bag Triage overlay when visiting a Vendor (if there are vendorable items)."
    )

    Settings.RegisterAddOnCategory(category)

    -- Minimap button (LibDataBroker + LibDBIcon)
    local ldb = LibStub("LibDataBroker-1.1")
    local icon = LibStub("LibDBIcon-1.0")

    local dataBroker = ldb:NewDataObject("EmpireManager", {
        type = "launcher",
        icon = "Interface\\AddOns\\EmpireManager\\textures\\logo-portrait",
        OnClick = function(btn, button)
            if button == "LeftButton" and IsShiftKeyDown() then
                self:ToggleTriageOverlay()
            elseif button == "LeftButton" then
                self:ToggleDashboard()
            elseif button == "RightButton" then
                MenuUtil.CreateContextMenu(btn, function(_, root)
                    root:CreateTitle("EmpireManager")
                    root:CreateButton("Open Dashboard", function()
                        self:ToggleDashboard()
                    end)
                    root:CreateButton("Open Triage", function()
                        self:ToggleTriageOverlay()
                    end)
                    root:CreateButton("Configure this character", function()
                        self:OpenSidecar(self.playerGUID)
                    end)
                    root:CreateDivider()
                    root:CreateButton("Import / Export", function()
                        self:ToggleIOWindow()
                    end)
                    root:CreateDivider()
                    root:CreateButton("Keep List", function()
                        self:ToggleKeeplistWindow()
                    end)
                    root:CreateButton("Vendor Whitelist", function()
                        self:ToggleVendorlistWindow()
                    end)
                    root:CreateButton("Guild Blacklist", function()
                        self:ToggleGuildBlacklistWindow()
                    end)
                    root:CreateButton("Character Blacklist", function()
                        self:ToggleCharBlacklistWindow()
                    end)
                    root:CreateDivider()
                    root:CreateButton("Options", function()
                        Settings.OpenToCategory(self.settingsCategoryID)
                    end)
                end)
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("EmpireManager", 1, 0.82, 0)
            tt:AddLine(" ")
            tt:AddLine("Left-click: Open Dashboard", 1, 1, 1)
            tt:AddLine("Shift-click: Open Triage", 1, 1, 1)
            tt:AddLine("Right-click: Menu", 1, 1, 1)
        end,
    })

    if not self.db.global.minimapIcon then
        self.db.global.minimapIcon = {}
    end
    -- Sync LibDBIcon's hide flag with our option BEFORE Register so its delayed
    -- PLAYER_LOGIN handler doesn't re-show a button we wanted hidden.
    self.db.global.minimapIcon.hide = not self.db.global.options.minimapButton
    icon:Register("EmpireManager", dataBroker, self.db.global.minimapIcon)

    self.minimapIcon = icon

    self:ChatMsg("EmpireManager loaded")
end

function EmpireManager:OnEnable()
    local guid = UnitGUID("player")
    self.playerGUID = guid -- cache for event handlers (never changes per session)
    local name = UnitName("player")
    local realm = GetRealmName()

    -- Skip data collection if character is blacklisted
    if self.db.global.charBlacklist[guid] then
        self:ChatMsg(
            string.format("|cff888888%s - %s is excluded from roster. Use /em charb to manage.|r", name, realm)
        )
        return
    end

    -- Ensure this character exists in the global registry.
    -- If an imported stub exists for this name+realm, promote it to the real GUID.
    local stubKey = "API-" .. name .. "-" .. realm
    if not self.db.global.registry[guid] then
        self.db.global.registry[guid] = self.db.global.registry[stubKey] or {}
    end
    if self.db.global.registry[stubKey] then
        self.db.global.registry[stubKey] = nil
        -- Update storage assignments that reference the old stub key
        for _, asn in ipairs(self.db.global.storageAssignments or {}) do
            if asn.char == stubKey then
                asn.char = guid
            end
        end
    end

    local entry = self.db.global.registry[guid]
    entry.name = name
    entry.realm = realm
    entry.class = select(2, UnitClass("player"))
    entry.race = select(2, UnitRace("player")) -- "BloodElf", "Orc", etc.
    entry.level = UnitLevel("player")
    entry.gold = GetMoney()
    entry.guild = GetGuildInfo("player") or ""
    entry.lastSeen = time()
    entry.ilvl = select(2, GetAverageItemLevel()) -- equipped ilvl
    entry.faction = UnitFactionGroup("player") -- "Horde" or "Alliance"

    -- Session stats (transient, not saved)
    self._sessionStats = {
        goldVendored = 0,
        itemsVendored = 0,
        itemsStashed = 0,
        itemsMailed = 0,
    }

    -- Snapshot bag slots
    local free, total = 0, 0
    for bag = 0, 4 do
        total = total + (C_Container.GetContainerNumSlots(bag) or 0)
        free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
    end
    entry.freeBagSlots = free
    entry.totalBagSlots = total

    -- Upgrade hint: undersized bags compared to character's own largest
    local maxBagSize = 0
    for bag = 1, 4 do
        local size = C_Container.GetContainerNumSlots(bag) or 0
        if size > maxBagSize then
            maxBagSize = size
        end
    end
    if maxBagSize > 0 then
        local smallBags = {}
        for bag = 1, 4 do
            local size = C_Container.GetContainerNumSlots(bag) or 0
            if size < maxBagSize then
                if size == 0 then
                    smallBags[#smallBags + 1] = string.format("Bag %d (empty)", bag)
                else
                    smallBags[#smallBags + 1] = string.format("Bag %d (%d)", bag, size)
                end
            end
        end
        if #smallBags > 0 then
            self:ChatHint(
                string.format(
                    "|cff4d99ff[Hint]|r Upgradeable bags (your largest is %d-slot): %s",
                    maxBagSize,
                    table.concat(smallBags, ", ")
                )
            )
        end
    end

    -- Openable-container hint: right-click-to-open loot boxes often sit forgotten
    -- in bags. Also re-runs on BAG_UPDATE_DELAYED (see HintOpenableContainers) so
    -- freshly looted chests get announced even mid-session.
    self:HintOpenableContainers()

    -- Snapshot spec (e.g. "Frost", "Shadow")
    local specIdx = GetSpecialization()
    if specIdx then
        entry.spec = select(2, GetSpecializationInfo(specIdx))
    end

    -- Snapshot professions
    self:SnapshotProfessions(entry)

    -- Sync char-level settings to global registry so the dashboard can read all alts.
    -- If another character edited this entry via the sidecar (dirtyFromSidecar flag),
    -- copy global→char instead of char→global to preserve those remote edits.
    if entry.dirtyFromSidecar then
        self.db.char.assignments = entry.assignments or self.db.char.assignments
        self.db.char.storageNote = entry.storageNote or self.db.char.storageNote
        self.db.char.sortOrder = entry.sortOrder or self.db.char.sortOrder
        if entry.auctioneerKeepBOE ~= nil then
            self.db.char.auctioneerKeepBOE = entry.auctioneerKeepBOE
        end
        if entry.enchanterKeepDE ~= nil then
            self.db.char.enchanterKeepDE = entry.enchanterKeepDE
        end
        if entry.keepOwnProfMatsInBank ~= nil then
            self.db.char.keepOwnProfMatsInBank = entry.keepOwnProfMatsInBank
        end
        if entry.keepOwnProfMatsInBags ~= nil then
            self.db.char.keepOwnProfMatsInBags = entry.keepOwnProfMatsInBags
        end
        if entry.keepOwnProfMatsInBagsLatestOnly ~= nil then
            self.db.char.keepOwnProfMatsInBagsLatestOnly = entry.keepOwnProfMatsInBagsLatestOnly
        end
        if entry.stashOldQuestItems ~= nil then
            self.db.char.stashOldQuestItems = entry.stashOldQuestItems
        end
        entry.dirtyFromSidecar = nil
    else
        entry.assignments = self.db.char.assignments
        entry.storageNote = self.db.char.storageNote
        entry.sortOrder = self.db.char.sortOrder
        entry.auctioneerKeepBOE = self.db.char.auctioneerKeepBOE
        entry.enchanterKeepDE = self.db.char.enchanterKeepDE
        entry.keepOwnProfMatsInBank = self.db.char.keepOwnProfMatsInBank
        entry.keepOwnProfMatsInBags = self.db.char.keepOwnProfMatsInBags
        entry.keepOwnProfMatsInBagsLatestOnly = self.db.char.keepOwnProfMatsInBagsLatestOnly
        entry.stashOldQuestItems = self.db.char.stashOldQuestItems
    end

    -- Lazy trigger events (only the windows we care about)
    self:RegisterEvent("BAG_UPDATE_DELAYED")
    self:RegisterEvent("TRADE_SKILL_SHOW")
    self:RegisterEvent("BANKFRAME_OPENED")
    self:RegisterEvent("BANKFRAME_CLOSED")
    -- Guild bank: GUILDBANKFRAME_OPENED/CLOSED are dead since 10.0.
    -- Use PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE with type 10 (GuildBanker).
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    -- Register permanently (like Blizzard's GuildBankFrame does in OnLoad).
    -- Dynamic registration inside the SHOW handler can miss the event if it fires
    -- before or during the frame show as part of initial server data load.
    self:RegisterEvent("GUILDBANK_UPDATE_TABS")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:RegisterEvent("PLAYER_LOGOUT")
    self:RegisterEvent("MERCHANT_SHOW")
    self:RegisterEvent("MERCHANT_CLOSED")
    self:RegisterEvent("MAIL_SHOW")
    self:RegisterEvent("MAIL_CLOSED")
    self:RegisterEvent("PLAYER_GUILD_UPDATE")
    self:RegisterEvent("TIME_PLAYED_MSG")
    self:RegisterEvent("PLAYER_LEVEL_UP")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    self:RegisterEvent("PLAYER_MONEY")

    -- Request playtime (async → triggers TIME_PLAYED_MSG). Silent variant suppresses
    -- Blizzard's chat output for our request; user-typed /played still prints normally.
    self:RequestTimePlayedSilent()

    -- Apply saved clamp preference to any XML frames that already exist
    self:UpdateClampToScreen()
    -- Apply saved ESC-to-close preference (registers UISpecialFrames entries)
    self:UpdateEscBehavior()
end

function EmpireManager:SlashHandler(input)
    local cmd = (self:GetArgs(input) or ""):lower()
    if cmd == "config" then
        local guid = self.playerGUID
        self:OpenSidecar(guid)
    elseif cmd == "triage" then
        local _, sub = self:GetArgs(input, 2)
        if sub and sub:lower() == "debug" then
            EmpireManager._debugShowKeep = not EmpireManager._debugShowKeep
            self:ChatMsg(
                string.format(
                    "Triage KEEP rows: %s",
                    EmpireManager._debugShowKeep and "|cff00ff00ON|r" or "|cffff4444OFF|r"
                ),
                true
            )
            if self.triageFrame and self.triageFrame:IsShown() then
                if self._triageActiveTab == "bank" then
                    self:RefreshBankTriageDisplay()
                else
                    self:RefreshTriageDisplay()
                end
            end
        else
            self:ToggleTriageOverlay()
        end
    elseif cmd == "options" then
        Settings.OpenToCategory(self.settingsCategoryID)
    elseif cmd == "purge" then
        local _, charName = self:GetArgs(input, 2)
        if not charName or charName == "" then
            self:ChatMsg("Usage: /em purge <character name>", true)
            return
        end
        self:PurgeCharacter(charName)
    elseif cmd == "keeplist" then
        self:ToggleKeeplistWindow()
    elseif cmd == "vendorw" then
        self:ToggleVendorlistWindow()
    elseif cmd == "gb" then
        self:ToggleGuildBlacklistWindow()
    elseif cmd == "charb" then
        self:ToggleCharBlacklistWindow()
    elseif cmd == "ie" then
        self:ToggleIOWindow()
    elseif cmd == "wipe" then
        local _, sub = self:GetArgs(input, 2)
        if sub == "chars" or sub == "rules" or sub == "all" then
            self:ConfirmWipe(sub)
        else
            self:ChatMsg("Usage: /em wipe chars | rules | all", true)
        end
    elseif cmd == "inspect" then
        -- Print classID/subClassID of the item currently under the cursor tooltip
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        local _, itemLink = GameTooltip:GetItem()
        GameTooltip:Hide()
        if not itemLink then
            -- Try cursor item
            local infoType, id = GetCursorInfo()
            if infoType == "item" then
                itemLink = select(2, C_Item.GetItemInfo(id))
            end
        end
        if not itemLink then
            self:ChatMsg("Pick up an item, then run /em inspect", true)
            return
        end
        self:EnsureStorageCache()
        local itemID, _, _, itemEquipLoc, icon, classID, subClassID = C_Item.GetItemInfoInstant(itemLink)
        local itemName, _, _, _, _, _, _, _, _, _, _, _, _, bindType, expansionID = C_Item.GetItemInfo(itemLink)
        self:ChatMsg(string.format("|cffffcc00[Inspect]|r %s", itemName or itemLink), true)
        self:ChatMsg(
            string.format(
                "  itemID=%d  classID=%d  subClassID=%d  equipLoc=%s",
                itemID or 0,
                classID or -1,
                subClassID or -1,
                itemEquipLoc or ""
            ),
            true
        )
        self:ChatMsg(
            string.format(
                "  bindType=%d  expansionID=%s  icon=%s",
                bindType or -1,
                tostring(expansionID or "nil"),
                tostring(icon or "nil")
            ),
            true
        )
        -- Tooltip-derived bind flags (what triage actually uses)
        if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
            local td = C_TooltipInfo.GetHyperlink(itemLink)
            local isWarbound, isSoulbound = false, false
            if td and td.lines then
                for _, line in ipairs(td.lines) do
                    local txt = line.leftText
                    if txt then
                        if txt == ITEM_ACCOUNTBOUND or txt == ITEM_BIND_TO_ACCOUNT or txt == ITEM_BIND_TO_ACCOUNT_UNTIL_EQUIP then
                            isWarbound = true
                        elseif txt == ITEM_SOULBOUND then
                            isSoulbound = true
                        end
                    end
                end
            end
            if isSoulbound then isWarbound = false end
            self:ChatMsg(
                string.format("  tooltip: isWarbound=%s  isSoulbound=%s", tostring(isWarbound), tostring(isSoulbound)),
                true
            )
        end
        -- Check profMatchCache
        local cacheKey = (classID or 0) * 1000 + (subClassID or 0)
        local matched = self._profMatchCache[cacheKey]
        if matched then
            local keys = {}
            for k in pairs(matched) do
                keys[#keys + 1] = k
            end
            self:ChatMsg(string.format("  profMatchCache[%d] = {%s}", cacheKey, table.concat(keys, ", ")), true)
        else
            self:ChatMsg(string.format("  profMatchCache[%d] = nil (no category match)", cacheKey), true)
        end
        local override = itemID and self._profOverrideCache[itemID]
        if override then
            local keys = {}
            for k in pairs(override) do
                keys[#keys + 1] = k
            end
            self:ChatMsg(string.format("  profOverrideCache[%d] = {%s}", itemID, table.concat(keys, ", ")), true)
        end
        -- TSM prices (if available)
        if TSM_API then
            local de = self:GetTSMPrice(itemLink, "DBDisenchant")
            local mk = self:GetTSMPrice(itemLink, "DBMarket")
            self:ChatMsg(
                string.format(
                    "  TSM DBDisenchant=%s  DBMarket=%s",
                    de and self:FormatGold(de) or "nil",
                    mk and self:FormatGold(mk) or "nil"
                ),
                true
            )
        else
            self:ChatMsg("  TSM not loaded (no DBDisenchant/DBMarket)", true)
        end
    elseif cmd == "dump" then
        local _, sub = self:GetArgs(input, 2)
        sub = sub and sub:lower() or "bags"
        -- Map sub-commands to {source label, scan type, bankType filter}. `debug`
        -- kept as alias for the default bag dump.
        local target
        if sub == "bags" or sub == "debug" or sub == "" then
            target = { label = "bag", scan = "bags" }
        elseif sub == "bank" then
            target = { label = "bank", scan = "bank", bankType = "charbank" }
        elseif sub == "wb" or sub == "warband" then
            target = { label = "warband bank", scan = "bank", bankType = "warbandbank" }
        elseif sub == "gb" or sub == "guild" then
            target = { label = "guild bank", scan = "guildbank" }
        else
            self:ChatMsg(string.format("|cffff4444[dump]|r unknown target: %s", sub), true)
            return
        end
        self:_DumpDebug(target)
    elseif cmd == "help" then
        self:ChatMsg("|cffffcc00Available commands:|r", true)
        self:ChatMsg("  /em Open the Dashboard", true)
        self:ChatMsg("  /em config Open the Assignment Panel for this character", true)
        self:ChatMsg("  /em triage Open the Bag Triage overlay", true)
        self:ChatMsg("  /em options Open the Options panel", true)
        self:ChatMsg("  /em purge <name> Remove a character from the registry", true)
        self:ChatMsg("  /em keeplist Open the Keep List window", true)
        self:ChatMsg("  /em vendorw Open the vendor whitelist window", true)
        self:ChatMsg("  /em gb Open the guild storage blacklist window", true)
        self:ChatMsg("  /em charb Open the character blacklist window", true)
        self:ChatMsg("  /em ie Open the Import/Export window", true)
        self:ChatMsg("  /em help Show this list", true)
    else
        self:ToggleDashboard()
    end
end

-- Toggle ESC-to-close behavior for all EmpireManager frames and popups
function EmpireManager:UpdateEscBehavior()
    local frameNames = {
        "EmpireManagerDashboard",
        "EmpireManagerTriage",
        "EmpireManagerSidecar",
        "EmpireManagerKeeplistWindow",
        "EmpireManagerVendorlistWindow",
        "EmpireManagerGuildBlacklistWindow",
        "EmpireManagerCharBlacklistWindow",
    }
    local enabled = self.db.global.options.escToClose
    if enabled then
        for _, name in ipairs(frameNames) do
            if _G[name] and not tContains(UISpecialFrames, name) then
                tinsert(UISpecialFrames, name)
            end
        end
    else
        for _, name in ipairs(frameNames) do
            for i = #UISpecialFrames, 1, -1 do
                if UISpecialFrames[i] == name then
                    tremove(UISpecialFrames, i)
                end
            end
        end
    end
    -- Apply same preference to our StaticPopup dialogs
    local popups = {
        "EM_CONFIRM_REMOVE",
        "EM_KEEPLIST_ADD",
        "EM_VENDORLIST_ADD",
        "EM_KEEPLIST_MOVE_FROM_VENDOR",
        "EM_VENDORLIST_MOVE_FROM_KEEP",
    }
    for _, key in ipairs(popups) do
        if StaticPopupDialogs[key] then
            StaticPopupDialogs[key].hideOnEscape = enabled
        end
    end
end

-- Render a single triage result as one debug line (inspect-style). Shared by
-- /em dump, /em dump bank, /em dump wb, /em dump gb.
local function FormatDumpLine(addon, r)
    local CATEGORY_INFO = addon.CATEGORY_INFO
    local item = r.item
    local link = item.itemLink or item.itemName or "?"
    -- For display use the plain item name (no brackets, no link escapes).
    -- `link` is still passed to GetItemInfo* below since those APIs accept
    -- both names and links.
    local displayName = item.itemName or link or "?"
    local catInfo = CATEGORY_INFO[r.category]
    local catLabel = catInfo and catInfo.label or "?"
    local count = item.count or 1
    local itemID, _, _, itemEquipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(link)
    local bindType, expansionID, _, isCraftingReagent = select(14, C_Item.GetItemInfo(link))
    local cacheKey = (classID or 0) * 1000 + (subClassID or 0)
    local override = itemID and addon._profOverrideCache[itemID]
    local matched = override or addon._profMatchCache[cacheKey]
    local profStr
    if matched then
        local keys = {}
        for k in pairs(matched) do
            keys[#keys + 1] = k
        end
        profStr = "{" .. table.concat(keys, ",") .. "}"
        if override then
            profStr = profStr .. "*" -- mark itemID overrides in dump output
        end
    else
        profStr = "nil"
    end
    local reagentStr = isCraftingReagent == true and "yes" or (isCraftingReagent == false and "no" or "?")
    local boundStr = item.isBound and "Y" or "n"
    local warStr = item.isWarbound and "Y" or "n"
    return string.format(
        "%s;%s;%d;%d;%d;%d;%s;%d;%s;%s;%s;%s;%s;%s",
        catLabel,
        displayName,
        count,
        itemID or 0,
        classID or -1,
        subClassID or -1,
        itemEquipLoc ~= "" and itemEquipLoc or "-",
        bindType or -1,
        boundStr,
        warStr,
        tostring(expansionID or "nil"),
        reagentStr,
        profStr,
        r.action or "?"
    )
end

-- Render results into the debug popup. `target` = {label, scan, bankType?}.
-- Handles bags (sync), char/warband bank (async bank scan), guild bank (async).
function EmpireManager:_DumpDebug(target)
    local charName = UnitName("player") or "?"
    local function render(results, filterFn)
        local filtered = {}
        if filterFn then
            for _, r in ipairs(results) do
                if filterFn(r) then
                    filtered[#filtered + 1] = r
                end
            end
        else
            filtered = results
        end
        if not filtered or #filtered == 0 then
            self:ChatMsg(string.format("No items in %s.", target.label), true)
            return
        end
        local lines = {
            string.format("# %s %s dump (%d items)", charName, target.label, #filtered),
            "category;name;count;itemID;classID;subClassID;equipLoc;bindType;bound;warbound;expansion;reagent;prof;action",
        }
        for _, r in ipairs(filtered) do
            lines[#lines + 1] = FormatDumpLine(self, r)
        end
        self:ShowDebugPopup(table.concat(lines, "\n"))
    end

    if target.scan == "bags" then
        render(self:RunTriage() or {})
    elseif target.scan == "bank" then
        if not self.bankIsOpen then
            self:ChatMsg("|cffff4444[dump]|r Bank must be open for this dump.", true)
            return
        end
        self:RunBankTriageAsync(function(results)
            render(results, function(r)
                return r.item.bankType == target.bankType
            end)
        end)
    elseif target.scan == "guildbank" then
        if not self:IsGuildBankOpen() then
            self:ChatMsg("|cffff4444[dump]|r Guild bank must be open for this dump.", true)
            return
        end
        self:RunBankTriageAsync(function(results)
            render(results, function(r)
                return r.item.bankType == "guildbank"
            end)
        end)
    end
end

-- Lazy-created popup used by debug dump commands (/em dumpv etc.)
-- Copyable textarea: plain ScrollFrame + EditBox scroll child. Avoids
-- InputScrollFrameTemplate's character-counter overlay and the selection-rect
-- bugs that come with chat-font templates.
function EmpireManager:ShowDebugPopup(text)
    local f = _G.EmpireManagerDebugFrame
    if not f then
        f = CreateFrame("Frame", "EmpireManagerDebugFrame", UIParent, "BackdropTemplate")
        f:SetSize(800, 520)
        f:SetPoint("CENTER")
        f:SetFrameStrata("HIGH")
        f:SetToplevel(true)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)

        local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -16)
        title:SetText("EmpireManager DEBUG")

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)

        -- Plain ScrollFrame (NOT InputScrollFrameTemplate) so there's no
        -- character-counter overlay and no template-imposed font.
        local scroll = CreateFrame("ScrollFrame", nil, f)
        scroll:SetPoint("TOPLEFT", 24, -48)
        scroll:SetPoint("BOTTOMRIGHT", -36, 24)
        scroll:EnableMouse(true)

        -- EditBox is the scroll child. Fills the scroll viewport; auto-grows
        -- vertically when SetText is called.
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:EnableMouse(true)
        eb:SetCountInvisibleLetters(false) -- fix selection-rect mis-alignment with escapes
        eb:SetTextInsets(4, 4, 4, 4)
        eb:SetFontObject("GameFontHighlightSmall")
        eb:SetMaxBytes(0)
        eb:SetMaxLetters(0)
        if eb.SetHyperlinksEnabled then
            eb:SetHyperlinksEnabled(false)
        end

        scroll:SetScrollChild(eb)
        eb:SetWidth(8000) -- wide so long lines never wrap
        scroll:SetHorizontalScroll(0)

        -- Click anywhere in the scroll viewport (including below the text)
        -- focuses the editbox and parks the cursor at the end.
        scroll:SetScript("OnMouseUp", function()
            eb:SetFocus()
            eb:SetCursorPosition(eb:GetNumLetters())
        end)

        -- Keep the editbox hit-rect aligned with the visible scroll area as
        -- the user scrolls vertically, otherwise clicks outside the visible
        -- region land on hidden text.
        scroll:HookScript("OnVerticalScroll", function(self, offset)
            eb:SetHitRectInsets(0, 0, offset, eb:GetHeight() - offset - self:GetHeight())
        end)

        -- Auto-scroll to keep the cursor in view as the user moves it.
        eb:SetScript("OnCursorChanged", function(_, _, y, _, cursorHeight)
            local sf = scroll
            local cy = -y
            local off = sf:GetVerticalScroll()
            if cy < off then
                sf:SetVerticalScroll(cy)
            else
                cy = cy + cursorHeight - sf:GetHeight()
                if cy > off then
                    sf:SetVerticalScroll(cy)
                end
            end
        end)

        eb:SetScript("OnEscapePressed", eb.ClearFocus)
        eb:SetScript("OnEditFocusLost", function(self)
            self:HighlightText(0, 0)
        end)

        -- Vertical scrollbar on the right.
        local sbar = CreateFrame("Slider", nil, scroll, "UIPanelScrollBarTemplate")
        sbar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, -16)
        sbar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 16)
        sbar:SetMinMaxValues(0, 0)
        sbar:SetValueStep(20)
        sbar:SetValue(0)
        sbar:SetWidth(16)
        sbar:SetScript("OnValueChanged", function(_, value)
            scroll:SetVerticalScroll(value)
        end)
        scroll:HookScript("OnVerticalScroll", function(_, offset)
            sbar:SetValue(offset)
        end)
        scroll:HookScript("OnScrollRangeChanged", function(_, _, yrange)
            sbar:SetMinMaxValues(0, yrange)
        end)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(_, delta)
            local cur = scroll:GetVerticalScroll()
            scroll:SetVerticalScroll(math.max(0, math.min(select(2, sbar:GetMinMaxValues()), cur - delta * 40)))
        end)

        f.EditBox = eb
        f.ScrollFrame = scroll
        tinsert(UISpecialFrames, "EmpireManagerDebugFrame")
    end
    f.EditBox:SetText(text or "")
    f.EditBox:SetTextColor(1, 1, 1, 1)
    f.EditBox:HighlightText(0, 0)
    f.EditBox:SetCursorPosition(0)
    f.ScrollFrame:SetVerticalScroll(0)
    f:Show()
end

-- Apply the clampToScreen option to all addon windows at runtime.
-- Frames created from XML default to clamped=true; this toggles them all at once.
EmpireManager.CLAMPED_FRAMES = {
    "EmpireManagerFrame",
    "EmpireManagerSidecar",
    "EmpireManagerStorageDialog",
    "EmpireManagerIOFrame",
    "EmpireManagerTriageFrame",
    "EmpireManagerMailDialog",
    "EmpireManagerKeeplistWindow",
    "EmpireManagerVendorlistWindow",
    "EmpireManagerGuildBlacklistWindow",
    "EmpireManagerCharBlacklistWindow",
}
function EmpireManager:UpdateClampToScreen()
    local clamp = self.db.global.options.clampToScreen
    for _, name in ipairs(self.CLAMPED_FRAMES) do
        local f = _G[name]
        if f and f.SetClampedToScreen then
            f:SetClampedToScreen(clamp)
        end
    end
end

-- Lazy trigger stubs: only do work when the relevant window opens

-- Scan bags 0-5 for `hasLoot` items (right-click-opens-a-loot-window boxes) and
-- print a [Hint] line listing any new ones since the last announcement. Session-
-- scoped dedup via `self._hintedOpenables` so the same chest doesn't re-announce
-- after every BAG_UPDATE_DELAYED.
function EmpireManager:HintOpenableContainers()
    self._hintedOpenables = self._hintedOpenables or {}
    local order, counts, linkByID = {}, {}, {}
    for bag = 0, 5 do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hasLoot and info.itemID and not self._hintedOpenables[info.itemID] then
                if not counts[info.itemID] then
                    order[#order + 1] = info.itemID
                    linkByID[info.itemID] = info.hyperlink
                end
                counts[info.itemID] = (counts[info.itemID] or 0) + 1
            end
        end
    end
    if #order == 0 then
        return
    end
    local parts = {}
    for _, id in ipairs(order) do
        local qty = counts[id]
        parts[#parts + 1] = qty > 1 and (linkByID[id] .. " x" .. qty) or linkByID[id]
        self._hintedOpenables[id] = true
    end
    self:ChatHint(string.format("|cff4d99ff[Hint]|r Openable containers (right-click): %s", table.concat(parts, ", ")))
end

function EmpireManager:BAG_UPDATE_DELAYED()
    -- Mark bag scan cache stale — RunTriageAsync will re-scan on next call.
    self._bagsDirty = true

    -- Re-check openable containers so freshly looted chests get announced.
    -- Session-scoped dedup inside HintOpenableContainers prevents spam.
    self:HintOpenableContainers()

    -- Update gold + free bag slots snapshot (cheap calls, always relevant)
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if entry then
        entry.gold = GetMoney()
        local free, total = 0, 0
        for bag = 0, 4 do
            local slots = C_Container.GetContainerNumSlots(bag)
            total = total + slots
            free = free + C_Container.GetContainerNumFreeSlots(bag)
        end
        entry.freeBagSlots = free
        entry.totalBagSlots = total
        if self.RefreshVisibleRows then
            self:RefreshVisibleRows()
        end
    end

    -- Debounced triage refresh: resets on each bag event, fires 0.3s after last change
    if self._bagRefreshTimer then
        self._bagRefreshTimer:Cancel()
    end
    self._bagRefreshTimer = C_Timer.NewTimer(0.3, function()
        self._bagRefreshTimer = nil
        self:SendMessage("EM_TRIAGE_REFRESH")
    end)
end

function EmpireManager:PLAYER_GUILD_UPDATE()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if entry then
        entry.guild = GetGuildInfo("player") or ""
    end
end

function EmpireManager:TRADE_SKILL_SHOW()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        return
    end

    -- Re-snapshot professions (may have changed since login)
    self:SnapshotProfessions(entry)

    -- Snapshot per-expansion skill breakdown for the open profession
    self:SnapshotExpansionSkills(entry)
end

function EmpireManager:BANKFRAME_OPENED()
    self.bankIsOpen = true

    -- Refresh triage tab visibility + deposit button immediately so the UI
    -- reacts without waiting for the capacity snapshot chain to finish.
    if self.triageFrame and self.triageFrame:IsShown() then
        if self.UpdateTriageTabButtons then
            self:UpdateTriageTabButtons()
        end
        if self.UpdateDepositBtnState then
            self:UpdateDepositBtnState()
        end
    end

    -- Fire the popup trigger early, BEFORE the capacity snapshot chain.
    -- Otherwise: replacement bank UIs like Baganator immediately call
    -- CloseBankFrame() to hide Blizzard's frame, which fires BANKFRAME_CLOSED
    -- and flips bankIsOpen back to false. Our chunked ProcessChunk aborts mid-
    -- scan and EM_BANK_OPENED never fires -> popup never appears. Running the
    -- bag scan up-front is safe since it only reads the player's bags.
    self:RunTriageAsync(function(bagResults)
        local bagActionable = 0
        for _, r in ipairs(bagResults) do
            if r.category ~= "KEEP" then
                bagActionable = bagActionable + 1
            end
        end
        self:SendMessage("EM_BANK_OPENED", bagActionable)
    end)

    -- Snapshot bank capacity using slot-level chunked C_Timer processing.
    -- Scans SLOTS_PER_CHUNK slots per frame to stay well under the 16ms budget.
    local SLOTS_PER_CHUNK = 20

    local guid = self.playerGUID
    local cap = self.db.global.storageCapacity
    if not cap.charbank[guid] then
        cap.charbank[guid] = {}
    end

    -- Build flat work list of individual slots across all bank containers
    local slots = {} -- { {bag, slot, type, tabIdx} ... }
    -- Character bank tabs (container IDs 6-11)
    for tabIdx = 1, 6 do
        local bag = tabIdx + 5
        local numSlots = C_Container.GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                slots[#slots + 1] = { bag = bag, slot = slot, type = "charbank", tabIdx = tabIdx, numSlots = numSlots }
            end
        end
    end
    -- Warband bank tabs (container IDs 12-16, AccountBankTab_1..5)
    local warbandTabIdx = 0
    for bag = 12, 16 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            warbandTabIdx = warbandTabIdx + 1
            for slot = 1, numSlots do
                slots[#slots + 1] =
                    { bag = bag, slot = slot, type = "warbandbank", tabIdx = warbandTabIdx, numSlots = numSlots }
            end
        end
    end

    -- Accumulator: { [type_tabIdx] = { total = N, used = N } }
    local accum = {}
    local cursor = 0
    local selfRef = self

    local function ProcessChunk()
        if not selfRef.bankIsOpen then
            return
        end -- bank closed, abort
        local limit = math.min(cursor + SLOTS_PER_CHUNK, #slots)
        for i = cursor + 1, limit do
            local s = slots[i]
            local key = s.type .. "_" .. s.tabIdx
            if not accum[key] then
                accum[key] = { total = s.numSlots, used = 0, type = s.type, tabIdx = s.tabIdx }
            end
            local info = C_Container.GetContainerItemInfo(s.bag, s.slot)
            if info then
                accum[key].used = accum[key].used + 1
            end
        end
        cursor = limit

        if cursor < #slots then
            C_Timer.After(0, ProcessChunk) -- next frame
            return
        end

        -- All slots scanned — write results
        for _, data in pairs(accum) do
            if data.type == "charbank" then
                cap.charbank[guid][data.tabIdx] = { total = data.total, used = data.used }
            else
                cap.warbandbank[data.tabIdx] = { total = data.total, used = data.used }
            end
        end

        local freeBank, totalBank, charTabs = 0, 0, 0
        for _, tabData in pairs(cap.charbank[guid] or {}) do
            local t = tabData.total or 0
            freeBank = freeBank + t - (tabData.used or 0)
            totalBank = totalBank + t
            charTabs = charTabs + 1
        end
        local entry = selfRef.db.global.registry[guid]
        if entry then
            entry.freeBankSlots = freeBank
            entry.totalBankSlots = totalBank
        end

        local freeWB, totalWB, wbTabs = 0, 0, 0
        for _, tabData in pairs(cap.warbandbank or {}) do
            local t = tabData.total or 0
            freeWB = freeWB + t - (tabData.used or 0)
            totalWB = totalWB + t
            wbTabs = wbTabs + 1
        end

        selfRef:ChatVerbose(
            string.format(
                "|cff4d99ff[Storage]|r Character Bank: %d tab%s, %d/%d free; Warband Bank: %d tab%s, %d/%d free",
                charTabs,
                charTabs == 1 and "" or "s",
                freeBank,
                totalBank,
                wbTabs,
                wbTabs == 1 and "" or "s",
                freeWB,
                totalWB
            )
        )

        -- Upgrade hint: unpurchased bank tabs (once per login)
        if not selfRef._bankUpgradeHintShown then
            selfRef._bankUpgradeHintShown = true
            local hints = {}
            -- Character bank tabs (containers 6-11) — skip in warband-only mode
            if not selfRef:IsWarbandBankOnly() then
                local unpurchasedChar = 0
                for tabIdx = 1, 6 do
                    local numSlots = C_Container.GetContainerNumSlots(tabIdx + 5)
                    if not numSlots or numSlots == 0 then
                        unpurchasedChar = unpurchasedChar + 1
                    end
                end
                if unpurchasedChar > 0 then
                    hints[#hints + 1] =
                        string.format("%d character Bank Tab%s", unpurchasedChar, unpurchasedChar == 1 and "" or "s")
                end
            end
            -- Warband bank tabs (containers 12-16)
            local unpurchasedWarband = 0
            for bag = 12, 16 do
                local numSlots = C_Container.GetContainerNumSlots(bag)
                if not numSlots or numSlots == 0 then
                    unpurchasedWarband = unpurchasedWarband + 1
                end
            end
            if unpurchasedWarband > 0 then
                hints[#hints + 1] =
                    string.format("%d Warband Bank Tab%s", unpurchasedWarband, unpurchasedWarband == 1 and "" or "s")
            end
            if #hints > 0 then
                selfRef:ChatHint("|cff4d99ff[Hint]|r Unpurchased: " .. table.concat(hints, ", "))
            end
        end

        -- Bag triage / EM_BANK_OPENED was fired up-front (see top of function)
        -- so the popup works even when replacement UIs close Blizzard's bank
        -- frame mid-snapshot. Nothing to do here after capacity is written.
    end

    ProcessChunk()
end

function EmpireManager:BANKFRAME_CLOSED()
    self.bankIsOpen = false
    self:SendMessage("EM_BANK_CLOSED")
end

-- Dispatcher for PLAYER_INTERACTION_MANAGER_FRAME_SHOW (replaces dead GUILDBANKFRAME events)
local INTERACTION_GUILD_BANK = 10
local INTERACTION_ACCOUNT_BANKER = 68
local INTERACTION_MAIL = 17
function EmpireManager:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(_, interactionType)
    if interactionType == INTERACTION_GUILD_BANK then
        self.guildBankIsOpen = true
        self._guildBankSnapshotDone = false
        self.MoveContexts.guildbank._currentTab = nil -- reset cached tab
        -- Refresh triage tab visibility + deposit button immediately so the UI
        -- reacts without waiting for the snapshot chain to finish.
        if self.triageFrame and self.triageFrame:IsShown() then
            if self.UpdateTriageTabButtons then
                self:UpdateTriageTabButtons()
            end
            if self.UpdateDepositBtnState then
                self:UpdateDepositBtnState()
            end
        end
        -- Fast path: tab metadata is often cached client-side, so try the
        -- snapshot immediately. SnapshotGuildBank returns early if data isn't
        -- ready; the GUILDBANK_UPDATE_TABS event handler will catch that case.
        self:SnapshotGuildBank()
        -- Safety net: if neither the immediate call nor the event populates
        -- tab data within 1.5s, force one more attempt.
        C_Timer.After(1.5, function()
            if self.guildBankIsOpen and not self._guildBankSnapshotDone then
                self:SnapshotGuildBank()
            end
        end)
    elseif interactionType == INTERACTION_ACCOUNT_BANKER then
        -- Warband bank opened (possibly remotely via Distance Inhibitor).
        -- other addons may suppress BANKFRAME_OPENED, so handle it here.
        if not self.bankIsOpen then
            self.bankIsOpen = true
            self:BANKFRAME_OPENED()
        end
    end
end
function EmpireManager:PLAYER_INTERACTION_MANAGER_FRAME_HIDE(_, interactionType)
    if interactionType == INTERACTION_GUILD_BANK then
        self.guildBankIsOpen = false
        self._guildBankSnapshotDone = false
        self:SendMessage("EM_BANK_CLOSED")
    elseif interactionType == INTERACTION_ACCOUNT_BANKER then
        if self.bankIsOpen then
            self.bankIsOpen = false
            self:SendMessage("EM_BANK_CLOSED")
        end
    elseif interactionType == INTERACTION_MAIL then
        if self.mailboxOpen then
            self.mailboxOpen = false
            self:SendMessage("EM_MAIL_CLOSED")
            C_Timer.After(0, function()
                self:SendMessage("EM_MAIL_BTN_UPDATE")
            end)
        end
    end
end

-- Fires when guild bank tab data is loaded from the server.
-- Registered permanently in OnEnable (like Blizzard's GuildBankFrame).
function EmpireManager:GUILDBANK_UPDATE_TABS()
    if not self.guildBankIsOpen then
        return
    end
    self:SnapshotGuildBank()
end

-- Idempotent guild bank snapshot — only runs once per open.
-- Queries each tab sequentially (waiting for GUILDBANKBAGSLOTS_CHANGED) so
-- item links are actually loaded before we count used slots. Without the
-- query, only the currently-visible tab reports data and all others read 0%.
function EmpireManager:SnapshotGuildBank()
    if self._guildBankSnapshotDone then
        return
    end

    local guildName = GetGuildInfo("player")
    if not guildName or guildName == "" then
        return
    end

    local numTabs = GetNumGuildBankTabs()
    if not numTabs or numTabs == 0 then
        return
    end -- data not ready yet

    self._guildBankSnapshotDone = true

    local cap = self.db.global.storageCapacity
    local selfRef = self

    local GUILD_BANK_TAB_SLOTS = 98 -- standard guild bank tab: 14 columns x 7 rows

    -- Build the list of viewable purchased tabs. A tab is purchased only when it has
    -- a non-empty name (numSlots is unreliable: returns bogus 100000 for purchased
    -- tabs and sometimes non-zero for unpurchased ones). isViewable filters out tabs
    -- this character lacks permission to see — querying those triggers "You don't
    -- have permission" spam and yields bogus 0/98 capacity data that would overwrite
    -- a valid snapshot taken from a character with full access.
    local purchasedTabs = {}
    local hiddenTabs = 0
    for tab = 1, numTabs do
        local name, _, isViewable = GetGuildBankTabInfo(tab)
        if name and name ~= "" then
            if isViewable then
                purchasedTabs[#purchasedTabs + 1] = tab
            else
                hiddenTabs = hiddenTabs + 1
            end
        end
    end

    if #purchasedTabs == 0 then
        if hiddenTabs > 0 then
            self:ChatVerbose(
                string.format(
                    "|cff4d99ff[Storage]|r Skipped guild bank snapshot for <%s>: no viewable tabs.",
                    guildName
                )
            )
        end
        self:SendMessage("EM_TRIAGE_REFRESH")
        return
    end

    -- Wipe stale tab entries only for tabs we can actually see; preserve data
    -- from other characters' snapshots for tabs hidden from this character.
    if not cap.guildbank[guildName] then
        cap.guildbank[guildName] = {}
    end
    local guildCap = cap.guildbank[guildName]
    for _, tab in ipairs(purchasedTabs) do
        guildCap[tab] = nil
    end

    local listener = self:AcquireListener()
    local finished = false
    local globalTimer
    local eventCount = 0

    local function FinishSnapshot()
        if finished then
            return
        end
        finished = true
        if globalTimer then
            globalTimer:Cancel()
            globalTimer = nil
        end
        selfRef:ReleaseListener(listener)

        local freeGB, totalGB = 0, 0
        for _, tabData in pairs(guildCap or {}) do
            local t = tabData.total or 0
            freeGB = freeGB + t - (tabData.used or 0)
            totalGB = totalGB + t
        end
        selfRef:ChatVerbose(
            string.format(
                "|cff4d99ff[Storage]|r Guild Bank %d tab%s, %d/%d free",
                #purchasedTabs,
                #purchasedTabs == 1 and "" or "s",
                freeGB,
                totalGB
            )
        )

        -- Chain: bag scan (deposits into GB) → bank scan (takeouts from GB) → open triage if needed.
        -- All scans share a single async slot so they must run sequentially.
        selfRef:RunTriageAsync(function(bagResults)
            -- Count bag items that need to go INTO this guild bank
            local depositCount = 0
            for _, r in ipairs(bagResults) do
                if r.category == "STASH" and r.routing and r.routing.destType == "guildbank" then
                    depositCount = depositCount + 1
                end
            end

            -- Now run bank scan to find items to take OUT + misplaced notifications
            selfRef:RunBankTriageAsync(function(bankResults)
                local takeoutCount = 0
                local reorganizeCount = 0
                for _, r in ipairs(bankResults) do
                    if r.item.bankType == "guildbank" then
                        if r.category == "TAKEOUT" then
                            takeoutCount = takeoutCount + 1
                        elseif r.category == "STASH" then
                            reorganizeCount = reorganizeCount + 1
                        end
                    end
                end

                selfRef:SendMessage("EM_GUILDBANK_OPENED", depositCount, takeoutCount + reorganizeCount)
            end)
        end)

        selfRef:SendMessage("EM_TRIAGE_REFRESH")
    end

    -- Count filled slots on one tab; event doesn't say which tab fired, so
    -- we re-scan all of them after each event (state is cumulative).
    local function ScanTab(tab)
        local _, _, _, _, numSlots = GetGuildBankTabInfo(tab)
        if not numSlots or numSlots <= 0 or numSlots > GUILD_BANK_TAB_SLOTS then
            numSlots = GUILD_BANK_TAB_SLOTS
        end
        local used = 0
        for slot = 1, numSlots do
            if GetGuildBankItemLink(tab, slot) then
                used = used + 1
            end
        end
        guildCap[tab] = { total = numSlots, used = used }
    end

    local function ScanAllTabs()
        for _, tab in ipairs(purchasedTabs) do
            ScanTab(tab)
        end
    end

    -- Event handler (registered before any query so nothing is missed).
    listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
    listener:SetScript("OnEvent", function()
        if finished then
            return
        end
        eventCount = eventCount + 1
        ScanAllTabs()
        if eventCount >= #purchasedTabs then
            FinishSnapshot()
        end
    end)

    -- Global fallback: if some events never fire (cached tabs, empty tabs),
    -- finish after 2s no matter what. Scan-all runs regardless so capacities
    -- reflect whatever the client already has.
    globalTimer = C_Timer.NewTimer(2.0, function()
        globalTimer = nil
        if finished then
            return
        end
        ScanAllTabs()
        FinishSnapshot()
    end)

    -- Fire all queries back-to-back. Server is expected to respond per tab.
    for _, tab in ipairs(purchasedTabs) do
        QueryGuildBankTab(tab)
    end
end

function EmpireManager:MERCHANT_SHOW()
    self:SendMessage("EM_MERCHANT_SHOW")
end

function EmpireManager:MERCHANT_CLOSED()
    self:SendMessage("EM_MERCHANT_CLOSED")
end

function EmpireManager:MAIL_SHOW()
    self.mailboxOpen = true
    -- Hook mail tab switches so the Mail button enables/disables live
    if not self._mailTabHooked and type(MailFrameTab_OnClick) == "function" then
        hooksecurefunc("MailFrameTab_OnClick", function()
            self:SendMessage("EM_MAIL_BTN_UPDATE")
        end)
        self._mailTabHooked = true
    end

    self:SendMessage("EM_MAIL_SHOW")

    -- Deferred update: MailFrame may not be visible yet when our handler fires
    C_Timer.After(0, function()
        self:SendMessage("EM_MAIL_BTN_UPDATE")
    end)
end

function EmpireManager:MAIL_CLOSED()
    self.mailboxOpen = false
    self:SendMessage("EM_MAIL_CLOSED")
end

function EmpireManager:PLAYER_LEVEL_UP(_, newLevel)
    local guid = self.playerGUID
    local entry = guid and self.db.global.registry[guid]
    if not entry then
        return
    end
    entry.level = tonumber(newLevel) or UnitLevel("player")
    if self.RefreshVisibleRows then
        self:RefreshVisibleRows()
    end
end

function EmpireManager:PLAYER_MONEY()
    local guid = self.playerGUID
    local entry = guid and self.db.global.registry[guid]
    if not entry then
        return
    end
    entry.gold = GetMoney()
    if self.RefreshVisibleRows then
        self:RefreshVisibleRows()
    end
end

function EmpireManager:PLAYER_EQUIPMENT_CHANGED()
    local guid = self.playerGUID
    local entry = guid and self.db.global.registry[guid]
    if not entry then
        return
    end
    local newIlvl = select(2, GetAverageItemLevel())
    if newIlvl and newIlvl ~= entry.ilvl then
        entry.ilvl = newIlvl
        if self.RefreshVisibleRows then
            self:RefreshVisibleRows()
        end
    end
end

function EmpireManager:PLAYER_ENTERING_WORLD()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then return end

    -- Trust the game over imported/edited values: level can be wrong (typo, post-import
    -- ding, or out-of-date import). Overwrite unconditionally, even if smaller.
    local liveLevel = UnitLevel("player")
    if liveLevel and liveLevel > 0 then
        entry.level = liveLevel
    end

    -- Snapshot location for global registry
    if not entry.mapPinned then
        entry.zone = GetRealZoneText()
        entry.subZone = GetSubZoneText()
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            entry.mapID = mapID
            local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
            if ok and pos then
                entry.mapX, entry.mapY = pos:GetXY()
            end
        end
    end
end

function EmpireManager:ZONE_CHANGED_NEW_AREA()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if entry and not entry.mapPinned then
        entry.zone = GetRealZoneText()
        entry.subZone = GetSubZoneText()
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            entry.mapID = mapID
            local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
            if ok and pos then
                entry.mapX, entry.mapY = pos:GetXY()
            end
        end
    end
end

-- Snapshot exact logout location (PEW/ZCNA don't fire when moving within a zone).
function EmpireManager:PLAYER_LOGOUT()
    local guid = self.playerGUID
    local entry = guid and self.db.global.registry[guid]
    if entry and not entry.mapPinned then
        entry.zone = GetRealZoneText()
        entry.subZone = GetSubZoneText()
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            entry.mapID = mapID
            local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
            if ok and pos then
                entry.mapX, entry.mapY = pos:GetXY()
            end
        end
    end
end

function EmpireManager:TIME_PLAYED_MSG(_, totalTime, levelTime)
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if entry then
        entry.playedTotal = totalTime -- seconds
        entry.playedLevel = levelTime -- seconds
    end
    -- Re-register TIME_PLAYED_MSG on chat frames we silenced for this request.
    self:RestoreTimePlayedChatFrames()
end

-- Suppress chat output for RequestTimePlayed(). Blizzard's chat handler writes the
-- "Total time played" lines directly via TIME_PLAYED_MSG (bypassing CHAT_MSG_SYSTEM),
-- so a chat filter does nothing. Instead, temporarily unregister the event from each
-- chat frame around our request and re-register after our own handler runs.
function EmpireManager:RequestTimePlayedSilent()
    local frames = {}
    for i = 1, NUM_CHAT_WINDOWS do
        local f = _G["ChatFrame" .. i]
        if f and f.IsEventRegistered and f:IsEventRegistered("TIME_PLAYED_MSG") then
            f:UnregisterEvent("TIME_PLAYED_MSG")
            frames[#frames + 1] = f
        end
    end
    self._silentTimePlayedFrames = frames
    RequestTimePlayed()
end

function EmpireManager:RestoreTimePlayedChatFrames()
    local frames = self._silentTimePlayedFrames
    if not frames then return end
    for _, f in ipairs(frames) do
        if f and f.RegisterEvent then
            f:RegisterEvent("TIME_PLAYED_MSG")
        end
    end
    self._silentTimePlayedFrames = nil
end

function EmpireManager:SnapshotProfessions(entry)
    -- Preserve existing expansionSkills (populated at TRADE_SKILL_SHOW)
    local oldByName = {}
    if entry.professions then
        for _, p in ipairs(entry.professions) do
            oldByName[p.name] = p
        end
    end

    local profs = {}
    local prof1, prof2 = GetProfessions()
    -- Check each slot individually: ipairs({prof1, prof2}) would skip prof2 if prof1 is nil
    for _, idx in pairs({ prof1, prof2 }) do
        if idx then
            local name, _, skillLevel, maxSkillLevel, _, _, skillLineID = GetProfessionInfo(idx)
            if name then
                local old = oldByName[name]
                -- Prefer the newest expansion skill snapshot (from opening the profession window)
                -- over GetProfessionInfo, which returns overall tier rank (1/100 style).
                if old and old.expansionSkills and #old.expansionSkills > 0 then
                    local newest = old.expansionSkills[#old.expansionSkills]
                    skillLevel = newest.skill
                    maxSkillLevel = newest.maxSkill
                end
                table.insert(profs, {
                    name = name,
                    skill = skillLevel,
                    maxSkill = maxSkillLevel,
                    skillLineID = skillLineID,
                    expansionSkills = old and old.expansionSkills or nil,
                })
            end
        end
    end
    entry.professions = profs
end

-- Snapshot per-expansion skill breakdown for the currently open profession.
-- Only callable during TRADE_SKILL_SHOW (C_TradeSkillUI requires an open window).
function EmpireManager:SnapshotExpansionSkills(entry)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllProfessionTradeSkillLines then
        return
    end
    local skillLines = C_TradeSkillUI.GetAllProfessionTradeSkillLines()
    if not skillLines or #skillLines == 0 then
        return
    end

    -- Identify which profession is currently open
    local baseProfInfo = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    if not baseProfInfo or not baseProfInfo.professionName then
        return
    end
    local profName = baseProfInfo.professionName

    -- Find matching entry in entry.professions
    if not entry.professions then
        return
    end
    local profEntry
    for _, p in ipairs(entry.professions) do
        if p.name == profName then
            profEntry = p
            break
        end
    end
    if not profEntry then
        return
    end

    -- Build per-expansion skill map keyed by numeric expansionID (locale-proof).
    -- `GetAllProfessionTradeSkillLines` can return multiple lines per expansion
    -- (parent + child), so dedupe keeping the highest skill. Skip entries with
    -- no valid expansionID.
    local byExpId = {}
    for _, lineID in ipairs(skillLines) do
        local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(lineID)
        if
            info
            and info.skillLevel
            and info.maxSkillLevel
            and info.maxSkillLevel > 0
            and info.expansionID
            and info.expansionID >= 0
        then
            local existing = byExpId[info.expansionID]
            if not existing or info.skillLevel > existing.skill then
                byExpId[info.expansionID] = {
                    skillLineID = lineID,
                    expansionID = info.expansionID,
                    expansionName = info.expansionName, -- may be localized; tooltip relabels
                    skill = info.skillLevel,
                    maxSkill = info.maxSkillLevel,
                }
            end
        end
    end

    local expSkills = {}
    for _, e in pairs(byExpId) do
        expSkills[#expSkills + 1] = e
    end
    table.sort(expSkills, function(a, b)
        return (a.expansionID or 999) < (b.expansionID or 999)
    end)
    profEntry.expansionSkills = expSkills

    -- Promote newest expansion skill to the top-level skill/maxSkill so UI shows
    -- e.g. 6/105 instead of the overall tier rank (1/100) from GetProfessionInfo.
    if #expSkills > 0 then
        local newest = expSkills[#expSkills]
        profEntry.skill = newest.skill
        profEntry.maxSkill = newest.maxSkill
    end
end

-- Count storage assignments that reference a given character GUID.
function EmpireManager:CountDependentAssignments(guid)
    if not guid or guid == "self" then
        return 0
    end
    local n = 0
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.type == "charbank" and asn.char == guid then
            n = n + 1
        end
    end
    return n
end

-- Return the list of storage assignments that reference a given character GUID.
function EmpireManager:GetDependentAssignments(guid)
    local out = {}
    if not guid or guid == "self" then
        return out
    end
    for i, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.type == "charbank" and asn.char == guid then
            out[#out + 1] = { index = i, asn = asn }
        end
    end
    return out
end

StaticPopupDialogs["EM_PURGE_CHAR"] = {
    text = "%s",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self)
        local guid = self.data and self.data.guid
        if guid then
            EmpireManager:PurgeByGUID(guid)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EM_WIPE_CONFIRM"] = {
    text = "%s",
    button1 = YES,
    button2 = CANCEL,
    OnAccept = function(self)
        local target = self.data and self.data.target
        if target then
            EmpireManager:PerformWipe(target)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

function EmpireManager:ConfirmWipe(target)
    local text
    if target == "chars" then
        text = "Wipe the entire character registry?\n\n|cffff4444This cannot be undone.|r"
    elseif target == "rules" then
        text = "Wipe all storage rules?\n\n|cffff4444This cannot be undone.|r"
    elseif target == "all" then
        text = "Wipe |cffff4444both|r storage rules and the character registry?\n\n|cffff4444This cannot be undone.|r"
    else
        return
    end
    local dialog = StaticPopup_Show("EM_WIPE_CONFIRM", text)
    if dialog then
        dialog.data = { target = target }
    end
end

function EmpireManager:PerformWipe(target)
    if target == "chars" then
        self.db.global.registry = {}
        self:ChatMsg("|cffff4444Wiped character registry.|r", true)
        self:SendMessage("EM_DASHBOARD_REFRESH")
    elseif target == "rules" then
        self.db.global.storageAssignments = {}
        self:ChatMsg("|cffff4444Wiped storage rules.|r", true)
        self:InvalidateStorageCache()
        if EmpireManagerFrame and EmpireManagerFrame.StoragePage and EmpireManagerFrame.StoragePage._nativeInit then
            EmpireManagerFrame.StoragePage:Refresh()
        end
    elseif target == "all" then
        self.db.global.storageAssignments = {}
        self.db.global.registry = {}
        self:ChatMsg("|cffff4444Wiped all storage rules and character registry.|r", true)
        self:InvalidateStorageCache()
        self:SendMessage("EM_DASHBOARD_REFRESH")
        if EmpireManagerFrame and EmpireManagerFrame.StoragePage and EmpireManagerFrame.StoragePage._nativeInit then
            EmpireManagerFrame.StoragePage:Refresh()
        end
    end
end

-- Build the confirmation-popup text for a given character GUID.
function EmpireManager:BuildPurgeConfirmText(guid)
    local entry = self.db.global.registry[guid]
    if not entry then
        return nil
    end
    local coloredName = self:ClassColoredName(entry)
    local realm = entry.realm or "?"
    local deps = self:GetDependentAssignments(guid)
    local depCount = #deps
    local lines = { string.format("Remove %s - %s from roster?", coloredName, realm) }
    if depCount > 0 then
        lines[#lines + 1] = string.format(
            "\n|cffff8800%d storage rule%s|r reference this character and will be |cffff4444DELETED|r:",
            depCount,
            depCount == 1 and "" or "s"
        )
        local maxShown = 6
        for i = 1, math.min(depCount, maxShown) do
            local dep = deps[i]
            local asn = dep.asn
            local pInfo = self.PROF_INFO_BY_KEY and self.PROF_INFO_BY_KEY[asn.profession]
            local profName
            if pInfo then
                local profColor = string.format("%02x%02x%02x", pInfo.r * 255, pInfo.g * 255, pInfo.b * 255)
                profName = "|cff" .. profColor .. (pInfo.label or asn.profession) .. "|r"
            else
                profName = asn.profession or "?"
            end
            lines[#lines + 1] = string.format("Rule #%d %s", dep.index, profName)
        end
        if depCount > maxShown then
            lines[#lines + 1] = string.format("...and %d more", depCount - maxShown)
        end
        lines[#lines + 1] = "To keep, cancel and edit in the Storage tab."
    end
    lines[#lines + 1] = "\nCharacter will be added to the Character Blacklist."
    return table.concat(lines, "\n")
end

function EmpireManager:ConfirmPurgeByGUID(guid)
    local text = self:BuildPurgeConfirmText(guid)
    if not text then
        return
    end
    local dialog = StaticPopup_Show("EM_PURGE_CHAR", text)
    if dialog then
        dialog.data = { guid = guid }
    end
end

function EmpireManager:PurgeCharacter(charName)
    local needle = charName:lower()
    local found = {}
    for guid, entry in pairs(self.db.global.registry) do
        if (entry.name or ""):lower() == needle then
            found[#found + 1] = { guid = guid, entry = entry }
        end
    end

    if #found == 0 then
        self:ChatMsg(string.format("No character named '%s' found in registry.", charName), true)
        return
    end

    for _, match in ipairs(found) do
        self:ConfirmPurgeByGUID(match.guid)
    end
end

-------------------------------------------------------------------------------
-- Registry Export / Import
-------------------------------------------------------------------------------

-- Export the character registry in the same format ImportRegistryFromText expects.
function EmpireManager:ExportRegistry()
    local reg = self.db.global.registry or {}
    local lines = {
        "# EmpireManager Registry v1",
        "# name;realm;class;race;faction;level;guild;ilvl;spec;professions;sortOrder(optional)",
    }

    -- Collect and sort entries by name-realm for stable output
    local entries = {}
    for _, entry in pairs(reg) do
        entries[#entries + 1] = entry
    end
    table.sort(entries, function(a, b)
        local ka = ((a.name or "") .. "-" .. (a.realm or "")):lower()
        local kb = ((b.name or "") .. "-" .. (b.realm or "")):lower()
        return ka < kb
    end)

    for _, entry in ipairs(entries) do
        local profStr = ""
        if entry.professions and #entry.professions > 0 then
            local profParts = {}
            for _, p in ipairs(entry.professions) do
                local s = (p.name or "Unknown") .. ":" .. (p.skill or 0) .. "/" .. (p.maxSkill or 0)
                if p.expansionSkills and #p.expansionSkills > 0 then
                    local tierParts = {}
                    for _, t in ipairs(p.expansionSkills) do
                        tierParts[#tierParts + 1] = (t.expansionName or "?")
                            .. "="
                            .. (t.skill or 0)
                            .. "/"
                            .. (t.maxSkill or 0)
                    end
                    s = s .. "[" .. table.concat(tierParts, ",") .. "]"
                end
                profParts[#profParts + 1] = s
            end
            profStr = table.concat(profParts, ",")
        end

        local classLabel = entry.class and self.CLASS_NAMES[entry.class] or entry.class or ""
        local sortOrderStr = (entry.sortOrder and entry.sortOrder > 0) and tostring(entry.sortOrder) or ""
        lines[#lines + 1] = string.format(
            "%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s",
            entry.name or "",
            entry.realm or "",
            classLabel,
            entry.race or "",
            entry.faction or "",
            entry.level or 0,
            entry.guild or "",
            entry.ilvl or "",
            entry.spec or "",
            profStr,
            sortOrderStr
        )
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Parse and apply a registry import string.
-- Format (Registry v1):
--   # EmpireManager Registry v1
--   # name;realm;class;race;faction;level;guild;ilvl;spec;professions(name:skill/max[tier=s/m|...])
--   Zarenna;Silvermoon;Mage;Blood Elf;Horde;80;MyGuild;620;Arcane;Alchemy:300/300[Classic=75/300|Midnight=150/150],Herbalism:150/300
--
-- Only seeds fields that are missing or outdated. Never overwrites gold, bags,
-- assignments — those only come from in-game snapshots.
function EmpireManager:ImportRegistryFromText(text, autoAssign)
    if not text or text:match("^%s*$") then
        return 0, "No text to import"
    end

    -- Validate header (accept v1 or v2)
    if not text:find("# EmpireManager Registry v", 1, true) then
        return 0, "Not a valid EmpireManager Registry export (missing header)"
    end

    -- Build name+realm -> guid reverse lookup (case-insensitive)
    local nameRealmToGUID = {}
    for guid, entry in pairs(self.db.global.registry) do
        local key = ((entry.name or "") .. "-" .. (entry.realm or "")):lower()
        nameRealmToGUID[key] = guid
    end

    -- Build blacklist lookup by name-realm (case-insensitive)
    local blacklistedNames = {}
    for _, label in pairs(self.db.global.charBlacklist or {}) do
        local blName, blRealm = label:match("^(.+) %- (.+)$")
        if blName then
            blacklistedNames[(blName .. "-" .. blRealm):lower()] = true
        end
    end

    local imported = 0
    local updated = 0
    local skipped = 0

    for line in text:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local parts = {}
            for f in (line .. ";"):gmatch("([^;]*);") do
                parts[#parts + 1] = f:match("^%s*(.-)%s*$")
            end

            local name = parts[1] or ""
            local realm = parts[2] or ""
            local classRaw = parts[3] or ""
            local class = self.CLASS_TOKENS[classRaw:lower()] or classRaw:upper():gsub("%s+", "")
            local race = parts[4] or ""
            local faction = parts[5] or ""
            local level = tonumber(parts[6]) or 0
            local guild = parts[7] or ""
            local ilvl = tonumber(parts[8]) or nil
            local spec = parts[9] or ""
            local profStr = parts[10] or ""
            local sortOrderRaw = tonumber(parts[11])
            local sortOrder = nil
            if
                sortOrderRaw
                and sortOrderRaw == math.floor(sortOrderRaw)
                and sortOrderRaw > 0
                and sortOrderRaw <= 99
            then
                sortOrder = sortOrderRaw
            end

            -- Validate class (must exist in RAID_CLASS_COLORS or be empty)
            if class ~= "" and not (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]) then
                class = ""
            end
            -- Validate faction
            if faction ~= "" and faction ~= "Alliance" and faction ~= "Horde" and faction ~= "Neutral" then
                faction = ""
            end
            -- Clamp level and ilvl
            local maxLvl = GetMaxLevelForExpansionLevel and GetMaxLevelForExpansionLevel(GetExpansionLevel()) or 90
            if level < 0 then
                level = 0
            elseif level > maxLvl then
                level = maxLvl
            end
            if ilvl and (ilvl < 0 or ilvl > 999) then
                ilvl = nil
            end

            if name ~= "" and realm ~= "" then
                -- Parse professions: "Alchemy:150/300[Classic=75/300|Midnight=150/150],Herbalism:100/300"
                local profs = {}
                if profStr ~= "" then
                    -- Split on commas that are NOT inside brackets
                    local profEntries = {}
                    local depth, start = 0, 1
                    for i = 1, #profStr do
                        local c = profStr:sub(i, i)
                        if c == "[" then
                            depth = depth + 1
                        elseif c == "]" then
                            depth = depth - 1
                        elseif c == "," and depth == 0 then
                            profEntries[#profEntries + 1] = profStr:sub(start, i - 1)
                            start = i + 1
                        end
                    end
                    profEntries[#profEntries + 1] = profStr:sub(start)

                    for _, entry in ipairs(profEntries) do
                        entry = entry:match("^%s*(.-)%s*$")
                        -- Split off optional [tiers] bracket
                        local mainPart, tierBracket = entry:match("^(.-)(%[.+%])$")
                        if not mainPart or mainPart == "" then
                            mainPart = entry
                        end
                        -- mainPart can be "Name:skill/max" OR just "Name" (skill optional)
                        local profName, skillStr, maxStr = mainPart:match("^(.+):(%d*)/(%d*)$")
                        if not profName then
                            profName = mainPart
                            skillStr, maxStr = "", ""
                        end
                        if profName and profName ~= "" then
                            local profEntry = {
                                name = profName,
                                skill = tonumber(skillStr) or 0,
                                maxSkill = tonumber(maxStr) or 0,
                            }
                            -- Parse per-expansion tiers from bracket: [TierName=skill/max,...]
                            -- Accepts ',' (current), ';' and '|' (backward compatibility).
                            -- Battle.net exports tier names with the profession suffix
                            -- (e.g. "Kul Tiran Herbalism") - strip it so we store
                            -- just the expansion name ("Kul Tiran"), matching the
                            -- format SnapshotExpansionSkills writes from in-game.
                            -- Skip tiers whose name doesn't resolve to a known
                            -- expansion (typos, future expansions we haven't mapped).
                            if tierBracket then
                                local expLookup = {}
                                for _, info in ipairs(EmpireManager.EXPANSION_DISPLAY or {}) do
                                    expLookup[info.label:lower()] = info.expansionID
                                    if info.apiNames then
                                        for _, n in ipairs(info.apiNames) do
                                            expLookup[n:lower()] = info.expansionID
                                        end
                                    end
                                end
                                local expSkills = {}
                                local inner = tierBracket:match("^%[(.+)%]$")
                                local profSuffix = profEntry.name and (" " .. profEntry.name) or nil
                                if inner then
                                    for tierEntry in inner:gmatch("[^|;,]+") do
                                        local tName, tSkill, tMax = tierEntry:match("^(.-)=(%d+)/(%d+)$")
                                        if tName then
                                            tName = tName:match("^%s*(.-)%s*$") -- trim
                                            if profSuffix and tName:sub(-#profSuffix) == profSuffix then
                                                tName = tName:sub(1, -#profSuffix - 1)
                                            end
                                            local expID = expLookup[tName:lower()]
                                            if tName ~= "" and expID then
                                                expSkills[#expSkills + 1] = {
                                                    expansionID = expID,
                                                    expansionName = tName,
                                                    skill = tonumber(tSkill) or 0,
                                                    maxSkill = tonumber(tMax) or 0,
                                                }
                                            end
                                        end
                                    end
                                end
                                if #expSkills > 0 then
                                    profEntry.expansionSkills = expSkills
                                end
                            end
                            profs[#profs + 1] = profEntry
                        end
                    end
                end

                local key = (name .. "-" .. realm):lower()
                if blacklistedNames[key] then
                    skipped = skipped + 1
                else
                    local existingGUID = nameRealmToGUID[key]

                    if existingGUID then
                        -- Update existing entry with API data (fill in blanks or refresh)
                        local entry = self.db.global.registry[existingGUID]
                        if class ~= "" and not (RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]) then
                            entry.class = class
                        end
                        if level > (entry.level or 0) then
                            entry.level = level
                        end
                        if ilvl and (not entry.ilvl or ilvl > entry.ilvl) then
                            entry.ilvl = ilvl
                        end
                        if spec ~= "" and not entry.spec then
                            entry.spec = spec
                        end
                        if guild ~= "" and not entry.guild then
                            entry.guild = guild
                        end
                        if #profs > 0 then
                            if not entry.professions or #entry.professions == 0 then
                                entry.professions = profs
                            else
                                -- Merge expansion skills into existing profession entries
                                for _, importedProf in ipairs(profs) do
                                    if importedProf.expansionSkills then
                                        for _, existingProf in ipairs(entry.professions) do
                                            if existingProf.name == importedProf.name then
                                                existingProf.expansionSkills = importedProf.expansionSkills
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                        end
                        if sortOrder and (entry.sortOrder or 0) == 0 then
                            self:ResolveSortConflict(existingGUID, sortOrder)
                            entry.sortOrder = sortOrder
                        end
                        if autoAssign then
                            self:AutoAssignRoles(entry, existingGUID)
                        end
                        updated = updated + 1
                    else
                        -- Create a new stub entry (will be fully snapshotted when the char logs in)
                        local stubGUID = "API-" .. name .. "-" .. realm
                        local entry = {
                            name = name,
                            realm = realm,
                            class = class,
                            race = race,
                            faction = faction,
                            level = level,
                            guild = guild,
                            ilvl = ilvl,
                            spec = spec,
                            professions = #profs > 0 and profs or nil,
                            lastSeen = 0,
                            _stub = true, -- marks as API-seeded, not yet in-game confirmed
                        }
                        self.db.global.registry[stubGUID] = entry
                        if sortOrder then
                            self:ResolveSortConflict(stubGUID, sortOrder)
                            entry.sortOrder = sortOrder
                        end
                        if autoAssign then
                            self:AutoAssignRoles(entry, stubGUID)
                        end
                        imported = imported + 1
                    end
                end -- blacklist check
            end -- name ~= "" and realm ~= ""
        end
    end

    if imported > 0 or updated > 0 then
        self:SendMessage("EM_DASHBOARD_REFRESH")
    end
    return imported, updated, skipped
end

function EmpireManager:PurgeByGUID(guid)
    local entry = self.db.global.registry[guid]
    if not entry then
        return
    end

    local name = entry.name or "?"
    local realm = entry.realm or "?"

    local removedRules = 0
    local assignments = self.db.global.storageAssignments
    if assignments then
        for i = #assignments, 1, -1 do
            local asn = assignments[i]
            if asn and asn.type == "charbank" and asn.char == guid then
                table.remove(assignments, i)
                removedRules = removedRules + 1
            end
        end
    end

    self.db.global.registry[guid] = nil
    if not self.db.global.charBlacklist then
        self.db.global.charBlacklist = {}
    end
    local label = name .. " - " .. realm
    local alreadyBlacklisted = false
    for existingGuid, existingLabel in pairs(self.db.global.charBlacklist) do
        if existingGuid == guid or existingLabel == label then
            alreadyBlacklisted = true
            break
        end
    end
    if not alreadyBlacklisted then
        self.db.global.charBlacklist[guid] = label
        self:ChatMsg(string.format("Removed %s - %s from roster and added to character blacklist.", name, realm), true)
    else
        self:ChatMsg(string.format("Removed %s - %s from roster (already on character blacklist).", name, realm), true)
    end
    if removedRules > 0 then
        self:ChatMsg(
            string.format(
                "Deleted %d storage rule%s referencing this character.",
                removedRules,
                removedRules == 1 and "" or "s"
            ),
            true
        )
        if self.InvalidateStorageCache then
            self:InvalidateStorageCache()
        end
    end

    -- Refresh char blacklist window if it's open so the new entry shows up.
    if self.charBlacklistFrame and self.charBlacklistFrame:IsShown() and self.RefreshCharBlacklistDisplay then
        self:RefreshCharBlacklistDisplay()
    end

    -- Close sidecar if it was showing this character
    if self.sidecarGUID == guid then
        self:CloseSidecar()
    end

    self:SendMessage("EM_DASHBOARD_REFRESH")
    if EmpireManagerFrame and EmpireManagerFrame.StoragePage and EmpireManagerFrame.StoragePage._nativeInit then
        EmpireManagerFrame.StoragePage:Refresh()
    end
end
