import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

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

Future<void> previewReport(BuildContext context, Report report) async {
  final exporter = ReportExporter();
  final future = exporter.pdf(report);
  await showDialog<void>(
    context: context,
    builder: (ctx) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(report.title),
          leading: IconButton(
            onPressed: () {
              exporter.cancelled = true;
              Navigator.pop(ctx);
            },
            icon: const Icon(Icons.close),
          ),
        ),
        body: FutureBuilder<Uint8List>(
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
    ),
  );
}
