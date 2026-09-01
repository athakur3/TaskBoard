import Testing
@testable import TaskBoard

/// The status workflow, pinned pair-by-pair. The same table is enforced
/// server-side (400 INVALID_TRANSITION): columns are adjacent-only —
/// To Do ↔ In Progress ↔ Done, never skipping.
struct TaskWorkflowTests {
    @Test func testEveryPairAgainstTheAdjacencyTable() {
        let legalSteps: Set<[TaskStatus]> = [
            [.todo, .inProgress], [.inProgress, .todo],
            [.inProgress, .done], [.done, .inProgress],
        ]
        for from in TaskStatus.allCases {
            for to in TaskStatus.allCases {
                let expected = from == to || legalSteps.contains([from, to])
                #expect(from.canMove(to: to) == expected,
                        "\(from.rawValue) -> \(to.rawValue) should be \(expected ? "legal" : "rejected")")
            }
        }
    }

    @Test func testEveryStepIsReversible() {
        // No one-way doors: any column you can step into can step you back,
        // so a misfiled task is never stranded.
        for from in TaskStatus.allCases {
            for to in from.adjacentColumns {
                #expect(to.adjacentColumns.contains(from))
            }
        }
    }
}
