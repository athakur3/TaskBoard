import Foundation
import Testing
@testable import TaskBoard

/// Port-parity tests with server/test/orderkey.test.js — the two
/// implementations must agree on the key space.
struct OrderKeyTests {
    @Test func testFirstKeyIsV() {
        #expect(OrderKey.after(nil) == "V")
        #expect(OrderKey.after("") == "V")
    }

    @Test func testAfterChainIsStrictlyIncreasing() {
        var key = OrderKey.after(nil)
        for _ in 0..<100 {
            let next = OrderKey.after(key)
            #expect(next > key)
            #expect(OrderKey.isValid(next))
            key = next
        }
    }

    @Test func testMidpointStrictlyBetweenAndNeverTrailingZero() {
        let pairs: [(String, String)] = [("A", "B"), ("A", "C"), ("K", "KV"), ("V", "z"), ("8", "G"), ("a", "aV"), ("0z", "1")]
        for (a, b) in pairs {
            let m = OrderKey.midpoint(a, b)
            #expect(a < m, "\(a) < \(m)")
            #expect(m < b, "\(m) < \(b)")
            #expect(m.last != "0")
        }
    }

    @Test func testRepeatedBoundaryInsertsStayOrdered() {
        var lower = "A"
        let upper = "B"
        for _ in 0..<50 {
            let m = OrderKey.midpoint(lower, upper)
            #expect(lower < m && m < upper)
            #expect(OrderKey.isValid(m))
            lower = m
        }
        #expect(lower.count <= 60)
    }

    @Test func testValidation() {
        #expect(OrderKey.isValid("V"))
        #expect(OrderKey.isValid("A0B"))
        #expect(!(OrderKey.isValid("V0")))
        #expect(!(OrderKey.isValid("")))
        #expect(!(OrderKey.isValid("a_b")))
        #expect(!(OrderKey.isValid(String(repeating: "x", count: 129))))
    }
}

extension OrderKeyTests {
    @Test func testDegenerateNeighborsNeverTrap() {
        // Equal neighbor keys are a spec-tolerated replicated state (§10);
        // a drag between them must produce a legal key, not a crash.
        let equal = OrderKey.between("hV", "hV")
        #expect(OrderKey.isValid(equal))
        #expect(equal > "hV")

        let inverted = OrderKey.between("b", "a")
        #expect(OrderKey.isValid(inverted))
        #expect(inverted > "b")

        // Trailing-zero inputs (illegal on the wire, defensively sanitized).
        let sanitized = OrderKey.midpoint("A0", "B")
        #expect(OrderKey.isValid(sanitized))
        #expect(sanitized < "B")
    }
}
