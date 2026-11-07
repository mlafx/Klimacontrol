import Foundation

/// Versionsnummer der App: bis zu vier Zahlen (fehlende = 0) und optional eine Beta-Kennung „b<n>“ (n ≥ 1).
/// Reihenfolge wie bei Sparkle: 1.1.0.0 < 1.2.0.0b1 < 1.2.0.0b2 < 1.2.0.0 < 1.2.0.1.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Immer vier Zahlen.
    public let numbers: [Int]
    /// nil = stabile Fassung.
    public let beta: Int?

    /// nil bei allem, was nicht `^\d+(\.\d+){0,3}(b[1-9]\d*)?$` ist (keine Leerzeichen, kein „v“, kleines „b“).
    public init?(_ text: String) {
        var core = Substring(text)
        var beta: Int?
        if let b = core.firstIndex(of: "b") {
            let digits = core[core.index(after: b)...]
            guard Self.isDigits(digits), let n = Int(digits), n >= 1 else { return nil }
            beta = n
            core = core[..<b]
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy(Self.isDigits) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            numbers.append(n)
        }
        self.init(numbers: numbers, beta: beta)
    }

    public init(numbers: [Int], beta: Int?) {
        var n = Array(numbers.prefix(4))
        while n.count < 4 { n.append(0) }
        self.numbers = n
        self.beta = beta
    }

    public var isBeta: Bool { beta != nil }

    /// Dieselbe Nummer ohne Beta-Kennung.
    public var base: AppVersion { AppVersion(numbers: numbers, beta: nil) }

    /// Vier Stellen, ggf. mit „b<n>“: "1.2.0.0", "1.2.0.0b1".
    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (beta.map { "b\($0)" } ?? "")
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for (x, y) in zip(a.numbers, b.numbers) where x != y { return x < y }
        switch (a.beta, b.beta) {
        case (nil, _): return false
        case (_?, nil): return true
        case let (x?, y?): return x < y
        }
    }

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
