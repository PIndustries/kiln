import Foundation

actor CounterModel {
    private var count = 0
    private var note = "State and HTML live on the server."
    func snapshot() -> (Int, String) { (count, note) }
    func increment() { count += 1 }
    func rename(_ text: String) { note = String(text.prefix(120)) }
}
