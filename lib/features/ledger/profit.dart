import '../../core/models.dart';
import 'book.dart';

/// A purchase price the user enters for gas the khata has no cost for (gas
/// sold before its purchase was entered, or from stock entered without a
/// cost): [rate] paisa per [unit] grams, in the units of a purchase (1000 per
/// KG, 11800 per 11.8 KG, 1000000 per ton). [setOn] is the business date it
/// was entered, shown beside it.
class GasPrice {
  static const units = [1000, 11800, 1000000];
  final int rate, unit;
  final String setOn;
  const GasPrice(this.rate, this.unit, {this.setOn = ''});

  /// What [grams] cost at this price, in paisa.
  int cost(int grams) => multiplyDivide(grams, rate, unit);

  Json toJson() => {
    'rate': rate,
    'unit': unit,
    if (setOn.isNotEmpty) 'setOn': setOn,
  };

  /// Null for anything that is not a usable price.
  static GasPrice? fromJson(dynamic j) {
    if (j is! Map) return null;
    final rate = j['rate'], unit = j['unit'];
    if (rate is! int || rate <= 0 || rate > 9000000000000) return null;
    if (unit is! int || !units.contains(unit)) return null;
    return GasPrice(rate, unit, setOn: '${j['setOn'] ?? ''}');
  }
}

/// What profit needs besides the entries. It is kept on the business profile
/// (the `business` settings record, under `profit`), so every device shows
/// the same profit, a backup keeps it and Reset all data returns it to the
/// defaults. Nothing here changes the khata: balances, stock and the FIFO
/// costs of entries stay exactly as they are.
class ProfitSettings {
  /// Rs 1,200 on every ton (1000 KG) of gas sold: the business's hospitality
  /// (asked for by the user on 19 November 2026).
  static const defaultHospitality = 120000;

  /// Hospitality in paisa per ton. Each rate applies from its date ('' for
  /// from the start) until the next one, so a new rate leaves the profit of
  /// earlier days as it was. Sorted by date; the first is always ''.
  final List<(String, int)> hospitality;

  /// The user's price for gas sold before its purchase was entered (negative
  /// stock), and for gas sold from stock entered without a cost.
  final GasPrice? waiting, noCost;

  /// Whether a hospitality rate was ever saved. Until then the first change
  /// is offered for every day.
  final bool hospitalitySaved;

  const ProfitSettings({
    this.hospitality = const [('', defaultHospitality)],
    this.waiting,
    this.noCost,
    this.hospitalitySaved = false,
  });

  /// Read tolerantly from the business profile [business]: anything missing
  /// or damaged is the default.
  factory ProfitSettings.of(Json business) {
    final j = business['profit'];
    if (j is! Map) return const ProfitSettings();
    final rates = <String, int>{};
    final saved = j['hospitality'];
    if (saved is List) {
      for (final item in saved) {
        if (item is! Map) continue;
        final from = '${item['from'] ?? ''}', rate = item['rate'];
        if (rate is! int || rate < 0 || rate > 9000000000000) continue;
        if (from.isNotEmpty && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(from)) {
          continue;
        }
        rates[from] = rate;
      }
    }
    rates.putIfAbsent('', () => defaultHospitality);
    final dates = rates.keys.toList()..sort();
    return ProfitSettings(
      hospitality: [for (final date in dates) (date, rates[date]!)],
      waiting: GasPrice.fromJson(j['waiting']),
      noCost: GasPrice.fromJson(j['noCost']),
      hospitalitySaved: saved is List,
    );
  }

  Json toJson() => {
    if (hospitalitySaved)
      'hospitality': [
        for (final (from, rate) in hospitality) {'from': from, 'rate': rate},
      ],
    'waiting': ?waiting?.toJson(),
    'noCost': ?noCost?.toJson(),
  };

  /// Hospitality per ton on [date].
  int hospitalityOn(String date) {
    var rate = hospitality.first.$2;
    for (final (from, value) in hospitality) {
      if (from.compareTo(date) > 0) break;
      rate = value;
    }
    return rate;
  }

  /// These settings with hospitality [rate] from [from] on ('' for every
  /// day): later rates give way to it, earlier days keep theirs.
  ProfitSettings withHospitality(int rate, String from) {
    final next = <(String, int)>[];
    for (final entry in [
      for (final e in hospitality)
        if (from.isNotEmpty && e.$1.compareTo(from) < 0) e,
      (from, rate),
    ]) {
      // A rate equal to the one before it changes nothing.
      if (next.isEmpty || next.last.$2 != entry.$2) next.add(entry);
    }
    return ProfitSettings(
      hospitality: next,
      waiting: waiting,
      noCost: noCost,
      hospitalitySaved: true,
    );
  }

