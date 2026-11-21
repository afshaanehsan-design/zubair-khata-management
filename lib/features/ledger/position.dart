// "What we have" (asked for by the user on 21 November 2026): the detailed
// profit adds the business's position at the end of a day (cash, banks, what
// parties owe and are owed, stock) and how the profit of a period turned into
// it. Like profit it is worked out on top of the ledger: nothing is stored or
// posted, the server never computes it, and the khata does not change.
//
// The user's answers that shape it: cylinders have no money value (only
// counted); hospitality is paid to someone outside the app and never entered,
// so the khata's cash still holds it and it comes off here too; the owner
// never takes money out or puts money in, so there is no line for that.
import '../../core/l10n.dart';
import '../../core/models.dart';
import '../reports/reports.dart' show kg;
import 'book.dart';
import 'entry_facts.dart' show partyOwed;
import 'profit.dart';

/// The business date before [date].
String dayBefore(String date) {
  final d = DateTime.parse(date);
  return DateTime.utc(
    d.year,
    d.month,
    d.day - 1,
  ).toIso8601String().substring(0, 10);
}

/// What the business has at the end of [date]: its money, what parties owe
/// it and what it owes them, and its gas, valued the way profit values it.
class Position {
  final String date;

  /// No entry is dated on or before [date].
  bool empty = true;

  /// Saved drafts are among the entries.
  bool drafts = false;

  /// Cash in hand: the Roznamcha's Closing of [date].
  int cash = 0;

  /// The money in every bank account together ([Book.bankMoney]), and each
  /// account's (account id → paisa), archived ones included, none at 0,
  /// biggest first.
  int bank = 0;
  final Map<String, int> banks = {};

  /// What parties owe the business and what it owes them, each party's two
  /// sides set off ([partyOwed], as the Parties page shows them), and who
  /// (party id → paisa), biggest first.
  int receive = 0, pay = 0;
  final List<(String, int)> receivers = [], payees = [];

  /// Cylinder security parties gave, which goes back with the cylinders.
  int deposits = 0, depositParties = 0;

  /// Gas in stock at its purchase cost (the khata's `inventory`), with gas
  /// bought for purchase shares that are not given yet.
  int stockGrams = 0, stockValue = 0;

  /// Gas in stock entered without a cost, at the user's price (null while
  /// there is such gas and no price).
  int noCostGrams = 0;
  int? noCostValue = 0;

  /// Gas of draft purchases still without their price: not valued, as
  /// profit leaves it unpriced.
  int draftGrams = 0;

  /// Gas that went out before any stock covered it (negative stock, and
  /// shares waiting for their purchase). Its purchase is still to be paid,
  /// so it comes off: at the cost a later purchase gave it, or the user's
  /// prices for gas still without a cost ([owedWaiting] KG at the price of
  /// gas sold before its purchase, [owedNoCost] KG covered later by stock
  /// entered without a cost). [owedUnpriced] KG have neither.
  int owedGrams = 0, owedValue = 0, owedUnpriced = 0;
  int owedWaiting = 0, owedNoCost = 0;

  /// Hospitality on every KG sold up to [date] (profit's figure), paid
  /// outside the khata, and the KG and rates it was worked out on.
  int hospitality = 0, soldGrams = 0;
  final Set<int> hospitalityRates = {};

  /// Cylinders parties hold, by size: counted, never valued.
  final Map<int, int> held = {};

  Position(this.date);

  /// The gas in stock at its value: at cost, and without a cost at the
  /// user's price.
  int get stock => stockValue + (noCostValue ?? 0);

  /// What the business has: everything it has less everything it must pay.
  int get total =>
      cash + bank + receive + stock - owedValue - pay - deposits - hospitality;
}

/// Accounts that receive the cost of gas taken from stock.
bool _isCost(String account) =>
    account == 'cogs' ||
    account == shareCostAccount ||
    account == 'expense:Stock loss';

