# Changelog

## [0.5.0] - 2026-06-01

### Added

- Gold tab in the character panel (`/em config`): shows bag gold and Warband Bank gold, with per-character "Withdraw if below" / "Deposit if above" amounts.
- Auto Transfer Gold at Warband Bank (Options > General): when you open a Warband Bank, gold is moved to or from the Warband Bank to keep the character within those amounts. On = moves automatically with a chat message; off = asks first with a confirmation dialog.
- Triage now vendors soulbound gear your class can never use, regardless of item level: a wrong armor type (such as Plate on a Priest), shields for classes that cannot use them, and weapons your class cannot wield. Gear you can use, account-bound (Warband) gear, and high-end items are left alone.

### Changed

- Triage keeps conjured items (healthstones, mage food and water, soulwells) instead of trying to route them, since they cannot be mailed, banked, or sold.
- Items that cannot be deposited because their assigned bank tabs are full now appear in the Triage window (highlighted) instead of being silently kept.

### Fixed

- Guild bank capacity showing "No data", items not depositing to your own guild bank, and guild mail recipients failing to resolve, all caused by a realm-name mismatch on realms whose name contains a space.
- Setting a Map waypoint no longer causes a blocked-action error when opening the world map in combat.

## [0.4.3] - 2026-05-31

### Added

- Triage: new option to automatically close the Triage window when you close the bank, guild bank, vendor, or mailbox. On by default; find it under Options > Triage.

### Fixed

- Roster: fixed an error that could appear on the Banks tab after opening a guild bank.

## [0.4.2] - 2026-05-24

### Fixed

- Triage: Mail All Routable works with TradeSkillMaster open.

## [0.4.1] - 2026-05-23

### Fixed

- Storage: cross-realm guild handling overhauled - guild home realm is tracked separately from the character's realm, exports and remap dialog disambiguate by realm, and stale realm data on alts self-heals as soon as any one character in the guild logs in.
- Core: deferred `GetMoney()` out of the `PLAYER_MONEY` event handler to avoid MoneyFrame taint.

## [0.4.0] - 2026-05-17

### Added

- Storage: overflow routing - when a primary destination is full, items fall through to the next matching rule instead of stalling.
- Import/Export: Remap Import dialog handles unknown characters and guilds on storage import, with duplicate-aware summary and ESC/X cancel hooks.
- About panel: clickable header opens a website-URL popup; refreshed copy and tighter layout.
- Dropdowns: scrollable when long, with automatic scroll-to-selected on open.
- Storage: snapshot timestamps with stale-age tooltips across dashboard, Storage tab, and roster banks so you can tell at a glance how fresh each capacity reading is.
- Sidecar: window is draggable by its title bar in both anchored and standalone (`/em config`) modes; option and simple-role checkbox labels are now clickable to toggle.

### Changed

- Storage: realm-aware guild-bank keys disambiguate same-named guilds across realms.
- Triage: live overlay refresh on rule changes, including per-character Sidecar toggles (previously waited for the next bag event).
- Triage: warbound legacy junk handling and several capacity edge cases tightened; broader UI/UX polish pass.
- Triage: re-enabled the "All matching destinations are full" chat warning, batched alongside unreachable-destination reasons.
- Naming: canonical capitalization for Character / Roster / Vendor Whitelist / Guild Blacklist / Character Blacklist across user-facing strings.

### Fixed

- Triage: Deposit button no longer renders on top of the Vendor button at a vendor. Dropped the `BankFrame:IsShown` fallback that falsely reported the bank as open; bank state now relies solely on tracked `BANKFRAME_OPENED/CLOSED` and `PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE` events.

## [0.3.6] - 2026-05-11

### Added

- Storage Setup Wizard: new guided flow to bulk-create storage rules from templates (Self-Banker, Mule Banker, Guild/Warband Bank, Split by Expansion, Stash Everything Else). Includes per-template Review summary, Clear-existing toggle, and an option to route shared professions to the highest-skill character.
- Roster: warband bank gold is now tracked and folded into the Roster Info total.

### Changed

- Options panel slash-command list synced with the About tab and `/em help`.
- Vendor and Disenchant threshold sliders show "Disabled" at 0 and drop the always-zero copper unit at other values.
- Storage tab preserves scroll position across rebuilds and jumps to the first imported rule.
- Storage tab capacity refreshes live as banks are visited.
- Sidecar refreshes on profession learn/unlearn; Auto button simplified.

