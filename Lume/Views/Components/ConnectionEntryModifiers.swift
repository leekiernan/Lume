import SwiftUI

extension View {
    /// Standard form URL entry, shared by add/edit playlist and source forms.
    /// Keyboard/capitalization overrides remain iOS-only, as before.
    func urlEntry() -> some View {
        self
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        #endif
        .autocorrectionDisabled()
        .textContentType(.URL)
    }

    /// Username entry without changing its binding, optionality or validation.
    /// Secure fields and uppercase MAC-address entry are deliberately separate.
    func usernameEntry() -> some View {
        self
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .autocorrectionDisabled()
        .textContentType(.username)
    }
}
