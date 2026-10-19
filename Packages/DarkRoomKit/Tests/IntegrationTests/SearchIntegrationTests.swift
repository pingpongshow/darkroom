import Foundation
import Testing
import ImmichAPI
@testable import DarkRoomCore

@Suite("Search, explore, people and map against the test server", .enabled(if: TestServer.isAvailable), .serialized)
@MainActor
struct SearchIntegrationTests {

    @Test func metadataSearchFilters() async throws {
        let client = try await TestServer.client()
        var videos = SearchQuery()
        videos.mediaType = .videos
        let videoResults = try await SearchService.assets(videos, client: client)
        #expect(!videoResults.isEmpty)
        #expect(videoResults.allSatisfy { $0.isVideo })

        var byName = SearchQuery(text: "animated")
        byName.textMode = .fileName
        let named = try await SearchService.run(byName, client: client)
        #expect(named.contains { $0.originalFileName == "animated.gif" })

        var favorites = SearchQuery()
        favorites.favoritesOnly = true
        let favs = try await SearchService.assets(favorites, client: client)
        #expect(favs.count >= 2 && favs.allSatisfy { $0.isFavorite })
    }

    @Test func placeAndCameraSuggestionsDriveSearch() async throws {
        let client = try await TestServer.client()
        let countries = try await client.getSearchSuggestions(type: .country)
        let country = try #require(countries.first)
        var query = SearchQuery()
        query.country = country
        let inCountry = try await SearchService.assets(query, client: client)
        #expect(!inCountry.isEmpty)
        #expect(inCountry.allSatisfy { $0.country == country })

        let makes = try await client.getSearchSuggestions(type: .cameraMake)
        #expect(!makes.isEmpty)
    }

    @Test func smartSearchReturnsRankedResults() async throws {
        let client = try await TestServer.client()
        let results = try await SearchService.assets(SearchQuery(text: "trees"), client: client, limit: 50)
        #expect(!results.isEmpty, "Smart search needs the ML container to have indexed the library")
        let store = TimelineStore(client: client, groupByMonth: false, flatTitle: "Best matches") { () async throws in results }
        await store.reload()
        #expect(store.sections.count == 1)
        #expect(store.loadedAssets.map(\.id) == results.map(\.id))
    }

    @Test func staticStoreGroupsByMonth() async throws {
        let client = try await TestServer.client()
        var query = SearchQuery()
        query.mediaType = .photos
        let photos = query
        let store = TimelineStore(client: client) { try await SearchService.assets(photos, client: client) }
        await store.reload()
        #expect(store.error == nil)
        #expect(store.sections.count >= 2)
        #expect(store.sections.allSatisfy { $0.isLoaded })
        #expect(store.totalCount == store.loadedAssets.count)
    }

    @Test func exploreMapAndPeople() async throws {
        let client = try await TestServer.client()
        let explore = try await client.getExploreData()
        // Immich only lists cities with several photos, so the small test library may have none.
        #expect(explore.allSatisfy { !$0.fieldName.isEmpty })
        let markers = try await client.getMapMarkers()
        #expect(!markers.isEmpty)
        #expect(markers.allSatisfy { abs($0.lat) <= 90 && abs($0.lon) <= 180 })
        let byCity = try await client.getAssetsByCity()
        #expect(!byCity.isEmpty)
        let people = try await client.getAllPeople(withHidden: true)
        #expect(people.total >= 0)
    }
}
