import Testing
@testable import OpenSpellCore

struct CorrectionPromptTests {
    @Test func stripsThinkBlocks() {
        #expect(CorrectionPrompt.postProcess("<think>hmm</think>Hello world.", original: "helo world.") == "Hello world.")
        #expect(CorrectionPrompt.postProcess("reasoning…</think> Hello.", original: "helo.") == "Hello.")
    }

    @Test func stripsCodeFences() {
        #expect(CorrectionPrompt.postProcess("```\nFixed text.\n```", original: "fixd text.") == "Fixed text.")
        #expect(CorrectionPrompt.postProcess("```text\nFixed.\n```", original: "fixd.") == "Fixed.")
    }

    @Test func stripsEchoedTextTagsUnlessTheOriginalHasThem() {
        #expect(CorrectionPrompt.postProcess("<text>Fixed.</text>", original: "fixd.") == "Fixed.")
        #expect(CorrectionPrompt.postProcess("Use <text> here.", original: "Use <text> hre.") == "Use <text> here.")
    }

    @Test func removesWrappingQuotesTheOriginalDidNotHave() {
        #expect(CorrectionPrompt.postProcess("\"Fixed.\"", original: "fixd.") == "Fixed.")
        #expect(CorrectionPrompt.postProcess("“Fixed.”", original: "fixd.") == "Fixed.")
        #expect(CorrectionPrompt.postProcess("\"Fixed.\"", original: "\"fixd.\"") == "\"Fixed.\"")
    }

    @Test func restoresSurroundingWhitespace() {
        #expect(CorrectionPrompt.postProcess("Hello world", original: "  helo wrld\n") == "  Hello world\n")
    }

    @Test func fallsBackToTheOriginalOnEmptyOutput() {
        #expect(CorrectionPrompt.postProcess("  ", original: "keep me") == "keep me")
        #expect(CorrectionPrompt.postProcess("<think>only thoughts</think>", original: "keep me") == "keep me")
    }

    @Test func languageHint() {
        #expect(CorrectionPrompt.system(language: .french).contains("The text is written in French."))
        #expect(!CorrectionPrompt.system(language: .auto).contains("The text is written in"))
        #expect(CorrectionPrompt.user("hi") == "<text>hi</text>")
    }
}
