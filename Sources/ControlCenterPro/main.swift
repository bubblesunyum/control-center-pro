// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import CCPKit
import CCPUI

// The real app lifecycle — status item, panel, wiring — lands in ccp-lr7.3.
// Until then this exists so the executable target links and the gate has
// something to build.
print("Control Center Pro — shell not yet built (CCPKit wired: \(CCPUI.isWired))")
