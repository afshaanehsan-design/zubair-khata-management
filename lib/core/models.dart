import 'dart:convert';

typedef Json = Map<String, dynamic>;

int integer(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

int multiplyDivide(int a, int b, int denominator) {
  if (denominator <= 0) throw ArgumentError('Invalid divisor');
  final product = BigInt.from(a) * BigInt.from(b);
  final result =
      (product.abs() + BigInt.from(denominator ~/ 2)) ~/
      BigInt.from(denominator);
  if (result > BigInt.from(9000000000000000)) {
    throw const FormatException('Number exceeds supported range');
  }
  return (product.isNegative ? -result : result).toInt();
}

/// Parse decimal input without binary floating-point arithmetic.
int decimal(String input, int places) {
  final text = input
      .trim()
      .replaceAll(',', '')
      .replaceAll('۰', '0')
      .replaceAll('۱', '1')
      .replaceAll('۲', '2')
      .replaceAll('۳', '3')
      .replaceAll('۴', '4')
      .replaceAll('۵', '5')
      .replaceAll('۶', '6')
      .replaceAll('۷', '7')
      .replaceAll('۸', '8')
      .replaceAll('۹', '9')
      .replaceAll('٠', '0')
      .replaceAll('١', '1')
      .replaceAll('٢', '2')
      .replaceAll('٣', '3')
      .replaceAll('٤', '4')
      .replaceAll('٥', '5')
      .replaceAll('٦', '6')
      .replaceAll('٧', '7')
      .replaceAll('٨', '8')
      .replaceAll('٩', '9')
      .replaceAll('٬', '')
      .replaceAll('−', '-')
      .replaceAll('٫', '.');
  if (text.isEmpty) return 0;
  if (!RegExp(r'^-?\d+(\.\d+)?$').hasMatch(text)) {
    throw const FormatException('Enter a valid number');
  }
  final sign = text.startsWith('-') ? -1 : 1;
  final parts = text.replaceFirst('-', '').split('.');
  final fraction = parts.length == 1 ? '' : parts[1];
  if (fraction.length > places) {
    throw FormatException('Use at most $places decimal places');
  }
  final scale = integer('1${'0' * places}');
  final parsed =
      BigInt.parse(parts.first) * BigInt.from(scale) +
      BigInt.from(integer(fraction.padRight(places, '0')));
  if (parsed > BigInt.from(9000000000000)) {
    throw const FormatException('Number exceeds supported range');
  }
  return sign * parsed.toInt();
}

String decimalText(int value, int places) {
  final sign = value < 0 ? '-' : '';
  final digits = value.abs().toString().padLeft(places + 1, '0');
  if (places == 0) return '$sign$digits';
  return '$sign${digits.substring(0, digits.length - places)}.${digits.substring(digits.length - places)}';
}

String businessDate([DateTime? instant]) => (instant ?? DateTime.now())
    .toUtc()
    .add(const Duration(hours: 5))
    .toIso8601String()
    .substring(0, 10);

enum EntryType {
  sale,
  receipt,
  payment,
  expense,
  purchase,
  transfer,
  discount,
  adjustment,
  stockAdjustment,
  cylinder,
  deposit,
  depositRefund,
  historicalSale,
  creditNote,
}

const sizes = [11800, 15000, 45000];
String sizeLabel(int grams) =>
    '${grams % 1000 == 0 ? grams ~/ 1000 : grams / 1000} KG';

class Record {
  final String id;
  final String kind;
  final Json data;
  final int version;
  final bool pending;
  const Record(
    this.id,
    this.kind,
    this.data, {
    this.version = 0,
    this.pending = false,
  });
  String get name => '${data['name'] ?? ''}';
  bool get archived => data['archived'] == true;

  /// A party removed from the khata. The record stays (the app never erases
  /// rows, so deleting syncs like any other change) but is hidden everywhere.
  bool get deleted => data['deleted'] == true;
  Json toJson() => {'id': id, 'kind': kind, 'data': data, 'version': version};
  factory Record.fromJson(Json json, {bool pending = false}) => Record(
    '${json['id']}',
    '${json['kind']}',
    Map<String, dynamic>.from(json['data'] as Map),
    version: integer(json['version']),
    pending: pending,
  );
}

/// One cylinder size on a sale or credit note: how many, how heavy, and what
/// they bill at the document's rate.
class SaleLine {
  final int size, count, grams, amount;
  const SaleLine(this.size, this.count, this.grams, this.amount);
}

/// One customer collection destination. A party means the customer paid the
/// company directly; otherwise the money reached one of our bank accounts.
class BankLine {
  final int amount;
  final String account, party, bankName;
  const BankLine({
    required this.amount,
    this.account = '',
    this.party = '',
    this.bankName = '',
  });
  bool get direct => party.isNotEmpty;
}

class Document {
  final Record record;
  const Document(this.record);
  Json get data => record.data;
  String get id => record.id;
  EntryType get type => EntryType.values.byName('${data['type']}');
  String get date => '${data['date']}';
  String get party => '${data['party'] ?? ''}';
  String get account => '${data['account'] ?? 'cash'}';
  String get bankAccount => '${data['bankAccount'] ?? ''}';

  /// Legacy fields are additive and retain their original posting order.
  List<BankLine> get bankLines => [
    if (value('bank') > 0)
      BankLine(amount: value('bank'), account: bankAccount),
    if (value('direct') > 0)
      BankLine(
        amount: value('direct'),
        party: '${data['directParty'] ?? ''}',
        bankName: '${data['directBank'] ?? ''}',
      ),
    if (data['bankLines'] is List)
      for (final line in (data['bankLines'] as List).whereType<Map>())
        BankLine(
          amount: integer(line['amount']),
          account: '${line['account'] ?? ''}',
          party: '${line['party'] ?? ''}',
          bankName: '${line['bankName'] ?? ''}',
        ),
  ];

  int get bankIn =>
      bankLines.where((l) => !l.direct).fold(0, (v, l) => v + l.amount);
  int get direct =>
      bankLines.where((l) => l.direct).fold(0, (v, l) => v + l.amount);
  Set<String> get directParties => {
    for (final l in bankLines)
      if (l.direct) l.party,
  };
  int directTo(String party) => bankLines
      .where((l) => l.direct && l.party == party)
      .fold(0, (v, l) => v + l.amount);

  /// Everything collected from the party with this sale or receipt: cash,
  /// bank and what it paid directly to another party.
  int get collected => value('cash') + bankIn + direct;
  String get note => '${data['note'] ?? ''}';
  String get reference =>
      '${data['reference'] ?? id.substring(0, id.length < 8 ? id.length : 8).toUpperCase()}';
  bool get voided => data['voided'] == true;
  int value(String key) => integer(data[key]);
  int get cylinderGrams => sizes.fold(
    0,
    (sum, size) => sum + size * integer((data['quantities'] as Map?)?['$size']),
  );
  int get extraGrams => value('extraGrams');

  /// Cylinders per size (sizes with none are left out), each billed at the
  /// rate. Lines are rounded to whole rupees on their own, so they can differ
  /// from [cylinderRevenue] by [lineRounding].
  List<SaleLine> get saleLines => [
    for (final size in sizes)
      if (integer((data['quantities'] as Map?)?['$size']) > 0)
        SaleLine(
          size,
          integer((data['quantities'] as Map?)?['$size']),
          size * integer((data['quantities'] as Map?)?['$size']),
          multiplyDivide(
                size * integer((data['quantities'] as Map?)?['$size']),
                rate,
                11800 * 100,
              ) *
              100,
        ),
  ];

  /// What the bill adds or removes beyond the sum of [saleLines].
  int get lineRounding =>
      cylinderRevenue - saleLines.fold(0, (sum, l) => sum + l.amount);
  int get rate => value('rate');
  int get cylinderRevenue =>
      multiplyDivide(cylinderGrams, rate, 11800 * 100) * 100;
  int get bill =>
      multiplyDivide(cylinderGrams + extraGrams, rate, 11800 * 100) * 100;
  int get bulkRevenue => bill - cylinderRevenue;
  int get purchaseBill =>
      multiplyDivide(
        value('grams'),
        rate,
        (value('rateUnit') == 0 ? 11800 : value('rateUnit')) * 100,
      ) *
      100;
  int get total => type == EntryType.sale
      ? bill + value('depositCharge')
      : type == EntryType.creditNote
      ? bill
      : type == EntryType.purchase
      ? purchaseBill
      : value('amount');
}

class Change {
  final String id;
  final String kind;
  final Json data;
  final int expectedVersion;
  const Change(this.id, this.kind, this.data, this.expectedVersion);
  Json toJson() => {
    'id': id,
    'kind': kind,
    'data': data,
    'expected_version': expectedVersion,
  };
  factory Change.fromJson(Json j) => Change(
    '${j['id']}',
    '${j['kind']}',
    Map<String, dynamic>.from(j['data'] as Map),
    integer(j['expected_version']),
  );
}

class Command {
  final String id;
  final String device;
  final String epoch;
  final String action;
  final String reason;
  final List<Change> changes;
  final String status;
  final String? error;
  final int created;
  const Command({
    required this.id,
    required this.device,
    required this.epoch,
    required this.action,
    required this.changes,
    this.reason = '',
    this.status = 'queued',
    this.error,
    required this.created,
  });
  Json get payload => {
    'command_id': id,
    'device_id': device,
    'epoch': epoch,
    'action': action,
    'reason': reason,
    'changes': changes.map((c) => c.toJson()).toList(),
  };
  Json toJson() => {
    ...payload,
    'status': status,
    'error': error,
    'created': created,
  };
  factory Command.fromJson(Json j) => Command(
    id: '${j['command_id']}',
    device: '${j['device_id']}',
    epoch: '${j['epoch']}',
    action: '${j['action']}',
    changes: (j['changes'] as List)
        .map((v) => Change.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
    reason: '${j['reason'] ?? ''}',
    status: '${j['status'] ?? 'queued'}',
    error: j['error'] as String?,
    created: integer(j['created']),
  );
}

Json decodeObject(String text) =>
    Map<String, dynamic>.from(jsonDecode(text) as Map);

String canonicalJson(dynamic value) {
  dynamic sorted(dynamic v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: sorted(v[k])};
    }
    if (v is List) return v.map(sorted).toList();
    return v;
  }

  return jsonEncode(sorted(value));
}

