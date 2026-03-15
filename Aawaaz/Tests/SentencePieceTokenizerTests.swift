import XCTest
@testable import Aawaaz

/// Validates the SentencePiece tokenizer against Python sentencepiece library outputs.
///
/// Golden references generated with:
/// ```python
/// from sentencepiece import SentencePieceProcessor
/// sp = SentencePieceProcessor("sp.model")
/// sp.EncodeAsIds(text)
/// ```
final class SentencePieceTokenizerTests: XCTestCase {

    // Path to the sp.model file in HuggingFace cache.
    // Uses /Users/<user> directly since the test runner's home may point to the app container.
    private static let modelPath: String = {
        let suffix = ".cache/huggingface/hub/models--1-800-BAD-CODE--xlm-roberta_punctuation_fullstop_truecase/snapshots/d1769a597ce8dfaa070d436bc67d4ee761f58884/sp.model"
        // Try real home first (test runner sandbox redirects NSHomeDirectory)
        if let pw = getpwuid(getuid()), let homeDir = pw.pointee.pw_dir {
            let realHome = String(cString: homeDir)
            let path = "\(realHome)/\(suffix)"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // Fallback to NSHomeDirectory
        return "\(NSHomeDirectory())/\(suffix)"
    }()

    private var tokenizer: SentencePieceTokenizer!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.modelPath),
            "sp.model not found at \(Self.modelPath) — download the model first"
        )
        tokenizer = try SentencePieceTokenizer(modelPath: Self.modelPath)
    }

    // MARK: - Vocabulary

    func testVocabSize() {
        XCTAssertEqual(tokenizer.vocabSize, 250002)
    }

    func testSpecialTokenIDs() {
        XCTAssertEqual(tokenizer.bosID, 0)   // <s>
        XCTAssertEqual(tokenizer.padID, 1)   // <pad>
        XCTAssertEqual(tokenizer.eosID, 2)   // </s>
        XCTAssertEqual(tokenizer.unkID, 3)   // <unk>
    }

    func testIdToPiece() {
        XCTAssertEqual(tokenizer.idToPiece(0), "<s>")
        XCTAssertEqual(tokenizer.idToPiece(1), "<pad>")
        XCTAssertEqual(tokenizer.idToPiece(2), "</s>")
        XCTAssertEqual(tokenizer.idToPiece(3), "<unk>")
        XCTAssertEqual(tokenizer.idToPiece(4), ",")
        XCTAssertEqual(tokenizer.idToPiece(5), ".")
    }

    // MARK: - Encoding (golden references from Python)

    func testEncodeSimple() {
        XCTAssertEqual(
            tokenizer.encodeAsIDs("hello world how are you"),
            [33600, 31, 8999, 3642, 621, 398]
        )
    }

    func testEncodeSentence() {
        XCTAssertEqual(
            tokenizer.encodeAsIDs("i think we should meet tomorrow at the office"),
            [17, 5351, 642, 5608, 23356, 127773, 99, 70, 23179]
        )
    }

    func testEncodeLonger() {
        XCTAssertEqual(
            tokenizer.encodeAsIDs("can you check if the server is running and restart it if its not"),
            [831, 398, 12765, 2174, 70, 10723, 83, 51042, 136, 456, 17137, 442, 2174, 6863, 959]
        )
    }

    func testEncodeSingleWord() {
        XCTAssertEqual(tokenizer.encodeAsIDs("hello"), [33600, 31])
        XCTAssertEqual(tokenizer.encodeAsIDs("yes"), [72272])
    }

    func testEncodeHinglish() {
        XCTAssertEqual(
            tokenizer.encodeAsIDs("aaj mera mood acha hai toh main party karunga"),
            [10, 1122, 13057, 52528, 84368, 1337, 77371, 5201, 19085, 1185, 28391]
        )
    }

    func testEncodeMixedCase() {
        XCTAssertEqual(
            tokenizer.encodeAsIDs("so basically I was thinking about the project"),
            [221, 198343, 87, 509, 47644, 1672, 70, 13452]
        )
    }

    func testEncodeWeather() {
        XCTAssertEqual(
            tokenizer.encodeAsIDs("the weather is nice today"),
            [70, 92949, 83, 26267, 18925]
        )
    }

    func testEncodeCamelCase() {
        XCTAssertEqual(
            tokenizer.encodeAsIDs("getUserById"),
            [2046, 1062, 2189, 75358, 568, 71]
        )
    }

    func testEncodeDashWords() {
        XCTAssertEqual(
            tokenizer.encodeAsIDs("npm install dash dash save"),
            [25037, 39, 20600, 381, 127, 381, 127, 30098]
        )
    }

    func testEncodeEmpty() {
        XCTAssertEqual(tokenizer.encodeAsIDs(""), [])
        XCTAssertEqual(tokenizer.encodeAsIDs("   "), [])
    }

    // MARK: - Normalization

    func testNormalizationCollapseWhitespace() {
        // Multiple spaces should be collapsed to single space
        let idsNormal = tokenizer.encodeAsIDs("hello world")
        let idsExtra = tokenizer.encodeAsIDs("hello  world")
        XCTAssertEqual(idsNormal, idsExtra)
    }

    func testNormalizationNFKC() {
        // ﬁ (U+FB01) should normalize to "fi"
        let ids = tokenizer.encodeAsIDs("ﬁnd")
        let idsNormal = tokenizer.encodeAsIDs("find")
        XCTAssertEqual(ids, idsNormal)
    }
}
