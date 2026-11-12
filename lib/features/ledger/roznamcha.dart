import '../../core/l10n.dart';
import '../../core/models.dart';

/// The forms of the original HTML Roznamcha. New entries store the form they
/// came from in `form`, so a day is shown exactly the way it was entered.
/// Older documents (and those made in the general composer) are inferred.
enum RozForm {
  aamad,
  kharcha,
  bankJama,
  companyPay,
  customerPay,

  /// Returning money borrowed from an Udhari party ("Udhar wapsi"). Posts
  /// like a company payment: it reduces what you owe that party (`ap:`).
  udharWapsi,
  nikali,
  less,
  office,
  companyIn,

  /// Adjustment entries: opening balances (see [isOpeningBalance]) and
  /// later balance corrections such as a cash count. There is no form for
  /// them; a wrong one is corrected with ✏️ like any other entry.
  opening,
}

/// An opening balance: the starting cash, or the balance a party or account
/// was created with. It is entered at the start of its day (`occurredAt` 0),
/// unlike a later balance correction.
bool isOpeningBalance(Document d) =>
    d.type == EntryType.adjustment && integer(d.data['occurredAt']) == 0;

/// The note shown on a Roznamcha row. The default note of an opening
/// balance only repeats its label, so it is left out.
String rozNote(Document d) =>
    isOpeningBalance(d) && d.note == openingBalanceNote ? '' : d.note;

bool _receiptFrom(Document d) =>
    d.type == EntryType.receipt && d.data['supplierRefund'] != true;

bool rozFormFits(RozForm form, Document d) => switch (form) {
  RozForm.aamad => d.type == EntryType.sale || _receiptFrom(d),
  RozForm.less => d.type == EntryType.discount || _receiptFrom(d),
  RozForm.companyIn =>
    d.type == EntryType.receipt && d.data['supplierRefund'] == true,
  RozForm.kharcha || RozForm.office => d.type == EntryType.expense,
  RozForm.companyPay || RozForm.udharWapsi =>
    d.type == EntryType.payment && d.data['supplierPayment'] == true,
  RozForm.customerPay =>
    d.type == EntryType.payment && d.data['supplierPayment'] != true,
  RozForm.nikali =>
    d.type == EntryType.transfer &&
        d.data['toAccount'] == 'cash' &&
        d.account != 'cash',
  RozForm.bankJama =>
    d.type == EntryType.transfer &&
        d.account == 'cash' &&
        d.data['toAccount'] != 'cash',
  RozForm.opening => d.type == EntryType.adjustment,
};

/// The Roznamcha form a document belongs to, or null when it is not a daily
/// cash-book entry (purchases, stock, cylinders, bank-to-bank transfers…).
RozForm? rozFormOf(Document d) {
  final stored = RozForm.values
      .where((f) => f.name == '${d.data['form'] ?? ''}')
      .firstOrNull;
  if (stored != null && rozFormFits(stored, d)) return stored;
  return switch (d.type) {
    EntryType.sale => RozForm.aamad,
    EntryType.receipt =>
      d.data['supplierRefund'] == true ? RozForm.companyIn : RozForm.aamad,
    EntryType.discount => RozForm.less,
    EntryType.expense =>
      d.data['category'] == 'Office' ? RozForm.office : RozForm.kharcha,
    EntryType.payment =>
      d.data['supplierPayment'] == true
          ? RozForm.companyPay
          : RozForm.customerPay,
    EntryType.transfer =>
      rozFormFits(RozForm.nikali, d)
          ? RozForm.nikali
          : rozFormFits(RozForm.bankJama, d)
          ? RozForm.bankJama
          : null,
    EntryType.adjustment => RozForm.opening,
    _ => null,
  };
}

/// A bank deposit shown in the Kharcha (B) side. Customer bank wasooli is
/// added automatically, exactly like the HTML "auto (Aamad se)" rows.
class BankJamaLine {
  final Document document;
  final String account;
  final int amount;
  final bool automatic;
  const BankJamaLine(this.document, this.account, this.amount, this.automatic);
}

class DirectLine {
  final Document document;
  final String party, bankName;
  final int amount;
  const DirectLine(this.document, this.party, this.bankName, this.amount);
}

/// One business day in the HTML Roznamcha layout.
///
/// Mirrors `computeDay()` of the original page:
///   A (Kul Aamad)  = opening + cash wasooli + bank wasooli + bank se nikali
///   B              = cash kharcha + bank wasooli (auto jama) + cash → bank
///   Safi Baqaya    = A − B = cash in hand
/// Money a customer paid straight to another party ("Direct to Party", not on
/// the original page) is treated like a bank wasooli: it is wasooli in A and
/// an automatic payment to that party in B, so cash in hand does not move.
/// Cash corrections, deposits and cash paid with purchases are included so
/// Safi Baqaya always equals the ledger's real closing cash.
class RoznamchaDay {
  final String date;
  final int opening;
  final List<Document> documents;

  /// A: Aamad / Wasooli rows (sales, receipts, company wasooli, deposits).
  final List<Document> aamad = [];
  final List<Document> nikali = [];
  final List<Document> less = [];
  final List<Document> openings = [];

  /// B: Kharcha rows (cash, office, company, customer, purchase payments).
  final List<Document> kharcha = [];
  final List<BankJamaLine> bankJama = [];

  /// Each direct collection in B, as an automatic payment to its company.
  final List<DirectLine> directLines = [];

  /// Entries of the day that are not part of the cash book.
  final List<Document> other = [];

  int cashIn = 0, bankCust = 0, wd = 0, cashAdj = 0;

