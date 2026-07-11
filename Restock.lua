-- Restock.lua - Bank Restock engine (Stage B). See docs/RESTOCK.md.
--
-- Par-level top-up: on bank open, keep a floor of specific items in a chosen bank
-- by depositing from this character's bags. Floor only (deposit, never withdraw).
-- Self-contained deposit loop (does NOT reuse the triage move engine, which rebuilds
-- its move list from triage classification each batch). Uses the low-level bank
-- accessors in MoveContexts (PickupItem / GetNumSlots / IsItemAllowedInBank) and the
-- same fire-move -> wait BAG_UPDATE_DELAYED -> verify-count settle pattern.

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")

local MoveContexts = EmpireManager.MoveContexts

-- Live count of an itemID in the open destination bank's containers. Reads the
-- slots directly (authoritative), not the saved snapshot. Uses the context's own
-- GetItemInfo so guild banks (which read via GetGuildBankItemInfo, not C_Container)
-- are counted correctly.
local function CountInBankContainers(ctx, itemID)
    local total = 0
    local first, last = ctx.ContainerRange()
    for container = first, last do
        local numSlots = ctx.GetNumSlots(container)
        for slot = 1, numSlots do
            local info = ctx.GetItemInfo(container, slot)
            if info and info.itemID == itemID then
                total = total + (info.stackCount or 1)
            end
        end
    end
    return total
end

