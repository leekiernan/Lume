import Foundation
@testable import Lume
import Testing

struct SportsPosterLookupTests {
    private var fixture: SportsFixture {
        SportsFixture(id: "event", leagueId: "espn:racing/f1", leagueName: "Formula 1", leagueAbbreviation: "F1",
                      startDate: Date(timeIntervalSince1970: 0), status: SportsFixtureStatus(state: .scheduled), name: "British Grand Prix")
    }

    private func event(date: String = "1970-01-01", league: String = "4370", sport: String = "Motorsport", name: String = "British Grand Prix", poster: String = "https://www.thesportsdb.com/poster.jpg") -> SportsPosterLookup.Event {
        SportsPosterLookup.Event(idLeague: league, strSport: sport, dateEvent: date, strEvent: name,
                                 strHomeTeam: nil, strAwayTeam: nil, strPoster: poster)
    }

    @Test func `unique event match accepts harmless capitalization and punctuation differences`() {
        let result = SportsPosterLookup.poster(in: [event(name: "BRITISH GRAND-PRIX")], fixture: fixture, leagueID: "4370", sport: "Motorsport")
        #expect(result?.absoluteString == "https://www.thesportsdb.com/poster.jpg")
    }

    @Test func `wrong meeting competition sport and ambiguous matches are rejected`() {
        for events in [[event(date: "1970-01-02")], [event(league: "other")], [event(sport: "Soccer")], [event(name: "Italian Grand Prix")], [event(), event()]] {
            #expect(SportsPosterLookup.poster(in: events, fixture: fixture, leagueID: "4370", sport: "Motorsport") == nil)
        }
    }

    @Test func `team fixture must match both participants in order`() {
        let home = SportsTeam(leagueId: "league", teamId: "home", name: "Arsenal", shortName: "ARS", abbreviation: "ARS")
        let away = SportsTeam(leagueId: "league", teamId: "away", name: "Chelsea", shortName: "CHE", abbreviation: "CHE")
        let match = SportsFixture(id: "match", leagueId: "league", leagueName: "Premier League", leagueAbbreviation: "EPL",
                                  startDate: fixture.startDate, status: SportsFixtureStatus(state: .scheduled),
                                  home: SportsCompetitor(team: home), away: SportsCompetitor(team: away))
        let right = SportsPosterLookup.Event(idLeague: "4328", strSport: "Soccer", dateEvent: "1970-01-01", strEvent: nil,
                                             strHomeTeam: "Arsenal", strAwayTeam: "Chelsea", strPoster: "https://www.thesportsdb.com/poster.jpg")
        let wrong = SportsPosterLookup.Event(idLeague: "4328", strSport: "Soccer", dateEvent: "1970-01-01", strEvent: nil,
                                             strHomeTeam: "Chelsea", strAwayTeam: "Arsenal", strPoster: right.strPoster)
        #expect(SportsPosterLookup.poster(in: [right], fixture: match, leagueID: "4328", sport: "Soccer") != nil)
        #expect(SportsPosterLookup.poster(in: [wrong], fixture: match, leagueID: "4328", sport: "Soccer") == nil)
    }

    @Test func `missing or invalid artwork safely falls back`() {
        for raw in ["", "relative.jpg", "http://example.com/poster.jpg"] {
            #expect(SportsPosterLookup.imageURL(raw) == nil)
        }
        #expect(SportsPosterLookup.imageURL(nil) == nil)
        #expect(SportsPosterLookup.poster(in: [], fixture: fixture, leagueID: "4370", sport: "Motorsport") == nil)
        #expect(SportsPosterLookup.day(Date(timeIntervalSince1970: 86399)) == "1970-01-01")
    }
}
