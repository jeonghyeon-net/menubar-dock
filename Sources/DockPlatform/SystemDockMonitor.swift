import Darwin
import Foundation

/// Dock plist와 그 부모 디렉터리를 함께 감시해 파일의 원자 교체도 놓치지 않는다.
@MainActor
public final class SystemDockMonitor {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Watch {
        let identity: Identity
        let source: any DispatchSourceFileSystemObject
    }

    private let preferencesURL: URL
    private let debounce: Duration
    private let retryDelays: [Duration]
    private let readData: (URL) throws -> Data
    private var directoryWatch: Watch?
    private var fileWatch: Watch?
    private var pendingRefresh: Task<Void, Never>?
    private var lastPayload: NSArray?
    private var onChange: (@MainActor () -> Void)?
    private var generation: UInt64 = 0

    public convenience init() {
        self.init(preferencesURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist"))
    }

    init(
        preferencesURL: URL, debounce: Duration = .milliseconds(120),
        retryDelays: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(600)],
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.preferencesURL = preferencesURL
        self.debounce = debounce
        self.retryDelays = retryDelays
        self.readData = readData
    }

    isolated deinit { stop() }

    /// 먼저 구독하고 기준값을 읽는다. 호출자는 이 메서드 다음에 최초 Dock 가져오기를 수행한다.
    public func start(onChange: @escaping @MainActor () -> Void) throws {
        stop()
        self.onChange = onChange
        do {
            try reconnectDirectory()
            _ = try reconnectFile()
        } catch {
            stop()
            throw error
        }
        do { lastPayload = try payload() }
        catch { scheduleRefresh(after: debounce, retry: 0) }
    }

    public func stop() {
        generation &+= 1
        pendingRefresh?.cancel()
        pendingRefresh = nil
        directoryWatch?.source.cancel()
        fileWatch?.source.cancel()
        directoryWatch = nil
        fileWatch = nil
        lastPayload = nil
        onChange = nil
    }

    private func reconnectDirectory() throws {
        let url = preferencesURL.deletingLastPathComponent()
        let current = try identity(at: url)
        guard current != directoryWatch?.identity else { return }
        let replacement = try watch(url: url, isDirectory: true)
        directoryWatch?.source.cancel()
        directoryWatch = replacement
    }

    @discardableResult
    private func reconnectFile() throws -> Bool {
        let current: Identity
        do { current = try identity(at: preferencesURL) }
        catch let error as POSIXError where error.code == .ENOENT {
            let hadWatch = fileWatch != nil
            fileWatch?.source.cancel()
            fileWatch = nil
            return hadWatch
        }
        guard current != fileWatch?.identity else { return false }
        let replacement = try watch(url: preferencesURL, isDirectory: false)
        fileWatch?.source.cancel()
        fileWatch = replacement
        return true
    }

    private func watch(url: URL, isDirectory: Bool) throws -> Watch {
        let descriptor = Darwin.open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw systemError(path: url.path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = systemError(path: url.path)
            Darwin.close(descriptor)
            throw error
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main
        )
        let subscribedGeneration = generation
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == subscribedGeneration, self.onChange != nil else { return }
                self.receive(isDirectory: isDirectory)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return Watch(identity: Identity(device: info.st_dev, inode: info.st_ino), source: source)
    }

    private func receive(isDirectory: Bool) {
        do {
            try reconnectDirectory()
            let fileReplaced = try reconnectFile()
            // 다른 앱의 plist 교체가 Dock 변경 debounce를 계속 미루지 않도록 걸러낸다.
            if !isDirectory || fileReplaced { scheduleRefresh(after: debounce, retry: 0) }
        } catch {
            scheduleRefresh(after: debounce, retry: 0)
        }
    }

    private func scheduleRefresh(after delay: Duration, retry: Int) {
        pendingRefresh?.cancel()
        let scheduledGeneration = generation
        pendingRefresh = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == scheduledGeneration, self.onChange != nil else { return }
            self.pendingRefresh = nil
            do {
                try self.reconnectDirectory()
                _ = try self.reconnectFile()
                let next = try self.payload()
                guard self.lastPayload?.isEqual(next) != true else { return }
                self.lastPayload = next
                self.onChange?()
            } catch {
                // 부분 쓰기·원자 교체 중의 일시 실패만 제한적으로 재시도하고 마지막 정상값은 유지한다.
                guard retry < self.retryDelays.count else { return }
                self.scheduleRefresh(after: self.retryDelays[retry], retry: retry + 1)
            }
        }
    }

    private func payload() throws -> NSArray {
        let object = try PropertyListSerialization.propertyList(from: readData(preferencesURL), options: [], format: nil)
        guard let domain = object as? [String: Any], let applications = domain["persistent-apps"] as? [Any] else {
            throw SystemDockReaderError.invalidApplicationList
        }
        return NSArray(array: applications)
    }

    private func identity(at url: URL) throws -> Identity {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw systemError(path: url.path) }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private func systemError(path: String) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: path])
    }
}
