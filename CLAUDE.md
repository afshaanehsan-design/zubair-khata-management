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

### Client and server must agree

The Supabase side (`supabase/migrations/`, contract in `supabase/README.md`) re-validates and re-projects every command inside the `apply_command` RPC. Three things exist twice and must be changed together:

| Client | Server |
| --- | --- |
| `validateDocument` in `book.dart` | `khata_private.validate_document` |
| `Book._project` and FIFO | `khata_private.rebuild`, `consume` |
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
- New in-memory state on `AppController` (like `rozDrafts` and `composerDrafts`) must be reset by hand in `resetAll()`.
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

Roznamcha Save, Agla Din and Khata Saaf store the day as a `snapshot` record. A day that has not changed since its latest visible snapshot is not stored again. Khata Saaf (`startBatch`) always stores one, with `batchAt`, which `batchStarts` reads, so it syncs; devices from before 12 November 2026 kept `batch:<date>` metadata instead, which is still read (the latest time wins).

### UI

There is no state-management package and no router. `main.dart` runs `KhataRoot`, which shows `KhataApp(app)` with the open organization's `AppController`, a `ChangeNotifier`. `Workspace` in `lib/ui/app.dart` rebuilds on it, shows the page named by `app.page` (an id from the `destinations` list) and passes `app` down to the pages. Change page with `app.go('settings')`; `page` is not business data, so Reset all data leaves it alone. A pending-sync count is shown only when `app.cloudLinked`: a device that has never signed in keeps every entry queued for good, so a count there means nothing. The Android sign-in link `com.zubairtraders.khata://auth` is handled by `supabase_flutter` alone: `AndroidManifest.xml` sets `flutter_deeplinking_enabled` to `false`, so keep it off or Flutter will try to open the link as a route, which this app does not have.

Translation has no ARB files. The English text is the key: `context.t('Cash in hand')` looks it up in the `_ur` map in `lib/core/l10n.dart`. `test/l10n_test.dart` scans `lib/ui` for `.t('...')` literals and fails if any has no Urdu entry. Errors are thrown as `FormatException` or `StateError` with an English message and translated when shown by `perform()` / `errorText()`, so a new error message needs an Urdu entry too, and the test will not catch a missing one. Roman-Urdu labels such as "Wasooli" and "Kharcha" are the business's own terms from the original page.

Reports: `buildReport()` in `lib/features/reports/reports.dart` returns one `Report` (columns and rows of `Cell`) that feeds the on-screen table, PDF, XLSX and CSV. Urdu text in PDFs is shaped by Flutter and embedded as 300 DPI images. A report with `grids` above 1 (the Parties page's Pending balances, `pendingReport`) is printed like the business's paper sheet instead: narrow grids side by side with one-line rows of a fixed height (`ReportExporter._gridPdf`). The Roznamcha's PDF (Print / PDF, Day history, Reports → Daily roznamcha) is `Report.sheets` instead (`lib/features/reports/roznamcha_sheet.dart`): each day exactly like the original page's "Roznamcha History (Date wise)" print, the user's reference, with its columns as wide as their content like the old browser tables and extra tables or columns only on days that need them. `test/roznamcha_sheet_test.dart` rebuilds the user's printed sheet of 25-10-2026 cell by cell; keep it passing when changing the layout. Its `rows` still feed the table, XLSX and CSV.

`Compact` belongs only to Roznamcha PDF previews. The page's original Entry wise / Customer wise toggle and `AppController.rozCustomerWise` retain their original subtotal-and-details behavior and have no effect on PDF mode. The PDF's old debug switch is disabled. `rozSheet` groups compact A rows by party ID within each day (company receipts and deposits stay separate), sums Bill/Cash/Bank/Direct and quantities, and shows a rate only when it is common to the grouped sales. Keep the customer/party name once; the Bank and Direct cells contain only their combined amount, with no bank/account/destination names underneath. B and Bank Nikali/Less group by entry type and actual party/account IDs. `Report.withCompact` rebuilds live and saved PDF sheets without changing source documents or Excel/CSV rows. Compact text ends in an ellipsis when it exceeds its measured width; amounts keep their full width. `test/roznamcha_compact_test.dart` covers grouping, unchanged totals, history/ranges, the restored page toggle's independence, bilingual layouts and PDFs.

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
