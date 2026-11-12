# Zubair Khata

Native Flutter bookkeeping for an LPG business, for Android and Windows. Fresh records; PKR; Asia/Karachi business dates. The original `index.html` is retained as a reference and is not used to render the application.

## Run

```powershell
flutter pub get
flutter run -d windows
```

If Windows Developer Mode is disabled, prepare workspace-only plugin junctions after fetching packages:

```powershell
powershell -ExecutionPolicy Bypass -File tool/windows_links.ps1
flutter run -d windows --no-pub
```

The app works locally without cloud configuration. Start by adding parties (with their old balances), bank accounts, the opening cash in hand (**Opening cash**, entered once), gas stock and cylinder counts. All actions persist in SQLite. No sample transactions, old opening balances or Firebase data are installed.

Builds:

```powershell
flutter build windows --release --no-pub
flutter build apk --debug --no-pub
```

The Windows executable and its adjacent DLL/data files must be distributed together. Android debug APKs are for local evaluation. Configure your own release signing before distribution.

To package the complete Windows release after a successful build:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/package_windows.ps1
```

The resulting `build/Zubair-Khata-1.0.0-Windows-x64.zip` contains the executable, plugins and bundled fonts. Extract the complete archive before running `zubair_khata_management.exe`. The Android evaluation installer is `build/app/outputs/flutter-apk/app-debug.apk`.

## Daily use

- **Roznamcha:** the daily cash book laid out like the original page: summary cards (A: Aamad, B: Kharcha + Bank Jama, Safi Baqaya, gas dispatch, calculated bill with day-rate apply), the Naya Entry tabs, the A: Aamad / Wasooli and B: Kharcha tables, Hisab Mel, Roznamcha Save, Agla Din, Khata Saaf (new batch), printing and closing.
- **Activity:** search and filter source transactions; inspect effects; correct or void with an audit reason.
- **Parties:** customers, suppliers and Udhari classifications over one identity. View trade accounts, invoices, custody and deposits independently.
- **Money:** cash/bank/personal accounts, statements, transfers and counted-balance reconciliation.
- **Stock:** gas FIFO lots, unknown costs, full/empty/held cylinders, filling, exchange, issue and return.
- **Reports:** PDF preview/printing, real XLSX, UTF-8 CSV and copyable tables.
- **Settings:** organizations, business profile, complete Urdu RTL interface, cloud account, backups, conflict review and **Reset all data**.

Use **Ctrl+N** for a new entry and **Ctrl+Enter** to add it. Roznamcha form values are kept while you move between pages.

Daily entry uses six **Naya Entry** tabs of the original HTML, with the same fields in the same order: **Wasooli / Sale, Kharcha / Payment** (Cash kharcha, Bank account mein jama, Company ko payment, Customer ko payment, Udhar wapsi), **Bank se Cash Nikala, Less / Kami** (discount, or bank deposit into an account), **Office kharcha** and **Company se Wasooli**. The HTML's "Opening Theek Karo" tab is intentionally left out: it existed to patch damaged old data. Opening balances are entered once (a party's or account's when it is added, the cash in hand with **Opening cash**), and a wrong one is corrected with ✏️ like any other entry. Wasooli without cylinders is recorded as a receipt. Typing a new customer or company name creates it with the entry; existing names match regardless of case and spacing. The rate field keeps the last rate used. ✏️ loads a row back into its form; Update and 🗑️ ask for a reason, and the original stays in the audit trail. Purchases, stock, cylinders, credit notes and bank-to-bank transfers use the general composer.

Each entry stores the Roznamcha form it came from (`form`, display only), so a bank Less is shown as a Less row exactly as on the original page.

**Direct to Party** (Wasooli / Sale tab only) is for money a customer did not pay to you: you gave the customer the company's account and the customer paid the company the gas is bought from. Type the amount in **Bank Wasooli** and choose **Direct to Party**, the last choice of the Bank / Account list; a company field then takes the list's place (the bank icon beside it brings the list back). A new name creates the company. The optional **Kis bank mein? (company ka)** field records its bank name and suggests names used before. Use **+** beside Bank Wasooli to add more payments, each into one of your banks or directly to a company; remove an extra line with its minus button. Cash and all non-empty lines are saved in one entry, and ✏️ loads every line for correction. Direct money reduces the customer's debt and what you owe that company, with no cash or bank account movement. The company's khata and statement register it as **Bank payment**, showing its bank name(s), **Customer: <name>**, and only the amount paid to that company. Other entry views and printed reports show the bank name beside the company.

**Udhar wapsi** pays back money borrowed from an Udhari party. It is a payment with `supplierPayment: true` (it reduces what you owe the party, `ap:<party>`, exactly like Company ko payment) and `form: udharWapsi`; its party field suggests only Udhari parties, and a new name opens a new Udhari khata. **Cash kharcha** is an expense and is never linked to a party, so it never appears in a khata. An entry opened from a party's khata (the party's **Udhar wapsi** / **Company ko payment** button, or Aamad / Wasooli) keeps that party on every tab and after saving, the Kharcha tab starts on the type that pays that party, and a tab or type without a party shows "Yeh entry … ke khata mein nahi jayegi".

## Accounting conventions

Money is integer paisa; gas is integer grams; cylinder counts are integers. Invoice/purchase bills round to whole rupees. Intermediate multiplications use arbitrary-precision arithmetic to avoid integer overflow.

The agreed legacy rule is retained: cylinder gas consumes stock and contributes to Sales Khata; extra/bulk KG adds customer billing but does not consume stock or contribute to cylinder Sales Khata. Bulk billing is shown separately and means full-business profit is incomplete until its cost is defined.

Roznamcha totals follow the original `computeDay()`: A (Kul Aamad) = opening + cash wasooli + bank wasooli + bank se nikali; B = cash kharcha + bank wasooli (auto bank jama) + cash deposited to bank; Safi Baqaya = A − B. Safi Baqaya always equals the ledger's cash in hand. A bank Less reduces the customer and increases the account without entering A or B. Direct to Party (not on the original page) is treated like a bank wasooli: each direct line on a sale or receipt posts `ap:<line party>` debit / `ar:<party>` credit, is counted as wasooli in A and as an automatic payment to that company in B, so Safi Baqaya is unchanged. Collections include cash and every bank/direct line; bank names are descriptive and have no accounting effect. A single Bank Wasooli keeps the legacy `bank`/`bankAccount` or `direct`/`directParty`/`directBank` fields; several use ordered `bankLines`. It settles the customer's bills like any other collection. The opening is always the previous day's closing and cannot be typed over. The opening cash is entered once, as an entry at the start of its day; it and the opening balances of parties and accounts are shown as "Opening balance" rows in the A table, where ✏️ corrects and 🗑️ deletes them with a reason. A counted-cash difference (Cash reconciliation) is shown as an "Adjustment" row.

Customer credit, supplier advances, lending, noncash discounts and cash/bank transfers have separate accounting effects. Refundable cylinder deposits are liabilities, not revenue. Changing a party classification or archiving a record does not change its financial history. A party with no entries can be deleted with the bin icon beside Edit in its details; voided entries do not count, but an opening balance does until it is deleted. Deleting sets `deleted: true` on the party (the khata never erases rows, so it syncs like any other change): the party disappears from every list, including Archived, its name can be used again, and it cannot come back or take new entries.

Stock shortages are allowed and shown explicitly. A later purchase reserves the physical deficit and records provisional cost; it does not pretend that earlier unknown margins are final. Enter/correct the missing dated purchase or opening cost to establish FIFO. Gas filling changes full/empty counts, not total gas KG, so gas is not consumed twice.

Full-invoice credit notes preserve collections and deposits. A customer cash refund is a separate payment. Returning gas to stock restores original known FIFO cost; physical cylinder returns are entered separately. An invoice with unknown original gas cost must have that cost resolved before a valued stock return.

Manual historical summaries are labelled reporting/stock-only and cannot overlap detailed sales on the same date. They do not invent cash receipts or customer debt, and make complete profit provisional.

## Organizations

One device can hold several organizations. Each is a complete, separate khata: its own parties, accounts, entries, closed days, backups and, online, its own account. They work offline like a single khata does.

- **Switching.** Tap the business name at the bottom of the side rail (the building icon on the narrow rail, **More → Organizations** on a phone) or use **Settings → Organization → Switch or add organization**. There is no lock or PIN: anyone using the device can open any organization. The app starts in the one that was open last. Opening another one rebuilds the whole app, so no page, draft or search text carries over.
- **Adding.** **New organization** asks for a name, which becomes its business name, and opens it empty. It takes over the cloud project (URL and key) of the organization that was open, so it only has to sign in.
- **One email per organization.** Online an account is one organization's books. The app refuses to sign an organization into an email that another organization on the same device already uses, and an organization stays bound to the account it first signed into. Each organization keeps its own sign-in, so they stay signed in side by side.
- **Removing.** **Settings → Organization → Remove from this device** deletes the open organization's database from this device after its name is typed (a backup is offered first). The cloud copy is not erased; use **Reset all data** first if that should go too. The last organization cannot be removed.
- **Reset all data** erases the open organization only and keeps its name. Every organization is reset on its own: the other organizations' files are not opened or changed, and on a cloud-linked organization only that organization's account is erased. On Android the cached copies of shared backups and reports are kept in a folder per organization (`exports/<organization id>/`), so a reset or a removal deletes that organization's copies and nobody else's.
- **Language** is a device setting, shared by all organizations.

Where it is stored: the first organization is `khata-v1.sqlite` in the app's support folder, the file a device already had before organizations existed, left in place. Each added one is `khata-org-<8 hex digits>.sqlite` beside it. `organizations.json` in the same folder holds the list, the last one used and the language. It is only a convenience: if it is lost or damaged the list is rebuilt from the database files, and other files in the folder (such as a manual `khata-v1.backup-….sqlite` copy) are ignored.

A limit to know about: the app can only see this device. Signing a new organization into an email that already holds a different business's data from another device joins that data, exactly as a second device of the same business does.

## Cloud setup

The Supabase backend is implemented in `supabase/migrations/`, to be applied in name order: `202611070001_khata.sql` (schema, row-level security, command RPCs and server validation), `202611070002_roznamcha_form.sql` (keeps the Roznamcha `form` and receipt parchi), `202611100001_reset_dataset.sql` (lets the owner erase the cloud dataset from **Reset all data**), `202611100002_party_delete.sql` (deleting a party that has no entries) and `202611100003_drop_lookup_command.sql` (removes an RPC the app never called). Nothing in this repository creates the Supabase project itself.

1. Create `zubair-khata-management` in your Supabase organization, Free tier if capacity permits, Mumbai (`ap-south-1`).
2. Apply the migrations in name order in the SQL editor, or link the Supabase CLI and run `supabase db push`. A project that already has some of them only needs the later ones. Without `202611100001_reset_dataset.sql`, Reset all data on a signed-in device fails and changes nothing.
3. Enable email/password authentication. Configure confirmation/recovery mail and allow `com.zubairtraders.khata://auth` as an Android redirect. For recovery on Windows, include `{{ .Token }}` in the recovery email template so its code can be entered in Settings.
4. Enter the project URL and **publishable** key in Settings, then create/sign into the same owner account on each device. Never use a service-role or secret key in the app. Every organization uses the same project with an email of its own (see Organizations); no extra server setup is needed for a second one.

