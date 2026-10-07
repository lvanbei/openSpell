import Testing
@testable import OpenSpellCore

struct ReplacementPlannerTests {
    /// What the document holds after applying `plan` to `original` sitting just before the caret.
    private func apply(_ plan: ReplacementPlan, to original: String) -> String {
        let kept = plan.keptSuffix.count
        #expect(original.hasSuffix(plan.keptSuffix))
        #expect(plan.deletions + kept <= original.count)
        return String(original.dropLast(kept + plan.deletions)) + plan.insertion + plan.keptSuffix
    }

    @Test func identicalTextNeedsNoEdits() {
        #expect(ReplacementPlanner.plan(from: "Fine.", to: "Fine.").isEmpty)
        #expect(ReplacementPlanner.plan(from: "", to: "").isEmpty)
    }

    @Test func retypesFromTheFirstChange() {
        let plan = ReplacementPlanner.plan(from: "I beleive its definately ready.", to: "I believe it's definitely ready.")
        #expect(plan.keptSuffix.isEmpty)
        #expect(plan.deletions == 26)
        #expect(plan.insertion == "ieve it's definitely ready.")
    }

    @Test func keepsALongUnchangedTail() {
        let tail = " and the rest of this paragraph is perfectly fine as it is."
        let plan = ReplacementPlanner.plan(from: "Teh start" + tail, to: "The start" + tail)
        #expect(plan.keptSuffix == " start" + tail)
        #expect(plan.deletions == 2)
        #expect(plan.insertion == "he")
        #expect(plan.caretOffset == plan.keptSuffix.utf16.count)
    }

    @Test func countsGraphemesForDeletesAndUTF16ForTheCaret() {
        let plan = ReplacementPlanner.plan(from: "Family 👨‍👩‍👧 teh", to: "Family 👨‍👩‍👧 the")
        #expect(plan.deletions == 2)
        #expect(plan.insertion == "he")

        let kept = ReplacementPlanner.plan(from: "teh 👨‍👩‍👧", to: "the 👨‍👩‍👧", minKeptSuffix: 0)
        #expect(kept.keptSuffix == " 👨‍👩‍👧")
        #expect(kept.deletions == 2)
        #expect(kept.caretOffset == 9)
    }

    @Test func handlesOverlapsAtTheEdges() {
        let shorter = ReplacementPlanner.plan(from: "aaa", to: "aa", minKeptSuffix: 0)
        #expect(shorter.deletions + shorter.keptSuffix.count <= 3)
        #expect(apply(shorter, to: "aaa") == "aa")

        let longer = ReplacementPlanner.plan(from: "helo", to: "hello", minKeptSuffix: 0)
        #expect(longer.deletions == 0)
        #expect(longer.insertion == "l")
        #expect(longer.keptSuffix == "o")
    }

    @Test(arguments: [
        ("I beleive its definately ready.", "I believe it's definitely ready."),
        ("cafe ole", "café olé"),
        ("我喜欢平果。\n第二行没有错。", "我喜欢苹果。\n第二行没有错。"),
        ("first line\nsecnd line\n", "first line\nsecond line\n"),
        ("Hi 👋🏽 thier", "Hi 👋🏽 their"),
        ("", "Inserted."),
        ("Removed.", ""),
        ("مرحبا بالعالم", "مرحباً بالعالم"),
    ])
    func rebuildsTheCorrectedText(_ texts: (String, String)) {
        for minKept in [0, 3, 40] {
            let plan = ReplacementPlanner.plan(from: texts.0, to: texts.1, minKeptSuffix: minKept)
            #expect(apply(plan, to: texts.0) == texts.1)
            #expect(plan.keptSuffix.isEmpty || plan.keptSuffix.count >= minKept)
        }
    }
}
