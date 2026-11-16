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
- **Money:** cash/bank/personal accounts, a Total bank card, statements (one per account, and a cash-and-bank statement printed like the Roznamcha), transfers and counted-balance reconciliation.
- **Stock:** gas FIFO lots, unknown costs, full/empty/held cylinders, filling, exchange, issue and return.
- **Reports:** PDF preview/printing (every report, statement and invoice printed in the Roznamcha sheet's design), real XLSX, UTF-8 CSV and copyable tables.
- **Settings:** organizations, business profile, complete Urdu RTL interface, cloud account, backups, conflict review and **Reset all data**.

Use **Ctrl+N** for a new entry and **Ctrl+Enter** to add it. Unsaved values in the Roznamcha form and in the general composer are kept while you move between pages, until the app or organization is closed; a composer entry opened again goes on the page's date, not the day it was begun. Roznamcha Save and Agla Din do not save a day again when it has not changed.

Daily entry uses six **Naya Entry** tabs of the original HTML, with the same fields in the same order: **Wasooli / Sale, Kharcha / Payment** (Cash kharcha, Bank account mein jama, Company ko payment, Customer ko payment, Udhar wapsi), **Bank se Cash Nikala, Less / Kami** (discount, or bank deposit into an account), **Office kharcha** and **Company se Wasooli**. The HTML's "Opening Theek Karo" tab is intentionally left out: it existed to patch damaged old data. Opening balances are entered once (a party's or account's when it is added, the cash in hand with **Opening cash**), and a wrong one is corrected with ✏️ like any other entry. Wasooli without cylinders is recorded as a receipt. Typing a new customer or company name creates it with the entry; existing names match regardless of case and spacing. The rate field keeps the last rate used. ✏️ loads a row back into its form; Update and 🗑️ ask for a reason, and the original stays in the audit trail. Purchases, stock, cylinders, credit notes and bank-to-bank transfers use the general composer.

Each entry stores the Roznamcha form it came from (`form`, display only), so a bank Less is shown as a Less row exactly as on the original page.

**Direct to Party** (Wasooli / Sale tab only) is for money a customer did not pay to you: you gave the customer the company's account and the customer paid the company the gas is bought from. Type the amount in **Bank Wasooli** and choose **Direct to Party**, the last choice of the Bank / Account list; a company field then takes the list's place (the bank icon beside it brings the list back). A new name creates the company. The optional **Kis bank mein? (company ka)** field records its bank name and suggests names used before. Use **+** beside Bank Wasooli to add more payments, each into one of your banks or directly to a company; remove an extra line with its minus button. Cash and all non-empty lines are saved in one entry, and ✏️ loads every line for correction. Direct money reduces the customer's debt and what you owe that company, with no cash or bank account movement. The company's khata and statement register it as **Bank payment**, showing its bank name(s), **Customer: <name>**, and only the amount paid to that company. Other entry views and printed reports show the bank name beside the company.

**Udhar wapsi** pays back money borrowed from an Udhari party. It is a payment with `supplierPayment: true` (it reduces what you owe the party, `ap:<party>`, exactly like Company ko payment) and `form: udharWapsi`; its party field suggests only Udhari parties, and a new name opens a new Udhari khata. **Cash kharcha** is an expense and is never linked to a party, so it never appears in a khata. An entry opened from a party's khata (the party's **Udhar wapsi** / **Company ko payment** button, or Aamad / Wasooli) keeps that party on every tab and after saving, the Kharcha tab starts on the type that pays that party, and a tab or type without a party shows "Yeh entry … ke khata mein nahi jayegi".

## Accounting conventions

Money is integer paisa; gas is integer grams; cylinder counts are integers. Invoice/purchase bills and purchase-share charges round to whole rupees; a share's few paisa of rounding stay in the share account (shown in the Purchase shares report), not in profit. Intermediate multiplications use arbitrary-precision arithmetic to avoid integer overflow.

Cylinder gas and extra/bulk KG both reduce gas stock using FIFO. New bulk entries default to **Share bulk at purchase cost**: the party receives part of your purchase and the shared portion is excluded from your sales revenue, sales cost and profit. **Share from** chooses where it comes from: one purchase (listed from 60 days before to 7 days after the entry, with the KG it has left), or oldest stock first (FIFO). A share from a chosen purchase is charged that purchase's own rate for its KG, rounded like the purchase bill (14,500 kg of a Rs 5,720 per 11.8 kg purchase is Rs 7,028,814); its KG come out of that purchase whatever the entry order, so they never become your stock, and the rest of the purchase keeps the rest of its bill exactly. Shares cannot take more KG than their purchase has, a purchase with shares cannot be deleted until they change, and correcting the purchase keeps the link (by its reference). A FIFO share is charged its FIFO cost in whole rupees. Mixed entries consume cylinders first at their normal selling rate, then price the shared bulk from the remaining FIFO stock. A share is priced from the stock that covers it in FIFO order, including a purchase entered later in the day or on a later date (a share typed before its purchase); a share that no stock of known cost covers yet is refused until the purchase is entered. Turning sharing off records an ordinary bulk sale. Old entries retain their recorded prices until explicitly corrected. Full-invoice physical returns restore both quantities and their original cost; bulk KG never changes cylinder custody counts. Unknown stock costs and historical summaries still make ordinary sales profit provisional.

The shared amount is fixed when posted. Later purchase-cost corrections do not silently change what a party owes: a **Purchase shares** report and a warning show any cost-recovery difference, which can be settled by an audited correction. Actual cash, bank and direct collections still settle the party's khata normally. Roznamcha shows purchase sharing separately from Calculated Bill, and Reports has a separate Purchase shares register.

Roznamcha totals follow the original `computeDay()`: A (Kul Aamad) = opening + cash wasooli + bank wasooli + bank se nikali; B = cash kharcha + bank wasooli (auto bank jama) + cash deposited to bank; Safi Baqaya = A − B. Safi Baqaya always equals the ledger's cash in hand. A bank Less reduces the customer and increases the account without entering A or B. Direct to Party (not on the original page) is treated like a bank wasooli: each direct line on a sale or receipt posts `ap:<line party>` debit / `ar:<party>` credit, is counted as wasooli in A and as an automatic payment to that company in B, so Safi Baqaya is unchanged. Collections include cash and every bank/direct line; bank names are descriptive and have no accounting effect. A single Bank Wasooli keeps the legacy `bank`/`bankAccount` or `direct`/`directParty`/`directBank` fields; several use ordered `bankLines`. It settles the customer's bills like any other collection. The opening is always the previous day's closing and cannot be typed over. The opening cash is entered once, as an entry at the start of its day; it and the opening balances of parties and accounts are shown as "Opening balance" rows in the A table, where ✏️ corrects and 🗑️ deletes them with a reason. A counted-cash difference (Cash reconciliation) is shown as an "Adjustment" row.

