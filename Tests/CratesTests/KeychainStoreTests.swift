import Testing
import Foundation
@testable import CratesIOS

/// Round-trips the Keychain wrapper against the real `SecItem` store in the simulator test host.
/// The pairing bearer token lives here now (moved out of UserDefaults), so these pin the
/// set / overwrite / read / delete and "absent reads nil" contract that the migration and
/// sign-out paths depend on. Uses a throwaway account so the real token item is never touched.
struct KeychainStoreTests {
    private let account = "test.token.\(UUID().uuidString)"

    @Test func roundTripsSetGetDelete() {
        defer { KeychainStore.delete(account: account) }

        #expect(KeychainStore.get(account: account) == nil)          // absent → nil
        #expect(KeychainStore.set("bearer-123", account: account))
        #expect(KeychainStore.get(account: account) == "bearer-123")
        #expect(KeychainStore.set("bearer-456", account: account))   // overwrite in place
        #expect(KeychainStore.get(account: account) == "bearer-456")
        #expect(KeychainStore.delete(account: account))
        #expect(KeychainStore.get(account: account) == nil)          // gone after delete
    }
}
