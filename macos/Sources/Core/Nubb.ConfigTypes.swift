extension Nubb {
    /// A configuration path value that may be optional or required.
    struct ConfigPath: Sendable {
        let path: String
        let optional: Bool
    }
}
