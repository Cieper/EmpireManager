# Changelog

## [1.1.7] - 2026-08-06

### Added

- **The Characters grid highlights the selected row.** A gold wash and a left edge bar mark the character whose Sidecar is open. With the Sidecar closed the highlight falls back to the character you are logged in on, so the grid always shows where you are.

### Fixed

- **Guilds no longer appear twice in Guild lists.** A Guild's realm is stored in two spellings depending on which part of the game reported it ("Argent Dawn" or "ArgentDawn"), and one Guild could show up as two separate entries in the Setup Wizard, the storage dropdowns, the remap picker, and the Guild Blacklist window.
- **Spare copies of equipment set gear are left alone by Triage.** Sets were still matching by item rather than by the specific piece, so every duplicate you owned was kept. Only the piece a set actually uses is protected now, including off-spec pieces you are not currently wearing; the spares follow the normal soulbound gear rules.

## [1.1.6] - 2026-07-30

### Fixed

- **Profession tracking is fixed.** On non-English clients professions were matched by their translated name and never resolved, so the Sidecar's Auto button assigned no roles, the Setup Wizard created no rules, and profession counts and skill levels read as empty. Separately, on every client language, the per-expansion skill breakdown stopped being saved in 0.3.2. Professions are now identified by a language-independent ID, exports always use English names, and the expansion breakdown is recorded again. Each character's data refreshes the next time you log in on them.
- **Spare copies of equipment set gear are no longer kept from Triage.** Equipment set protection matched by item rather than by the specific piece, so every copy you owned was kept. Only the piece a set actually uses is protected now; the spares follow the normal soulbound gear rules.

## [1.1.5] - 2026-07-27

### Fixed

- **Two Guilds with the same name on different realms are now told apart.** If you have legacy Guilds sharing a name (an Alliance one and a Horde one, say), the addon collapsed them into a single Guild and overwrote one Guild's realm with the other's on every login. Only one appeared in the Guild dropdowns, and Triage wanted to take items out and mail them even with the correct Guild Bank open in front of you. Both Guilds are now tracked separately and shown as "Guild - Realm" wherever the name alone is ambiguous.
- **The Guild Blacklist hides one Guild at a time.** Blacklisting a Guild whose name is shared with a Guild on another realm hid both. Existing blacklist entries keep working as before.

**If you have two Guilds sharing a name:** log in once on a character in each Guild to refresh their Guild info, then delete and re-create the Guild Bank storage rules for those Guilds. Existing rules still carry the wrong realm and are not rewritten automatically.

## [1.1.4] - 2026-07-26

### Fixed

- **Soulbound gear is no longer treated as Warbound** when you carry another copy of the same item that is Warbound until equipped. Triage was offering the soulbound copy as a Warband Bank deposit under the Equipment (BoA) rule instead of leaving it to Keep or Vendor.

## [1.1.3] - 2026-07-24

### Changed

- **Restock list rows show the game item tooltip first**, with the restock info below it, so hovering a row gives you the full in-game item details.
- **Character name tooltip lists only the two main professions**, hiding secondary professions (Fishing, Cooking, Archaeology).

### Fixed

- **Soulbound gear above your required level is no longer vendored** by Triage.
- **BoE gray (junk quality) items are no longer vendored** by mistake.
- **Spec stays current after a respec** - the tooltip's spec and class line updates correctly and no longer duplicates.

## [1.1.2] - 2026-07-11

### Added

- **More items in the Restock picker** - the "Other", "Optional Reagents", and "Finishing Reagents" Auction House sections are now included, so cross-profession reagents (Petrified Root, Tormented Tantalum, Motes, and the like) can be stocked.

### Changed

- **Restock picker organizes by Auction House category** (Cloth, Herb, Metal & Stone, Other, Optional Reagents, Finishing Reagents, and so on, in the same order as the Auction House sidebar) instead of by profession. Cross-profession reagents now appear in the right bucket automatically.
- **New Restock confirm dialog** - the top-up prompt is now a scrollable list grouped by destination (Warband Bank, Guild Bank, Character Bank) with item icons, quality colors, and hover tooltips, replacing the old plain-text popup that capped at six lines.

### Fixed

