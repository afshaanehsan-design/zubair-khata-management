import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../core/controller.dart';
import '../core/organizations.dart';
import '../features/reports/reports.dart';
import 'app.dart' show KhataApp;
import 'components.dart';

Future<void> saveBytes(
  BuildContext context,
  Uint8List bytes,
  String name,
  String extension,
) async {
  if (Platform.isAndroid) {
    // The organization whose screen this is. Dialogs are under KhataApp too.
    final organization =
        context
            .findAncestorWidgetOfExactType<KhataApp>()
            ?.app
            .organization
            ?.id ??
        Organization.main;
    final directory = exportCopiesFolder(
      await getTemporaryDirectory(),
      organization,
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}/$name.$extension');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], title: name),
    );
  } else {
    final target = await getSaveLocation(
      suggestedName: '$name.$extension',
      acceptedTypeGroups: [
        XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
      ],
    );
    if (target != null) await XFile.fromData(bytes).saveTo(target.path);
  }
}

/// Android shares a copy of each backup or report from the app's cache. Each
/// organization has a folder of its own there, so resetting or removing one
/// deletes its copies and nobody else's.
Directory exportCopiesFolder(Directory cache, String organization) =>
    Directory('${cache.path}/exports/$organization');

/// Deletes one organization's cached copies under [cache]. Copies written
/// before organizations existed (straight into `exports/`, and before that
/// into the cache folder itself) belong to the first organization.
Future<void> deleteExportCopies(Directory cache, String organization) async {
  final folder = exportCopiesFolder(cache, organization);
  if (await folder.exists()) await folder.delete(recursive: true);
  if (organization != Organization.main) return;
  for (final old in [Directory('${cache.path}/exports'), cache]) {
    if (!await old.exists()) continue;
    await for (final f in old.list()) {
      if (f is File &&
          RegExp(r'\.(json|pdf|xlsx|csv)$').hasMatch(f.path.toLowerCase())) {
        await f.delete();
      }
    }
  }
}

/// Deletes an organization's cached copies of shared backups and reports
/// (Android only; on Windows files go only where the user saved them, and
/// stay theirs). Called when the organization is reset or removed.
Future<void> clearExportCopies(String organization) async {
  if (!Platform.isAndroid) return;
  await deleteExportCopies(await getTemporaryDirectory(), organization);
}

