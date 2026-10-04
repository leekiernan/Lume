@testable import Lume
import Testing

struct CredentialMergeApplicationTests {
    @Test func `credential writes precede the shadow and preserve local-first ordering`() {
        let cases: [(MergeVerdict<String>, [String], CredentialMergeApplication.Effects)] = [
            (.noChange, [], .init()),
            (.pushToCloud("token"), ["cloud", "shadow"], .init(pushed: 1)),
            (.pushToCloud(nil), ["cloud", "shadow"], .init(pushed: 1, deletionPushed: true)),
            (.pullToLocal("token"), ["local", "shadow"], .init(pulled: 1)),
            (.pullToLocal(nil), ["local", "shadow"], .init(pulled: 1)),
            (.writeBoth("token"), ["local", "cloud", "shadow"], .init(pushed: 1, pulled: 1))
        ]
        for (verdict, expected, effects) in cases {
            var calls: [String] = []
            let result = CredentialMergeApplication.apply(verdict, writeLocal: { _ in
                calls.append("local")
                return true
            }, writeCloud: { _ in calls.append("cloud") }, recordShadow: { _ in calls.append("shadow") })
            #expect(calls == expected)
            #expect(result == effects)
        }
    }

    @Test func `rejected keychain writes cannot dirty cloud or baseline`() {
        for verdict in [MergeVerdict<String>.pullToLocal("token"), .pullToLocal(nil), .writeBoth("token")] {
            var calls: [String] = []
            let result = CredentialMergeApplication.apply(verdict, writeLocal: { _ in
                calls.append("local")
                return false
            }, writeCloud: { _ in calls.append("cloud") }, recordShadow: { _ in calls.append("shadow") })
            #expect(calls == ["local"])
            #expect(result == .init(pending: 1))
        }
    }
}
