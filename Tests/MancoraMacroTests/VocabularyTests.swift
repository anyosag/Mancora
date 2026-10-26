import Testing

import MancoraMacro

/// The names editors color: the keywords and every kind of built-in function.
@Suite("Macro vocabulary")
struct VocabularyTests {
    @Test func namesTheKeywordsAndBuiltIns() {
        let (keywords, functions) = MancoraMacro.vocabulary
        let words = ["macro", "function", "var", "if", "else", "for", "while", "do", "return", "true", "false", "PI", "NaN"]
        #expect(words.allSatisfy(keywords.contains))
        let names = ["run", "print", "getTitle", "d2s", "newArray", "Table", "Math", "requires"]
        #expect(names.allSatisfy(functions.contains))
        #expect(keywords.isDisjoint(with: functions))
    }
}
