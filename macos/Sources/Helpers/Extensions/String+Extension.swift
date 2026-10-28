extension String {
    /// True when the first scalar is an ASCII control character (C0 or DEL).
    var startsWithASCIIControlCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// The string as the text of a terminal key event, or nil when it is empty
    /// or begins with an ASCII control character.
    ///
    /// - Note: Control characters are encoded by Nubb itself so that the
    /// physical key and its modifiers remain available to protocols
    /// such as the Kitty keyboard protocol.
    var keyEventText: String? {
        guard !isEmpty, !startsWithASCIIControlCharacter else { return nil }
        return self
    }

    /// Returns the path with the home directory abbreviated as ~.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if hasPrefix(home) {
            return "~" + dropFirst(home.count)
        }
        return self
    }
}