-- All bag slots (bags 0-5) holding itemID, newest-first is irrelevant; returns
-- { {bag, slot, count}, ... } so the deposit loop can pick stacks to move.
local function FindBagStacks(itemID)
    local stacks = {}
    for bag = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and not info.isLocked then
                stacks[#stacks + 1] = { bag = bag, slot = slot, count = info.stackCount or 1 }
            end
        end
    end
    return stacks
end

-- Scan the open destination bank ONCE and build the list of slots that can receive
-- `itemID`, ordered partials-first (top up existing stacks before opening fresh
-- slots), then empty slots. Each entry carries `room` = how many more units it can
-- take, so the caller can assign multiple deposits to one slot and decrement as it
-- goes. Built once per deposit pass, avoiding a full bank rescan per bag stack.
local function BuildDestSlots(ctx, itemID)
    local maxStack = (select(8, C_Item.GetItemInfo(itemID))) or 1
    if maxStack < 1 then
        maxStack = 1
    end
    local partials, empties = {}, {}
    local first, last = ctx.ContainerRange()
    for container = first, last do
        local numSlots = ctx.GetNumSlots(container)
        for slot = 1, numSlots do
            local info = ctx.GetItemInfo(container, slot)
            if not info then
                empties[#empties + 1] = { container = container, slot = slot, room = maxStack }
            elseif info.itemID == itemID then
                local room = maxStack - (info.stackCount or 1)
                if room > 0 then
                    partials[#partials + 1] = { container = container, slot = slot, room = room }
                end
            end
        end
    end
    -- Empties append after partials (both entry tables share the same shape).
    for i = 1, #empties do
        partials[#partials + 1] = empties[i]
    end
    return partials
end

-- Claim capacity from the first destination slot with room. Grants at most `want`
-- units (never more than the slot's remaining room), decrements that slot's room by
-- the granted amount (so it can never go negative), and returns
-- container, slot, granted. Returns nil when no slot has any room left. The caller
-- loops on the remainder so one bag stack can fan out across several dest slots.
local function ClaimDestSlot(slots, want)
    for _, s in ipairs(slots) do
        if s.room > 0 then
            local granted = math.min(want, s.room)
            s.room = s.room - granted
            return s.container, s.slot, granted
        end
    end
    return nil
end

-- Reachability: which restock destinations can THIS character top up at the
-- currently open bank. Warband: whenever warband containers are open. Char bank:
-- only the owner, and only when the regular (non-warband-only) bank is open. Guild:
-- when the guild bank is open and the entry's guild is this character's guild.
-- Bags: keep-in-bags floors are not deposited (protection handles them).
local function EntryReachableNow(self, entry)
    if entry.dest == "warbandbank" then
        for bag = 12, 16 do
            if (C_Container.GetContainerNumSlots(bag) or 0) > 0 then
                return true
            end
        end
        return false
    elseif entry.dest == "charbank" then
        if not self.bankIsOpen or self:IsWarbandBankOnly() then
            return false
        end
        -- Owner-only (decision C). entry.chars holds target GUIDs; the open char
        -- bank belongs to the current player, so only top up if they're a target.
        local guid = self.playerGUID
        if entry.chars then
            for _, g in ipairs(entry.chars) do
                if g == guid then
                    return true
                end
            end
        elseif entry.char == guid then
            return true
        end
        return false
    elseif entry.dest == "guildbank" then
        if not self:IsGuildBankOpen() or not entry.guild then
            return false
        end
        -- The open guild bank belongs to the current character's guild; the entry
        -- must target that same guild (deposit rights are checked per-tab at move
        -- time, like the triage guild deposit path). Match realm too when the entry
        -- carries one, so same-name guilds on different realms don't collide.
        local guildName, _, _, guildRealm = GetGuildInfo("player")
        if not guildName or guildName == "" then
            return false
        end
        if entry.guild ~= guildName then
            return false
        end
        if entry.realm and guildRealm and entry.realm ~= guildRealm then
            return false
        end
        return true
    end
    return false
end

-- Build the deposit plan: ordered list of { ctx, destType, itemID, name, move } for
-- every restock entry reachable now that is below its floor, in restockList priority
-- order. `move` is the exact deficit we can cover from bags (never exceeds target).
function EmpireManager:ComputeRestockPlan()
    local list = self.db.global.restockList
    if not list or #list == 0 then
        return {}
    end
    local plan = {}
    for _, entry in ipairs(list) do
        if entry.itemID and entry.target and entry.target > 0 and EntryReachableNow(self, entry) then
            local ctx = MoveContexts[entry.dest]
            if ctx then
                local inBank = CountInBankContainers(ctx, entry.itemID)
                local deficit = entry.target - inBank
                if deficit > 0 then
                    local have = self:CountItemInBags(entry.itemID)
                    local move = math.min(deficit, have)
                    if move > 0 then
                        plan[#plan + 1] = {
                            ctx = ctx,
                            destType = entry.dest,
                            itemID = entry.itemID,
                            name = entry.name or ("Item " .. entry.itemID),
                            move = move,
                            entry = entry, -- source rule (guild/char for dialog headers)
                        }
                    end
                end
            end
        end
    end
    return plan
end

-- Execute one plan: deposit `move` of each item from bags into its bank. Sequential
-- per item (split partial stacks to hit the target exactly, never overshoot the
-- floor). Fires moves, waits for bag settle, re-verifies, advances. Calls onDone
-- with the total number of items deposited.
function EmpireManager:ExecuteRestockPlan(plan, onDone)
    onDone = onDone or function() end
    if not plan or #plan == 0 then
        onDone(0)
        return
    end

    local idx = 0
    local totalDeposited = 0
    local listener = self:AcquireListener()
    local settleTimer -- debounce after BAG_UPDATE_DELAYED
    local fallbackTimer -- fires if no BAG_UPDATE_DELAYED arrives

    local function clearTimers()
        if settleTimer then
            settleTimer:Cancel()
            settleTimer = nil
        end
        if fallbackTimer then
            fallbackTimer:Cancel()
            fallbackTimer = nil
        end
    end

    local function cleanup()
        clearTimers()
        listener:UnregisterAllEvents()
        self:ReleaseListener(listener)
    end

    local processNext -- forward decl

    -- True if the destination bank for this item is currently open.
    local function bankOpenFor(destType)
        if destType == "guildbank" then
            return self:IsGuildBankOpen()
        end
        return self.bankIsOpen
    end

    -- Fire one batch of deposits for `item`: move up to `need` units of the itemID
    -- from bags into the prebuilt `destSlots`, capped at `maxMoves` pickup/place
    -- pairs (guild = 1, warband = 5, char = unlimited). Returns how many pickup/place
    -- pairs it fired (0 = nothing could be placed this pass). Verified afterward by
    -- re-counting bags, so the return is best-effort intent, not confirmed success.
    --
    -- A single bag stack fans out across as many dest slots as needed: ClaimDestSlot
    -- grants only what one slot can actually hold, so a 200-stack can fill a partial
    -- (room 5) and then spill into empty slots. Each placement moves a whole stack
    -- only when it exactly equals both the remaining need AND the slot's granted room;
    -- otherwise it splits off exactly the granted amount so the floor is hit precisely
    -- and no slot overflows. `maxMoves` bounds the WoW rate-limited APIs per pass.
    local function depositItem(item, destSlots, maxMoves)
        if not bankOpenFor(item.destType) then
            return 0, nil
        end
        local need = item.move
        local moves = 0
        local lastTab
        -- Source moves are ALWAYS from a bag, so pickup/split use the C_Container API
        -- regardless of destination type (the guild context's SplitItem targets a
        -- guild-tab source and would be wrong here). Only the destination PLACE uses
        -- ctx.PickupItem.
        for _, st in ipairs(FindBagStacks(item.itemID)) do
            if need <= 0 then
                break
            end
            if item.ctx.IsItemAllowedInBank(st.bag, st.slot) then
                -- One bag stack may fan across several dest slots. `remaining` tracks
                -- how much of this stack is still to place.
                local remaining = math.min(need, st.count)
                while remaining > 0 and not (maxMoves > 0 and moves >= maxMoves) do
                    local destC, destS, granted = ClaimDestSlot(destSlots, remaining)
                    if not destC then
                        -- No dest slot has room left; bank is full for this item.
                        return moves, lastTab
                    end
                    if granted >= st.count then
                        -- The bag stack fits entirely here: move it whole. `granted`
                        -- equals `remaining` here, so the while loop exits after this.
                        C_Container.PickupContainerItem(st.bag, st.slot)
                    else
                        -- Split off exactly `granted` so the floor is hit precisely and
                        -- the destination slot never overflows.
                        C_Container.SplitContainerItem(st.bag, st.slot, granted)
                    end
                    item.ctx.PickupItem(destC, destS)
                    ClearCursor()
                    lastTab = destC
                    need = need - granted
                    remaining = remaining - granted
                    moves = moves + 1
                end
            end
        end
        return moves, lastTab
    end

    -- Deposit for `item`, settle, then re-enter the same item if it made progress and
    -- is still short (batched contexts loop until satisfied). Any context re-enters:
    -- guild moves one at a time, warband five at a time, char unlimited - each pass
    -- re-scans dest slots and bag positions from the post-settle state. A pass that
    -- makes no progress (`moved <= 0`) or exhausts the no-progress retry budget ends
    -- the loop so a full/blocked tab can't spin forever.
    local function runItem(item, depositedSoFar, noProgress)
        noProgress = noProgress or 0
        if not bankOpenFor(item.destType) then
            -- Destination bank closed mid-run; skip this item, try the next.
            processNext()
            return
        end

        -- Already met this item's target during the run? (Re-entry guard.)
        if depositedSoFar >= item.move then
            processNext()
            return
        end

        local batchSize = item.ctx.batchSize or 0
        local before = self:CountItemInBags(item.itemID)
        -- Scan the bank's receiving slots fresh each pass so re-entry sees the
        -- post-settle state (a merged partial stack, a newly emptied slot, etc.).
        local destSlots = BuildDestSlots(item.ctx, item.itemID)
        local fired, lastTab = depositItem(item, destSlots, batchSize)
        -- Guild: refresh the server's view of the tab we deposited into so the next
        -- pass counts the moved item.
        if fired > 0 and lastTab and item.ctx.needsQueryAfterMove and item.ctx.QueryAfterMove then
            item.ctx.QueryAfterMove(lastTab)
        end
        if fired <= 0 then
            processNext()
            return
        end

        local isGuild = (item.destType == "guildbank")

        -- Apply a verified move count: chat, tally, then either re-enter the
        -- same item if it still has a deficit or advance. Extracted so the
        -- verification-delay branch can call it with the corrected count.
        local function applyMoved(moved)
            if moved > 0 then
                totalDeposited = totalDeposited + moved
                depositedSoFar = depositedSoFar + moved
                self:ChatMsg(string.format("|cff4d99ff[Restock]|r Deposited %d x %s", moved, item.name))
            end
            -- Re-enter the same item if it still has a deficit. Batched contexts
            -- (warband 5, guild 1) need several passes; char (unlimited) usually
            -- finishes in one. A pass that moves something resets the retry budget;
            -- a no-progress pass bumps it and bails after 2 fruitless retries, so a
            -- genuinely full or blocked destination can't loop endlessly.
            if depositedSoFar < item.move then
                if moved > 0 then
                    runItem(item, depositedSoFar, 0)
                elseif noProgress < 2 then
                    runItem(item, depositedSoFar, noProgress + 1)
                else
                    processNext()
                end
            else
                processNext()
            end
        end

        local function finishBatch()
            clearTimers()
            listener:UnregisterAllEvents()
            local afterSettle = self:CountItemInBags(item.itemID)
            local movedProvisional = before - afterSettle
            if movedProvisional <= 0 then
                applyMoved(0)
                return
            end
            -- Verification pass. WoW's rejected-placement recovery leaves the
            -- item on the cursor and returns it to bags asynchronously (~1-2s
            -- after ClearCursor). The `after` count at settle time reads that
            -- transient "not in bags" state as a successful move; a second
            -- count 1.5s later catches the cursor-return so we don't report a
            -- deposit that never actually landed. If some units did bounce
            -- back, chat says so and the corrected count feeds applyMoved,
            -- which triggers the existing noProgress retry path.
            C_Timer.After(1.5, function()
                local afterVerify = self:CountItemInBags(item.itemID)
                local movedReal = before - afterVerify
                if movedReal < 0 then
                    movedReal = 0
                end
                if movedReal < movedProvisional then
                    local bounced = movedProvisional - movedReal
                    self:ChatMsg(string.format(
                        "|cffff8800[Restock]|r %d x %s bounced back (destination rejected)",
                        bounced, item.name
                    ))
                end
                applyMoved(movedReal)
            end)
        end

        -- Each settle event resets a short debounce so we wait until moves stop
        -- arriving before counting. Success is measured by what left bags
        -- (BAG_UPDATE_DELAYED); guild banks also fire GUILDBANKBAGSLOTS_CHANGED,
        -- which we register so the debounce tracks the slower guild round-trip.
        listener:RegisterEvent("BAG_UPDATE_DELAYED")
        if isGuild then
            listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
        end
        listener:SetScript("OnEvent", function()
            if fallbackTimer then
                fallbackTimer:Cancel()
                fallbackTimer = nil
            end
            if settleTimer then
                settleTimer:Cancel()
            end
            settleTimer = C_Timer.NewTimer(0.4, finishBatch)
        end)
        -- Fallback if the settle events never arrive (guild round-trip is slower).
        fallbackTimer = C_Timer.NewTimer(isGuild and 2.5 or 1.5, finishBatch)
    end

    processNext = function()
        idx = idx + 1
        local item = plan[idx]
        if not item then
            cleanup()
            if totalDeposited > 0 then
                self:IncrementStat("itemsStashed", totalDeposited)
            end
            -- Re-snapshot so the Fill column reflects the new counts. Bag
            -- counts feed "Character Bags" rules; SnapshotBankItemCounts writes
            -- the per-itemID ledger for warband + char bank Fill;
            -- SnapshotGuildBank writes guildbank Fill (clearing the once-per-open
            -- dedup guard first). Without these the Restock tab keeps showing
            -- the pre-deposit counts until the bank is closed and reopened.
            C_Timer.After(0.5, function()
                self:SnapshotOpenBankCapacity()
                self:SnapshotBagItemCounts()
                self:SnapshotBankItemCounts()
                if self:IsGuildBankOpen() and self.SnapshotGuildBank then
                    self._guildBankSnapshotDone = nil
                    self:SnapshotGuildBank()
                end
                if self.RefreshRestockTab then
                    self:RefreshRestockTab()
                end
            end)
            onDone(totalDeposited)
            return
        end
        runItem(item, 0)
    end

    processNext()
end

-- Header label for a plan destination: "Warband Bank", "Guild Bank (Foo)",
-- "Character Bank (Ax)". Used as a section heading in the confirm dialog so the
-- user can see where each batch is going at a glance.
local function DestHeaderText(self, item)
    if item.destType == "warbandbank" then
        return "Warband Bank"
    elseif item.destType == "guildbank" then
        local guild = item.entry and item.entry.guild or "Guild"
        return string.format("Guild Bank (%s)", guild)
    elseif item.destType == "charbank" then
        -- charbank rules are owner-only in the engine, so item.entry.chars must
        -- include the current player. Show that name for clarity.
        local myGuid = UnitGUID("player")
        if item.entry and item.entry.chars and item.entry.chars[myGuid] then
            local entry = self.db.global.registry[myGuid]
            if entry and entry.name then
                return string.format("Character Bank (%s)", entry.name)
            end
        end
        return "Character Bank"
    end
    return item.destType or "?"
end

-- Custom confirm dialog: scrollable list of top-ups grouped by destination, each
-- row rendered with quality color + item icon + hover tooltip. Replaces the old
-- StaticPopup which capped at 6 lines and had no colors/icons/destinations.
function EmpireManager:ShowRestockConfirmDialog(plan)
    local f = EmpireManagerRestockConfirmDialog
    if not f then
        -- Defensive fallback: XML frame missing -> just execute the plan.
        self:ExecuteRestockPlan(plan)
        return
    end

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

    f.TitleText:SetText("EmpireManager - Confirm Restock")

    -- Clear previous widgets (rows and section headers pooled implicitly by GC-
    -- friendly hide-and-forget; same pattern the vendor dialog uses).
    if f._widgets then
        for _, w in ipairs(f._widgets) do
            if w.Hide then
                w:Hide()
            end
            if w.SetScript then
                pcall(w.SetScript, w, "OnEnter", nil)
                pcall(w.SetScript, w, "OnLeave", nil)
            end
        end
    end
    f._widgets = {}
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    local sf = f.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    local y = 8

    -- Header
    local hdr = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    hdr:SetText(string.format(
        "|cffffcc00Top up %d Restock floor%s?|r",
        #plan,
        #plan == 1 and "" or "s"
    ))
    y = y + 26

    -- Sub-header
    local sub = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
    sub:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    sub:SetText("|cffffffffDeposit from your bags:|r")
    y = y + 22

    y = y + 4

    -- Group by destination header so the user sees each bank's batch separately.
    -- Plan order already reflects restockList priority; grouping preserves it by
    -- emitting a new section header whenever the destination text changes.
    local lastHeader
    for _, item in ipairs(plan) do
        local headerText = DestHeaderText(self, item)
        if headerText ~= lastHeader then
            lastHeader = headerText
            y = y + 4 -- spacer above each group
            local grp = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
            grp:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
            grp:SetText("|cffffcc00" .. headerText .. "|r")
            y = y + 18
        end

        -- Row: icon + "N x colored name"
        local _, itemLink, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(item.itemID)
        icon = icon or 134400
        local btn = Track(CreateFrame("Button", nil, content))
        btn:SetSize(content:GetWidth() - 16, 18)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -y)

        local iconTex = btn:CreateTexture(nil, "ARTWORK")
        iconTex:SetSize(16, 16)
        iconTex:SetPoint("LEFT", btn, "LEFT", 0, 0)
        iconTex:SetTexture(icon)

        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", iconTex, "RIGHT", 6, 0)
        fs:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
        fs:SetJustifyH("LEFT")
        local qc = quality and ITEM_QUALITY_COLORS[quality]
        local coloredName = (qc and qc.hex or "|cffffffff") .. (item.name or "?") .. "|r"
        fs:SetText(string.format("%d x %s", item.move, coloredName))

        local hoverLink = itemLink or item.itemID
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            if type(hoverLink) == "string" then
                GameTooltip:SetHyperlink(hoverLink)
            else
                GameTooltip:SetItemByID(hoverLink)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        y = y + 18
    end

    content:SetHeight(y + 10)

    -- Fit the frame to content up to a cap so 3-item plans don't render an
    -- awkwardly tall dialog and 30-item plans use the scrollbar.
    local desiredHeight = math.min(math.max(200, y + 120), 500)
    f:SetHeight(desiredHeight)

    -- Rebuild the two action buttons every time (their closures capture `plan`).
    if f._btns then
        for _, btn in ipairs(f._btns) do
            btn:Hide()
        end
    end
    f._btns = {}

    local intentionalClose = false

    local okBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    okBtn:SetSize(100, 28)
    okBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 18)
    okBtn:SetText("Deposit")
    okBtn:SetScript("OnClick", function()
        intentionalClose = true
        f:Hide()
        self:ExecuteRestockPlan(plan)
    end)
    f._btns[1] = okBtn

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 28)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 18)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        intentionalClose = true
        f:Hide()
    end)
    f._btns[2] = cancelBtn

    f.CloseButton:SetScript("OnClick", function()
        if intentionalClose then
            return
        end
        f:Hide()
    end)

    -- Reset scroll to top so a fresh plan doesn't open mid-list from a prior use.
    sf:SetVerticalScroll(0)
    f:Show()
