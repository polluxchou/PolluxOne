import Foundation

// Entry point for the offline engine suites — see scripts/test-engines.sh.

MainActor.assumeIsolated {
    let alignment = runAlignmentSuite()
    let voice = runVoiceSuite()

    let pass = alignment.pass + voice.pass
    let fail = alignment.fail + voice.fail
    print("\n══════ TOTAL: \(pass) passed, \(fail) failed ══════")
}
