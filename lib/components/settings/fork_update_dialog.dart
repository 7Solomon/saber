import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:saber/components/settings/fork_update_manager.dart';
import 'package:saber/data/fork_config.dart';

/// Settings entry "Nach Updates suchen" of the Saber Fork.
///
/// Only shown in fork release builds (see [ForkConfig.isForkRelease]).
class ForkUpdateButton extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    const n = ForkConfig.buildNumber;
    const current = n > 0 ? 'Installiert: Build $n' : 'Lokaler Build';
    return InkWell(
      onTap: () => ForkUpdateDialog.show(context),
      child: const ListTile(
        contentPadding: .symmetric(vertical: 4, horizontal: 16),
        leading: Icon(Icons.system_update),
        title: Text('Nach Updates suchen', style: TextStyle(fontSize: 18)),
        subtitle: Text(current, style: TextStyle(fontSize: 13)),
      ),
    );
  }
}

/// Checks for, downloads, verifies and installs a fork update.
class ForkUpdateDialog extends StatefulWidget {
  const new({super.key, this.checkForUpdate});

  /// Overrides [ForkUpdateManager.checkForUpdate] in tests.
  final Future<ForkUpdateCheckResult> Function()? checkForUpdate;

  static Future<void> show(BuildContext context) => showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => const ForkUpdateDialog(),
  );

  @override
  State<ForkUpdateDialog> createState() => _ForkUpdateDialogState();
}

enum _Phase {
  checking,
  upToDate,
  checkFailed,
  available,
  downloading,
  downloadFailed,
  needsPermission,
  installerOpened,
  installFailed,
}