end

-- Decide silent vs. confirm, then run. Called on bank open (after capacity settles).
function EmpireManager:MaybeRestock()
    if InCombatLockdown() then
        return
    end
    local plan = self:ComputeRestockPlan()
    if #plan == 0 then
        return
    end

    if self.db.global.options.autoRestock then
        self:ExecuteRestockPlan(plan)
    else
        self:ShowRestockConfirmDialog(plan)
    end
end

-- Close the confirm dialog when the bank or guild bank closes: the plan it
-- shows became stale (destinations no longer reachable, dest counts frozen at
-- open time). EM_BANK_CLOSED is sent by both BANKFRAME_CLOSED and guild-bank
-- PLAYER_INTERACTION_MANAGER_FRAME_HIDE(type 10).
EmpireManager:RegisterMessage("EM_BANK_CLOSED", function()
    local f = EmpireManagerRestockConfirmDialog
    if f and f:IsShown() then
        f:Hide()
    end
end)

-------------------------------------------------------------------------------
-- Bag consolidation for floored items (shared by PrepMailFloors and the pre-
-- Triage-scan step). Merges partial stacks of a single itemID: reagent-bag
-- (bag 5) merges only within the reagent bag, normal bags (0-4) within
-- themselves (WoW rejects reagent<->normal pickup merges). Smallest onto
-- largest, one move per BAG_UPDATE_DELAYED settle so timing is safe.
-------------------------------------------------------------------------------

