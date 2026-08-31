import Foundation

// Entry point for the offline engine suites — see scripts/test-engines.sh.
//
// Top-level code here is async (the archiving suite awaits), which also makes
// it MainActor-isolated under -default-isolation MainActor — so the synchronous
// suites are called directly. MainActor.assumeIsolated is unavailable from an
// async context and is a hard error under the Swift 6 language mode.

let alignment = runAlignmentSuite()
let voice = runVoiceSuite()
let camera = runCameraSuite()
let archive = await runArchiveSuite()

let pass = alignment.pass + voice.pass + camera.pass + archive.pass
let fail = alignment.fail + voice.fail + camera.fail + archive.fail
print("\n══════ TOTAL: \(pass) passed, \(fail) failed ══════")
