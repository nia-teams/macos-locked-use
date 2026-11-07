import Foundation

public enum LockedUseCommand: Equatable {
    case status(json: Bool)
    case exec(command: [String], requireLocked: Bool)
    case gui(LockedUseGUICommand)
    case end
    case lock
    case manage(String)
    case help

    public static let usage = """
    Usage: locked-use status [--json]
           locked-use enable | disable | recover | certify | end | lock
           locked-use exec [--require-locked] -- <command> [args...]
           locked-use click (--app <name-or-bundle-id> | --pid <pid> | --window-id <id>) --x <coord> --y <coord> [--pixel] [--double] [--screen | --window-local] [--require-locked]
           locked-use type <target> --text <text> [--require-locked]
           locked-use key <target> --key <cmd+v|Return|...> [--require-locked]
           locked-use capture <target> --out <file.png> [--require-locked]
    Target options may be combined to constrain ownership. Click coordinates default
    to logical points from the window's top-left; pass --pixel to use screenshot
    pixel coordinates directly, or --screen for global screen points. Exit 75: yield
    to human; 76: lease expired/relocked; 77: unavailable/precondition; 64: usage.
    """

    public static func parse(_ arguments: [String]) throws -> Self {
        switch arguments {
        case [], ["--help"], ["-h"]: return .help
        case ["status"]: return .status(json: false)
        case ["status", "--json"]: return .status(json: true)
        case ["end"]: return .end
        case ["lock"]: return .lock
        default: break
        }
        if arguments.count == 1, ["enable", "disable", "recover", "certify"].contains(arguments[0]) {
            return .manage(arguments[0])
        }
        if let first = arguments.first, LockedUseGUICommand.Action(rawValue: first) != nil {
            return .gui(try LockedUseGUICommand.parse(arguments))
        }
        if arguments.first == "exec" {
            var rest = Array(arguments.dropFirst())
            let required = rest.first == "--require-locked"
            if required { rest.removeFirst() }
            if rest.first == "--", rest.count > 1, !rest[1].isEmpty {
                return .exec(command: Array(rest.dropFirst()), requireLocked: required)
            }
        }
        throw LockedUseError.usage(usage)
    }
}
