# Changelog

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
