extension Nubb {
    /// Possible errors from internal Nubb calls.
    enum Error: Swift.Error, CustomLocalizedStringResourceConvertible {
        case apiFailed

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .apiFailed: return "libnubb API call failed"
            }
        }
    }
}