Customer credit, supplier advances, lending, noncash discounts and cash/bank transfers have separate accounting effects. Refundable cylinder deposits are liabilities, not revenue; while a party holds one, its details offer **Refund deposit**, and a refund larger than the deposit is refused. Changing a party classification or archiving a record does not change its financial history. A party with no entries can be deleted with the bin icon beside Edit in its details; voided entries do not count, but an opening balance does until it is deleted. Deleting sets `deleted: true` on the party (the khata never erases rows, so it syncs like any other change): the party disappears from every list, including Archived, its name can be used again, and it cannot come back or take new entries.

Stock shortages are allowed and shown explicitly. Gas sold, shared or lost before its stock was entered (the day's sales first, the supplier's purchase later) waits for the next stock: that stock covers the waiting gas first, oldest first, at its own cost, before anything else can take it. The cost belongs to the waiting entry itself (its FIFO allocation, and its postings under its id, dated the day the stock came so a closed day never changes), so the sale is fully costed and the Profit report counts the cost with the sale. Until stock arrives the gas shows as uncosted and profit as incomplete. A physical return of an invoice whose gas is still waiting cancels that wait. Gas covered by stock of unknown cost stays uncosted until that cost is entered. Gas filling changes full/empty counts, not total gas KG, so gas is not consumed twice.

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

Backups contain a consistent versioned snapshot and queued commands with a SHA-256 integrity checksum. They exclude authentication tokens. Validate backups before restoring; a backup restored on a connected device recovers missing pending commands and does not overwrite newer server records. The checksum detects accidental corruption; it is not encryption or proof of authenticity. A backup is of the open organization only, and its file name carries the business name (`ZubairKhata_<name>_Backup_<date>.json`). Restoring a backup whose business name differs from the open organization's asks first, because a restore on a device without a cloud account replaces the whole khata. A restore (and **Reconnect to cloud**) first keeps a backup of what it replaces; Settings then offers **Export the backup from before the last restore**, and restoring that file undoes the restore.

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

## Second cleanup round: the audit's remaining findings — 12 November 2026

- **Version control.** The project is now a git repository. Commit `bbd0181` is the code as it stood this morning; this round's changes are left uncommitted for review. `core.autocrlf` is off so files with CRLF or a BOM are stored byte for byte, and `.claude/settings.local.json` is ignored.
- **The client refuses what the server refuses.** Before, five kinds of entry were accepted on the device and would only have been rejected on sync: a negative cylinder quantity, a date outside 2000–2100, an entry naming a party that does not exist, a credit note whose cylinders or rate differ from its invoice (even when the bill rounds to the same rupees), and `allocations` that are not a map. A direct payment to a deleted party was already refused through the bank lines. In "Loss / correction" the composer no longer sends the hidden quantity field. Cases are in `test/validation_parity_test.dart`. All 145 live entries of both organizations pass the new rules, and a full backup and restore of each gives the same balances (checked on copies).
- **Speed.** Receipts are settled per party from the oldest unpaid claim, used-up gas lots are skipped, and the Roznamcha reuses the full ledger when nothing is dated after the chosen day. Results are identical: `test/allocation_equivalence_test.dart` compares with the original algorithm on 300 random khatas. On a synthetic local khata of about 70 entries a day, a save at 20,000 entries took 19.9 s and its redraw 49 s; now 0.9 s and 0.3 s. At 60,000 entries, which did not finish before, a save takes about 3.3 s, most of it reading every queued change again.
- **Drafts.** Unsaved composer entries are kept in memory like the Roznamcha form's, only for new entries and only for the same party, and a reopened one goes on the page's date. The SQLite `drafts` table is no longer used; older files keep it and Reset all data empties it. Neither live organization had a draft.
- **Saved days.** Roznamcha Save and Agla Din no longer store an unchanged day again. Khata Saaf is stored on its snapshot (`batchAt`), so it syncs to other devices; the older `batch:<date>` metadata is still read.
- **Deposits.** A party holding a refundable deposit has **Refund deposit** in its details; a refund larger than the deposit is refused.
- **Undoing a restore.** Settings offers **Export the backup from before the last restore** when there is one; restoring that file undoes the restore.
- **Local devices.** The pending-sync count in the top bar and in Settings is shown only for a khata linked to a cloud account.
- Removed the unused `Book.netProfit` and the `expenseTotal` that only fed it.
- No migration: no table, metadata key, document field, command payload or posting changed for existing data, and there is no server change. Reset all data also clears the new in-memory composer drafts.
- Verification: `flutter analyze`: no issues. Full `flutter test --no-pub`: 138 tests passed (124 before, plus 14 new in `validation_parity_test`, `allocation_equivalence_test`, `local_device_test`, `composer_draft_test`, `snapshot_test`, `deposit_refund_test` and `pre_restore_test`), including the English/Urdu layout walk at six sizes, now with the Refund deposit button and the restore export. PostgreSQL integration (all migrations): 57 checks passed. `flutter build windows --release` succeeded.
- Not run: the Android build, a live Supabase project, and a by-eye run of the live app.

## "Customer (kis ke liye)" back on Company ko payment — 12 November 2026