  /// Wasooli that customers paid directly to another party.
  int direct = 0;
  int kharchaCash = 0, kharchaBank = 0, depMan = 0;
  int plainCash = 0, officeCash = 0, companyCash = 0, customerCash = 0;
  int udharCash = 0;
  int lessDiscount = 0, lessBank = 0;
  int bill = 0, cylinderBill = 0, bulkGrams = 0, cylinderGrams = 0;
  int gasIn = 0, gasOut = 0;
  final Map<int, int> cylinders = {for (final s in sizes) s: 0};

  RoznamchaDay(this.date, this.opening, Iterable<Document> docs)
    : documents = docs.toList() {
    for (final d in documents) {
      _add(d);
    }
  }

  int get wasooli => cashIn + bankCust + direct;
  int get left => opening + cashAdj + wasooli + wd;
  int get rightTotal => kharchaCash + bankCust + direct + depMan;
  int get safi => left - rightTotal;
  int get bankIn => bankCust + depMan + lessBank;
  int get bankOut => wd + kharchaBank;
  int get bankNet => bankIn - bankOut;
  int get lessTotal => lessDiscount + lessBank;
  int get bulkBill => bill - cylinderBill;
  int get count => documents.length;

  void _out(Document d, int amount, {RozForm? form}) {
    if (d.account == 'cash') {
      kharchaCash += amount;
      switch (form) {
        case RozForm.office:
          officeCash += amount;
        case RozForm.companyPay:
          companyCash += amount;
        case RozForm.customerPay:
          customerCash += amount;
        case RozForm.udharWapsi:
          udharCash += amount;
        default:
          plainCash += amount;
      }
    } else {
      kharchaBank += amount;
    }
  }

  void _in(Document d, int cash, int bank, String account) {
    cashIn += cash;
    bankCust += bank;
    if (bank > 0) bankJama.add(BankJamaLine(d, account, bank, true));
  }

  void _add(Document d) {
    final form = rozFormOf(d);
    final amount = d.value('amount');
    switch (d.type) {
      case EntryType.sale:
        bill += d.bill;
        cylinderBill += d.cylinderRevenue;
        bulkGrams += d.extraGrams;
        cylinderGrams += d.cylinderGrams;
        gasOut += d.cylinderGrams;
        for (final s in sizes) {
          cylinders[s] =
              cylinders[s]! + integer((d.data['quantities'] as Map?)?['$s']);
        }
      case EntryType.purchase:
        gasIn += d.value('grams');
      case EntryType.stockAdjustment:
        final grams = d.value('grams');
        if (grams > 0) {
          gasIn += grams;
        } else {
          gasOut -= grams;
        }
      case EntryType.historicalSale:
        gasOut += d.value('grams');
      case EntryType.creditNote:
        if (d.data['stockReturned'] == true) gasIn += d.cylinderGrams;
      default:
        break;
    }
    switch (form) {
      case RozForm.aamad || RozForm.companyIn:
        aamad.add(d);
        cashIn += d.value('cash');
        for (final l in d.bankLines) {
          if (l.direct) {
            direct += l.amount;
            directLines.add(DirectLine(d, l.party, l.bankName, l.amount));
          } else {
            bankCust += l.amount;
            bankJama.add(BankJamaLine(d, l.account, l.amount, true));
          }
        }
      case RozForm.less:
        less.add(d);
        if (d.type == EntryType.receipt) {
          // A bank "less" reaches the account but stays out of A and B,
          // exactly like the original page. (Cash is never entered here, but
          // if present it must still reach cash in hand.)
          lessBank += d.bankIn;
          cashIn += d.value('cash');
        } else {
          lessDiscount += amount;
        }
      case RozForm.nikali:
        nikali.add(d);
        wd += amount;
      case RozForm.bankJama:
        depMan += amount;
        bankJama.add(BankJamaLine(d, '${d.data['toAccount']}', amount, false));
      case RozForm.kharcha ||
          RozForm.office ||
          RozForm.companyPay ||
          RozForm.customerPay ||
          RozForm.udharWapsi:
        kharcha.add(d);
        _out(d, amount, form: form);
      case RozForm.opening:
        openings.add(d);
        if (d.data['target'] == 'money:cash') cashAdj += amount;
      case null:
        switch (d.type) {
          case EntryType.depositRefund:
            kharcha.add(d);
            _out(d, amount, form: RozForm.customerPay);
          case EntryType.deposit:
            aamad.add(d);
            if (d.account == 'cash') {
              _in(d, amount, 0, '');
            } else {
              _in(d, 0, amount, d.account);
            }
          default:
            // Purchases stay listed with the gas entries; cash paid with
            // them is still a payment to the company on the B side.
            if (d.type == EntryType.purchase && amount > 0) {
              kharcha.add(d);
              _out(d, amount, form: RozForm.companyPay);
            }
            other.add(d);
        }
    }
  }
}

/// Kharcha (B) type label, as on the original page.
String rozTypeLabel(Document d) => switch (rozFormOf(d)) {
  RozForm.office => 'Office kharcha',
  RozForm.companyPay => 'Company ko payment',
  RozForm.customerPay => 'Customer ko payment',
  RozForm.udharWapsi => 'Udhar wapsi',
  RozForm.kharcha => 'Cash kharcha',
  RozForm.bankJama => 'Bank jama',
  _ =>
    d.type == EntryType.purchase
        ? 'Purchase payment'
        : d.type == EntryType.depositRefund
        ? 'Deposit refund'
        : entryLabel(d.type.name),
};
