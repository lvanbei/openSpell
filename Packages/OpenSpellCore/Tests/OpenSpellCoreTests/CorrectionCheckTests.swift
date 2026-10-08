import Testing
@testable import OpenSpellCore

struct CorrectionCheckTests {
    private func accepts(_ original: String, _ output: String) -> Bool {
        CorrectionCheck.correction(in: output, of: original) == output
    }

    @Test func acceptsCorrections() {
        #expect(accepts("I beleive we can definately ship the new featur by tommorow.",
                        "I believe we can definitely ship the new feature by tomorrow."))
        #expect(accepts("des appartemet", "des appartement"))
        #expect(accepts("Module photo defectueux", "Module photo défectueux"))
        #expect(accepts("Seuille en aluminium", "Seuil en aluminium"))
        #expect(accepts("peux-tu me faire un compte rendu condencé temporelle de cette situation",
                        "Peux-tu me faire un compte rendu condensé temporel de cette situation ?"))
        #expect(accepts("when I switch between tabs the windows resizes slowly and sometimes it bugging .. can you fix this or apply a proper solution ?",
                        "When I switch between tabs, the windows resizes slowly, and sometimes it's bugging. Can you fix this or apply a proper solution?"))
        #expect(accepts("Same for the word : chassis, it should be : ", "Same for the word: chassis, it should be:"))
        #expect(accepts("can you tell me wat time it is ?", "Can you tell me what time it is?"))
        #expect(accepts("FR : Longueur des châssis de la face arrière (appartements communs + chambre 2) n’est pas la même.",
                        "FR : La longueur des châssis de la face arrière (appartements communs + chambre 2) n’est pas la même."))
        #expect(accepts("Hi Sarah,\nI beleive we can definately ship it.", "Hi Sarah,\nI believe we can definitely ship it."))
        #expect(accepts("unchanged text", "unchanged text"))
    }

    @Test func acceptsSmallGrammarFixes() {
        #expect(accepts("teh", "the"))
        #expect(accepts("I go store", "I go to the store"))
        #expect(accepts("they was going home now", "they were going home now"))
        #expect(accepts("alot of people came", "a lot of people came"))
        #expect(accepts("cava bien", "Ça va bien"))
    }

    @Test func rejectsReplies() {
        #expect(!accepts("imprimer un ticket vers les accueils",
                         "Pour imprimer un ticket vers les accueils, vous pouvez suivre les étapes suivantes :\n\n1. Ouvrez votre logiciel de traitement de texte.\n2. Créez un nouveau document."))
        #expect(!accepts("can you tell me wat time it is ?", "I don't have access to the current time."))
        #expect(!accepts("check mu speling", "Can you check my spelling?"))
        #expect(!accepts("I beleive we can", "I believe we can do it. Let's get started on the project right away."))
    }

    @Test func rejectsTranslations() {
        #expect(!accepts("des appartement", "des apartments (French to English translation: apartments)"))
        #expect(!accepts("des appartement", "the apartment"))
        #expect(!accepts("Je suis très fatigué aujourd'hui", "I am very tired today"))
    }

    @Test func rejectsPartsAndSummaries() {
        let text = "The meeting started late because the projector didnt work. We discused the budget, the hiring plan and the new office. Nobody agreed on anything, so we will meet again next week."
        #expect(!accepts(text, "The meeting started late because the projector didn't work. We discussed the budget, the hiring plan and the new office."))
        #expect(!accepts(text, "We discussed the budget, the hiring plan and the new office. Nobody agreed on anything, so we will meet again next week."))
        #expect(!accepts(text, "The meeting achieved nothing and will be repeated next week."))
        #expect(CorrectionCheck.correction(in: "", of: text) == nil)
        #expect(CorrectionCheck.correction(in: " \n", of: text) == nil)
    }

    @Test func keepsTheCorrectionInsideLabelsAndNotes() {
        let fixed = "I believe we can definitely ship it by tomorrow."
        let original = "I beleive we can definately ship it by tommorow."
        #expect(CorrectionCheck.correction(in: "Here is the corrected text:\n\n\(fixed)\n\nI fixed three typos.", of: original) == fixed)
        #expect(CorrectionCheck.correction(in: "Corrected: \(fixed)", of: original) == fixed)
        #expect(CorrectionCheck.correction(in: "\(fixed)\n\nChanges: beleive → believe", of: original) == fixed)
        #expect(CorrectionCheck.correction(in: "Voici le texte corrigé :\nDes appartements.", of: "des appartement") == "Des appartements.")
        #expect(CorrectionCheck.correction(in: "Subject: Meeting tomorrow", of: "Subject: Meeting tomorow") == "Subject: Meeting tomorrow")
    }

    @Test func asksAgainWithAReminderAfterAReply() async throws {
        let model = FakeModel(["Sure! To print a ticket, open the app and tap Print.", "Imprimer un ticket vers l’accueil"])
        let fixed = try await CorrectionService.ask("imprimer un ticket vers l’acceuil", system: "s") { _, user in await model.answer(user) }
        #expect(fixed == "Imprimer un ticket vers l’accueil")
        #expect(await model.users == [CorrectionPrompt.user("imprimer un ticket vers l’acceuil"),
                                      CorrectionPrompt.retry("imprimer un ticket vers l’acceuil")])
    }

    @Test func neverReturnsSomethingElse() async {
        let model = FakeModel(["I am very tired today", "I'm really tired today"])
        await #expect(throws: NotACorrectionError.self) {
            try await CorrectionService.ask("Je suis très fatigué aujourd'hui", system: "s") { _, user in await model.answer(user) }
        }
    }

    @Test func treatsAnEmptyAnswerAsAFailure() async {
        let model = FakeModel(["<think>hmm</think>", "  "])
        await #expect(throws: NotACorrectionError.self) {
            try await CorrectionService.ask("keep me", system: "s") { _, user in await model.answer(user) }
        }
    }

    @Test func restoresWhitespaceAndApostrophes() async throws {
        let model = FakeModel(["\"La longueur n'est pas la même.\""])
        let fixed = try await CorrectionService.ask("  longueur n’est pas la meme\n", system: "s") { _, user in await model.answer(user) }
        #expect(fixed == "  La longueur n’est pas la même.\n")
    }
}

private actor FakeModel {
    private var answers: [String]
    private(set) var users: [String] = []

    init(_ answers: [String]) { self.answers = answers }

    func answer(_ user: String) -> String {
        users.append(user)
        return answers.removeFirst()
    }
}
