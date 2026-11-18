# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Zubair Khata: an offline-first Flutter bookkeeping app (Windows and Android) for an LPG cylinder business, in English and Urdu (RTL), with optional Supabase sync. One device can hold several separate organizations. `README.md` documents the accounting conventions, cloud setup and backup rules in detail; read the relevant section before changing behaviour in those areas.

`index.html` in the repo root is the original single-page app this one replaced. It is never built or served. It is the reference for how the Roznamcha (daily cash book) must look and calculate, so consult it but do not edit it.

## Commands

Run everything from the repo root (tests read `lib/ui` and write to `build/` by relative path).

```powershell
flutter pub get
flutter run -d windows
flutter analyze
flutter test                                          # whole suite
flutter test test/book_test.dart                      # one file
flutter test test/book_test.dart --plain-name "FIFO"  # tests whose name contains the text
flutter build windows --release --no-pub
flutter build apk --debug --no-pub
powershell -NoProfile -ExecutionPolicy Bypass -File tool/package_windows.ps1   # zip the Windows release
```

If Windows Developer Mode is off, plugin symlinks fail. Create junctions instead, then skip pub on later commands:

```powershell
powershell -ExecutionPolicy Bypass -File tool/windows_links.ps1
flutter run -d windows --no-pub
```

Cloud configuration is optional and can be passed at run time: `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...` (publishable key only).

There is no code generation step. Drift is used only as a raw-SQL executor (`customStatement` / `customSelect`), so there are no table classes and no `build_runner`.

### Server integration test

`tool/backend_test.dart` applies every file in `supabase/migrations/` (sorted by name) to a throwaway PostgreSQL and checks that the server computes the same numbers as the client, plus idempotency, rollback, closing and owner isolation. It only talks to `127.0.0.1:55439` and refuses to run unless the server's data directory is `build/tooling/pgdata`, because it drops the `public` and `auth` schemas.

```powershell
build/tooling/postgres/bin/pg_ctl.exe -D build/tooling/pgdata -o "-p 55439 -h 127.0.0.1" -l build/tooling/pg.log start
dart run tool/backend_test.dart
build/tooling/postgres/bin/pg_ctl.exe -D build/tooling/pgdata stop
```

The PostgreSQL binaries and cluster live under `build/tooling/`, so `flutter clean` deletes them. From an agent or tool shell `pg_ctl ... start` may never return, because the server keeps the shell's output pipe open: start it in the background, check it with `pg_ctl -D build/tooling/pgdata status`, then run the test and stop it.

## Architecture

### One write path, no stored balances

All state is a flat list of `Record(id, kind, data, version)` (`lib/core/models.dart`). Kinds: `party`, `account`, `settings`, `document`, `snapshot`, `close`, and server-written `audit`. Fixed ids: `cash` (the cash account), `business` (settings), `close:<date>`.

`AppController` (`lib/core/controller.dart`) is the whole application layer. Every change goes through `commit(changes, action, reason)`, which checks optimistic versions, runs `validateDocument`, projects a `Book` over the proposed state to reject cylinder or deposit over-returns, and then appends a `Command` to the SQLite queue. Nothing writes the `records` table directly: it holds server-confirmed rows and changes only when sync bundles are applied.

What the app reads is `db.effective()`: confirmed records overlaid with the changes of commands still `queued`, `sending` or `accepted`. That is how the app works offline and without any cloud at all.

Posted documents are immutable. A correction is `post(data, replace: old)`, which voids the old document and creates its replacement in one command; `voidDocument` only voids. Actions `correct`, `void`, `restore`, `close` and `reopen` require a reason. Days at or before a closed date reject changes until reopened.

### The ledger is a projection

`Book` (`lib/features/ledger/book.dart`) replays all non-void documents, sorted by date, then `occurredAt`, then id, into double-entry postings and derives everything from them: balances, FIFO gas lots and shortages, cylinder full/empty/held counts, and which receipts settle which invoices. Use `app.book` (everything) or `app.bookAt(date)` (through that date); both are cached until `reload()`.

Posting account keys are strings: `ar:<partyId>`, `ap:<partyId>`, `deposit:<partyId>`, `money:<accountId>`, `inventory`, `cogs`, `revenue:gas`, `revenue:bulk`, `purchase-share:cost`, `expense:<category>`, `equity:opening`.

An opening balance is an `adjustment` document with a `target` key and `occurredAt: 0`, so it sorts first in its day (`isOpeningBalance`).

