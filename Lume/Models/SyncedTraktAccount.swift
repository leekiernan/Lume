import Foundation
import SwiftData

/// The one Trakt authorization shared by every Lume device on the user's
/// iCloud account.
///
/// Trakt refresh tokens are single-use: refreshing on one device immediately
/// invalidates the token every other device still holds. Keeping the latest
/// token pair in the CloudKit mirror lets those devices converge on the winner
/// instead of each consuming another Trakt authorization.
///
/// The token fields use CloudKit encrypted values, matching playlist
/// credentials. The local copy remains in the keychain; this record is only the
/// cross-device transport that iCloud Keychain cannot provide on tvOS.
@Model
final class SyncedTraktAccount {
    static let singletonID = "trakt-account"

    var id: String = SyncedTraktAccount.singletonID
    @Attribute(.allowsCloudEncryption) var accessToken: String = ""
    @Attribute(.allowsCloudEncryption) var refreshToken: String = ""
    var createdAt: Double = 0
    var expiresIn: Double = 0
    var scope: String?
    var tokenType: String?

    /// Used to collapse duplicate singleton rows and resolve the unlikely case
    /// where two devices refresh before either receives the other's CloudKit
    /// update. Trakt's server-issued `createdAt` is the primary ordering value.
    var updatedAt: Date = Date()

    init(tokens: TraktTokens, updatedAt: Date = Date()) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        createdAt = tokens.createdAt
        expiresIn = tokens.expiresIn
        scope = tokens.scope
        tokenType = tokens.tokenType
        self.updatedAt = updatedAt
    }
}
