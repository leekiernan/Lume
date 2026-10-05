import Foundation
@testable import Lume
import Testing

struct ProviderRetryPolicyTests {
    @Test func `the existing catalog budget grants two backoffs and no fourth attempt`() {
        let policy = ProviderRetryPolicy.catalog
        #expect(policy.maxAttempts == 3)
        #expect(policy.delay(afterFailedAttempt: 1) == 2)
        #expect(policy.delay(afterFailedAttempt: 2) == 4)
        #expect(policy.delay(afterFailedAttempt: 3) == nil)
        #expect(policy.delay(afterFailedAttempt: 0) == nil)
        #expect(policy.delay(afterFailedAttempt: -1) == nil)
        #expect(ProviderRetryPolicy(maxAttempts: 1).delay(afterFailedAttempt: 1) == nil)
    }

    @Test func `phase spacing only waits for time not already paid by persistence`() {
        let finished = ContinuousClock.now
        #expect(ProviderRequestSpacing.remaining(minimum: .seconds(2), since: nil, now: finished) == .zero)
        #expect(ProviderRequestSpacing.remaining(minimum: .seconds(2), since: finished, now: finished + .seconds(1)) == .seconds(1))
        #expect(ProviderRequestSpacing.remaining(minimum: .seconds(2), since: finished, now: finished + .seconds(10)) == .zero)
        #expect(ProviderRequestSpacing.remaining(minimum: .seconds(2), since: finished, now: finished - .seconds(1)) == .seconds(2))
    }
}
