import Foundation

// The Hugging Face SentencePiece Unigram tokenizer the frozen candidates were trained with:
// whitespace Replace, NFC and right Strip normalizers, an always-prepended Metaspace split and
// Viterbi segmentation. The golden input ids check every step.
public struct Tokenizer: Sendable {
  public static let cls: Int32 = 1
  public static let sep: Int32 = 2
  public static let pad: Int32 = 0

  private let pieces: [String: (id: Int32, score: Double)]
  // Added tokens such as "[SEP]", matched in the raw text before normalization.
  private let added: [(content: String, id: Int32)]
  private let longest: Int
  private let unknown: Int32
  private let unknownScore: Double

  public init(contentsOf url: URL) throws {
    struct File: Decodable {
      struct Model: Decodable {
        let type: String
        let unk_id: Int32
        let vocab: [Piece]
      }
      struct Piece: Decodable {
        let text: String
        let score: Double
        init(from decoder: any Decoder) throws {
          var pair = try decoder.unkeyedContainer()
          text = try pair.decode(String.self)
          score = try pair.decode(Double.self)
        }
      }
      struct Added: Decodable {
        let id: Int32
        let content: String
        let normalized: Bool
      }
      let model: Model
      let added_tokens: [Added]
    }
    let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    let model = file.model
    // Matching raw text equals Hugging Face's normalized matching when normalizing is a no-op.
    guard file.added_tokens.allSatisfy({ !$0.normalized || Self.normalize($0.content) == $0.content })
    else {
      throw SpikeError.unsupported("normalized added tokens")
    }
    added = file.added_tokens.map { ($0.content, $0.id) }.sorted { $0.0.count > $1.0.count }
    guard model.type == "Unigram" else { throw SpikeError.unsupported("tokenizer \(model.type)") }
    var pieces: [String: (id: Int32, score: Double)] = [:]
    pieces.reserveCapacity(model.vocab.count)
    for (index, piece) in model.vocab.enumerated() where pieces[piece.text] == nil {
      pieces[piece.text] = (Int32(index), piece.score)
    }
    self.pieces = pieces
    longest = model.vocab.map(\.text.unicodeScalars.count).max() ?? 1
    unknown = model.unk_id
    // Hugging Face scores an unknown character 10 below the lowest piece.
    unknownScore = (model.vocab.map(\.score).min() ?? 0) - 10
  }

  // Ids without the [CLS]/[SEP] wrapping. Added-token text splits the input first, and each
  // remaining segment is normalized and segmented on its own, as in Hugging Face.
  public func encode(_ text: String) -> [Int32] {
    var ids: [Int32] = []
    var rest = Substring(text)
    while !rest.isEmpty {
      // The earliest added token, the longest one where several start together.
      let next = added.compactMap { token in rest.range(of: token.content).map { ($0, token.id) } }
        .min { $0.0.lowerBound < $1.0.lowerBound }
      let segment = next.map { rest[..<$0.0.lowerBound] } ?? rest
      let normalized = Self.normalize(String(segment))
      if !normalized.isEmpty {
        for word in words(normalized) { ids += self.segment(word) }
      }
      guard let (range, id) = next else { break }
      ids.append(id)
      rest = rest[range.upperBound...]
    }
    return ids
  }

  static func normalize(_ text: String) -> String {
    // Replace(`\s{2,}|[\n\r\t]`, " "), then NFC, then strip trailing whitespace.
    var scalars = String.UnicodeScalarView()
    var run: [Unicode.Scalar] = []
    func flush() {
      if run.count >= 2 || (run.count == 1 && ["\n", "\r", "\t"].contains(run[0])) {
        scalars.append(" ")
      } else {
        scalars.append(contentsOf: run)
      }
      run.removeAll()
    }
    for scalar in text.unicodeScalars {
      if scalar.properties.isWhitespace {
        run.append(scalar)
      } else {
        flush()
        scalars.append(scalar)
      }
    }
    flush()
    var normalized = String(scalars).precomposedStringWithCanonicalMapping.unicodeScalars
    while let last = normalized.last, last.properties.isWhitespace { normalized.removeLast() }
    return String(normalized)
  }

  // Metaspace: spaces become "▁", one is prepended, and each "▁" starts a new word.
  func words(_ text: String) -> [[Unicode.Scalar]] {
    let marker: Unicode.Scalar = "\u{2581}"
    var scalars = text.unicodeScalars.map { $0 == " " ? marker : $0 }
    if scalars.first != marker { scalars.insert(marker, at: 0) }
    var words: [[Unicode.Scalar]] = []
    for scalar in scalars {
      if scalar == marker || words.isEmpty {
        words.append([scalar])
      } else {
        words[words.count - 1].append(scalar)
      }
    }
    return words
  }

  // Viterbi over pieces, matching Hugging Face's tie order (shorter pieces first, strict
  // improvement wins) and fusing consecutive unknown characters into one unknown token.
  func segment(_ word: [Unicode.Scalar]) -> [Int32] {
    struct Node {
      var score = -Double.infinity
      var start = -1
      var id: Int32 = -1
    }
    var best = [Node](repeating: Node(), count: word.count + 1)
    best[0].score = 0
    for start in 0..<word.count where best[start].start >= 0 || start == 0 {
      let base = best[start].score
      var single = false
      for length in 1...min(longest, word.count - start) {
        let end = start + length
        var text = String.UnicodeScalarView()
        text.append(contentsOf: word[start..<end])
        guard let piece = pieces[String(text)] else { continue }
        if best[end].start < 0 || base + piece.score > best[end].score {
          best[end] = Node(score: base + piece.score, start: start, id: piece.id)
        }
        if length == 1 { single = true }
      }
      if !single, best[start + 1].start < 0 || base + unknownScore > best[start + 1].score {
        best[start + 1] = Node(score: base + unknownScore, start: start, id: unknown)
      }
    }
    var ids: [Int32] = []
    var end = word.count
    while end > 0 {
      let node = best[end]
      if !(node.id == unknown && ids.last == unknown) { ids.append(node.id) }
      end = node.start
    }
    return ids.reversed()
  }
}

public enum SpikeError: Error, Equatable {
  case unsupported(String)
  case missing(String)
  case cancelled
}
