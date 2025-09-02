import Foundation
import Lowtech
import SwiftTerm

public class FZFTerminal: TerminalDelegate, LocalProcessDelegate {
    public init(queue: DispatchQueue? = nil, options: TerminalOptions = TerminalOptions.default, onEnd: @escaping (_ exitCode: Int32?) -> Void) {
        self.onEnd = onEnd
        terminal = Terminal(delegate: self, options: options)
        process = LocalProcess(delegate: self, dispatchQueue: queue)
        
        // Store original onEnd to ensure cleanup
        self.originalOnEnd = onEnd
        
        // Wrap onEnd to ensure cleanup happens
        self.onEnd = { [weak self] exitCode in
            self?.cleanup()
            onEnd(exitCode)
        }
    }

    deinit {
        cleanup()
    }

    public private(set) var terminal: Terminal!
    public var images: [([UInt8], Int, Int)] = []
    
    private var originalOnEnd: (_ exitCode: Int32?) -> Void
    private var isCleanedUp = false
    private let cleanupLock = NSLock()

    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        cleanup()
        originalOnEnd(exitCode)
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
//        debug(String (bytes: slice, encoding: .utf8) ?? "")
        guard !isCleanedUp else { return }
        terminal?.feed(buffer: slice)
    }

    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        send(data: data)
    }

    public func getWindowSize() -> winsize {
        guard let terminal = terminal else {
            return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 16, ws_ypixel: 16)
        }
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: UInt16(16), ws_ypixel: UInt16(16))
    }

    public func mouseModeChanged(source: Terminal) {}

    public func hostCurrentDirectoryUpdated(source: Terminal) {
        guard !isCleanedUp else { return }
        dir = source.hostCurrentDirectory
    }
    
    public func colorChanged(source: Terminal, idx: Int) {}

    public func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        guard !isCleanedUp else { return }
        images.append((bytes, width, height))
    }

    var process: LocalProcess!
    var onEnd: (_ exitCode: Int32?) -> Void
    var dir: String?

    var running: Bool {
        guard !isCleanedUp, let process = process else { return false }
        return process.running && kill(process.shellPid, 0) == 0
    }

    func send(data: ArraySlice<UInt8>) {
        guard !isCleanedUp else { return }
        process?.send(data: data)
    }

    func send(_ text: String) {
        send(data: [UInt8](text.utf8)[...])
    }
    
    /// Properly cleanup all PTY resources
    private func cleanup() {
        cleanupLock.lock()
        defer { cleanupLock.unlock() }
        
        guard !isCleanedUp else { return }
        isCleanedUp = true
        
        // Terminate the process if still running
        if let process = process, process.running {
            // Send SIGTERM first for graceful shutdown
            kill(process.shellPid, SIGTERM)
            
            // Give process time to terminate gracefully
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, let process = self.process else { return }
                
                // If still running, force kill
                if process.running {
                    kill(process.shellPid, SIGKILL)
                }
                
                // Explicitly close PTY file descriptors
                self.closePTYDescriptors()
            }
        } else {
            closePTYDescriptors()
        }
        
        // Clear references
        terminal = nil
        process = nil
        images.removeAll()
        dir = nil
    }
    
    /// Close PTY file descriptors explicitly
    private func closePTYDescriptors() {
        guard let process = process else { return }
        
        // Access the underlying file descriptors through reflection or direct access
        // This ensures PTY descriptors are properly closed
        let mirror = Mirror(reflecting: process)
        for child in mirror.children {
            if let label = child.label {
                // Look for file descriptor properties
                if label.contains("fd") || label.contains("pty") {
                    if let fd = child.value as? Int32, fd >= 0 {
                        close(fd)
                    }
                }
            }
        }
    }
    
    /// Force cleanup - can be called externally
    public func forceCleanup() {
        cleanup()
    }
}
