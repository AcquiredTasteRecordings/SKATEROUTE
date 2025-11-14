import XCTest
@testable import SKATEROUTE

final class QueryCacheTests: XCTestCase {
    @MainActor
    func testConcurrentRefreshAndSearchDeterministicEviction() async {
        for _ in 0..<200 {
            let cache = QueryCache<String, Int>(capacity: 3)
            cache.setValue(1, forKey: "A")
            cache.setValue(2, forKey: "B")
            cache.setValue(3, forKey: "C")

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await MainActor.run {
                        cache.setValue(4, forKey: "A")
                    }
                }
                group.addTask {
                    await MainActor.run {
                        _ = cache.value(forKey: "B")
                    }
                }
            }

            cache.setValue(5, forKey: "D")

            XCTAssertNil(cache.value(forKey: "C"))
            XCTAssertNotNil(cache.value(forKey: "A"))
            XCTAssertNotNil(cache.value(forKey: "B"))
            XCTAssertNotNil(cache.value(forKey: "D"))

            #if DEBUG
            let order = cache.debugOrder()
            XCTAssertEqual(order.first, "D")
            XCTAssertEqual(Set(order), ["A", "B", "D"])
            #endif
        }
    }
}
