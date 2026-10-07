import Testing
@testable import OpenSpellCore

struct TextChunkerTests {
    private func chunks(_ text: String, budget: Int) -> [String] {
        let pieces = TextChunker.chunks(of: text, budget: budget) { $0.utf8.count }.map(String.init)
        #expect(pieces.joined() == text)
        return pieces
    }

    @Test func keepsTextThatFitsWhole() {
        #expect(chunks("I beleive its definately ready.", budget: 100) == ["I beleive its definately ready."])
    }

    @Test func groupsParagraphsUpToTheBudget() {
        let text = "First paragraph here.\nSecond one.\n\nThird paragraph, a bit longer."
        let pieces = chunks(text, budget: 40)
        #expect(pieces == ["First paragraph here.\nSecond one.\n\n", "Third paragraph, a bit longer."])
    }

    @Test func splitsALongParagraphAtSentenceEnds() {
        let text = "This is the first sentence. This is the second one. And a third."
        let pieces = chunks(text, budget: 30)
        #expect(pieces == ["This is the first sentence. ", "This is the second one. ", "And a third."])
    }

    @Test func fallsBackToWordsAndCharacters() {
        let words = chunks("alpha beta gamma delta epsilon", budget: 12)
        #expect(words.allSatisfy { $0.utf8.count <= 12 })
        #expect(words.first == "alpha beta ")

        let blob = String(repeating: "x", count: 25)
        #expect(chunks(blob, budget: 10).map(\.count) == [10, 10, 5])
    }

    @Test func neverCutsInsideACharacter() {
        let text = "Family 👨‍👩‍👧 trip.\nCafé déjà vu 漢字かな交じり文。\n" + String(repeating: "👍", count: 9)
        for budget in [8, 13, 21, 34] {
            for piece in chunks(text, budget: budget) {
                #expect(piece.utf8.count <= max(budget, "👨‍👩‍👧".utf8.count))
            }
        }
    }
}