/// The position at the end of [date]. [at] is the book through [date]
/// (`app.bookAt(date)`), [all] the book of every entry (`app.book`), which
/// gives gas that waited at [date] the cost a later purchase brought, and
/// [upTo] the profit of every entry up to [date], for its hospitality.
Position positionAt(
  Book at,
  Book all,
  ProfitSettings settings,
  Profit upTo,
  String date,
) {
  final p = Position(date)
    ..empty = at.documents.isEmpty
    ..drafts = at.documents.any((d) => d.isDraft)
    ..cash = at.money('cash')
    ..bank = at.bankMoney;
  final banks = <(String, int)>[];
  final parties = <String>{};
  for (final MapEntry(key: account, value: balance) in at.balances.entries) {
    if (account.startsWith('money:') && account != 'money:cash') {
      if (balance != 0) banks.add((account.substring(6), balance));
    } else if (account.startsWith('deposit:')) {
      if (balance != 0) {
        p.deposits -= balance;
        p.depositParties++;
      }
    } else if (account.startsWith('ar:') || account.startsWith('ap:')) {
      parties.add(account.substring(3));
    }
  }
  for (final party in parties) {
    final (:receive, :pay) = partyOwed(at, party);
    if (receive > 0) p.receivers.add((party, receive));
    if (pay > 0) p.payees.add((party, pay));
  }
  int biggest((String, int) a, (String, int) b) {
    final order = b.$2.compareTo(a.$2);
    return order != 0 ? order : a.$1.compareTo(b.$1);
  }

  banks.sort(biggest);
  p.banks.addEntries([for (final (id, amount) in banks) MapEntry(id, amount)]);
  p.receivers.sort(biggest);
  p.payees.sort(biggest);
  p.receive = p.receivers.fold(0, (v, e) => v + e.$2);
  p.pay = p.payees.fold(0, (v, e) => v + e.$2);

  p.stockValue = at.balance('inventory');
  for (final lot in at.lots) {
    if (lot.grams <= 0 || lot.cost != null) continue;
    if (at.byId[lot.id]?.isDraft ?? false) {
      p.draftGrams += lot.grams;
    } else {
      p.noCostGrams += lot.grams;
    }
  }
  if (p.noCostGrams > 0) p.noCostValue = settings.noCost?.cost(p.noCostGrams);

  // Gas that waited at [date]: what stock entered later gave it, and the
  // user's prices for what still has no cost (as profit counts it).
  var stillWaiting = 0, laterNoCost = 0, laterDraft = 0;
  final waitingIds = <String>{
    for (final MapEntry(key: id, value: sources) in at.uncostedSources.entries)
      if ((sources[''] ?? 0) > 0) id,
    ...at.uncostedShares.keys,
  };
  for (final id in waitingIds) {
    final waiting = at.uncostedSources[id]?[''] ?? 0;
    p.owedGrams += waiting + (at.uncostedShares[id] ?? 0);
    for (final posting in all.postingsOf[id] ?? const <Posting>[]) {
      if (posting.date.compareTo(date) > 0 && _isCost(posting.account)) {
        p.owedValue += posting.debit;
      }
    }
    if (waiting == 0) continue;
    final before = at.uncostedSources[id]!;
    final now = all.uncostedSources[id] ?? const <String, int>{};
    for (final MapEntry(key: source, value: grams) in now.entries) {
      if (source.isEmpty) {
        stillWaiting += grams;
        continue;
      }
      // Covered after [date] by stock of unknown cost.
      final later = grams - (before[source] ?? 0);
      if (later <= 0) continue;
      if (all.byId[source]?.isDraft ?? false) {
        laterDraft += later;
      } else {
        laterNoCost += later;
      }
    }
  }
  final waitingPrice = settings.waiting, noCostPrice = settings.noCost;
  if (waitingPrice == null) {
    p.owedUnpriced += stillWaiting;
  } else if (stillWaiting != 0) {
    p.owedValue += waitingPrice.cost(stillWaiting);
    p.owedWaiting = stillWaiting;
  }
  if (noCostPrice == null) {
    p.owedUnpriced += laterNoCost;
  } else if (laterNoCost != 0) {
    p.owedValue += noCostPrice.cost(laterNoCost);
    p.owedNoCost = laterNoCost;
  }
  p.owedUnpriced += laterDraft;
  // Every lot, less the gas that has no stock yet, is what [Book.gasGrams]
  // holds; the lots of unknown cost are counted on their own.
  final grams = at.gasGrams + p.owedGrams - p.noCostGrams - p.draftGrams;
  p.stockGrams = grams < 0 ? 0 : grams;

  p
    ..hospitality = upTo.hospitality
    ..soldGrams = upTo.soldGrams
    ..hospitalityRates.addAll(upTo.hospitalityRates);
  for (final MapEntry(key: key, value: count) in at.held.entries) {
    if (count == 0) continue;
    final size = int.tryParse(key.substring(key.lastIndexOf(':') + 1));
    if (size != null) {
      p.held.update(size, (v) => v + count, ifAbsent: () => count);
    }
  }
  p.held.removeWhere((_, count) => count == 0);
  return p;
}