- Earlier today the field was removed at the user's request. The user then asked for it back because they need it. It is restored exactly as it was, with each line checked byte for byte against the removed text. The Roznamcha form's Company ko payment asks "Customer (kis ke liye)" beside Branch and saves it as `customerNote`, and Edit loads it back. The general composer's payment has "Customer annotation" again. The B: Kharcha row reads "Customer: … · Branch: …" ("—" when empty), and the two Urdu labels are back. Keep the field.
- The removal went live with the running debug app's hot restart at 10:52. Six Company ko payments saved on the live khata between 11:06 and 12:11 therefore have no customer. All are dated 2 November: four to JU Gas and two to سانگلہ پیٹرو گیس. Correcting an entry adds the customer. The app's read-only VM service shows it still runs the 10:52 code, so the field returns there only after a full restart.
- No migration: `customerNote` never left either whitelist (`cleanDocumentData` and the server's `canonical_document`), and an entry without it reads as empty. There is no server change, and Reset all data is unaffected.
- Verification: `dart format`: no changes, after the formatter wrapped one long test name. `flutter analyze`: no issues. Full `flutter test --no-pub`: **138 tests** passed, the same count as before, because the test that checked the field was gone now checks that it is back. In `test/daily_entry_test.dart` the field shows, saves `customerNote` with the branch, moves only the company's khata and the cash, and Edit loads both back. `test/roznamcha_page_test.dart` checks that the B row reads "Customer: — · Branch: Lahore". The English/Urdu layout walk passed at all six sizes on Windows and Android.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Purchases are bought from companies — 12 November 2026

- The purchase form (Stock → Purchase) showed every party, customers included. Its party list now starts with companies only (parties marked Supplier), with a "Show all parties" switch for a supplier that was never marked as a company, and a "No company found" line when the search matches none. Other forms keep the full list (`pickRecord(companiesOnly:)` in `lib/ui/components.dart`).
- Saving a purchase from a party not yet marked as a company marks it as one in the same command, as the Roznamcha form already does for its party fields. Other flags (customer, Udhari) are kept. A party that is already a company is not changed.
- A company's page has a **Purchase** button that opens the purchase form with the company filled in.
- No accounting change: a purchase posts to `ap:<party>` exactly as before, and no stored entry is changed, so there is no migration and no server change. Reset all data is unaffected (no new stored data).
- Verification: `flutter analyze`: no issues. Full `flutter test --no-pub`: **140 tests** passed, in a worktree and again in the main tree after the merge. The new `test/purchase_party_test.dart` checks that the list shows only companies, "Show all parties" brings back customers, saving marks the party as a company and keeps it a customer, a purchase from an existing company leaves the party unchanged, and the Purchase button appears only on a company's page and fills the company in. The English/Urdu layout walk passed at all six sizes.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app. The picker dialog itself is not in the layout walk; its two buttons sit in the dialog's action bar, which wraps.

## Daily roznamcha PDF: overview section — 12 November 2026

- The printed Daily roznamcha (Roznamcha → Print / PDF, and Reports) started straight with the A rows, so the page's summary was missing. Each day now opens with an **Overview** section built from the same numbers as the page: Opening (sabiqa), with "+ Bank se Nikali … = …" and the earlier-closing note when they apply; A, B and Safi Baqaya with the breakdowns under the cards (cash / bank / direct / nikali, kharcha / bank jama / bank se diye, Bank (aaj)); Calculated Bill (cylinder / bulk); Total Gas Dispatch by cylinder size; and the Gas (KG) line, left out until gas stock has been entered, as on the page. Weights stay in the description, so the Amount column holds rupees only. The A and B totals further down are unchanged.
- The Overview, A and B heading rows are shaded in the PDF and in the on-screen report table (`Report.sections`). The same rows reach the XLSX and CSV.
- A day's gas closing is worked back from the report's end date with each day's gas in and out, so a long range does not replay the book once per day. The test checks every day against `app.bookAt(date).gasGrams`.
- Report output only: nothing new is stored, no entry changes, no server change, and Reset all data is unaffected.
- Verification: `flutter analyze`: no issues. Full `flutter test --no-pub`: **143 tests** passed (140 plus the 3 in the new `test/roznamcha_report_test.dart`), in a worktree and again in the main tree after the merge. The new tests check a three-day range: the order of the overview rows; each amount against the page's `RoznamchaDay` and the totals below it; the exact text for nikali, bank kharcha, a cash-count adjustment and a gas leak; the gas line across days; that one day printed alone matches the same day inside the range; that there is no gas line before any gas stock; and that English and Urdu PDFs build. `build/preview-roznamcha-english.pdf` and `-urdu.pdf` were turned into PNGs with `tool/render_pdf.ps1` and checked by eye.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Parties: Pending balances PDF — 12 November 2026

- The Parties page has a **Pending balances** button (بقایا جات). It prints the parties the list is showing, with the chosen filter chip (All, Customers, Companies, Udhari, You will receive, You will pay), the Archived switch and the top-bar search, in the same order (newest first). When nothing is pending the button says "No pending balances" instead of opening an empty PDF. The page and the PDF use one list (`visibleParties` in `lib/ui/pages.dart`).
- The first version was the ordinary full-width table with separate receive and pay columns; the user asked for the look of the business's paper sheet instead. The PDF now has **two grids side by side on each page**, each with a narrow number column, the name and one **Baqaya jaat** column: what you will receive is written plainly and what you will pay with a "+". A page holds 32 rows a grid (64 parties, as on the sheet); rows fill the first grid, then the second, and the last page shares its rows evenly. In Urdu the first grid and the number column are on the right. The subtitle gives the date, the filter and "+ = You will pay", and one line under the grids gives the number of parties and both totals.
- The balance is the party's khata balance (`Book.partyBalance`, both sides netted), so a customer with an old opening payable shows one figure here, not the two gross figures of the party list. A party whose two sides cancel out is left out with the settled ones.
- `Report.grids` (with `Report.flex` for the column widths) selects this layout in `ReportExporter.pdf()`; every other report is drawn as before. Rows are one line of a fixed height: `UrduPdfRenderer.line()` shapes a name without the padding of the ordinary cells, and a name too long for its cell is scaled down, not wrapped.
- Report output only: nothing new is stored, no entry changes, no server change, and Reset all data is unaffected. Four new Urdu labels: Pending balances, No pending balances, No., Baqaya jaat.
- Verification: `flutter analyze`: no issues. Full `flutter test --no-pub`: **146 tests** passed, in a worktree and again in the main tree after the merge. `test/pending_report_test.dart` checks every filter chip, the Archived switch and the search; the order, numbering, the "+" on amounts to pay, the amounts against `Book.partyBalance`, a party with both sides, and the totals line; the Urdu headings; the button and its "No pending balances" message; and that 40 parties make one page and 65 make two, in English and Urdu. The English/Urdu layout walk passed at all six sizes. `build/preview-pending-english.pdf`, `-urdu.pdf` and `-long.pdf` were turned into PNGs with `tool/render_pdf.ps1` and checked by eye against the paper sheet: Urdu names are not clipped, and a full page holds 64 rows with the totals line below.
- Names align right, like the amounts beside them, in English as in Urdu (the user asked for it after seeing the first two-grid print). Only the grid PDF changed. `flutter analyze`: no issues; `test/pending_report_test.dart`: 3 tests passed; the English and Urdu previews were rendered again and checked by eye. The full suite was not re-run for this one-line alignment change.
- Not run: the PostgreSQL integration (no server change), the Windows/Android builds, and a by-eye run of the live app.

## Bulk gas consumes stock — 12 November 2026

- Bulk KG now reduces FIFO gas stock along with cylinder KG. One 11.8 KG cylinder plus 1.18 bulk KG consumes 12.98 KG exactly once. Existing source entries recalculate with this rule; cylinder custody counts still use cylinders alone. Bills, collections and party balances retain their previous behavior.
- Physical full-invoice returns restore cylinder and bulk KG and their original FIFO cost. Financial credit notes without a physical return do not add stock. Corrections and voids replay the same quantities. Missing purchase costs and shortages remain provisional.
- Roznamcha dispatch, the daily gas-stock equation, Sales register KG and Gas stock reports include bulk. Cylinder and bulk billing are still shown separately; profit uses both revenues against the full gas cost. English and Urdu entry labels no longer describe bulk as billing-only.
- `202611120001_bulk_stock.sql` updates the server projection and rebuilds existing owners' derived caches under their sync locks. It changes no source documents, field whitelists or sync sequence. Apply it to a cloud backend before syncing updated clients. Local-device books need no data rewrite.
- Verification: `flutter analyze --no-pub`: no issues. Full `flutter test --no-pub`: **152 tests passed**, including six new bulk-stock tests, existing billing/party/payment tests, report exports, and English/Urdu layout checks at all six sizes for Windows and Android. `dart run tool/backend_test.dart`: passed, including an upgrade from the previous cylinder-only projection with existing data, mixed and bulk-only FIFO consumption, and both kinds of physical return. The isolated PostgreSQL test server was stopped afterward.
- Not run: Windows/Android builds, deployment of the migration to a live Supabase backend, or restarting the live app.

## Shared purchases at FIFO cost — 12 November 2026

- New bulk inputs in both entry forms default to **Share bulk at purchase cost**. The exact FIFO cost becomes the amount recoverable from the other party, with no sales revenue or COGS for the shared portion. A pure share needs no selling rate. Mixed entries keep their cylinder sale and consume cylinder stock first, then quote bulk from the remaining lots. Insufficient or uncosted dated stock is refused. Ordinary bulk sales remain available by turning sharing off; existing posted entries retain their mode and recorded prices until corrected.
- Price is recalculated when posting against the actual document date, time and id, excluding the original for a correction. Quoting never changes stock. Exact paisa, including one-paisa and known zero-cost shares, avoids a rounding margin. Collections, partial payments and advances use the party's normal khata. Daily selling-rate changes skip pure shares and preserve the shared amount on mixed entries.
- Roznamcha shows **Purchase shares** separately from Calculated Bill and includes sharing in physical dispatch. The Sales register excludes pure shares and counts only the own-sale portion of mixed entries. A separate Purchase shares report shows KG, recorded charge, FIFO cost and any recovery difference. Receipts and party details label the shared amount at cost. Full physical returns reverse each original cost category and preserve payments; corrections, voids, reset and backup restore retain the same accounting rules.
- Later purchase-cost corrections preserve historical party debt. A recovery-account difference raises a warning and appears in the sharing report; an audited share correction recalculates the agreed amount. New changed share documents are checked against their FIFO cost on both the client and server, so a stale cloud quote is rejected rather than posted with a margin.
- `202611120002_purchase_sharing.sql` keeps `bulkAtCost` and `bulkCost` on sales and credit notes, adds the FIFO allocation's cost category, updates projection/validation and rebuilds derived caches under sync locks. Apply it after the bulk-stock migration and before syncing clients using sharing. No migration was deployed to a live backend.
- Verification: `flutter analyze --no-pub`: no issues. Full `flutter test --no-pub`: **167 tests passed**, including fourteen new sharing tests and a new validation-parity case. The Windows/Android layout walk now includes a purchase-share entry, summary, details and correction form at all six sizes in English and Urdu. `dart run tool/backend_test.dart`: passed, including pure/mixed client-server posting parity, stale/unknown-cost rejection, typed-field validation, backdated cost corrections, physical returns and reset. The isolated test server was stopped.
- Not run: native Windows/Android builds, live app restart, or live cloud deployment.

## Sales before their purchase; review of purchase sharing — 13 November 2026

- Review of the 12 November bulk-stock and purchase-sharing work (also independently reviewed by a second model): the sharing arithmetic and collections were right, but a share made every projection throw when it had no stock at its position. On a copy of the live khata that refused converting صادق گیس پلانٹ's 14,500 kg bulk entry (entered before the JU Gas purchase) into a share, and refused even a one-cylinder sale back-dated to 1 November once any share existed, both with "Enter dated stock and purchase cost before sharing gas". A stored share losing its stock (a voided purchase, a pulled change while a local entry waits) could also make the book unbuildable.
- Sales entered before their purchase (the business's daily pattern) now wait for stock instead of staying "uncosted" for good: the next stock covers waiting gas first, oldest first, at its own cost, recorded as the waiting entry's own FIFO allocation and postings (dated the stock-in day, so closed days never change). This replaces the single provisional `cogs:shortage` posting on the purchase. On the live copy all 2 November sales, the 1 November 440 kg stock loss and the bulk entry are now costed from the JU purchase; only the 3 November sales, which have no purchase yet, stay uncosted. The purchase's Rs 14,394,525 is conserved exactly; the 440 kg loss now shows as stock loss (Rs 213,288.13) instead of cost of gas sold. Party and money balances are unchanged.
- Shares: the projection never throws; a share without stock waits like any sale. Changed shares are verified after the whole replay, so a share typed before its purchase is priced from it once the purchase exists (the bulk entry above quotes Rs 7,028,813.35, 65 paisa under its current Rs 7,028,814). The quote is the projection itself, with a fast path from the current lots for a new entry placed last. Daily rate changes and snapshot restores price their re-created shares from one projection. A physical return of an invoice whose gas still waits cancels the wait; a financial-only credit note of a share moves the shared cost to cost of gas sold. The cost-difference warning starts at Rs 1 (paisa drift from proportional rounding stays in the Purchase shares report). The Roznamcha share switch returns to "on" after every save. The client credit-note check compares raw `bulkCost` as the server does. The Profit and FIFO allocations reports read everything known for the entries in their range.
- `202611130001_fifo_backorders.sql` mirrors all of this on the server (`stock_in`, `rebuild`, post-replay share verification) and rebuilds existing owners' caches under their sync locks; documents and sync sequences are unchanged. No source data needed rewriting on the device: the change is in the projection.
- Verification: `flutter analyze --no-pub`: no issues. Full `flutter test --no-pub`: **184 tests passed**, including 15 new backorder tests (`test/fifo_backorder_test.dart`), a share-switch widget test, and updated FIFO/sharing tests whose old expectations encoded the replaced rules. `dart run tool/backend_test.dart`: passed (93 checks) in an isolated copy, including 7 new posting-by-posting client/server parity checks (waiting sales and stock loss, a share priced from a later purchase, a back-entered earlier sale, a voided purchase under a share, a return of waiting gas, a forgiven share); re-run in the workspace after merging. The live database was only read, through copies.
- Not run: native Windows/Android builds, a restart of the running live app, or deployment of either migration to a cloud backend.

## Purchase shares: whole rupees and a chosen purchase — 13 November 2026

- Asked by the user after the review above: share charges round to whole rupees like every bill, and a share can name the purchase it comes from ("Share from" in the daily form and the composer; oldest stock first stays the default).
- A share from a chosen purchase (`sharePurchase`, the purchase's reference) is charged that purchase's rate for its KG, rounded like the purchase bill, and its KG come out of that purchase whatever the entry order, so they never become our stock. Capacity is checked (a share or a purchase correction cannot leave the purchase short), a purchase with shares cannot be deleted until they change, a correction keeps the link, and a physical return gives the KG back to us. The entry, its details, the Roznamcha row, the invoice and the Purchase shares report (new "Share from" column) name the purchase. The few paisa between a share's charge and its exact cost stay in the share account; the warning now fires only when one share differs by a rupee or more.
- On a copy of the live khata, choosing the JU Gas purchase for صادق گیس پلانٹ's 14,500 kg bulk charges Rs 7,028,814.00, its current bill, so no party balance changes; the 14,500 kg leave the JU purchase at Rs 7,028,813.35 of its bill and the 65 paisa stay out of profit. The live database was only read, through copies; the entry itself was not changed.
- `202611130002_share_purchase.sql` mirrors it on the server (whitelist, validation, reservation in `rebuild`, charge and capacity checks) and rebuilds existing owners' caches. No stored document needed rewriting: no share existed in live data, and FIFO shares already posted keep their recorded charge (only shares saved from now on must be in whole rupees).
- Verification: `flutter analyze --no-pub`: no issues. Full `flutter test --no-pub`: **196 tests passed**, including 11 new chosen-purchase tests (`test/share_purchase_test.dart`, with a widget test that picks the purchase and saves), a validation-parity case, the layout walk now correcting a chosen share in both entry forms at all six sizes in English and Urdu, and earlier sharing tests updated to whole-rupee charges. `dart run tool/backend_test.dart`: passed (102 checks) in an isolated copy, including 9 new checks (a share before its chosen purchase charged Rs 7,028,814, exact-paisa / too-many-KG / unknown-purchase refusals, posting parity, a purchase correction that keeps the link and one that is refused, the deletion block, and a return); re-run in the workspace after merging.
- Not run: native Windows/Android builds, a restart of the running live app, or deployment to a cloud backend.

## Cylinder full/empty counts hidden — 13 November 2026

- Asked by the user: the Stock page showed Full −19 / −94 / −452 and Empty 19 / 94 / 452 with a "Check cylinder counts" warning, although gas had been bought. The business buys and sells gas by KG and never enters cylinder fills, so every sale lowered "Full" and every returned empty raised "Empty" with nothing to balance them. The counts meant nothing and would always look wrong.
- The Stock page no longer shows Full/Empty counts or the Cylinder movement button. Its Cylinders panel appears only when some customer still holds our cylinders, and then shows just that. `Book.warnings` no longer raises "Check cylinder counts". The Cylinder custody report lists only customer-held cylinders. Gas stock (KG), purchase lots, cylinders sold per size, bills and the sale form are unchanged. `Book.full`/`empty` are still projected, and existing cylinder movement entries still post and display, so nothing stored changed and it can be brought back. Server and client are unaffected (display only).
- Verification: `flutter analyze --no-pub`: no issues. Full `flutter test --no-pub`: **196 tests passed**, including the layout walk at all six sizes in English and Urdu. The live database was only read, through copies.
- Not run: native Windows/Android builds, the backend test (no accounting change), or a restart of the running live app.

## Roznamcha PDF like the old printed sheet — 13 November 2026

- Asked by the user, with a photo of a page printed from the old single-page app ("Roznamcha History — Roznamcha History (Date wise)", 25-10-2026): the Roznamcha PDF must have the same details, format and arrangement.
- Print / PDF on the Roznamcha page, Day history's Preview PDF and Reports → Daily roznamcha now print that sheet (`lib/features/reports/roznamcha_sheet.dart`), each day on its own page. Top to bottom:
  - the title and print stamp;
  - the day, when it was saved (only while the printout is that saved copy) and its Safi Baqaya;
  - Opening, A: Kul Aamad, B: Kharcha + Bank Jama and Safi Baqaya;
  - A: Aamad / Wasooli (#, Parchi, Customer / Party, 11.8K, 15K, 45K, Rate, Bill, Cash, Bank / Account, Kul Wasooli, then its Total row);
  - Bank Nikali / Less, when the day has any;
  - B: Kharcha + Bank Jama: the day's own entries in order, then one Bank Jama per bank wasooli.
- It prints black on white in Helvetica (Arial's metrics). Columns are as wide as their content, and a wide day is shrunk to fit (not below 85%), as the old browser print was.
- Added only on days that need them: a Direct to Party column and rows, opening balance rows, bulk or share KG and the note under the customer, the bank-paid kharcha total, and the day's purchases, stock and cylinder entries. Urdu prints the same sheet mirrored.
- Urdu in names and notes is shaped by Flutter, with the Latin part in Arial. Names, and numbers with "-", are isolated so mixed Urdu/English text keeps its order.
- The old generic PDF's Calculated Bill, gas dispatch, gas stock and purchase-share lines are no longer printed; they stay on the page. Excel/CSV and the Reports table are unchanged, and nothing stored changed.
- Verification: `flutter analyze --no-pub`: no issues. Full `flutter test --no-pub`: **202 tests passed**, including six new ones in `test/roznamcha_sheet_test.dart`:
  - the photographed day rebuilt cell by cell;
  - every extra kind of entry;
  - the saved-copy rule;
  - ranges and empty days;
  - Urdu labels;
  - English and Urdu PDFs.
- The PDFs were rendered to PNG and compared with the photo; `build/preview-roznamcha-reference.pdf` is the photographed day.
- On a copy of the live khata, 1–3 November printed with each day's Safi Baqaya equal to the ledger's cash in hand. 2 November (34 Aamad and 34 Kharcha rows) fits on two pages, one line per entry. The live database was only read, through that copy.
- Not run: native Windows/Android builds, the backend test (no accounting change), or a restart of the running live app.

## Compact PDF; original Roznamcha toggle restored — 13 November 2026

- Compact applies only to Roznamcha PDF previews. The page's original Entry wise / Customer wise toggle, subtotal rows and individual entries are fully restored, with no shared PDF setting.
- The PDF preview's previous debug switch is removed. Its Compact switch combines repeated entries per party and day, retains the customer/party name once, and shows only the combined amount in Bank and Direct cells, without bank/account/destination names underneath. For the reference's three bank receipts, 10,000 + 39,000 + 18,000 becomes **67,000**. Long text ends in an ellipsis; amounts retain their full width. Switching Compact off restores PDF details.
- Saved history and date ranges support the same PDF option. Stored entries, balances, Safi Baqaya, the page and Excel/CSV rows are unchanged.
- Verification: the compact, Roznamcha page, sheet, report and translation tests passed (**17 tests**); static analysis reported no issues. The restored page toggle was checked at desktop and phone sizes down to 360×640 in both languages. Compact English and Urdu PDFs were rendered and checked visually, including full large amounts and the absence of bank/account labels in collection amount cells.
- Not run: the full suite, native Windows/Android builds, the backend test (no accounting change), or a restart of the running live app.

## Roznamcha PDF: Total Gas Dispatch and Calculated Bill — 14 November 2026

- Asked by the user: the Roznamcha PDF's summary row now has two more boxes after Opening, A: Kul Aamad, B: Kharcha + Bank Jama and Safi Baqaya: **Total Gas Dispatch (KG)** (cylinder counts per size and bulk KG beside it) and **Calculated Bill** (Cylinder and Bulk beside it). This reverses the 13 November note that these two were no longer printed.
- Both show exactly the Roznamcha page cards' values (`RoznamchaDay.dispatchGrams` and `bill`): the bill leaves out purchase shares (still in A's Bill total), and the dispatch counts their KG. A day with no sales prints them at 0.
- Every Roznamcha PDF has them: Print / PDF, Day history, Reports → Daily roznamcha, normal and Compact, English and Urdu. In an Urdu sheet with Urdu "Bulk" in the gas box, each Latin part is isolated so "151.7 kg" stays beside its own label. Excel/CSV, the page and stored data are unchanged.
- Verification: `flutter analyze` on the changed files: no issues. Full `flutter test`: **209 tests passed**, including the 25-10-2026 reference day (both boxes at 0), the day with every extra kind of entry (73.6 kg, Rs 28,941 = 26,975 + 1,966), a new purchase-share case and the Urdu isolation. English, Urdu and reference PDFs were rendered to PNG and checked by eye.
- On a scratchpad copy of the live khata (read only), both days (12 and 13 November) printed the page's own dispatch and bill, with Safi Baqaya equal to cash in hand; 13 November prints 15,554 kg and Rs 7,917,671.
- Not run: native Windows/Android builds, the backend test (no accounting change), or a restart of the running live app, which shows the new PDF only after it is restarted.

## Money page: Total bank card and cash-and-bank statement — 14 November 2026

- Asked by the user: a **Total bank** card right after Cash on the Money page, with every bank account added together, and a **Statement** button whose PDF gives each account, Cash, Total bank and Total, in the Roznamcha's design.
- The card (`Book.bankMoney`) is for the end of the top bar's day and counts archived accounts too, so an earlier day still adds up. It shows how many banks are listed, and tapping it opens the statement too.
- The statement (`moneyReport`) is one Roznamcha-style sheet printed by the same renderer: title and print stamp, the day with Total (Cash + Bank), a summary row Cash | Total bank | Total (Cash + Bank) with openings, then each account's Opening, Money in, Money out and Closing, with Cash, Total bank and Total (Cash + Bank) rows under it. An archived account is listed only on a day it held or moved money. Urdu prints the same sheet mirrored. Nothing stored changed.
- Verification: `flutter analyze`: no issues. Full `flutter test`: **212 tests passed**, including three new tests in `test/money_page_test.dart` (card order and totals, the statement's figures on three days with an archived account, English and Urdu PDFs on one page) and the layout test at all six sizes in both languages. Both PDFs were rendered to PNG and checked by eye.
- Not run: native Windows/Android builds, the backend test (no accounting change), or a restart of the running live app, which shows the new card and button only after it is reloaded.

## Every report PDF in the Roznamcha design — 14 November 2026

- Asked by the user (with a screenshot of the Party statement still in the old green-header table): every report printed like the Roznamcha. Every PDF is now a Roznamcha-style sheet: "Zubair Traders — <report>" and the print stamp, a bold heading (dates, party or account, the key figure), a summary row of figures like the Roznamcha's cards, then tables with capital heads, a `#` column, figures on the right with '—' for nothing, dates as dd-mm-yyyy and a bold Total row.
- Each report has its own summary: Party statement (Opening, Debit, Credit, Balance, Refundable deposit and cylinders held when there are any, with the khata and deposits as separate tables and the balance brought forward unnumbered), Cash/Bank book (Opening, Money in, Money out, Closing), the registers, Customer balances/Udhari, Overdue, Gas stock (Opening, Gas in, Gas out, Closing), FIFO, Profit (its six figures), Cylinder custody, Deposit liabilities and the Audit trail. Daily customer balances prints one table a day; days and parties with no figure, and parties whose balances are all 0 in the balance lists, are left out of the print. The invoice/receipt prints its items with the bill, payments and outstanding as the table's foot. Any other report goes through the same design automatically.
- Pending balances keeps the paper sheet's two grids a page, now drawn in the same black-and-white style (no green fill, grey rules, capital heads, title and print stamp).
- A wide table that does not fit even at the smallest zoom lets its headings take two lines. In Urdu the sheets are mirrored; summary boxes with Urdu keep each part whole.
- Nothing stored changed. The table, Excel and CSV rows are unchanged, except that Overdue and FIFO allocations gained a Total row and Cylinder custody's counts are numbers in Excel.
- Verification: `flutter analyze`: no issues. Full `flutter test`: **217 tests passed**, including the new `test/report_sheet_test.dart` (the party statement sheet cell by cell, every report's sheet in both languages with rows that fill their tables, the summaries' figures, the invoice, the automatic sheet, and every report printed to PDF in English and Urdu). English and Urdu previews were rendered to PNG and checked by eye. On a scratchpad copy of the live khata (read only), Imtiaz's statement printed 137,975 / 137,970 / Owes you 5 as on screen; the cash book, sales register and customer balances also printed.
- Not run: native Windows/Android builds, the backend test (no accounting change), or a restart of the running live app, which shows the new PDFs only after it is restarted.

## Parties page: party count and totals in the heading — 14 November 2026

- Asked by the user: the total receivable and payable of all parties beside the "Parties" heading, and how many parties there are, without numbering any party.
- Beside "Parties" a small badge gives the number of listed parties. On the far side of the same line are **You will receive** and **You will pay** in all (payable in red), the sums of the rows' own figures (`partyOwed`). All three follow the filter chips, the Archived switch and the search, like the Pending balances PDF, so under "All" they are for every party and under "Customers" for the customers only. Rows are not numbered. Nothing stored changed.
- `PageHeading` gained optional `count` and `beside`; other pages are unchanged.
- Verification: `flutter analyze`: no issues. Full `flutter test`: **218 tests passed**, including a new test in `test/entry_facts_test.dart` (count and totals beside the list and on a 360x640 phone, and after a filter) and the layout test at all six sizes in both languages. English and Urdu previews at desktop and phone size were rendered to PNG and checked by eye.
- Not run: native Windows/Android builds, the backend test (no accounting change), or a restart of the running live app, which shows the heading only after it is reloaded.

## Pending balances: only the day's changes, with details — 14 November 2026

- Asked by the user: besides the complete Pending balances sheet, a second one for the current day only, of the parties whose pending balance changed that day; a party that cleared its balance that day is shown with 0; and a switch in the PDF for a detailed version.
- The Pending balances button on the Parties page now opens a menu: **All pending balances** (the sheet as before) and **Changed on this day only · <date>**, for the date in the top bar.
- The day sheet is the same paper-style sheet (No., Name, Baqaya jaat, two grids a page) with only the parties whose khata balance that day's entries changed. Each shows its balance at the end of that day, so on an earlier date it is that day's balance, not today's. A party whose entries of the day cancel out (a sale paid in full) is not listed, because its balance did not change. The filter chips, Archived switch and search apply as on the complete sheet. With nothing changed it says "No pending balance changed on this day".
- Its PDF preview has a **Details** switch. On, the same parties are printed as one Roznamcha-style sheet: Previous balance, Debit (added that day), Credit (taken off that day) and Baqaya jaat, with a Total row and a summary row; "+" still marks what you will pay. Off, it is the grid sheet again.
- Fixed on the way: the Urdu Pending balances PDF did not print its bold heading line (the date and filter), because Urdu lines are taller than the space kept for the heading. It prints now, and two full grids with the totals still fit one page.
- Nothing stored changed; no accounting change.
- Verification: `flutter analyze`: no issues. Full `flutter test`: **219 tests passed**, including the layout test at all six sizes in both languages. New cases in `test/pending_report_test.dart` cover the day's parties and figures (a part payment, a cleared khata at 0, a paid company, a sale paid in full left out, a later day, the filter), the detailed sheet cell by cell in English and its Urdu heads, the menu's two choices and messages, and the PDFs of both sheets in both languages. The English and Urdu PDFs (day, detailed, and a full Urdu page) and the menu were rendered to PNG and checked by eye.
- Not run: native Windows/Android builds, the backend test (no accounting change), a run against the live khata, or a restart of the running live app, which shows the menu only after it is reloaded.

## Deleting an entry: one step, stock returns by itself — 14 November 2026

- Asked by the user: deleting a sale opened the credit note form and asked whether to return gas to stock. Deleting should not ask that; the gas should go back to the FIFO stock it came from automatically, and deleting should be simple.
- The red button in an entry's details window (Parties, Activity) is now **Delete** for every entry type, sales included. It asks once ("Delete this entry? Its gas goes back to stock automatically and its amounts leave the khata."), then voids the entry and closes the window. A void takes the entry out of the projection, so its gas, cost and khata amounts come off by themselves, back to the same FIFO lots; nothing has to be chosen.
- The reason is now optional when deleting, here and on the Roznamcha page: left empty, the audit trail records "Deleted". Corrections and other reason prompts still require one.
- Credit notes (partial returns, or a financial-only credit) remain under New entry → Credit note.
- Nothing stored changed; no accounting change.
- Verification: `flutter analyze`: no issues. Full `flutter test`: **220 tests passed**, including a new widget test in `test/entry_facts_test.dart` (a purchase and a sale; Delete in the details window shows no credit note form or stock question, confirms with an empty reason, voids the sale with reason "Deleted", and stock and inventory value return to what they were before the sale) and the layout test at all six sizes in both languages.
- Not run: native Windows/Android builds, the backend test (no accounting change), or a restart of the running live app, which shows the new button only after it is reloaded.

## Less / Kami: Cash kam and Cash zyada, with no party — 16 November 2026

- Asked by the user: sometimes cash in hand is short or over for a reason that has no party (cash lost, money outside the khata). It should be possible to reduce or add cash without it coming from or going to a party.
- The Roznamcha's Less / Kami tab has two more choices under "Less kaise?": **Cash kam (nuqsan / khata se bahar)** and **Cash zyada (izafa)**. They ask for no customer, only the amount and a reason (required), and show cash in hand before and after.
- Decided with the user: the entry only corrects cash in hand and does not change the Profit report. It is saved as the existing `adjustment` on `money:cash` (negative for Cash kam), which client and server already validate and project, so there is no migration, no new field and nothing new for Reset all data.
- The row is named "Cash kam" or "Cash zyada" on the Roznamcha page, in entry details, the reports and the PDF (`adjustmentLabel`); this also renames earlier cash corrections made from New entry → Adjustment, which are the same thing. Safi Baqaya still equals the ledger's cash; the Opening line keeps showing "(pichla closing …, Adjustment ±…)". Editing the row opens the existing balance dialog.
- Verification: `flutter analyze`: no issues. Full `flutter test`: **221 tests passed**, including a new widget test in `test/daily_entry_test.dart` (Cash kam Rs 500 is refused without a reason, then saved as −50000 paisa on `money:cash` with no party; Cash zyada Rs 200; no party created; Safi Baqaya equals ledger cash; the unsaved choice survives leaving the tab) and the layout test at all six sizes in both languages.
- Not run: native Windows/Android builds, the backend test (no accounting or server change), or a restart of the running live app, which shows the new choices only after it is reloaded.

## Search bar: clear button — 16 November 2026

- Asked by the user: when something is typed in the top search bar, an X should appear on its right to remove the whole text.
- The search field in the top bar (`lib/ui/app.dart`) now shows a close icon (tooltip "Clear search" / "تلاش صاف کریں") whenever it has text. Tapping it empties the field and the search, so lists show everything again. It is hidden while the field is empty.
- Nothing stored changed; no accounting change.
- Verification: `flutter analyze` on the changed files: no issues. `test/l10n_test.dart` and `test/layout_overflow_test.dart` (all six sizes, both languages, Windows and Android): passed.
- Not run: the rest of the test suite, native builds, or a restart of the running live app, which shows the button only after it is reloaded.
## Pending balances: Roznamcha size, biggest first, the day's changes shaded — 16 November 2026

- Asked by the user: make the Pending balances PDF smaller, the same size as the Roznamcha; put the parties with the biggest balance on top; and in the full report, lightly highlight the parties whose balance changed today.
- The PDF's grids now use the Roznamcha sheet's sizes: 18 pt margin, 8.3 pt title and heading, 6.4 pt print stamp, 7.3 pt table text, rows of 15 pt instead of 20. A grid holds 45 rows instead of 32, so one A4 page takes 90 parties instead of 64, in English and Urdu.
- Both sheets (All pending balances and Changed on this day only, including its Details table) list the biggest balance first: everything to receive, largest first, then everything to pay ("+"), largest first. Equal balances keep the page's order. Row numbers follow the new order.
- All pending balances shades, in light grey, the rows of the parties whose khata balance the top bar's date changed (normally today), on screen and in the PDF, and adds a note under the totals: "Shaded: balance changed on <date> (<count>)". A party whose entries that day cancel out (a sale paid in cash) is not shaded. The day-only sheet is not shaded, since every row on it changed. One new Urdu label.
- Report output only: nothing stored changed, no accounting or server change, Reset all data unaffected.
- Verification: `flutter analyze`: no issues. Full `flutter test`: **221 tests passed**. `test/pending_report_test.dart` now checks the order of both sheets and the Details table, the shaded rows and the note for three different days, that the day sheet never shades, and that 90 rows plus both notes fit one page in English and Urdu while 91 need a second. The English and Urdu PDFs were rendered to PNG and checked by eye beside the Roznamcha sheet.
- Not run: native Windows/Android builds, the backend test (no server change), or a restart of the running live app, which shows the change only after it is reloaded.

## PDF size slider — 16 November 2026

- Asked by the user: a slider on every PDF report to make what is printed bigger or smaller, from 50% to 150%, changing the real PDF and remembered for each report.
- Every PDF preview (Roznamcha Print / PDF, Day history, Reports, party statements, invoices, the Money statement, Pending balances) has a **Size** bar under its title: − and + in 5% steps, the slider, and the percentage, which goes back to 100% when tapped. The PDF is built again when the slider is let go; what is saved, shared or printed is the PDF shown.
- Type, padding, row heights and spacing grow or shrink; the A4 page and its 18 pt margin do not. A wide Roznamcha day still shrinks to fit the page from the chosen size, and what is still too wide wraps. Pending balances grids hold 45 rows at 100%, 97 at 50% and 27 at 150%. At 100% the PDFs are exactly as before.
- The size is remembered for each kind of report (Daily roznamcha, Party statement, Invoice, Pending balances…) in the organization's own database (`pdf_sizes` metadata). Reset all data erases it (back to 100%); a backup restore brings back the backup's sizes. Excel, CSV and the on-screen tables are unchanged. No accounting, server or stored-entry change. Three new Urdu labels.
- Verification: `flutter analyze`: no issues. Full `flutter test`: **227 tests passed**, in a worktree, including the new `test/pdf_size_test.dart` (remembering, rounding to 5% and the 50–150 limits, a new start, a damaged value, Reset all data and backup restore; the exporter's limits; grid rows at every step fit the page; the bar's buttons, reset and drag; and long Customer balances and Pending balances PDFs at 50%, 100% and 150% in English and Urdu, with fewer pages smaller and more bigger, and 100% as before). The layout test now draws the preview's title bar with no switch, Compact and Details at all six sizes in both languages. PDFs at 50% and 150% were rendered to PNG with `tool/render_pdf.ps1` and checked by eye.
- Not run: native Windows/Android builds, the backend test (no server change), or a restart of the running live app, which shows the slider only after it is reloaded.

## Pending balances: the complete sheet on the top bar's date — 16 November 2026

- Asked by the user: with today the 16th and the 13th chosen in the top bar, the complete Pending balances sheet showed today's balances while shading the 13th's changes. It should be built on the chosen date.
- **All pending balances · <date>** (the menu item now shows the date) is the balances at the end of the top bar's date (`pendingReport(..., asOf: app.selectedDate)`, which uses `app.bookAt`), with that date in its heading; entries after it are not counted. The parties whose balance that date changed are shaded, as before. On today's date nothing changes.
- Report output only: nothing stored changed, no accounting or server change.
- Verification: `flutter analyze`: no issues. `test/pending_report_test.dart` checks the sheet on three dates (balances at the end of each, Ali's later payment left out, Hassan still listed before he paid, the subtitle date, the totals and the shading) and the menu label; `test/l10n_test.dart`, `test/layout_overflow_test.dart` and `test/report_sheet_test.dart` passed, then the full `flutter test`: **227 tests passed**.
- Not run: native builds, the backend test, or a restart of the running live app.

## Pending balances: arrange A to Z, by balance or newest first — 16 November 2026

- Asked by the user: besides the biggest balance first, Pending balances should be arrangeable A to Z by name, or newest first, with checks so exactly one is chosen, and A to Z by default.
- The Pending balances menu on the Parties page has an **Arrange** section under its two sheets: **A to Z** (ticked at first), **Biggest balance first** and **Newest first** (the Parties list's own order). Exactly one is ticked; choosing another ticks it and opens the menu again, so the sheet can be picked next. The choice is kept while the app is open (`AppController.pendingOrder`), like the Roznamcha's Customer wise toggle, and applies to both sheets and the day sheet's Details table.
- A to Z ignores capital and small letters ("aslam" sorts after "Ali Raza"). Urdu names follow the order of their letters in Unicode, after Latin names. Equal names or balances keep the list's order. Rows are numbered in the printed order, the shading follows its rows, and the subtitle names the order (e.g. "· A to Z ·"). Totals never change.
- Report output only: nothing stored changed, no accounting or server change; the choice is a view setting, so Reset all data leaves it alone. Three new Urdu labels: Arrange (ترتیب), A to Z, Biggest balance first.
- Verification: `flutter analyze`: no issues. `test/pending_report_test.dart` checks all three orders on the complete and day sheets (case ignored, numbering, the Details table, shading in two orders, totals unchanged, the subtitle in English and Urdu) and the menu: only A to Z ticked at first, each choice moves the tick and reopens the menu, Escape closes it. `test/l10n_test.dart` passed; full `flutter test`: **227 tests passed**.
- Not run: native builds, the backend test, or a restart of the running live app.