/// Default note of an opening balance (adjustments always need a note).
const openingBalanceNote = 'Opening balance';

Json cleanDocumentData(Json data) {
  const common = [
    'type',
    'date',
    'occurredAt',
    'party',
    'note',
    'reference',
    'voided',
    'voidReason',
    'replacement',
    'replaces',
    'restoredFrom',
    // The Roznamcha form the entry was made in (display only).
    'form',
  ];
  final fields = switch (EntryType.values.byName('${data['type']}')) {
    EntryType.sale => [
      'quantities',
      'returned',
      'rate',
      'extraGrams',
      'depositCharge',
      'cash',
      'bank',
      'bankAccount',
      'direct',
      'directParty',
      'directBank',
      'bankLines',
      'customerOwned',
      'vehicle',
      'dueDate',
      'allocations',
    ],
    EntryType.receipt => [
      'cash',
      'bank',
      'bankAccount',
      'direct',
      'directParty',
      'directBank',
      'bankLines',
      'supplierRefund',
      'allocations',
      'vehicle',
    ],
    EntryType.payment => [
      'amount',
      'account',
      'supplierPayment',
      'branch',
      // Only on older Company ko payment entries: the form no longer asks
      // for it. Kept, like the server's canonical_document, so they keep it.
      'customerNote',
    ],
    EntryType.expense => ['amount', 'account', 'category'],
    EntryType.purchase => [
      'grams',
      'rate',
      'rateUnit',
      'amount',
      'account',
      'vehicle',
    ],
    EntryType.transfer => ['amount', 'account', 'toAccount'],
    EntryType.discount => ['amount'],
    EntryType.adjustment => ['target', 'amount'],
    EntryType.stockAdjustment => ['grams', 'cost', 'costKnown'],
    EntryType.cylinder => [
      'size',
      'fullDelta',
      'emptyDelta',
      'heldDelta',
      'cylinderMode',
      'count',
      'acquireFull',
    ],
    EntryType.deposit || EntryType.depositRefund => ['amount', 'account'],
    EntryType.historicalSale => ['grams', 'amount'],
    EntryType.creditNote => [
      'sourceInvoice',
      'stockReturned',
      'quantities',
      'rate',
      'extraGrams',
    ],
  };
  return {
    for (final key in [...common, ...fields])
      if (data.containsKey(key)) key: data[key],
  };
}