### Fixed

- Import/Export hardened against malformed data.
- Triage tooltip cache no longer stores empty results.

## [0.3.5] - 2026-05-05

### Changed

- Triage controls lock during mail and vendor operations; closing the mailbox or merchant cancels cleanly.
- "Default Vendor Threshold" tooltip rewritten to reflect what it actually does.
- Storage tab help tooltip clarifies that the first matching rule wins.

### Fixed

- Disabled action buttons (Mail/Vendor/Deposit/Reorganize) now show their reason tooltip on hover.
- Row hovers and Right-click half-highlight no longer draw on disabled rows.
- Vendor cooking ingredients (Mild/Soothing/Hot/Holiday Spices, Simple Flour) no longer false-match alchemy.

## [0.3.4] - 2026-05-04

### Added

- Triage: "Keep Above iLvl" option (Options -> Triage -> Vendor) protects soulbound gear at or above the configured iLvl from Pawn/iLvl vendor checks.
- Triage: classification-affecting options now trigger a debounced rescan when the triage window is open.
- Triage: disenchant chat notice now appends item links.

### Changed

- Triage: right-click skip on the left column now keys per-row (bag:slot) instead of per-itemID, so non-stacking duplicates (e.g. caged pets) skip independently.
- Triage: failed-deposit list capped at 5 entries with "... and N more" tail to keep chat readable.
- Storage UI: collapsed "All Expansions" into "Any Expansion" and singularised "Tabs:"/"Expansions:" labels for consistency.
- Tooltip wording: refined Ctrl+click hints, sort-order tooltip, and failed-deposit reasons.

### Fixed

- Triage: rescan button and option changes now invalidate the cached classification, so new settings actually apply instead of returning stale results.
- Triage: skip the deposit pass entirely when no destination has accessible capacity (e.g. warband bank with no tabs purchased) instead of dumping a per-item failure list.
- Core: corrects character level on `PLAYER_ENTERING_WORLD` even when the imported value is higher than the current level.
- Core: `/played` request no longer prints to chat.

## [0.3.3] - 2026-04-30

### Added

- Storage UI: faded fill bar behind rule fill-level text.

### Changed

- Storage UI: tweaked reorder arrow spacing and help text.
- Roster tooltips: standardized to "Name - Realm (level)" with class color.
- Vendor dialog: reduced height of confirmation dialog and parent frame.

### Fixed

- Import: validation for missing/invalid fields so bad imports don't break the UI.
- Bank actions: no longer displays "0 actions".

## [0.3.2] - 2026-04-26

### Fixed

- Triage now reclassifies after toggling a Sidecar role-behaviour option
  or changing role/profession assignments. Previously cached results
  could ignore the new setting until bag contents changed.

## [0.3.1] - 2026-04-26

### Added
- Legion artifact weapons now route to character bank.
- Dashboard refreshes live on level-up, equipment change, and gold change.
- Minimap button enabled by default.
- About page and Options panel headers use the logo image.
- Confirmation dialog when vendoring uncommon+ quality items, with sell-low-quality-first ordering for buyback safety.
- Confirmation dialog for `/em wipe chars|rules|all`.
- Global **Keep List** (`/em keeplist`) - items always classified as Keep regardless of other rules.
- Global **Vendor List** (`/em vendorw`) - items always classified as Vendor.
- Keep/Vendor list mutual-exclusion gate with "move it instead" prompt.
- Tooltip-scan-based teleport item detection (Hearthstone, Kirin Tor ring, etc. never get vendored).
- Search filter supports space-separated tokens for AND matching.
- Triage popup for Baganator users.

### Changed
- Multi-currency formatting (correct display below 1 gold).
- Cross-realm mail tooltip text clarified.
- Guild bank snapshot filters viewable tabs, preserves hidden-tab data.
- Storage rule purge messaging improved.

### Fixed
- Item link color bleed in messages.
- Dialog spacing and subtitle clarity.
- Add Button positioning across dialogs.

## [0.3.0]

Initial public baseline. Changelog tracking starts here; refer to git history for pre-0.3.0 development.
