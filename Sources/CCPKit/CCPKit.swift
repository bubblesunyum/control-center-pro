// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

/// Namespace for the adapter layer over upstream's engines.
///
/// Everything Control Center Pro knows about `VorssaintEngines` enters through
/// this target, so an upstream refactor breaks an adapter here rather than the
/// interface in `CCPUI`.
public enum CCPKit {
    /// Marker the package tests assert on until the first real adapter lands.
    public static let isWired = true
}