/// How the profit of a period became the change in what the business has:
/// [start] is the position at the end of the day before the period, [end]
/// at its last day.
class PositionChange {
  final Position start, end;
  final Profit profit;

  /// Opening balances, Cash kam / Cash zyada and stock entered with a cost
  /// (all posted against `equity:opening`), and stock entered without a cost
  /// at the user's price: they set the khata right and are not profit.
  int entered = 0;

  /// What purchase shares were charged above their cost (below it when
  /// negative): gas passed on at cost is not in profit.
  int shares = 0;

  /// The sales of historical summaries: profit counts them, but no money
  /// for them is in the khata.
  int historical = 0;

  PositionChange(this.start, this.end, this.profit);

  int get change => end.total - start.total;

  /// What the lines above leave unexplained: rounding of the user's prices
  /// (profit rounds them day by day) and of costs.
  int get other => change - profit.net - entered - shares + historical;
}

/// The change from [start] (the end of the day before [from], [startBook]
/// through that day) to [end] (the end of [to], [endBook] through it), with
/// the [profit] of the entries dated [from] to [to] and [all], the book of
/// every entry.
PositionChange positionChangeOf({
  required Position start,
  required Position end,
  required Book startBook,
  required Book endBook,
  required Book all,
  required ProfitSettings settings,
  required Profit profit,
  required String from,
  required String to,
}) {
  final c = PositionChange(start, end, profit)
    ..entered =
        startBook.balance('equity:opening') - endBook.balance('equity:opening');
  var noCostIn = 0;
  for (final d in all.documents) {
    if (d.date.compareTo(from) < 0 || d.date.compareTo(to) > 0) continue;
    if (d.type == EntryType.historicalSale) c.historical += d.value('amount');
    if (d.type == EntryType.stockAdjustment &&
        d.value('grams') > 0 &&
        d.data['costKnown'] != true &&
        !d.isDraft) {
      noCostIn += d.value('grams');
    }
    for (final posting in all.postingsOf[d.id] ?? const <Posting>[]) {
      if (posting.account == shareCostAccount) c.shares -= posting.debit;
    }
  }
  if (noCostIn > 0) c.entered += settings.noCost?.cost(noCostIn) ?? 0;
  return c;
}

/// One line of the detailed profit, as the screen and the PDF show it: its
/// [label] (with its + or −), what it is and why ([detail]), and [amount]
/// (null: not known). [price] lines are gas without a purchase price.
class PositionLine {
  final String label;
  final String? detail;
  final int? amount;
  final bool total, price;
  const PositionLine(
    this.label,
    this.amount, {
    this.detail,
    this.total = false,
    this.price = false,
  });
}

