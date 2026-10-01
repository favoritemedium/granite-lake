import 'dart:async';

import 'package:geolocator/geolocator.dart';

/// Builds [LocationSettings] for [Geolocator.getCurrentPosition]/streams.
///
/// Deliberately does NOT set `forceLocationManager` on Android.
/// geolocator_android's `GeolocationManager.createLocationClient` already
/// probes `GoogleApiAvailability` per-device and picks the right backend on
/// its own: the fast, network+GPS-assisted FusedLocationProviderClient when
/// Play Services is present (most devices, including budget ones - assist
/// data is what lets a cheap GNSS chip get a fix quickly), falling back to
/// plain AOSP LocationManager automatically when it isn't (e.g. GrapheneOS
/// without Sandboxed Google Play). Forcing LocationManager unconditionally
/// would strip that assistance from every device, including ones with
/// perfectly good Play Services - regressing exactly the budget-hardware
/// devices that rely on it most to compensate for weaker GPS antennas.
///
/// [timeLimit] matters independently of all that: without it, a fix that
/// never arrives (weak signal, no assistance data, etc.) hangs forever with
/// no error - nothing for the UI to show and nothing to diagnose from.
LocationSettings resolveLocationSettings({
  required LocationAccuracy accuracy,
  Duration? timeLimit,
}) {
  return LocationSettings(accuracy: accuracy, timeLimit: timeLimit);
}

/// Tries Google Play Services' network/Wi-Fi-based positioning first, and
/// only falls back to a raw GPS fix if that can't resolve at all.
///
/// `LocationAccuracy.high` (Android's `PRIORITY_HIGH_ACCURACY`) biases the
/// fused provider toward the GPS chip's own satellite lock, which is
/// normally unreachable indoors - that's what was leaving the HUD stuck on
/// "Still acquiring GPS" for the full [gpsTimeout] in every indoor use.
/// `LocationAccuracy.medium` (`PRIORITY_BALANCED_POWER_ACCURACY`) instead
/// asks the same Play Services client to resolve from cell/Wi-Fi scan data
/// (Google's network location API), which answers in a few seconds
/// indoors and out, on every device with Play Services.
///
/// The GPS fallback only matters for the devices with no Play Services at
/// all (e.g. GrapheneOS without Sandboxed Google Play), where the network
/// attempt has nothing to answer with and just times out - those still get
/// the original patient, GPS-only fix (see [resolveLocationSettings]'s
/// GrapheneOS cold-start note) instead of being left without one.
Future<Position> resolveBestEffortPosition({
  Duration networkTimeout = const Duration(seconds: 10),
  Duration gpsTimeout = const Duration(minutes: 2),
}) async {
  try {
    return await Geolocator.getCurrentPosition(
      locationSettings: resolveLocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: networkTimeout,
      ),
    );
  } on TimeoutException {
    return await Geolocator.getCurrentPosition(
      locationSettings: resolveLocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: gpsTimeout,
      ),
    );
  }
}
