import Foundation
import KilnWeb

/// Handles live requests and model changes; the view only receives values.
actor CounterController: LiveView {
    let model: CounterModel
    let hub: LiveHub
    init(model: CounterModel, hub: LiveHub) { self.model = model; self.hub = hub }

    func render() async -> HTML {
        let (count, note) = await model.snapshot()
        return CounterPage(count: count, note: note).render()
    }

    func handle(_ event: LiveEvent) async throws {
        switch event.name {
        case "increment": await model.increment()
        case "rename":
            guard let value = event.values["message"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebError(422) }
            await model.rename(value)
        default: throw WebError(400)
        }
        await hub.publish("counter")
    }
}
