import Foundation
import Lowtech
import SwiftTerm

public class FZFTerminal: TerminalDelegate, LocalProcessDelegate {
    public init(queue: DispatchQueue? = nil, options: TerminalOptions = TerminalOptions.default, onEnd: @escaping (_ exitCode: Int32?) -> Void) {
        self.onEnd = onEnd
        terminal = Terminal(delegate: self, options: options)
        process = LocalProcess(delegate: self, dispatchQueue: queue)
    }

    public private(set) var terminal: Terminal!
    public var images: [([UInt8], Int, Int)] = []

    public func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        onEnd(exitCode)
    }

    public func dataReceived(slice: ArraySlice<UInt8>) {
//        debug(String (bytes: slice, encoding: .utf8) ?? "")
        terminal.feed(buffer: slice)
    }

    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        send(data: data)
    }

    public func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: UInt16(16), ws_ypixel: UInt16(16))
    }

    public func mouseModeChanged(source: Terminal) {}

    public func hostCurrentDirectoryUpdated(source: Terminal) {
        dir = source.hostCurrentDirectory
    }
    public func colorChanged(source: Terminal, idx: Int) {}

    public func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        images.append((bytes, width, height))
    }

    var process: LocalProcess!
    var onEnd: (_ exitCode: Int32?) -> Void
    var dir: String?

    var running: Bool {
        process.running && kill(process.shellPid, 0) == 0
    }

    func send(data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func send(_ text: String) {
        send(data: [UInt8](text.utf8)[...])

    }

}
