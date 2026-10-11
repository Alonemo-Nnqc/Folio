import Foundation
@testable import FolioTranslate

/// A temporary directory removed when the value is deinitialised.
final class TemporaryDirectory: Sendable {
    let url: URL

    init(_ name: String = "FolioTranslateTests") {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? TranslatorInstallation.forceRemove(url) }

    /// Writes an executable shell script and returns its URL.
    func script(_ name: String, _ body: String) throws -> URL {
        let file = url.appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}

/// Shell snippet: starts a background worker that ignores SIGTERM (like a stuck
/// multiprocessing worker) and waits until it has written its pid to `pidFile`
/// (after installing the handler, so no signal can race it).
func termIgnoringWorker(pidFile: URL) -> String {
    #"/usr/bin/perl -e '$SIG{TERM}="IGNORE"; open(my $f, ">", $ARGV[0]); print $f $$; close $f; sleep 60' '"#
        + pidFile.path + "' & while [ ! -s '" + pidFile.path + "' ]; do sleep 0.05; done"
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

func collect(_ stream: AsyncStream<TranslationEvent>) async -> [TranslationEvent] {
    var events: [TranslationEvent] = []
    for await event in stream { events.append(event) }
    return events
}
