/// Keep window-level shortcuts away from native editors and modal sheets.
/// Native menus handle their key equivalents before the window's controls.
nonisolated enum MacWindowShortcutPolicy {
    static func accepts(isEditingText: Bool, hasPresentedSheet: Bool) -> Bool {
        !isEditingText && !hasPresentedSheet
    }
}