  /// These settings with the two prices replaced (null removes one).
  ProfitSettings withPrices({GasPrice? waiting, GasPrice? noCost}) =>
      ProfitSettings(
        hospitality: hospitality,
        waiting: waiting,
        noCost: noCost,
        hospitalitySaved: hospitalitySaved,
      );
}

/// The profit of entries: one day's, or a range's (the sum of its days).
///
/// Sales − cost of gas sold − gas without a cost at the user's price = gross
/// profit; gross − hospitality − office kharcha − other kharcha = net profit.
class Profit {
  /// Sales at their bills: cylinders, and extra (bulk) KG sold. A credit
  /// note takes its invoice's back. Purchase shares are not sales: they pass
  /// gas on at cost.
  int cylinderSales = 0, bulkSales = 0;

  /// What the gas sold cost: its purchase price by FIFO, less gas that came
  /// back to stock.
  int cost = 0;

  /// Gas sold without a known cost: still waiting for its purchase (negative
  /// stock), or sold from stock entered without a cost.
  int waitingGrams = 0, noCostGrams = 0;

  /// Those KG at the user's prices (0 while there is no price).
  int waitingCost = 0, noCostCost = 0;

  /// The KG of them no price covers: profit leaves their cost out.
  int unpricedGrams = 0;

  /// KG of gas sold (cylinders and bulk, less gas returned; never purchase
  /// shares) and the hospitality on them.
  int soldGrams = 0, hospitality = 0;

  /// The hospitality rates (paisa per ton) of the days that sold gas.
  final Set<int> hospitalityRates = {};

  /// Office kharcha, and every other expense by category: `General` (cash
  /// kharcha), `Write-off` (a Less discount), `Stock loss`...
  int office = 0;
  final Map<String, int> expenses = {};

  /// KG of purchase shares, left out of sales, cost and hospitality.
  int sharedGrams = 0;

  /// Whether a historical summary or a saved draft is among the entries.
  bool historical = false, drafts = false;

  int get sales => cylinderSales + bulkSales;
  int get estimated => waitingCost + noCostCost;
  int get gross => sales - cost - estimated;
  int get otherExpenses => expenses.values.fold(0, (v, e) => v + e);
  int get net => gross - hospitality - office - otherExpenses;

  /// Every KG sold has a cost (FIFO or the user's price) and no historical
  /// summary makes the figures provisional.
  bool get complete => unpricedGrams == 0 && !historical;

  void add(Profit other) {
    cylinderSales += other.cylinderSales;
    bulkSales += other.bulkSales;
    cost += other.cost;
    waitingGrams += other.waitingGrams;
    noCostGrams += other.noCostGrams;
    waitingCost += other.waitingCost;
    noCostCost += other.noCostCost;
    unpricedGrams += other.unpricedGrams;
    soldGrams += other.soldGrams;
    hospitality += other.hospitality;
    hospitalityRates.addAll(other.hospitalityRates);
    office += other.office;
    for (final MapEntry(:key, :value) in other.expenses.entries) {
      expenses.update(key, (v) => v + value, ifAbsent: () => value);
    }
    sharedGrams += other.sharedGrams;
    historical |= other.historical;
    drafts |= other.drafts;
  }
}

/// Each day's profit from [from] to [to] (business dates, both included).
/// [book] should hold every known entry (`app.book`): a sale entered before
/// its purchase gets its cost when the stock comes, possibly after the range,
/// and that cost belongs to the sale's day. Days without entries are left
/// out.
Map<String, Profit> profitByDay(
  Book book,
  ProfitSettings settings,
  String from,
  String to,
) {
  final days = <String, List<Document>>{};
  for (final d in book.documents) {
    if (d.date.compareTo(from) < 0 || d.date.compareTo(to) > 0) continue;
    days.putIfAbsent(d.date, () => []).add(d);
  }
  return {
    for (final MapEntry(key: date, value: docs) in days.entries)
      date: _day(book, settings, date, docs),
  };
}

/// The profit from [from] to [to]: the sum of [profitByDay]. Hospitality and
/// the priced KG are rounded per day, so the daily view adds up exactly.
Profit profitOf(Book book, ProfitSettings settings, String from, String to) {
  final total = Profit();
  for (final day in profitByDay(book, settings, from, to).values) {
    total.add(day);
  }
  return total;
}