class _ForkUpdateDialogState extends State<ForkUpdateDialog>
    with WidgetsBindingObserver {
  var _phase = _Phase.checking;
  ForkUpdateCheckResult? _check;
  String? _errorText;
  File? _verifiedApk;
  final _progress = ValueNotifier<double?>(null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runCheck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progress.dispose();
    super.dispose();
  }

  /// When the user comes back from the "install unknown apps" settings,
  /// try to open the installer again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == .resumed &&
        _phase == _Phase.needsPermission &&
        _verifiedApk != null) {
      _install(_verifiedApk!);
    }
  }

  Future<void> _runCheck() async {
    setState(() => _phase = .checking);
    final result =
        await (widget.checkForUpdate ?? ForkUpdateManager.checkForUpdate)();
    if (!mounted) return;
    setState(() {
      _check = result;
      _phase = switch (result) {
        ForkUpToDate() => .upToDate,
        ForkUpdateAvailable() => .available,
        ForkUpdateError() => .checkFailed,
      };
      if (result is ForkUpdateError) {
        _errorText = switch (result.reason) {
          .network =>
            'Keine Verbindung zu GitHub. Bitte prüfe deine '
                'Internetverbindung und versuche es erneut.',
          .httpStatus =>
            'GitHub hat die Anfrage abgelehnt (${result.details}). '
                'Bitte versuche es später erneut.',
          .invalidRelease =>
            'Das neueste Release konnte nicht gelesen werden '
                '(${result.details}).',
          .missingAssets =>
            'Das neueste Release enthält keine vollständige APK '
                '(${result.details}). Das Release ist evtl. noch im Aufbau.',
        };
      }
    });
  }

  Future<void> _download(ForkRelease release) async {
    setState(() {
      _phase = .downloading;
      _progress.value = 0;
    });
    final File apk;
    try {
      apk = await ForkUpdateManager.downloadAndVerify(
        release,
        onProgress: (p) => _progress.value = p < 0 ? null : p,
      );
    } on ForkUpdateDownloadException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = .downloadFailed;
        _errorText = switch (e.reason) {
          .download =>
            'Der Download ist fehlgeschlagen. Bitte versuche es erneut.',
          .invalidChecksumFile =>
            'Die Prüfsummen-Datei des Releases ist ungültig. '
                'Aus Sicherheitsgründen wird nicht installiert.',
          .checksumMismatch =>
            'Die heruntergeladene Datei stimmt nicht mit der Prüfsumme '
                'überein und wurde gelöscht. Es wurde nichts installiert.',
        };
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = .downloadFailed;
        _errorText = 'Der Download ist fehlgeschlagen: $e';
      });
      return;
    }
    _verifiedApk = apk;
    await _install(apk);
  }

  Future<void> _install(File apk) async {
    final result = await ForkUpdateManager.install(apk);
    if (!mounted) return;
    setState(() {
      _phase = switch (result) {
        .installerOpened => .installerOpened,
        .needsInstallPermission => .needsPermission,
        .failed => .installFailed,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final release = switch (_check) {
      ForkUpdateAvailable(:final release) => release,
      _ => null,
    };

    final Widget title = Text(switch (_phase) {
      .checking => 'Suche nach Updates …',
      .upToDate => 'Kein Update verfügbar',
      .checkFailed => 'Update-Prüfung fehlgeschlagen',
      .available ||
      .downloading ||
      .downloadFailed ||
      .needsPermission ||
      .installerOpened ||
      .installFailed => 'Update ${release?.version.buildName ?? ''}',
    });

    final List<Widget> content = switch (_phase) {
      .checking => [const LinearProgressIndicator()],
      .upToDate => [const Text('Du hast die neueste Version.')],
      .checkFailed || .downloadFailed => [
        Text(_errorText ?? '', style: TextStyle(color: colorScheme.error)),
      ],
      .available => [
        Text('Neue Version: ${release!.version.buildName}'),
        const SizedBox(height: 12),
        if (release.body.isNotEmpty)
          Flexible(child: SingleChildScrollView(child: Text(release.body))),
        const SizedBox(height: 12),
        const Text(
          'Deine Notizen bleiben beim Update erhalten. '
          'Bitte deinstalliere die App nicht.',
          style: TextStyle(fontSize: 13),
        ),
      ],
      .downloading => [
        const Text('Lade herunter und prüfe die SHA-256-Prüfsumme …'),
        const SizedBox(height: 12),
        ValueListenableBuilder(
          valueListenable: _progress,
          builder: (context, progress, _) =>
              LinearProgressIndicator(value: progress),
        ),
      ],
      .needsPermission => [
        const Text(
          'Damit Saber Fork das Update installieren kann, musst du einmalig '
          'erlauben, dass diese App andere Apps installieren darf '
          '(„Unbekannte Apps installieren“).\n\n'
          'Tippe auf „Einstellungen öffnen“, aktiviere den Schalter für '
          'Saber Fork und kehre dann hierher zurück.',
        ),
      ],
      .installerOpened => [
        const Text(
          'Die Prüfsumme ist korrekt. Der Android-Installer wurde geöffnet – '
          'bitte bestätige dort „Aktualisieren“.',
        ),
      ],
      .installFailed => [
        Text(
          'Der Installer konnte nicht geöffnet werden.',
          style: TextStyle(color: colorScheme.error),
        ),
      ],
    };

    final List<Widget> actions = switch (_phase) {
      .checking || .downloading => [],
      .upToDate || .installerOpened => [_close(context, 'OK')],
      .checkFailed => [
        _close(context, 'Schließen'),
        TextButton(onPressed: _runCheck, child: const Text('Erneut versuchen')),
      ],
      .available || .downloadFailed => [
        _close(context, 'Abbrechen'),
        TextButton(
          onPressed: () => _download(release!),
          child: Text(
            _phase == .available
                ? 'Herunterladen und installieren'
                : 'Erneut versuchen',
          ),
        ),
      ],
      .needsPermission => [
        _close(context, 'Abbrechen'),
        const TextButton(
          onPressed: ForkUpdateManager.openInstallPermissionSettings,
          child: Text('Einstellungen öffnen'),
        ),
      ],
      .installFailed => [
        _close(context, 'Schließen'),
        TextButton(
          onPressed: () => _install(_verifiedApk!),
          child: const Text('Erneut versuchen'),
        ),
      ],
    };

    return AlertDialog(
      title: title,
      content: Column(
        mainAxisSize: .min,
        crossAxisAlignment: .start,
        children: content,
      ),
      actions: actions,
    );
  }

  Widget _close(BuildContext context, String label) =>
      TextButton(onPressed: () => Navigator.pop(context), child: Text(label));
}
