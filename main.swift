import AppKit
import Foundation
import UniformTypeIdentifiers

let SELFTEST_RESULT: String? = {
#if SELFTEST
    return ProcessInfo.processInfo.environment["ZIPLATIN1_TEST_RESULT"]
#else
    return nil
#endif
}()

// MARK: - Helpers

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    return exists && isDir.boolValue
}

private func standard(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

private func humanBytes(_ bytes: Int) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
}

enum PythonRuntime {
    private static var cached: URL?
    private static var checked = false

    static func find() -> URL? {
        if checked { return cached }
        checked = true
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/python3",
                     "/usr/local/bin/python3",
                     "/usr/bin/python3"] {
            guard fm.isExecutableFile(atPath: path) else { continue }
            if probe(path) {
                cached = URL(fileURLWithPath: path)
                return cached
            }
        }
        return nil
    }

    private static func probe(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import sys; print(int(sys.version_info >= (3, 9)))"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "1"
    }
}

enum Engine {
    static func scriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "zip_latin1", withExtension: "py") {
            return url
        }
        let here = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("zip_latin1.py")
        return FileManager.default.fileExists(atPath: here.path) ? here : nil
    }
}

// MARK: - Drop zone

final class DropZone: NSView {
    var onDrop: (([URL]) -> Void)?
    var onReject: (() -> Void)?
    var acceptsDrops = true

    private var highlighted = false {
        didSet { if highlighted != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func urls(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        return (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    private func folders(from info: NSDraggingInfo) -> [URL] {
        urls(from: info).filter(isDirectory)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrops else { return [] }
        let ok = !folders(from: sender).isEmpty
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsDrops && !folders(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard acceptsDrops else { return false }
        let dirs = folders(from: sender)
        guard !dirs.isEmpty else {
            onReject?()
            return false
        }
        onDrop?(dirs)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)

        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
            path.fill()
        }
        (highlighted ? NSColor.controlAccentColor
                     : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()

        let title = NSAttributedString(
            string: "Drop folders here",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                         .foregroundColor: NSColor.labelColor])
        let subtitle = NSAttributedString(
            string: "All folders go into one .zip, saved next to them",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])

        let iconSize: CGFloat = 26
        let titleSize = title.size()
        let subtitleSize = subtitle.size()
        let totalHeight = iconSize + 6 + titleSize.height + 3 + subtitleSize.height
        var top = bounds.midY + totalHeight / 2

        if let symbol = NSImage(systemSymbolName: "tray.and.arrow.down",
                                accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(
                pointSize: 28, weight: .regular
            ).applying(NSImage.SymbolConfiguration(
                paletteColors: [NSColor.secondaryLabelColor]))
            (symbol.withSymbolConfiguration(config) ?? symbol).draw(
                in: NSRect(x: bounds.midX - iconSize / 2, y: top - iconSize,
                           width: iconSize, height: iconSize))
        }
        top -= iconSize + 6
        title.draw(at: NSPoint(x: bounds.midX - titleSize.width / 2,
                               y: top - titleSize.height))
        top -= titleSize.height + 3
        subtitle.draw(at: NSPoint(x: bounds.midX - subtitleSize.width / 2,
                                  y: top - subtitleSize.height))
    }
}

// MARK: - Engine runner

final class LineSplitter {
    private var buffer = Data()

    func feed(_ data: Data, _ handler: (Data) -> Void) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { handler(Data(line)) }
        }
    }
}

final class DataBox {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class ZipRunner {
    private var process: Process?
    private let splitter = LineSplitter()

    var isRunning: Bool { process?.isRunning ?? false }

    func start(folders: [URL], script: URL, python: URL, output: URL?,
               encoding: String,
               onEvent: @escaping (String, [String: Any]) -> Void,
               onExit: @escaping (Int32, String) -> Void) throws {
        let p = Process()
        p.executableURL = python
        var arguments = ["-u", script.path, "--json",
                         "--encoding", encoding]
        if let output = output {
            arguments += ["--output", output.path]
        }
        arguments += folders.map { $0.path }
        p.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        let stderr = DataBox()
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.splitter.feed(data) { line in
                guard let object = (try? JSONSerialization.jsonObject(with: line))
                        as? [String: Any],
                      let event = object["event"] as? String else { return }
                DispatchQueue.main.async { onEvent(event, object) }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderr.append(data) }
        }

