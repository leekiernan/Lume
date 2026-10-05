import SwiftUI

extension Binding {
    /// Adapts an optional presentation target to a native alert/dialog binding.
    /// Dismissal clears it; `true` cannot invent or replace a target.
    func presentationPresence<Item>() -> Binding<Bool> where Value == Item? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } }
        )
    }
}
