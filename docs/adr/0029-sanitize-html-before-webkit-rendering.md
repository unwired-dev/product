---
status: accepted
---

# Sanitize message HTML before isolated WebKit rendering

Retained message HTML is untrusted input. The Apple client will sanitize it on device with [SwiftSoup](https://github.com/scinfu/SwiftSoup) before passing it to WebKit. The Xcode package lock pins the reviewed 2.13.7 release. The sanitizer owns explicit allowlists for common text and table-based email elements, their attributes, the `http`, `https`, `mailto`, and `tel` link schemes, and a conservative set of inline CSS properties. It removes active elements, event handlers, forms, frames, embedded objects, metadata refreshes, unsafe URL schemes, CSS URL values, and remote image sources. Sanitization never mutates the retained encrypted source body.

Sanitized HTML renders in a shared `WKWebView` boundary used by every adaptive conversation-reader presentation. Page JavaScript is disabled, website data storage is non-persistent, and the generated document supplies a content security policy whose default, image, media, font, connection, frame, and object sources are `none`. Inline CSS remains enabled only because the sanitizer filters both property names and values before WebKit receives them. Remote message content and embedded images remain unavailable until their separate explicit-loading boundaries are implemented.

The navigation delegate cancels all message-originated navigation. A user-activated link with an allowed scheme is handed to the platform URL opener; automatic navigation and unsupported schemes remain blocked. The web view observes its scroll content size instead of executing JavaScript to measure layout. A missing HTML alternative, empty sanitized result, sanitizer error, WebKit load failure, or terminated WebKit content process falls back to the retained readable plain text.

This boundary uses UIKit-backed `WKWebView` integration available on the supported iOS 17 and Mac Catalyst 14 targets and does not depend on the OS 26 SwiftUI WebView API.
