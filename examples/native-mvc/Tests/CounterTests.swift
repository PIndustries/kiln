import Testing
@testable import KilnApplication

@Test func counterStateAndNoteAreIndependent() async {
    let model = CounterModel()
    await model.increment()
    await model.rename("A new note")
    let (count, note) = await model.snapshot()
    #expect(count == 1)
    #expect(note == "A new note")
}
