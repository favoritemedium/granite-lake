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
