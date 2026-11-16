import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/controller.dart';
import '../core/models.dart';
import '../features/ledger/roznamcha.dart';
import '../features/reports/reports.dart';
import 'components.dart';
import 'roznamcha_widgets.dart';

/// The "Naya Entry" tabs of the original Roznamcha page, in the same order.
/// The HTML's "Opening Theek Karo" tab is left out on purpose: opening
/// balances are entered once, and a wrong entry is corrected with ✏️.
enum RozTab {
  aamad(
    'Wasooli / Sale',
    'Customer se paisay mile ya gas ki sale. Cash ya Bank wasooli. Customer ne seedha company ko diye to bank list mein "Direct to Party" chunein.',
    Icons.south_west_rounded,
  ),
  kharcha(
    'Kharcha / Payment',
    'Kharcha ya kisi ko payment (company, customer, udhar wapsi). Cash ya Bank se.',
    Icons.north_east_rounded,
  ),
  nikali(
    'Bank se Cash Nikala',
    'Bank se paisay nikal kar haath mein aaye. Cash in Hand barhti hai.',
    Icons.account_balance_outlined,
  ),
  less(
    'Less / Kami',
    'Customer ka hisab kam karna (discount / kami), ya cash kam / zyada karna bina kisi party ke.',
    Icons.content_cut_outlined,
  ),
  office(
    'Office kharcha',
    'Office ka kharcha. Kharcha (B) mein aata hai.',
    Icons.business_center_outlined,
  ),
  companyIn(
    'Company se Wasooli',
    'Company ne humein paisay diye (cash ya bank). Company ke khata mein jama.',
    Icons.business_outlined,
  );

  final String label, description;
  final IconData icon;
  const RozTab(this.label, this.description, this.icon);
  bool get spending => this == kharcha || this == office;
}

/// Kharcha types of the original page (Office has its own tab there).
enum KharchaKind {
  cash('Cash kharcha'),
  bankJama('Bank account mein jama'),
  company('Company ko payment'),
  customer('Customer ko payment'),
  udharWapsi('Udhar wapsi');

  final String label;
  const KharchaKind(this.label);
}

/// The Kharcha type that records a payment to [party], so the entry lands in
/// that party's khata: Udhar wapsi for an Udhari party, Company ko payment
/// for a company, otherwise Customer ko payment.
KharchaKind kharchaKindFor(Record party) => party.data['udhari'] == true
    ? KharchaKind.udharWapsi
    : party.data['supplier'] == true
    ? KharchaKind.company
    : KharchaKind.customer;

/// The tab that shows an entry of [form]. Opening balances and other
/// adjustments have no tab; they are corrected in their own dialog.
(RozTab, KharchaKind)? tabFor(RozForm form) => switch (form) {
  RozForm.aamad => (RozTab.aamad, KharchaKind.cash),
  RozForm.kharcha => (RozTab.kharcha, KharchaKind.cash),
  RozForm.bankJama => (RozTab.kharcha, KharchaKind.bankJama),
  RozForm.companyPay => (RozTab.kharcha, KharchaKind.company),
  RozForm.customerPay => (RozTab.kharcha, KharchaKind.customer),
  RozForm.udharWapsi => (RozTab.kharcha, KharchaKind.udharWapsi),
  RozForm.nikali => (RozTab.nikali, KharchaKind.cash),
  RozForm.less => (RozTab.less, KharchaKind.cash),
  RozForm.office => (RozTab.office, KharchaKind.cash),
  RozForm.companyIn => (RozTab.companyIn, KharchaKind.cash),
  RozForm.opening => null,
};

/// Whether the Roznamcha form can show and correct this document.
bool rozEditable(Document d) {
  final form = rozFormOf(d);
  return form != null && tabFor(form) != null;
}

/// Opens the Roznamcha entry form in a dialog (or a sheet on phones). With
/// [party] the form belongs to that party's khata: the name stays on every
/// tab, and the Kharcha tab starts on the type that pays that party.
Future<void> openRoznamchaForm(
  BuildContext context,
  AppController app, {
  RozTab tab = RozTab.aamad,
  String? party,
  Document? replace,
}) async {
  Widget form() => RoznamchaForm(
    app: app,
    initialTab: tab,
    initialParty: party,
    replace: replace,
    dialog: true,
  );
  if (MediaQuery.sizeOf(context).width < 700) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: paper,
      builder: (ctx) =>
          SizedBox(height: MediaQuery.sizeOf(ctx).height * .96, child: form()),
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: paper,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 920,
            maxHeight: MediaQuery.sizeOf(ctx).height * .9,
          ),
          child: form(),
        ),
      ),
    );
  }
}

String _plain(int minor) =>
    minor % 100 == 0 ? '${minor ~/ 100}' : decimalText(minor, 2);
String _amount(int minor) => minor == 0 ? '' : _plain(minor);
String _kgText(int grams) => grams == 0
    ? ''
    : grams % 1000 == 0
    ? '${grams ~/ 1000}'
    : decimalText(grams, 3).replaceFirst(RegExp(r'0+$'), '');

class _ExtraBank {
  final amount = TextEditingController();
  final company = TextEditingController();
  final bankName = TextEditingController();
  String account = '';
  bool direct = false;
  void dispose() {
    amount.dispose();
    company.dispose();
    bankName.dispose();
  }
}

class RoznamchaForm extends StatefulWidget {
  final AppController app;
  final RozTab initialTab;
  final String? initialParty;
  final Document? replace;
  final bool dialog;
  const RoznamchaForm({
    required this.app,
    this.initialTab = RozTab.aamad,
    this.initialParty,
    this.replace,
    this.dialog = false,
    super.key,
  });
  @override
  State<RoznamchaForm> createState() => RoznamchaFormState();
}

class RoznamchaFormState extends State<RoznamchaForm> {
  static const _keys = [
    'party',
    'vehicle',
    'q11800',
    'q15000',
    'q45000',
    'r11800',
    'r15000',
    'r45000',
    'bulk',
    'rate',
    'cash',
    'bank',
    // Direct to Party (the last choice of the Bank / Account list): the
    // company the customer paid instead of one of our banks.
    'directParty',
    'directBank',
    'amount',
    'note',
    'branch',
    'customerNote',
    'deposit',
  ];
  final c = {for (final k in _keys) k: TextEditingController()};
  final _extraBanks = <_ExtraBank>[];

  void _clearExtraBanks() {
    for (final line in _extraBanks) {
      line.dispose();
    }
    _extraBanks.clear();
  }

  ({
    TextEditingController amount,
    TextEditingController company,
    TextEditingController bankName,
    String account,
    bool direct,
  })
  _bankFields(int i) {
    if (i == 0) {
      return (
        amount: c['bank']!,
        company: c['directParty']!,
        bankName: c['directBank']!,
        account: account,
        direct: bankDirect,
      );
    }
    final l = _extraBanks[i - 1];
    return (
      amount: l.amount,
      company: l.company,
      bankName: l.bankName,
      account: l.account,
      direct: l.direct,
    );
  }

  final partyFocus = FocusNode();
  RozTab tab = RozTab.aamad;
  KharchaKind kind = KharchaKind.cash;
  bool payBank = false,
      bulkAtCost = true,
          // Bank Wasooli went to a company (Direct to Party), not to our bank.
          bankDirect =
          false,
      customerOwned = false,
      more = false,
      saving = false;
  String account = '', category = 'General';

