import SwiftUI
import Testing
@testable import OpenSpellUI

struct WordDiffTests {
    private typealias Strike = AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute
    private typealias Foreground = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute

    @Test func tokensKeepWhitespaceRuns() {
        #expect(WordDiff.tokens("Hi  there\nyou") == ["Hi", "  ", "there", "\n", "you"])
        #expect(WordDiff.tokens("") == [])
    }

    @Test func unchangedTextHasNoMarkup() {
        let diff = WordDiff.attributed(from: "Same text.", to: "Same text.")
        #expect(String(diff.characters) == "Same text.")
        #expect(diff.runs.allSatisfy { $0[Strike.self] == nil && $0[Foreground.self] == nil })
    }

    @Test func showsRemovedThenInsertedWords() {
        let diff = WordDiff.attributed(from: "I beleive it", to: "I believe it")
        #expect(String(diff.characters) == "I beleivebelieve it")
        let struck = diff.runs.filter { $0[Strike.self] != nil }.map { String(diff[$0.range].characters) }
        #expect(struck == ["beleive"])
    }
}
