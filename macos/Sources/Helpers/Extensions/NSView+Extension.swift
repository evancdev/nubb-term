import AppKit
import SwiftUI

extension NSView {
    /// Returns true if this view is currently the first responder
    var isFirstResponder: Bool {
        window?.firstResponder === self
    }
}

// MARK: View Traversal and Search

extension NSView {
    /// Returns the absolute root view by walking up the superview chain.
    var rootView: NSView {
        var root: NSView = self
        while let superview = root.superview {
            root = superview
        }
        return root
    }

    /// Checks if the view contains the given class in its hierarchy.
    func contains(className name: String) -> Bool {
        if String(describing: type(of: self)) == name {
            return true
        }

        for subview in subviews where subview.contains(className: name) {
            return true
        }

        return false
    }

    /// Finds the superview with the given class name.
    func firstSuperview(withClassName name: String) -> NSView? {
        guard let superview else { return nil }
        if String(describing: type(of: superview)) == name {
            return superview
        }

        return superview.firstSuperview(withClassName: name)
    }

    /// Recursively finds and returns the first descendant view that has the given class name.
    func firstDescendant(withClassName name: String) -> NSView? {
        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                return subview
            } else if let found = subview.firstDescendant(withClassName: name) {
                return found
            }
        }

        return nil
    }

    /// Recursively finds and returns descendant views that have the given class name.
    func descendants(withClassName name: String) -> [NSView] {
        var result = [NSView]()

        for subview in subviews {
            if String(describing: type(of: subview)) == name {
                result.append(subview)
            }

            result += subview.descendants(withClassName: name)
        }

        return result
    }

	/// Recursively finds and returns the first descendant view that has the given identifier.
	func firstDescendant(withID id: String) -> NSView? {
		for subview in subviews {
			if subview.identifier == NSUserInterfaceItemIdentifier(id) {
				return subview
			} else if let found = subview.firstDescendant(withID: id) {
				return found
			}
		}

		return nil
	}

	/// Finds and returns the first view with the given class name starting from the absolute root of the view hierarchy.
	/// This includes private views like title bar views.
	func firstViewFromRoot(withClassName name: String) -> NSView? {
		let root = rootView

		// Check if the root view itself matches
		if String(describing: type(of: root)) == name {
			return root
		}

		// Otherwise search descendants
		return root.firstDescendant(withClassName: name)
	}
}