**A party's two sides are set off** (asked for by the user on 17 November 2026; README, "Accounting conventions"). After each document, `Book._setOff` checks every party the document posted to. If `ar:` and `ap:` then point opposite ways, it adds a pair of `Posting(setOff: true)` under that document and on its date, moving the smaller amount from one side to the other. Before this a purchase from a customer who owed you left both "You will receive" and "You will pay" on his card. Now at most one side is non-zero, so `receivable`, `payable`, `partyOwed`, `receivables` / `payables` and Customer balances read net figures. The khata (`partyBalance`, `partyBalances`, Roznamcha) is unchanged. `Book.setOffs` lists what each document set off. `_allocateReceipts` treats a positive set-off as a collection that pays the oldest bills, recorded in `setOffAllocations` (never `receiptAllocations`, which `paymentNotes` compares with the cash taken). A negative set-off (an advance used against an overpaid company) is a claim. Code that splits a khata's postings into Debit and Credit by sign must skip `setOff` postings, as `_statement` and the Pending balances day sheet do, or both columns grow by the set-off. Nothing is stored for it. The server does the same in `rebuild` (`202611170001_party_set_off.sql`), as one ordered pass over the postings after the replay. `test/party_set_off_test.dart` covers it.

### Client and server must agree

The Supabase side (`supabase/migrations/`, contract in `supabase/README.md`) re-validates and re-projects every command inside the `apply_command` RPC. Three things exist twice and must be changed together:

| Client | Server |
| --- | --- |
| `validateDocument` in `book.dart` | `khata_private.validate_document` |
| `Book._project`, FIFO and `_setOff` | `khata_private.rebuild`, `consume` |
| `cleanDocumentData` field whitelist in `models.dart` | `khata_private.canonical_document` |

A document field missing from either whitelist is silently dropped. Server changes go in a new timestamped migration using `create or replace` (as `202611070002_roznamcha_form.sql` does), never by editing an applied one. Re-run the server integration test after any accounting change.

The client must reject at least what the server rejects, so a bad entry is refused when it is typed rather than coming back later as a rejected change. `test/validation_parity_test.dart` holds those cases; give a new server rule a case there. `restoreBackup` validates every document of a backup, so before tightening a rule, check that existing data still passes.

### Sync

`SyncService` (`lib/data/sync.dart`) pulls change bundles in strict sequence (the cursor advances in the same SQLite transaction that applies them), then sends queued commands one at a time. `apply_command` is idempotent on the command UUID plus a hash of the payload, so a command's payload must never change once sent; only the empty `epoch` of a never-sent offline command is filled in. Command status runs `queued → sending → accepted → synced`; `conflict`, `rejected` and `quarantined` commands stay for the user to review in Settings.

`SyncTransport` is the seam for tests (`test/sync_test.dart` uses an in-memory server). Closing a day requires being signed in and fully synced.

### Organizations

A device can hold several organizations (README, "Organizations"). `Organizations` (`lib/core/organizations.dart`) owns the list and the one open `AppController`; `main.dart` runs `KhataRoot(organizations)`, which shows `KhataApp(organizations.app)` keyed by the organization id, so opening another one rebuilds the whole app.

- Each organization is its own SQLite file with its own controller, device id, queue, sync cursor and sign-in. Nothing is shared in memory: switching calls `AppController.close()` (waits for a running sync, disposes the Supabase client, closes the database) and then opens the other file. Put anything new that belongs to one khata in that organization's database or on its `AppController`, never on `Organizations` or in a static.
- The first organization (`Organization.main`) is `khata-v1.sqlite`, the file from before organizations, never moved. Added ones are `khata-org-<8 hex>.sqlite`. `Organization.idOfFile` is strict on purpose: manual backup copies live in the same folder.
- `organizations.json` holds the list (name, linked account uid and email, copied from each database by `Organizations.mirror` on every `reload()`), the last one used and the language. It is device settings and a cache: `_load()` reconciles it with the files that exist and rebuilds it when it is lost.
- An organization's name is its business profile name. `_seedDefaults()` seeds the same defaults the server does and, for a name other than the default, queues an ordinary `business` change, both for a new organization and after a reset.
- Online one account is one organization: `_onAuth()` refuses a uid that `ownerUsedElsewhere`. `SecureAuthStorage` keeps one session per organization; `main` keeps the old key.
- `AppController(db)` without organizations still works and is what most tests use; the switcher UI is hidden then. Tests that need organizations pass a temp `directory` and an `opener` that opens the file in the test isolate (see `test/organizations_test.dart`), which also works inside `testWidgets`.

