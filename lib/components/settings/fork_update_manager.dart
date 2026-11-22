import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:open_file/open_file.dart';
import 'package:saber/data/fork_config.dart';

/// A parsed fork release tag, e.g. `v1.38.0-fork.1`.
@immutable
class ForkVersion {
  const new({
    required this.major,
    required this.minor,
    required this.patch,
    required this.fork,
  });

  final int major;
  final int minor;
  final int patch;

  /// The fork revision `N` in `v<upstream>-fork.<N>`, between 1 and 99.
  final int fork;

  static final _tagRegex = RegExp(
    r'^v(\d{1,2})\.(\d{1,2})\.(\d{1,2})-fork\.(\d{1,2})$',
  );

  /// Parses a tag like `v1.38.0-fork.1`.
  /// Returns null if [tag] is not a valid fork release tag.
  static ForkVersion? tryParseTag(String tag) {
    final match = _tagRegex.firstMatch(tag.trim());
    if (match == null) return null;
    final fork = int.parse(match[4]!);
    if (fork < 1 || fork > 99) return null;
    return ForkVersion(
      major: int.parse(match[1]!),
      minor: int.parse(match[2]!),
      patch: int.parse(match[3]!),
      fork: fork,
    );
  }

  /// The upstream build number, e.g. `138000` for `1.38.0`.
  /// Same formula as `SaberVersion.buildNumber` (with revision 0).
  int get upstreamBuildNumber => major * 100000 + minor * 1000 + patch * 10;

  /// The fork build number, e.g. `13800001` for `v1.38.0-fork.1`.
  /// This is also the Android versionCode of the release.
  int get buildNumber => upstreamBuildNumber * 100 + fork;

  /// E.g. `1.38.0-fork.1`.
  String get buildName => '$major.$minor.$patch-fork.$fork';

  @override
  String toString() => buildName;

  @override
  bool operator ==(Object other) =>
      other is ForkVersion && other.buildNumber == buildNumber;

  @override
  int get hashCode => buildNumber.hashCode;
}

/// Information about the latest fork release on GitHub.
@immutable
class ForkRelease {
  const new({
    required this.version,
    required this.body,
    required this.apkName,
    required this.apkUrl,
    required this.sha256Url,
  });

  final ForkVersion version;

  /// The release notes (may be empty).
  final String body;

  final String apkName;
  final String apkUrl;
  final String sha256Url;
}

/// The result of [ForkUpdateManager.checkForUpdate].
sealed class ForkUpdateCheckResult {
  const new();
}

class ForkUpToDate extends ForkUpdateCheckResult {
  const new(this.latest);

  /// The latest release on GitHub, or null if there is no release yet.
  final ForkVersion? latest;
}

class ForkUpdateAvailable extends ForkUpdateCheckResult {
  const new(this.release);
  final ForkRelease release;
}

class ForkUpdateError extends ForkUpdateCheckResult {
  const new(this.reason, [this.details]);
  final ForkUpdateErrorReason reason;
  final String? details;
}

enum ForkUpdateErrorReason {
  /// No internet connection or the server could not be reached.
  network,

  /// GitHub returned an unexpected HTTP status (e.g. rate limit).
  httpStatus,

  /// The response or the release tag could not be understood.
  invalidRelease,

  /// The release does not contain the APK or its `.sha256` file.
  missingAssets,
}

/// Thrown by [ForkUpdateManager.downloadAndVerify].
class ForkUpdateDownloadException implements Exception {
  const new(this.reason, [this.details]);
  final ForkUpdateDownloadError reason;
  final String? details;

  @override
  String toString() => 'ForkUpdateDownloadException($reason, $details)';
}

enum ForkUpdateDownloadError {
  /// The APK or the checksum file could not be downloaded.
  download,

  /// The checksum file is not in the expected format.
  invalidChecksumFile,

  /// The downloaded APK does not match the published SHA-256 checksum.
  checksumMismatch,
}

/// Result of [ForkUpdateManager.install].
enum ForkInstallResult {
  /// The Android package installer was opened.
  installerOpened,