/// "per KG", "per 11.8 KG" or "per tonne".
String _unit(int unit) => switch (unit) {
  1000 => 'per KG',
  1000000 => 'per tonne',
  _ => 'per 11.8 KG',
};

/// "Ali Rs 2,000 · Bilal Rs 1,500 · 3 more": the biggest of [who].
String _biggest(
  Words t,
  List<(String, int)> who,
  String Function(int) rs,
  String Function(String) name,
) {
  const shown = 3;
  return [
    for (final (id, amount) in who.take(shown)) '${name(id)} ${rs(amount)}',
    if (who.length > shown)
      t('{n} more').replaceAll('{n}', '${who.length - shown}'),
  ].join(' · ');
}

/// What a line about parties says: [what] it is (translated), how many [who] there are
/// and the biggest of them.
String _parties(
  Words t,
  String what,
  List<(String, int)> who,
  String Function(int) rs,
  String Function(String) name,
) => [
  what,
  t('Parties: {n}.').replaceAll('{n}', '${who.length}'),
  '${t('Biggest')}: ${_biggest(t, who, rs, name)}',
].join(' ');

/// The lines of "What we have" for [p], then its notes. [rs] writes an
/// amount, [name] a party or account, [date] a business date; [settings]
/// holds the user's prices, named on the lines that use them.
(List<PositionLine>, List<String>) whatWeHaveLines(
  Position p,
  ProfitSettings settings,
  Words t, {
  required String Function(int) rs,
  required String Function(String) name,
  required String Function(String) date,
}) {
  final day = date(p.date);
  final rates = p.hospitalityRates.toList()..sort();
  String price(GasPrice? g) =>
      g == null ? '' : '${rs(g.rate)} ${t(_unit(g.unit))} (${t('your price')})';
  String unpriced(int grams) =>
      t('{kg} KG: purchase price not entered').replaceAll('{kg}', kg(grams));
  final lines = [
    PositionLine(
      t('Cash in hand'),
      p.cash,
      detail: t('Closing of the Roznamcha on {date}').replaceAll('{date}', day),
    ),
    PositionLine(
      '+ ${t('Banks')}',
      p.bank,
      detail: p.banks.isEmpty
          ? t('No money in any bank')
          : [
              for (final MapEntry(key: id, value: amount) in p.banks.entries)
                '${name(id)} ${rs(amount)}',
            ].join(' · '),
    ),
    PositionLine(
      '+ ${t('You will receive')}',
      p.receive,
      detail: p.receivers.isEmpty
          ? t('No party owes you anything.')
          : _parties(
              t,
              t('Your money that parties have not paid yet.'),
              p.receivers,
              rs,
              name,
            ),
    ),
    PositionLine(
      '+ ${t('Gas stock')}',
      p.stockValue,
      detail: t(
        '{kg} KG in stock, at what you paid for it (oldest stock first).',
      ).replaceAll('{kg}', kg(p.stockGrams)),
    ),
    if (p.noCostGrams != 0)
      PositionLine(
        '+ ${t('Stock entered without cost')}',
        p.noCostValue,
        detail: p.noCostValue == null
            ? unpriced(p.noCostGrams)
            : '${kg(p.noCostGrams)} KG × ${price(settings.noCost)}',
        price: p.noCostValue == null,
      ),
    if (p.owedGrams != 0 || p.owedValue != 0)
      PositionLine(
        '− ${t('Gas sold before its purchase')}',
        p.owedValue == 0 && p.owedUnpriced != 0 ? null : p.owedValue,
        detail: [
          t(
            '{kg} KG went out before their purchase was entered: you still have to pay for them.',
          ).replaceAll('{kg}', kg(p.owedGrams)),
          if (p.owedWaiting != 0)
            '${kg(p.owedWaiting)} KG × ${price(settings.waiting)}.',
          if (p.owedNoCost != 0)
            '${kg(p.owedNoCost)} KG × ${price(settings.noCost)}.',
          if (p.owedUnpriced != 0) unpriced(p.owedUnpriced),
        ].join(' '),
        price: p.owedUnpriced != 0,
      ),
    PositionLine(
      '− ${t('You will pay')}',
      p.pay,
      detail: p.payees.isEmpty
          ? t('You owe no party anything.')
          : _parties(
              t,
              t(
                'Money you still have to pay. It is in your cash, bank or stock, but it is not yours.',
              ),
              p.payees,
              rs,
              name,
            ),
    ),
    if (p.deposits != 0)
      PositionLine(
        '− ${t('Cylinder deposits')}',
        p.deposits,
        detail:
            '${t('Security money parties gave for their cylinders. It goes back when the cylinders come back.')} '
            '${t('Parties: {n}.').replaceAll('{n}', '${p.depositParties}')}',
      ),
    if (p.hospitality != 0)
      PositionLine(
        '− ${t('Hospitality')}',
        p.hospitality,
        detail:
            '${kg(p.soldGrams ~/ 1000)} ${t('ton')} × '
            '${rates.map(rs).join(' / ')} ${t('per ton')}, '
            '${t('up to {date}').replaceAll('{date}', day)}. '
            '${t('You pay it without an entry, so the khata still counts this money as yours.')}',
      ),
    PositionLine(
      '= ${t('What we have')}',
      p.total,
      total: true,
      detail: t(
        'What would be left if every party paid you, you paid every party and the stock went at what it cost.',
      ),
    ),
  ];
  final notes = [
    if (p.held.isNotEmpty)
      t(
        'Cylinders with customers: {list}. They are counted, not valued in money.',
      ).replaceAll(
        '{list}',
        [
          for (final size in sizes)
            if (p.held.containsKey(size)) '${sizeLabel(size)}: ${p.held[size]}',
        ].join(' · '),
      ),
    if (p.draftGrams != 0)
      t('{kg} KG of draft purchases have no price yet and are not counted.')
          .replaceAll('{kg}', kg(p.draftGrams)),
    if (p.drafts)
      t('Totals include saved drafts. Missing values are not counted.'),
  ];
  return (lines, notes);
}

