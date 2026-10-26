import Foundation
import MancoraBridge
import MancoraCore
import MancoraPlugins
import MancoraUpdate

let updateSitesUsage = """
    usage: mancora update-sites list                     the sites, and whether each is enabled
           mancora update-sites known                    update sites Mancora knows by name
           mancora update-sites add <name> [<url>]       add and enable a site (its files install at the next update)
           mancora update-sites enable <name>            enable a site (its files install at the next update)
           mancora update-sites disable <name>           disable a site and remove its files
           mancora update-sites remove <name>            forget a site and remove its files
           mancora update-sites status [--all]           what an update would change (--all: every file)
           mancora update-sites update [--dry-run] [<file> …]
                                                         install, update and remove files as the sites say
                                                         (only the files named, and what they need, if any)
    The sites manage the Java bridge's folder (MANCORA_BRIDGE_HOME), as Fiji's updater manages Fiji.
    """

func updateSitesCommand(_ args: [String]) async {
    let home = BridgeHome.standard()
    let client = URLSessionHTTPClient(userAgent: "mancora/\(MancoraVersion.number)")
    do {
        let manager = try PluginManager(root: home.root)
        switch (args.first, args.count) {
        case ("list", 1):
            for site in manager.sites {
                print("\(site.isActive ? "enabled " : "disabled")  \(site.name)  \(site.url)")
            }
        case ("known", 1):
            for site in KnownSites.all { print("\(site.name)\t\(site.url)\t\(site.description)") }
        case ("add", 2...3):
            try manager.addSite(name: args[1], url: args.count == 3 ? args[2] : nil)
            try manager.save()
            print("Added \(args[1]); run `mancora update-sites update` to install its files.")
        case ("enable", 2):
            try manager.setActive(args[1], true)
            try manager.save()
            print("Enabled \(args[1]); run `mancora update-sites update` to install its files.")
        case ("disable", 2), ("remove", 2):
            // As in Fiji's window: what the site installed goes (or returns to
            // the version another site provides), then the change is applied.
            guard manager.files.site(named: args[1]) != nil else { throw PluginManager.SiteError.unknown(args[1]) }
            try await manager.refresh(client: client)
            report(manager.warnings)
            if args[0] == "disable" { try manager.setActive(args[1], false) } else { try manager.removeSite(args[1]) }
            let (changes, _) = manager.plan()
            try await manager.apply(client: client) { print($0) }
            print("\(args[0] == "disable" ? "Disabled" : "Removed") \(args[1]); \(changes.count) file(s) changed.")
        case ("status", 1), ("status", 2):
            let all = args.count == 2
            guard !all || args[1] == "--all" else { fail(updateSitesUsage) }
            try await manager.refresh(client: client)
            report(manager.warnings)
            _ = manager.plan()
            for file in manager.files.files.sorted(by: { $0.filename < $1.filename }) {
                guard all || file.actionSpecified || [.updateable, .modified, .obsolete, .obsoleteModified].contains(file.status)
                else { continue }
                let action = file.actionSpecified ? "  → \(file.action.rawValue)" : ""
                print("\(file.localFilename(forDisplay: true))\t(\(file.status.rawValue))\t\(file.updateSite ?? "local")\(action)")
            }
            for conflict in manager.files.conflicts { print("warning: \(conflict.message)") }
        case ("update", 1...):
            var names = Array(args.dropFirst())
            let dryRun = names.first == "--dry-run"
            if dryRun { names.removeFirst() }
            try await manager.refresh(client: client)
            report(manager.warnings)
            if !names.isEmpty { try manager.select(names) }
            let (changes, conflicts) = manager.plan()
            for change in changes { print(change) }
            report(conflicts.filter(\.isWarning).map { "\($0) (keeping the local file)" })
            let errors = conflicts.filter { !$0.isWarning }
            guard errors.isEmpty else {
                fail("mancora: cannot update:\n" + errors.map { "  \($0)" }.joined(separator: "\n"))
            }
            if changes.isEmpty {
                print("Everything is up to date.")
                return
            }
            if dryRun { return }
            try await manager.apply(client: client) { print($0) }
            print("Done: \(changes.count) file(s) changed in \(home.root.path)")
        default:
            fail(updateSitesUsage)
        }
    } catch {
        fail("mancora: \(error)")
    }
}

func report(_ warnings: [String]) {
    for warning in warnings { FileHandle.standardError.write(Data(("warning: " + warning + "\n").utf8)) }
}