### Reset all data

`AppController.resetAll()` (Settings → Reset all data) must erase everything in the open organization except the device id, language, cloud connection/sign-in and the organization's name. Other organizations are separate files and are not touched; `organizations.json` holds no business data and is left alone. On a cloud-linked device it calls `reset_dataset` (`202611100001_reset_dataset.sql`) first, then `KhataDatabase.wipe()`, then re-seeds the defaults. **Whenever you add something that stores data, make reset clear it, and extend the reset tests** (`test/database_test.dart`, `test/sync_test.dart`, `tool/backend_test.dart`):

- A new SQLite table is emptied automatically.
- A new metadata key is erased unless you add it to `KhataDatabase.keptOnWipe`. Add only device or connection settings there, never business data.
- New in-memory state on `AppController` (like `rozDrafts`, `composerDrafts`, `pdfSizes` and `entryDrafts`) must be reset by hand in `resetAll()`.
- A new server table needs the `khata_` prefix and an `owner_id` column, or `reset_dataset` will not erase it.
- Files the app writes (e.g. Android export copies) must be kept per organization and deleted for that organization only, as `clearExportCopies(organizationId)` does (`exports/<organization id>/` in the cache). Removing an organization must delete them too (Settings does both).

### Units

- Money is integer paisa, gas is integer grams, cylinder counts are integers. Cylinder sizes are 11800, 15000 and 45000 grams.
- A sale's `rate` is paisa per 11.8 kg cylinder. Bills, purchase bills and purchase-share charges round to whole rupees (`roundRupees`, `Document.purchaseBillFor`).
- Parse user input with `decimal()` and compute `a * b / c` with `multiplyDivide()` (BigInt inside). Do not introduce doubles into accounting code.
- Business dates are `YYYY-MM-DD` strings in Asia/Karachi (`businessDate()`), compared as strings.
- Cylinder gas and extra (bulk) KG both consume FIFO stock. Ordinary bulk sales contribute revenue and cost; shared purchases do not. Physical invoice returns restore both quantities and their original cost. Bulk KG never changes cylinder custody counts.
- Gas taken with no stock (a sale entered before its purchase, the daily pattern) waits in `Book._backorders`; the next stock-in covers it first, oldest first (cylinders before a mixed entry's share), at that lot's proportional cost. The allocation and postings belong to the waiting document but are dated the stock-in day, so closed days never change. Until covered it is in `uncostedSales` (and `uncostedShares` for a share). A physical credit note cancels its invoice's waiting gas. `Book(...)` must never throw on stored data because of stock: a share that loses its stock just waits. The Profit and FIFO allocations reports read `app.book` (everything known) for the entries in range, since a later purchase can cost an earlier sale.

### Purchase sharing

New bulk inputs default to sharing at purchase cost. It remains a `sale` document for collections, corrections and invoice allocation, marked with `bulkAtCost: true` and integer-paisa `bulkCost` (both whitelisted on sales and credit notes). `Document.purchaseShare` is a pure share with no cylinders; mixed entries keep their cylinder sale. Optional `sharePurchase` (whitelisted on sales and credit notes) is the **reference** of the purchase the share comes from; references survive corrections, restores and rate changes, so the link does too. `Book._reserveShares` runs over every live document (not only those through a dated book's cut-off): in document order each such share reserves its KG from that purchase up to what is left (`shareExcess` beyond); a share whose gas a physical credit note returned reserves nothing. Reserved KG never enter FIFO: the purchase stocks in only the rest, at its bill minus the reserved part (split by KG on the running total, so it adds up exactly), and the share gets that allocation when both have been replayed (dated the later of the two). `Book.shareChargeFor` is the one rule for a share's charge: `purchaseBillFor(extraGrams)` of its chosen purchase, or `roundRupees` of its FIFO cost. In `verifyShares`, a changed purchase must not leave its shares short and a voided purchase whose reference no live purchase has any more must have no live (unreturned) shares ("Change the shares of this purchase first"). Unmarked old documents remain ordinary bulk sales. Both UIs preserve the choice in drafts and load old entries without changing their mode.

`AppController.quoteBulkCost` returns the charge `shareChargeFor` will check. With `sharePurchase` it reads the purchase and its free KG (`Book.purchaseFree`) from the current book, with no replay. Otherwise it prices the FIFO share as the books would: the whole projection with the entry in place (the original excluded when correcting), so a purchase entered later covers a share typed before it. A new entry after everything, with nothing waiting, uses `Book.quoteAtEnd` on the current lots instead (same number, no replay). The last quote is cached until `reload()`. A share no stock of known cost covers is refused. `post` recalculates the quote with the real new id, stores `bulkCost`, and sets a pure share's selling rate to zero. `applyDailyRate` and `restoreSnapshot` re-create shares with new ids, so `_priceShares` prices them all from one projection of the resulting state. `Book.verifyShares` checks changed shares after the whole projection (fully covered, `bulkCost` == `shareChargeFor`) before enqueueing; the server verifies the same ids via transaction-local `khata.verify_shares`, also after its replay.

Shared FIFO cost and the recorded charge meet in `purchase-share:cost`, with no `revenue:bulk` or COGS for that portion. `FifoAllocation.account` and the server FIFO table's `cost_account` retain the cost category so physical credit notes reverse cylinder and shared cost separately. A later purchase-cost correction leaves historical party debt unchanged and exposes the recovery difference in the Purchase shares report, and in a warning when one share's cost and charge differ by Rs 1 or more (whole-rupee charges and proportional rounding leave a few paisa per share). `AppController.sharePurchaseOptions` feeds the "Share from" pickers in both forms; `shareSource` names the chosen purchase on entries and reports. A financial-only credit note of a share moves the shared FIFO cost to `cogs` (the gas is gone). Repricing a posted share requires an ordinary audited correction. Roznamcha's `bill` excludes sharing, `shareAmount` shows it separately, and `totalBilled` adds both for the entry-table footer.

`202611120002_purchase_sharing.sql`, `202611130001_fifo_backorders.sql` and `202611130002_share_purchase.sql` must be applied before syncing clients using these fields or the backorder rule. It changes no source documents during cache rebuild. Reset already clears the source documents, FIFO rows and all form drafts; the sharing tests cover reset and backup restoration too.

### Roznamcha

`RoznamchaDay` (`lib/features/ledger/roznamcha.dart`) arranges one day's documents the way `computeDay()` in `index.html` does: A (Kul Aamad), B (Kharcha + Bank Jama), and Safi Baqaya = A − B. Safi Baqaya must always equal the ledger's cash in hand for that date.

Each document carries `form` (a `RozForm` name) recording which entry tab created it. It is display-only and has no accounting effect; `rozFormOf` infers it when absent.

"Direct to Party" is not on the original page: a customer pays the company the gas is bought from. A sale or receipt can carry legacy `bank`/`bankAccount`, `direct`/`directParty`/`directBank`, and ordered `bankLines`. `Document.bankLines` reads them additively as `BankLine` values (legacy bank, legacy direct, then additional lines). A bank line debits `money:<account>`; a direct line debits `ap:<line party>` and credits `ar:<customer>`, with no money account movement. Bank names are optional descriptive text. Use `bankIn` for money reaching our banks, `direct` for all direct payments, `directTo(party)` for one company's amount, `directParties` for all referenced companies, and `collected` (cash + bankIn + direct) for customer collections. `RoznamchaDay` counts each direct line in A and B (`direct`, `directLines`), so Safi Baqaya is unchanged. Party entries and deletion checks include every direct party (`directFor` in `entry_facts.dart`); its khata/statement row is a "Bank payment" with bank names and the customer. The Wasooli form supports multiple destinations and keeps their controllers in its in-memory draft; a single non-empty line writes legacy fields, several write `bankLines` with legacy amounts zero.

There are two entry UIs, and both end in `app.post`: `RoznamchaForm` (`lib/ui/roznamcha_form.dart`, the six "Naya Entry" tabs for daily cash-book entries) and `EntryComposer` (`lib/ui/entry_composer.dart`, for purchases, stock, cylinders, credit notes and bank-to-bank transfers). Both keep unsaved values in memory on the controller (`rozDrafts`, `composerDrafts`), which ends with the app or organization. A composer draft is kept only for a new entry, is used only for the same party, and always takes the page's date and the current time, never the day it was begun.

Saved drafts (asked for on 17 November 2026) are `EntryDraft` values in `AppController.entryDrafts`, persisted in this organization's `entry_drafts` metadata. The **Draft** button in both UIs keeps complete or incomplete inputs; corrections, conflict reviews and opening-balance dialogs have no Draft button. `source: roznamcha` stores text from `_snapshot()` and its `RozTab`; `source: composer` stores the payload and `EntryType`. `missing` records the English validation message at draft time. The Drafts tab (`lib/ui/drafts.dart`) lists them with Open and Delete. A finished draft keeps its own date. An open Roznamcha draft's unsaved changes use `rozDrafts['<page|dialog>:open']` with `draftId`, and a composer's use `composerDrafts['saved:<id>']`; Cancel leaves the saved draft intact and Draft updates it. Backups preserve drafts and Reset all data erases them.

**Saved drafts count locally in every calculation** (the user's follow-up request). `DraftProjection` (`lib/features/ledger/draft_projection.dart`) converts both saved formats to provisional documents and named parties. `accountingRecords`, `book`, `bookAt`, `record` and `ofKind` include them; `records` stays the actual effective database state and is the only state used to validate and enqueue posted commands. `Record.draftId` / `Document.isDraft` identify projections and are never serialized into a posted record. Missing/invalid values contribute zero, missing parties/banks are explicit unassigned placeholders, and missing purchase prices give unknown stock cost. Draft shares are priced from the combined local projection. They have no server rows or commands until finished; posted accounting is unchanged. Named draft parties get deterministic UUIDs and materialize atomically when an entry needs them; composer drafts retain their selected draft parties' names so deleting another draft cannot lose the name. Provisional masters cannot be edited until posted. Stock returns can remain provisionally uncosted in a draft projection without relaxing posted validation.

Saving/deleting drafts invalidates every book/quote cache. `post(draftId: ...)` uses the draft's id, reference and original order and removes its metadata in the same SQLite transaction as enqueueing the entry; on failure both remain unchanged, and listeners cannot see a double count. Both forms use this path. Quotes and previews exclude the draft being edited; final posting quotes only actual records for server parity. `draftOccurredAt` keeps order stable while `savedAt` changes when a draft is updated. Closing a day requires finishing/deleting all drafts through that date, and edits to drafts on closed days require reopening. Synced day snapshots, restores and daily-rate corrections operate on posted entries only. Entry views label draft rows, and totals/reports explain that saved drafts are included. `test/draft_calculations_test.dart` covers accounting and lifecycle, alongside the form tests in `test/entry_drafts_test.dart`.

The Less / Kami tab's "Less kaise?" (`lessMode`) has four choices. `discount` and `bank` reduce a customer's khata. `cashOut` ("Cash kam") and `cashIn` ("Cash zyada") have no party: cash lost, or money outside the khata. They post an ordinary `adjustment` with `target: 'money:cash'`, a signed amount and a required reason, so they move cash in hand (`RoznamchaDay.cashAdj`) and never the Profit report. `adjustmentLabel` names such a row everywhere; ✏️ on it opens the `editOpeningBalance` dialog like any other adjustment.

Roznamcha Save, Agla Din and Khata Saaf store the day as a `snapshot` record. A day that has not changed since its latest visible snapshot is not stored again. Khata Saaf (`startBatch`) always stores one, with `batchAt`, which `batchStarts` reads, so it syncs; devices from before 12 November 2026 kept `batch:<date>` metadata instead, which is still read (the latest time wins).

### UI

There is no state-management package and no router. `main.dart` runs `KhataRoot`, which shows `KhataApp(app)` with the open organization's `AppController`, a `ChangeNotifier`. `Workspace` in `lib/ui/app.dart` rebuilds on it, shows the page named by `app.page` (an id from the `destinations` list) and passes `app` down to the pages. Change page with `app.go('settings')`; `page` is not business data, so Reset all data leaves it alone. A pending-sync count is shown only when `app.cloudLinked`: a device that has never signed in keeps every entry queued for good, so a count there means nothing. The Android sign-in link `com.zubairtraders.khata://auth` is handled by `supabase_flutter` alone: `AndroidManifest.xml` sets `flutter_deeplinking_enabled` to `false`, so keep it off or Flutter will try to open the link as a route, which this app does not have.

Translation has no ARB files. The English text is the key: `context.t('Cash in hand')` looks it up in the `_ur` map in `lib/core/l10n.dart`. `test/l10n_test.dart` scans `lib/ui` for `.t('...')` literals and fails if any has no Urdu entry. Errors are thrown as `FormatException` or `StateError` with an English message and translated when shown by `perform()` / `errorText()`, so a new error message needs an Urdu entry too, and the test will not catch a missing one. Roman-Urdu labels such as "Wasooli" and "Kharcha" are the business's own terms from the original page.

Reports: `buildReport()` in `lib/features/reports/reports.dart` returns one `Report` (columns and rows of `Cell`) that feeds the on-screen table, XLSX and CSV. Urdu text in PDFs is shaped by Flutter and embedded as 300 DPI images. **Every PDF is printed in the Roznamcha sheet's design** (asked for by the user on 14 November 2026): `Report.sheets` (`RozSheet`s) rendered by `rozSheetPdf`. `buildReport` gives every kind its own sheet (`lib/features/reports/report_sheet.dart`: `reportSheet`, `reportTable`, `SheetFigure`): "<business> — <report>" and the print stamp, a bold heading (dates, party or account, the key figure), a summary row of figures like the Roznamcha's cards, then tables with capital heads, a `#` column, figures on the end side with '—' for nothing, dates as dd-mm-yyyy and a bold Total row. The Party statement has its khata and deposit tables with the balance brought forward unnumbered; Daily customer balances has one table a day (parties and days with no figure left out); balance lists leave out parties whose figures are all 0. `invoiceReport` prints its items with the totals and payments as the foot. A `Report` built anywhere without sheets is printed through `autoSheet`, so nothing falls back to the old table. A table too wide even at the smallest zoom lets its headings break between words. Changing a sheet never changes `rows`, so the table, Excel and CSV stay as they were. A report with `grids` above 1 (the Parties page's Pending balances, `pendingReport`) keeps the business's paper-sheet arrangement, drawn in the same black-and-white style and at the Roznamcha sheet's sizes (18 pt margin, 8.3 pt title, 7.3 pt text, 45 rows of 15 pt a grid): narrow grids side by side with one-line rows of a fixed height (`ReportExporter._gridPdf`), its `sections` rows shaded light grey. `test/report_sheet_test.dart` covers the sheets of every report and prints them all in both languages. The Roznamcha's PDF (Print / PDF, Day history, Reports → Daily roznamcha) is `Report.sheets` instead (`lib/features/reports/roznamcha_sheet.dart`): each day exactly like the original page's "Roznamcha History (Date wise)" print, the user's reference, with its columns as wide as their content like the old browser tables and extra tables or columns only on days that need them. One deliberate exception, asked for by the user: after the print's four summary figures (Opening, A: Kul Aamad, B: Kharcha + Bank Jama, Safi Baqaya) every day also prints Total Gas Dispatch (KG) and Calculated Bill, with the Roznamcha page cards' values (the bill leaves out purchase shares, the dispatch counts their KG), at 0 on a day without sales. `test/roznamcha_sheet_test.dart` rebuilds the user's printed sheet of 25-10-2026 cell by cell; keep it passing when changing the layout. Its `rows` still feed the table, XLSX and CSV. The Money page's Statement (`moneyReport`, also opened by the Total bank card) is one `RozSheet` in the same design, at the end of the top bar's day: Cash | Total bank | Total (Cash + Bank) as the summary, then every account's opening, money in, money out and closing, with Cash, Total bank and Total footers. Its Total bank and the card's (`Book.bankMoney`) count archived accounts, so an earlier day still adds up; the PDF lists an archived account only on a day it held or moved money. It has no Compact switch (`roznamchaSheets` is null).

The Parties page's heading (`PageHeading` with `count` and `beside`) shows how many parties are listed and their You will receive / You will pay totals (sums of the rows' `partyOwed`), following the filter, Archived switch and search. Its Pending balances button opens a menu: every pending balance at the end of the top bar's day (`asOf: app.selectedDate`: `app.bookAt(day)`, that date in the subtitle, the rows whose khata balance that day changed shaded and a note saying so), or `pendingReport(..., day: app.selectedDate)`, only the parties whose khata balance (`ar:` + `ap:`) that day's entries changed, each with its balance at the end of that day (`app.bookAt(day)`), so one that cleared its khata that day is listed with 0 and one whose day's entries cancel out is not listed. Both are arranged by `app.pendingOrder` (`PendingOrder`: `name` A to Z ignoring case, the default; `balance`, to receive largest first then to pay largest first; `newest`, the list's own order), chosen in the same menu's Arrange section, where exactly one choice is ticked and choosing one reopens the menu; it is a view setting, so Reset all data leaves it alone. The subtitle names the order. The day sheet's preview has a **Details** switch: the same `compact`/`roznamchaSheets` mechanism, labelled by `Report.sheetSwitch`. Off it prints the grids; on, one Roznamcha-style sheet with Previous balance, Debit, Credit (summed like the Party statement) and Baqaya jaat. `test/pending_report_test.dart` covers both.

Every PDF preview (`previewReport` in `lib/ui/export_ui.dart`) has a **size slider** under its title (`pdfPreviewBar`, `PdfSizeBar`; asked for by the user on 16 November 2026): 50% to 150% in 5% steps, − and + buttons, and the percentage, which goes back to 100%. It changes the real PDF, so what is saved, shared or printed is what is shown: `ReportExporter(size:)` scales type, padding, row heights and spacing in `rozSheetPdf` and `_gridPdf`, never the A4 page or its 18 pt margin. In `rozSheetPdf` the size is the starting zoom; a wide day still shrinks to fit, down to `_minScale` of the chosen size, and what is still too wide wraps. The grids hold `ReportExporter.gridRowsAt(size)` rows (45 at 100%, 97 at 50%, 27 at 150%). At 100% every number is what it was before the slider, so the reference sheet tests are unaffected. The PDF is rebuilt when the slider is let go, cancelling the one being prepared. The size is remembered per `Report.kind` (a stable English name every builder sets; the title when empty) in `AppController.pdfSizes`, saved as the organization's `pdf_sizes` metadata: it is erased by Reset all data (cleared in memory in `resetAll()`) and comes back with a backup restore. Excel, CSV and the on-screen tables ignore it. `test/pdf_size_test.dart` covers it; the layout test draws the bar at every size.

The Reports page has a **Compact** toggle for every report (`buildReportView` in `lib/features/reports/daily_report.dart`). It produces one summary row per date: movements summed in integer paisa/grams, statements with end-of-day balances and separate deposit figures, balance/custody lists with a snapshot for every date in the range, profit by day, FIFO costs by the sale date, and audit counts by Karachi date. Rates are left out; opening/closing balances are never summed across dates. Invoice outstanding stays as of the report end date, as in the detailed register. The table, PDF, Excel, CSV and copy all use the selected view. `Report.compactView` rebuilds the complete view when `withCompact` is called; the preview switch also updates the page's switch. Turning it off restores the detailed report. Audit trail filters both views by the selected range. `test/daily_report_test.dart` covers all report kinds, both languages, daily calculations, exports and page layouts.

The separate Roznamcha page and history PDF previews retain their own Compact behavior. The page's original Entry wise / Customer wise toggle and `AppController.rozCustomerWise` retain their original subtotal-and-details behavior and have no effect on PDF mode. The PDF's old debug switch is disabled. `rozSheet` groups compact A rows by party ID within each day (company receipts and deposits stay separate), sums Bill/Cash/Bank/Direct and quantities, and shows a rate only when it is common to the grouped sales. Keep the customer/party name once; the Bank and Direct cells contain only their combined amount, with no bank/account/destination names underneath. B and Bank Nikali/Less group by entry type and actual party/account IDs. `Report.withCompact` uses `roznamchaSheets` for these live and saved PDF sheets without changing source documents or Excel/CSV rows. Compact text ends in an ellipsis when it exceeds its measured width; amounts keep their full width. `test/roznamcha_compact_test.dart` covers grouping, unchanged totals, history/ranges, the restored page toggle's independence, bilingual layouts and PDFs.

## Tests

Tests run the real stack on an in-memory database:

```dart
final db = KhataDatabase(NativeDatabase.memory());
await db.initialize();
final app = AppController(db);
await app.initialize();
```

`test/layout_overflow_test.dart` opens every page and main dialog at six sizes (down to a 360x640 phone) in English and Urdu with the real fonts, and fails on any overflow. UI changes have to fit all of them.

Widget and report tests write preview files to `build/` (`preview-*.png`, `urdu-statement.pdf`, `urdu-statement.xlsx`). `tool/render_pdf.ps1` turns the PDF into a PNG, using `pdfium.dll` from the Windows release build, to check Urdu rendering by eye.

## Other things to know

- `windows/compat/atlstr.h` stands in for the two ATL conversions that `flutter_secure_storage` uses, so the Windows build does not need the ATL/MFC workload. Keep it.
- `README.md` ends with dated verification sections. After a verified change, add one that says what was run and what was not re-run.
