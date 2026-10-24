import Testing

@testable import Perch

// Core Audio のプロセスオブジェクトから読んだものの解釈。読み取りそのもの（実機の
// Core Audio）はテストせず、読んだ結果への問いだけを純粋な関数として確かめる。

private typealias Snapshot = AudibleProcesses.Snapshot

private let ownPID: Int32 = 100

@Test(
  "自分以外に音を出しているプロセスがあるか（Perch 自身の出力は空間化した音なので数えない）",
  arguments: [
    ([], false),
    ([Snapshot(pid: ownPID, bundleID: "dev.perch.mac", isRunningOutput: true)], false),
    (
      [
        Snapshot(pid: ownPID, bundleID: "dev.perch.mac", isRunningOutput: true),
        Snapshot(pid: 200, bundleID: "com.example.player", isRunningOutput: false),
      ],
      false
    ),
    (
      [
        Snapshot(pid: ownPID, bundleID: "dev.perch.mac", isRunningOutput: true),
        Snapshot(pid: 200, bundleID: "com.example.player", isRunningOutput: true),
      ],
      true
    ),
    ([Snapshot(pid: 200, bundleID: nil, isRunningOutput: true)], true),
    // pid を読めないものは、自分かどうか分からないので数えない（自分を数えると、
    // 空間化している間ずっと「他が再生中」に見えてしまう）。
    ([Snapshot(pid: nil, bundleID: "com.example.player", isRunningOutput: true)], false),
  ] as [([Snapshot], Bool)]
)
private func anotherProcessIsOutputting(row: ([Snapshot], Bool)) {
  let (snapshots, expected) = row
  #expect(AudibleProcesses.anyOutputting(snapshots, excluding: ownPID) == expected)
}

@Test("音を出しているプロセスの bundle ID だけを集める。空や読めないものは除く")
func bundleIDsOfOutputtingProcesses() {
  let snapshots = [
    Snapshot(pid: 1, bundleID: "com.example.browser", isRunningOutput: true),
    Snapshot(pid: 2, bundleID: "com.example.idle", isRunningOutput: false),
    Snapshot(pid: 3, bundleID: "", isRunningOutput: true),
    Snapshot(pid: 4, bundleID: nil, isRunningOutput: true),
  ]
  #expect(AudibleProcesses.bundleIDs(outputtingIn: snapshots) == ["com.example.browser"])
}
