import Testing
@testable import OpenSpellCore

struct LayoutGuardTests {
    private func restore(_ original: String, _ corrected: String) -> String {
        LayoutGuard.restore(corrected, from: original)
    }

    @Test func keepsCorrectionsThatKeptTheLayout() {
        #expect(restore("I beleive it", "I believe it") == "I believe it")
        #expect(restore("hi\n\nteh end", "Hi\n\nThe end") == "Hi\n\nThe end")
        #expect(restore("alot of people", "a lot of people") == "a lot of people")
        #expect(restore("I go store", "I go to the store") == "I go to the store")
    }

    @Test func restoresLineBreaksBlankLinesAndTabs() {
        #expect(restore("hi team,\n\nteh plan", "Hi team, the plan") == "Hi team,\n\nthe plan")
        #expect(restore("a\tb\tteh", "a b the") == "a\tb\tthe")
        #expect(restore("line one\r\nline too", "Line one line two") == "Line one\r\nline two")
        #expect(restore("    indented code is fun", "indented code is fun") == "indented code is fun")
        #expect(restore("two  spaces", "two spaces") == "two  spaces")
        #expect(restore("Bonjour\u{A0}!", "Bonjour !") == "Bonjour\u{A0}!")
    }

    @Test func restoresTheLineBreakAroundChangedWords() {
        // A word fixed next to the line break.
        #expect(restore("I beleive\nwe can", "I believe we can") == "I believe\nwe can")
        // A word added where the line break was.
        #expect(restore("I went\nthe store", "I went to the store") == "I went\nto the store")
        // A word dropped next to the line break.
        #expect(restore("it is is\nfine", "it is fine") == "it is\nfine")
        // Words joined next to the line break.
        #expect(restore("alot\nof people", "a lot of people") == "a lot\nof people")
    }

    @Test func restoresListMarkers() {
        #expect(restore("- teh one\n- two", "The one\nTwo") == "- The one\n- Two")
        #expect(restore("1. teh one\n2. two", "1) The one\n2) Two") == "1. The one\n2. Two")
        #expect(restore("• one\n• two", "- one\n- two") == "• one\n• two")
    }

    @Test func restoresMarkdown() {
        #expect(restore("the **dealine** is today", "The deadline is today") == "The **deadline** is today")
        #expect(restore("see `teh_var` now", "See the_var now") == "See `teh_var` now")
        #expect(restore("_realy_ good", "_really_ good") == "_really_ good")
    }

    @Test func restoresProtectedTokens() {
        #expect(restore("go to https://exemple.com/a_b", "Go to https://example.com/a-b") == "Go to https://exemple.com/a_b")
        #expect(restore("mail jon@exmple.com", "Mail jon@example.com") == "Mail jon@exmple.com")
        #expect(restore("ask @jhon", "Ask @john") == "Ask @jhon")
        #expect(restore("it costs 3.5 euros", "It costs 3,5 euros") == "It costs 3.5 euros")
        #expect(restore("hello {nmae}", "Hello {name}") == "Hello {nmae}")
        // Punctuation added after a protected token is a fix.
        #expect(restore("see https://example.com", "See https://example.com.") == "See https://example.com.")
    }

    @Test func protectedTokens() {
        for token in ["https://a.b", "www.example.com", "a@b.co", "@name", "#tag", "snake_case", "a/b", "C:\\dir",
                      "file.txt", "3.5", "10:30", "`x`", "{name}"] {
            #expect(LayoutGuard.isProtected(Substring(token)), "\(token)")
        }
        for token in ["word", "U.S.", "it's", "end.", "peux-tu", "#", "@"] {
            #expect(!LayoutGuard.isProtected(Substring(token)), "\(token)")
        }
    }
}