  /// "Less kaise?": `discount` and `bank` reduce a customer's khata;
  /// `cashOut` and `cashIn` correct cash in hand with no party (cash lost,
  /// or money outside the khata), as a `money:cash` adjustment.
  String lessMode = 'discount';
  bool get lessBank => lessMode == 'bank';
  set lessBank(bool v) => lessMode = v ? 'bank' : 'discount';
  bool get lessCash => lessMode == 'cashOut' || lessMode == 'cashIn';

  /// The reference of the purchase a share comes from; '' shares the oldest
  /// stock first (FIFO).
  String sharePurchase = '';
  String dueDate = '';
  String? pickedDate, error, success;
  Json? allocations;
  final returnedEdited = <int, bool>{};
  Document? editing;
  List<Record>? _suggestFor;
  final _suggest = <String, List<String>>{};

  AppController get app => widget.app;
  String get date => pickedDate ?? editing?.date ?? app.selectedDate;
  String _draftKey(RozTab t) =>
      '${widget.dialog ? 'dialog' : 'page'}:${t.name}';

  @override
  void initState() {
    super.initState();
    tab = widget.initialTab;
    if (widget.replace != null && rozEditable(widget.replace!)) {
      edit(widget.replace!, notify: false);
    } else {
      _restore(app.rozDrafts[_draftKey(tab)]);
      if (widget.initialParty != null) {
        c['party']!.text = app.name(widget.initialParty!);
        _kindForKhata();
      }
    }
    if (c['rate']!.text.isEmpty) c['rate']!.text = _lastRate();
  }

  /// Opened from a party's khata: on the Kharcha tab, start on the type that
  /// pays this party. A type without a party field would leave the entry
  /// out of the khata, which is how a payment went missing before.
  void _kindForKhata() {
    if (widget.initialParty == null || tab != RozTab.kharcha) return;
    final party = app.partyByName(c['party']!.text);
    if (party != null) kind = kharchaKindFor(party);
  }

  @override
  void dispose() {
    _remember();
    _clearExtraBanks();
    for (final controller in c.values) {
      controller.dispose();
    }
    partyFocus.dispose();
    super.dispose();
  }

  /// The day's rate: last rate used, else the business default rate.
  String _lastRate() {
    for (final d in app.book.documents.reversed) {
      if (d.type == EntryType.sale && d.rate > 0) return _plain(d.rate);
    }
    final rate = integer(app.settings['defaultRate']);
    return rate > 0 ? _plain(rate) : '';
  }

  Json _snapshot() => {
    for (final k in _keys) k: c[k]!.text,
    'kind': kind.name,
    'payBank': payBank,
    'bulkAtCost': bulkAtCost,
    'sharePurchase': sharePurchase,
    'lessMode': lessMode,
    'bankDirect': bankDirect,
    'extraBanks': [
      for (final l in _extraBanks)
        {
          'amount': l.amount.text,
          'account': l.account,
          'direct': l.direct,
          'company': l.company.text,
          'bankName': l.bankName.text,
        },
    ],
    'customerOwned': customerOwned,
    'account': account,
    'dueDate': dueDate,
    'more': more,
    'returnedEdited': [
      for (final e in returnedEdited.entries)
        if (e.value) e.key,
    ],
  };

  void _restore(Json? s) {
    _clearExtraBanks();
    for (final l in (s?['extraBanks'] as List?) ?? const []) {
      _extraBanks.add(
        _ExtraBank()
          ..amount.text = '${l['amount'] ?? ''}'
          ..account = '${l['account'] ?? ''}'
          ..direct = l['direct'] == true
          ..company.text = '${l['company'] ?? ''}'
          ..bankName.text = '${l['bankName'] ?? ''}',
      );
    }
    for (final k in _keys) {
      if (k == 'rate' && '${s?[k] ?? ''}'.isEmpty) continue;
      c[k]!.text = '${s?[k] ?? ''}';
    }
    kind =
        KharchaKind.values.where((v) => v.name == s?['kind']).firstOrNull ??
        KharchaKind.cash;
    payBank = s?['payBank'] == true;
    bulkAtCost = s?['bulkAtCost'] != false;
    sharePurchase = '${s?['sharePurchase'] ?? ''}';
    final mode = '${s?['lessMode'] ?? ''}';
    lessMode = const ['discount', 'bank', 'cashOut', 'cashIn'].contains(mode)
        ? mode
        : 'discount';
    bankDirect = s?['bankDirect'] == true;
    customerOwned = s?['customerOwned'] == true;
    if (s != null) account = '${s['account'] ?? ''}';
    dueDate = '${s?['dueDate'] ?? ''}';
    more = s?['more'] == true;
    returnedEdited
      ..clear()
      ..addAll({
        for (final v in (s?['returnedEdited'] as List?) ?? const [])
          integer(v): true,
      });
    allocations = null;
    category = 'General';
  }

  void _remember() {
    if (editing == null) app.rozDrafts[_draftKey(tab)] = _snapshot();
  }

  void _changed() {
    if (error != null || success != null) {
      error = null;
      success = null;
    }
    _remember();
    setState(() {});
  }

  void selectTab(RozTab t) {
    if (editing != null || t == tab) return;
    _remember();
    setState(() {
      tab = t;
      error = null;
      success = null;
      final keepAccount = account, keepParty = c['party']!.text;
      _restore(app.rozDrafts[_draftKey(t)]);
      if (app.rozDrafts[_draftKey(t)] == null) account = keepAccount;
      // Inside a party's khata every tab is for that party.
      if (widget.initialParty != null && keepParty.trim().isNotEmpty) {
        c['party']!.text = keepParty;
        _kindForKhata();
      }
    });
  }

