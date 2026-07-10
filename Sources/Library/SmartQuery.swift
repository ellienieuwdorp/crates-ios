import Foundation

/// Client-side evaluator for smart-crate (SEARCH_CRATE) queries, e.g.
/// `in:"DJ Library" genre:house`, `in:"…" (genre:funk OR genre:soul)`,
/// `in:"…" genre:dub !genre:house`, `genre:dnb OR genre:drum*bass`.
///
/// The backup export ships smart crates with ZERO tune memberships (their contents are computed
/// by the desktop frontend on view), so the phone materializes them locally instead: parse the
/// crate's stored query, evaluate it over the synced genre join. Matching mirrors the server's
/// verified semantics (2026-07-10 probes): case-insensitive SUBSTRING over genre names
/// (`house` matches "Acid House"), with separators folded so `hip hop` matches "Hip-Hop".
///
/// Deliberately tiny: `genre:` terms, quoted values, `OR` groups in parens, `!` negation and
/// `*` wildcards — the grammar of every real query seen. `in:"…"` scopes are ignored (the
/// phone's corpus is the collection; the desktop's own `in:` scoping provably returns zero).
/// Anything else fails the parse and the crate renders an honest "computed on desktop" state.
struct SmartQuery: Sendable, Equatable {
    indirect enum Term: Sendable, Equatable {
        case genre(String)        // normalized, may contain "*"
        case not(Term)
        case anyOf([Term])        // OR group
    }

    /// All terms must match (AND).
    let terms: [Term]

    // MARK: - Parse

    /// nil when the query uses anything beyond the supported grammar — callers must fall back
    /// to an honest empty state, never a silently-wrong list.
    static func parse(_ raw: String) -> SmartQuery? {
        var tokens = tokenize(raw)
        var terms: [Term] = []
        while !tokens.isEmpty {
            guard let term = parseTerm(&tokens) else { return nil }
            // Top-level `a OR b` (no parens) — seen in the wild: `genre:dnb OR genre:drum*bass`.
            if tokens.first == "OR" {
                var options = [term]
                while tokens.first == "OR" {
                    tokens.removeFirst()
                    guard let next = parseTerm(&tokens) else { return nil }
                    options.append(next)
                }
                terms.append(.anyOf(options))
            } else {
                terms.append(term)
            }
        }
        return terms.isEmpty ? nil : SmartQuery(terms: terms)
    }

    private static func parseTerm(_ tokens: inout [String]) -> Term? {
        guard !tokens.isEmpty else { return nil }
        let tok = tokens.removeFirst()
        switch tok {
        case "(":
            var options: [Term] = []
            while let inner = parseTerm(&tokens) {
                options.append(inner)
                if tokens.first == "OR" { tokens.removeFirst(); continue }
                break
            }
            guard tokens.first == ")" else { return nil }
            tokens.removeFirst()
            return options.count == 1 ? options[0] : .anyOf(options)
        case ")", "OR":
            return nil
        default:
            if tok.hasPrefix("!") {
                var rest = tokens
                rest.insert(String(tok.dropFirst()), at: 0)
                guard let inner = parseTerm(&rest) else { return nil }
                tokens = rest
                return .not(inner)
            }
            guard let colon = tok.firstIndex(of: ":") else { return nil }
            let field = tok[..<colon].lowercased()
            let value = String(tok[tok.index(after: colon)...])
            switch field {
            case "in":  // scope — ignored (see doc comment), but must parse cleanly
                return tokens.isEmpty ? .anyOf([]) : parseTerm(&tokens)
            case "genre":
                let norm = normalize(value, keepWildcards: true)
                return norm.isEmpty ? nil : .genre(norm)
            default:
                return nil // bpm:/rating:/artist: … — unsupported, honest fallback
            }
        }
    }

    /// Split into tokens: quoted spans stay attached to their prefix (`genre:"hip hop"` is one
    /// token), parens are their own tokens, `OR` is a keyword.
    private static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            switch ch {
            case "\"":
                inQuotes.toggle()
            case " " where !inQuotes:
                if !current.isEmpty { tokens.append(current); current = "" }
            case "(" where !inQuotes, ")" where !inQuotes:
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
            default:
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Evaluate

    func matches(_ tune: Tune) -> Bool {
        // Haystack: the genre join plus the legacy single-genre string (the server's own search
        // matches both — its counts exceed the join alone).
        var names = tune.genres
        if let g = tune.genre, !g.isEmpty { names.append(g) }
        guard !names.isEmpty else { return false }
        let haystacks = names.map { Self.normalize($0, keepWildcards: false) }
        return terms.allSatisfy { Self.eval($0, haystacks: haystacks) }
    }

    private static func eval(_ term: Term, haystacks: [String]) -> Bool {
        switch term {
        case .genre(let needle):
            if needle.contains("*") {
                let parts = needle.split(separator: "*").map(String.init)
                return haystacks.contains { hay in
                    var idx = hay.startIndex
                    for p in parts {
                        guard let r = hay.range(of: p, range: idx..<hay.endIndex) else { return false }
                        idx = r.upperBound
                    }
                    return true
                }
            }
            return haystacks.contains { $0.contains(needle) }
        case .not(let inner):
            return !eval(inner, haystacks: haystacks)
        case .anyOf(let options):
            return options.isEmpty || options.contains { eval($0, haystacks: haystacks) }
        }
    }

    /// Lowercase, diacritic-fold, and treat -, _, /, & as spaces so "Hip-Hop" ≍ "hip hop".
    static func normalize(_ s: String, keepWildcards: Bool) -> String {
        var out = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        for sep in ["-", "_", "/", "&"] { out = out.replacingOccurrences(of: sep, with: " ") }
        if !keepWildcards { out = out.replacingOccurrences(of: "*", with: " ") }
        return out.split(separator: " ").joined(separator: " ")
    }
}