  /// The user needs to allow "install unknown apps" for Saber Fork first.
  needsInstallPermission,

  /// The installer could not be opened.
  failed,
}

/// Handles updates of the Saber Fork via GitHub releases of [ForkConfig.repo].
///
/// This is separate from the upstream `UpdateManager` so that upstream code
/// stays (mostly) untouched and merges stay easy.
abstract class ForkUpdateManager {
  static final log = Logger('ForkUpdateManager');

  static final Uri latestReleaseUrl = Uri.parse(
    'https://api.github.com/repos/${ForkConfig.repo}/releases/latest',
  );

  /// Matches the APK asset of a fork release, e.g.
  /// `SaberFork_v1.38.0-fork.1.apk`.
  static final apkAssetRegex = RegExp(r'^SaberFork_.*\.apk$');

  static const _platform = MethodChannel('saber_fork/install');

  /// Checks GitHub for a newer fork release than [currentBuildNumber]
  /// (defaults to [ForkConfig.buildNumber]).
  ///
  /// Never throws: errors are returned as [ForkUpdateError].
  static Future<ForkUpdateCheckResult> checkForUpdate({
    int? currentBuildNumber,
    @visibleForTesting http.Client? client,
  }) async {
    currentBuildNumber ??= ForkConfig.buildNumber;

    final http.Response response;
    try {
      final headers = {'Accept': 'application/vnd.github+json'};
      response = client != null
          ? await client.get(latestReleaseUrl, headers: headers)
          : await http.get(latestReleaseUrl, headers: headers);
    } catch (e) {
      log.warning('Failed to fetch latest release: $e');
      return ForkUpdateError(.network, e.toString());
    }

    if (response.statusCode == 404) {
      // No (non-prerelease) release published yet
      return const ForkUpToDate(null);
    }
    if (response.statusCode >= 400) {
      log.warning('Failed to fetch latest release: ${response.statusCode}');
      return ForkUpdateError(.httpStatus, 'HTTP ${response.statusCode}');
    }

    return parseLatestRelease(
      response.body,
      currentBuildNumber: currentBuildNumber,
    );
  }

  /// Parses the GitHub API response of `releases/latest`.
  @visibleForTesting
  static ForkUpdateCheckResult parseLatestRelease(
    String apiResponse, {
    required int currentBuildNumber,
  }) {
    final Map<String, dynamic> json;
    final String tag;
    try {
      json = jsonDecode(apiResponse) as Map<String, dynamic>;
      tag = json['tag_name'] as String;
    } catch (e) {
      return ForkUpdateError(.invalidRelease, e.toString());
    }

    final version = ForkVersion.tryParseTag(tag);
    if (version == null) {
      return ForkUpdateError(.invalidRelease, 'Unknown tag format: $tag');
    }

    if (version.buildNumber <= currentBuildNumber) {
      return ForkUpToDate(version);
    }

    final assets = json['assets'];
    if (assets is! List) return const ForkUpdateError(.missingAssets);

    Map<String, dynamic>? apkAsset;
    Map<String, dynamic>? sha256Asset;
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'];
      if (name is! String) continue;
      if (apkAssetRegex.hasMatch(name)) apkAsset ??= asset;
    }
    if (apkAsset != null) {
      final expectedName = '${apkAsset['name']}.sha256';
      for (final asset in assets) {
        if (asset is Map<String, dynamic> && asset['name'] == expectedName) {
          sha256Asset = asset;
          break;
        }
      }
    }

    final apkUrl = apkAsset?['browser_download_url'];
    final sha256Url = sha256Asset?['browser_download_url'];
    if (apkUrl is! String || sha256Url is! String) {
      return ForkUpdateError(
        .missingAssets,
        apkAsset == null ? 'APK missing' : '.sha256 missing',
      );
    }

