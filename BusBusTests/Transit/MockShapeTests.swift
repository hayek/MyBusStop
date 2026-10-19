import Testing
@testable import BusBus

/// The staged app's line card draws the mock's shapes, so every one of them has to pass the same
/// check a real feed's does.
struct MockShapeTests {
    @Test(arguments: MockScenario.allCases)
    func everyFixtureLineHasAShapeThatPasses(scenario: MockScenario) async throws {
        let mock = MockTransitProvider(scenario: scenario, onwardCount: 2)
        for fixture in scenario.lines {
            let line = TransitLine(id: fixture.id, shortName: fixture.number)
            let pattern = try await mock.routePattern(for: line)
            let shape = try await mock.routeShape(for: line, pattern: pattern)
            let verdict = ShapeCheck.verdict(shape, stops: pattern.stops.map(\.stop.location))
            #expect(verdict.passes, "line \(fixture.id) in \(scenario): \(verdict.reason ?? "")")
        }
    }
}
