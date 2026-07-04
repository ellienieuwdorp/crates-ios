import Foundation

/// The Crates API is generated from decompiled Java and is loose with types: an id may arrive as
/// a JSON number or a quoted string; "rating" may be missing entirely. These helpers decode
/// either shape without throwing, so one sloppy field never fails a whole list.
extension KeyedDecodingContainer {
    func decodeFlexibleInt64(_ key: Key) throws -> Int64? {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        return nil
    }

    func decodeFlexibleInt(_ key: Key) throws -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        return nil
    }
}
