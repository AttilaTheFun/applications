"""How this repository's Swift is compiled."""

# The Swift 6 language mode, where the compiler checks data-race safety, and
# warnings as errors. Every Swift target here passes these as its `copts`.
STRICT_SWIFT = [
    "-swift-version",
    "6",
    "-warnings-as-errors",
]