Alternatively supply public configuration at build/run time:

```powershell
flutter run -d windows --dart-define=SUPABASE_URL=https://PROJECT.supabase.co --dart-define=SUPABASE_ANON_KEY=YOUR_PUBLISHABLE_KEY
```

First authentication requires internet. Later offline work uses the existing owner-bound database. Authentication sessions are stored using the platform secure-storage adapter, one per organization, outside backups. Pending entries are never silently deleted on sign-out.

The server owns command validation and commits each compound operation atomically. The client retries the same frozen command UUID after interrupted responses. A locked per-owner row produces a durable, ordered change cursor. Rejected edits have no financial effect; conflicting changes remain available for review. No whole-dataset last-writer-wins replacement is used.

Closing requires successful synchronization. Closed dates reject late entries; reopening invalidates affected later closes. A dataset epoch change stops old writes. Reconnect to cloud stages the new feed, preserves the prior backup and quarantines unresolved commands for review with new IDs.

For administrative database rollback, change `khata_sync.epoch` to a fresh UUID before reopening writes. The epoch restored from an old database backup cannot itself detect a rollback.

## Backup and Urdu exports

Backups contain a consistent versioned snapshot and queued commands with a SHA-256 integrity checksum. They exclude authentication tokens. Validate backups before restoring; a backup restored on a connected device recovers missing pending commands and does not overwrite newer server records. The checksum detects accidental corruption; it is not encryption or proof of authenticity. A backup is of the open organization only, and its file name carries the business name (`ZubairKhata_<name>_Backup_<date>.json`). Restoring a backup whose business name differs from the open organization's asks first, because a restore on a device without a cloud account replaces the whole khata.

