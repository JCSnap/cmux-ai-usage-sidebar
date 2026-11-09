import Foundation
import ProxySteer
import UsageModels

let usage = """
usage: aiusage proxy-steer [--dry-run] [--pool ID] [--basis edf|weekly|tightest]

Sets each CLIProxyAPI pool login's routing weight from the aiusaged snapshot.
Logins that reset soon with headroom left get more new sessions. The proxy
must use `strategy: weighted-round-robin` for weights to matter.
  --dry-run   print the planned weights and change nothing
  --pool ID   pool account id in ~/.config/ai-usage/config.json (default cc3)
  --basis B   edf: earliest deadline first; the login whose weekly window
              resets soonest gets most new sessions (default)
              weekly: weekly headroom per hour to the weekly reset drives the
              weight; the 5-hour window only gates it
              tightest: the fullest window and the soonest reset drive it

The daemon port, proxy URL and management key file come from that config.

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("aiusage: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
}

func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

func get(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // The proxy's error bodies are short JSON messages without secrets.
    guard (200..<300).contains(status) else {
        throw NSError(domain: "aiusage", code: status, userInfo: [
            NSLocalizedDescriptionKey: "HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))",
        ])
    }
    return data
}

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "proxy-steer" else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty || arguments.first == "--help" ? 0 : 2)
}
arguments.removeFirst()

var dryRun = false
var poolID = "cc3"
var basis = SteerWeight.Basis.edf
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--dry-run": dryRun = true
    case "--pool":
        guard let next = arguments.first else { fail("--pool needs a value") }
        arguments.removeFirst()
        poolID = next
    case "--basis":
        guard let next = arguments.first, let value = SteerWeight.Basis(rawValue: next) else {
            fail("--basis needs edf, weekly or tightest")
        }
        arguments.removeFirst()
        basis = value
    case "--help", "-h": print(usage); exit(0)
    default: fail("unknown option \(argument)\n\(usage)")
    }
}

// MARK: - Config

// Read as plain JSON, so this binary never links the credential code.
let configPath = expand("~/.config/ai-usage/config.json")
guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
      let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
else { fail("cannot read \(configPath)") }
let port = config["port"] as? Int ?? 47823
guard let pool = (config["accounts"] as? [[String: Any]])?.first(where: { $0["id"] as? String == poolID }),
      let proxyURL = pool["cliProxyURL"] as? String
else { fail("\(configPath) has no CLIProxyAPI pool \(poolID)") }
let keyPath = expand(pool["cliProxyKeyFile"] as? String ?? "~/.cli-proxy-api/management-key")
guard let key = try? String(contentsOfFile: keyPath, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
else { fail("cannot read the management key file \(keyPath)") }

// MARK: - Run

let rows: [ProxySteer.Row]
do {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
    request.timeoutInterval = 10
    let snapshot = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: try await get(request))
    let entries = ProxySteer.authEntries(fromListing: try await get(ProxySteer.listRequest(base: proxyURL, key: key)))
    rows = try ProxySteer.plan(snapshot: snapshot, poolID: poolID, entries: entries, now: Date(), basis: basis)
} catch {
    fail("\(error is ProxySteer.PlanError ? "\(error)" : error.localizedDescription); no change")
}

if dryRun {
    print(ProxySteer.table(rows))
    exit(0)
}

var failed = false
for row in rows {
    guard row.needsUpdate, let name = row.name, let weight = row.newWeight else {
        log("\(row.email) keep \(row.currentWeight.map(String.init) ?? "-"): \(row.reason)")
        continue
    }
    do {
        _ = try await get(ProxySteer.weightRequest(base: proxyURL, key: key, name: name, weight: weight))
        log("\(row.email) weight \(weight): \(row.reason)")
    } catch {
        failed = true
        log("\(row.email) not set: \(error.localizedDescription)")
    }
}
exit(failed ? 1 : 0)
