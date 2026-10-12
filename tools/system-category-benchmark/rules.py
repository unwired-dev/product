"""Python port of the Swift prototype's RuleBasedClassificationEngine.

Source: apps/unwired-mail/unwired-mail/Services/Gmail/MessageCategorizationService.swift
(systemCategories, RuleBasedClassificationEngine, ClassificationTokenizer). The prototype's
legacy Promotions and Invoices keyword sets stand for Newsletters & Promotions and Orders.
Future Learning Signals are omitted: the corpus has no User Overrides.
"""

import email.utils
import re

KEYWORDS = {
    "Newsletters & Promotions": {"coupon", "discount", "offer", "promotion", "sale"},
    "Invites": {"invitation", "invite", "rsvp"},
    "Orders": {"invoice", "order", "payment", "receipt"},
    "Flights": {"airline", "boarding", "flight", "itinerary"},
}
AUTOMATED_MARKERS = {
    "automated",
    "campaign",
    "digest",
    "marketing",
    "newsletter",
    "no-reply",
    "noreply",
    "notification",
    "notifications",
    "promo",
    "support",
    "updates",
}


def tokens(text: str) -> set[str]:
    # Swift splits on every character that is neither a letter nor a number.
    return set(re.findall(r"[^\W_]+", text.lower()))


def matches(input_tokens: set[str]) -> list[str]:
    return sorted(category for category, words in KEYWORDS.items() if input_tokens & words)


def is_direct_correspondence(sender: str, subject: str, snippet: str) -> bool:
    addresses = {
        address.lower() for _, address in email.utils.getaddresses([sender]) if "@" in address
    }
    if len(addresses) != 1:
        return False
    local_part = next(iter(addresses)).split("@", 1)[0]
    # As in Swift, "no-reply" can never match because tokens split on "-".
    return not tokens(f"{subject} {snippet} {local_part}") & AUTOMATED_MARKERS


def classify(sender: str, reply_to: str, subject: str, snippet: str, body: str | None) -> list[str]:
    """Return the assigned categories; body None means Minimized Classification Input only."""
    assigned = matches(tokens(f"{sender} {reply_to} {snippet} {subject}"))
    if assigned or body is None:
        return assigned  # with body None an empty result is the engine's needsBody
    assigned = matches(tokens(body))
    if not assigned and is_direct_correspondence(sender, subject, snippet):
        assigned = ["People"]
    return assigned