/// The PDF preview of every report. Its size slider (50% to 200%) sets how big
/// the PDF prints its content ([ReportExporter.size]); what is saved, shared
/// or printed is the PDF shown. The size is remembered for each kind of
/// report ([AppController.pdfSize]).
Future<void> previewReport(
  BuildContext context,
  Report report, {
  ValueChanged<bool>? onCompact,
}) async {
  final app = context.findAncestorWidgetOfExactType<KhataApp>()?.app;
  final kind = report.kind.isEmpty ? report.title : report.kind;
  var current = report;
  // The size the PDF is built at, and the one the slider shows while it is
  // dragged (the PDF is built again only when it is let go).
  var percent = app?.pdfSize(kind) ?? 100;
  var shown = percent.toDouble();
  var exporter = ReportExporter(size: percent / 100);
  var future = exporter.pdf(current);

  // Builds the PDF again for the current mode and size, abandoning the one
  // being prepared.
  void rebuild() {
    exporter.cancelled = true;
    // Its ReportCancelled is expected and must not be reported.
    future.ignore();
    exporter = ReportExporter(size: percent / 100);
    future = exporter.pdf(current);
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        void resize(int value) {
          value = value.clamp(
            AppController.pdfSizeMin,
            AppController.pdfSizeMax,
          );
          setState(() {
            shown = value.toDouble();
            if (value == percent) return;
            percent = value;
            rebuild();
          });
          app?.setPdfSize(kind, value);
        }

        return Dialog.fullscreen(
          child: Scaffold(
            appBar: pdfPreviewBar(
              ctx,
              title: report.title,
              // Compact (Roznamcha) or Details (the day's pending balances).
              switchLabel:
                  report.roznamchaSheets == null && report.compactView == null
                  ? null
                  : report.sheetSwitch,
              compact: current.compact,
              onCompact: (value) {
                setState(() {
                  current = current.withCompact(value);
                  rebuild();
                });
                onCompact?.call(value);
              },
              size: shown,
              onSliding: (v) => setState(() => shown = v),
              onSize: resize,
              onClose: () {
                exporter.cancelled = true;
                Navigator.pop(ctx);
              },
            ),
            body: FutureBuilder<Uint8List>(
              key: ObjectKey(future),
              future: future,
              builder: (ctx, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('${ctx.t('Error')}: ${snapshot.error}'),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(ctx.t('Preparing report…')),
                      ],
                    ),
                  );
                }
                return PdfPreview(
                  build: (_) async => snapshot.data!,
                  canDebug: false,
                  canChangeOrientation: false,
                  canChangePageFormat: false,
                  pdfFileName: 'ZubairKhata.pdf',
                  actions: [
                    PdfPreviewAction(
                      icon: const Icon(Icons.save_alt),
                      onPressed: (context, build, pageFormat) async {
                        await saveBytes(
                          context,
                          snapshot.data!,
                          'ZubairKhata',
                          'pdf',
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    ),
  );
  exporter.cancelled = true;
  future.ignore();
}

/// The PDF preview's title bar: close, the report's title, the Compact or
/// Details switch when the report has one ([switchLabel]), and the size
/// slider under them. Its own function so the layout test can draw it.
PreferredSizeWidget pdfPreviewBar(
  BuildContext context, {
  required String title,
  String? switchLabel,
  bool compact = false,
  ValueChanged<bool>? onCompact,
  required double size,
  required ValueChanged<double> onSliding,
  required ValueChanged<int> onSize,
  required VoidCallback onClose,
}) => AppBar(
  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
  actions: [
    if (switchLabel != null)
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(context.t(switchLabel)),
          Switch(
            key: const ValueKey('pdf-compact'),
            value: compact,
            onChanged: onCompact,
          ),
        ],
      ),
  ],
  leading: IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
  bottom: PreferredSize(
    preferredSize: const Size.fromHeight(PdfSizeBar.height),
    child: PdfSizeBar(shown: size, onSliding: onSliding, onSet: onSize),
  ),
);

/// The PDF preview's size slider, under its title: smaller and bigger in 5%
/// steps between 50% and 200%, and the percentage, which goes back to 100%
/// when tapped. [onSliding] follows a drag; [onSet] gets the size chosen.
class PdfSizeBar extends StatelessWidget {
  static const height = 48.0;
  final double shown;
  final ValueChanged<double> onSliding;
  final ValueChanged<int> onSet;
  const PdfSizeBar({
    super.key,
    required this.shown,
    required this.onSliding,
    required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    const step = AppController.pdfSizeStep;
    const low = AppController.pdfSizeMin, high = AppController.pdfSizeMax;
    final value = shown.round();
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
        child: Row(
          children: [
            Flexible(
              child: Text(
                context.t('Size'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              key: const ValueKey('pdf-size-smaller'),
              tooltip: context.t('Smaller'),
              visualDensity: VisualDensity.compact,
              onPressed: value <= low
                  ? null
                  : () => onSet(((value - 1) ~/ step) * step),
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              flex: 8,
              child: Slider(
                key: const ValueKey('pdf-size'),
                min: low.toDouble(),
                max: high.toDouble(),
                divisions: (high - low) ~/ step,
                value: shown.clamp(low.toDouble(), high.toDouble()),
                label: '$value%',
                onChanged: onSliding,
                onChangeEnd: (v) => onSet(v.round()),
              ),
            ),
            IconButton(
              key: const ValueKey('pdf-size-bigger'),
              tooltip: context.t('Bigger'),
              visualDensity: VisualDensity.compact,
              onPressed: value >= high
                  ? null
                  : () => onSet((value ~/ step + 1) * step),
              icon: const Icon(Icons.add),
            ),
            Tooltip(
              message: context.t('Back to 100%'),
              child: TextButton(
                key: const ValueKey('pdf-size-reset'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(56, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: value == 100 ? null : () => onSet(100),
                // Digits and % read left to right in Urdu too.
                child: Text('$value%', textDirection: TextDirection.ltr),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
