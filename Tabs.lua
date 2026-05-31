-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")
-------------------------------------------------------------------------------
-- Storage Import / Export
-------------------------------------------------------------------------------

function EmpireManager:ExportStorageAssignments()
    local assignments = self.db.global.storageAssignments or {}
    if #assignments == 0 then
        return "# EmpireManager Storage Rules v1\n# category;type;tabs;char;guild;expansions;subcategories;realm\n# (no rules configured)\n"
    end

    -- Build GUID -> "Name-Realm" lookup
    local guidToName = {}
    for guid, entry in pairs(self.db.global.registry) do
        guidToName[guid] = (entry.name or "Unknown") .. "-" .. (entry.realm or "Unknown")
    end

    local lines = {
        "# EmpireManager Storage Rules v1",
        "# category;type;tabs;char;guild;expansions;subcategories;realm",
    }
    for _, asn in ipairs(assignments) do
        if type(asn) == "table" then
            local tabStr = ""
            if type(asn.tabs) == "table" and #asn.tabs > 0 then
                local parts = {}
                for _, t in ipairs(asn.tabs) do
                    parts[#parts + 1] = tostring(t)
                end
                tabStr = table.concat(parts, ",")
            end

            local charStr = ""
            if asn.type ~= "guildbank" and asn.char and asn.char ~= "" then
                charStr = guidToName[asn.char] or tostring(asn.char)
            end

            local guildStr = ""
            local realmStr = ""
            if type(asn.guild) == "string" and asn.guild ~= "" then
                guildStr = asn.guild
                if type(asn.realm) == "string" and asn.realm ~= "" then
                    realmStr = asn.realm
                end
            end

            local expStr = ""
            if type(asn.expansions) == "table" and #asn.expansions > 0 then
                local parts = {}
                for _, eid in ipairs(asn.expansions) do
                    parts[#parts + 1] = tostring(eid)
                end
                expStr = table.concat(parts, ",")
            end

            local subcatStr = ""
            if type(asn.subcategories) == "table" and #asn.subcategories > 0 then
                local parts = {}
                for _, sc in ipairs(asn.subcategories) do
                    parts[#parts + 1] = tostring(sc)
                end
                subcatStr = table.concat(parts, ",")
            end

            lines[#lines + 1] = string.format(
                "%s;%s;%s;%s;%s;%s;%s;%s",
                tostring(asn.profession or ""),
                tostring(asn.type or ""),
                tabStr,
                charStr,
                guildStr,
                expStr,
                subcatStr,
                realmStr
            )
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

function EmpireManager:ImportStorageAssignments(text)
    if not text or text:match("^%s*$") then
        return nil, nil, "No text to import"
    end

    -- Build "Name-Realm" -> GUID reverse lookup
    local nameToGUID = {}
    for guid, entry in pairs(self.db.global.registry) do
        local nameRealm = (entry.name or "Unknown") .. "-" .. (entry.realm or "Unknown")
        nameToGUID[nameRealm] = guid
        -- Also store lowercase for case-insensitive matching
        nameToGUID[nameRealm:lower()] = guid
    end

    local readyRules = {}
    local unresolvedRules = {}
    local skippedCount = 0

    for line in text:gmatch("[^\r\n]+") do
        -- Skip comments and blanks
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local parts = {}
            for f in (line .. ";"):gmatch("([^;]*);") do
                parts[#parts + 1] = f:match("^%s*(.-)%s*$") -- trim whitespace
            end

            local category = parts[1] or ""
            local bankType = parts[2] or ""
            local tabStr = parts[3] or ""
            local charStr = parts[4] or ""
            local guildStr = parts[5] or ""
            local expStr = parts[6] or ""
            local subcatStr = parts[7] or ""
            -- Column 8 (realm) was added later. Old exports omit it and fall
            -- back to the registry lookup below for cross-realm guilds.
            local realmStr = parts[8] or ""

            -- Cap free-text fields so a malformed export can't break the UI / chat
            if #category > 32 then category = category:sub(1, 32) end
            if #bankType > 32 then bankType = bankType:sub(1, 32) end
            if #charStr > 96 then charStr = charStr:sub(1, 96) end
            if #guildStr > 64 then guildStr = guildStr:sub(1, 64) end
            if #tabStr > 64 then tabStr = tabStr:sub(1, 64) end
            if #expStr > 128 then expStr = expStr:sub(1, 128) end
            if #subcatStr > 256 then subcatStr = subcatStr:sub(1, 256) end

            -- Validate category (professions + storage categories)
            if not self.PROF_INFO_BY_KEY[category] then
                skippedCount = skippedCount + 1
                self:ChatMsg("Import warning: skipped unknown category '" .. category .. "'.", true)
            -- Validate bank type
            elseif bankType ~= "warbandbank" and bankType ~= "guildbank" and bankType ~= "charbank" then
                skippedCount = skippedCount + 1
                self:ChatMsg(string.format(
                    "Import warning: skipped rule '%s' - unknown bank type '%s'.",
                    category, bankType
                ), true)
            else
                -- Parse tabs (valid: 1-7 for guild, 1-6 for charbank, 1-5 for warband)
                local tabs = nil
                if tabStr ~= "" then
                    tabs = {}
                    local invalid = {}
                    local maxTab = (bankType == "charbank") and 6 or (bankType == "warbandbank") and 5 or 7
                    for t in tabStr:gmatch("[^,]+") do
                        local n = tonumber(t)
                        if n and n >= 1 and n <= maxTab then
                            tabs[#tabs + 1] = n
                        else
                            invalid[#invalid + 1] = t
                        end
                    end

                    -- Drop tabs that don't exist on the destination (only when we
                    -- have a capacity snapshot; absence of snapshot just means the
                    -- bank hasn't been opened on this machine yet).
                    local missing = {}
                    if #tabs > 0 then
                        local cap = self.db.global.storageCapacity or {}
                        local capSection
                        if bankType == "warbandbank" then
                            capSection = cap.warbandbank
                        elseif bankType == "guildbank" and guildStr ~= "" then
                            local realm = realmStr ~= "" and realmStr or nil
                            if not realm then
                                for _, entry in pairs(self.db.global.registry) do
                                    if entry.guild == guildStr and entry.guildRealm and entry.guildRealm ~= "" then
                                        realm = entry.guildRealm
                                        break
                                    end
                                end
                            end
                            local key = realm and self:GuildKey(guildStr, realm)
                            capSection = key and cap.guildbank and cap.guildbank[key]
                        elseif bankType == "charbank" and charStr ~= "" then
                            local guid = nameToGUID[charStr] or nameToGUID[charStr:lower()]
                            if guid then
                                capSection = cap.charbank and cap.charbank[guid]
                            end
                        end
                        if capSection and next(capSection) then
                            local kept = {}
                            for _, n in ipairs(tabs) do
                                if capSection[n] then
                                    kept[#kept + 1] = n
                                else
                                    missing[#missing + 1] = tostring(n)
                                end
                            end
                            tabs = kept
                        end
                    end

                    if #invalid > 0 or #missing > 0 then
                        local bankLabel = (bankType == "charbank") and "Character Bank"
                            or (bankType == "warbandbank") and "Warband Bank"
                            or "Guild Bank"
                        local dest
                        if bankType == "guildbank" and guildStr ~= "" then
                            dest = bankLabel .. " <" .. guildStr .. ">"
                        elseif bankType == "charbank" and charStr ~= "" then
                            dest = bankLabel .. " (" .. charStr .. ")"
                        else
                            dest = bankLabel
                        end
                        local dropped = {}
                        if #invalid > 0 then
                            dropped[#dropped + 1] = "invalid: " .. table.concat(invalid, ",")
                        end
                        if #missing > 0 then
                            dropped[#dropped + 1] = "not purchased: " .. table.concat(missing, ",")
                        end
                        if #tabs == 0 then
                            tabs = nil
                            self:ChatMsg(string.format(
                                "Import warning: %s rule '%s' had no usable tabs (%s); using AnyTab.",
                                dest, category, table.concat(dropped, "; ")
                            ), true)
                        else
                            local nDropped = #invalid + #missing
                            self:ChatMsg(string.format(
                                "Import warning: %s rule '%s' dropped %d tab%s (%s).",
                                dest, category, nDropped, nDropped == 1 and "" or "s", table.concat(dropped, "; ")
                            ), true)
                        end
                    elseif #tabs == 0 then
                        tabs = nil
                    end
                end

                -- Parse expansions (validate against EXPANSION_DISPLAY)
                local expansions = nil
                if expStr ~= "" then
                    local validExpIDs = {}
                    for _, exp in ipairs(self.EXPANSION_DISPLAY) do
                        validExpIDs[exp.expansionID] = true
                    end
                    expansions = {}
                    for e in expStr:gmatch("[^,]+") do
                        local n = tonumber(e)
                        if n and validExpIDs[n] then
                            expansions[#expansions + 1] = n
                        end
                    end
                    if #expansions == 0 then
                        expansions = nil
                    end
                end

                -- Parse subcategories (validate against SUBCATEGORY_DISPLAY)
                local subcategories = nil
                if subcatStr ~= "" then
                    local subcatDef = self.SUBCATEGORY_DISPLAY[category]
                    local validKeys = {}
                    if subcatDef then
                        for _, item in ipairs(subcatDef.items) do
                            validKeys[item.key] = true
                        end
                    end
                    subcategories = {}
                    for s in subcatStr:gmatch("[^,]+") do
                        if subcatDef and validKeys[s] then
                            subcategories[#subcategories + 1] = s
                        end
                    end
                    if #subcategories == 0 then
                        subcategories = nil
                    end
                end

                local rule = {
                    profession = category,
                    type = bankType,
                    tabs = tabs,
                    guild = guildStr ~= "" and guildStr or nil,
                    expansions = expansions,
                    subcategories = subcategories,
                    _origChar = charStr, -- keep original for resolution
                    _origGuild = guildStr, -- keep original for resolution
                }

                -- Resolve character / guild
                if bankType == "warbandbank" then
                    readyRules[#readyRules + 1] = rule
                elseif bankType == "guildbank" then
                    -- Prefer the realm from column 8 of the export. Fall back to
                    -- registry lookup (by guild name) for old exports without it.
                    -- entry.guildRealm is the guild's home realm, NOT the
                    -- character's realm - they differ for cross-realm guilds.
                    local resolvedRealm = realmStr ~= "" and realmStr or nil
                    if not resolvedRealm and guildStr ~= "" then
                        for _, entry in pairs(self.db.global.registry) do
                            if entry.guild == guildStr and entry.guildRealm and entry.guildRealm ~= "" then
                                resolvedRealm = entry.guildRealm
                                break
                            end
                        end
                    end
                    if resolvedRealm then
                        rule.realm = resolvedRealm
                        local bankerGuid = self:FindCharInGuild(guildStr, nil, resolvedRealm)
                        if bankerGuid then
                            rule.char = bankerGuid
                            readyRules[#readyRules + 1] = rule
                        else
                            -- Guild name known but no matching banker - surface in remap dialog
                            unresolvedRules[#unresolvedRules + 1] = rule
                        end
                    else
                        -- Unknown / missing guild - surface in remap dialog
                        unresolvedRules[#unresolvedRules + 1] = rule
                    end
                elseif charStr == "" then
                    unresolvedRules[#unresolvedRules + 1] = rule
                else
                    local guid = nameToGUID[charStr] or nameToGUID[charStr:lower()]
                    if guid then
                        rule.char = guid
                        readyRules[#readyRules + 1] = rule
                    else
                        unresolvedRules[#unresolvedRules + 1] = rule
                    end
                end
            end
        end
    end

    return readyRules, unresolvedRules, nil, skippedCount
end

-- Order-insensitive set comparison for expansions/subcategories.
-- Matches the UI dedup behaviour (OpenStorageDialog).
local function setsEqual(a, b)
    if type(a) ~= "table" then a = {} end
    if type(b) ~= "table" then b = {} end
    if #a ~= #b then
        return false
    end
    local setA = {}
    for _, v in ipairs(a) do
        setA[tostring(v)] = true
    end
    for _, v in ipairs(b) do
        if not setA[tostring(v)] then
            return false
        end
    end
    return true
end

-- Pure dup-count helper. Mirrors the dedup check in ApplyImportedRules so the
-- remap dialog's Summary can pre-warn the user how many rules would collapse
-- to duplicates against the current storage list. Does NOT mutate anything.
local function CountDuplicatesAgainst(self, rules, existingList)
    if not rules or #rules == 0 then
        return 0
    end
    existingList = existingList or self.db.global.storageAssignments or {}
    local dup = 0
    for _, rule in ipairs(rules) do
        for _, existing in ipairs(existingList) do
            if
                existing.profession == rule.profession
                and existing.type == rule.type
                and existing.char == rule.char
                and existing.guild == rule.guild
                and setsEqual(existing.expansions, rule.expansions)
                and setsEqual(existing.subcategories, rule.subcategories)
            then
                dup = dup + 1
                break
            end
        end
    end
    return dup
end

-- ----------------------------------------------------------------------------
-- Import Remap Dialog
-- Stepper that walks one unknown-char group at a time. Apply remaps every rule
-- in the group to a chosen local GUID; Skip drops the group; Cancel aborts the
-- whole import. After the last group, a Summary step shows totals and offers
-- [Import] / [Cancel].
-- ----------------------------------------------------------------------------

-- Class-colored "Name - Realm" label for the remap dropdown.
local function RemapCharLabel(entry)
    if not entry then
        return "?"
    end
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
    local name = entry.name or "?"
    local realm = entry.realm or ""
    local text = realm == "" and name or (name .. " - " .. realm)
    if color then
        return string.format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, text)
    end
    return text
end

-- Group unresolvedRules by their unresolved identity. Charbank rules group by
-- _origChar; guildbank rules group by _origGuild. Char groups first (sorted),
-- then guild groups (sorted) so the dialog has a stable order.
-- Returns: array of
--   { type = "char",  origChar  = "Name-Realm",  rules = {...} }
--   { type = "guild", origGuild = "GuildName",   rules = {...} }
local function GroupUnresolved(unresolvedRules)
    local byChar = {}
    local charOrder = {}
    local byGuild = {}
    local guildOrder = {}
    for _, rule in ipairs(unresolvedRules) do
        if rule.type == "guildbank" then
            local key = (rule._origGuild and rule._origGuild ~= "") and rule._origGuild or "<unspecified>"
            if not byGuild[key] then
                byGuild[key] = { type = "guild", origGuild = key, rules = {} }
                guildOrder[#guildOrder + 1] = key
            end
            table.insert(byGuild[key].rules, rule)
        else
            local key = (rule._origChar and rule._origChar ~= "") and rule._origChar or "<unspecified>"
            if not byChar[key] then
                byChar[key] = { type = "char", origChar = key, rules = {} }
                charOrder[#charOrder + 1] = key
            end
            table.insert(byChar[key].rules, rule)
        end
    end
    table.sort(charOrder, function(a, b) return a:lower() < b:lower() end)
    table.sort(guildOrder, function(a, b) return a:lower() < b:lower() end)
    local groups = {}
    for _, key in ipairs(charOrder) do groups[#groups + 1] = byChar[key] end
    for _, key in ipairs(guildOrder) do groups[#groups + 1] = byGuild[key] end
    return groups
end

-- Sorted, deduped list of {guild, realm} pairs from the registry (excluding blacklist).
-- Keyed on guild.."\1"..realm so same-name guilds on different realms are distinct.
local function RemapCandidateGuilds(self, excludeGuild)
    local seen, list = {}, {}
    local bl = self.db.global.guildBlacklist or {}
    for _, entry in pairs(self.db.global.registry or {}) do
        local g = entry.guild
        local r = entry.guildRealm or ""
        if g and g ~= "" and not bl[g] and g ~= excludeGuild then
            local key = g .. "\1" .. r
            if not seen[key] then
                seen[key] = true
                list[#list + 1] = { guild = g, realm = r }
            end
        end
    end
    table.sort(list, function(a, b)
        local la, lb = a.guild:lower(), b.guild:lower()
        if la ~= lb then return la < lb end
        return a.realm:lower() < b.realm:lower()
    end)
    return list
end

-- Sorted list of registry chars (excluding blacklist) for the remap dropdown.
local function RemapCandidateChars(self)
    local chars = {}
    local blacklist = self.db.global.charBlacklist or {}
    for guid, entry in pairs(self.db.global.registry or {}) do
        if not blacklist[guid] and entry.name then
            chars[#chars + 1] = { guid = guid, entry = entry }
        end
    end
    table.sort(chars, function(a, b)
        local an = ((a.entry.name or "") .. "-" .. (a.entry.realm or "")):lower()
        local bn = ((b.entry.name or "") .. "-" .. (b.entry.realm or "")):lower()
        return an < bn
    end)
    return chars
end

-- Human label for a rule's destination (profession + bank type + optional tab/guild).
local function RemapRuleDescription(rule)
    local profKey = rule.profession or "?"
    local profLabel = profKey
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        if info.key == profKey then
            profLabel = info.label
            break
        end
    end
    if profLabel == profKey then
        for _, info in ipairs(EmpireManager.STORAGE_CATEGORY_DISPLAY) do
            if info.key == profKey then
                profLabel = info.label
                break
            end
        end
    end
    local destText
    if rule.type == "warbandbank" then
        destText = "Warband Bank"
    elseif rule.type == "guildbank" then
        destText = "Guild Bank (" .. (rule.guild or "?") .. ")"
    elseif rule.type == "charbank" then
        destText = "Character Bank"
    else
        destText = rule.type or "?"
    end
    if rule.tabs and #rule.tabs > 0 then
        destText = destText .. " Tab " .. table.concat(rule.tabs, ", ")
    end
    return profLabel, destText
end

function EmpireManager:ShowRemapDialog(groups, readyRules, doReplace, onCommit)
    local f = EmpireManagerRemapDialog
    if not f._initialized then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
        f:RegisterForDrag("LeftButton")
        f.ScrollFrame:SetScrollChild(f.ScrollFrame.Content)
        f._initialized = true
    end
    f.TitleText:SetText("EmpireManager - Remap Import")

    -- Decisions[origChar] = { action = "remap"|"skip", guid = "Player-..." }
    local decisions = {}
    local index = 1
    local self_ = self

    local function ClearBody()
        if f._widgets then
            for _, w in ipairs(f._widgets) do
                if w.Hide then w:Hide() end
                if w.SetScript and w.HasScript then
                    if w:HasScript("OnClick") then w:SetScript("OnClick", nil) end
                    if w:HasScript("OnEnter") then w:SetScript("OnEnter", nil) end
                    if w:HasScript("OnLeave") then w:SetScript("OnLeave", nil) end
                end
            end
        end
        f._widgets = {}
        if f._btns then
            for _, b in ipairs(f._btns) do b:Hide() end
        end
        f._btns = {}
    end
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    -- Build the final rule list from decisions + readyRules.
    local function BuildFinalRules()
        local finalRules = {}
        for _, r in ipairs(readyRules) do
            finalRules[#finalRules + 1] = r
        end
        local remappedCount = 0
        for _, group in ipairs(groups) do
            local key = group.type == "guild" and group.origGuild or group.origChar
            local d = decisions[key]
            if d and d.action == "remap" then
                if group.type == "guild" and d.guild then
                    -- Guildbank rules: replace guild + auto-resolve a banker char
                    -- the same way the parser's resolved-guild path does.
                    local bankerGuid = self_:FindCharInGuild(d.guild, nil, d.realm)
                    for _, r in ipairs(group.rules) do
                        r.guild = d.guild
                        r.realm = d.realm
                        if bankerGuid then
                            r.char = bankerGuid
                        end
                        finalRules[#finalRules + 1] = r
                        remappedCount = remappedCount + 1
                    end
                elseif group.type ~= "guild" and d.guid then
                    -- Charbank rules: replace target char.
                    for _, r in ipairs(group.rules) do
                        r.char = d.guid
                        finalRules[#finalRules + 1] = r
                        remappedCount = remappedCount + 1
                    end
                end
            end
        end
        return finalRules, remappedCount
    end

    -- Set by every explicit close path (Cancel/Import/X). OnHide checks it so
    -- that ESC (or any other implicit hide) still fires the cancel callback.
    local intentionalClose = false
    local function CloseDialog()
        intentionalClose = true
        f:Hide()
        self_.remapDialogFrame = nil
    end
    f:SetScript("OnHide", function()
        -- Re-enable the IE window's Import button (which we disabled at open
        -- to prevent re-entry while the user is mid-remap).
        local ie = EmpireManagerIOFrame
        if ie and ie._importBtn then
            ie._importBtn:Enable()
        end
        if intentionalClose then
            return
        end
        self_.remapDialogFrame = nil
        if onCommit then onCommit(false, nil, 0, 0) end
    end)

    local renderStep
    local renderSummary

    -- Per-group step renderer (handles both char and guild types).
    renderStep = function()
        if index > #groups then
            renderSummary()
            return
        end
        local group = groups[index]
        ClearBody()
        local sf = f.ScrollFrame
        local content = sf.Content
        content:SetWidth(sf:GetWidth())
        local contentW = sf:GetWidth() or 400
        local y = 8

        local isGuild = group.type == "guild"
        local groupKey = isGuild and group.origGuild or group.origChar
        local unspecifiedLabel = isGuild and "<no guild specified>" or "<no character specified>"
        local refLine = isGuild
            and "%d rule%s reference this guild:"
            or "%d rule%s reference this character:"

        f.SubTitleText:SetText(string.format(
            "|cffdaa520%s %d of %d|r",
            isGuild and "Unknown Guild" or "Unknown Character",
            index, #groups
        ))

        local origName = groupKey == "<unspecified>"
            and ("|cffff8800" .. unspecifiedLabel .. "|r")
            or ("|cffffffff" .. groupKey .. "|r")
        local toFs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
        toFs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        toFs:SetText(origName)
        y = y + 26

        local countFs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
        countFs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        local n = #group.rules
        countFs:SetText(string.format(refLine, n, n == 1 and "" or "s"))
        y = y + 18
        y = y + 4

        for _, r in ipairs(group.rules) do
            local row = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -y)
            row:SetWidth(contentW - 24)
            row:SetJustifyH("LEFT")
            if row.SetIndentedWordWrap then
                row:SetIndentedWordWrap(true)
            end
            local profLabel, destText = RemapRuleDescription(r)
            row:SetText(string.format("%s » %s", profLabel, destText))
            local h = row:GetStringHeight() or 14
            y = y + math.max(16, math.ceil(h) + 2)
        end
        y = y + 8

        local pickLabel = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
        pickLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        pickLabel:SetText("Remap to:")
        pickLabel:SetTextColor(1, 0.82, 0)
        y = y + 18

        -- Candidates: char or guild. The renderer keeps a single `chosen` token
        -- and dispatches to the right dropdown source.
        local chars = (not isGuild) and RemapCandidateChars(self_) or nil
        local guilds = isGuild and RemapCandidateGuilds(self_) or nil
        local candidateCount = isGuild and #guilds or #chars

        local existing = decisions[groupKey]
        local chosenGUID = (not isGuild and existing and existing.action == "remap") and existing.guid or nil
        local chosenGuild = (isGuild and existing and existing.action == "remap")
            and { guild = existing.guild, realm = existing.realm or "" } or nil

        -- Forward decl: Next button is created below; the dropdown callbacks
        -- need to re-enable it when the user makes a pick.
        local nextBtn
        local function HasPick()
            return (isGuild and chosenGuild ~= nil) or (not isGuild and chosenGUID ~= nil)
        end
        local function RefreshNextBtn()
            if nextBtn then
                nextBtn:SetEnabled(HasPick())
            end
        end

        local dd = Track(CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate"))
        dd:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        dd:SetSize(contentW - 24, 26)
        if dd.SetDefaultText then
            if candidateCount == 0 then
                dd:SetDefaultText(isGuild and "(no guilds)" or "(no characters)")
            else
                dd:SetDefaultText(isGuild and "Pick a guild..." or "Pick a character...")
            end
        end
        local selIdx
        dd:SetupMenu(function(_, root)
            root:SetScrollMode(20 * 20)
            selIdx = nil
            if isGuild then
                if #guilds == 0 then return end
                for i, g in ipairs(guilds) do
                    local isChosen = chosenGuild and chosenGuild.guild == g.guild and chosenGuild.realm == g.realm
                    if isChosen then selIdx = i end
                    local label = g.realm ~= "" and (g.guild .. " (" .. g.realm .. ")") or g.guild
                    root:CreateRadio(label, function()
                        return chosenGuild and chosenGuild.guild == g.guild and chosenGuild.realm == g.realm
                    end, function()
                        chosenGuild = g
                        RefreshNextBtn()
                    end)
                end
            else
                if #chars == 0 then return end
                for i, c in ipairs(chars) do
                    if c.guid == chosenGUID then selIdx = i end
                    root:CreateRadio(RemapCharLabel(c.entry), function()
                        return chosenGUID == c.guid
                    end, function()
                        chosenGUID = c.guid
                        RefreshNextBtn()
                    end)
                end
            end
        end)
        self_:EnableDropdownScrollToSelected(dd, function() return selIdx end)
        y = y + 30

        if candidateCount == 0 then
            local empty = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
            empty:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
            empty:SetWidth(contentW - 16)
            empty:SetJustifyH("LEFT")
            if isGuild then
                empty:SetText("|cffff8800No guilds in your roster to remap to. Log in to a character in a guild first, then re-import.|r")
            else
                empty:SetText("|cffff8800No characters in your roster to remap to. Log in to your alts first, then re-import.|r")
            end
            y = y + 28
        end

        content:SetHeight(y + 10)

        -- Bottom buttons: Cancel (left) | Skip (center) | Next (right)
        local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cancelBtn:SetSize(100, 22)
        cancelBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 20)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function()
            CloseDialog()
            if onCommit then onCommit(false, nil, 0, 0) end
        end)
        f._btns[1] = cancelBtn

        local skipBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        skipBtn:SetSize(100, 22)
        skipBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 20)
        skipBtn:SetText("Skip")
        skipBtn:SetScript("OnClick", function()
            decisions[groupKey] = { action = "skip" }
            index = index + 1
            renderStep()
        end)
        f._btns[2] = skipBtn

        nextBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        nextBtn:SetSize(100, 22)
        nextBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 20)
        nextBtn:SetText("Next")
        nextBtn:SetScript("OnClick", function()
            if isGuild then
                decisions[groupKey] = { action = "remap", guild = chosenGuild.guild, realm = chosenGuild.realm }
            else
                decisions[groupKey] = { action = "remap", guid = chosenGUID }
            end
            index = index + 1
            renderStep()
        end)
        f._btns[3] = nextBtn
        RefreshNextBtn()
    end

    -- Summary step renderer
    renderSummary = function()
        ClearBody()
        local sf = f.ScrollFrame
        local content = sf.Content
        content:SetWidth(sf:GetWidth())
        local contentW = sf:GetWidth() or 400
        local y = 8

        f.SubTitleText:SetText("|cffdaa520Import Summary|r")

        local readyN = #readyRules
        local remappedTotal, skippedTotal = 0, 0
        local remapLines, skipLines = {}, {}
        local registry = self_.db.global.registry or {}
        for _, group in ipairs(groups) do
            local key = group.type == "guild" and group.origGuild or group.origChar
            local d = decisions[key]
            if d and d.action == "remap" then
                local label
                if group.type == "guild" then
                    label = (d.realm and d.realm ~= "") and (d.guild .. " (" .. d.realm .. ")") or (d.guild or "?")
                else
                    local rEntry = registry[d.guid]
                    label = rEntry and RemapCharLabel(rEntry) or d.guid
                end
                remapLines[#remapLines + 1] = string.format(
                    "%s » %s  (%d)",
                    key, label, #group.rules
                )
                remappedTotal = remappedTotal + #group.rules
            else
                skipLines[#skipLines + 1] = string.format(
                    "%s  (%d)",
                    key, #group.rules
                )
                skippedTotal = skippedTotal + #group.rules
            end
        end

        local function AddLine(text, color, indent, font)
            local leftPad = 8 + (indent or 0)
            local fs = Track(content:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight"))
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, -y)
            fs:SetWidth(contentW - leftPad - 8)
            fs:SetJustifyH("LEFT")
            if fs.SetIndentedWordWrap then
                fs:SetIndentedWordWrap(true)
            end
            fs:SetText(text)
            if color then fs:SetTextColor(color[1], color[2], color[3]) end
            -- Advance y by the actual rendered height so wrapped lines (long
            -- realm names, etc.) don't draw on top of the next row.
            local h = fs:GetStringHeight() or 14
            y = y + math.max(16, math.ceil(h) + 2)
        end

        AddLine(string.format("|cff00cc00%d rule%s ready to import|r", readyN, readyN == 1 and "" or "s"), nil, nil, "GameFontNormalLarge")
        y = y + 4

        if remappedTotal > 0 then
            AddLine(string.format("|cff88ccff%d rule%s remapped:|r", remappedTotal, remappedTotal == 1 and "" or "s"), nil, nil, "GameFontNormalLarge")
            for _, line in ipairs(remapLines) do AddLine(line) end
            y = y + 4
        end
        if skippedTotal > 0 then
            AddLine(string.format("|cffdddd00%d rule%s skipped:|r", skippedTotal, skippedTotal == 1 and "" or "s"), nil, nil, "GameFontNormalLarge")
            for _, line in ipairs(skipLines) do AddLine(line) end
            y = y + 4
        end

        -- Pre-commit duplicate check against the current storage list (skipped
        -- in Replace mode since the list will be wiped before applying).
        local previewRules, _ = BuildFinalRules()
        local dupTotal = doReplace and 0 or CountDuplicatesAgainst(self_, previewRules)
        if dupTotal > 0 then
            AddLine(string.format(
                "|cffe8d9a8%d rule%s already exist (will be skipped as duplicates)|r",
                dupTotal, dupTotal == 1 and "" or "s"
            ))
            y = y + 4
        end

        local total = readyN + remappedTotal - dupTotal
        y = y + 8
        AddLine(string.format("|cffffd100%d total rule%s to import|r", total, total == 1 and "" or "s"), nil, nil, "GameFontNormalLarge")

        if doReplace then
            y = y + 6
            AddLine("|cffff8800Existing storage rules will be replaced first.|r")
        end

        content:SetHeight(y + 10)

        -- Buttons: Cancel (left) | Import (right)
        local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cancelBtn:SetSize(120, 22)
        cancelBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 20)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function()
            CloseDialog()
            if onCommit then onCommit(false, nil, 0, 0) end
        end)
        f._btns[1] = cancelBtn

        local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        importBtn:SetSize(120, 22)
        importBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 20)
        importBtn:SetText("Import")
        if total == 0 then
            importBtn:Disable()
        end
        importBtn:SetScript("OnClick", function()
            local finalRules, mappedN = BuildFinalRules()
            CloseDialog()
            if onCommit then onCommit(true, finalRules, mappedN, skippedTotal) end
        end)
        f._btns[2] = importBtn
    end

    -- Closing via X = cancel
    f.CloseButton:SetScript("OnClick", function()
        CloseDialog()
        if onCommit then onCommit(false, nil, 0, 0) end
    end)

    -- Block re-entry: disable the IE window's Import button while the remap
    -- dialog is active. OnHide re-enables it via every close path.
    local ie = EmpireManagerIOFrame
    if ie and ie._importBtn then
        ie._importBtn:Disable()
    end

    f:Show()
    self.remapDialogFrame = f
    renderStep()
end

function EmpireManager:ApplyImportedRules(rules)
    if not self.db.global.storageAssignments then
        self.db.global.storageAssignments = {}
    end
    local assignments = self.db.global.storageAssignments
    local imported = 0
    local skipped = 0

    for _, rule in ipairs(rules) do
        -- Clean internal fields
        rule._origChar = nil
        rule._origGuild = nil

        -- Duplicate check - matches the UI rule: same category + destination = dup,
        -- regardless of tab list (set-based for expansions/subcategories).
        local isDupe = false
        for _, existing in ipairs(assignments) do
            if
                existing.profession == rule.profession
                and existing.type == rule.type
                and existing.char == rule.char
                and existing.guild == rule.guild
                and setsEqual(existing.expansions, rule.expansions)
                and setsEqual(existing.subcategories, rule.subcategories)
            then
                isDupe = true
                break
            end
        end

        if isDupe then
            skipped = skipped + 1
        else
            assignments[#assignments + 1] = rule
            if rule.char and rule.char ~= "self" then
                self:SyncBankerRole(rule.char)
            end
            imported = imported + 1
        end
    end

    if imported > 0 then
        self:InvalidateStorageCache()
    end

    return imported, skipped
end

function EmpireManager:ParseImportSections(text)
    local sections = {}
    local currentType = nil
    local currentLines = {}

    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:find("^# EmpireManager Registry v") then
            if currentType then
                sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
            end
            currentType = "registry"
            currentLines = { trimmed }
        elseif trimmed:find("^# EmpireManager Storage Rules v") then
            if currentType then
                sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
            end
            currentType = "storage"
            currentLines = { trimmed }
        elseif currentType then
            currentLines[#currentLines + 1] = trimmed
        end
    end

    if currentType then
        sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
    end

    return sections
end

-------------------------------------------------------------------------------

-- Shared helpers for native pages
local FONT_NORMAL = "GameFontHighlight"
local LINE_HEIGHT = 20
local HEADING_HEIGHT = 32

-- Aggregate capacity across specific tabs or all tabs (used by Roster Banks and Storage page).
-- Delegates to EmpireManager:AggregateCapacity (Utils.lua) - shared with triage routing.
local function AggregateCapacity(capSection, tabs)
    return EmpireManager:AggregateCapacity(capSection, tabs)
end

-------------------------------------------------------------------------------
-- ABOUT PAGE MIXIN
-------------------------------------------------------------------------------

-- Popup that lets the user copy the EmpireManager website URL.
-- WoW cannot launch a browser; the standard pattern is a read-only edit box
-- pre-selected for Ctrl+C.
StaticPopupDialogs["EM_URL_SITE"] = {
    text = "EmpireManager website (Ctrl+C to copy):",
    button1 = OKAY,
    hasEditBox = true,
    editBoxWidth = 280,
    OnShow = function(self)
        local eb = self.editBox or self.EditBox
        if not eb then return end
        eb:SetText("https://wow.cyberpunk.gr/")
        eb:HighlightText()
        eb:SetFocus()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    EditBoxOnEnterPressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function EMAboutPageMixin:OnLoad()
    self.ScrollFrame = self.Inset.ScrollFrame
    local sf = self.ScrollFrame
    sf:SetScrollChild(sf.Content)

    local inset = self.Inset
    if inset then
        if inset.BGCornerTopLeft then
            inset.BGCornerTopLeft:Hide()
        end
        if inset.BGCornerTopRight then
            inset.BGCornerTopRight:Hide()
        end
        if inset.BGCornerBottomLeft then
            inset.BGCornerBottomLeft:Hide()
        end
        if inset.BGCornerBottomRight then
            inset.BGCornerBottomRight:Hide()
        end
    end
end

function EMAboutPageMixin:OnShow()
    self:Refresh()
end

function EMAboutPageMixin:Refresh()
    local sf = self.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    -- Clear previous content
    if self._lines then
        for _, obj in ipairs(self._lines) do
            obj:Hide()
        end
    end
    self._lines = {}

    local lines = self._lines
    local y = EmpireManager:BuildAboutPanel(content, {
        track = function(obj)
            lines[#lines + 1] = obj
            return obj
        end,
    })

    content:SetHeight(y + 20)
end

-------------------------------------------------------------------------------
-- MAP PAGE MIXIN
-------------------------------------------------------------------------------

-- Map column definitions. `sortKey` enables clickable header sort.
local MAP_COLUMNS = {
    { key = "name", width = 130, label = "Name", justify = "LEFT", padLeft = 8, sortKey = "name" },
    { key = "zone", width = 170, label = "Zone", justify = "LEFT", padLeft = 8, sortKey = "zone" },
    { key = "subZone", width = 200, label = "SubZone", justify = "LEFT", padLeft = 8, sortKey = "subZone" },
    { key = "seen", width = 100, label = "Last Seen", justify = "RIGHT", padRight = 16, sortKey = "seen" },
    { key = "coords", width = 110, label = "Coords", justify = "CENTER" },
}

-- Sort key functions per column. Tiebreak handled by caller (name asc).
local MAP_SORT_KEYS = {
    name = function(e)
        return (e.name or ""):lower()
    end,
    zone = function(e)
        return (e.zone or ""):lower()
    end,
    subZone = function(e)
        return (e.subZone or ""):lower()
    end,
    seen = function(e)
        return e.lastSeen or 0
    end,
}

function EMMapPageMixin:OnLoad()
    self.ScrollBox = self.Inset.ScrollBox
    self.ScrollBar = self.Inset.ScrollBar

    -- Default sort: first column (name), ascending
    self.sortColumn = "name"
    self.sortAscending = true
    self.headerButtons = {}

    local view = CreateScrollBoxListLinearView()
    view:SetElementInitializer("EMMapRowTemplate", function(frame, elementData)
        if not frame._mixinApplied then
            Mixin(frame, EMMapRowMixin)
            frame:OnLoad()
            frame._mixinApplied = true
        end
        frame:Populate(elementData)
    end)
    view:SetElementExtent(22)
    ScrollUtil.InitScrollBoxListWithScrollBar(self.ScrollBox, self.ScrollBar, view)

    -- Build column headers
    self:InitMapHeaders()
end

function EMMapPageMixin:InitMapHeaders()
    local container = self.Inset.HeaderContainer
    local xOffset = 6
    for _, col in ipairs(MAP_COLUMNS) do
        local btn = CreateFrame("Button", nil, container, "ColumnDisplayButtonShortTemplate")
        btn:SetSize(col.width, 19)
        btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
        btn:SetText(col.label)
        btn:SetNormalFontObject(GameFontHighlightSmall)
        btn:GetFontString():SetJustifyH(col.justify)
        btn._text = btn:GetFontString()

        if col.sortKey then
            local arrow = btn:CreateTexture(nil, "OVERLAY")
            arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
            arrow:SetPoint("LEFT", btn._text, "RIGHT", 1, 0)
            arrow:Hide()
            btn._arrow = arrow

            local page = self
            btn:SetScript("OnClick", function()
                if page.sortColumn == col.sortKey then
                    page.sortAscending = not page.sortAscending
                else
                    page.sortColumn = col.sortKey
                    page.sortAscending = true
                end
                page:UpdateHeaderArrows()
                page:Refresh()
            end)

            self.headerButtons[#self.headerButtons + 1] = { btn = btn, sortKey = col.sortKey }
        else
            btn:SetEnabled(false)
        end

        xOffset = xOffset + col.width
    end

    self:UpdateHeaderArrows()
end

function EMMapPageMixin:UpdateHeaderArrows()
    for _, h in ipairs(self.headerButtons) do
        if self.sortColumn == h.sortKey then
            h.btn._arrow:Show()
            if self.sortAscending then
                h.btn._arrow:SetTexCoord(0, 1, 1, 0)
            else
                h.btn._arrow:SetTexCoord(0, 1, 0, 1)
            end
            h.btn:SetNormalFontObject(GameFontHighlight)
        else
            h.btn._arrow:Hide()
            h.btn:SetNormalFontObject(GameFontHighlightSmall)
        end
    end
end

function EMMapPageMixin:OnShow()
    self:Refresh()
end

function EMMapPageMixin:Refresh()
    -- Flat list of all characters with a known zone
    local data = {}
    for guid, entry in pairs(EmpireManager.db.global.registry) do
        if entry.zone and entry.zone ~= "" then
            data[#data + 1] = { guid = guid, entry = entry }
        end
    end

    local keyFn = MAP_SORT_KEYS[self.sortColumn] or MAP_SORT_KEYS.name
    local asc = self.sortAscending
    table.sort(data, function(a, b)
        local kA = keyFn(a.entry)
        local kB = keyFn(b.entry)
        if kA == kB then
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end
        if asc then
            return kA < kB
        else
            return kA > kB
        end
    end)

    -- Add index for row tracking
    for i, d in ipairs(data) do
        d.index = i
    end

    local dataProvider = CreateDataProvider(data)
    self.ScrollBox:SetDataProvider(dataProvider)
end

-- Map Row Mixin
function EMMapRowMixin:OnLoad()
    self:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    self:SetScript("OnClick", function(f, button)
        f:OnClick(button)
    end)
    self:SetScript("OnEnter", function(f)
        f:OnEnter()
    end)
    self:SetScript("OnLeave", function(f)
        f:OnLeave()
    end)

    self.cells = {}
    local x = 6
    for _, col in ipairs(MAP_COLUMNS) do
        local padL = col.padLeft or 0
        local padR = col.padRight or 0
        local fs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
        fs:SetJustifyH(col.justify)
        fs:SetWidth(col.width - 4 - padL - padR)
        fs:SetHeight(22)
        fs:SetPoint("LEFT", self, "LEFT", x + 2 + padL, 0)
        self.cells[col.key] = fs
        x = x + col.width
    end
end

function EMMapRowMixin:Populate(data)
    self._data = data
    local entry = data.entry

    self.cells.name:SetText(EmpireManager:ClassColoredName(entry))
    self.cells.zone:SetText(entry.zone or "")
    self.cells.zone:SetTextColor(1, 0.82, 0)
    self.cells.subZone:SetText((entry.subZone and entry.subZone ~= "") and entry.subZone or "")
    self.cells.subZone:SetTextColor(0.8, 0.72, 0.5)
    self.cells.seen:SetText(EmpireManager:FormatTimeSince(entry.lastSeen))
    self.cells.seen:SetTextColor(1, 1, 1)

    local pinPrefix = entry.mapPinned and "|cff4488cc*|r " or ""
    if entry.mapX and entry.mapY then
        self.cells.coords:SetText(pinPrefix .. string.format("%.1f, %.1f", entry.mapX * 100, entry.mapY * 100))
        self.cells.coords:SetTextColor(0.5, 0.7, 0.5)
    else
        self.cells.coords:SetText(pinPrefix .. "-")
        self.cells.coords:SetTextColor(0.7, 0.65, 0.5)
    end

    -- Zebra stripe (AH-style atlas, matches Characters/Storage tabs)
    if data.index and data.index % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetAtlas("auctionhouse-rowstripe-2")
    end
end

function EMMapRowMixin:OnClick(button)
    local data = self._data
    if not data then
        return
    end
    local entry = data.entry

    if button == "RightButton" then
        -- Toggle map pin
        entry.mapPinned = not entry.mapPinned
        local state = entry.mapPinned and "pinned" or "unpinned"
        EmpireManager:Print(string.format("%s location %s", entry.name or "?", state))
        -- Refresh the row display
        self:Populate(data)
        return
    end

    if entry.mapID and entry.mapX then
        local point = UiMapPoint.CreateFromCoordinates(entry.mapID, entry.mapX, entry.mapY or 0)
        C_Map.SetUserWaypoint(point)
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
        -- Print clickable waypoint link
        local link = C_Map.GetUserWaypointHyperlink()
        if link then
            EmpireManager:Print(string.format("%s: %s", entry.name or "?", link))
        end
    else
        EmpireManager:Print(string.format("No location data for %s", entry.name or "?"))
    end
end

function EMMapRowMixin:OnEnter()
    local data = self._data
    if not data then
        return
    end
    local entry = data.entry
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
    local cr, cg, cb = cc and cc.r or 1, cc and cc.g or 1, cc and cc.b or 1
    local header = string.format("%s - %s (%d)", entry.name or "?", entry.realm or "?", entry.level or 0)
    GameTooltip:AddLine(header, cr, cg, cb)
    if entry.zone then
        local loc = entry.zone
        if entry.subZone and entry.subZone ~= "" then
            loc = loc .. " - " .. entry.subZone
        end
        GameTooltip:AddLine(loc, 0.7, 0.7, 0.7)
    end
    if entry.mapPinned then
        GameTooltip:AddLine("Pinned (coordinates locked)", 0.27, 0.53, 0.8)
    end
    if entry.mapX and entry.mapY and entry.mapID then
        GameTooltip:AddLine(
            string.format("%.1f, %.1f  (Map %d)", entry.mapX * 100, entry.mapY * 100, entry.mapID),
            0.5,
            0.7,
            0.5
        )
        GameTooltip:AddLine("Click to set waypoint", 1, 0.82, 0)
    end
    GameTooltip:AddLine(entry.mapPinned and "Right-click to unpin" or "Right-click to pin location", 0.5, 0.8, 1.0)
    GameTooltip:Show()
end

function EMMapRowMixin:OnLeave()
    GameTooltip:Hide()
end

-------------------------------------------------------------------------------
-- ROSTER PAGE MIXIN (PanelTemplates sub-tabs)
-------------------------------------------------------------------------------

function EMRosterPageMixin:OnLoad()
    self._selectedTab = 1

    self.ScrollFrame = self.Inset.ScrollFrame
    local sf = self.ScrollFrame
    sf:SetScrollChild(sf.Content)

    -- Override CollectionsBackgroundTemplate's built-in anchors so the inset
    -- sits directly under the sub-tabs (Wardrobe pattern, matches Sidecar).
    local inset = self.Inset
    if inset then
        inset:ClearAllPoints()
        inset:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 8)
        inset:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, 0)
        if inset.BGCornerTopLeft then
            inset.BGCornerTopLeft:Hide()
        end
        if inset.BGCornerTopRight then
            inset.BGCornerTopRight:Hide()
        end
        if inset.BGCornerBottomLeft then
            inset.BGCornerBottomLeft:Hide()
        end
        if inset.BGCornerBottomRight then
            inset.BGCornerBottomRight:Hide()
        end
    end

    -- Top tabs (Appearances-style TabSystemTopButtonTemplate)
    Mixin(self, TabSystemOwnerMixin)
    TabSystemOwnerMixin.OnLoad(self)
    self:SetTabSystem(self.TabSystem)

    local tabNames = { "Info", "Banks", "Professions", "Categories", "Roles" }
    self._tabNames = tabNames
    self._tabIDs = {}
    for i, name in ipairs(tabNames) do
        self._tabIDs[i] = self:AddNamedTab(name)
        self:SetTabCallback(self._tabIDs[i], function()
            self._selectedTab = i
            self:Refresh()
            -- Refresh InfoButton tooltip if it's visible (sub-tab help)
            if
                EmpireManager.dashboardFrame
                and EmpireManager.dashboardFrame.InfoButton:IsShown()
                and GameTooltip:GetOwner() == EmpireManager.dashboardFrame.InfoButton
            then
                EmpireManager.dashboardFrame.InfoButton:GetScript("OnEnter")(EmpireManager.dashboardFrame.InfoButton)
            end
        end)
    end
end

function EMRosterPageMixin:OnShow()
    if self._tabIDs and self._tabIDs[self._selectedTab or 1] then
        self:SetTab(self._tabIDs[self._selectedTab or 1])
    end
    self:Refresh()
end

function EMRosterPageMixin:Refresh()
    local sf = self.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    -- Clear previous: hide objects and release closure references
    if self._lines then
        for _, obj in ipairs(self._lines) do
            if obj.Hide then
                obj:Hide()
            end
            if obj.HasScript then
                if obj:HasScript("OnClick") then
                    obj:SetScript("OnClick", nil)
                end
                if obj:HasScript("OnEnter") then
                    obj:SetScript("OnEnter", nil)
                end
                if obj:HasScript("OnLeave") then
                    obj:SetScript("OnLeave", nil)
                end
            end
        end
    end
    self._lines = {}

    local tab = self._selectedTab or 1
    local y = 8

    if tab == 1 then
        y = self:BuildInfoContent(content, y)
    elseif tab == 2 then
        y = self:BuildBankContent(content, y)
    elseif tab == 3 then
        y = self:BuildDeptContent(content, y)
    elseif tab == 4 then
        y = self:BuildCategoriesContent(content, y)
    elseif tab == 5 then
        y = self:BuildRoleContent(content, y)
    end

    content:SetHeight(y + 20)
    sf:SetVerticalScroll(0)
end

function EMRosterPageMixin:Track(obj)
    self._lines[#self._lines + 1] = obj
    return obj
end

-- Helper: add a heading with separator. Returns (newY, headingFontString).
-- Fill bar with subtle vertical gradient; pct left, used/total right (Blizz health-bar style).
-- `anchor` is either a region (anchored "TOPLEFT" to its "BOTTOMLEFT" with -12 y-offset) or
-- nil (anchored to `content` "TOPLEFT" at offset 8, -y).
-- Returns new y value after the bar.
function EMRosterPageMixin:DrawFillBar(content, anchor, y, pct, used, total, free, scannedAt)
    local function colorForPct(p)
        if p >= 0.85 then
            return 1.0, 0.2, 0.2
        elseif p >= 0.60 then
            return 1.0, 0.8, 0.0
        else
            return 0.0, 0.8, 0.0
        end
    end

    local BAR_W, BAR_H = 400, 19
    local row = self:Track(CreateFrame("Frame", nil, content))
    row:SetSize(BAR_W, BAR_H)
    if anchor then
        row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -12)
    else
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    end

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.1, 0.1, 0.85)

    local fill = row:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 1, 1)
    local fw = math.max(1, math.floor((BAR_W - 2) * pct))
    fill:SetWidth(fw)
    fill:SetColorTexture(1, 1, 1, 1)
    local r, g, b = colorForPct(pct)
    fill:SetGradient(
        "VERTICAL",
        CreateColor(r * 0.7, g * 0.7, b * 0.7, 0.6),
        CreateColor(math.min(1, r * 1.1), math.min(1, g * 1.1), math.min(1, b * 1.1), 0.6)
    )

    local border = CreateFrame("Frame", nil, row, "BackdropTemplate")
    border:SetAllPoints()
    border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    border:SetBackdropBorderColor(0, 0, 0, 0.7)

    local pctFS = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    pctFS:SetPoint("LEFT", row, "LEFT", 6, 0)
    pctFS:SetShadowColor(0, 0, 0, 1)
    pctFS:SetShadowOffset(1, -1)
    pctFS:SetTextColor(1, 1, 1)
    pctFS:SetText(string.format("%d%%", math.floor(pct * 100 + 0.5)))

    local valFS = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    valFS:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    valFS:SetShadowColor(0, 0, 0, 1)
    valFS:SetShadowOffset(1, -1)
    valFS:SetTextColor(1, 1, 1)
    valFS:SetText(string.format("%s / %s", BreakUpLargeNumbers(used), BreakUpLargeNumbers(total)))

    local freeFS = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    freeFS:SetPoint("LEFT", row, "RIGHT", 8, 0)
    freeFS:SetTextColor(0.85, 0.85, 0.85)
    local age = EmpireManager:FormatStaleAge(scannedAt)
    if age then
        freeFS:SetText(string.format("%s free, scanned %s", BreakUpLargeNumbers(free), age))
    else
        freeFS:SetText(string.format("%s free", BreakUpLargeNumbers(free)))
    end

    return y + BAR_H + 4
end

function EMRosterPageMixin:AddHeading(content, y, text, skipDivider)
    if not skipDivider then
        y = y + 4 -- extra spacing above divider

        local divider = self:Track(content:CreateTexture(nil, "ARTWORK"))
        divider:SetAtlas("ui-journeys-renown-divider", true)
        divider:SetPoint("TOP", content, "TOP", 0, -y)
        y = y + 28
    end

    local fs = self:Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    fs:SetText("|cffffd100" .. text .. "|r")
    return y + HEADING_HEIGHT, fs
end

-- Helper: add a stat line "Label   Value" in a row
function EMRosterPageMixin:AddStatLine(content, y, label, value, lr, lg, lb, vr, vg, vb)
    local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
    fs:SetPoint("RIGHT", content, "RIGHT", -8, 0)
    fs:SetJustifyH("LEFT")
    local lColor = string.format("|cff%02x%02x%02x", (lr or 0.87) * 255, (lg or 0.87) * 255, (lb or 0.87) * 255)
    local vColor = string.format("|cff%02x%02x%02x", (vr or 1) * 255, (vg or 1) * 255, (vb or 1) * 255)
    fs:SetText(lColor .. label .. "|r    " .. vColor .. value .. "|r")
    return y + LINE_HEIGHT
end

-- Helper: interactive label with tooltip
function EMRosterPageMixin:AddClickLabel(content, y, text, width, tooltipTitle, chars, tooltipFmt)
    local btn = self:Track(CreateFrame("Button", nil, content))
    btn:SetSize(width, LINE_HEIGHT)
    btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (self._flowX or 0), -y)

    local fs = btn:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    fs:SetAllPoints()
    fs:SetJustifyH("LEFT")
    fs:SetText(text)

    if chars and #chars > 0 then
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:AddLine(tooltipTitle, 1, 0.82, 0)
            for _, c in ipairs(chars) do
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
                local r2, g2, b2 = cc and cc.r or 1, cc and cc.g or 1, cc and cc.b or 1
                local line
                if tooltipFmt == "no_realm" then
                    line = string.format("%s - %d", c.name or "?", c.level)
                elseif tooltipFmt == "no_level" then
                    line = string.format("%s - %s", c.name or "?", c.realm or "?")
                else
                    line = string.format("%s - %s (%d)", c.name or "?", c.realm or "?", c.level or 0)
                end
                GameTooltip:AddLine(line, r2, g2, b2)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    return btn
end

-------------------------------------------------------------------------------
-- Roster: Info sub-tab
-------------------------------------------------------------------------------

-- Helper: render a horizontal bar row.
--   opts: { label, valueText, value, maxValue, r, g, b, tooltipTitle, chars, iconText }
function EMRosterPageMixin:AddBarRow(content, y, opts)
    local BAR_W = 660
    local BAR_H = LINE_HEIGHT - 4
    local LABEL_PAD = 8

    local row = self:Track(CreateFrame("Button", nil, content))
    row:SetSize(BAR_W, LINE_HEIGHT)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 1)
    bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)

    local frac = (opts.maxValue and opts.maxValue > 0) and (opts.value / opts.maxValue) or 0
    local barWidth = math.max(2, math.floor(BAR_W * frac))
    local bar = row:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    bar:SetSize(barWidth, BAR_H)
    bar:SetColorTexture(1, 1, 1, 1)
    local br, bg2, bb = opts.r or 0.7, opts.g or 0.7, opts.b or 0.7
    bar:SetGradient(
        "VERTICAL",
        CreateColor(br * 0.7, bg2 * 0.7, bb * 0.7, 0.6),
        CreateColor(math.min(1, br * 1.1), math.min(1, bg2 * 1.1), math.min(1, bb * 1.1), 0.6)
    )

    local fs = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    fs:SetPoint("LEFT", row, "LEFT", LABEL_PAD, 1)
    fs:SetPoint("RIGHT", row, "RIGHT", -LABEL_PAD, 1)
    fs:SetJustifyH("LEFT")
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    fs:SetAlpha(0.85)
    local labelText = opts.iconText and (opts.iconText .. " " .. opts.label) or opts.label
    fs:SetText(string.format("|cffffffff%s|r  |cffe8d9a8%s|r", labelText, opts.valueText or tostring(opts.value)))

    if opts.chars and #opts.chars > 0 then
        local r, g, b = opts.r or 1, opts.g or 0.82, opts.b or 0
        local title = opts.tooltipTitle or opts.label
        local fmt = opts.tooltipFmt
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:AddLine(title, r, g, b)
            for _, c in ipairs(opts.chars) do
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
                local r2, g2, b2 = cc and cc.r or 1, cc and cc.g or 1, cc and cc.b or 1
                local line
                if fmt == "no_realm" then
                    line = string.format("%s - %d", c.name or "?", c.level)
                elseif fmt == "no_level" then
                    line = string.format("%s - %s", c.name or "?", c.realm or "?")
                else
                    line = string.format("%s - %s (%d)", c.name or "?", c.realm or "?", c.level or 0)
                end
                GameTooltip:AddLine(line, r2, g2, b2)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    return y + LINE_HEIGHT
end

local NEUTRAL_RACES = { Pandaren = true, Dracthyr = true, EarthenDwarf = true, Harronir = true }

function EMRosterPageMixin:BuildInfoContent(content, y)
    local MAX_LEVEL = GetMaxLevelForExpansionLevel(GetExpansionLevel())

    -- Gather stats
    local totalChars, totalPlayed, maxLevelChars = 0, 0, 0
    local maxLevelChars_list = {}
    local classData, raceData, factionData, realmData, guildData, profData = {}, {}, {}, {}, {}, {}

    local function addChar(tbl, key, ci)
        if not tbl[key] then
            tbl[key] = { count = 0, chars = {} }
        end
        tbl[key].count = tbl[key].count + 1
        tbl[key].chars[#tbl[key].chars + 1] = ci
    end

    local classPlayed = {}

    for _, entry in pairs(EmpireManager.db.global.registry) do
        totalChars = totalChars + 1
        totalPlayed = totalPlayed + (entry.playedTotal or 0)
        local ci = {
            name = entry.name or "?",
            level = entry.level or 0,
            realm = entry.realm or "?",
            class = entry.class or "UNKNOWN",
        }

        if ci.level >= MAX_LEVEL then
            maxLevelChars = maxLevelChars + 1
            maxLevelChars_list[#maxLevelChars_list + 1] = ci
        end

        local classKey = entry.class or "UNKNOWN"
        classPlayed[classKey] = (classPlayed[classKey] or 0) + (entry.playedTotal or 0)
        addChar(classData, classKey, ci)
        local raceKey = entry.race or "Unknown"
        raceKey = raceKey:gsub("[%s']", "") -- "Night Elf" → "NightElf", "Mag'har Orc" → "MagharOrc"
        if NEUTRAL_RACES[raceKey] and entry.faction then
            raceKey = raceKey .. "|" .. entry.faction
        end
        addChar(raceData, raceKey, ci)
        addChar(factionData, entry.faction or "Unknown", ci)
        addChar(realmData, entry.realm or "Unknown", ci)

        local guild = entry.guild
        if guild and guild ~= "" then
            addChar(guildData, guild, ci)
        else
            addChar(guildData, "Not in a Guild", ci)
        end

        if entry.professions then
            for _, prof in ipairs(entry.professions) do
                if prof.name then
                    addChar(
                        profData,
                        prof.name,
                        { name = ci.name, level = ci.level, realm = ci.realm, class = ci.class }
                    )
                end
            end
        end
    end

    local function sortChars(list)
        table.sort(list, function(a, b)
            return a.name < b.name
        end)
    end
    sortChars(maxLevelChars_list)
    for _, d in pairs(classData) do
        sortChars(d.chars)
    end
    for _, d in pairs(raceData) do
        sortChars(d.chars)
    end
    for _, d in pairs(factionData) do
        sortChars(d.chars)
    end
    for _, d in pairs(realmData) do
        sortChars(d.chars)
    end
    for _, d in pairs(guildData) do
        sortChars(d.chars)
    end
    for _, d in pairs(profData) do
        sortChars(d.chars)
    end

    -- Roster Overview
    y = self:AddHeading(content, y, "Roster Overview", true)

    -- Row 1: Total | Max Level | Gold
    local totalGold, _, warbandGold = EmpireManager:CalculateGrandTotals()
    local playedText = EmpireManager:FormatPlaytime(totalPlayed) or "0h 0m"
    local colW = 220

    -- Total Characters
    self:AddClickLabel(content, y, string.format("|cffe8d9a8Total Characters:|r  |cffffffff%d|r", totalChars), colW)
    self._flowX = colW
    self:AddClickLabel(
        content,
        y,
        string.format("|cffe8d9a8Max Level (%d):|r  |cff00cc00%d|r", MAX_LEVEL, maxLevelChars),
        colW,
        string.format("Max Level (%d)", MAX_LEVEL),
        maxLevelChars_list,
        "no_level"
    )
    self._flowX = colW * 2
    local goldText = string.format("|cffe8d9a8Gold:|r  |cffffff00%s|r", EmpireManager:FormatGold(totalGold))
    local goldBtn = self:AddClickLabel(content, y, goldText, colW)
    if warbandGold and warbandGold > 0 then
        local charGold = totalGold - warbandGold
        goldBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:AddLine("Gold", 1, 0.82, 0)
            GameTooltip:AddDoubleLine("Characters", EmpireManager:FormatGold(charGold), 1, 1, 1, 1, 1, 0)
            GameTooltip:AddDoubleLine("Warband Bank", EmpireManager:FormatGold(warbandGold), 1, 1, 1, 1, 1, 0)
            GameTooltip:Show()
        end)
        goldBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
    self._flowX = nil
    y = y + LINE_HEIGHT

    -- Row 2: /played
    self:AddClickLabel(content, y, string.format("|cffe8d9a8Total /played:|r  |cffffffff%s|r", playedText), colW * 2)
    y = y + LINE_HEIGHT + 4

    -- By Faction
    y = self:AddHeading(content, y, "Characters by Faction")
    local factionColors = { Alliance = { 0.2, 0.4, 1.0 }, Horde = { 0.8, 0.15, 0.15 } }
    local factionSorted = {}
    local factionMax = 0
    for faction, d in pairs(factionData) do
        factionSorted[#factionSorted + 1] = { faction = faction, count = d.count, chars = d.chars }
        if d.count > factionMax then
            factionMax = d.count
        end
    end
    table.sort(factionSorted, function(a, b)
        return a.count > b.count
    end)
    for _, data in ipairs(factionSorted) do
        local fc = factionColors[data.faction] or { 0.7, 0.7, 0.7 }
        y = self:AddBarRow(content, y, {
            label = data.faction,
            value = data.count,
            valueText = tostring(data.count),
            maxValue = factionMax,
            r = fc[1],
            g = fc[2],
            b = fc[3],
            tooltipTitle = data.faction,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- By Guild
    y = self:AddHeading(content, y, "Characters by Guild")
    local guildSorted = {}
    local guildMax = 0
    for guild, d in pairs(guildData) do
        guildSorted[#guildSorted + 1] = { guild = guild, count = d.count, chars = d.chars }
        if d.count > guildMax then
            guildMax = d.count
        end
    end
    table.sort(guildSorted, function(a, b)
        if a.guild == "Not in a Guild" then
            return false
        end
        if b.guild == "Not in a Guild" then
            return true
        end
        return a.count > b.count
    end)
    local guildColors = { "44ddaa", "dd8844", "8899ee", "ddcc44", "cc66aa", "66ccdd", "aacc55", "cc7777" }
    local guildIdx = 0
    for _, data in ipairs(guildSorted) do
        local color
        if data.guild == "Not in a Guild" then
            color = "666666"
        else
            guildIdx = guildIdx + 1
            color = guildColors[((guildIdx - 1) % #guildColors) + 1]
        end
        local r = tonumber(color:sub(1, 2), 16) / 255
        local g = tonumber(color:sub(3, 4), 16) / 255
        local b = tonumber(color:sub(5, 6), 16) / 255
        y = self:AddBarRow(content, y, {
            label = data.guild,
            value = data.count,
            valueText = tostring(data.count),
            maxValue = guildMax,
            r = r,
            g = g,
            b = b,
            tooltipTitle = data.guild,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- By Class
    y = self:AddHeading(content, y, "Characters by Class")
    -- Pre-seed every known class at 0 so they all render
    for classKey in pairs(EmpireManager.CLASS_NAMES) do
        if not classData[classKey] then
            classData[classKey] = { count = 0, chars = {} }
        end
    end
    local classSorted = {}
    local classMax = 0
    for class, d in pairs(classData) do
        classSorted[#classSorted + 1] = { class = class, count = d.count, chars = d.chars }
        if d.count > classMax then
            classMax = d.count
        end
    end
    table.sort(classSorted, function(a, b)
        return a.count > b.count
    end)
    for _, data in ipairs(classSorted) do
        local cc = RAID_CLASS_COLORS[data.class]
        local r, g, b = cc and cc.r or 0.7, cc and cc.g or 0.7, cc and cc.b or 0.7
        local displayName = EmpireManager.CLASS_NAMES[data.class] or data.class
        y = self:AddBarRow(content, y, {
            label = displayName,
            value = data.count,
            valueText = tostring(data.count),
            maxValue = classMax,
            r = r,
            g = g,
            b = b,
            tooltipTitle = displayName,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- Played by Class (pre-seed every class so all render, even with 0 time)
    for classKey in pairs(EmpireManager.CLASS_NAMES) do
        if not classPlayed[classKey] then
            classPlayed[classKey] = 0
        end
    end
    local playedSorted = {}
    local maxPlayed = 0
    for class, secs in pairs(classPlayed) do
        playedSorted[#playedSorted + 1] =
            { class = class, secs = secs, chars = (classData[class] and classData[class].chars) or {} }
        if secs > maxPlayed then
            maxPlayed = secs
        end
    end
    table.sort(playedSorted, function(a, b)
        return a.secs > b.secs
    end)

    if #playedSorted > 0 then
        y = self:AddHeading(content, y, "Time Played by Class")
        for _, data in ipairs(playedSorted) do
            local cc = RAID_CLASS_COLORS[data.class]
            local r, g, b = cc and cc.r or 0.7, cc and cc.g or 0.7, cc and cc.b or 0.7
            local displayName = EmpireManager.CLASS_NAMES[data.class] or data.class
            local playedStr = EmpireManager:FormatPlaytime(data.secs) or "0h"
            y = self:AddBarRow(content, y, {
                label = displayName,
                value = data.secs,
                valueText = playedStr,
                maxValue = maxPlayed,
                r = r,
                g = g,
                b = b,
                tooltipTitle = displayName,
                chars = data.chars,
                tooltipFmt = "full",
            })
        end
        y = y + 4
    end

    -- By Profession
    y = self:AddHeading(content, y, "Characters by Profession")
    local profSorted = {}
    local profMax = 0
    for _, pInfo in ipairs(EmpireManager.PROF_DISPLAY) do
        if pInfo.category ~= "secondary" then
            local pd = profData[pInfo.label] or { count = 0, chars = {} }
            profSorted[#profSorted + 1] = { info = pInfo, count = pd.count, chars = pd.chars }
            if pd.count > profMax then
                profMax = pd.count
            end
        end
    end
    table.sort(profSorted, function(a, b)
        return a.count > b.count
    end)
    for _, data in ipairs(profSorted) do
        local pInfo = data.info
        y = self:AddBarRow(content, y, {
            label = pInfo.label,
            value = data.count,
            valueText = tostring(data.count),
            maxValue = profMax,
            r = pInfo.r,
            g = pInfo.g,
            b = pInfo.b,
            iconText = string.format("|T%s:14:14|t", pInfo.icon),
            tooltipTitle = pInfo.label,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- By Race
    y = self:AddHeading(content, y, "Characters by Race")
    -- Pre-seed every known race at 0 so they all render
    for raceKey in pairs(EmpireManager.RACE_NAMES) do
        if NEUTRAL_RACES[raceKey] then
            if not raceData[raceKey .. "|Alliance"] then
                raceData[raceKey .. "|Alliance"] = { count = 0, chars = {} }
            end
            if not raceData[raceKey .. "|Horde"] then
                raceData[raceKey .. "|Horde"] = { count = 0, chars = {} }
            end
        else
            if not raceData[raceKey] then
                raceData[raceKey] = { count = 0, chars = {} }
            end
        end
    end
    local raceSorted = {}
    local raceMax = 0
    for race, d in pairs(raceData) do
        raceSorted[#raceSorted + 1] = { race = race, count = d.count, chars = d.chars }
        if d.count > raceMax then
            raceMax = d.count
        end
    end
    table.sort(raceSorted, function(a, b)
        return a.count > b.count
    end)

    local RACE_NAMES = EmpireManager.RACE_NAMES
    local HORDE_RACES = {
        Orc = true,
        Troll = true,
        Tauren = true,
        Scourge = true,
        Undead = true,
        BloodElf = true,
        Goblin = true,
        Nightborne = true,
        HighmountainTauren = true,
        MagharOrc = true,
        ZandalariTroll = true,
        Vulpera = true,
    }
    local ALLIANCE_RACES = {
        Human = true,
        Dwarf = true,
        NightElf = true,
        Gnome = true,
        Draenei = true,
        Worgen = true,
        VoidElf = true,
        LightforgedDraenei = true,
        DarkIronDwarf = true,
        KulTiran = true,
        Mechagnome = true,
    }
    for _, data in ipairs(raceSorted) do
        local race, faction = data.race:match("^(.+)|(.+)$")
        if not race then
            race = data.race
        end
        local displayName = RACE_NAMES[race] or race
        local color
        if faction then
            displayName = displayName .. " (" .. faction .. ")"
            color = faction == "Horde" and "cc3333" or faction == "Alliance" and "3399ff" or "cc99ff"
        elseif HORDE_RACES[race] then
            color = "cc3333"
        elseif ALLIANCE_RACES[race] then
            color = "3399ff"
        else
            color = "cc99ff"
        end
        local r = tonumber(color:sub(1, 2), 16) / 255
        local g = tonumber(color:sub(3, 4), 16) / 255
        local b = tonumber(color:sub(5, 6), 16) / 255
        y = self:AddBarRow(content, y, {
            label = displayName,
            value = data.count,
            valueText = tostring(data.count),
            maxValue = raceMax,
            r = r,
            g = g,
            b = b,
            tooltipTitle = displayName,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- By Realm
    y = self:AddHeading(content, y, "Characters by Realm")
    local realmSorted = {}
    local realmMax = 0
    for realm, d in pairs(realmData) do
        realmSorted[#realmSorted + 1] = { realm = realm, count = d.count, chars = d.chars }
        if d.count > realmMax then
            realmMax = d.count
        end
    end
    table.sort(realmSorted, function(a, b)
        return a.count > b.count
    end)
    local realmColors = { "55bbff", "ffaa33", "55dd77", "dd77cc", "bbbb44", "77cccc", "cc8855", "99aadd" }
    for idx, data in ipairs(realmSorted) do
        local rc = realmColors[((idx - 1) % #realmColors) + 1]
        local r = tonumber(rc:sub(1, 2), 16) / 255
        local g = tonumber(rc:sub(3, 4), 16) / 255
        local b = tonumber(rc:sub(5, 6), 16) / 255
        y = self:AddBarRow(content, y, {
            label = data.realm,
            value = data.count,
            valueText = tostring(data.count),
            maxValue = realmMax,
            r = r,
            g = g,
            b = b,
            tooltipTitle = data.realm,
            chars = data.chars,
            tooltipFmt = "no_realm",
        })
    end

    return y
end

-------------------------------------------------------------------------------
-- Roster: Professions sub-tab
-------------------------------------------------------------------------------

-- Lookup: expansion label OR apiName (lowercased) -> { id, label }. apiName is
-- what C_TradeSkillUI returns (e.g. "Outland", "Northrend", "Kul Tiran",
-- "Dragon Isles"); label is the display name. Both keys map to the same entry
-- so we can sort by id and re-label the API name when rendering tooltips.
local EXPANSION_LOOKUP = {}
for _, info in ipairs(EmpireManager.EXPANSION_DISPLAY) do
    local entry = { id = info.expansionID, label = info.label }
    EXPANSION_LOOKUP[info.label:lower()] = entry
    if info.apiNames then
        for _, n in ipairs(info.apiNames) do
            EXPANSION_LOOKUP[n:lower()] = entry
        end
    end
end
local EXPANSION_ID_BY_LABEL = {}
for k, v in pairs(EXPANSION_LOOKUP) do
    EXPANSION_ID_BY_LABEL[k] = v.id
end

-- Return a numeric expansion order for an `expansionSkills` entry. Unknown names sort last.
local function ExpansionOrder(expEntry, fallbackIndex)
    if not expEntry or not expEntry.expansionName then
        return 1000 + (fallbackIndex or 0)
    end
    return EXPANSION_ID_BY_LABEL[expEntry.expansionName:lower()] or (1000 + (fallbackIndex or 0))
end

-- Return the skill in the latest expansion this character has data for, in a given profession.
local function GetLatestExpansionSkill(entry, profLabel)
    if not entry.professions then
        return 0
    end
    for _, p in ipairs(entry.professions) do
        if p.name == profLabel then
            if p.expansionSkills and #p.expansionSkills > 0 then
                local bestOrder, bestSkill = -1, 0
                for i, exp in ipairs(p.expansionSkills) do
                    local order = ExpansionOrder(exp, i)
                    if order > bestOrder then
                        bestOrder = order
                        bestSkill = exp.skill or 0
                    end
                end
                return bestSkill
            end
            return p.skill or 0
        end
    end
    return 0
end

-- Render the "Storage: ..." line and combined fill bar for a profession/category.
-- Returns new y. No-op (returns y unchanged) when profAssignments is empty.
function EMRosterPageMixin:RenderStorageSection(content, y, profAssignments)
    if #profAssignments == 0 then
        return y
    end

    -- Build subcat suffix for assignments belonging to a category that has
    -- subcategories defined (equipment_boe/boa, recipes, consumables).
    -- Professions don't have subcats so this is a no-op there.
    local function subcatSuffix(asn)
        if not (asn.subcategories and #asn.subcategories > 0) then
            return ""
        end
        local subcatDef = EmpireManager.SUBCATEGORY_DISPLAY[asn.profession]
        if not subcatDef then
            return ""
        end
        local labels = {}
        for _, sc in ipairs(asn.subcategories) do
            for _, def in ipairs(subcatDef.items) do
                if def.key == sc then
                    labels[#labels + 1] = def.label
                    break
                end
            end
        end
        if #labels == 0 then
            return ""
        end
        return " |cffe0d4a8(" .. table.concat(labels, ", ") .. ")|r"
    end

    local parts = {}
    for _, asn in ipairs(profAssignments) do
        local tabStr = ""
        if asn.tabs and #asn.tabs > 0 then
            tabStr = #asn.tabs == 1 and (" Tab " .. asn.tabs[1]) or (" Tabs " .. table.concat(asn.tabs, ","))
        end
        local sub = subcatSuffix(asn)
        if asn.type == "warbandbank" then
            parts[#parts + 1] = "|cff66b3ffWarband|r Bank" .. tabStr .. sub
        elseif asn.type == "guildbank" then
            local guildPrefix = (asn.guild and asn.guild ~= "") and ("|cff40ff40" .. asn.guild .. "|r ") or ""
            parts[#parts + 1] = guildPrefix .. "|cff40ff40Guild|r Bank" .. tabStr .. sub
        elseif asn.type == "charbank" then
            local charName = "?"
            if asn.char then
                local e = EmpireManager.db.global.registry[asn.char]
                if e then
                    charName = EmpireManager:ClassColoredName(e)
                end
            end
            parts[#parts + 1] = charName .. " Bank" .. tabStr .. sub
        end
    end
    local ROW_H = 24
    local LABEL_COL_W = 64
    local TEXT_TOP_PAD = 5
    local cw = content:GetWidth()
    local totalW = (cw > 20 and cw or 740) - 20

    local row = self:Track(CreateFrame("Frame", nil, content))
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    row:SetSize(totalW, ROW_H)

    local labelFS = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    labelFS:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -TEXT_TOP_PAD)
    labelFS:SetWidth(LABEL_COL_W)
    labelFS:SetJustifyH("RIGHT")
    labelFS:SetJustifyV("TOP")
    labelFS:SetWordWrap(false)
    labelFS:SetText("|cffdaa520Storage:|r")

    local fs = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    fs:SetPoint("TOPLEFT", labelFS, "TOPRIGHT", 6, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:SetSpacing(6)
    fs:SetText(table.concat(parts, ", "))

    local contentH = math.max(fs:GetStringHeight(), labelFS:GetStringHeight())
    local finalH = math.max(ROW_H, contentH + TEXT_TOP_PAD + 6)
    row:SetHeight(finalH)
    y = y + finalH

    local cap = EmpireManager.db.global.storageCapacity or {}
    local totalSum, usedSum = 0, 0
    for _, asn in ipairs(profAssignments) do
        local capSection
        if asn.type == "warbandbank" then
            capSection = cap.warbandbank
        elseif asn.type == "guildbank" and asn.guild then
            local key = EmpireManager:GuildKey(asn.guild, asn.realm)
            capSection = key and cap.guildbank and cap.guildbank[key]
        elseif asn.type == "charbank" and asn.char then
            capSection = cap.charbank and cap.charbank[asn.char]
        end
        local agg = AggregateCapacity(capSection, asn.tabs)
        if agg then
            totalSum = totalSum + agg.total
            usedSum = usedSum + agg.used
        end
    end
    if totalSum > 0 then
        local pct = usedSum / totalSum
        local free = totalSum - usedSum
        y = self:DrawFillBar(content, nil, y, pct, usedSum, totalSum, free) + 2
    end

    return y
end

function EMRosterPageMixin:BuildDeptContent(content, y)
    local assignments = EmpireManager.db.global.storageAssignments or {}

    local firstProf = true
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        local isSecondary = info.category == "secondary"
        local profKey = info.key
        y = self:AddHeading(
            content,
            y,
            string.format(
                "|T%s:16:16|t |cff%02x%02x%02x%s|r",
                info.icon,
                info.r * 255,
                info.g * 255,
                info.b * 255,
                info.label
            ),
            firstProf
        )
        firstProf = false

        -- Collect members and capture each member's latest-expansion skill (for sorting).
        local members = {}
        for guid, entry in pairs(EmpireManager.db.global.registry) do
            local skill = GetLatestExpansionSkill(entry, info.label)
            if EmpireManager:HasProfessionRole(entry, profKey) or skill > 0 then
                members[#members + 1] = { guid = guid, entry = entry, skill = skill }
            end
        end
        -- Highest skill first; tie-break alphabetically by name.
        table.sort(members, function(a, b)
            if a.skill ~= b.skill then
                return a.skill > b.skill
            end
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end)

        local profAssignments = {}
        for _, asn in ipairs(assignments) do
            if asn.profession == profKey then
                profAssignments[#profAssignments + 1] = asn
            end
        end

        y = self:RenderStorageSection(content, y, profAssignments)

        if isSecondary then -- luacheck: ignore 542
        elseif #members > 0 then
            local colW = 160
            local colCount = 0
            for _, m in ipairs(members) do
                local btn = self:Track(CreateFrame("Button", nil, content))
                btn:SetSize(colW, LINE_HEIGHT)
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (colCount % 3) * colW, -y)
                local fs = btn:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
                fs:SetAllPoints()
                fs:SetJustifyH("LEFT")
                local nameText = EmpireManager:ClassColoredName(m.entry)
                if m.skill > 0 then
                    nameText = nameText .. string.format(" (%d)", m.skill)
                end
                fs:SetText(nameText)

                local cGuid, cEntry, profLabel = m.guid, m.entry, info.label
                btn:SetScript("OnClick", function()
                    EmpireManager:OpenSidecar(cGuid)
                end)
                btn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
                    local cc = RAID_CLASS_COLORS[cEntry.class or ""] or NORMAL_FONT_COLOR
                    GameTooltip:AddLine(
                        string.format("%s - %s (%d)", cEntry.name or "?", cEntry.realm or "?", cEntry.level or 0),
                        cc.r,
                        cc.g,
                        cc.b
                    )
                    if cEntry.professions then
                        for _, p in ipairs(cEntry.professions) do
                            if p.name == profLabel and p.expansionSkills then
                                -- Dedupe by expansion. Prefer numeric expansionID
                                -- (locale-proof, written by SnapshotExpansionSkills).
                                -- Fall back to label lookup for legacy/import data.
                                local byKey = {}
                                for _, exp in ipairs(p.expansionSkills) do
                                    local lookup = exp.expansionName and EXPANSION_LOOKUP[exp.expansionName:lower()]
                                        or nil
                                    local id = exp.expansionID or (lookup and lookup.id)
                                    local displayName = (lookup and lookup.label) or exp.expansionName
                                    if displayName and displayName ~= "" and displayName:lower() ~= "unknown" then
                                        local key = id or ("name:" .. displayName:lower())
                                        local existing = byKey[key]
                                        if not existing or (exp.skill or 0) > (existing.skill or 0) then
                                            byKey[key] = {
                                                expansionID = id,
                                                expansionName = displayName,
                                                skill = exp.skill,
                                                maxSkill = exp.maxSkill,
                                            }
                                        end
                                    end
                                end
                                local sorted = {}
                                for _, exp in pairs(byKey) do
                                    local order = exp.expansionID or ExpansionOrder(exp, 0)
                                    sorted[#sorted + 1] = { exp = exp, order = order }
                                end
                                table.sort(sorted, function(a, b)
                                    return a.order < b.order
                                end)
                                for _, e in ipairs(sorted) do
                                    GameTooltip:AddDoubleLine(
                                        string.format("  %s", e.exp.expansionName),
                                        string.format("%d / %d", e.exp.skill, e.exp.maxSkill),
                                        1,
                                        1,
                                        1,
                                        1,
                                        1,
                                        1
                                    )
                                end
                            end
                        end
                    end
                    GameTooltip:AddLine(" ")
                    if cEntry.totalBankSlots and cEntry.totalBankSlots > 0 then
                        local total = cEntry.totalBankSlots
                        local free = cEntry.freeBankSlots or 0
                        local used = total - free
                        local pct = math.floor((used / total) * 100 + 0.5)
                        GameTooltip:AddLine(string.format("Bank: %d/%d (%d%%)", used, total, pct), 1, 0.82, 0)
                    else
                        GameTooltip:AddLine("Bank: no data", 1, 0.82, 0)
                    end
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)

                colCount = colCount + 1
                if colCount % 3 == 0 then
                    y = y + LINE_HEIGHT
                end
            end
            if colCount % 3 ~= 0 then
                y = y + LINE_HEIGHT
            end
        else
            local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
            fs:SetText("|cff999999No members|r")
            y = y + LINE_HEIGHT
        end
        y = y + 4
    end

    return y
end

-------------------------------------------------------------------------------
-- Roster: Categories sub-tab (non-profession storage targets)
-------------------------------------------------------------------------------

function EMRosterPageMixin:BuildCategoriesContent(content, y)
    local assignments = EmpireManager.db.global.storageAssignments or {}

    local firstCat = true
    for _, info in ipairs(EmpireManager.STORAGE_CATEGORY_DISPLAY) do
        local catKey = info.key
        y = self:AddHeading(
            content,
            y,
            string.format(
                "|T%s:16:16|t |cff%02x%02x%02x%s|r",
                info.icon,
                info.r * 255,
                info.g * 255,
                info.b * 255,
                info.label
            ),
            firstCat
        )
        firstCat = false

        local catAssignments = {}
        for _, asn in ipairs(assignments) do
            if asn.profession == catKey then
                catAssignments[#catAssignments + 1] = asn
            end
        end

        if #catAssignments > 0 then
            y = self:RenderStorageSection(content, y, catAssignments)
        else
            local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
            fs:SetText("|cff999999No storage assigned|r")
            y = y + LINE_HEIGHT
        end
        y = y + 4
    end

    return y
end

-------------------------------------------------------------------------------
-- Roster: Roles sub-tab
-------------------------------------------------------------------------------

function EMRosterPageMixin:BuildRoleContent(content, y)
    local ICON16_FMT = EmpireManager.ICON16_FMT

    local firstRole = true
    for _, display in ipairs(EmpireManager.ROLE_DISPLAY) do
        local roleKey = display.key
        local roleColor = string.format("|cff%02x%02x%02x", display.r * 255, display.g * 255, display.b * 255)

        local members = {}
        for guid, entry in pairs(EmpireManager.db.global.registry) do
            if EmpireManager:HasRole(entry, roleKey) then
                members[#members + 1] = { guid = guid, entry = entry }
            end
        end
        table.sort(members, function(a, b)
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end)

        local headingFS
        y, headingFS = self:AddHeading(
            content,
            y,
            string.format("%s" .. ICON16_FMT .. " (%d)|r", roleColor, display.icon, display.label or roleKey, #members),
            firstRole
        )
        firstRole = false

        -- Tooltip (reused from sidecar role-checkbox tooltips)
        local tipText = EmpireManager.ROLE_TOOLTIPS and EmpireManager.ROLE_TOOLTIPS[roleKey]
        if tipText and headingFS then
            local hitRect = self:Track(CreateFrame("Frame", nil, content))
            hitRect:SetAllPoints(headingFS)
            local roleLabel = display.label or roleKey
            hitRect:SetScript("OnEnter", function(f)
                GameTooltip:SetOwner(f, "ANCHOR_CURSOR_RIGHT")
                GameTooltip:AddLine(roleLabel, 1, 0.82, 0)
                GameTooltip:AddLine(" ")
                for line in tipText:gmatch("[^\n]+") do
                    GameTooltip:AddLine(line, 1, 1, 1, true)
                end
                GameTooltip:Show()
            end)
            hitRect:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end

        if #members > 0 then
            local colW = 160
            local maxCols = 4
            local colCount = 0
            for _, m in ipairs(members) do
                local nameText = EmpireManager:ClassColoredName(m.entry)
                if display.profType and m.entry.assignments and m.entry.assignments[roleKey] then
                    local tags = {}
                    for _, pInfo in ipairs(EmpireManager.PROF_DISPLAY) do
                        if m.entry.assignments[roleKey][pInfo.key] then
                            tags[#tags + 1] = string.format("|T%s:14:14|t", pInfo.icon)
                        end
                    end
                    if #tags > 0 then
                        -- 8px transparent spacer between name and profession icons
                        local spacer = "|TInterface\\Common\\Spacer:1:8:0:0:1:1:0:1:0:1|t"
                        nameText = nameText .. spacer .. table.concat(tags, "")
                    end
                end

                local btn = self:Track(CreateFrame("Button", nil, content))
                btn:SetSize(colW, LINE_HEIGHT)
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (colCount % maxCols) * colW, -y)
                local fs = btn:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
                fs:SetAllPoints()
                fs:SetJustifyH("LEFT")
                fs:SetText(nameText)

                local cGuid, cEntry = m.guid, m.entry
                btn:SetScript("OnClick", function()
                    EmpireManager:OpenSidecar(cGuid)
                end)
                btn:SetScript("OnEnter", function(self)
                    EmpireManager:ShowNameTooltip({ frame = self }, cEntry, "ANCHOR_CURSOR_RIGHT")
                end)
                btn:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)

                colCount = colCount + 1
                if colCount % maxCols == 0 then
                    y = y + LINE_HEIGHT
                end
            end
            if colCount % maxCols ~= 0 then
                y = y + LINE_HEIGHT
            end
        else
            local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
            fs:SetText("|cff555555None|r")
            y = y + LINE_HEIGHT
        end
        y = y + 4
    end

    -- Unassigned
    y = self:AddHeading(content, y, "|cff888888Unassigned|r")
    local unassigned = {}
    for guid, entry in pairs(EmpireManager.db.global.registry) do
        if not entry.assignments or not next(entry.assignments) then
            unassigned[#unassigned + 1] = { guid = guid, entry = entry }
        end
    end
    table.sort(unassigned, function(a, b)
        return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
    end)

    if #unassigned > 0 then
        local colW = 160
        local colCount = 0
        for _, m in ipairs(unassigned) do
            local btn = self:Track(CreateFrame("Button", nil, content))
            btn:SetSize(colW, LINE_HEIGHT)
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (colCount % 3) * colW, -y)
            local fs = btn:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
            fs:SetAllPoints()
            fs:SetJustifyH("LEFT")
            fs:SetText(EmpireManager:ClassColoredName(m.entry))

            local cGuid, cEntry = m.guid, m.entry
            btn:SetScript("OnClick", function()
                EmpireManager:OpenSidecar(cGuid)
            end)
            btn:SetScript("OnEnter", function(self)
                EmpireManager:ShowNameTooltip({ frame = self }, cEntry, "ANCHOR_CURSOR_RIGHT")
            end)
            btn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            colCount = colCount + 1
            if colCount % 3 == 0 then
                y = y + LINE_HEIGHT
            end
        end
        if colCount % 3 ~= 0 then
            y = y + LINE_HEIGHT
        end
    else
        local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
        fs:SetText("|cff555555(all characters assigned)|r")
        y = y + LINE_HEIGHT
    end

    return y
end

-------------------------------------------------------------------------------
-- Roster: Banks sub-tab
-------------------------------------------------------------------------------

function EMRosterPageMixin:BuildBankContent(content, y)
    local assignments = EmpireManager.db.global.storageAssignments or {}
    local cap = EmpireManager.db.global.storageCapacity or {}
    local guildBL = EmpireManager.db.global.guildBlacklist or {}

    local function CharBankLabel(charEntry)
        local base = EmpireManager:ClassColoredName(charEntry)
        local realm = charEntry.realm
        if not realm or realm == "" then
            return base
        end
        local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[charEntry.class]
        if color then
            return string.format("%s|cff%02x%02x%02x - %s|r", base, color.r * 255, color.g * 255, color.b * 255, realm)
        end
        return base .. " - " .. realm
    end

    -- Group assignments by bank destination
    local bankOrder, bankMap = {}, {}
    for _, asn in ipairs(assignments) do
        local bankKey, bankLabel, capSection
        if asn.type == "warbandbank" then
            bankKey = "warbandbank"
            bankLabel = "Warband Bank"
            capSection = cap.warbandbank
        elseif asn.type == "guildbank" then
            local guild = asn.guild or "Unknown Guild"
            local realm = asn.realm or ""
            if guildBL[guild] then
                bankKey = nil
            else
                bankKey = "guildbank:" .. guild .. "\1" .. realm
                bankLabel = guild .. " Guild Bank"
                local key = EmpireManager:GuildKey(asn.guild, asn.realm)
                capSection = key and cap.guildbank and cap.guildbank[key]
            end
        elseif asn.type == "charbank" then
            local charEntry = asn.char and EmpireManager.db.global.registry[asn.char]
            if charEntry then
                bankKey = "charbank:" .. asn.char
                bankLabel = CharBankLabel(charEntry)
                capSection = cap.charbank and cap.charbank[asn.char]
            end
        end
        if bankKey then
            if not bankMap[bankKey] then
                bankMap[bankKey] = {
                    label = bankLabel,
                    assignments = {},
                    capSection = capSection,
                    charGuid = (asn.type == "charbank") and asn.char or nil,
                    charEntry = (asn.type == "charbank") and EmpireManager.db.global.registry[asn.char] or nil,
                }
                bankOrder[#bankOrder + 1] = bankKey
            end
            bankMap[bankKey].assignments[#bankMap[bankKey].assignments + 1] = asn
        end
    end

    -- Also include banks we've snapshotted even if no rules reference them yet
    if cap.warbandbank and next(cap.warbandbank) and not bankMap["warbandbank"] then
        bankMap["warbandbank"] = { label = "Warband Bank", assignments = {}, capSection = cap.warbandbank }
        bankOrder[#bankOrder + 1] = "warbandbank"
    end
    if cap.charbank then
        for charGuid, section in pairs(cap.charbank) do
            local key = "charbank:" .. charGuid
            if not bankMap[key] then
                local charEntry = EmpireManager.db.global.registry[charGuid]
                if charEntry then
                    bankMap[key] = {
                        label = CharBankLabel(charEntry),
                        assignments = {},
                        capSection = section,
                        charGuid = charGuid,
                        charEntry = charEntry,
                    }
                    bankOrder[#bankOrder + 1] = key
                end
            end
        end
    end
    if cap.guildbank then
        -- cap.guildbank keys are "GuildName-Realm" composites. Realm names CAN
        -- contain "-" (e.g. "Azjol-Nerub"), so we can't reliably regex-split.
        -- Instead, match each composite against the registry's known
        -- (guild, guildRealm) pairs.
        local knownPairs = {}
        for _, entry in pairs(EmpireManager.db.global.registry or {}) do
            if entry.guild and entry.guild ~= "" and entry.guildRealm and entry.guildRealm ~= "" then
                knownPairs[entry.guild .. "-" .. entry.guildRealm] = { entry.guild, entry.guildRealm }
            end
        end
        for composite, section in pairs(cap.guildbank) do
            local pair = knownPairs[composite]
            local guildName, realm
            if pair then
                guildName, realm = pair[1], pair[2]
            else
                guildName, realm = composite:match("^(.+)-([^-]+)$")
                guildName = guildName or composite
                realm = realm or ""
            end
            local key = "guildbank:" .. guildName .. "\1" .. realm
            if not bankMap[key] and not guildBL[guildName] then
                bankMap[key] = {
                    label = guildName .. " Guild Bank",
                    assignments = {},
                    capSection = section,
                }
                bankOrder[#bankOrder + 1] = key
            end
        end
    end

    if #bankOrder == 0 then
        local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
        fs:SetText("No bank data yet. Open a bank on any character to record capacity.")
        return y + LINE_HEIGHT
    end

    local typePriority = { warbandbank = 1, guildbank = 2, charbank = 3 }
    table.sort(bankOrder, function(a, b)
        local pa = typePriority[a:match("^(%w+)")] or 9
        local pb = typePriority[b:match("^(%w+)")] or 9
        if pa ~= pb then
            return pa < pb
        end
        -- Within the same type, banks WITH rules come before banks without.
        local ruledA = (#bankMap[a].assignments > 0) and 0 or 1
        local ruledB = (#bankMap[b].assignments > 0) and 0 or 1
        if ruledA ~= ruledB then
            return ruledA < ruledB
        end
        return a < b
    end)

    local drawFillBar = function(anchorFS, y, pct, used, total, free, scannedAt)
        return self:DrawFillBar(content, anchorFS, y, pct, used, total, free, scannedAt)
    end

    -- Pre-compute the aggregate capacity across all charbanks so we can show a summary
    -- line above the individual charbank entries. Oldest snapshot wins (worst-case signal).
    local charTotal, charUsed = 0, 0
    local oldestCharScannedAt
    for _, bankKey in ipairs(bankOrder) do
        if bankKey:match("^charbank") then
            local capSection = bankMap[bankKey].capSection
            local agg = AggregateCapacity(capSection, nil)
            if agg then
                charTotal = charTotal + agg.total
                charUsed = charUsed + agg.used
            end
            local sa = capSection and capSection._scannedAt
            if sa and (not oldestCharScannedAt or sa < oldestCharScannedAt) then
                oldestCharScannedAt = sa
            end
        end
    end

    -- Draw a divider only when the bank type changes (e.g., warband→guild, guild→charbank).
    -- Within a type group (especially charbanks), headings flow without a separator.
    local prevType = nil
    local charSummaryDrawn = false
    for _, bankKey in ipairs(bankOrder) do
        local bank = bankMap[bankKey]
        local bankType = bankKey:match("^(%w+)")

        local skipDivider = (prevType == nil)

        -- Insert the "Character Banks" summary above the first charbank entry
        if bankType == "charbank" and not charSummaryDrawn then
            local sumHeadingFS
            y, sumHeadingFS = self:AddHeading(content, y, "All Character Banks", skipDivider)
            charSummaryDrawn = true

            if charTotal > 0 then
                local pct = charUsed / charTotal
                local free = charTotal - charUsed
                y = drawFillBar(sumHeadingFS, y, pct, charUsed, charTotal, free, oldestCharScannedAt)
            end
            -- First charbank below still gets its own divider as a separator after the summary
            skipDivider = false
        end

        local headingFS
        y, headingFS = self:AddHeading(content, y, bank.label, skipDivider)
        prevType = bankType

        -- Charbank headers are clickable - open sidecar for that character
        if bank.charGuid and bank.charEntry then
            local btn = self:Track(CreateFrame("Button", nil, content))
            btn:SetAllPoints(headingFS)
            local cGuid = bank.charGuid
            btn:SetScript("OnClick", function()
                EmpireManager:OpenSidecar(cGuid)
            end)
        end

        -- Aggregate capacity across all tabs for this bank (uses AggregateCapacity helper)
        local agg = AggregateCapacity(bank.capSection, nil)

        if agg then
            local pct = agg.used / agg.total
            local free = agg.total - agg.used
            y = drawFillBar(headingFS, y, pct, agg.used, agg.total, free, bank.capSection and bank.capSection._scannedAt)
        else
            local val = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            val:SetPoint("TOPLEFT", headingFS, "BOTTOMLEFT", 0, -2)
            val:SetText("No data")
            val:SetTextColor(0.5, 0.5, 0.5)
            y = y + LINE_HEIGHT
        end

        local tabMap, anyTab = {}, {}
        for _, asn in ipairs(bank.assignments) do
            local profInfo = EmpireManager.PROF_INFO_BY_KEY[asn.profession]
            local catEntry = { profession = asn.profession, info = profInfo, expansions = asn.expansions }
            if asn.tabs and #asn.tabs > 0 then
                for _, tabNum in ipairs(asn.tabs) do
                    if not tabMap[tabNum] then
                        tabMap[tabNum] = {}
                    end
                    tabMap[tabNum][#tabMap[tabNum] + 1] = catEntry
                end
            else
                anyTab[#anyTab + 1] = catEntry
            end
        end

        local function renderTabRow(labelText, cats, tabCap)
            local parts = {}
            for _, cat in ipairs(cats) do
                local text
                if cat.info then
                    text = string.format(
                        "|cff%02x%02x%02x%s|r",
                        cat.info.r * 255,
                        cat.info.g * 255,
                        cat.info.b * 255,
                        cat.info.label
                    )
                else
                    text = cat.profession
                end
                if cat.expansions and #cat.expansions > 0 then
                    for _, eid in ipairs(cat.expansions) do
                        for _, expInfo in ipairs(EmpireManager.EXPANSION_DISPLAY) do
                            if expInfo.expansionID == eid then
                                text = text .. " " .. EmpireManager:ExpIconString(expInfo, 6)
                                break
                            end
                        end
                    end
                end
                parts[#parts + 1] = text
            end
            local ROW_H = 24
            local LABEL_COL_W = 64
            local TEXT_TOP_PAD = 5
            local cw = content:GetWidth()
            local totalW = (cw > 20 and cw or 740) - 20

            local row = self:Track(CreateFrame("Frame", nil, content))
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            row:SetSize(totalW, ROW_H)

            local labelFS = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
            labelFS:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -TEXT_TOP_PAD)
            labelFS:SetWidth(LABEL_COL_W)
            labelFS:SetJustifyH("RIGHT")
            labelFS:SetJustifyV("TOP")
            labelFS:SetWordWrap(false)
            labelFS:SetText(labelText)

            if tabCap and tabCap.total and tabCap.total > 0 then
                local pct = math.floor((tabCap.used / tabCap.total) * 100)
                local r, g, b
                if pct >= 85 then
                    r, g, b = 1.0, 0.2, 0.2
                elseif pct >= 60 then
                    r, g, b = 1.0, 0.8, 0.0
                else
                    r, g, b = 0.0, 0.8, 0.0
                end
                row:EnableMouse(true)
                local tabLabelClean = labelText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub(":%s*$", "")
                local catsText = table.concat(parts, ", ")
                local slotsText = string.format("Slots: %d/%d (%d%%), %d free", tabCap.used, tabCap.total, pct, tabCap.total - tabCap.used)
                row:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
                    GameTooltip:AddLine(bank.label, 1, 0.82, 0)
                    GameTooltip:AddLine(tabLabelClean, 1, 1, 1)
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(catsText, 1, 1, 1, true)
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(slotsText, r, g, b)
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            end

            local fs = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
            fs:SetPoint("TOPLEFT", labelFS, "TOPRIGHT", 6, 0)
            fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            fs:SetJustifyH("LEFT")
            fs:SetJustifyV("TOP")
            fs:SetWordWrap(true)
            fs:SetText(table.concat(parts, ", "))

            local contentH = math.max(fs:GetStringHeight(), labelFS:GetStringHeight())
            local finalH = math.max(ROW_H, contentH + TEXT_TOP_PAD + 2)
            row:SetHeight(finalH)
            y = y + finalH
        end

        if #anyTab > 0 then
            renderTabRow("|cffdaa520Any Tab:|r", anyTab, nil)
        end
        local tabNums = {}
        for t in pairs(tabMap) do
            tabNums[#tabNums + 1] = t
        end
        table.sort(tabNums)
        for _, tabNum in ipairs(tabNums) do
            local tabCap = bank.capSection and bank.capSection[tabNum]
            renderTabRow("|cffdaa520Tab " .. tabNum .. ":|r", tabMap[tabNum], tabCap)
        end
    end

    return y
end

-------------------------------------------------------------------------------
-- STORAGE PAGE MIXIN
-------------------------------------------------------------------------------

local NO_EXPANSION_FILTER = { pets = true }

-- Storage column layout
local STORAGE_COLUMNS = {
    { key = "reorder", width = 60, label = "" },
    { key = "category", width = 148, label = "Category" },
    { key = "fill", width = 120, label = "Fill Level" },
    { key = "dest", width = 0, label = "Destination", fill = true },
}
local STORAGE_ROW_HEIGHT = 24

-------------------------------------------------------------------------------
-- Helpers (file-local)
-------------------------------------------------------------------------------

-- Returns true if an assignment references a character no longer in the registry.
local function IsOrphanedAssignment(asn)
    if not asn or asn.type ~= "charbank" then
        return false
    end
    if not asn.char or asn.char == "self" then
        return false
    end
    local reg = EmpireManager.db and EmpireManager.db.global and EmpireManager.db.global.registry
    return reg and reg[asn.char] == nil
end

-- Get the number of purchased tabs from capacity data
local function GetTabCount(cap, bankType, charGUID, guildName, guildRealm)
    local section
    if bankType == "warbandbank" then
        section = cap.warbandbank
    elseif bankType == "charbank" and charGUID then
        section = (cap.charbank or {})[charGUID]
    elseif bankType == "guildbank" and guildName then
        local key = EmpireManager:GuildKey(guildName, guildRealm)
        section = key and (cap.guildbank or {})[key]
    end
    if not section then
        return 0
    end
    local n = 0
    for _, v in pairs(section) do
        if type(v) == "table" then
            n = n + 1
        end
    end
    return n
end

-- Format a tab label with fill % from capacity data
local function GetTabLabel(cap, bankType, charGUID, guildName, tabNum, guildRealm)
    local capData
    if bankType == "warbandbank" then
        capData = (cap.warbandbank or {})[tabNum]
    elseif bankType == "charbank" and charGUID then
        capData = ((cap.charbank or {})[charGUID] or {})[tabNum]
    elseif bankType == "guildbank" and guildName then
        local key = EmpireManager:GuildKey(guildName, guildRealm)
        capData = key and (((cap.guildbank or {})[key]) or {})[tabNum]
    end
    if capData and capData.total and capData.total > 0 then
        local pct = math.floor((capData.used / capData.total) * 100)
        return string.format("Tab %d - %d%%", tabNum, pct)
    end
    return "Tab " .. tabNum
end

-- Build destination text for a storage assignment
local function FormatDestText(asn)
    local tabSuffix = ""
    if asn.tabs and #asn.tabs > 0 then
        if #asn.tabs == 1 then
            tabSuffix = " Tab " .. asn.tabs[1]
        else
            tabSuffix = " Tabs " .. table.concat(asn.tabs, ",")
        end
    end
    local destText
    if asn.type == "warbandbank" then
        destText = "|cff66b3ffWarband|r Bank" .. tabSuffix
    elseif asn.type == "guildbank" then
        local prefix = asn.guild and ("|cff40ff40" .. asn.guild .. "|r ") or ""
        destText = prefix .. "|cff40ff40Guild|r Bank" .. tabSuffix
    elseif asn.type == "charbank" then
        if asn.char == "self" then
            destText = "Character Bank" .. tabSuffix
        else
            local charName = "?"
            if asn.char then
                local e = EmpireManager.db.global.registry[asn.char]
                if e then
                    charName = EmpireManager:ClassColoredName(e)
                end
            end
            destText = charName .. " Bank" .. tabSuffix
        end
    else
        destText = (asn.type or "?") .. tabSuffix
    end
    -- Expansion filter tags
    if asn.expansions and #asn.expansions > 0 then
        for _, eid in ipairs(asn.expansions) do
            for _, expInfo in ipairs(EmpireManager.EXPANSION_DISPLAY) do
                if expInfo.expansionID == eid then
                    destText = destText .. " " .. EmpireManager:ExpIconString(expInfo)
                    break
                end
            end
        end
    end
    -- Subcategory tags
    if asn.subcategories and #asn.subcategories > 0 then
        local subcatDef = EmpireManager.SUBCATEGORY_DISPLAY[asn.profession]
        if subcatDef then
            local labels = {}
            for _, sc in ipairs(asn.subcategories) do
                for _, def in ipairs(subcatDef.items) do
                    if def.key == sc then
                        labels[#labels + 1] = def.label
                        break
                    end
                end
            end
            if #labels > 0 then
                destText = destText .. " |cffe0d4a8" .. table.concat(labels, ", ") .. "|r"
            end
        end
    end
    return destText
end

function EmpireManager:FormatStorageDestText(asn)
    return FormatDestText(asn)
end

-- Build sorted char list from registry. Labels are class-colored; sort uses a
-- separate plain-text key so color escapes don't break alphabetical order.
local function BuildCharList()
    local list, plain, order = {}, {}, {}
    for guid, entry in pairs(EmpireManager.db.global.registry) do
        list[guid] = RemapCharLabel(entry)
        plain[guid] = (entry.name or "?") .. " - " .. (entry.realm or "?")
        order[#order + 1] = guid
    end
    table.sort(order, function(a, b)
        return (plain[a] or ""):lower() < (plain[b] or ""):lower()
    end)
    return list, order
end

-- Build guild list from registry, excluding blacklisted
-- Returns a sorted list of unique (guild, realm) pairs across the roster,
-- skipping blacklisted guild names. Display label is "Guild" when the name is
-- unique, "Guild - Realm" when the same name appears on multiple realms.
-- Each entry: { guild = "Vanguard", realm = "Stormrage", label = "Vanguard" }.
local function BuildGuildList()
    local bl = EmpireManager.db.global.guildBlacklist or {}
    local nameCounts, pairs_ = {}, {}
    local seen = {}
    for _, entry in pairs(EmpireManager.db.global.registry) do
        local g = entry.guild
        local r = entry.guildRealm
        if g and g ~= "" and r and r ~= "" and not bl[g] then
            local key = g .. "\1" .. r
            if not seen[key] then
                seen[key] = true
                pairs_[#pairs_ + 1] = { guild = g, realm = r }
                nameCounts[g] = (nameCounts[g] or 0) + 1
            end
        end
    end
    for _, item in ipairs(pairs_) do
        if nameCounts[item.guild] > 1 then
            item.label = item.guild .. " - " .. item.realm
        else
            item.label = item.guild
        end
    end
    table.sort(pairs_, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    return pairs_
end

-------------------------------------------------------------------------------
-- EMStorageRowMixin (virtualized row for ScrollBox pool)
-------------------------------------------------------------------------------

function EMStorageRowMixin:OnLoad()
    local UP_PATH = "Interface\\AddOns\\EmpireManager\\Textures\\up"
    local DOWN_PATH = "Interface\\AddOns\\EmpireManager\\Textures\\down"

    -- Up button (icon, vertically centered in row)
    self.UpBtn = CreateFrame("Button", nil, self)
    self.UpBtn:SetSize(16, 16)
    self.UpBtn:SetPoint("LEFT", self, "LEFT", 12, 0)
    self.UpBtn:SetNormalTexture(UP_PATH)
    self.UpBtn:GetNormalTexture():SetVertexColor(1, 0.82, 0)
    self.UpBtn:SetPushedTexture(UP_PATH)
    self.UpBtn:GetPushedTexture():SetVertexColor(0.8, 0.65, 0)
    self.UpBtn:SetDisabledTexture(UP_PATH)
    self.UpBtn:GetDisabledTexture():SetDesaturated(true)
    self.UpBtn:GetDisabledTexture():SetVertexColor(0.4, 0.4, 0.4)
    self.UpBtn:SetHighlightTexture(UP_PATH, "ADD")
    self.UpBtn:GetHighlightTexture():SetVertexColor(1, 1, 0.6)
    self.UpBtn:GetHighlightTexture():SetAlpha(0.5)
    self.UpBtn:SetScript("OnClick", function()
        local d = self._data
        if not d then
            return
        end
        local a = EmpireManager.db.global.storageAssignments
        local idx = d.idx
        local newIdx = idx
        if IsShiftKeyDown() then
            local target = idx
            for i = idx - 1, 1, -1 do
                if a[i].profession == d.asn.profession then
                    target = i
                    break
                end
            end
            if target < idx then
                local rule = table.remove(a, idx)
                table.insert(a, target, rule)
                newIdx = target
            end
        elseif IsControlKeyDown() then
            local target = math.max(1, idx - 5)
            local rule = table.remove(a, idx)
            table.insert(a, target, rule)
            newIdx = target
        else
            a[idx], a[idx - 1] = a[idx - 1], a[idx]
            newIdx = idx - 1
        end
        EmpireManager._storageScrollToIdx = newIdx
        EmpireManager:InvalidateStorageCache()
        EmpireManager:SelectDashboardTab("storage")
    end)

    -- Down button (icon)
    self.DownBtn = CreateFrame("Button", nil, self)
    self.DownBtn:SetSize(16, 16)
    self.DownBtn:SetPoint("LEFT", self.UpBtn, "RIGHT", 6, 0)
    self.DownBtn:SetNormalTexture(DOWN_PATH)
    self.DownBtn:GetNormalTexture():SetVertexColor(1, 0.82, 0)
    self.DownBtn:SetPushedTexture(DOWN_PATH)
    self.DownBtn:GetPushedTexture():SetVertexColor(0.8, 0.65, 0)
    self.DownBtn:SetDisabledTexture(DOWN_PATH)
    self.DownBtn:GetDisabledTexture():SetDesaturated(true)
    self.DownBtn:GetDisabledTexture():SetVertexColor(0.4, 0.4, 0.4)
    self.DownBtn:SetHighlightTexture(DOWN_PATH, "ADD")
    self.DownBtn:GetHighlightTexture():SetVertexColor(1, 1, 0.6)
    self.DownBtn:GetHighlightTexture():SetAlpha(0.5)
    self.DownBtn:SetScript("OnClick", function()
        local d = self._data
        if not d then
            return
        end
        local a = EmpireManager.db.global.storageAssignments
        local idx = d.idx
        local newIdx = idx
        if IsShiftKeyDown() then
            local target = idx
            for i = idx + 1, #a do
                if a[i].profession == d.asn.profession then
                    target = i
                    break
                end
            end
            if target > idx then
                local rule = table.remove(a, idx)
                table.insert(a, target, rule)
                newIdx = target
            end
        elseif IsControlKeyDown() then
            local target = math.min(#a, idx + 5)
            local rule = table.remove(a, idx)
            table.insert(a, target, rule)
            newIdx = target
        else
            a[idx], a[idx + 1] = a[idx + 1], a[idx]
            newIdx = idx + 1
        end
        EmpireManager._storageScrollToIdx = newIdx
        EmpireManager:InvalidateStorageCache()
        EmpireManager:SelectDashboardTab("storage")
    end)

    -- Category FontString (vertically centered)
    self.CategoryFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.CategoryFs:SetPoint("LEFT", self, "LEFT", 68, 0)
    self.CategoryFs:SetWidth(144)
    self.CategoryFs:SetJustifyH("LEFT")
    self.CategoryFs:SetWordWrap(false)

    -- Fill level bar (full-height, faded; behind the text)
    self.FillBar = self:CreateTexture(nil, "ARTWORK")
    self.FillBar:SetPoint("TOPLEFT", self, "TOPLEFT", 210, -2)
    self.FillBar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 210, 2)
    self.FillBar:SetColorTexture(1, 1, 1, 1)
    self.FillBar:Hide()

    -- Fill level FontString (right-justified, vertically centered)
    self.FillFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.FillFs:SetPoint("LEFT", self, "LEFT", 200, 0)
    self.FillFs:SetWidth(116)
    self.FillFs:SetJustifyH("RIGHT")
    self.FillFs:SetWordWrap(false)

    -- Destination FontString (vertically centered)
    self.DestFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.DestFs:SetPoint("LEFT", self, "LEFT", 336, 0)
    self.DestFs:SetJustifyH("LEFT")
    self.DestFs:SetWordWrap(false)

    -- Click handlers
    self:SetScript("OnClick", function(f, button)
        if button == "RightButton" and f._data then
            EmpireManager:OpenStorageDialog(f._data.idx)
        end
    end)
    self:SetScript("OnDoubleClick", function(f)
        if f._data then
            EmpireManager:OpenStorageDialog(f._data.idx)
        end
    end)
    local function showRowTooltip(f)
        local d = f._data
        if not d then
            return
        end
        GameTooltip:SetOwner(f, "ANCHOR_CURSOR_RIGHT")
        local titleText
        if d.catTotal and d.catTotal > 1 then
            titleText = string.format("Rule #%d  %s (%d/%d)", d.idx, d.profName, d.catIndex or 1, d.catTotal)
        else
            titleText = string.format("Rule #%d  %s", d.idx, d.profName)
        end
        GameTooltip:AddLine(titleText, 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        local destText = FormatDestText(d.asn)
        if d.asn.expansions and #d.asn.expansions > 0 then
            destText = destText:gsub("(|T)", "\n%1", 1)
        end
        GameTooltip:AddLine(destText, 1, 1, 1, true)
        local fillText = f.FillFs:GetText()
        if fillText and fillText ~= "" and fillText ~= "No data" then
            local suffix = ""
            if d.tabData and d.tabData.total then
                suffix = string.format(", %d free", d.tabData.total - (d.tabData.used or 0))
            end
            GameTooltip:AddLine("Slots: " .. fillText .. suffix, f.FillFs:GetTextColor())
        end
        local cap = EmpireManager.db.global.storageCapacity or {}
        local section
        if d.asn.type == "warbandbank" then
            section = cap.warbandbank
        elseif d.asn.type == "guildbank" and d.asn.guild then
            local key = EmpireManager:GuildKey(d.asn.guild, d.asn.realm)
            section = key and cap.guildbank and cap.guildbank[key]
        elseif d.asn.type == "charbank" and d.asn.char then
            section = cap.charbank and cap.charbank[d.asn.char]
        end
        local age = section and EmpireManager:FormatStaleAge(section._scannedAt)
        if age then
            GameTooltip:AddLine("Scanned: " .. age, 1, 1, 1)
        end
        if d.isOrphan then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffff4444Orphaned rule|r", 1, 0.3, 0.3)
            GameTooltip:AddLine(
                "This rule references a character no longer in the roster. Edit or delete it.",
                1,
                1,
                1,
                true
            )
        end
        GameTooltip:Show()
    end

    local function inReorderCol(f)
        local cursorX = GetCursorPosition()
        local scale = f:GetEffectiveScale()
        local relX = (cursorX / scale) - f:GetLeft()
        return relX < 60
    end

    self:SetScript("OnEnter", function(f)
        if not f._data then
            return
        end
        f._tooltipShown = not inReorderCol(f)
        if f._tooltipShown then
            showRowTooltip(f)
        end
        f._tooltipTimer = 0
        f:SetScript("OnUpdate", function(fr, elapsed)
            fr._tooltipTimer = (fr._tooltipTimer or 0) + elapsed
            if fr._tooltipTimer < 0.1 then
                return
            end
            fr._tooltipTimer = 0
            if not fr._data then
                return
            end
            local inCol = inReorderCol(fr)
            if inCol and fr._tooltipShown then
                GameTooltip:Hide()
                fr._tooltipShown = false
            elseif not inCol and not fr._tooltipShown then
                showRowTooltip(fr)
                fr._tooltipShown = true
            end
        end)
    end)
    self:SetScript("OnLeave", function(f)
        f:SetScript("OnUpdate", nil)
        f._tooltipShown = false
        GameTooltip:Hide()
    end)
end

function EMStorageRowMixin:Populate(data)
    self._data = data
    local idx = data.idx
    local asn = data.asn

    -- Zebra stripe (AH-style atlas, matches Characters tab)
    if idx % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetAtlas("auctionhouse-rowstripe-2")
    end

    -- Up/down enable state
    self.UpBtn:SetEnabled(idx > 1)
    self.DownBtn:SetEnabled(idx < data.totalCount)

    -- Category
    local pInfo = EmpireManager.PROF_INFO_BY_KEY[asn.profession]
    local profColor = "ffffff"
    local profIcon = ""
    if pInfo then
        profColor = string.format("%02x%02x%02x", pInfo.r * 255, pInfo.g * 255, pInfo.b * 255)
        profIcon = string.format("|T%s:16:16|t ", pInfo.icon)
    end
    local profName = (pInfo and pInfo.label) or (asn.profession:sub(1, 1):upper() .. asn.profession:sub(2))
    data.profName = profName
    self.CategoryFs:SetText(profIcon .. "|cff" .. profColor .. profName .. "|r")

    -- Destination (flag orphaned charbank rules whose character is no longer in the registry)
    local isOrphan = IsOrphanedAssignment(asn)
    data.isOrphan = isOrphan
    local destText = FormatDestText(asn)
    if isOrphan then
        destText = "|cffff4444[!]|r " .. destText
    end
    self.DestFs:SetText(destText)
    self.DestFs:SetTextColor(1, 1, 1)

    -- Fill level
    local tabData = data.tabData
    if tabData and tabData.total and tabData.total > 0 then
        local pct = math.floor((tabData.used / tabData.total) * 100)
        self.FillFs:SetText(string.format("%d/%d (%d%%)", tabData.used, tabData.total, pct))
        local r, g, b
        if pct >= 85 then
            r, g, b = 1.0, 0.2, 0.2
        elseif pct >= 60 then
            r, g, b = 1.0, 0.8, 0.0
        else
            r, g, b = 0.0, 0.8, 0.0
        end
        self.FillFs:SetTextColor(r, g, b)
        local barWidth = math.max(1, math.floor(116 * (pct / 100) + 0.5))
        self.FillBar:SetWidth(barWidth)
        self.FillBar:SetVertexColor(r, g, b, 0.18)
        self.FillBar:Show()
    elseif asn.type == "charbank" and asn.char == "self" then
        self.FillFs:SetText("")
        self.FillBar:Hide()
    else
        self.FillFs:SetText("No data")
        self.FillFs:SetTextColor(0.5, 0.5, 0.5)
        self.FillBar:Hide()
    end
end

-------------------------------------------------------------------------------
-- EMStoragePageMixin
-------------------------------------------------------------------------------

function EMStoragePageMixin:OnLoad()
    self.ScrollBox = self.Inset.ScrollBox
    self.ScrollBar = self.Inset.ScrollBar

    -- ScrollBox view with two element types
    local view = CreateScrollBoxListLinearView()
    view:SetElementFactory(function(factory, elementData)
        if elementData.type == "rule" then
            factory("EMStorageRowTemplate", function(frame, data)
                if not frame._mixinApplied then
                    Mixin(frame, EMStorageRowMixin)
                    frame:OnLoad()
                    frame._mixinApplied = true
                end
                frame:Populate(data)
            end)
        else
            factory("EMStorageNoticeTemplate", function(frame, data)
                if not frame._noticeInit then
                    frame.Text = frame:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
                    frame.Text:SetPoint("TOPLEFT", 8, -4)
                    frame.Text:SetPoint("RIGHT", -8, 0)
                    frame.Text:SetJustifyH("LEFT")
                    frame._noticeInit = true
                end
                frame.Text:SetWordWrap(true)
                frame.Text:SetNonSpaceWrap(true)
                if data.type == "empty_notice" then
                    frame.Text:SetText("\nNo storage assignments configured yet. Click 'Add Rule' to create one, or click the wand icon to use the Setup Wizard.")
                    frame.Text:SetTextColor(1, 1, 1)
                else
                    frame.Text:SetText(data.text)
                    frame.Text:SetTextColor(1, 1, 1)
                end
            end)
        end
    end)
    view:SetElementExtentCalculator(function(_dataIndex, elementData)
        if elementData.type == "empty_notice" then
            return 40
        end
        if elementData.type == "notice" then
            return elementData.height or 24
        end
        return STORAGE_ROW_HEIGHT
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(self.ScrollBox, self.ScrollBar, view)

    -- Import/Export button (icon-only, texture set in XML)
    local ieBtn = self.IEButton
    EmpireManager:StyleIconButton(ieBtn, 0.5)
    ieBtn:SetScript("OnClick", function()
        local ie = EmpireManagerIOFrame
        if ie and ie:IsShown() then
            return
        end
        local sd = EmpireManagerStorageDialog
        if sd and sd:IsShown() then
            sd:Hide()
        end
        EmpireManager:ToggleIOWindow()
    end)
    ieBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Import / Export", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Import or export storage rules and character roster.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ieBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Add Rule icon button (texture set in XML)
    EmpireManager:StyleIconButton(self.AddButton, 0.5)
    self.AddButton:SetScript("OnClick", function()
        local sd = EmpireManagerStorageDialog
        if sd and sd:IsShown() then
            return
        end
        local ie = EmpireManagerIOFrame
        if ie and ie:IsShown() then
            ie:Hide()
        end
        EmpireManager:OpenStorageDialog(nil)
    end)
    self.AddButton:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Add Rule", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Create a new storage assignment.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    self.AddButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Wand icon button: opens the Storage Setup Wizard (texture set in XML)
    if self.WandButton then
        EmpireManager:StyleIconButton(self.WandButton, 0.5)
        self.WandButton:SetScript("OnClick", function()
            local sd = EmpireManagerStorageDialog
            if sd and sd:IsShown() then
                sd:Hide()
            end
            local ie = EmpireManagerIOFrame
            if ie and ie:IsShown() then
                ie:Hide()
            end
            EmpireManager:OpenWizard()
        end)
        self.WandButton:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Storage Setup Wizard", 1, 0.82, 0)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Quickly create Storage Rules from a template.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        self.WandButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    -- Column headers
    self:InitStorageHeaders()
end

function EMStoragePageMixin:InitStorageHeaders()
    local container = self.Inset.HeaderContainer
    local xOffset = 0
    for _, col in ipairs(STORAGE_COLUMNS) do
        local btn = CreateFrame("Button", nil, container, "ColumnDisplayButtonShortTemplate")
        if col.fill then
            btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
            btn:SetPoint("RIGHT", container, "RIGHT", 0, 0)
            btn:SetHeight(19)
        else
            btn:SetSize(col.width, 19)
            btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
        end
        btn:SetText(col.label)
        btn:SetNormalFontObject(GameFontHighlightSmall)
        btn:GetFontString():SetJustifyH("LEFT")
        btn:SetEnabled(false)
        xOffset = xOffset + col.width
    end
end

function EMStoragePageMixin:OnShow()
    self:Refresh()
end

function EMStoragePageMixin:Refresh()
    local assignments = EmpireManager.db.global.storageAssignments or {}
    local cap = EmpireManager.db.global.storageCapacity or {}
    local data = {}

    if #assignments == 0 then
        data[#data + 1] = { type = "empty_notice" }
    else
        -- Per-category totals (for "Rule #N <Category> (x/y)" tooltip).
        local catTotals = {}
        for _, asn in ipairs(assignments) do
            local k = asn.profession or ""
            catTotals[k] = (catTotals[k] or 0) + 1
        end
        local catSeen = {}

        for i, asn in ipairs(assignments) do
            local tabData
            if asn.type == "warbandbank" then
                tabData = AggregateCapacity(cap.warbandbank, asn.tabs)
            elseif asn.type == "guildbank" and asn.guild then
                local key = EmpireManager:GuildKey(asn.guild, asn.realm)
                tabData = AggregateCapacity(key and cap.guildbank and cap.guildbank[key], asn.tabs)
            elseif asn.type == "charbank" and asn.char then
                tabData = AggregateCapacity(cap.charbank and cap.charbank[asn.char], asn.tabs)
            end
            local catKey = asn.profession or ""
            catSeen[catKey] = (catSeen[catKey] or 0) + 1
            data[#data + 1] = {
                type = "rule",
                idx = i,
                asn = asn,
                tabData = tabData,
                totalCount = #assignments,
                catIndex = catSeen[catKey],
                catTotal = catTotals[catKey] or 1,
            }
        end
    end

    -- Unconfigured notice (estimate height from text length for wrapping)
    local noticeText = self:BuildUnconfiguredText(assignments)
    if noticeText then
        -- strip color codes for length estimate
        local plainLen = #(noticeText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        local lines = math.max(1, math.ceil(plainLen / 95))
        local noticeHeight = lines * 16 + 12
        data[#data + 1] = { type = "notice", text = noticeText, height = noticeHeight }
    end

    -- Preserve scroll position across rebuilds (live capacity refresh in
    -- particular replaces the data provider without changing the rule list).
    local savedOffset = self.ScrollBox:GetScrollPercentage()

    local dataProvider = CreateDataProvider(data)
    self.ScrollBox:SetDataProvider(dataProvider)

    -- Scroll-follow after reorder wins over saved-offset restore.
    local scrollTo = EmpireManager._storageScrollToIdx
    EmpireManager._storageScrollToIdx = nil
    if scrollTo and scrollTo > 0 then
        C_Timer.After(0, function()
            local dp = self.ScrollBox:GetDataProvider()
            if not dp then
                return
            end
            for _, elementData in dp:Enumerate() do
                if elementData.type == "rule" and elementData.idx == scrollTo then
                    self.ScrollBox:ScrollToElementData(elementData, ScrollBoxConstants.AlignCenter)
                    break
                end
            end
        end)
    elseif savedOffset and savedOffset >= 0 then
        C_Timer.After(0, function()
            if self.ScrollBox:GetDataProvider() then
                self.ScrollBox:SetScrollPercentage(savedOffset)
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- Storage Dialog (Modal - Add/Edit)
-------------------------------------------------------------------------------

function EmpireManager:InitStorageDialog()
    local f = EmpireManagerStorageDialog
    if f._initialized then
        return f
    end
    f._initialized = true

    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
    f:RegisterForDrag("LeftButton")

    f.SaveButton:SetText("Save")
    f.DeleteButton:SetText("|cffff4444Delete|r")
    f.CancelButton:SetText("Cancel")

    f.CancelButton:ClearAllPoints()
    f.CancelButton:SetPoint("RIGHT", f.SaveButton, "LEFT", -4, 0)
    f.CancelButton:SetScript("OnClick", function()
        f:Hide()
    end)
    f.CloseButton:SetScript("OnClick", function()
        f:Hide()
    end)

    -- ESC closes the dialog (not the dashboard behind it)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- Create dropdowns (persistent across opens, menus rebuilt each time)
    local DD_WIDTH = 270
    local function MakeDropdown(row, template)
        local dd = CreateFrame("DropdownButton", nil, row, template or "WowStyle1DropdownTemplate")
        dd:SetPoint("LEFT", row.Label, "RIGHT", 4, 0)
        dd:SetWidth(DD_WIDTH)
        return dd
    end

    f.CategoryDD = MakeDropdown(f.Row1)
    f.BankTypeDD = MakeDropdown(f.Row2)
    f.TabsDD = MakeDropdown(f.Row3, "WowStyle1FilterDropdownTemplate")
    f.CharDD = MakeDropdown(f.Row4)
    f.GuildDD = MakeDropdown(f.Row5)
    f.ExpDD = MakeDropdown(f.Row6, "WowStyle1FilterDropdownTemplate")
    f.SubcatDD = MakeDropdown(f.Row7)

    return f
end

function EmpireManager:OpenStorageDialog(editIdx)
    local f = self:InitStorageDialog()
    local isEdit = editIdx ~= nil
    local asn = isEdit and self.db.global.storageAssignments[editIdx] or nil

    f.TitleText:SetText(
        isEdit and ("EmpireManager - Edit Storage Rule #" .. editIdx) or "EmpireManager - Add Storage Rule"
    )
    f.DeleteButton:SetShown(isEdit)

    -- Dialog state
    local st = {}
    if isEdit and asn then
        st.prof = asn.profession
        st.bankType = asn.type
        st.char = asn.char
        st.guild = asn.guild
        st.guildRealm = asn.realm
        st.tabs = {}
        for _, t in ipairs(asn.tabs or {}) do
            st.tabs[tostring(t)] = true
        end
        st.expansions = {}
        for _, eid in ipairs(asn.expansions or {}) do
            st.expansions[tostring(eid)] = true
        end
        st.subcategories = {}
        for _, sc in ipairs(asn.subcategories or {}) do
            st.subcategories[sc] = true
        end
    else
        st.prof = nil
        st.bankType = nil
        st.char = nil
        st.guild = nil
        st.guildRealm = nil
        st.tabs = {}
        st.expansions = {}
        st.subcategories = {}
    end
    f._state = st

    local cap = self.db.global.storageCapacity or {}

    -- Helper: rebuild layout (show/hide conditional rows, resize dialog)
    local function UpdateLayout()
        local showChar = (st.bankType == "charbank")
        local showGuild = (st.bankType == "guildbank")
        local showExp = st.prof and not NO_EXPANSION_FILTER[st.prof]
        local subcatDef = st.prof and self.SUBCATEGORY_DISPLAY[st.prof]
        local showSubcat = subcatDef ~= nil

        f.Row4:SetShown(showChar)
        f.Row5:SetShown(showGuild)
        f.Row6:SetShown(showExp or false)
        f.Row7:SetShown(showSubcat)

        -- Reanchor rows dynamically
        local prevRow = f.Row3
        if showChar then
            f.Row4:ClearAllPoints()
            f.Row4:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT")
            f.Row4:SetPoint("RIGHT", f, "RIGHT", -14, 0)
            prevRow = f.Row4
        end
        if showGuild then
            f.Row5:ClearAllPoints()
            f.Row5:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT")
            f.Row5:SetPoint("RIGHT", f, "RIGHT", -14, 0)
            prevRow = f.Row5
        end
        if showExp then
            f.Row6:ClearAllPoints()
            f.Row6:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT")
            f.Row6:SetPoint("RIGHT", f, "RIGHT", -14, 0)
            prevRow = f.Row6
        end
        if showSubcat then
            f.Row7:ClearAllPoints()
            f.Row7:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT")
            f.Row7:SetPoint("RIGHT", f, "RIGHT", -14, 0)
            prevRow = f.Row7
        end

        -- Resize dialog to fit visible rows
        -- Layout: 56 top padding (title) + rows + 24 gap + 40 button area
        local rowCount = 3
            + (showChar and 1 or 0)
            + (showGuild and 1 or 0)
            + (showExp and 1 or 0)
            + (showSubcat and 1 or 0)
        f:SetHeight(56 + rowCount * 32 + 24 + 40)

        -- Update dropdown display text
        -- Category
        local catLabel
        for _, info in ipairs(self.PROF_DISPLAY) do
            if info.key == st.prof then
                catLabel = info.label
                break
            end
        end
        if not catLabel then
            for _, info in ipairs(self.STORAGE_CATEGORY_DISPLAY) do
                if info.key == st.prof then
                    catLabel = info.label
                    break
                end
            end
        end
        f.CategoryDD:OverrideText(catLabel or "Select category")

        -- Bank type
        local btLabels = { warbandbank = "Warband Bank", guildbank = "Guild Bank", charbank = "Character Bank" }
        f.BankTypeDD:OverrideText(st.bankType and btLabels[st.bankType] or "Select bank type")

        -- Tabs
        local tabNums = {}
        for k in pairs(st.tabs) do
            tabNums[#tabNums + 1] = tonumber(k)
        end
        table.sort(tabNums)
        if #tabNums > 0 then
            local parts = {}
            for _, t in ipairs(tabNums) do
                parts[#parts + 1] = tostring(t)
            end
            f.TabsDD:SetText("Tab " .. table.concat(parts, ", "))
        else
            f.TabsDD:SetText("Any Tab")
        end

        -- Character
        if showChar then
            if st.char then
                local charList = BuildCharList()
                f.CharDD:OverrideText(charList[st.char] or st.char)
            else
                f.CharDD:OverrideText("Select Character")
            end
        end

        -- Guild
        if showGuild then
            f.GuildDD:OverrideText(st.guild or "Select Guild")
        end

        -- Expansions
        if showExp then
            local expIcons = {}
            for i = #self.EXPANSION_DISPLAY, 1, -1 do
                local expInfo = self.EXPANSION_DISPLAY[i]
                if st.expansions[tostring(expInfo.expansionID)] then
                    expIcons[#expIcons + 1] = EmpireManager:ExpIconString(expInfo)
                end
            end
            local total = #expIcons
            local text
            if total == 0 or total == #self.EXPANSION_DISPLAY then
                text = "Any Expansion"
            elseif total > 4 then
                text = table.concat(expIcons, " ", 1, 4) .. string.format(" +%d", total - 4)
            else
                text = table.concat(expIcons, " ")
            end
            f.ExpDD:SetText(text)
        end

        -- Subcategory
        if showSubcat and subcatDef then
            local scNames = {}
            for _, sc in ipairs(subcatDef.items) do
                if st.subcategories[sc.key] then
                    scNames[#scNames + 1] = sc.label
                end
            end
            f.SubcatDD:OverrideText(#scNames > 0 and table.concat(scNames, ", ") or "Any")
        end

        -- Save button: enable only when all required fields are filled.
        local valid = st.prof and st.bankType
        if st.bankType == "charbank" and not st.char then
            valid = false
        end
        if st.bankType == "guildbank" and (not st.guild or st.guild == "") then
            valid = false
        end
        if subcatDef and subcatDef.mode == "single" and not next(st.subcategories) then
            valid = false
        end
        f.SaveButton:SetEnabled(valid and true or false)
    end

    -- Category dropdown
    f.CategoryDD:SetEnabled(not isEdit)
    f.CategoryDD:SetupMenu(function(_, rootDescription)
        -- Professions
        for _, info in ipairs(self.PROF_DISPLAY) do
            rootDescription:CreateRadio(string.format("|T%s:14:14|t %s", info.icon, info.label), function()
                return st.prof == info.key
            end, function()
                st.prof = info.key
                st.subcategories = {}
                C_Timer.After(0, UpdateLayout)
            end)
        end
        rootDescription:CreateDivider()
        -- Storage categories
        for _, info in ipairs(self.STORAGE_CATEGORY_DISPLAY) do
            rootDescription:CreateRadio(string.format("|T%s:14:14|t %s", info.icon, info.label), function()
                return st.prof == info.key
            end, function()
                st.prof = info.key
                st.subcategories = {}
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)

    -- Bank Type dropdown
    f.BankTypeDD:SetupMenu(function(_, rootDescription)
        for _, bt in ipairs({ "warbandbank", "guildbank", "charbank" }) do
            local labels = { warbandbank = "Warband Bank", guildbank = "Guild Bank", charbank = "Character Bank" }
            rootDescription:CreateRadio(labels[bt], function()
                return st.bankType == bt
            end, function()
                st.bankType = bt
                st.char = nil
                st.guild = nil
                st.guildRealm = nil
                st.tabs = {}
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)

    -- Tabs filter dropdown
    f.TabsDD:SetupMenu(function(_, rootDescription)
        rootDescription:SetTag("EM_STORAGE_TABS")
        local count = GetTabCount(cap, st.bankType, st.char, st.guild, st.guildRealm)
        if count == 0 then
            local msg
            if not st.bankType then
                msg = "Select a Bank Type first"
            elseif st.bankType == "guildbank" and not st.guild then
                msg = "Select a Guild first"
            elseif st.bankType == "charbank" and not st.char then
                msg = "Select a Character first"
            else
                msg = "No tabs found (open bank first)"
            end
            rootDescription:CreateTitle(msg)
        else
            for t = 1, count do
                local key = tostring(t)
                rootDescription:CreateCheckbox(GetTabLabel(cap, st.bankType, st.char, st.guild, t, st.guildRealm), function()
                    return st.tabs[key] or false
                end, function()
                    st.tabs[key] = not st.tabs[key] or nil
                    C_Timer.After(0, UpdateLayout)
                end)
            end
        end
    end)

    -- Character dropdown
    local charSelIdx
    f.CharDD:SetupMenu(function(_, rootDescription)
        rootDescription:SetScrollMode(20 * 20)
        charSelIdx = nil
        local charList, charOrder = BuildCharList()
        for i, guid in ipairs(charOrder) do
            if guid == st.char then charSelIdx = i end
            rootDescription:CreateRadio(charList[guid], function()
                return st.char == guid
            end, function()
                st.char = guid
                st.tabs = {}
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)
    self:EnableDropdownScrollToSelected(f.CharDD, function() return charSelIdx end)

    -- Guild dropdown
    local guildSelIdx
    f.GuildDD:SetupMenu(function(_, rootDescription)
        rootDescription:SetScrollMode(20 * 20)
        guildSelIdx = nil
        local guilds = BuildGuildList()
        for i, item in ipairs(guilds) do
            if item.guild == st.guild and item.realm == st.guildRealm then guildSelIdx = i end
            rootDescription:CreateRadio(item.label, function()
                return st.guild == item.guild and st.guildRealm == item.realm
            end, function()
                st.guild = item.guild
                st.guildRealm = item.realm
                st.tabs = {}
                local banker = self:FindCharInGuild(item.guild, nil, item.realm)
                if banker then
                    st.char = banker
                end
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)
    self:EnableDropdownScrollToSelected(f.GuildDD, function() return guildSelIdx end)

    -- Expansions filter dropdown
    f.ExpDD:SetupMenu(function(_, rootDescription)
        rootDescription:SetTag("EM_STORAGE_EXP")

        -- Toggle-all button: if any are checked, clear all; otherwise select all.
        local anyChecked = false
        for _, expInfo in ipairs(self.EXPANSION_DISPLAY) do
            if st.expansions[tostring(expInfo.expansionID)] then
                anyChecked = true
                break
            end
        end
        local toggleLabel = anyChecked and "Clear All" or "Select All"
        rootDescription:CreateButton(toggleLabel, function()
            if anyChecked then
                wipe(st.expansions)
            else
                for _, expInfo in ipairs(self.EXPANSION_DISPLAY) do
                    st.expansions[tostring(expInfo.expansionID)] = true
                end
            end
            C_Timer.After(0, UpdateLayout)
        end)
        rootDescription:CreateDivider()

        for i = #self.EXPANSION_DISPLAY, 1, -1 do
            local expInfo = self.EXPANSION_DISPLAY[i]
            local key = tostring(expInfo.expansionID)
            rootDescription:CreateCheckbox(
                EmpireManager:ExpIconString(expInfo)
                    .. string.format(
                        " |cff%02x%02x%02x%s|r",
                        expInfo.r * 255,
                        expInfo.g * 255,
                        expInfo.b * 255,
                        expInfo.label
                    ),
                function()
                    return st.expansions[key] or false
                end,
                function()
                    st.expansions[key] = not st.expansions[key] or nil
                    C_Timer.After(0, UpdateLayout)
                end
            )
        end
    end)

    -- Subcategory dropdown
    f.SubcatDD:SetupMenu(function(_, rootDescription)
        local subcatDef = self.SUBCATEGORY_DISPLAY[st.prof]
        if not subcatDef then
            return
        end
        if subcatDef.mode == "single" then
            for _, sc in ipairs(subcatDef.items) do
                rootDescription:CreateRadio(sc.label, function()
                    return st.subcategories[sc.key] or false
                end, function()
                    wipe(st.subcategories)
                    st.subcategories[sc.key] = true
                    C_Timer.After(0, UpdateLayout)
                end)
            end
        else
            rootDescription:SetTag("EM_STORAGE_SUBCAT")
            for _, sc in ipairs(subcatDef.items) do
                rootDescription:CreateCheckbox(sc.label, function()
                    return st.subcategories[sc.key] or false
                end, function()
                    st.subcategories[sc.key] = not st.subcategories[sc.key] or nil
                    C_Timer.After(0, UpdateLayout)
                end)
            end
        end
    end)

    -- Save button
    f.SaveButton:SetScript("OnClick", function()
        if not st.prof then
            self:ChatMsg("Select a category", true)
            return
        end
        if not st.bankType then
            self:ChatMsg("Select a bank type", true)
            return
        end
        if st.bankType == "charbank" and not st.char then
            self:ChatMsg("Select a banker character", true)
            return
        end
        if st.bankType == "guildbank" and (not st.guild or st.guild == "") then
            self:ChatMsg("Select a Guild", true)
            return
        end

        local subcatDef = self.SUBCATEGORY_DISPLAY[st.prof]
        if subcatDef and subcatDef.mode == "single" and not next(st.subcategories) then
            self:ChatMsg("Select a subcategory", true)
            return
        end

        -- Build entry
        local tabsArray = {}
        for k in pairs(st.tabs) do
            tabsArray[#tabsArray + 1] = tonumber(k)
        end
        table.sort(tabsArray)
        local expArray = {}
        for k in pairs(st.expansions) do
            expArray[#expArray + 1] = tonumber(k)
        end
        local subcatArray = {}
        for k in pairs(st.subcategories) do
            subcatArray[#subcatArray + 1] = k
        end

        -- Collapse "all selected" to "none selected": both mean "any", so clear
        -- the list to keep display/runtime consistent.
        local tabTotal = GetTabCount(cap, st.bankType, st.char, st.guild, st.guildRealm)
        if tabTotal > 0 and #tabsArray >= tabTotal then
            tabsArray = {}
        end
        if #expArray >= #EmpireManager.EXPANSION_DISPLAY then
            expArray = {}
        end
        if subcatDef and subcatDef.items and #subcatArray >= #subcatDef.items then
            subcatArray = {}
        end

        local newEntry = {
            profession = st.prof,
            type = st.bankType,
            tabs = #tabsArray > 0 and tabsArray or nil,
        }
        if st.bankType == "charbank" then
            newEntry.char = st.char
        end
        if st.bankType == "guildbank" then
            newEntry.guild = st.guild
            newEntry.realm = st.guildRealm
            if st.char then
                newEntry.char = st.char
            end
        end
        if #expArray > 0 then
            newEntry.expansions = expArray
        end
        if #subcatArray > 0 then
            newEntry.subcategories = subcatArray
        end

        -- Duplicate check (skip self in edit mode)
        local function SameSet(a, b)
            -- Compare two arrays-as-sets (nil/empty treated as equal)
            a = a or {}
            b = b or {}
            if #a ~= #b then
                return false
            end
            local setA = {}
            for _, v in ipairs(a) do
                setA[tostring(v)] = true
            end
            for _, v in ipairs(b) do
                if not setA[tostring(v)] then
                    return false
                end
            end
            return true
        end
        local assignments = self.db.global.storageAssignments
        for i, existing in ipairs(assignments) do
            if
                (not isEdit or i ~= editIdx)
                and existing.profession == newEntry.profession
                and existing.type == newEntry.type
                and existing.char == newEntry.char
                and existing.guild == newEntry.guild
                and (existing.realm or "") == (newEntry.realm or "")
                and SameSet(existing.expansions, newEntry.expansions)
                and SameSet(existing.subcategories, newEntry.subcategories)
            then
                self:ChatMsg("A rule for this category and destination already exists", true)
                return
            end
        end

        if isEdit then
            assignments[editIdx] = newEntry
            EmpireManager._storageScrollToIdx = editIdx
        else
            assignments[#assignments + 1] = newEntry
            EmpireManager._storageScrollToIdx = #assignments
        end

        if newEntry.char and newEntry.char ~= "self" then
            self:SyncBankerRole(newEntry.char)
        end
        self:InvalidateStorageCache()
        f:Hide()
        self:SelectDashboardTab("storage")
    end)

    -- Delete button (edit only)
    f.DeleteButton:SetScript("OnClick", function()
        if not isEdit then
            return
        end
        StaticPopupDialogs["EM_DELETE_STORAGE_RULE"] = StaticPopupDialogs["EM_DELETE_STORAGE_RULE"]
            or {
                text = "Delete this storage rule?",
                button1 = "Delete",
                button2 = "Cancel",
                OnAccept = function() end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                showAlert = true,
                preferredIndex = 3,
            }
        StaticPopupDialogs["EM_DELETE_STORAGE_RULE"].OnAccept = function()
            table.remove(self.db.global.storageAssignments, editIdx)
            self:InvalidateStorageCache()
            f:Hide()
            self:SelectDashboardTab("storage")
        end
        StaticPopup_Show("EM_DELETE_STORAGE_RULE")
    end)

    UpdateLayout()
    f:Show()
end

-------------------------------------------------------------------------------
-- Unconfigured Categories Notice
-------------------------------------------------------------------------------

function EMStoragePageMixin:BuildUnconfiguredText(assignments)
    local configuredProfs = {}
    for _, asn in ipairs(assignments) do
        configuredProfs[asn.profession] = true
    end
    local missing = {}
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        if not configuredProfs[info.key] then
            missing[#missing + 1] =
                string.format("|cff%02x%02x%02x%s|r", info.r * 255, info.g * 255, info.b * 255, info.label)
        end
    end
    for _, info in ipairs(EmpireManager.STORAGE_CATEGORY_DISPLAY) do
        if not configuredProfs[info.key] then
            missing[#missing + 1] =
                string.format("|cff%02x%02x%02x%s|r", info.r * 255, info.g * 255, info.b * 255, info.label)
        end
    end
    if #missing > 0 then
        local lines = { "Not configured:" }
        for i = 1, #missing, 7 do
            local row = {}
            for j = i, math.min(i + 6, #missing) do
                row[#row + 1] = missing[j]
            end
            lines[#lines + 1] = table.concat(row, ", ")
        end
        return table.concat(lines, "\n")
    end
    return nil
end

-------------------------------------------------------------------------------
-- Import / Export
-------------------------------------------------------------------------------

function EmpireManager:InitIOFrame()
    local f = EmpireManagerIOFrame
    if f._initialized then
        return
    end
    f._initialized = true

    -- Backdrop
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)

    -- Title
    f.TitleText:SetText("EmpireManager - Import/Export")

    -- Subtitle: explain the dialog handles both directions
    local subtitle = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    subtitle:SetPoint("TOP", f.TitleText, "BOTTOM", 0, -8)
    subtitle:SetPoint("LEFT", f, "LEFT", 24, 0)
    subtitle:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    subtitle:SetJustifyH("CENTER")
    subtitle:SetWordWrap(true)
    subtitle:SetText("|cffdaa520Characters and Storage Rules can be exported for sharing/backup or imported.|r")
    -- Push the EditScroll down to clear the new line.
    f.EditScroll:ClearAllPoints()
    f.EditScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 32, -84)

    -- Close button
    f.CloseButton:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
        f:Hide()
    end)

    -- Draggable
    f:RegisterForDrag("LeftButton")

    -- ESC registration
    _G["EmpireManagerIO"] = f
    if self.db.global.options.escToClose and not tContains(UISpecialFrames, "EmpireManagerIO") then
        tinsert(UISpecialFrames, "EmpireManagerIO")
    end

    -- Edit box reference
    local editBox = f.EditScroll.EditBox

    -- Disable wrap: force a wide fixed width so long lines scroll horizontally
    -- instead of wrapping. InputScrollFrameTemplate normally resizes the
    -- EditBox to match the ScrollFrame width on every size change, so we
    -- clear that script and pin it wide.
    f.EditScroll:SetScript("OnSizeChanged", nil)
    editBox:SetWidth(4000)
    f.EditScroll:SetHorizontalScroll(0)

    -- Move the scrollbar outside the bordered input area, to the right
    local sb = f.EditScroll.ScrollBar
    if sb then
        sb:ClearAllPoints()
        sb:SetPoint("TOPLEFT", f.EditScroll, "TOPRIGHT", 10, 0)
        sb:SetPoint("BOTTOMLEFT", f.EditScroll, "BOTTOMRIGHT", 10, 0)
    end

    -- Status text (below edit box)
    local statusText = f.StatusFrame.StatusText
    statusText:SetText(" ")

    -- Bottom row: [ExportDD][Export]          [Auto-assign] [Import]
    -- Export type dropdown
    local exportDD = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    exportDD:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 20)
    exportDD:SetWidth(160)
    f._exportType = "all"

    -- Auto-assign checkbox
    local autoAssignCB = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    autoAssignCB:SetChecked(true)
    f._autoAssign = autoAssignCB

    local cbLabel = autoAssignCB:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cbLabel:SetText("Auto-assign roles")
    local function showAutoAssignTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR")
        GameTooltip:AddLine("Auto-Assign Roles", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "Assign Artisan/Gatherer roles from detected professions for all imported characters.",
            1,
            1,
            1,
            true
        )
        GameTooltip:Show()
    end
    local function hideAutoAssignTip()
        GameTooltip:Hide()
    end
    autoAssignCB:SetScript("OnEnter", function(btn)
        showAutoAssignTip(btn)
    end)
    autoAssignCB:SetScript("OnLeave", hideAutoAssignTip)
    local autoAssignHit = CreateFrame("Frame", nil, f)
    autoAssignHit:SetAllPoints(cbLabel)
    autoAssignHit:SetScript("OnEnter", function(h)
        showAutoAssignTip(h)
    end)
    autoAssignHit:SetScript("OnLeave", hideAutoAssignTip)

    -- Replace rules checkbox
    local replaceCB = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    replaceCB:SetChecked(false)
    f._replaceRules = replaceCB

    local replaceLabel = replaceCB:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    replaceLabel:SetText("Replace existing rules")
    replaceLabel:SetPoint("LEFT", replaceCB, "RIGHT", 2, 0)
    local function showReplaceTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR")
        GameTooltip:AddLine("Replace Existing Rules", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, imported storage rules will replace all existing ones. When unchecked, new rules are merged (duplicates skipped).",
            1,
            1,
            1,
            true
        )
        GameTooltip:Show()
    end
    local function hideReplaceTip()
        GameTooltip:Hide()
    end
    replaceCB:SetScript("OnEnter", function(btn)
        showReplaceTip(btn)
    end)
    replaceCB:SetScript("OnLeave", hideReplaceTip)
    local replaceHit = CreateFrame("Frame", nil, f)
    replaceHit:SetAllPoints(replaceLabel)
    replaceHit:SetScript("OnEnter", function(h)
        showReplaceTip(h)
    end)
    replaceHit:SetScript("OnLeave", hideReplaceTip)

    exportDD:SetupMenu(function(_, rootDescription)
        local types = {
            { key = "chars", label = "Characters" },
            { key = "storage", label = "Storage Rules" },
            { key = "all", label = "All" },
        }
        for _, t in ipairs(types) do
            rootDescription:CreateRadio(t.label, function()
                return f._exportType == t.key
            end, function()
                f._exportType = t.key
            end)
        end
    end)
    -- Export button
    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 22)
    exportBtn:SetPoint("LEFT", exportDD, "RIGHT", 8, 0)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        local val = f._exportType
        if not val then
            statusText:SetText("|cffff4444Select an export type first.|r")
            return
        end
        local ok, text = pcall(function()
            if val == "chars" then
                return self:ExportRegistry()
            elseif val == "storage" then
                return self:ExportStorageAssignments()
            elseif val == "all" then
                return self:ExportRegistry() .. "\n" .. self:ExportStorageAssignments()
            end
        end)
        if not ok then
            statusText:SetText("|cffff4444Export error: " .. tostring(text) .. "|r")
            return
        end
        if text then
            editBox:SetText(text)
            editBox:SetFocus()
            statusText:SetText(string.format("|cff00cc00Exported %d lines|r", select(2, text:gsub("\n", "\n"))))
        else
            statusText:SetText("|cffff4444Export returned nil.|r")
        end
    end)

    -- Import button (right-aligned)
    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetSize(80, 22)
    importBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 20)
    importBtn:SetText("Import")
    f._importBtn = importBtn

    -- Position checkboxes above the import button (right-aligned)
    replaceCB:ClearAllPoints()
    replaceCB:SetPoint("BOTTOMRIGHT", importBtn, "TOPRIGHT", 0, 2)

    autoAssignCB:ClearAllPoints()
    autoAssignCB:SetPoint("BOTTOMRIGHT", replaceCB, "TOPRIGHT", 0, 2)
    cbLabel:SetPoint("RIGHT", autoAssignCB, "LEFT", -2, 0)
    replaceLabel:ClearAllPoints()
    replaceLabel:SetPoint("RIGHT", replaceCB, "LEFT", -2, 0)
    local function PerformImport(sections)
        local statusParts = {}
        local doReplace = replaceCB:GetChecked()

        for _, section in ipairs(sections) do
            if section.type == "registry" then
                local numNew, numUpdated, numSkipped =
                    self:ImportRegistryFromText(section.text, autoAssignCB:GetChecked())
                if type(numSkipped) == "string" then
                    statusParts[#statusParts + 1] = "|cffff4444Import Characters: " .. numSkipped .. "|r"
                else
                    local msg = string.format(
                        "|cff88ccffImport Characters:|r |cff00cc00%d new|r, |cffffcc00%d updated|r",
                        numNew,
                        numUpdated
                    )
                    if numSkipped and numSkipped > 0 then
                        msg = msg .. string.format(", |cff888888%d blacklisted|r", numSkipped)
                    end
                    statusParts[#statusParts + 1] = msg
                end
            elseif section.type == "storage" then
                local readyRules, unresolvedRules, errMsg, parseSkipped =
                    self:ImportStorageAssignments(section.text)
                if errMsg and not readyRules then
                    self:ChatMsg("Storage import error: " .. errMsg, true)
                    statusParts[#statusParts + 1] = "|cff88ccffStorage:|r |cffff4444failed|r"
                elseif unresolvedRules and #unresolvedRules > 0 then
                    -- Unknown chars in the export. Open the remap dialog and
                    -- apply everything atomically when the user clicks Import
                    -- on the summary step.
                    local groups = GroupUnresolved(unresolvedRules)
                    statusParts[#statusParts + 1] = "|cff88ccffStorage:|r |cffffaa00awaiting remap...|r"
                    self:ShowRemapDialog(groups, readyRules, doReplace, function(commit, finalRules, mappedN, skippedN)
                        if not commit then
                            self:ChatMsg("Storage import cancelled.", true)
                            statusText:SetText("|cffff8800Storage import cancelled.|r")
                            return
                        end
                        if doReplace then
                            self.db.global.storageAssignments = {}
                        end
                        local lenBefore = #(self.db.global.storageAssignments or {})
                        local imp, dup = 0, 0
                        if finalRules and #finalRules > 0 then
                            imp, dup = self:ApplyImportedRules(finalRules)
                        end
                        if imp > 0 then
                            self._storageScrollToIdx = lenBefore + 1
                        end
                        local totalSkipped = (parseSkipped or 0) + dup + (skippedN or 0)
                        local parts = {}
                        if imp > 0 then
                            parts[#parts + 1] = string.format("|cff00cc00%d imported|r", imp)
                        end
                        if mappedN and mappedN > 0 then
                            parts[#parts + 1] = string.format("|cff88ccff%d remapped|r", mappedN)
                        end
                        if totalSkipped > 0 then
                            parts[#parts + 1] = string.format("|cffdddd00%d skipped|r", totalSkipped)
                        end
                        local msg2 = "|cff88ccffStorage:|r "
                            .. (#parts > 0 and table.concat(parts, " ") or "|cff00cc00OK|r")
                        statusText:SetText(msg2)
                        self:ChatMsg(msg2:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), true)
                        if self.dashboardFrame and self.dashboardFrame:IsShown() and self.activeTab then
                            C_Timer.After(0, function() self:SelectDashboardTab(self.activeTab) end)
                        end
                    end)
                else
                    if doReplace then
                        self.db.global.storageAssignments = {}
                    end
                    local lenBefore = #(self.db.global.storageAssignments or {})
                    local imp, dup = 0, 0
                    if readyRules and #readyRules > 0 then
                        imp, dup = self:ApplyImportedRules(readyRules)
                    end
                    -- After a bulk import the prior scroll offset maps to a
                    -- different region of the new list; jump to the first
                    -- imported rule so the user lands on the new content.
                    if imp > 0 then
                        self._storageScrollToIdx = lenBefore + 1
                    end
                    local totalSkipped = (parseSkipped or 0) + dup
                    local parts = {}
                    if imp > 0 then
                        parts[#parts + 1] = string.format("|cff00cc00%d imported|r", imp)
                    end
                    if totalSkipped > 0 then
                        parts[#parts + 1] = string.format("|cffdddd00%d skipped|r", totalSkipped)
                    end
                    statusParts[#statusParts + 1] = "|cff88ccffStorage:|r "
                        .. (#parts > 0 and table.concat(parts, " ") or "|cff00cc00OK|r")
                end
            end
        end

        local msg = table.concat(statusParts, "  ")
        statusText:SetText(msg)
        self:ChatMsg(msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), true)

        -- Refresh dashboard if visible
        if self.dashboardFrame and self.dashboardFrame:IsShown() then
            C_Timer.After(0, function()
                if self.activeTab then
                    self:SelectDashboardTab(self.activeTab)
                end
            end)
        end
    end

    importBtn:SetScript("OnClick", function()
        local text = editBox:GetText()
        if not text or text:match("^%s*$") then
            statusText:SetText("|cffff4444No text to import|r")
            return
        end

        local sections = self:ParseImportSections(text)
        if #sections == 0 then
            statusText:SetText("|cffff4444No recognized EmpireManager headers found.|r")
            return
        end

        -- Build a short summary of what will be imported, then confirm.
        local charSections, ruleSections = 0, 0
        local charLines, ruleLines = 0, 0
        for _, section in ipairs(sections) do
            if section.type == "registry" then
                charSections = charSections + 1
                for _ in section.text:gmatch("[^\r\n]+") do
                    charLines = charLines + 1
                end
            elseif section.type == "storage" then
                ruleSections = ruleSections + 1
                for _ in section.text:gmatch("[^\r\n]+") do
                    ruleLines = ruleLines + 1
                end
            end
        end
        local summary = {}
        if charSections > 0 then
            summary[#summary + 1] = string.format("%d Character%s", charLines, charLines == 1 and "" or "s")
        end
        if ruleSections > 0 then
            summary[#summary + 1] = string.format("%d Storage Rule%s", ruleLines, ruleLines == 1 and "" or "s")
        end
        if replaceCB:GetChecked() and ruleSections > 0 then
            summary[#summary + 1] = "|cffff8800replace existing rules|r"
        end
        local summaryText = #summary > 0 and (table.concat(summary, ", ") .. ".") or "no recognized data."

        local dialog = StaticPopup_Show("EM_IMPORT_CONFIRM", summaryText)
        if dialog then
            dialog.data = { sections = sections }
        end
    end)

    StaticPopupDialogs["EM_IMPORT_CONFIRM"] = StaticPopupDialogs["EM_IMPORT_CONFIRM"]
        or {
            text = "Import the following?\n\n%s",
            button1 = "Import",
            button2 = "Cancel",
            OnAccept = function(popup)
                if popup.data and popup.data.sections then
                    PerformImport(popup.data.sections)
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            showAlert = true,
            preferredIndex = 3,
        }
end

function EmpireManager:ToggleIOWindow()
    local f = EmpireManagerIOFrame
    if not f then
        return
    end

    self:InitIOFrame()

    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end