Profit _day(
  Book book,
  ProfitSettings settings,
  String date,
  List<Document> docs,
) {
  final p = Profit();
  var waiting = 0, noCost = 0, draftLots = 0;
  for (final d in docs) {
    if (d.isDraft) p.drafts = true;
    // The entry's own postings, with any cost stock gave it later.
    for (final posting in book.postingsOf[d.id] ?? const <Posting>[]) {
      final account = posting.account;
      if (account == 'revenue:gas') {
        p.cylinderSales -= posting.debit;
      } else if (account == 'revenue:bulk') {
        p.bulkSales -= posting.debit;
      } else if (account == 'cogs') {
        p.cost += posting.debit;
      } else if (account.startsWith('expense:')) {
        final category = account.substring(8);
        if (category == 'Office') {
          p.office += posting.debit;
        } else {
          p.expenses.update(
            category,
            (v) => v + posting.debit,
            ifAbsent: () => posting.debit,
          );
        }
      }
    }
    switch (d.type) {
      case EntryType.sale:
        p.soldGrams += d.ownSaleGrams;
        if (d.bulkAtCost) p.sharedGrams += d.extraGrams;
      case EntryType.historicalSale:
        p.historical = true;
        // A day's sales summed up: it posts no revenue of its own.
        p.cylinderSales += d.value('amount');
        p.soldGrams += d.value('grams');
      case EntryType.creditNote when d.data['stockReturned'] == true:
        final original = book.byId['${d.data['sourceInvoice']}'];
        if (original != null) {
          p.soldGrams -= original.ownSaleGrams;
          if (original.bulkAtCost) p.sharedGrams -= original.extraGrams;
        }
      default:
        break;
    }
    final sources = book.uncostedSources[d.id] ?? const <String, int>{};
    for (final MapEntry(key: source, value: grams) in sources.entries) {
      if (source.isEmpty) {
        waiting += grams;
      } else if (book.byId[source]?.isDraft ?? false) {
        // A draft purchase still without its price: missing, not priced.
        draftLots += grams;
      } else {
        noCost += grams;
      }
    }
  }
  p.waitingGrams = waiting;
  p.noCostGrams = noCost + draftLots;
  final waitingPrice = settings.waiting, noCostPrice = settings.noCost;
  if (waitingPrice == null) {
    p.unpricedGrams += waiting;
  } else {
    p.waitingCost = waitingPrice.cost(waiting);
  }
  if (noCostPrice == null) {
    p.unpricedGrams += noCost;
  } else {
    p.noCostCost = noCostPrice.cost(noCost);
  }
  p.unpricedGrams += draftLots;
  final rate = settings.hospitalityOn(date);
  p.hospitality = multiplyDivide(p.soldGrams, rate, 1000000);
  if (p.soldGrams != 0) p.hospitalityRates.add(rate);
  return p;
}

/// Gas without a known cost in [book] (all of it, any date), for the
/// purchase price dialog: KG waiting for their purchase (negative stock), and
/// KG sold from each lot of unknown cost (lot id → KG). Purchase shares are
/// left out (at cost, they never change profit), and so are draft purchases
/// still without their price.
(int, Map<String, int>) gasWithoutCost(Book book) {
  var waiting = 0;
  final lots = <String, int>{};
  for (final sources in book.uncostedSources.values) {
    for (final MapEntry(key: source, value: grams) in sources.entries) {
      if (source.isEmpty) {
        waiting += grams;
      } else if (!(book.byId[source]?.isDraft ?? false)) {
        lots.update(source, (v) => v + grams, ifAbsent: () => grams);
      }
    }
  }
  return (waiting, lots);
}

/// Whether the user's prices make [book]'s profit complete where
/// [Book.warnings] calls it incomplete: every KG of gas without a known cost
/// has a price, stock of unknown cost still in hand will be priced when it
/// is sold, and nothing else (a saved draft, a historical summary, a share
/// waiting for stock) leaves it provisional. The pages then say the prices
/// are used instead of "Profit is incomplete".
bool profitPriced(Book book, ProfitSettings settings) {
  if (book.documents.any(
    (d) => d.isDraft || d.type == EntryType.historicalSale,
  )) {
    return false;
  }
  if (book.uncostedShares.isNotEmpty) return false;
  final (waiting, lots) = gasWithoutCost(book);
  final unknownStock = book.lots.any((l) => l.cost == null && l.grams > 0);
  if (waiting > 0 && settings.waiting == null) return false;
  if ((lots.isNotEmpty || unknownStock) && settings.noCost == null) {
    return false;
  }
  return waiting > 0 || lots.isNotEmpty || unknownStock;
}
