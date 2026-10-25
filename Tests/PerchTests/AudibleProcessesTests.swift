import CoreAudio
import Testing

@testable import Perch

// Core Audio のプロセスオブジェクトから読んだものの解釈。読み取りそのもの（実機の
// Core Audio）はテストせず、読んだ結果への問いだけを純粋な関数として確かめる。

private typealias Snapshot = AudibleProcesses.Snapshot

/// Perch 自身のプロセスオブジェクト（pid を translate して得るもの）。
private let ownObject: AudioObjectID = 100

@Test(
  "自分以外に音を出しているプロセスがあるか（Perch 自身の出力は空間化した音なので数えない）",
  arguments: [
    ([], false),
    ([Snapshot(objectID: ownObject, bundleID: "dev.perch.mac", isRunningOutput: true)], false),
    (
      [
        Snapshot(objectID: ownObject, bundleID: "dev.perch.mac", isRunningOutput: true),
        Snapshot(objectID: 200, bundleID: "com.example.player", isRunningOutput: false),
      ],
      false
    ),
    (
      [
        Snapshot(objectID: ownObject, bundleID: "dev.perch.mac", isRunningOutput: true),
        Snapshot(objectID: 200, bundleID: "com.example.player", isRunningOutput: true),
      ],
      true
    ),
    // 自分かどうかはオブジェクト ID で決まる。bundle ID（や pid）を読めない他プロセスも
    // 数える。
    ([Snapshot(objectID: 200, bundleID: nil, isRunningOutput: true)], true),
    // 同じ bundle ID でも、別のオブジェクトなら別のプロセス。
    ([Snapshot(objectID: 300, bundleID: "dev.perch.mac", isRunningOutput: true)], true),
    // 出力しているかを読めなかった他プロセスがあれば、「出力していない」とは言えない:
    // 分からない（nil）。
    ([Snapshot(objectID: 200, bundleID: nil, isRunningOutput: nil)], nil),
    (
      [
        Snapshot(objectID: 200, bundleID: nil, isRunningOutput: nil),
        Snapshot(objectID: 300, bundleID: "com.example.idle", isRunningOutput: false),
      ],
      nil
    ),
    // ただし、出力していると分かっている他プロセスが1つでもあれば、答えは確かに「いる」。
    (
      [
        Snapshot(objectID: 200, bundleID: nil, isRunningOutput: nil),
        Snapshot(objectID: 300, bundleID: "com.example.player", isRunningOutput: true),
      ],
      true
    ),
    // 自分のぶんは読めなくても関係ない。
    ([Snapshot(objectID: ownObject, bundleID: nil, isRunningOutput: nil)], false),
  ] as [([Snapshot], Bool?)]
)
private func anotherProcessIsOutputting(row: ([Snapshot], Bool?)) {
  let (snapshots, expected) = row
  #expect(AudibleProcesses.anyOutputting(snapshots, excluding: ownObject) == expected)
}

@Test("音を出しているプロセスの bundle ID だけを集める。空や読めないもの、出力を読めないものは除く")
func bundleIDsOfOutputtingProcesses() {
  let snapshots = [
    Snapshot(objectID: 1, bundleID: "com.example.browser", isRunningOutput: true),
    Snapshot(objectID: 2, bundleID: "com.example.idle", isRunningOutput: false),
    Snapshot(objectID: 3, bundleID: "", isRunningOutput: true),
    Snapshot(objectID: 4, bundleID: nil, isRunningOutput: true),
    Snapshot(objectID: 5, bundleID: "com.example.unreadable", isRunningOutput: nil),
  ]
  #expect(AudibleProcesses.bundleIDs(outputtingIn: snapshots) == ["com.example.browser"])
}
