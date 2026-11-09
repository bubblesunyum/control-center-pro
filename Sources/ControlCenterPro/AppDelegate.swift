// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Control Center Pro contributors

import AppKit
import CCPKit
import CCPUI
import Observation
import UserNotifications
import VorssaintEngines

/// Wires the app together: the widgets it offers, the arrangement they start
/// in, the panel that draws them, and the menu bar item that opens it.
///
/// This is the only place that knows all four, which is what keeps the registry
/// from having to reach for the interface and the shell from having to know
/// what a widget is.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: StatusItemController?
    private var arrangement: PanelArrangement?
    private var settings: SettingsStore?
    private var craft: CraftConnectionModel?
    private var hotkey: GlobalHotkey?
    /// When the hotkey press landed and whether the panel was up then. The
    /// release reads both to tell a quick toggle from a hold-to-peek. Nil
    /// while no press is in flight — a release without one is ignored.
    private var hotkeyPressDate: Date?
    private var hotkeyWasVisibleAtPress = false
    private var settingsWindow: SettingsWindowController?
    private var dropOverlay: DropOverlayController?
    private var notesBackupTimer: Timer?
    private var notesBackups = NotesBackupStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        BridgedDefaults.register()
        // UNUserNotificationCenter has no bundle under xctest and traps, so
        // only the shipped app takes the delegate and categories.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            LiveFocusNotifier.registerCategories()
        }
        let registry = makeStandardRegistry()
        let store = JSONFileStore(filename: "layout.json", default: standardLayout)
        let arrangement = PanelArrangement(
            store.load(),
            registry: registry,
            autosave: LayoutAutosave(store: store)
        )
        self.arrangement = arrangement

        let panel = ControlPanelController(arrangement: arrangement)
        let settings = SettingsStore()
        self.settings = settings

        let hotkey = GlobalHotkey()
        self.hotkey = hotkey
        // Hold-to-peek: a press shows at once so a hold reads as a peek, and
        // the release decides. Quick tap toggles and stays; a hold past the
        // threshold hides on release. Releasing either key ends the hold, so a
        // peek that ends with one key down re-shows when that key re-presses —
        // that press lands while hidden, which is just another show.
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            hotkeyPressDate = Date()
            hotkeyWasVisibleAtPress = panel.isVisible
            if HotkeyHoldPolicy.shouldShowOnPress(isVisible: panel.isVisible) {
                panel.show(from: self.statusItem?.button)
            }
        }
        hotkey.onRelease = { [weak self] in
            guard let self, let pressDate = hotkeyPressDate else { return }
            hotkeyPressDate = nil
            let duration = Date().timeIntervalSince(pressDate)
            if HotkeyHoldPolicy.shouldHideOnRelease(
                wasVisibleAtPress: hotkeyWasVisibleAtPress,
                pressDuration: duration
            ) {
                panel.hide()
            }
        }
        hotkey.use(settings.panelShortcut)
        trackShortcutChanges()

        let craftConnection = CraftConnectionModel()
        self.craft = craftConnection

        let settingsWindow = SettingsWindowController(settings: settings,
                                                        craft: craftConnection,
                                                        claudeToken: ClaudeTokenModel(),
                                                        hotkey: hotkey)
        self.settingsWindow = settingsWindow
        statusItem = StatusItemController(panel: panel, settingsWindow: settingsWindow)

        // The drop-catcher pill: a drag of something the shelf can keep hangs
        // a target below the menu-bar item. Suppressed while the panel or the
        // shelf is open — the user can drop directly on those instead.
        dropOverlay = DropOverlayController(
            statusFrame: { [weak self] in self?.statusItem?.button?.window?.frame },
            isSuppressed: { panel.isVisible || ShelfWindowController.shared.isVisible }
        )
        startNotesBackups()

        // An agent can't click a menu bar item, and a screenshot of a panel
        // nobody opened is a screenshot of the desktop. This is how the smoke
        // run and the design review get to see the thing.
        if CommandLine.arguments.contains("--show-panel") {
            panel.show(from: nil)
        }
        if CommandLine.arguments.contains("--edit-mode") {
            panel.startEditing()
        }
        if CommandLine.arguments.contains("--show-settings") {
            settingsWindow.show()
        }
        if CommandLine.arguments.contains("--show-shelf") {
            ShelfWindowController.shared.show()
        }
    }

    /// Notes survive a kill -9 by at most one snapshot interval: an
    /// app-level repeating snapshot — panel-open or not — plus a launch
    /// snapshot (a crash may have skipped the termination flush) and a
    /// termination flush next to the other stores'.
    private func startNotesBackups() {
        notesBackups.run()
        notesBackupTimer = Timer.scheduledTimer(withTimeInterval: NotesBackupStore.snapshotInterval,
                                                repeats: true) { [weak self] _ in
            self?.notesBackups.run()
        }
    }

    /// Keep the registration on whatever the user last chose.
    ///
    /// Observation reports a change as it is about to happen and then stops
    /// watching, so this reads the new value a turn later and arms itself
    /// again — the same shape the panel uses to follow its content.
    private func trackShortcutChanges() {
        withObservationTracking {
            _ = settings?.panelShortcut
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                trackShortcutChanges()
                hotkey?.use(settings?.panelShortcut)
            }
        }
    }

    /// The autosave is deliberately lazy, so quitting is the one moment it has
    /// to stop being.
    func applicationWillTerminate(_ notification: Notification) {
        dropOverlay?.stop()
        arrangement?.flush()
        ShelfStore.shared.flush()
        StickyStore.shared.flush()
        notesBackups.run()
    }

    // MARK: - Notifications

    /// Foreground banners only for the return nudge. The phase-end request
    /// keeps its old behaviour — no banner while active, the store's own
    /// chime carries it — so the panel-open deadline doesn't gain a second
    /// signal.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.content.categoryIdentifier
            == LiveFocusNotifier.returnCategoryID
        else { return [] }
        return [.banner, .sound]
    }

    /// The nudge's Start action, or a tap on its body, begins the round
    /// silently — the panel stays shut.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let isStart = response.actionIdentifier == LiveFocusNotifier.startFocusActionID
        let isBodyTap = response.actionIdentifier
            == UNNotificationDefaultActionIdentifier
            && response.notification.request.content.categoryIdentifier
                == LiveFocusNotifier.returnCategoryID
        guard isStart || isBodyTap else { return }
        FocusStore.shared.handleReturnNudgeAction()
    }
}