/// "Why": how [c]'s profit became what we have, from what we had at the
/// end of the day before. (A list of each part's change followed it until
/// the user asked to remove it on 21 November 2026: they want to see what
/// they own, and a fall in what parties owe read as a loss.)
List<PositionLine> whyLines(
  PositionChange c,
  Words t, {
  required String Function(String) date,
}) {
  final start = c.start, end = c.end;
  final bridge = [
    PositionLine(
      start.empty
          ? t('What we had before the first entry')
          : t('What we had at the end of {date}')
                .replaceAll('{date}', date(start.date)),
      start.total,
    ),
    PositionLine(
      '+ ${t('Net profit')}',
      c.profit.net,
      detail: t('The profit worked out above'),
    ),
    if (c.entered != 0)
      PositionLine(
        '+ ${t('Opening balances and adjustments')}',
        c.entered,
        detail: t(
          'Opening balances, Cash kam / Cash zyada and stock entered: they set the khata right and are not profit.',
        ),
      ),
    if (c.shares != 0)
      PositionLine(
        '+ ${t('Purchase shares')}',
        c.shares,
        detail: t('Gas passed on at cost: what you charged less what it cost.'),
      ),
    if (c.historical != 0)
      PositionLine(
        '− ${t('Historical summaries')}',
        c.historical,
        detail: t(
          'Their sales are in profit, but no money for them is in the khata.',
        ),
      ),
    if (c.other != 0)
      PositionLine(
        '+ ${t('Other differences')}',
        c.other,
        detail: t('Rounding of prices and costs'),
      ),
    PositionLine(
      '= ${t('What we have at the end of {date}').replaceAll('{date}', date(end.date))}',
      end.total,
      total: true,
    ),
  ];
  return bridge;
}