  /// Loads an existing entry into the form (HTML "✏️ Edit").
  void edit(Document d, {bool notify = true}) {
    final form = rozFormOf(d);
    final target = form == null ? null : tabFor(form);
    if (form == null || target == null) return;
    if (editing == null && notify) _remember();
    void apply() {
      final (t, k) = target;
      final data = d.data;
      editing = d;
      tab = t;
      kind = k;
      error = null;
      success = null;
      pickedDate = null;
      for (final key in _keys) {
        c[key]!.text = '';
      }
      c['party']!.text = d.party.isEmpty ? '' : app.name(d.party);
      c['note']!.text = d.note;
      c['vehicle']!.text = '${data['vehicle'] ?? ''}';
      category = '${data['category'] ?? 'General'}';
      allocations = data['allocations'] is Map
          ? Map<String, dynamic>.from(data['allocations'] as Map)
          : null;
      customerOwned = data['customerOwned'] == true;
      bulkAtCost = data['bulkAtCost'] == true;
      sharePurchase = '${data['sharePurchase'] ?? ''}';
      dueDate = '${data['dueDate'] ?? ''}';
      returnedEdited.clear();
      payBank = false;
      lessBank = false;
      bankDirect = false;
      more = false;
      account = '';
      _clearExtraBanks();
      switch (form) {
        case RozForm.aamad:
          for (final s in sizes) {
            final q = integer((data['quantities'] as Map?)?['$s']);
            final r = integer((data['returned'] as Map?)?['$s']);
            c['q$s']!.text = q == 0 ? '' : '$q';
            c['r$s']!.text = r == 0 ? '' : '$r';
            returnedEdited[s] = d.type == EntryType.sale && q != r;
          }
          c['bulk']!.text = _kgText(d.extraGrams);
          c['rate']!.text = d.rate == 0 ? _lastRate() : _plain(d.rate);
          c['deposit']!.text = _amount(d.value('depositCharge'));
          c['cash']!.text = _amount(d.value('cash'));
          final lines = d.bankLines;
          for (var i = 0; i < lines.length; i++) {
            final l = lines[i];
            if (i == 0) {
              c['bank']!.text = _amount(l.amount);
              account = l.account;
              bankDirect = l.direct;
              c['directParty']!.text = l.direct ? app.name(l.party) : '';
              c['directBank']!.text = l.bankName;
            } else {
              _extraBanks.add(
                _ExtraBank()
                  ..amount.text = _amount(l.amount)
                  ..account = l.account
                  ..direct = l.direct
                  ..company.text = l.direct ? app.name(l.party) : ''
                  ..bankName.text = l.bankName,
              );
            }
          }
          more =
              customerOwned ||
              d.value('depositCharge') != 0 ||
              dueDate.isNotEmpty ||
              d.note.isNotEmpty ||
              returnedEdited.values.any((v) => v);
        case RozForm.companyIn:
          c['cash']!.text = _amount(d.value('cash'));
          c['bank']!.text = _amount(d.value('bank'));
          account = d.bankAccount;
        case RozForm.less:
          lessBank = d.type == EntryType.receipt;
          c['amount']!.text = _amount(
            lessBank ? d.value('cash') + d.value('bank') : d.value('amount'),
          );
          account = d.bankAccount;
        case RozForm.nikali:
          c['amount']!.text = _amount(d.value('amount'));
          account = d.account;
        case RozForm.bankJama:
          c['amount']!.text = _amount(d.value('amount'));
          account = '${data['toAccount'] ?? ''}';
        case RozForm.kharcha ||
            RozForm.office ||
            RozForm.companyPay ||
            RozForm.customerPay ||
            RozForm.udharWapsi:
          c['amount']!.text = _amount(d.value('amount'));
          payBank = d.account != 'cash';
          account = payBank ? d.account : '';
          c['branch']!.text = '${data['branch'] ?? ''}';
          c['customerNote']!.text = '${data['customerNote'] ?? ''}';
        case RozForm.opening:
          // No tab: opening balances are corrected in their own dialog.
          break;
      }
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  void cancelEdit() {
    if (widget.dialog && widget.replace != null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      editing = null;
      error = null;
      success = null;
      _restore(app.rozDrafts[_draftKey(tab)]);
      if (c['rate']!.text.isEmpty) c['rate']!.text = _lastRate();
    });
  }

  int _money(String key) => decimal(c[key]!.text, 2);
  int _count(String key) => decimal(c[key]!.text, 0);
  int _grams(String key) => decimal(c[key]!.text, 3);
  int _try(int Function() f) {
    try {
      return f();
    } catch (_) {
      return 0;
    }
  }

  PartyRole get _role => switch (tab) {
    RozTab.companyIn => PartyRole.company,
    RozTab.kharcha when kind == KharchaKind.company => PartyRole.company,
    RozTab.kharcha when kind == KharchaKind.udharWapsi => PartyRole.udhari,
    _ => PartyRole.customer,
  };

  bool get _usesParty => switch (tab) {
    RozTab.aamad || RozTab.companyIn => true,
    RozTab.less => !lessCash,
    RozTab.kharcha =>
      kind == KharchaKind.company ||
          kind == KharchaKind.customer ||
          kind == KharchaKind.udharWapsi,
    _ => false,
  };

  /// Opened from a party's khata, but this tab or Kharcha type has no party:
  /// says the entry will not reach the khata, and which type would.
  String? _notInKhata() {
    if (widget.initialParty == null || editing != null || _usesParty) {
      return null;
    }
    final name = c['party']!.text.trim();
    if (name.isEmpty) return null;
    final warning = context
        .t('Yeh entry {name} ke khata mein nahi jayegi.')
        .replaceAll('{name}', name);
    final party = app.partyByName(name);
    if (tab != RozTab.kharcha || party == null) return warning;
    final type = context.t(kharchaKindFor(party).label);
    return '$warning ${context.t('Khata ke liye "{type}" chunein.').replaceAll('{type}', type)}';
  }

  /// Builds the document exactly as the HTML form would record it.
  (Json, List<Change>) _build() {
    final before = <Change>[];
    final partyIds = <String, String>{};
    // [field] is the name field read: the entry's party, or the party a
    // customer paid directly.
    String partyId(PartyRole role, {String field = 'party', String? name}) {
      final text = (name ?? c[field]!.text).trim();
      if (text.isEmpty) {
        throw FormatException(
          field == 'directParty'
              ? 'Direct to Party ke liye party ka naam likhein'
              : switch (role) {
                  PartyRole.company => 'Company ka naam likhein',
                  PartyRole.udhari => 'Udhari party ka naam likhein',
                  PartyRole.customer => 'Customer / Party ka naam likhein',
                },
        );
      }
      final nameKey = AppController.nameKey(text);
      if (partyIds.containsKey(nameKey)) return partyIds[nameKey]!;
      final found = app.partyByName(text);
      if (found != null) {
        partyIds[nameKey] = found.id;
        if (found.archived || !role.fits(found)) {
          before.add(
            Change(found.id, 'party', {
              ...found.data,
              'archived': false,
              role.flag: true,
            }, found.version),
          );
        }
        return found.id;
      }
      final id = uuid.v4();
      partyIds[nameKey] = id;
      before.add(
        Change(id, 'party', {
          'name': text.replaceAll(RegExp(r'\s+'), ' '),
          'phone': '',
          'address': '',
          'customer': role == PartyRole.customer,
          'supplier': role == PartyRole.company,
          'udhari': role == PartyRole.udhari,
          'archived': false,
        }, 0),
      );
      return id;
    }

    String bankAccount(String message) {
      if (account.isEmpty || app.record(account) == null) {
        throw FormatException(message);
      }
      return account;
    }

    final note = c['note']!.text.trim();
    final base = <String, dynamic>{
      'date': date,
      'note': note,
      'occurredAt': editing == null
          ? DateTime.now().millisecondsSinceEpoch
          : integer(editing!.data['occurredAt']),
    };
    Json keepAllocations(int collected) {
      final a = allocations;
      if (a == null) return const {};
      final sum = a.values.fold(0, (v, x) => v + integer(x));
      return sum <= collected ? {'allocations': a} : const {};
    }

    switch (tab) {
      case RozTab.aamad:
        final q = {for (final s in sizes) s: _count('q$s')};
        final grams = sizes.fold(0, (v, s) => v + s * q[s]!);
        final bulk = _grams('bulk'), rate = _money('rate');
        final cash = _money('cash');
        // Keep each nonzero destination in the order entered.
        final lines = <Json>[];
        var lineTotal = 0;
        for (var i = 0; i <= _extraBanks.length; i++) {
          final l = _bankFields(i);
          final amount = decimal(l.amount.text, 2);
          if (amount < 0) {
            throw const FormatException(
              'Amounts and quantities cannot be negative',
            );
          }
          if (amount == 0) continue;
          lineTotal += amount;
          if (l.direct) {
            if (AppController.nameKey(l.company.text) ==
                    AppController.nameKey(c['party']!.text) &&
                l.company.text.trim().isNotEmpty) {
              throw const FormatException(
                'Direct to Party ke liye customer se alag party chunein',
              );
            }
            lines.add({
              'amount': amount,
              'party': partyId(
                PartyRole.company,
                field: 'directParty',
                name: l.company.text,
              ),
              'bankName': l.bankName.text.trim(),
            });
          } else {
            if (l.account.isEmpty || app.record(l.account) == null) {
              throw const FormatException(
                'Bank wasooli ke liye bank / account chunein',
              );
            }
            lines.add({'amount': amount, 'account': l.account});
          }
        }
        final deposit = customerOwned ? 0 : _money('deposit');
        if (q.values.any((v) => v < 0) ||
            bulk < 0 ||
            rate < 0 ||
            cash < 0 ||
            deposit < 0) {
          throw const FormatException(
            'Amounts and quantities cannot be negative',
          );
        }
        if (grams == 0 && bulk == 0 && cash == 0 && lineTotal == 0) {
          throw const FormatException(
            'Kam az kam wasooli ya cylinders darj karein',
          );
        }
        if ((grams > 0 || (bulk > 0 && !bulkAtCost)) && rate == 0) {
          throw const FormatException('Rate likhein (11.8 KG ka)');
        }
        if (grams == 0 && bulk == 0 && deposit > 0) {
          throw const FormatException('Zamanat sirf cylinders ke saath');
        }
        final pid = partyId(PartyRole.customer);
        final single = lines.length == 1 ? lines.single : null;
        final common = {
          ...base,
          'party': pid,
          'vehicle': c['vehicle']!.text.trim(),
          'cash': cash,
          'bank': single?.containsKey('account') == true
              ? single!['amount']
              : 0,
          'bankAccount': single?['account'] ?? '',
          'direct': single?.containsKey('party') == true
              ? single!['amount']
              : 0,
          'directParty': single?['party'] ?? '',
          if (lines.length > 1 || single?.containsKey('party') == true)
            'directBank': single?['bankName'] ?? '',
          if (lines.length > 1) 'bankLines': lines,
          'form': RozForm.aamad.name,
          ...keepAllocations(cash + lineTotal),
        };
        if (grams == 0 && bulk == 0) {
          return ({'type': 'receipt', ...common}, before);
        }
        return (
          {
            'type': 'sale',
            ...common,
            'quantities': {for (final s in sizes) '$s': q[s]},
            'returned': {
              for (final s in sizes)
                '$s': customerOwned
                    ? 0
                    : returnedEdited[s] == true
                    ? _count('r$s')
                    : q[s],
            },
            'rate': rate,
            'extraGrams': bulk,
            if (bulk > 0 && bulkAtCost) 'bulkAtCost': true,
            if (bulk > 0 && bulkAtCost && sharePurchase.isNotEmpty)
              'sharePurchase': sharePurchase,
            'depositCharge': deposit,
            'customerOwned': customerOwned,
            'dueDate': dueDate,
          },
          before,
        );
      case RozTab.kharcha || RozTab.office:
        final amount = _money('amount');
        if (amount <= 0) {
          throw const FormatException('Raqam likhna zaroori hai');
        }
        final bankJama = tab == RozTab.kharcha && kind == KharchaKind.bankJama;
        final from = bankJama || !payBank
            ? 'cash'
            : bankAccount('Bank / account chunein');
        if (tab == RozTab.office ||
            (tab == RozTab.kharcha && kind == KharchaKind.cash)) {
          if (note.isEmpty) {
            throw const FormatException('Tafseel likhna zaroori hai');
          }
          final office = tab == RozTab.office;
          return (
            {
              'type': 'expense',
              ...base,
              'amount': amount,
              'account': from,
              'category': office
                  ? 'Office'
                  : (category == 'Office' ? 'General' : category),
              'form': office ? RozForm.office.name : RozForm.kharcha.name,
            },
            before,
          );
        }
        if (bankJama) {
          return (
            {
              'type': 'transfer',
              ...base,
              'amount': amount,
              'account': 'cash',
              'toAccount': bankAccount('Bank / account chunein'),
              'form': RozForm.bankJama.name,
            },
            before,
          );
        }
        final company = kind == KharchaKind.company;
        final udhar = kind == KharchaKind.udharWapsi;
        return (
          {
            'type': 'payment',
            ...base,
            'party': partyId(_role),
            'amount': amount,
            'account': from,
            // Udhar wapsi reduces what you owe the party, like a company
            // payment; only the form (display) tells them apart.
            'supplierPayment': company || udhar,
            if (company) 'branch': c['branch']!.text.trim(),
            if (company) 'customerNote': c['customerNote']!.text.trim(),
            'form': company
                ? RozForm.companyPay.name
                : udhar
                ? RozForm.udharWapsi.name
                : RozForm.customerPay.name,
          },
          before,
        );
      case RozTab.nikali:
        final from = bankAccount('Bank / account chunein');
        final amount = _money('amount');
        if (amount <= 0) {
          throw const FormatException('Raqam likhna zaroori hai');
        }
        return (
          {
            'type': 'transfer',
            ...base,
            'amount': amount,
            'account': from,
            'toAccount': 'cash',
            'form': RozForm.nikali.name,
          },
          before,
        );
      case RozTab.less:
        if (lessCash) {
          // Cash short or over with no party: only cash in hand changes.
          final amount = _money('amount');
          if (amount <= 0) {
            throw const FormatException('Raqam likhna zaroori hai');
          }
          if (note.isEmpty) {
            throw const FormatException('Wajah likhna zaroori hai');
          }
          return (
            {
              'type': 'adjustment',
              ...base,
              'target': 'money:cash',
              'amount': lessMode == 'cashOut' ? -amount : amount,
            },
            before,
          );
        }
        final pid = partyId(PartyRole.customer);
        final amount = _money('amount');
        if (amount <= 0) {
          throw const FormatException('Less ki raqam likhein');
        }
        if (lessBank) {
          return (
            {
              'type': 'receipt',
              ...base,
              'party': pid,
              'cash': 0,
              'bank': amount,
              'bankAccount': bankAccount('Bank / account chunein'),
              'form': RozForm.less.name,
              ...keepAllocations(amount),
            },
            before,
          );
        }
        return (
          {
            'type': 'discount',
            ...base,
            'party': pid,
            'amount': amount,
            'form': RozForm.less.name,
          },
          before,
        );
      case RozTab.companyIn:
        final cash = _money('cash'), bank = _money('bank');
        if (cash < 0 || bank < 0) {
          throw const FormatException(
            'Amounts and quantities cannot be negative',
          );
        }
        if (cash == 0 && bank == 0) {
          throw const FormatException('Cash ya Bank wasooli likhein');
        }
        return (
          {
            'type': 'receipt',
            ...base,
            'party': partyId(PartyRole.company),
            'cash': cash,
            'bank': bank,
            'bankAccount': bank > 0
                ? bankAccount('Bank wasooli ke liye bank / account chunein')
                : '',
            'supplierRefund': true,
            'form': RozForm.companyIn.name,
          },
          before,
        );
    }
  }

  Future<void> save() async {
    if (saving) return;
    setState(() {
      error = null;
      success = null;
    });
    final Json data;
    final List<Change> before;
    try {
      (data, before) = _build();
    } catch (e) {
      setState(() => error = errorText(context, e));
      return;
    }
    final replace = editing;
    var reason = '';
    if (replace != null) {
      reason = (await askText(context, 'Reason for correction'))?.trim() ?? '';
      if (reason.isEmpty || !mounted) return;
    }
    setState(() => saving = true);
    try {
      await app.post(data, replace: replace, reason: reason, before: before);
      if (!mounted) return;
      final summary = _summary(data);
      app.rozDrafts.remove(_draftKey(tab));
      if (replace != null && widget.dialog) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${context.t('Update ho gaya')}: $summary')),
        );
        Navigator.pop(context);
        return;
      }
      setState(() {
        final wasEditing = replace != null;
        editing = null;
        _clearAfterSave();
        success =
            '${context.t(wasEditing ? 'Update ho gaya' : 'Save ho gaya')}: $summary';
      });
      if (_usesParty && MediaQuery.sizeOf(context).width >= 700) {
        partyFocus.requestFocus();
      }
    } catch (e) {
      if (mounted) setState(() => error = errorText(context, e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  /// Which purchase a share comes from: oldest stock first (FIFO), or one
  /// purchase, charged at that purchase's own rate.
  Widget _sharePurchasePicker() {
    final options = app.sharePurchaseOptions(
      date,
      replace: editing,
      selected: sharePurchase,
    );
    final known = options.any((o) => o.$1.data['reference'] == sharePurchase);
    return KeyedSubtree(
      key: const ValueKey('roz-share-purchase'),
      child: Labeled(
        context.t('Share from'),
        DropdownButtonFormField<String>(
          key: ValueKey('roz-share-purchase-$sharePurchase-${options.length}'),
          initialValue: known ? sharePurchase : '',
          isExpanded: true,
          isDense: true,
          decoration: rozDecoration(null),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(
                context.t('Oldest stock first (FIFO)'),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5),
              ),
            ),
            for (final (p, free) in options)
              DropdownMenuItem(
                value: '${p.data['reference']}',
                child: Text(
                  '${dmy(p.date)} · ${app.name(p.party)} · '
                  '${kg(p.value('grams'))} KG '
                  '(${context.t('free')} ${kg(free)})',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
          ],
          onChanged: (v) {
            sharePurchase = v ?? '';
            _changed();
          },
        ),
      ),
    );
  }

  void _clearAfterSave() {
    _clearExtraBanks();
    final rate = c['rate']!.text, party = c['party']!.text;
    for (final k in _keys) {
      c[k]!.text = '';
    }
    c['rate']!.text = rate.isEmpty ? _lastRate() : rate;
    // Inside a party's khata the next entry is for the same party.
    if (widget.initialParty != null) c['party']!.text = party;
    customerOwned = false;
    // Each new bulk entry starts as a purchase share again, even after an
    // old ordinary bulk sale was corrected or one was saved with it off.
    bulkAtCost = true;
    sharePurchase = '';
    // The bank stays chosen for the next customer; Direct to Party does not.
    bankDirect = false;
    more = false;
    dueDate = '';
    allocations = null;
    returnedEdited.clear();
    category = 'General';
  }

  String _summary(Json data) {
    final party = '${data['party'] ?? ''}';
    final name = party.isEmpty
        ? context.t(tab == RozTab.kharcha ? kind.label : tab.label)
        : (app.record(party)?.name ?? c['party']!.text.trim());
    final doc = Document(
      Record('preview', 'document', cleanDocumentData(data)),
    );
    final value = doc.type == EntryType.receipt ? doc.collected : doc.total;
    return '$name · ${rs(value)}';
  }

  // ---------- previews ----------

  String _partyBalance(int value, PartyRole role) {
    if (value == 0) return 'Rs 0';
    if (role.payable) {
      return value > 0
          ? '${context.t('Dena')} ${money(value)}'
          : '${context.t(role == PartyRole.udhari ? 'Lena' : 'Advance')} ${money(-value)}';
    }
    return value > 0
        ? '${context.t('Lena')} ${money(value)}'
        : '${context.t('Dena')} ${money(-value)}';
  }

  int _postingEffect(Document d, String account) => app.book.postings
      .where((p) => p.document == d.id && p.account == account)
      .fold(0, (v, p) => v + p.debit);

  /// What [d] moved in [party]'s khata, both sides (`ar:` and `ap:`).
  int _partyEffect(Document d, String party) =>
      _postingEffect(d, 'ar:$party') + _postingEffect(d, 'ap:$party');

  /// Customer / company balance before → after this entry. It is the whole
  /// khata balance, both sides, as on the Parties page: a customer you owe
  /// (an opening payable or an advance) reads "Dena", not Rs 0.
  String? _balancePreview(int newEffect) {
    final party = app.partyByName(c['party']!.text);
    if (party == null) return null;
    final role = _role;
    final sign = role.payable ? -1 : 1;
    final now = sign * app.book.partyBalance(party.id);
    final old = editing == null ? 0 : sign * _partyEffect(editing!, party.id);
    final after = now - old + newEffect;
    return '${context.t('Baqaya')}: ${_partyBalance(now, role)}  →  ${_partyBalance(after, role)}';
  }

  /// What we owe the company a customer paid directly, before → after.
  String _directPreview(String name, int direct) {
    final party = app.partyByName(name);
    final id = party?.id ?? '';
    final now = -app.book.partyBalance(id);
    final old = editing == null ? 0 : -_partyEffect(editing!, id);
    return '${party?.name ?? name.trim()}: ${_partyBalance(now, PartyRole.company)}  →  ${_partyBalance(now - old - direct, PartyRole.company)}';
  }

  String? _accountPreview(String id, int change) {
    if (id.isEmpty || app.record(id) == null) return null;
    final now = app.book.money(id);
    final old = editing == null ? 0 : _postingEffect(editing!, 'money:$id');
    return '${accountLabel(app.record(id)!)}: ${rs(now)}  →  ${rs(now - old + change)}';
  }

  Widget _previewLine(List<Widget> parts) => Wrap(
    spacing: 10,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: parts,
  );

  Widget _previewText(String text, {Color color = teal}) => Text(
    text,
    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color),
  );

  Widget? _preview() {
    switch (tab) {
      case RozTab.aamad:
        final grams = sizes.fold(
          0,
          (v, s) => v + s * _try(() => _count('q$s')),
        );
        final bulk = _try(() => _grams('bulk'));
        final rate = _try(() => _money('rate'));
        final deposit = customerOwned ? 0 : _try(() => _money('deposit'));
        var bill = rate > 0 && grams + bulk > 0
            ? multiplyDivide(grams + bulk, rate, 1180000) * 100
            : 0;
        int? shareCost;
        String? costError;
        if (bulk > 0 && bulkAtCost) {
          try {
            shareCost = app.quoteBulkCost({
              'date': date,
              if (editing != null) 'occurredAt': editing!.value('occurredAt'),
              'quantities': {
                for (final s in sizes) '$s': _try(() => _count('q$s')),
              },
              'extraGrams': bulk,
              if (sharePurchase.isNotEmpty) 'sharePurchase': sharePurchase,
            }, replace: editing);
          } catch (e) {
            costError = errorText(context, e);
          }
          bill = multiplyDivide(grams, rate, 1180000) * 100 + (shareCost ?? 0);
        }
        final total = bill + (grams + bulk > 0 ? deposit : 0);
        final cash = _try(() => _money('cash'));
        var bank = 0;
        final companies = <String, (String, int)>{};
        for (var i = 0; i <= _extraBanks.length; i++) {
          final l = _bankFields(i),
              amount = _try(() => decimal(_bankFields(i).amount.text, 2));
          bank += amount;
          if (l.direct && amount > 0 && l.company.text.trim().isNotEmpty) {
            final key = AppController.nameKey(l.company.text);
            companies.update(
              key,
              (v) => (v.$1, v.$2 + amount),
              ifAbsent: () => (l.company.text, amount),
            );
          }
        }
        final balance = costError == null
            ? _balancePreview(total - cash - bank)
            : null;
        return _previewLine([
          if (grams + bulk > 0)
            _previewText(
              '${context.t('Total Gas')}: ${kg(grams + bulk)} kg${bill > 0 ? '  |  ${context.t('Bill')}: ${rs(total)}' : ''}',
            ),
          if (shareCost != null)
            _previewText(
              '${context.t('Purchase share (at cost)')}: ${rs(shareCost)}',
            ),
          if (costError != null) _previewText(costError, color: amber),
          if (total > 0 && costError == null) ...[
            OutlinedButton(
              style: _smallButton,
              onPressed: () {
                c['cash']!.text = _plain(total);
                c['bank']!.clear();
                _clearExtraBanks();
                _changed();
              },
              child: Text(context.t('Cash mein dalein')),
            ),
            OutlinedButton(
              style: _smallButton,
              onPressed: () {
                c['bank']!.text = _plain(total);
                c['cash']!.clear();
                _clearExtraBanks();
                _changed();
              },
              child: Text(context.t('Bank mein dalein')),
            ),
          ],
          if ((grams > 0 || (bulk > 0 && !bulkAtCost)) && rate == 0)
            _previewText(context.t('Rate likhein (11.8 KG ka)'), color: amber),
          if (balance != null) _previewText(balance, color: ink),
          for (final company in companies.values)
            _previewText(_directPreview(company.$1, company.$2), color: ink),
        ]);
      case RozTab.kharcha:
        final amount = _try(() => _money('amount'));
        final lines = <String?>[
          if (kind == KharchaKind.company || kind == KharchaKind.udharWapsi)
            _balancePreview(-amount),
          if (kind == KharchaKind.customer) _balancePreview(amount),
          if (kind == KharchaKind.bankJama) _accountPreview(account, amount),
          if (kind != KharchaKind.bankJama && payBank)
            _accountPreview(account, -amount),
        ];
        return _previewLine([
          for (final l in lines.whereType<String>())
            _previewText(l, color: ink),
        ]);
      case RozTab.office:
        if (!payBank) return null;
        final line = _accountPreview(account, -_try(() => _money('amount')));
        return line == null ? null : _previewText(line, color: ink);
      case RozTab.nikali:
        final line = _accountPreview(account, -_try(() => _money('amount')));
        return line == null ? null : _previewText(line, color: ink);
      case RozTab.less:
        final amount = _try(() => _money('amount'));
        if (lessCash) {
          final line = _accountPreview(
            'cash',
            lessMode == 'cashOut' ? -amount : amount,
          );
          return line == null ? null : _previewText(line, color: ink);
        }
        return _previewLine([
          if (_balancePreview(-amount) case final b?)
            _previewText(b, color: ink),
          if (lessBank)
            if (_accountPreview(account, amount) case final a?)
              _previewText(a, color: ink),
        ]);
      case RozTab.companyIn:
        final total = _try(() => _money('cash')) + _try(() => _money('bank'));
        final line = _balancePreview(total);
        return line == null ? null : _previewText(line, color: ink);
    }
  }

  static final _smallButton = OutlinedButton.styleFrom(
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    textStyle: const TextStyle(fontSize: 12),
  );

  // ---------- suggestions (HTML datalists) ----------

  List<String> _suggestions(String kind) {
    if (!identical(_suggestFor, app.records)) {
      _suggestFor = app.records;
      _suggest.clear();
      final notes = <String>{},
          office = <String>{},
          branches = <String>{},
          banks = <String>{};
      for (final d in app.book.documents.reversed) {
        for (final l in d.bankLines) {
          if (l.direct && l.bankName.trim().isNotEmpty) {
            banks.add(l.bankName.trim());
          }
        }
        if (d.note.isNotEmpty &&
            [EntryType.expense, EntryType.payment].contains(d.type)) {
          (d.data['category'] == 'Office' ? office : notes).add(d.note);
        }
        final branch = '${d.data['branch'] ?? ''}';
        if (branch.isNotEmpty) branches.add(branch);
      }
      _suggest['note'] = notes.take(300).toList();
      _suggest['office'] = office.take(300).toList();
      _suggest['branch'] = branches.take(100).toList();
      _suggest['directBank'] = banks.take(100).toList();
    }
    return _suggest[kind] ?? const [];
  }

  // ---------- fields ----------

  PartyInput _party(String label) => PartyInput(
    app: app,
    label: label,
    controller: c['party']!,
    role: _role,
    focusNode: partyFocus,
    onChanged: (_) => _changed(),
  );

  RozInput _input(
    String label,
    String key, {
    String? hint,
    bool number = true,
    int decimals = 2,
    bool submit = false,
    ValueChanged<String>? onChanged,
  }) => RozInput(
    label,
    c[key]!,
    key: ValueKey('roz-$key'),
    hint: hint,
    number: number,
    decimals: decimals,
    onSubmitted: submit ? save : null,
    onChanged: (v) {
      onChanged?.call(v);
      _changed();
    },
  );

  AccountPicker _account(String label) => AccountPicker(
    app: app,
    label: label,
    value: account,
    onChanged: (v) {
      account = v;
      _changed();
    },
  );

  static const _directChoice = '__direct_to_party__';

  /// Where the Bank Wasooli went: one of our banks, or (the last choice)
  /// Direct to Party, which swaps the list for a company field in its place.
  Widget _bankOrDirect([int i = 0]) {
    final l = _bankFields(i);
    final suffix = i == 0 ? '' : '-$i';
    void chooseDirect(bool direct) {
      if (i == 0) {
        bankDirect = direct;
      } else {
        _extraBanks[i - 1].direct = direct;
      }
      _changed();
    }

    if (!l.direct) {
      return AccountPicker(
        key: i == 0 ? null : ValueKey('roz-account-$i'),
        app: app,
        label: 'Bank / Account',
        value: l.account,
        extra: const [(_directChoice, 'Direct to Party')],
        onChanged: (v) {
          if (v == _directChoice) {
            chooseDirect(true);
          } else {
            if (i == 0) {
              account = v;
            } else {
              _extraBanks[i - 1].account = v;
            }
            _changed();
          }
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PartyInput(
                app: app,
                label: 'Direct to Party: kis company ko?',
                controller: l.company,
                role: PartyRole.company,
                fieldKey: ValueKey('roz-direct-party$suffix'),
                onChanged: (_) => _changed(),
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: IconButton(
                key: ValueKey('roz-back-to-banks$suffix'),
                tooltip: context.t('Wapas bank list'),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  chooseDirect(false);
                },
                icon: const Icon(
                  Icons.account_balance_outlined,
                  size: 20,
                  color: teal,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SuggestInput(
          'Kis bank mein? (company ka)',
          l.bankName,
          _suggestions('directBank'),
          key: ValueKey('roz-direct-bank$suffix'),
          hint: 'e.g. UBL',
          onChanged: (_) => _changed(),
        ),
      ],
    );
  }

  RozSelect _payFrom() => RozSelect(
    'Kis se diye?',
    payBank ? 'bank' : 'cash',
    const [
      ('cash', 'Cash (haath ki cash se)'),
      ('bank', 'Bank se (cash par asar nahi)'),
    ],
    (v) {
      payBank = v == 'bank';
      _changed();
    },
  );

  List<GridItem> _fields() {
    switch (tab) {
      case RozTab.aamad:
        final bank = _try(() => _money('bank'));
        return [
          GridItem(_party('Customer / Party'), span: 2),
          GridItem(
            _input('Parchi / Van', 'vehicle', hint: 'e.g. 92', number: false),
          ),
          for (final s in sizes)
            GridItem(
              _input(
                sizeLabel(s),
                'q$s',
                hint: '0',
                decimals: 0,
                onChanged: (v) {
                  if (returnedEdited[s] != true) c['r$s']!.text = v;
                },
              ),
            ),
          GridItem(_input('Bulk KG', 'bulk', hint: '0', decimals: 3)),
          if (_try(() => _grams('bulk')) > 0)
            GridItem(
              Material(
                color: Colors.transparent,
                child: SwitchListTile(
                  key: const ValueKey('roz-share-at-cost'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.t('Share bulk at purchase cost')),
                  subtitle: Text(
                    context.t(
                      'Not our sale; the party pays our purchase price.',
                    ),
                  ),
                  value: bulkAtCost,
                  onChanged: (v) {
                    bulkAtCost = v;
                    _changed();
                  },
                ),
              ),
              span: 2,
            ),
          if (bulkAtCost && _try(() => _grams('bulk')) > 0)
            GridItem(_sharePurchasePicker(), span: 2),
          if (!(bulkAtCost &&
              _try(() => _grams('bulk')) > 0 &&
              sizes.every((s) => _try(() => _count('q$s')) == 0)))
            GridItem(_input('Rate (11.8 KG)', 'rate', hint: 'Rate')),
          GridItem(_input('Cash Wasooli', 'cash', hint: 'Rs. 0')),
          GridItem(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _input(
                    'Bank Wasooli',
                    'bank',
                    hint: 'Rs. 0',
                    submit: bank == 0,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: IconButton(
                    key: const ValueKey('roz-add-bank'),
                    tooltip: context.t('Aur bank wasooli'),
                    onPressed: () {
                      _extraBanks.add(_ExtraBank());
                      _changed();
                    },
                    icon: const Icon(Icons.add_circle_outline, color: teal),
                  ),
                ),
              ],
            ),
          ),
          if (bank > 0) GridItem(_bankOrDirect(), span: 2),
          for (var i = 1; i <= _extraBanks.length; i++) ...[
            GridItem(
              KeyedSubtree(
                key: ObjectKey(_extraBanks[i - 1]),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: RozInput(
                        '${context.t('Bank Wasooli')} ${i + 1}',
                        _extraBanks[i - 1].amount,
                        key: ValueKey('roz-bank-$i'),
                        hint: 'Rs. 0',
                        onChanged: (_) => _changed(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: IconButton(
                        key: ValueKey('roz-remove-bank-$i'),
                        tooltip: context.t('Hatayein'),
                        onPressed: () {
                          _extraBanks.removeAt(i - 1).dispose();
                          _changed();
                        },
                        icon: const Icon(
                          Icons.remove_circle_outline,
                          color: rozRed,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_try(() => decimal(_extraBanks[i - 1].amount.text, 2)) > 0)
              GridItem(
                KeyedSubtree(
                  key: ObjectKey(_extraBanks[i - 1].company),
                  child: _bankOrDirect(i),
                ),
                span: 2,
              ),
          ],
        ];
      case RozTab.kharcha:
        return [
          GridItem(
            RozSelect(
              'Kharcha type',
              kind.name,
              [for (final k in KharchaKind.values) (k.name, k.label)],
              (v) {
                kind = KharchaKind.values.byName(v);
                // A name typed for another role is not carried into a
                // company or Udhari field, so saving cannot quietly turn a
                // customer into one. Inside a khata the name always stays.
                final typed = app.partyByName(c['party']!.text);
                if (widget.initialParty == null &&
                    _role.payable &&
                    (typed == null || !_role.fits(typed))) {
                  c['party']!.clear();
                }
                _changed();
              },
            ),
            span: 2,
          ),
          if (kind != KharchaKind.bankJama) GridItem(_payFrom()),
          if (kind == KharchaKind.bankJama || payBank)
            GridItem(
              _account(
                kind == KharchaKind.bankJama
                    ? 'Kis account mein?'
                    : 'Kis account se?',
              ),
              span: 2,
            ),
          if (kind == KharchaKind.company) GridItem(_party('Company'), span: 2),
          if (kind == KharchaKind.customer)
            GridItem(_party('Customer'), span: 2),
          if (kind == KharchaKind.udharWapsi)
            GridItem(_party('Udhari party'), span: 2),
          GridItem(
            SuggestInput(
              kind == KharchaKind.cash ? 'Tafseel' : 'Tafseel (optional)',
              c['note']!,
              _suggestions('note'),
              key: const ValueKey('roz-note'),
              hint: 'Tafseel...',
              onChanged: (_) => _changed(),
            ),
            span: 2,
          ),
          if (kind == KharchaKind.company) ...[
            GridItem(
              _input(
                'Customer (kis ke liye)',
                'customerNote',
                number: false,
                hint: 'Customer...',
              ),
            ),
            GridItem(
              SuggestInput(
                'Branch',
                c['branch']!,
                _suggestions('branch'),
                key: const ValueKey('roz-branch'),
                hint: 'Branch...',
                onChanged: (_) => _changed(),
              ),
            ),
          ],
          GridItem(_input('Raqam', 'amount', hint: 'Rs. 0', submit: true)),
        ];
      case RozTab.nikali:
        return [
          GridItem(_account('Kis account se? (Bank)'), span: 2),
          GridItem(
            _input(
              'Tafseel (optional)',
              'note',
              number: false,
              hint: 'Tafseel...',
            ),
            span: 2,
          ),
          GridItem(_input('Raqam', 'amount', hint: 'Rs. 0', submit: true)),
        ];
      case RozTab.less:
        return [
          if (!lessCash) GridItem(_party('Customer'), span: 2),
          GridItem(
            RozSelect(
              'Less kaise?',
              lessMode,
              const [
                ('discount', 'Khata se minus (discount)'),
                ('bank', 'Bank deposit (account mein jama)'),
                ('cashOut', 'Cash kam (nuqsan / khata se bahar)'),
                ('cashIn', 'Cash zyada (izafa)'),
              ],
              (v) {
                lessMode = v;
                _changed();
              },
            ),
            span: lessCash ? 2 : 1,
          ),
          if (lessBank) GridItem(_account('Kis account mein?'), span: 2),
          GridItem(
            _input(
              lessCash ? 'Wajah (zaroori)' : 'Tafseel (optional)',
              'note',
              number: false,
              hint: 'Tafseel...',
            ),
            span: 2,
          ),
          GridItem(
            _input(
              lessCash ? 'Raqam' : 'Less Raqam',
              'amount',
              hint: 'Rs. 0',
              submit: true,
            ),
          ),
        ];
      case RozTab.office:
        return [
          GridItem(
            SuggestInput(
              'Tafseel',
              c['note']!,
              _suggestions('office'),
              key: const ValueKey('roz-note'),
              hint: 'Office kharcha tafseel...',
              onChanged: (_) => _changed(),
            ),
            span: 3,
          ),
          GridItem(_payFrom()),
          if (payBank) GridItem(_account('Kis account se?'), span: 2),
          GridItem(_input('Raqam', 'amount', hint: 'Rs. 0', submit: true)),
        ];
      case RozTab.companyIn:
        final bank = _try(() => _money('bank'));
        return [
          GridItem(_party('Company'), span: 2),
          GridItem(_input('Cash', 'cash', hint: 'Rs. 0')),
          GridItem(_input('Bank Wasooli', 'bank', hint: 'Rs. 0')),
          if (bank > 0) GridItem(_account('Kis account mein?'), span: 2),
          GridItem(
            _input(
              'Tafseel',
              'note',
              number: false,
              hint: 'Tafseel...',
              submit: true,
            ),
            span: 2,
          ),
        ];
    }
  }

  Widget _more() {
    final open = more;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () {
              more = !more;
              _changed();
            },
            icon: Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
            label: Text(
              context.t(
                'Aur options (khali cylinder, zamanat, tareekh, tafseel)',
              ),
            ),
          ),
          if (open)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: rozBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Own Material so the tap ripple isn't hidden behind the
                  // white box decoration above.
                  Material(
                    type: MaterialType.transparency,
                    child: SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.t('Customer-owned cylinders')),
                      value: customerOwned,
                      onChanged: (v) {
                        customerOwned = v;
                        _changed();
                      },
                    ),
                  ),
                  FormGrid([
                    if (!customerOwned) ...[
                      for (final s in sizes)
                        GridItem(
                          _input(
                            '${context.t('Khali wapas')} ${sizeLabel(s)}',
                            'r$s',
                            hint: '0',
                            decimals: 0,
                            onChanged: (_) => returnedEdited[s] = true,
                          ),
                        ),
                      GridItem(
                        _input('Deposit charged', 'deposit', hint: 'Rs. 0'),
                      ),
                    ],
                    GridItem(
                      Labeled(
                        'Due date',
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            alignment: AlignmentDirectional.centerStart,
                          ),
                          onPressed: () async {
                            final v = await pickDate(
                              context,
                              dueDate.isEmpty ? date : dueDate,
                            );
                            if (v != null) {
                              dueDate = v;
                              _changed();
                            }
                          },
                          icon: const Icon(Icons.event_outlined, size: 17),
                          label: Text(dueDate.isEmpty ? '—' : dmy(dueDate)),
                        ),
                      ),
                    ),
                    GridItem(
                      _input(
                        'Tafseel (optional)',
                        'note',
                        number: false,
                        hint: 'Tafseel...',
                      ),
                      span: 2,
                    ),
                  ]),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabs() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final t in RozTab.values)
        if (editing == null || t == tab)
          Material(
            color: t == tab ? (t.spending ? amber : teal) : Colors.white,
            shape: StadiumBorder(
              side: BorderSide(
                color: t == tab ? (t.spending ? amber : teal) : rozBorder,
              ),
            ),
            child: InkWell(
              key: ValueKey('roz-tab-${t.name}'),
              customBorder: const StadiumBorder(),
              onTap: () => selectTab(t),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      t.icon,
                      size: 16,
                      color: t == tab ? Colors.white : teal,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      context.t(t.label),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: t == tab ? Colors.white : ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
    ],
  );

  Widget _body() {
    final preview = _preview();
    final notInKhata = _notInKhata();
    final closed = app.isClosed(date);
    final accent = tab.spending ? amber : teal;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): save,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: _tabs(),
          ),
          if (editing != null)
            Container(
              color: rozAccentSoft,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.edit_note_rounded, color: amber, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${context.t('Entry theek ho rahi hai')}: ${editing!.reference} · ${dmy(editing!.date)}',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xff855b20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: const BoxDecoration(
              color: rozSoft,
              border: Border.symmetric(
                horizontal: BorderSide(color: rozBorder),
              ),
            ),
            child: Text(
              context.t(tab.description),
              style: const TextStyle(fontSize: 12.5, color: muted),
            ),
          ),
          Container(
            color: rozSoft,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (closed)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Notice('Day is closed'),
                  ),
                FocusTraversalGroup(child: FormGrid(_fields())),
                if (tab == RozTab.aamad) _more(),
                if (preview != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: preview,
                  ),
                if (notInKhata != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      key: const ValueKey('roz-not-in-khata'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          color: amber,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            notInKhata,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xff855b20),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: error != null
                          ? Text(
                              error!,
                              key: const ValueKey('roz-error'),
                              style: const TextStyle(
                                color: rozRed,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            )
                          : success != null
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.check_circle_rounded,
                                  color: teal,
                                  size: 18,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    success!,
                                    style: const TextStyle(
                                      color: teal,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              '${context.t('Tareekh')}: ${dmy(date)}',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12,
                              ),
                            ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (editing != null)
                          OutlinedButton.icon(
                            onPressed: saving ? null : cancelEdit,
                            icon: const Icon(Icons.close, size: 17),
                            label: Text(context.t('Cancel')),
                          ),
                        FilledButton.icon(
                          key: const ValueKey('roz-save'),
                          style: FilledButton.styleFrom(
                            backgroundColor: accent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                          ),
                          onPressed: saving ? null : save,
                          icon: saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  editing == null
                                      ? Icons.add_rounded
                                      : Icons.save_outlined,
                                  size: 18,
                                ),
                          label: Text(
                            context.t(editing == null ? 'Add' : 'Update'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.dialog) return _body();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.t(
                        editing == null ? 'New entry' : 'Correct entry',
                      ),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                    // Opened from a party: whose khata this entry is for.
                    if (widget.initialParty != null && editing == null)
                      Text(
                        '${context.t('Khata')}: ${app.name(widget.initialParty!)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: muted),
                      ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                ),
                onPressed: () async {
                  final v = await pickDate(context, date);
                  if (v != null) setState(() => pickedDate = v);
                },
                icon: const Icon(Icons.calendar_today_outlined, size: 15),
                label: Text(
                  dmy(date),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: context.t('Close'),
                onPressed: saving ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: rozBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: _body(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
