import Foundation
import FolioTranslate

/// Where an agent was found and which version answered.
struct AgentInstallation: Sendable, Hashable {
    let location: String
    let version: String?
    let isApp: Bool
}

extension AgentIntegrator {
    /// The folders searched for agents' commands: the login shell's PATH, then the usual install folders.
    var commandFolders: [String] {
        if let commandFoldersOverride { return commandFoldersOverride }
        var seen = Set<String>()
        return (ShellEnvironment.loginPATH() + ShellEnvironment.fallbackFolders(home: home)).filter { seen.insert($0).inserted }
    }

    /// The environment agents' commands run in: Folio's own, with the shell's PATH.
    var commandEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (commandFolders + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["HOME"] = home.path
        // Some CLIs print colours or update notices unless told they are not talking to a person.
        environment["NO_COLOR"] = "1"
        environment["CI"] = "1"
        return environment
    }

    /// An executable named `name` on the search path (symlinks resolved; a dangling link does not count).
    func findCommand(_ name: String) -> String? {
        for folder in commandFolders {
            let path = "\(folder)/\(name)"
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue,
                  FileManager.default.isExecutableFile(atPath: path) else { continue }
            return path
        }
        return nil
    }

    func installation(of descriptor: AgentDescriptor) -> AgentInstallation? {
        for app in descriptor.apps {
            for folder in applicationFolders {
                // Info.plist is read directly: `Bundle` caches by path, so a bundle seen half-installed
                // would stay that way until Folio quits.
                let url = folder.appending(path: app)
                guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let executable = info["CFBundleExecutable"] as? String,
                      FileManager.default.isExecutableFile(atPath: url.appending(path: "Contents/MacOS/\(executable)").path)
                else { continue }
                return AgentInstallation(location: url.path, version: info["CFBundleShortVersionString"] as? String, isApp: true)
            }
        }
        for command in descriptor.commands {
            guard let path = findCommand(command) else { continue }
            guard verifiesCommands else { return AgentInstallation(location: path, version: nil, isApp: false) }
            let environment = commandEnvironment
            for arguments in descriptor.versionArguments {
                guard let result = CommandProbe.run(path, arguments, environment: environment, timeout: 8), result.status == 0 else { continue }
                return AgentInstallation(location: path, version: CommandProbe.version(in: result.output), isApp: false)
            }
        }
        return nil
    }
}
