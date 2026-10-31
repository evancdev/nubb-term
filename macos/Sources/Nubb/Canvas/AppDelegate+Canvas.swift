import AppKit
import UniformTypeIdentifiers

/// The app's entry points to canvases: File menu items and opening
/// `.excalidraw` files.
extension AppDelegate {
    /// The window new canvases join as a tab.
    private var canvasParentWindow: NSWindow? {
        if let main = NSApp.mainWindow, main.windowController is TabSidebarTab { return main }
        return TerminalController.preferredParent?.window
    }

    @IBAction func newCanvas(_ sender: Any?) {
        CanvasController.openNew(nubb: nubb, from: canvasParentWindow)
    }

    @IBAction func openCanvas(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Canvas"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: CanvasDocument.fileExtension) {
            panel.allowedContentTypes = [type, .json]
        }
        let directory = CanvasFiles.defaultDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            panel.directoryURL = directory
        }
        let parent = canvasParentWindow
        let open: ([URL]) -> Void = { [weak self] urls in
            guard let self else { return }
            var anchor = parent
            for url in urls {
                anchor = CanvasController.open(url, nubb: self.nubb, from: anchor).window ?? anchor
            }
        }
        if let parent {
            panel.beginSheetModal(for: parent) { response in
                if response == .OK { open(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            open(panel.urls)
        }
    }

    /// Opens a `.excalidraw` file as a canvas tab. Returns false for other
    /// files so they get the terminal behavior.
    func openCanvasFileIfNeeded(_ filename: String) -> Bool {
        guard CanvasFiles.isCanvasFile(filename) else { return false }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        CanvasController.open(URL(fileURLWithPath: filename), nubb: nubb, from: canvasParentWindow)
        return true
    }

    /// Adds the canvas items to the File menu after New Tab.
    func installCanvasMenuItems() {
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu,
              fileMenu.items.contains(where: { $0.action == #selector(newCanvas(_:)) }) == false else { return }
        let anchor = fileMenu.items.firstIndex { $0.action == #selector(newTab(_:)) } ?? 1

        let newItem = NSMenuItem(title: "New Canvas", action: #selector(newCanvas(_:)), keyEquivalent: "")
        newItem.target = self
        let openItem = NSMenuItem(title: "Open Canvas…", action: #selector(openCanvas(_:)), keyEquivalent: "")
        openItem.target = self
        let revealItem = NSMenuItem(title: "Show Canvas in Finder", action: #selector(CanvasController.revealCanvasInFinder(_:)), keyEquivalent: "")
        let copyPathItem = NSMenuItem(title: "Copy Canvas Path", action: #selector(CanvasController.copyCanvasPath(_:)), keyEquivalent: "")

        fileMenu.insertItem(newItem, at: anchor + 1)
        fileMenu.insertItem(openItem, at: anchor + 2)
        fileMenu.insertItem(revealItem, at: anchor + 3)
        fileMenu.insertItem(copyPathItem, at: anchor + 4)
    }
}