        p.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            stderr.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            DispatchQueue.main.async {
                onExit(proc.terminationStatus, stderr.text())
            }
        }

        try p.run()
        self.process = p
    }

    func cancel() {
        process?.terminate()
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate,
                         NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var tableView: NSTableView!
    private var dropZone: DropZone!
    private var statusLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var progressHeight: NSLayoutConstraint!
    private var encodingPopup: NSPopUpButton!
    private var addButton: NSButton!
    private var clearButton: NSButton!
    private var createButton: NSButton!
    private var revealButton: NSButton!

    private var folders: [URL] = []
    private var pendingURLs: [URL] = []
    private var runner = ZipRunner()
    private var outputURL: URL?
    private var sawDone = false
    private var sawError = false
    private var errorMessage = ""
    private var promptedForDestination = false

    private let encodingDefaultsKey = "NameEncoding"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        updateStatus()
        NSApp.activate(ignoringOtherApps: true)

        if !pendingURLs.isEmpty {
            add(pendingURLs)
            pendingURLs.removeAll()
        }

#if SELFTEST
        setupSelftest()
#endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        runner.cancel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if window == nil {
            pendingURLs.append(contentsOf: urls)
        } else {
            add(urls)
            window.makeKeyAndOrderFront(nil)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    // MARK: Menu

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Zip Latin-1",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Zip Latin-1",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Zip Latin-1",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Zip Latin-1"
        window.minSize = NSSize(width: 520, height: 520)
        window.setFrameAutosaveName("ZipLatin1Window")
        window.center()

        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "ZIP with a chosen name encoding")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let subtitle = NSTextField(
            labelWithString: "Folders are added recursively; filenames are stored in the encoding selected at right.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let encodingLabel = NSTextField(labelWithString: "Encoding:")
        encodingLabel.font = .systemFont(ofSize: 11)
        encodingLabel.textColor = .secondaryLabelColor

        encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        encodingPopup.controlSize = .small
        encodingPopup.font = .systemFont(ofSize: 11)
        encodingPopup.toolTip = "Encoding used for the filenames stored inside the zip"
        for (label, value) in [("CP850 (Windows/DOS)", "cp850"),
                               ("ISO-8859-1 (Latin-1)", "latin1"),
                               ("UTF-8", "utf8")] {
            encodingPopup.addItem(withTitle: label)
            encodingPopup.lastItem?.representedObject = value
        }
        let savedEncoding = UserDefaults.standard.string(forKey: encodingDefaultsKey) ?? "cp850"
        if let item = encodingPopup.itemArray.first(where: {
            ($0.representedObject as? String) == savedEncoding
        }) {
            encodingPopup.select(item)
        } else {
            encodingPopup.selectItem(at: 0)
        }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged(_:))

        dropZone = DropZone()
        dropZone.onDrop = { [weak self] urls in self?.add(urls) }
        dropZone.onReject = { [weak self] in
            self?.statusLabel.stringValue = "Only folders can be added."
        }

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 2

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.isHidden = true

        addButton = NSButton(title: "Add Folders…", target: self,
                             action: #selector(addFolders(_:)))
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "o"

        clearButton = NSButton(title: "Clear", target: self,
                               action: #selector(clearFolders(_:)))
        clearButton.bezelStyle = .rounded

        revealButton = NSButton(title: "Show in Finder", target: self,
                                action: #selector(revealArchive(_:)))
        revealButton.bezelStyle = .rounded
        revealButton.isHidden = true

        createButton = NSButton(title: "Create ZIP", target: self,
                                action: #selector(createZip(_:)))
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.isEnabled = false

        let flexible = NSView()
        flexible.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                           for: .horizontal)
        flexible.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)

        let buttons = NSStackView(views: [addButton, clearButton, flexible,
                                          revealButton, createButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.distribution = .fill

        for view in [title, subtitle, encodingLabel, encodingPopup!,
                     dropZone!, scroll, statusLabel!, progress!,
                     buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        progressHeight = progress.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: encodingLabel.leadingAnchor,
                                            constant: -12),

            encodingPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                    constant: -20),
            encodingPopup.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            encodingLabel.trailingAnchor.constraint(equalTo: encodingPopup.leadingAnchor,
                                                    constant: -6),
            encodingLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                               constant: -20),

            dropZone.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            dropZone.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            dropZone.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            dropZone.heightAnchor.constraint(equalToConstant: 118),

            scroll.topAnchor.constraint(equalTo: dropZone.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            progress.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            progressHeight,

            buttons.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttons.heightAnchor.constraint(equalToConstant: 30),

            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        window.makeKeyAndOrderFront(nil)
    }

    @objc private func encodingChanged(_ sender: Any?) {
        UserDefaults.standard.set(selectedEncoding, forKey: encodingDefaultsKey)
    }

    private var selectedEncoding: String {
        (encodingPopup.selectedItem?.representedObject as? String) ?? "cp850"
    }

    // MARK: Folder list

    private func add(_ urls: [URL]) {
        if runner.isRunning { return }
        var rejected = false
        var changed = false
        for raw in urls {
            let url = standard(raw)
            guard isDirectory(url) else { rejected = true; continue }
            if folders.contains(where: { $0.path == url.path }) { continue }
            if folders.contains(where: { url.path.hasPrefix($0.path + "/") }) {
                continue
            }
            folders.removeAll { $0.path.hasPrefix(url.path + "/") }
            folders.append(url)
            changed = true
        }
        if changed {
            folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            outputURL = nil
            sawDone = false
            sawError = false
            tableView.reloadData()
        }
        updateStatus()
        if rejected && folders.isEmpty {
            statusLabel.stringValue = "Only folders can be added."
        }
    }

    private func updateStatus() {
        if runner.isRunning { return }
        revealButton.isHidden = outputURL == nil || sawError
        clearButton.isEnabled = !folders.isEmpty
        createButton.isEnabled = !folders.isEmpty
        if folders.isEmpty {
            statusLabel.stringValue = "Drop folders above, or use Add Folders."
        } else {
            let total = folders.count
            let items = total == 1 ? "1 folder" : "\(total) folders"
            statusLabel.stringValue = "\(items) selected — one archive will be created."
        }
    }

    @objc private func addFolders(_ sender: Any?) {
        guard !runner.isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to add to the archive"
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    @objc private func clearFolders(_ sender: Any?) {
        guard !runner.isRunning else { return }
        folders.removeAll()
        outputURL = nil
        sawError = false
        tableView.reloadData()
        updateStatus()
    }

    @objc private func revealArchive(_ sender: Any?) {
        guard let url = outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Running

    @objc private func createZip(_ sender: Any?) {
        if runner.isRunning {
            runner.cancel()
            statusLabel.stringValue = "Cancelling…"
            createButton.isEnabled = false
            return
        }
        guard !folders.isEmpty else { return }
        guard let python = PythonRuntime.find() else {
            showAlert(title: "Python 3 is required",
                      message: "Install Python 3 with Homebrew (brew install python3) or install the Xcode Command Line Tools (xcode-select --install), then try again.")
            return
        }
        guard let script = Engine.scriptURL() else {
            showAlert(title: "Engine missing",
                      message: "The archive engine (zip_latin1.py) is not inside the application bundle.")
            return
        }

        // Folders from different parents, or a read-only destination: let the
        // user choose where the archive goes. Folders sharing a writable
        // parent go next to them, as before.
        var outputOverride: URL?
        let parents = Set(folders.map { $0.deletingLastPathComponent().path })
        let defaultDirectory = folders[0].deletingLastPathComponent()
        let defaultWritable = isWritable(defaultDirectory)

        promptedForDestination = false
        if parents.count > 1 || !defaultWritable {
#if SELFTEST
            if let testOutput = ProcessInfo.processInfo.environment["ZIPLATIN1_TEST_OUTPUT"],
               !testOutput.isEmpty {
                outputOverride = URL(fileURLWithPath: testOutput)
            }
#endif
            promptedForDestination = true
            if outputOverride == nil {
                guard let destination = askForDestination() else { return }
                outputOverride = destination
            }
        }

        runner = ZipRunner()
        outputURL = nil
        sawDone = false
        sawError = false
        errorMessage = ""
        revealButton.isHidden = true
        setBusy(true)
        statusLabel.stringValue = "Scanning folders…"
        statusLabel.toolTip = nil

        do {
            try runner.start(
                folders: folders, script: script, python: python,
                output: outputOverride, encoding: selectedEncoding,
                onEvent: { [weak self] event, object in
                    self?.handle(event, object)
                },
                onExit: { [weak self] code, stderr in
                    self?.finish(code: code, stderr: stderr)
                })
        } catch {
            setBusy(false)
            showAlert(title: "Could not start",
                      message: error.localizedDescription)
        }
    }

    private func defaultArchiveName() -> String {
        guard let first = folders.first else { return "Archive.zip" }
        if folders.count == 1 {
            return first.lastPathComponent + ".zip"
        }
        return "\(first.lastPathComponent) and \(folders.count - 1) more.zip"
    }

    private func isWritable(_ directory: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path,
                                                    isDirectory: &isDir)
        return exists && isDir.boolValue
            && FileManager.default.isWritableFile(atPath: directory.path)
    }

    private func writableFallbackDirectory() -> URL? {
        let fm = FileManager.default
        if let desktop = fm.urls(for: .desktopDirectory,
                                 in: .userDomainMask).first,
           isWritable(desktop) {
            return desktop
        }
        let home = fm.homeDirectoryForCurrentUser
        return isWritable(home) ? home : nil
    }

    private func askForDestination() -> URL? {
        let defaultDirectory = folders[0].deletingLastPathComponent()
        let readOnly = !isWritable(defaultDirectory)
        let multipleLocations = Set(
            folders.map { $0.deletingLastPathComponent().path }).count > 1

        let panel = NSSavePanel()
        panel.title = "Save Archive"
        if readOnly && multipleLocations {
            panel.message = "The folders are in different locations and the usual destination is read-only. Choose where to save the archive."
        } else if readOnly {
            panel.message = "The folders are on a read-only location. Choose where to save the archive."
        } else {
            panel.message = "The folders come from different locations. Choose where to save the archive."
        }
        panel.prompt = "Create"
        panel.nameFieldStringValue = defaultArchiveName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.showsTagField = false
        panel.allowedContentTypes = [UTType.zip]
        panel.directoryURL = readOnly ? writableFallbackDirectory() : defaultDirectory

        while true {
            guard panel.runModal() == .OK, var url = panel.url else { return nil }
            if url.pathExtension.lowercased() != "zip" {
                url = url.appendingPathExtension("zip")
            }
            if isWritable(url.deletingLastPathComponent()) {
                return url
            }
            panel.directoryURL = writableFallbackDirectory()
            showAlert(title: "Can't save there",
                      message: "The selected folder is read-only or not writable. Please choose another location.")
        }
    }

    private func handle(_ event: String, _ object: [String: Any]) {
        switch event {
        case "scanning":
            statusLabel.stringValue = "Scanning folders…"
            progress.isIndeterminate = true
            progress.isHidden = false
            progressHeight.constant = 8
            progress.startAnimation(nil)

        case "start":
            progress.stopAnimation(nil)
            progress.isIndeterminate = false
            let total = object["total"] as? Int ?? 0
            progress.minValue = 0
            progress.maxValue = Double(max(total, 1))
            progress.doubleValue = 0
            if let archive = object["archive"] as? String {
                outputURL = URL(fileURLWithPath: archive)
            }
            statusLabel.stringValue = "Creating archive…"

        case "entry":
            let index = object["index"] as? Int ?? 0
            let total = object["total"] as? Int ?? 0
            progress.doubleValue = Double(index)
            if let name = object["name"] as? String {
                statusLabel.stringValue = "\(index) of \(total) — \(name)"
            }

        case "done":
            sawDone = true
            let entries = object["entries"] as? Int ?? 0
            let bytes = object["bytes"] as? Int ?? 0
            let renamed = object["renamed_total"] as? Int ?? 0
            if let archive = object["archive"] as? String {
                outputURL = URL(fileURLWithPath: archive)
            }
            var message = ""
            if let url = outputURL {
                message = "Created \(url.lastPathComponent) — \(entries) items, \(humanBytes(bytes))"
            } else {
                message = "Archive created."
            }
            if renamed > 0 {
                message += " · \(renamed) name\(renamed == 1 ? "" : "s") transliterated"
                if let pairs = object["renamed"] as? [[String]] {
                    statusLabel.toolTip = pairs.map { "\($0[0])  →  \($0[1])" }
                        .joined(separator: "\n")
                }
            }
            statusLabel.stringValue = message
            progress.doubleValue = progress.maxValue
            revealButton.isHidden = false
            if let url = outputURL, SELFTEST_RESULT == nil {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }

        case "error":
            sawError = true
            errorMessage = (object["message"] as? String) ?? "Failed."
            statusLabel.stringValue = errorMessage

        default:
            break
        }
    }

    private func finish(code: Int32, stderr: String) {
        setBusy(false)
#if SELFTEST
        if SELFTEST_RESULT != nil {
            if let after = ProcessInfo.processInfo.environment["ZIPLATIN1_SNAPSHOT_AFTER"] {
                saveSnapshot(to: after)
            }
            writeSelftestResult(code: code, stderr: stderr)
            return
        }
#endif
        if code == 0 && sawDone { return }

        if code == 15 || code == 130 || code == 143 {
            statusLabel.stringValue = "Cancelled."
            return
        }

        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail: String
        if !errorMessage.isEmpty {
            detail = errorMessage
        } else if !trimmed.isEmpty {
            detail = trimmed
        } else {
            detail = "The engine stopped with exit code \(code)."
        }
        statusLabel.stringValue = "Failed."
        showAlert(title: "Could not create the archive", message: detail)
    }

    private func setBusy(_ busy: Bool) {
        dropZone.acceptsDrops = !busy
        addButton.isEnabled = !busy
        encodingPopup.isEnabled = !busy
        clearButton.isEnabled = !busy && !folders.isEmpty
        createButton.isEnabled = busy || !folders.isEmpty
        createButton.title = busy ? "Cancel" : "Create ZIP"
        tableView.isEnabled = !busy
        if !busy {
            progress.stopAnimation(nil)
            progress.isHidden = true
            progressHeight.constant = 0
            clearButton.isEnabled = !folders.isEmpty
            createButton.isEnabled = !folders.isEmpty
            if sawDone {
                revealButton.isHidden = outputURL == nil
            } else if sawError {
                revealButton.isHidden = true
            } else {
                updateStatus()
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        folders.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FolderCell")
        var cell = tableView.makeView(withIdentifier: identifier,
                                      owner: nil) as? NSTableCellView
        if cell == nil {
            let created = NSTableCellView()
            created.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.maximumNumberOfLines = 2
            field.lineBreakMode = .byTruncatingMiddle
            created.addSubview(field)
            created.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: created.leadingAnchor,
                                               constant: 6),
                field.trailingAnchor.constraint(equalTo: created.trailingAnchor,
                                                constant: -6),
                field.centerYAnchor.constraint(equalTo: created.centerYAnchor),
            ])
            cell = created
        }

        let url = folders[row]
        let text = NSMutableAttributedString(
            string: url.lastPathComponent + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(
            string: url.deletingLastPathComponent().path,
            attributes: [.font: NSFont.systemFont(ofSize: 10),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        cell?.textField?.attributedStringValue = text
        cell?.toolTip = url.path
        return cell
    }
}

// MARK: - Self test support

#if SELFTEST
extension AppDelegate {
    func setupSelftest() {
        let env = ProcessInfo.processInfo.environment
        if let list = env["ZIPLATIN1_TEST_FOLDERS"], !list.isEmpty {
            add(list.components(separatedBy: "|").map { URL(fileURLWithPath: $0) })
        }
        if let encoding = env["ZIPLATIN1_ENCODING"],
           let item = encodingPopup.itemArray.first(where: {
               ($0.representedObject as? String) == encoding
           }) {
            encodingPopup.select(item)
        }
        if let snapshot = env["ZIPLATIN1_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.saveSnapshot(to: snapshot)
            }
        }
        if env["ZIPLATIN1_AUTOSTART"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.createZip(nil)
            }
        }
    }

    func saveSnapshot(to path: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    func writeSelftestResult(code: Int32, stderr: String) {
        guard let path = SELFTEST_RESULT else { return }
        let object: [String: Any] = [
            "ok": code == 0 && sawDone,
            "code": Int(code),
            "status": statusLabel.stringValue,
            "archive": outputURL?.path ?? "",
            "prompted": promptedForDestination,
            "stderr": stderr,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}
#endif

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
