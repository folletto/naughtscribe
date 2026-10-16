import Testing
import TranscriptionCore
@testable import NaughtScribe

struct EngineRegistryTests {
    @Test func preferredEngineIsUsedWhenItCanRun() async {
        let registry = EngineRegistry(engines: [
            FakeEngine(id: "best", priority: 0),
            FakeEngine(id: "preferred", priority: 5),
        ])
        let engine = await registry.resolve(preferredID: "preferred")
        #expect(engine?.descriptor.id == "preferred")
    }

    @Test func unavailablePreferredEngineFallsBackToTheMostPreferredAvailableOne() async {
        let registry = EngineRegistry(engines: [
            FakeEngine(id: "preferred", priority: 0, availability: .unavailable(reason: "Not on this Mac.")),
            FakeEngine(id: "third", priority: 2),
            FakeEngine(id: "second", priority: 1),
        ])
        let engine = await registry.resolve(preferredID: "preferred")
        #expect(engine?.descriptor.id == "second")
    }

    @Test func unknownPreferredIDFallsBackToTheMostPreferredAvailableEngine() async {
        let registry = EngineRegistry(engines: [
            FakeEngine(id: "third", priority: 2),
            FakeEngine(id: "first", priority: 0),
        ])
        let engine = await registry.resolve(preferredID: "not.installed")
        #expect(engine?.descriptor.id == "first")
    }

    @Test func automaticChoiceUsesTheMostPreferredAvailableEngine() async {
        let registry = EngineRegistry(engines: [
            FakeEngine(id: "unavailable", priority: 0, availability: .unavailable(reason: "Not on this Mac.")),
            FakeEngine(id: "available", priority: 1),
        ])
        let engine = await registry.resolve(preferredID: nil)
        #expect(engine?.descriptor.id == "available")
    }

    @Test func resolveReturnsNilWhenNoEngineCanRun() async {
        let registry = EngineRegistry(engines: [
            FakeEngine(id: "a", availability: .unavailable(reason: "No.")),
            FakeEngine(id: "b", availability: .unavailable(reason: "No.")),
        ])
        let engine = await registry.resolve(preferredID: "a")
        #expect(engine == nil)
    }

    @Test func sortedEnginesListTheMostPreferredFirst() {
        let registry = EngineRegistry(engines: [
            FakeEngine(id: "c", priority: 3),
            FakeEngine(id: "a", priority: 1),
            FakeEngine(id: "b", priority: 2),
        ])
        #expect(registry.sortedEngines().map { $0.descriptor.id } == ["a", "b", "c"])
    }
}
