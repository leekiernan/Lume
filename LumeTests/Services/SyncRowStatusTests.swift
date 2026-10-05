@testable import Lume
import Testing

struct SyncRowStatusTests {
    @Test func `steps share symbols without treating busy as completed`() {
        #expect(SyncRowStatus.step(.pending).symbol == "circle")
        #expect(SyncRowStatus.step(.active).symbol == nil)
        #expect(!SyncRowStatus.step(.active).isCompleted)
        #expect(SyncRowStatus.step(.completed).symbol == "checkmark.circle.fill")
        #expect(SyncRowStatus.step(.completed).isCompleted)
    }

    @Test func `guide skipped and pending remain distinct from updated`() {
        #expect(SyncRowStatus.guide(.afterSync).symbol == "circle")
        #expect(SyncRowStatus.guide(.notUpdated).symbol == "minus.circle")
        #expect(!SyncRowStatus.guide(.notUpdated).isCompleted)
        #expect(SyncRowStatus.guide(.updating).symbol == nil)
        #expect(!SyncRowStatus.guide(.updating).isCompleted)
        #expect(SyncRowStatus.guide(.updated).symbol == "checkmark.circle.fill")
        #expect(SyncRowStatus.guide(.updated).isCompleted)
    }
}