- **Restock fill count updates live** while a bank is open: dragging items out by hand or using Take Out now refreshes the current-vs-target count right away, instead of staying stale until you close and reopen the bank.
- **Honest deposit reporting** - if a restock deposit is rejected by the destination and the item returns to your bags, the addon now reports "N x Item bounced back" and corrects the count, instead of falsely counting it as deposited.
- **Editing a Restock rule** scrolls the item into view and highlights it on the first open (previously you had to reopen the dialog to see it).
- **Non-reagent items** (food, potions, and other items added by shift-click) open the picker under "All Categories" with a full list, instead of showing nothing.
- **Rule dialog state resets cleanly** - adding a rule, cancelling, then editing another no longer leaks the cancelled item, target, or destination, and rapid add/cancel/edit cycles no longer show a stale target value.
- **Switching Dashboard tabs** now closes the open Restock or Storage rule editor.
- The Restock edit dialog title now shows the rule number ("Edit Restock Rule #N").
- Removed the picker's Expansion dropdown, which only ever offered the current expansion.
- The Inscription category icon now renders in the picker.

## [1.1.1] - 2026-07-04

### Added

- **Bank Restock (par-level stocking)** - keep a floor of specific items in the Warband Bank, a guild bank, a character's own bank, or in a character's bags. When you open a bank the addon tops up to the target automatically (silent) or with a confirm dialog. New Restock tab on the Dashboard with add / edit / delete / reorder, per-character fill display, and multi-character rules for shared floors. Guild bank floors are supported end-to-end.
- **Consolidate bags before Triage** - partial stacks of items that have a bags floor are merged into one clean stack before Triage classifies them, so you see one row per item instead of several. Reagent-bag stacks and normal-bag stacks of the same reagent are bridged so they can join up.
- **Import / Export for the Keep List, Vendor Whitelist, and Restock Rules** - the paste-in Import / Export window handles all three now. Export dropdown has entries for each and an "All" option that includes them.
- **Dashboard search** also matches faction and race.
- Illusion appearances (weapon-enchant looks) that you have already learned and are soulbound sell to the vendor as junk; unknown ones are always kept.

### Changed

- **Import / Export** window's "Replace existing rules" checkbox is now "Replace existing" and applies to every list type in the paste (Storage Rules, Keep List, Vendor Whitelist, Restock Rules). This is the recommended way to start clean before importing a snapshot.

### Fixed

- **Restock floor preserved on mail** - when a single stack straddled the floor (e.g. floor of 20 in one stack of 39), Mail All Routable no longer mails the whole stack away. Now it mails exactly the surplus and leaves the floor in your bags.
- **Restock does not churn bags on every scan** - stack consolidation only runs on a user-initiated Triage refresh, not on the automatic background refresh that fires whenever your bags change.
- **Storage Rule reorder** takes effect on the next Triage scan without needing an explicit rescan click.

## [1.0.1] - 2026-06-19

### Added

- Secondary professions (Fishing, Cooking, and Archaeology) are now tracked and displayed alongside your primary professions.

### Fixed

- Stackable items now route into bank tabs that are already partially full, instead of being treated as not fitting.
- Warbound and account-bound items now mail correctly cross-realm.
- Locked lockboxes no longer show the skip hint.
- Closing windows with Escape no longer triggers a secret-value crash (untainted the UISpecialFrames registrations).

## [1.0.0] - 2026-06-10

### Added

- Auto-Repair at Vendor (Options > General, off by default): repairs all your gear when you open a repair-capable merchant. The child "Repair with Guild funds" option uses guild bank funds when available and sufficient, falling back to your own gold. The result is reported in chat every time (repaired, repaired with Guild funds, or not enough gold), and total repair spend is tracked as a new "Gold on Repairs" statistic in the About tab.
- Per-character "Skip all Storage Rules" option: exempts a character from all Storage-tab routing (stash, mail, take out, reorganize).
- Triage vendors mounts and battle pets you have already collected, since soulbound duplicates cannot be traded or relearned.

### Changed

- Triage keeps right-click gear tokens (such as the Unsullied set) in your bags instead of mailing them to a consumables banker. These are class-restricted "Use: opens a piece of gear" items that were previously mis-detected as consumables.
- New logo artwork.

### Fixed

- Triage: walking away from the mailbox while the per-recipient mail confirmation is open now closes the dialog and finalizes, instead of leaving it up and attempting another send.
- Triage: fixed a hang in the vendor loop and padding on the gold input field.

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
