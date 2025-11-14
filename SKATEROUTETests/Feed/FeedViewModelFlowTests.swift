import XCTest
@testable import SKATEROUTE

@MainActor
final class FeedViewModelFlowTests: XCTestCase {
    func testPullToRefreshPrependsNewItems() async throws {
        let stub = FeedPagingStub(initialPages: [
            [FeedItem(id: "1", kind: .video, title: "Session", subtitle: nil, thumbURL: nil, mediaURL: nil, createdAt: .now)]
        ],
        refreshItems: [FeedItem(id: "0", kind: .spot, title: "Fresh", subtitle: nil, thumbURL: nil, mediaURL: nil, createdAt: .now)])

        let vm = FeedViewModel(feed: stub)
        await vm.loadInitial()
        XCTAssertEqual(vm.items.map(\.id), ["1"])

        await vm.refresh()
        XCTAssertEqual(vm.items.map(\.id), ["0", "1"])
        XCTAssertFalse(vm.isRefreshing)
    }

    func testLoadMoreAppendsUntilEnd() async throws {
        let first = FeedItem(id: "1", kind: .video, title: "Session", subtitle: nil, thumbURL: nil, mediaURL: nil, createdAt: .now)
        let second = FeedItem(id: "2", kind: .route, title: "Route", subtitle: nil, thumbURL: nil, mediaURL: nil, createdAt: .now)
        let third = FeedItem(id: "3", kind: .spot, title: "Spot", subtitle: nil, thumbURL: nil, mediaURL: nil, createdAt: .now)
        let stub = FeedPagingStub(initialPages: [[first]], refreshItems: [], loadMorePages: [[second], [third]])

        let vm = FeedViewModel(feed: stub)
        await vm.loadInitial()
        XCTAssertEqual(vm.items.map(\.id), ["1"])

        await vm.loadMoreIfNeeded(current: first)
        XCTAssertEqual(vm.items.map(\.id), ["1", "2"])
        XCTAssertFalse(vm.isLoadingMore)

        await vm.loadMoreIfNeeded(current: second)
        XCTAssertEqual(vm.items.map(\.id), ["1", "2", "3"])
        XCTAssertNil(vm.nextToken)
    }
}

// MARK: - Test doubles

private final class FeedPagingStub: FeedPagingProviding {
    private let initialPages: [[FeedItem]]
    private let refreshItems: [FeedItem]
    private let loadMorePages: [[FeedItem]]

    init(initialPages: [[FeedItem]], refreshItems: [FeedItem], loadMorePages: [[FeedItem]] = []) {
        self.initialPages = initialPages
        self.refreshItems = refreshItems
        self.loadMorePages = loadMorePages
    }

    func fetchFirstPage(limit: Int) async throws -> (items: [FeedItem], next: String?) {
        let firstPage = initialPages.first ?? []
        let nextToken = loadMorePages.isEmpty ? nil : "0"
        return (firstPage, nextToken)
    }

    func fetchNextPage(token: String, limit: Int) async throws -> (items: [FeedItem], next: String?) {
        guard let idx = Int(token), idx < loadMorePages.count else { return ([], nil) }
        let items = loadMorePages[idx]
        let nextToken = (idx + 1) < loadMorePages.count ? String(idx + 1) : nil
        return (items, nextToken)
    }

    func refresh(since itemId: String) async throws -> [FeedItem] {
        refreshItems
    }
}