-- Run `fn` after next BAG_UPDATE_DELAYED settles (fallback timer if it doesn't).
local function afterSettle(addon, fn)
    local listener = addon:AcquireListener()
    local fired = false
    local function go()
        if fired then
            return
        end
        fired = true
        listener:UnregisterAllEvents()
        addon:ReleaseListener(listener)
        fn()
    end
    listener:SetScript("OnEvent", function()
        listener:UnregisterAllEvents()
        C_Timer.After(0.05, go)
    end)
    listener:RegisterEvent("BAG_UPDATE_DELAYED")
    C_Timer.NewTimer(1.0, go)
end

-- Merge partial stacks of `id` into full ones. Calls onDone when no more
-- merges help (pool of both spaces down to <2 mergeable stacks).
-- Stacks whose count exactly equals the bags floor are treated as untouchable
-- (already the floor), so consolidation preserves a naturally-aligned floor
-- stack instead of destroying it and recreating one via carve. Guards against
-- the "merge overflow" case (dst hits maxStack, cursor spills leftover back
-- into a source that used to be a clean floor stack).
function EmpireManager:ConsolidateBagStacksFor(id, onDone)
    local maxStack = (select(8, C_Item.GetItemInfo(id))) or 1
    if maxStack < 1 then
        maxStack = 1
    end
    local floor = self:RestockFloorTarget(id, "bags") or 0
    local isReagent = select(17, C_Item.GetItemInfo(id)) and true or false
    local function firstEmptyReagentSlot()
        local n = C_Container.GetContainerNumSlots(5) or 0
        for slot = 1, n do
            if not C_Container.GetContainerItemInfo(5, slot) then
                return slot
            end
        end
        return nil
    end
    local function step()
        local reagents, normals = {}, {}
        for _, s in ipairs(FindBagStacks(id)) do
            if s.count < maxStack and (floor <= 0 or s.count ~= floor) then
                if s.bag == 5 then
                    reagents[#reagents + 1] = s
                else
                    normals[#normals + 1] = s
                end
            end
        end
        -- Bridge the reagent/normal pool split: WoW rejects pickup merges from
        -- normal bags into the reagent bag (and vice versa), but ACCEPTS a whole-
        -- stack move into an empty reagent slot when the item is a crafting
        -- reagent. Relocate one normal-bag stack per pass so it can join the
        -- reagent pool on the next step().
        if isReagent and #normals > 0 then
            local emptySlot = firstEmptyReagentSlot()
            if emptySlot then
                local src = normals[1]
                C_Container.PickupContainerItem(src.bag, src.slot)
                C_Container.PickupContainerItem(5, emptySlot)
                ClearCursor()
                afterSettle(self, step)
                return
            end
        end
        -- Merge within the larger same-space pool this pass; recursion alternates
        -- pools as counts shift, so both spaces converge to a single partial each.
        local pool = (#normals >= #reagents) and normals or reagents
        if #pool < 2 then
            onDone()
            return
        end
        table.sort(pool, function(a, b)
            return a.count < b.count
        end)
        local src, dst = pool[1], pool[#pool] -- smallest onto largest
        C_Container.PickupContainerItem(src.bag, src.slot)
        C_Container.PickupContainerItem(dst.bag, dst.slot)
        ClearCursor()
        afterSettle(self, step)
    end
    step()
end

-- Consolidate every bags-floor itemID targeting the current character.
-- Called BEFORE a user-initiated Triage scan so the classifier and display see
-- one clean stack per floored item instead of many partials. Idempotent - a
-- second run with all stacks already at max is a no-op.
function EmpireManager:ConsolidateBagsFloors(onDone)
    onDone = onDone or function() end
    local list = self.db.global.restockList
    if not list or #list == 0 then
        onDone()
        return
    end
    local guid = self.playerGUID
    local ids, seen = {}, {}
    for _, e in ipairs(list) do
        if e.dest == "bags" and e.itemID and not seen[e.itemID] then
            local targets = false
            if e.chars then
                for _, g in ipairs(e.chars) do
                    if g == guid then
                        targets = true
                        break
                    end
                end
            elseif e.char == guid then
                targets = true
            end
            if targets then
                ids[#ids + 1] = e.itemID
                seen[e.itemID] = true
            end
        end
    end
    if #ids == 0 then
        onDone()
        return
    end
    local i = 0
    local function nextId()
        i = i + 1
        local id = ids[i]
        if not id then
            onDone()
            return
        end
        self:ConsolidateBagStacksFor(id, nextId)
    end
    nextId()
end