**Reset all data** (Settings) erases everything in the open organization and starts again with an empty khata (only the cash account and the business profile, which keeps the organization's name): parties, accounts, entries, closed days, saved days and batches, pending and rejected changes, drafts, the pre-restore recovery copy and, on Android, the cached copies of shared backups and reports. It keeps the device id, the language, the cloud connection and the sign-in. The user must type RESET, and the dialog offers **Export backup** first. Reset cannot be undone. On a device that has been linked to a cloud account it must be signed in and online: the cloud dataset is erased first (`reset_dataset`), so the next sync cannot bring the old data back. The new epoch stops other devices, which then use **Reconnect to cloud**. Their unsent entries are quarantined for review, not sent.

Urdu and Latin fonts are bundled and work offline. The PDF renderer shapes Urdu using Flutter, renders only complex-script text blocks at 300 DPI, and keeps numbers, Latin text and table rules vector. Urdu bitmap blocks are not selectable/searchable. XLSX and CSV retain editable Unicode. Long rows are measured and split, headings repeat, and export generation is cancellable.

Fonts: Noto Nastaliq Urdu and Manrope, SIL Open Font License. Licenses are bundled under `assets/fonts`. Sources: https://github.com/google/fonts/tree/main/ofl/notonastaliqurdu and https://github.com/google/fonts/tree/main/ofl/manrope.

## Verify and extend

```powershell
flutter analyze
flutter test
```

Tests cover monetary parsing, the agreed sales fixture, FIFO/shortages, advances, transfers, deposits, credit notes, snapshot restoration, immutable corrections, offline sync/retries/conflicts, backups, responsive English/Urdu layouts and real PDF/XLSX generation. Preview artifacts are written under `build/`.

`tool/backend_test.dart` is an integration harness for a disposable PostgreSQL instance on localhost port 55439. It verifies the migration, numerical parity, idempotency, rollback, closing and owner isolation. It is not a production deployment script.

Code boundaries:

- `lib/core`: records, exact arithmetic, localization, application commands and the organizations on the device (`organizations.dart`).
- `lib/data`: Drift persistence, secure sessions and sync transport/worker.
- `lib/features/ledger`: deterministic journal, FIFO, custody and settlement projections, and the Roznamcha day view (`roznamcha.dart`).
- `lib/features/reports`: shared report data, PDF shaping, XLSX/CSV.
- `lib/ui`: adaptive workspace, entry forms, ledgers, settings and reports.
- `supabase/migrations`: schema, RLS, command RPCs and server accounting validation.

The Windows compatibility header only supplies the two UTF conversions used by the secure-storage dependency; its Credential Manager/BCrypt implementation remains intact. It avoids an otherwise unnecessary ATL/MFC installation.

Live authentication, actual multi-device networking, phone sharing and physical printer output must be checked against the deployed Supabase project and target devices. Staff roles, migration of legacy records, automated messaging, tax filing, and store publishing are outside this version.

## Local verification — 7 November 2026

- Full Flutter suite: 32 tests passed, including the six daily forms, receipt-only Aamad, bank withdrawals and Kharcha bank deposits; final PDF/XLSX tests also passed.
- Full analyzer and final report-file analyzer: no issues.
- Disposable PostgreSQL integration: 19 checks passed, including server/client calculation parity, idempotency, concurrent owner commits, rollback, closing and owner isolation.
- Final Windows x64 release and Android debug APK builds succeeded.
- Final Urdu statement PDF rendered through PDFium and visually checked for joined Nastaliq, right alignment, legible amounts and pagination.

These checks use local databases and native build tools. They do not establish a live Supabase deployment or replace checks on physical phones and printers.

## Roznamcha update — 7 November 2026

- Full analyzer: no issues. Full Flutter suite: 39 tests passed, including a mixed-day fixture checked against the original `computeDay()` totals, the seven entry tabs, editing and deleting rows, the printed Roznamcha, and English/Urdu desktop and phone layouts without overflow.
- Disposable PostgreSQL integration (both migrations): 20 checks passed, including keeping `form` and receipt parchi.
- Windows and Android builds were not re-run for this update.

## Opening Theek Karo removed — 9 November 2026

- The "Opening Theek Karo" tab and the "Theek karo" button beside the day's opening are gone. The opening cash is entered once (**Opening cash**); opening balances show as rows that ✏️ corrects and 🗑️ deletes, each with a reason.
- Full analyzer: no issues. Full Flutter suite: 40 tests passed, including the six entry tabs and a new test for entering the opening cash and correcting customer, company and cash opening balances.
- No server change: the existing migrations already accept these entries. The PostgreSQL integration and the Windows/Android builds were not re-run.

## Reset all data — 10 November 2026

- Settings has a **Reset all data** panel (type RESET to confirm; Export backup offered in the dialog). Locally it empties every SQLite table and keeps only the device, language and cloud-connection metadata; on a cloud-linked device it first calls the new `reset_dataset` RPC (`202611100001_reset_dataset.sql`).
- Full analyzer: no issues. Full Flutter suite: 50 tests passed, including new tests for a local reset (every table, metadata key, draft, batch and in-memory form draft cleared; a table unknown to the code also emptied), a refused reset on a signed-out cloud-linked device, and a two-device cloud reset where the other device is stopped and then reconnects onto the empty dataset. The reset dialog was added to the English/Urdu layout walk at all six sizes with no overflow.
- Disposable PostgreSQL integration (all three migrations): 28 checks passed, 8 of them new: anonymous callers cannot reset, a stale epoch changes nothing, every owner table is emptied, other owners are untouched, old-epoch writes and pulls fail, and the next sync bootstraps the defaults.
- Not run: the Windows/Android builds, a live Supabase project, and deleting the Android cache copies on a phone (`clearExportCopies` does nothing on Windows and is not covered by tests).

## Delete a party — 10 November 2026

- The party details dialog has a bin icon beside Edit. With live entries it explains why not (and suggests Archive); without, it asks "Pakka?" and then closes. Rules and storage are described under Accounting conventions. New migration `202611100002_party_delete.sql` replaces `apply_command` so the server enforces the same rules (no entries, no restore, no new entries, name free again, only parties). Existing data needs no migration.
- Reset needs no change: the flag lives inside the existing party row, which reset already erases.
- Full analyzer: no issues. Full Flutter suite: 56 tests passed, including the new `test/party_delete_test.dart` (delete, hidden everywhere, name reuse, entries block, voided entries do not, no new entries, no restore, only parties, and the dialog icon: its place beside Edit, confirm, cancel and the blocked message) and the English/Urdu layout walk at six sizes with the extra icon.
- Disposable PostgreSQL integration (all four migrations): 35 checks passed, 8 of them new, covering the same server rules.
- Not run: the Windows/Android builds, a live Supabase project (the new migration is not yet applied there), and a by-eye run of the app.

## Opening balance date when adding a party or account — 10 November 2026

- Add party / Add account has an **Opening balance date** field under the opening amounts. It starts on the page's date and opens a calendar; the chosen day is the date of the opening-balance entries (and of their `OP-…` reference). Editing an existing party or account has no opening fields, as before. A rejected create reopened from Settings → conflicts starts on the date of the original entry.
- No server change: the entries are ordinary opening-balance adjustments, which the server already accepts on any open day.
- Full analyzer: no issues. Full Flutter suite: 60 tests passed, including the new `test/master_opening_date_test.dart` (party receivable and payable and an account dated on the chosen day and valid in `bookAt`, the page date still used by default, a closed day refusing it with nothing half-saved, and picking a day in the dialog) and the English/Urdu layout walk at six sizes with the extra field.
- Not run: the PostgreSQL integration, the Windows/Android builds and a by-eye run of the app.

## Entry details in plain words — 10 November 2026

- Every entry now says what it is, not just its total. The details dialog (tap any entry) shows who, the date, how much and whether it is paid; for a sale, **What was sold** (each cylinder size with count, weight and amount, the rate and the bill total), **Cylinders** (delivered, empties returned, what the customer holds now), **Payment** (cash, bank, still due on this bill) and **Details** (parchi, due date, note). Other types get their own rows (purchase: weight, rate, paid, still owed; transfer: from → to; cylinder movement: size and full/empty/held change; stock adjustment, credit note, deposit, discount, payment, expense, opening balance). The accounting postings moved into a collapsed **Accounting entries** card and read "Ali Raza owes you +Rs …" instead of raw ledger names.
- A sale whose cash went to an older balance now explains it ("Rs 200,000 of the money received here went to the older balance first …"), so "cash received" next to "still due" no longer looks wrong. Receipts say which invoices they settled. This is read from `Book.receiptAllocations`; no allocation rule changed.
- Entry rows on Activity, the party dialog, the Roznamcha "other entries" panel, Stock → Overdue and the pending-change review show the same one-line summary (cylinders and rate, weight and rate, cash/bank split…), a Paid / Due Rs X chip, and Voided. The party dialog drops the repeated party name and shows the party's running balance after each entry; its Invoices section is now "Unpaid invoices" with bill, paid and due. Purchase lots show supplier, remaining KG and rate.
- The "Pending" / "Synced" tag is shown only on a signed-in device and reads "Waiting to sync": on a local-only device every entry stayed "Pending" for ever and looked like an unpaid bill. Also fixed: "Bank received 0 ·" with no bank, "Due date:" with no date, and opening balances labelled "Adjustment".
- Code: `lib/features/ledger/entry_facts.dart` (pure functions over `Document` and `Book`; `Document.saleLines` in `models.dart` is shared with the invoice PDF). No accounting, server, migration or stored-data change, so Reset all data is unaffected.
- Full analyzer: no issues. Full Flutter suite: 66 tests passed, including the new `test/entry_facts_test.dart` (the Ali Raza case with an older opening balance, a paid and bank sale, every entry type described in English and Urdu with every label checked against the Urdu map, voided entries, and the dialog and party ledger text) and an extended `test/l10n_test.dart`. The English/Urdu layout walk now also opens the details dialog for the first and last entry of every type (including a long sale with a long party name) at all six sizes down to 360×640 on Windows and Android: no overflow. Rendered the sale, purchase, cylinder, party and Activity screens to images and checked them by eye in English and Urdu, and a 390 px phone.
- Not run: the PostgreSQL integration (no SQL change), the Windows/Android builds, and a by-eye run of the live app.

## Party cards: receive and pay — 10 November 2026

- Each party card on the Parties page now shows **You will receive** and **You will pay** on separate lines (pay in red), plus **Net** when a party has both, and **Settled · Rs 0** when nothing is owed either way. Before, the pay side showed only for parties marked Supplier, so a customer you owed money to read "You will receive Rs 0". A customer's advance counts as pay and an overpaid company as receive (`partyOwed` in `entry_facts.dart`); the "You will receive / You will pay" filter chips use the same rule. Amounts are aligned to the card's far edge (right in English, left in Urdu).
- Full analyzer: no issues. Full Flutter suite: 68 tests passed, including two new tests (the receive/pay rule for owed, company, both, settled and advance parties; the cards' lines and the amount sitting at the card edge) and the English/Urdu layout walk at six sizes. Rendered the Parties page in English and Urdu and checked it by eye.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Parties: list on the left, details on the right — 10 November 2026

- The Parties page lists parties newest first (the order they were first saved: `KhataDatabase.confirmed()` now reads `ORDER BY rowid`, and an edit keeps a party's place; nothing new is stored). On a wide screen (content at least 840 px) the list sits on the left and the chosen party's details on the right, each scrolling on its own; the newest party is shown until another is picked. In Urdu the layout mirrors, so the list is on the right. On narrower screens a tap opens the same details as a dialog, as before.
- Each list row shows name, phone and kind, and on the far side what the party owes you and what you owe it (or Settled). The details (`PartyDetails`, shared by the dialog and the pane) show the balances as a compact strip: You will receive, You will pay (with the net when both exist) and Refundable deposit. Archive moved into the button row. Deleting from the pane keeps the page open and shows the next party.
- The Workspace gives the Parties page the full height instead of the shared scroll view.
- Full analyzer: no issues. Full Flutter suite: 69 tests passed, including a new test (newest first, list left of details, picking a party updates the pane without a dialog, the net, a dialog on a narrow screen), a new delete-from-the-pane test, the party-dialog tests scoped to the dialog, and the English/Urdu layout walk at six sizes. Rendered the page at 1366×720, 1024×700 and 390×844 in English and Urdu and checked it by eye.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Udhar wapsi and payments from a khata — 10 November 2026

- Why: a Rs 15,00,000 payment meant for an Udhari party (استاد عثمان) was saved as **Cash kharcha**, which has no party, so it never showed in his khata. The form had been opened from his khata, but switching to the Kharcha tab dropped his name and fell back to Cash kharcha without a word, and Udhari parties were never suggested in any party field.
- New Kharcha type **Udhar wapsi** (rules under Daily use). The party dialog of an Udhari party leads with an **Udhar wapsi** button (a company gets **Company ko payment**); the form shows "Khata: <name>", keeps the party on every tab and after saving, starts the Kharcha tab on the type that pays that party, and warns when a tab or type would leave the entry out of the khata. The party ledger's running balance now nets what the party owes you and what you owe it (before, only `ar:`), so udhar and company entries show "You owe Rs …" after each row; an Udhari party's opening balance reads "Udhar liya — aap ne dena hai" instead of "You owe the company".
- No migration: the posting is the existing `supplierPayment` payment, `form` was already free text in both whitelists, and old documents read as before. Nothing new is stored, so Reset all data needs no change.
- Live data (local device, app closed, backup `khata-v1.backup-2026-11-10-before-udhar-wapsi.sqlite` beside the database): the mistaken expense `TX-20261101-DBF0-69665E4D` was voided with a reason through `AppController.voidDocument`, and an Udhar wapsi `TX-20261101-DBF0-0A09E3B3` (same date, time and Tafseel) was posted. Ustad Usman's payable went from Rs 3,225,000 to Rs 1,725,000; Safi Baqaya for 2026-11-01 stayed Rs 2,292,170. The same script was run first on a copy.
- Full analyzer: no issues. Full Flutter suite: 73 tests passed, including new tests for Udhar wapsi in the form (suggestions, balance preview, posting, Roznamcha B row, new Udhari party), the khata flow (party kept, type picked, warnings, kept after save), the Udhari party dialog (button, activity, running balance, the button opening the form), the Roznamcha day and stored-form rules, and the English/Urdu layout walk at six sizes with an Udhari khata, the Udhar wapsi form and the warning. PostgreSQL integration (all migrations): 37 checks passed, including a new Udhar wapsi check (form kept, `ap:` reduced like the client). `flutter build windows --debug` succeeded.
- Not run: the release and Android builds, a live Supabase project, and a by-eye run of the app.

## Parties page: list column and full-height details — 10 November 2026

- On a wide screen the left column now holds everything for finding a party (heading, Add party, the filter chips and the list) and scrolls as one, so the heading scrolls away with the list. The chosen party's details fill the whole height on the right and scroll on their own, instead of starting below the heading and filters. Narrow screens are unchanged: the whole page scrolls and a tap opens the details dialog. UI only; nothing new is stored.
- Full analyzer: no issues. Full Flutter suite: 73 tests passed, including the English/Urdu layout walk at six sizes; the two Parties-page tests now find the list by `PartiesPage.listKey` instead of a `ListView`.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.
## PDF tables: Excel-style grid — 11 November 2026

- Every PDF (party and bank statements, reports, invoices, Roznamcha) is drawn by `ReportExporter.pdf()`. Its table border was a 0.4 pt pale line that mostly disappeared once the preview turned the page into an image, so rows ran together. It is now a grid like a spreadsheet: 0.75 pt grey-green lines between every row and every column, and a darker 1 pt outline. The on-screen tables, the XLSX and CSV exports, and all accounting are unchanged. Nothing new is stored.
- `flutter analyze` on the file: no issues. Full Flutter suite: 79 tests passed, including the report tests and the English/Urdu layout walk. `build/urdu-statement.pdf` was turned into a PNG with `tool/render_pdf.ps1` and checked by eye: every row and column line shows, and the Urdu text renders cleanly.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Cleanup of unused pieces — 10 November 2026

- Removed because nothing used them: the `ios/`, `macos/`, `linux/` and `web/` folders (only Windows and Android are built; `flutter create` brings a platform back), the `flutter_riverpod` and `go_router` packages and the five packages only they pulled in (`riverpod`, `state_notifier`, `listen`, `cupertino_ui`, `material_ui`; no other package changed version), `roundedDivide`, `Record.copy`, `RoznamchaDay.kharchaAll`, `AppController.busy` and `initialized`, 33 Urdu entries no screen asked for, the copy of `nameKey` inside `saveMaster`, and the server RPC `lookup_command` (`202611100003_drop_lookup_command.sql`; a repeated send is answered from its stored receipt).
- Navigation is `AppController.page` and `go(id)` instead of a router, and each page still opens scrolled to the top. `AndroidManifest.xml` now sets `flutter_deeplinking_enabled` to `false`, so the Android sign-in link is handled only by `supabase_flutter` (an app without a router has no route to open it as). The merged debug manifest was checked; the link itself was not tried on a phone.
- Looked at and kept: `pre_restore` (the only copy of what a restore replaces; no screen shows it yet) and the `balances` / `closedAt` the server stamps on a closed day. Not removed: `Book.netProfit` is unused, but `expenseTotal` only feeds it and removing both edits the projection, so that is left for a separate change.
- No table, metadata key, document field, command payload, posting rule or stored value changed, so no data migration was needed and Reset all data needs no change (`AppController.page` is not business data). The one server change only drops a function.
- Full analyzer: no issues. Full Flutter suite: 79 tests passed (73 before, plus the new `test/app_start_test.dart`: launch routes, every page through `app.go`, a new page starting at the top, the side rail, the search box and the phone More sheet). The desktop, phone-Urdu and two Roznamcha preview images are byte-for-byte identical to those the code produced before the change. PostgreSQL integration (all five migrations): 38 checks passed, one of them new (`lookup_command` is gone). `flutter build apk --debug` and `flutter build windows --release` succeeded.
- Not run: a live Supabase project (the new migration is not applied there), the sign-in link on a real phone, and a by-eye run of the live app.

## Party statement: one khata, newest first — 11 November 2026

- The Party statement used to be three separate ledgers: what the party owes you, a "Trade payable" section and a "Refundable deposit" section. Each always had its own "Opening" row, even when empty, and the Statement button started from 2000-01-01. It is now one khata with one running balance, the same as the party screen (`ar:` net of `ap:`, as `partyBalances` does). The balance reads "Owes you …", "You owe …" or "Settled". The XLSX still gets the signed number. Debit is what makes the party owe you more or you owe less (a sale, an udhar wapsi), and Credit is the opposite (a receipt, udhar taken). For companies and Udhari parties this swaps the columns compared with the old "Trade payable" section. Deposits get their own section only when the party has any.
- In the Party statement, Cash book and Bank book there is one row per entry, not per posting, so a sale paid partly in cash or bank is one row with Debit = bill and Credit = paid. The description comes from the entry helpers (`entryTypeLabel`, `entryHeadline`, note).
- The Party statement, Cash book, Bank book and Gas stock list the newest entry first. There is at most one "Opening" row, at the bottom, and only when the balance brought forward is not 0. The party and account Statement buttons now start from the first entry instead of 2000-01-01. Display only: no accounting, server or stored-data change.
- Full analyzer: no issues. Full Flutter suite: 82 tests passed, including the new `test/statement_test.dart` (an Udhari party with an opening balance and an udhar wapsi gives exactly two rows, newest first, with the balance matching `partyBalances`; a part-paid sale is one row; the opening brought forward is the last row; the deposit section appears only for a party with deposits; Cash book and Gas stock are newest first). A sample Udhari statement PDF was rendered with `tool/render_pdf.ps1` and checked by eye.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Organizations — 11 November 2026

- One device can hold several separate organizations (see Organizations above). Each is its own SQLite file with its own `AppController`; `Organizations` (`lib/core/organizations.dart`) keeps the list in `organizations.json` and opens one at a time, and `KhataRoot` rebuilds the app for the one that is open. The switcher is on the side rail, in the phone More sheet and in Settings, where an organization can also be removed from the device after its name is typed.
- No migration was needed. The existing `khata-v1.sqlite` is the first organization and is neither moved nor rewritten; no table, metadata key, document field or command payload changed. No server change either: an account already is one dataset, and the app now refuses to link two organizations on a device to the same account. Each organization has its own stored sign-in; the first keeps the key it had.
- Reset all data erases the open organization only and keeps its name (a new organization's name is a queued change to the business profile, applied again after a reset). Backup files carry the business name, and restoring a backup of a differently named business asks first.
- Reset was checked organization by organization. No static or top-level state exists in `lib/`, so nothing in memory outlives a switch. The one thing stored outside an organization's database was Android's shared `exports/` cache folder: a reset in one organization deleted every organization's cached copies, and removing an organization left its cached backups behind. The copies are now per organization and are deleted on reset and on removal (`deleteExportCopies`; copies from before organizations belong to the first one).
- Full analyzer: no issues. Full Flutter suite: 97 tests passed (82 before). New: `test/organizations_test.dart` (a database from before organizations opening as the first one with the same balances and queue, separate books, the last one reopening, names, reset, a three-organization reset test in which the other two database files are byte-for-byte unchanged while the reset one loses every party, account, entry, saved day, batch, draft, recovery copy and sync cursor and keeps only device, language and name, then the same the other way round and a signed-out cloud-linked organization refusing by itself, the per-organization cached copies, rename, a lost or damaged list rebuilt while a `khata-v1.backup-….sqlite` copy is ignored, remove, one account per organization, shared language and cloud project, the business name in a backup), a sync test with two organizations on two accounts including a cloud reset that keeps the name, and a widget test that adds, opens and removes organizations through the screens. The English/Urdu layout walk now runs with two organizations and also opens the organizations list, the new-organization prompt, both remove confirmations and the other-backup question at all six sizes on Windows and Android: no overflow.
- Live data: a copy of the live database was opened the old way and through `Organizations` and compared: 191 records, 97 entries, 111 queued commands, every ledger balance, stock and cylinder count and the cash in hand of every day were identical (2026-11-01: Rs 2,292,170). The running debug app had already restarted on the new code and registered the live khata as its one organization, `main`.
- Not run: the PostgreSQL integration (no server or accounting change), the Windows release and Android builds, a real Supabase sign-in with two emails (the same-email refusal is covered by unit tests of `ownerUsedElsewhere`, not by a live sign-in), switching while signed in to a real project, and a by-eye walk through the new screens.

## Direct to Party — 11 November 2026

- New case: a customer pays the company the gas is bought from instead of paying us. Until now the only way to record it was a bank account named after the company (Bank Wasooli into it), which put a company's balance among the banks. The Wasooli / Sale tab now has **Direct to Party** with a company field (see Daily use). A sale or receipt carries `direct` (paisa) and `directParty` (party id) and posts `ap:<directParty>` debit / `ar:<party>` credit; no money account moves.
- Party flow, as checked first: a customer's balance is `ar:<party>`, a company's or Udhari party's is `ap:<party>`, and a party's khata, statement and running balance are the net of the two (`partyBalances`). Company ko payment and Udhar wapsi debit `ap:`; a purchase credits it. Direct to Party is the same debit of `ap:` with the customer's `ar:` on the other side instead of cash or a bank, so every balance screen and report that reads the postings needed no change. What listed entries by `party` did: the party khata, the Activity party filter, deleting a party and the statement text now also look at `directParty`.
- Roznamcha: counted as wasooli in A (its own column, shown only on a day that has any) and as an automatic row in B ("DIRECT TO PARTY"), like the automatic bank jama, so Safi Baqaya = cash in hand still holds. Hisab Mel, the printed Daily roznamcha, Sales register, Daily customer balances and the invoice/receipt PDF show it.
- Rules, the same on client and server: only on a sale or a customer's receipt (not a supplier refund), to an existing, not deleted party other than the customer; it counts as collection for allocations and for "Enter a collection amount"; a party that was paid directly has entries and cannot be deleted.
- Migration: none needed on the device. Entries without the fields post exactly as before; a read-only copy of the live database was checked and no stored entry or queued command uses either name. Server: `202611110001_direct_to_party.sql` replaces `canonical_document`, `validate_document`, `rebuild` and `apply_command` with `create or replace`. Apply it before using Direct to Party on a cloud-linked device: an older server drops the two fields and would keep the customer's balance unchanged.
- Not changed: existing entries. A company kept as a bank account stays as it is until its entries are corrected by hand (✏️ on a Bank Wasooli row: clear Bank Wasooli, type the amount in Direct to Party).
- Full analyzer: no issues. Full Flutter suite: 104 tests passed (97 before). New: `test/direct_to_party_test.dart` (ledger postings, validation, Roznamcha totals with Safi equal to cash, party delete, both khatas, statement, Cash book, printed roznamcha and receipt, the entry form including a new company, the same-name refusal and ✏️, the page and both party dialogs; it writes `build/preview-direct-to-party.png`, checked by eye). The English/Urdu layout walk now includes two direct entries, one to a long Urdu name: no overflow at the six sizes on Windows and Android.
- PostgreSQL integration (`dart run tool/backend_test.dart`): passed, with new checks that the server posts the same `ap:` / `ar:` amounts as the client for a receipt and for a sale paid in cash and directly, refuses a missing, same or refund party and a negative amount, refuses to delete a party that was paid directly, and drops the fields on other entry types.
- Not run: the Windows release and Android builds, a real Supabase project, and a by-eye run of the live app.

## Direct to Party in the bank list — 11 November 2026

- The separate Direct to Party box on the Wasooli / Sale tab is gone. The amount is typed in Bank Wasooli, and **Direct to Party** is the last choice of the Bank / Account list; choosing it puts a company field where the list was, with a bank icon to go back. Only the Wasooli / Sale tab has it.
- Same stored entry and accounting as before (`direct` / `directParty`), so no migration and no server change. The form has one Bank Wasooli amount, so an entry with both a bank amount and a direct amount (only possible from the general composer) opens there for correction (`rozEditable`). After saving, the next entry starts on the bank list again; the chosen bank is still kept.
- Full analyzer: no issues. Full Flutter suite: 104 tests passed, including the updated form test (Direct to Party listed after the banks, the company field replacing the list and the icon bringing it back, cash plus direct on one sale, ✏️ loading it back) and the English/Urdu layout walk at all six sizes on Windows and Android.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Bank name and several Bank Wasooli lines — 12 November 2026

- Wasooli / Sale now has a **+** beside Bank Wasooli for additional payments, each to a bank account or directly to a company. Extra lines can be removed; empty/zero lines are ignored. Direct to Party includes an optional company bank-name field with suggestions from previous payments. Drafts, corrections, fill-cash/fill-bank buttons, allocations and balance previews cover all lines; repeated new company names create one party.
- The company's khata and Party statement register direct money as **Bank payment**, with distinct bank names and **Customer: <name>**, and show only that company's combined amount. Customer khatas, payment details, Roznamcha A/B, Activity filters, daily reports and invoice/receipt exports read every payment line and show company bank names. Every direct company counts as having entries and cannot be deleted while a live entry references it.
- No device migration was needed: old documents read and post the same, and `bankLines`/`directBank` are new optional fields. One non-empty Bank Wasooli keeps the legacy fields; several save ordered `bankLines` and zero the legacy amounts. Bank names have no accounting effect, and direct lines remain in both A and B so Safi Baqaya still equals cash in hand.
- Server: new `supabase/migrations/202611110002_bank_lines.sql` replaces canonicalisation, validation, rebuild and the party-delete check; existing migrations are unchanged. Apply it before cloud-linked clients use the new fields. `tool/backend_test.dart` now checks client/server postings for two bank accounts plus a named direct line, canonicalisation, invalid lines and line-only party deletion.
- Verification: `dart format` on every changed Dart file; `flutter analyze` reported **No issues found!**; the full `flutter test --no-pub` suite passed **122 tests** (104 before, 18 new: `test/bank_lines_test.dart` plus `test/bank_lines_acceptance_test.dart`, an independent check of the agreed design covering line reading, postings, Roznamcha totals with Safi equal to cash, validation, the deleted-party guard, the form flow and the company khata). This includes `test/bank_lines_test.dart` and the English/Urdu layout walk at all six sizes on Windows and Android, with a long-name multi-line entry and two extra payment lines visible in the form: no layout problems found.
- PostgreSQL integration (`dart run tool/backend_test.dart`): passed, including the 15 new checks (server postings equal the client for two bank accounts plus a named direct line, `bankLines`/`directBank` kept on sales and receipts, every invalid-line rejection, an allocation above the collection, and deleting a party referenced only in a line refused). Screens were checked by eye on desktop and phone renders (form with three lines, A/B tables, the company khata).
- Not run: Windows/Android builds, a live Supabase deployment, physical phones or printers, and a by-eye run of the live app.

## Roznamcha balance counts both sides of the khata — 12 November 2026

- Why: لقمان احمد LPG was added as a customer with an **Opening payable** of Rs 888,029 (you owe him), which posts to `ap:`. The Parties page and his khata count both sides and showed "You will pay Rs 1,315,029", but the Roznamcha form read one side per role (`ar:` for a customer, `ap:` for a company or Udhari party), so choosing him on Wasooli / Sale showed "Baqaya: Rs 0 → Rs 0" (Dena 427,000 after his two bank receipts).
- The form's Baqaya line, the balance under the party field and in its suggestions, the Direct to Party company line, and the general composer's sale "Remaining balance" now use the new `Book.partyBalance` (`ar:` plus `ap:`, the balance the party's ledger already runs to), read for the field's role as before (Lena / Dena / Advance). When correcting an entry, the form takes out what the old entry put on either side.
- Display only: no stored data, posting, validation, sync or server change, so no migration was needed and Reset all data is unaffected. The Parties page keeps its separate receive / pay lines; the "Daily customer balances" report still shows the receivable side only.
- On a copy of the live database the fixed code reads لقمان احمد LPG as Dena 1,315,029, the Parties page figure. Six other customers entered with an opening payable and no receivable, which showed nothing before, now show what you owe them (Rs 51 to Rs 1,992). Every other party reads as before.
- Verification: `dart format` (no changes); `flutter analyze`: no issues; full `flutter test --no-pub`: **123 tests** passed (122 before, plus a new test in `test/daily_entry_test.dart`: a customer with an opening payable and a bank receipt in the suggestion, the field balance and the before → after line, a sale to him, a company with both sides paid directly, and Customer ko payment), including the English/Urdu layout walk at all six sizes on Windows and Android.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Company ko payment without "Customer (kis ke liye)" — 12 November 2026

- The user found the field unnecessary. It was a free-text note (`customerNote`) on Company ko payment with no accounting effect, and it read as if the payment touched that customer's khata (for money a customer paid a company, Direct to Party is the entry). It is removed from the Roznamcha form and from the general composer, where it was labelled "Customer annotation"; new payments no longer store it. Branch stays.
- The B: Kharcha row no longer prints "Customer: — · Branch: …". It shows "Branch: …" and, only for an older entry that has one, "Customer: …"; the details dialog still shows an older entry's note. The two Urdu labels the field used were removed.
- No migration: `customerNote` stays in both whitelists (`cleanDocumentData` and the server's `canonical_document`), so older documents keep it and the server needs no change. The live khata had one payment carrying the key, empty; the second organization had none. Nothing new is stored, so Reset all data is unaffected.
- Verification: `dart format` (no changes); `flutter analyze`: no issues; full `flutter test --no-pub`: **124 tests** passed (123 before, plus a new test in `test/daily_entry_test.dart`: Company ko payment shows no customer field, saves the branch and no `customerNote`, and moves the company and cash balances), with a new check in `test/roznamcha_page_test.dart` that the B row reads "Branch: Lahore" without "Customer: —", and the English/Urdu layout walk at all six sizes on Windows and Android.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.
