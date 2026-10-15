import Foundation

// One message as the benchmark's corpus records it: public or synthetic sample input only.
public struct Message: Codable, Sendable {
  public let id: String
  public let language: String
  public let from: String
  public let reply_to: String
  public let list: Bool
  public let recipients: Int
  public let subject: String
  public let body: String
}

// A Custom Category definition from categories-v1.json, per language.
public struct CustomCategory: Codable, Sendable {
  public struct Text: Codable, Sendable {
    public let name: String
    public let description: String
  }
  public let id: String
  public let en: Text
  public let cs: Text

  public func text(_ language: String) -> Text { language == "cs" ? cs : en }
}

// The bounded classification input, matching the benchmark's run.py `with_body`: header fields
// and a 200-character snippet, then the rest of the body for the token budget to truncate.
public enum Input {
  public static func text(_ message: Message) -> String {
    let body = Array(normalize(message.body).unicodeScalars)
    let snippet = body.prefix(200)
    let minimized = [
      "From: \(message.from)",
      "Reply-To: \(message.reply_to)",
      "Mailing list: \(message.list ? "yes" : "no")",
      "Recipients: \(message.recipients)",
      "Subject: \(normalize(message.subject))",
      "Snippet: \(string(snippet))",
    ].joined(separator: "\n")
    return minimized + "\nBody: " + string(body.dropFirst(200))
  }

  // The Natural Language Inference hypothesis for one Custom Category.
  public static func hypothesis(
    _ category: CustomCategory, language: String, template: [String: String]
  ) -> String {
    let text = category.text(language)
    let named = (template[language] ?? "").replacingOccurrences(of: "{name}", with: text.name)
    return "\(named) \(text.description)"
  }

  // Python's `re.sub(r"\s+", " ", text).strip()`: Python whitespace also covers U+001C–U+001F.
  static func normalize(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    var space = false
    for scalar in text.unicodeScalars {
      if isSpace(scalar) {
        space = true
      } else {
        if space, !scalars.isEmpty { scalars.append(" ") }
        space = false
        scalars.append(scalar)
      }
    }
    return String(scalars)
  }

  static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
  }

  // Python slices strings by code point, so slicing works on Unicode scalars, not Characters.
  private static func string<S: Sequence<Unicode.Scalar>>(_ scalars: S) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
  }
}

// Token ids for one model pass, truncated like the benchmark: right truncation for a single
// message, and only the message (premise) shortened for a hypothesis pair.
public enum Encoding {
  public static func single(_ ids: [Int32], maxLength: Int) -> [Int32] {
    [Tokenizer.cls] + ids.prefix(maxLength - 2) + [Tokenizer.sep]
  }

  public static func pair(premise: [Int32], hypothesis: [Int32], maxLength: Int) throws -> [Int32]
  {
    let room = maxLength - hypothesis.count - 3
    guard room >= 1 else { throw SpikeError.unsupported("hypothesis exceeds the token budget") }
    return [Tokenizer.cls] + premise.prefix(room) + [Tokenizer.sep] + hypothesis + [Tokenizer.sep]
  }
}
