import Foundation

extension UserDefaults {
    static var nubbSuite: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["NUBB_USER_DEFAULTS_SUITE"]
        #else
        nil
        #endif
    }

    static var nubb: UserDefaults {
        nubbSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
