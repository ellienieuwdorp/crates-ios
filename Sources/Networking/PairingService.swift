import Foundation
import UIKit

/// Device pairing handshake. Verified live against a running Crates 1.15.3 server (2026-07-04):
///
///   POST /pairing/request
///     header: Authorization: Bearer <BOOTSTRAP_TOKEN>   ← required; a fresh device has no token
///                                                          yet, so it presents the shared bootstrap
///                                                          credential the server's AuthService
///                                                          accepts via isValidAuthHeaderWithTempToken
///     body:   {UID, deviceName, platform, model, arch, clientType}   (UID = stable 64-hex device id)
///     → server pops an approve/deny prompt on the DESKTOP and long-polls up to 60s
///     → 200 with the device access token once the user approves
///     → 406 declined · 408 not approved in time · 417 UID already paired
///
///   Thereafter every request uses  Authorization: Bearer <access-token>.
///
/// Confirmed on the wire: the raw token without the `Bearer ` scheme, a random UID, and no header
/// are all rejected ("Authorization header … is invalid"); only `Bearer <bootstrap>` enters the
/// flow ("Received request for ios device → User is Supporter → waiting (N/60)"). Pairing also
/// requires the desktop account to be logged in and Supporter/Beta.
struct PairingRequest: Codable, Sendable {
    let UID: String
    let deviceName: String
    let platform: String
    let model: String
    let arch: String
    let clientType: String

    static func makeForThisDevice(uid: String) -> PairingRequest {
        PairingRequest(
            UID: uid,
            deviceName: UIDevice.current.name,
            platform: "iOS \(UIDevice.current.systemVersion)",
            model: UIDevice.current.model,
            arch: "arm64",
            clientType: "mobile-iOS"
        )
    }
}

struct PairingResult: Sendable {
    let token: String
}

actor PairingService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    /// Shared bootstrap credential a fresh, un-paired device presents on `/pairing/request` so the
    /// server will accept the request and start the approval flow. Extracted from the desktop
    /// server binary's `AuthService` (`isValidAuthHeaderWithTempToken`) and confirmed live — the
    /// official mobile app ships the same constant. NOT a device token; it only unlocks pairing.
    static let bootstrapToken = "CratesTempToken*LnQbf2X_yxE.VCUxqo3urY!4TE!@xi@qjVasYJ"

    private static let uidKey = "crates.device.uid"

    /// A stable per-install UID. Real build stores this in the Keychain; POC uses UserDefaults.
    static func persistentDeviceUID() -> String {
        if let existing = UserDefaults.standard.string(forKey: uidKey) { return existing }
        return rotateDeviceUID()
    }

    /// Mint a fresh UID. Used when the server reports the current UID as already paired but we
    /// hold no token for it (e.g. after sign-out) — re-pairing under a new identity self-heals.
    /// Format matches the real client: a 64-char uppercase hex string (32 random bytes).
    @discardableResult
    static func rotateDeviceUID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let uid = bytes.map { String(format: "%02X", $0) }.joined()
        UserDefaults.standard.set(uid, forKey: uidKey)
        return uid
    }

    /// Fire the pairing request. `host`/`port` come from discovery or manual entry. The call may
    /// block for up to the server's approval window; surface a "check your computer" UI meanwhile.
    /// A 417 ("UID already paired" — but we have no token) rotates the UID and retries once.
    func requestPairing(host: String, port: Int = CratesConnection.defaultPort) async throws -> CratesConnection {
        do {
            return try await requestPairingOnce(host: host, port: port, uid: Self.persistentDeviceUID())
        } catch CratesAPIError.http(417) {
            return try await requestPairingOnce(host: host, port: port, uid: Self.rotateDeviceUID())
        }
    }

    private func requestPairingOnce(host: String, port: Int, uid: String) async throws -> CratesConnection {
        let request = PairingRequest.makeForThisDevice(uid: uid)
        var comps = URLComponents()
        comps.scheme = "http"; comps.host = host; comps.port = port
        comps.path = "/\(CratesConnection.apiRoot)/pairing/request"
        guard let url = comps.url else { throw CratesAPIError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Fresh device → present the shared bootstrap token (confirmed live: this is the only header
        // that passes the server's pairing auth check for an un-paired device).
        req.setValue("Bearer \(Self.bootstrapToken)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 75 // server long-polls ~60s waiting for desktop approval
        req.httpBody = try JSONEncoder().encode(request)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch let e as URLError where e.code == .timedOut { throw CratesAPIError.pairingTimeout }
        catch { throw CratesAPIError.transport(error) }
        guard let http = response as? HTTPURLResponse else { throw CratesAPIError.badURL }
        switch http.statusCode {
        case 200:
            let token = try Self.extractToken(from: data)
            return CratesConnection(host: host, port: port, token: token)
        case 401, 403: throw CratesAPIError.unauthorized
        case 406: throw CratesAPIError.pairingNotApproved
        case 408: throw CratesAPIError.pairingTimeout
        default: throw CratesAPIError.http(http.statusCode)
        }
    }

    /// The token may come back as a bare string, a quoted string, or wrapped in JSON. Be liberal.
    static func extractToken(from data: Data) throws -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            if let s = obj as? String { return s }
            if let dict = obj as? [String: Any] {
                for k in ["token", "accessToken", "access_token", "UID", "value"] {
                    if let v = dict[k] as? String, !v.isEmpty { return v }
                }
            }
        }
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r\t"))
        guard !raw.isEmpty else { throw CratesAPIError.decoding(NSError(domain: "pairing", code: 0)) }
        return raw
    }
}
