import AppKit
import WebKit

// Evaluates the JavaScript function body on stdin in a blank WKWebView, the engine that renders
// sanitized mail, and prints the string it returns.
let script = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
let view = WKWebView(frame: .zero)

final class Evaluator: NSObject, WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
    webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
      switch result {
      case .success(let value):
        print(value as? String ?? "")
        exit(0)
      case .failure(let error):
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
      }
    }
  }
}

let evaluator = Evaluator()
view.navigationDelegate = evaluator
view.loadHTMLString("<!doctype html><title>oracle</title>", baseURL: nil)
NSApplication.shared.run()
