import SwiftUI

#if !os(tvOS)
    /// The same editable/generated MAC field in add and edit forms. Generation
    /// changes the form binding only; it never saves or reconnects the playlist.
    struct StalkerMACEntry: View {
        @Binding var address: String

        var body: some View {
            HStack {
                TextField("MAC Address", text: $address)
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                    .autocorrectionDisabled()
                Button { address = StalkerMAC.generate() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Generate a new MAC address")
            }
        }
    }
#endif
