import 'package:flutter/foundation.dart';
import 'package:saber/data/is_this_a_test.dart';

/// Configuration specific to the Saber Fork (`7Solomon/saber`).
abstract class ForkConfig {
  /// The GitHub repository the fork is released from.
  static const repo = '7Solomon/saber';

  /// The fork build number of this build, e.g. `13800001` for
  /// `v1.38.0-fork.1`.
  ///
  /// Set by the release workflow via
  /// `--dart-define=FORK_BUILD_NUMBER=...`.
  /// It is 0 for local builds and in tests.
  static const buildNumber = int.fromEnvironment('FORK_BUILD_NUMBER');

  /// Overrides [isForkRelease] in tests.
  @visibleForTesting
  static bool? isForkReleaseOverride;

  /// Whether this is a fork release build made by the release workflow.
  ///
  /// Fork-only UI (e.g. the "check for updates" button) is only shown in such
  /// builds, so that tests and golden screenshots behave exactly like upstream.
  static bool get isForkRelease =>
      isForkReleaseOverride ?? (buildNumber > 0 && !isThisATest);
}
