import Foundation

// Shared scaffolding for the plain (no-XCTest) test harnesses: identical
// check/skip counters and the final summary + exit convention. Compiled into
// both UnitTests and IntegrationTests (same module as Sources).

var passCount = 0
var failCount = 0
var skipCount = 0

func check(_ name: String, _ condition: Bool) {
    if condition {
        passCount += 1
        print("PASS \(name)")
    } else {
        failCount += 1
        print("FAIL \(name)")
    }
}

/// Count and print an explicit SKIP — never recorded as a PASS.
func skip(_ name: String) {
    skipCount += 1
    print("SKIP \(name)")
}

func printTestSummary(label: String) -> Never {
    print("\(label): \(passCount) passed, \(failCount) failed, \(skipCount) skipped")
    exit(failCount == 0 ? 0 : 1)
}
