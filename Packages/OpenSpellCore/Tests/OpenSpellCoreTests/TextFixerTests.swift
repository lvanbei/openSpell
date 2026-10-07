import Foundation
import Testing
@testable import OpenSpellCore

@MainActor
struct TextFixerTests {
    let fixer = TextFixer(timeout: .milliseconds(300))
    let tail = " and the rest of this paragraph is fine as it is 👨‍👩‍👧 really."

    @Test func capturesTheSelectionFirst() throws {
        let doc = FakeDocument("Hello wrld and more", selecting: 6..<10)
        let capture = try #require(TextFixer.capture(from: doc))
        #expect(capture.text == "wrld")
        #expect(capture.isSelection)
    }

    @Test func capturesTheTextBeforeTheCaret() throws {
        let capture = try #require(TextFixer.capture(from: FakeDocument("Hello wrld")))
        #expect(capture.text == "Hello wrld")
        #expect(!capture.isSelection)
    }

    @Test func ignoresBlankText() {
        #expect(TextFixer.capture(from: FakeDocument(" \n ")) == nil)
        #expect(TextFixer.capture(from: FakeDocument("Text  then", selecting: 4..<6)) == nil)
    }

    @Test func refreshReadsTextTypedOutsideTheKeyboard() async throws {
        let doc = FakeDocument("Hi")
        doc.typeElsewhere(" thier")
        #expect(TextFixer.capture(from: doc)?.text == "Hi")
        #expect(await fixer.refresh(doc))
        #expect(TextFixer.capture(from: doc)?.text == "Hi thier")
        #expect(doc.caret == doc.text.count)
    }

    @Test func refreshStepsOverAWholeEmoji() async {
        let doc = FakeDocument("Done 👨‍👩‍👧")
        #expect(await fixer.refresh(doc))
        #expect(doc.caret == doc.text.count)
    }

    @Test func leavesTheDocumentAloneWhenTextWasTypedElsewhereMeanwhile() async throws {
        // The Simulator bug: deleting by the cached length from the real caret corrupted the text.
        let doc = FakeDocument("Hi Sarah, I beleive it.")
        let capture = try #require(TextFixer.capture(from: doc))
        doc.typeElsewhere("xyz")
        #expect(await fixer.apply("Hi Sarah, I believe it.", over: capture, in: doc) == .textChanged)
        #expect(doc.string == "Hi Sarah, I beleive it.xyz")
        #expect(doc.textEdits == 0)
    }

    @Test func replacesTheTextBeforeTheCaret() async throws {
        let doc = FakeDocument("I beleive its definately ready.")
        let capture = try #require(TextFixer.capture(from: doc))
        let result = await fixer.apply("I believe it's definitely ready.", over: capture, in: doc)
        #expect(result == .replaced)
        #expect(doc.string == "I believe it's definitely ready.")
        #expect(doc.caret == doc.text.count)
        #expect(fixer.canUndo)
    }

    @Test func replacesTheSelection() async throws {
        let doc = FakeDocument("Hello wrld and more", selecting: 6..<10)
        let capture = try #require(TextFixer.capture(from: doc))
        #expect(await fixer.apply("world", over: capture, in: doc) == .replaced)
        #expect(doc.string == "Hello world and more")
    }

    @Test func keepsALongTailByMovingTheCaret() async throws {
        let doc = FakeDocument("Teh start" + tail)
        let capture = try #require(TextFixer.capture(from: doc))
        #expect(await fixer.apply("The start" + tail, over: capture, in: doc) == .replaced)
        #expect(doc.string == "The start" + tail)
        #expect(doc.caret == doc.text.count)
        #expect(doc.textEdits == 3)
    }

    @Test func retypesTheTailWhenTheHostCountsCharacters() async throws {
        let doc = FakeDocument("Some words come before it. Teh start" + tail)
        doc.unit = .characters
        let capture = try #require(TextFixer.capture(from: doc))
        #expect(await fixer.apply("Some words come before it. The start" + tail, over: capture, in: doc) == .replaced)
        #expect(doc.string == "Some words come before it. The start" + tail)
        #expect(doc.caret == doc.text.count)
    }

    @Test func leavesTheDocumentAloneWhenTheUserTypedMeanwhile() async throws {
        let doc = FakeDocument("Helo")
        let capture = try #require(TextFixer.capture(from: doc))
        doc.insertText(" there")
        #expect(await fixer.apply("Hello", over: capture, in: doc) == .textChanged)
        #expect(doc.string == "Helo there")
        #expect(!fixer.canUndo)
    }

    @Test func leavesOtherDocumentsAlone() async throws {
        let doc = FakeDocument("Helo")
        let capture = try #require(TextFixer.capture(from: doc))
        doc.documentIdentifier = UUID()
        #expect(await fixer.apply("Hello", over: capture, in: doc) == .textChanged)
        #expect(doc.string == "Helo")
    }

    @Test func waitsForSlowHosts() async throws {
        let doc = FakeDocument("Teh start" + tail)
        doc.updateDelay = .milliseconds(80)
        let capture = try #require(TextFixer.capture(from: doc))
        #expect(await fixer.apply("The start" + tail, over: capture, in: doc) == .replaced)
        #expect(doc.string == "The start" + tail)
    }

    @Test func writesNothingWhenTheHostDoesNotReport() async throws {
        let doc = FakeDocument("Helo")
        let capture = try #require(TextFixer.capture(from: doc))
        doc.frozen = true
        #expect(await fixer.apply("Hello", over: capture, in: doc) == .unreadable)
        #expect(doc.string == "Helo")
        #expect(doc.textEdits == 0)
    }

    @Test func correctsOnlyTheVisibleContext() async throws {
        let doc = FakeDocument("Earlier text stays as is. Ths is it.", contextLimit: 11)
        let capture = try #require(TextFixer.capture(from: doc))
        #expect(capture.text == " Ths is it.")
        #expect(await fixer.apply(" This is it.", over: capture, in: doc) == .replaced)
        #expect(doc.string == "Earlier text stays as is. This is it.")
    }

    @Test func undoRestoresTheOriginal() async throws {
        let doc = FakeDocument("Teh start" + tail)
        let capture = try #require(TextFixer.capture(from: doc))
        _ = await fixer.apply("The start" + tail, over: capture, in: doc)
        #expect(await fixer.undo(in: doc))
        #expect(doc.string == "Teh start" + tail)
        #expect(!fixer.canUndo)
    }

    @Test func undoRefusesOnceTheTextMovedOn() async throws {
        let doc = FakeDocument("Helo")
        let capture = try #require(TextFixer.capture(from: doc))
        _ = await fixer.apply("Hello", over: capture, in: doc)
        doc.typeElsewhere(" there")
        #expect(await fixer.undo(in: doc) == false)
        #expect(doc.string == "Hello there")
    }
}