    return ForkUpdateAvailable(
      ForkRelease(
        version: version,
        body: (json['body'] as String?)?.trim() ?? '',
        apkName: apkAsset!['name'] as String,
        apkUrl: apkUrl,
        sha256Url: sha256Url,
      ),
    );
  }

  /// Parses a checksum file as produced by `sha256sum`
  /// (`<64 hex chars>  <file name>`).
  /// Returns the lowercase hex digest, or null if invalid.
  @visibleForTesting
  static String? parseSha256File(String contents) {
    final match = RegExp(r'^\s*([0-9a-fA-F]{64})(\s|$)').firstMatch(contents);
    return match?[1]?.toLowerCase();
  }

  /// Returns the SHA-256 of [file] as lowercase hex.
  @visibleForTesting
  static Future<String> sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// Checks [file] against [expectedSha256].
  /// If it doesn't match, the file is deleted and a
  /// [ForkUpdateDownloadException] is thrown.
  @visibleForTesting
  static Future<void> verifyOrDelete(File file, String expectedSha256) async {
    final actual = await sha256OfFile(file);
    if (actual == expectedSha256.toLowerCase()) return;
    log.severe(
      'Checksum mismatch for ${file.path}: '
      'expected $expectedSha256, got $actual',
    );
    try {
      await file.delete();
    } catch (e) {
      log.warning('Failed to delete corrupt download: $e');
    }
    throw ForkUpdateDownloadException(
      .checksumMismatch,
      'expected $expectedSha256, got $actual',
    );
  }

  /// Downloads the APK of [release], verifies its SHA-256 checksum,
  /// and returns the downloaded file.
  ///
  /// Throws a [ForkUpdateDownloadException] on failure; in that case no
  /// (partial or corrupt) APK is left behind.
  static Future<File> downloadAndVerify(
    ForkRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    // 1. Download the checksum (small)
    final http.Response shaResponse;
    try {
      shaResponse = await http.get(Uri.parse(release.sha256Url));
    } catch (e) {
      throw ForkUpdateDownloadException(.download, e.toString());
    }
    if (shaResponse.statusCode >= 400) {
      throw ForkUpdateDownloadException(
        .download,
        'HTTP ${shaResponse.statusCode} for .sha256',
      );
    }
    final expectedSha256 = parseSha256File(shaResponse.body);
    if (expectedSha256 == null) {
      throw const ForkUpdateDownloadException(.invalidChecksumFile);
    }

    // 2. Download the APK
    final task = DownloadTask(
      url: release.apkUrl,
      filename: release.apkName,
      baseDirectory: BaseDirectory.temporary,
      directory: 'fork_updates',
      updates: Updates.statusAndProgress,
    );
    final file = File(await task.filePath());
    // Never reuse an old (possibly incomplete) file
    await _deleteIfExists(file);

    final result = await FileDownloader().download(
      task,
      onProgress: onProgress,
    );
    if (result.status != TaskStatus.complete) {
      await _deleteIfExists(file);
      throw ForkUpdateDownloadException(
        .download,
        '${result.status} ${result.exception?.description ?? ''}',
      );
    }

    // 3. Verify
    await verifyOrDelete(file, expectedSha256);
    log.info('Downloaded and verified ${file.path}');
    return file;
  }

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (e) {
      log.warning('Failed to delete ${file.path}: $e');
    }
  }

  /// Whether Saber Fork may open the package installer
  /// ("install unknown apps" permission).
  static Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _platform.invokeMethod<bool>('canRequestPackageInstalls') ??
          false;
    } catch (e) {
      log.warning('canRequestPackageInstalls failed: $e');
      // Let the system installer handle it
      return true;
    }
  }

  /// Opens the system settings page where the user can allow
  /// "install unknown apps" for Saber Fork.
  static Future<void> openInstallPermissionSettings() async {
    try {
      await _platform.invokeMethod<void>('openUnknownAppSourcesSettings');
    } catch (e) {
      log.warning('openUnknownAppSourcesSettings failed: $e');
    }
  }

  /// Opens the Android package installer for the verified [apk].
  static Future<ForkInstallResult> install(File apk) async {
    if (!await canInstallPackages()) {
      return .needsInstallPermission;
    }
    final result = await OpenFile.open(
      apk.path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type == ResultType.done) return .installerOpened;
    log.severe('Failed to open installer: ${result.type} ${result.message}');
    return .failed;
  }
}
