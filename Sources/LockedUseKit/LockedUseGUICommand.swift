import Foundation

public struct LockedUseGUICommand: Equatable, Sendable {
    public enum Action: String, Sendable { case click, type, key, capture }
    public let action: Action
    public let app: String?
    public let pid: Int32?
    public let windowID: UInt32?
    public let x: Double?
    public let y: Double?
    public let pixel: Bool
    public let screen: Bool
    public let doubleClick: Bool
    public let text: String?
    public let key: String?
    public let output: String?
    public let requireLocked: Bool

    public static func parse(_ arguments: [String]) throws -> Self {
        guard let first = arguments.first, let action = Action(rawValue: first) else { throw LockedUseError.usage("Unknown GUI command") }
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        let valueOptions: Set<String> = ["--app", "--pid", "--window-id", "--x", "--y", "--text", "--key", "--out"]
        let flagOptions: Set<String> = ["--pixel", "--screen", "--window-local", "--double", "--require-locked"]
        while index < arguments.count {
            let option = arguments[index]
            if flagOptions.contains(option), !flags.contains(option) { flags.insert(option); index += 1 }
            else if valueOptions.contains(option), values[option] == nil, index + 1 < arguments.count {
                values[option] = arguments[index + 1]; index += 2
            } else { throw LockedUseError.usage("Unknown, duplicate, or incomplete option: \(option)") }
        }
        var allowed: Set<String> = ["--app", "--pid", "--window-id"]
        switch action {
        case .click: allowed.formUnion(["--x", "--y"])
        case .type: allowed.insert("--text")
        case .key: allowed.insert("--key")
        case .capture: allowed.insert("--out")
        }
        guard Set(values.keys).isSubset(of: allowed),
              action == .click || flags.isSubset(of: ["--require-locked"]),
              !(flags.contains("--screen") && flags.contains("--window-local")),
              !(flags.contains("--screen") && flags.contains("--pixel")),
              values["--app"] != nil || values["--pid"] != nil || values["--window-id"] != nil else {
            throw LockedUseError.usage("Specify a target (--app, --pid, or --window-id) and options appropriate for \(first)")
        }
        let pid = values["--pid"].flatMap(Int32.init)
        let windowID = values["--window-id"].flatMap(UInt32.init)
        let x = values["--x"].flatMap(Double.init), y = values["--y"].flatMap(Double.init)
        guard values["--pid"] == nil || (pid ?? 0) > 0,
              values["--window-id"] == nil || (windowID ?? 0) > 0,
              values["--app"] != "",
              action != .click || (x?.isFinite == true && y?.isFinite == true),
              action != .type || values["--text"] != nil,
              action != .key || values["--key"]?.isEmpty == false,
              action != .capture || values["--out"]?.isEmpty == false else { throw LockedUseError.usage("Missing or invalid \(first) arguments") }
        if let key = values["--key"] { _ = try LockedUseKeyPressParser.parse(key) }
        return .init(action: action, app: values["--app"], pid: pid, windowID: windowID,
            x: x, y: y, pixel: flags.contains("--pixel"), screen: flags.contains("--screen"), doubleClick: flags.contains("--double"),
            text: values["--text"], key: values["--key"], output: values["--out"], requireLocked: flags.contains("--require-locked"))
    }
}
