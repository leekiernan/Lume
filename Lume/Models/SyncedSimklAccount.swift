import Foundation
import SwiftData

/// The one Simkl authorization shared by every Lume device on the user's
/// iCloud account. The encrypted CloudKit fields transport the latest OAuth
/// token pair between devices; the keychain remains the local store of record.
@Model
final class SyncedSimklAccount {
    static let singletonID = "simkl-account"

    var id: String = SyncedSimklAccount.singletonID
    @Attribute(.allowsCloudEncryption) var accessToken: String = ""
    @Attribute(.allowsCloudEncryption) var refreshToken: String = ""
    var issuedAt: Double = 0
    var expiresIn: Double = 0
    var scope: String?
    var tokenType: String?
    var updatedAt: Date = Date()

    init(tokens: SimklTokens, updatedAt: Date = Date()) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        issuedAt = tokens.issuedAt
        expiresIn = tokens.expiresIn
        scope = tokens.scope
        tokenType = tokens.tokenType
        self.updatedAt = updatedAt
    }
}
