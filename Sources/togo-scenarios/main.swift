import Foundation
import TogoCore
import TogoScenarios

// Replay the shared scenarios through the Swift core (`scenarios/README.md`).
//
//   swift run togo-scenarios                   check every scenario against expected/,
//                                              and every native one against expected-native/
//   swift run togo-scenarios <name>…           check these
//   swift run togo-scenarios --print <name>    print the recorded batches, projected
//   swift run togo-scenarios --record-native   (re)write expected-native/ — and read the diff
//   swift run togo-scenarios --send <native>   perform one native scenario now and upload it
//                                              to TOGO_ENDPOINT under TOGO_WRITE_KEY; prints
//                                              the batches and the edge's answers as JSON, and
//                                              exits 1 unless every upload was a 202 with
//                                              nothing rejected (the stage journey's sender)
//
// It never writes expected/: the browser SDK records those goldens, and this
// runner holds a second SDK to them (Projection, in TogoScenarios). It is the
// runner that records expected-native/, the native profile's goldens, which no
// browser can perform; a second native SDK replays them.

let arguments = Array(CommandLine.arguments.dropFirst())
let printOnly = arguments.first == "--print"
let recordNative = arguments.first == "--record-native"
let send = arguments.first == "--send"
let names = arguments.filter { !$0.hasPrefix("--") }
let root = ScenarioFormat.defaultRoot

func golden(_ directory: String, _ name: String) throws -> JSONValue {
  try JSONValue.parse(try Data(contentsOf: root.appendingPathComponent("\(directory)/\(name).json")))
}

func goldenFile(_ name: String, _ uploads: [ScenarioDriver.Upload]) -> JSONValue {
  .object([
    "scenario": .string(name),
    "now": .string(ISOTime.format(ScenarioDriver.goldenNowMs)),
    "seed": .int(Int64(ScenarioDriver.goldenSeed)),
    "batches": .array(uploads.map { .object(["client": .string($0.client), "body": $0.body]) }),
  ])
}

do {
  let nativeNames = try ScenarioFormat.nativeScenarioNames()
  if send {
    let environment = ProcessInfo.processInfo.environment
    guard names.count == 1, nativeNames.contains(names[0]),
      let endpoint = environment["TOGO_ENDPOINT"].flatMap(URL.init(string:)),
      let writeKey = environment["TOGO_WRITE_KEY"], !writeKey.isEmpty
    else {
      FileHandle.standardError.write(
        Data(
          "togo-scenarios: --send takes one native scenario (\(nativeNames.joined(separator: ", "))) and needs TOGO_ENDPOINT and TOGO_WRITE_KEY\n"
            .utf8))
      exit(2)
    }
    let nowMs = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    let runId = environment["TOGO_RUN_ID"] ?? "send"
    let uploads = try ScenarioDriver.sendNative(
      names[0], endpoint: endpoint, writeKey: writeKey, nowMs: nowMs, runId: runId)
    var problems: [String] = []
    for upload in uploads {
      let rejected = upload.response?["rejected"]?.arrayValue?.count ?? 0
      if upload.status != 202 || rejected > 0 {
        problems.append("status \(upload.status.map(String.init) ?? "none"), \(rejected) rejected")
      }
    }
    if uploads.isEmpty { problems.append("nothing was uploaded") }
    let report = JSONValue.array(
      uploads.map {
        .object([
          "client": .string($0.client), "status": $0.status.map { .int(Int64($0)) } ?? .null,
          "body": $0.body, "response": $0.response ?? .null,
        ])
      })
    print(report.pretty())
    for problem in problems { FileHandle.standardError.write(Data("togo-scenarios: \(problem)\n".utf8)) }
    exit(problems.isEmpty ? 0 : 1)
  }
  if recordNative {
    let directory = root.appendingPathComponent("expected-native", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in names.isEmpty ? nativeNames : names {
      let file = goldenFile(name, try ScenarioDriver.recordNative(name))
      try Data((file.pretty() + "\n").utf8).write(to: directory.appendingPathComponent("\(name).json"))
      print("recorded expected-native/\(name).json")
    }
    exit(0)
  }
  let selected = names.isEmpty ? try ScenarioFormat.scenarioNames() + nativeNames : names
  var failed = 0
  for name in selected {
    let native = nativeNames.contains(name)
    let recorded =
      native
      ? try ScenarioDriver.recordNative(name) : Projection.recorded(try ScenarioDriver.record(name))
    if printOnly {
      let batches = recorded.map { JSONValue.object(["client": .string($0.client), "body": $0.body]) }
      print(JSONValue.array(batches).pretty())
      continue
    }
    let expected =
      native
      ? Projection.native(try golden("expected-native", name))
      : Projection.expected(try golden("expected", name))
    if let difference = Projection.difference(expected, recorded) {
      failed += 1
      print("✗ \(name): \(difference)")
    } else {
      print("✓ \(name)")
    }
  }
  exit(failed == 0 ? 0 : 1)
} catch {
  FileHandle.standardError.write(Data("togo-scenarios: \(error)\n".utf8))
  exit(2)
}
