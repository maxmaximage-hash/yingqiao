import AppKit
import SwiftUI
import AVFoundation
import ImageCaptureCore
import ImageIO
import Photos
import PhotosUI
import UniformTypeIdentifiers

private let appName = "影桥"
private let appSubtitle = "iPhone 媒体导入器"

enum SourceMode: String, CaseIterable, Identifiable {
    case photosLibrary = "照片图库"
    case usb = "USB 设备"
    var id: String { rawValue }
}

final class PhotoLibraryAsset: ObservableObject, Identifiable {
    let asset: PHAsset
    let id: String
    @Published var thumbnail: NSImage?
    @Published var livePhoto: PHLivePhoto?
    @Published var isLiveLoading = false
    @Published var isSelected = false

    init(asset: PHAsset) {
        self.asset = asset
        self.id = asset.localIdentifier
    }

    var isLive: Bool { asset.mediaSubtypes.contains(.photoLive) }
}

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published var assets: [PhotoLibraryAsset] = []
    @Published var status = "正在检查照片图库权限…"
    @Published private(set) var isReady = false
    private let imageManager = PHCachingImageManager()
    private let audit = CatalogAuditLogger.shared
    private var authorizationRequestInFlight = false

    init() { load() }

    func load() {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .notDetermined {
            guard !authorizationRequestInFlight else { return }
            authorizationRequestInFlight = true
            status = "正在请求照片图库权限，请在系统弹窗中选择“允许访问所有照片”…"
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.authorizationRequestInFlight = false
                    self?.applyAuthorization(status)
                }
            }
        } else {
            applyAuthorization(authorization)
        }
    }

    private func applyAuthorization(_ status: PHAuthorizationStatus) {
        guard status == .authorized || status == .limited else {
            isReady = false
            self.status = "没有获得照片图库权限，请在系统设置中允许影桥访问照片"
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var loaded: [PhotoLibraryAsset] = []
        result.enumerateObjects { asset, _, _ in loaded.append(PhotoLibraryAsset(asset: asset)) }
        assets = loaded
        isReady = true
        let limitedPrefix = status == .limited ? "照片权限为有限访问，" : ""
        self.status = "\(limitedPrefix)照片图库已读取 \(loaded.count) 项 · Live \(loaded.filter(\.isLive).count) 张"
        audit.record("photosLibraryLoaded", [
            "authorization": status == .limited ? "limited" : "authorized",
            "assetCount": loaded.count,
            "liveCount": loaded.filter(\.isLive).count,
            "source": "PhotoKit"
        ])
    }

    func requestThumbnail(for item: PhotoLibraryAsset) {
        guard item.thumbnail == nil else { return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        imageManager.requestImage(
            for: item.asset,
            targetSize: CGSize(width: 320, height: 320),
            contentMode: .aspectFill,
            options: options
        ) { [weak item] image, _ in
            Task { @MainActor in item?.thumbnail = image }
        }
    }

    func requestLivePhoto(for item: PhotoLibraryAsset) {
        guard item.isLive, item.livePhoto == nil, !item.isLiveLoading else { return }
        item.isLiveLoading = true
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        PHImageManager.default().requestLivePhoto(
            for: item.asset,
            targetSize: CGSize(width: 640, height: 640),
            contentMode: .aspectFill,
            options: options
        ) { [weak item] livePhoto, _ in
            Task { @MainActor in
                item?.livePhoto = livePhoto
                item?.isLiveLoading = false
            }
        }
    }
}

final class CatalogAuditLogger {
    static let shared = CatalogAuditLogger()
    let sessionID = UUID().uuidString
    let fileURL: URL

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/影桥", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("catalog-audit.ndjson")
        record("sessionStart", ["appVersion": "0.1.0"])
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sessionID": sessionID,
            "event": event
        ]
        fields.forEach { payload[$0.key] = $0.value }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        var line = data
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: fileURL, options: .atomic)
        }
    }
}

final class MediaAsset: ObservableObject, Identifiable {
    let item: ICCameraFile
    let id: String
    let name: String
    let uti: String
    let createdAt: Date?
    var liveVideo: ICCameraFile?
    @Published var thumbnail: NSImage?
    @Published var isSelected = false
    @Published var livePreviewURL: URL?
    @Published var isLivePreviewLoading = false

    init(item: ICCameraFile, liveVideo: ICCameraFile? = nil) {
        self.item = item
        self.id = "\(item.ptpObjectHandle)-\(item.name ?? UUID().uuidString)"
        self.name = item.name ?? "未命名媒体"
        self.uti = item.uti ?? "public.data"
        self.createdAt = item.creationDate
        self.liveVideo = liveVideo
    }

    var isVideo: Bool {
        uti.contains("movie") || uti.contains("video") || ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }

    var isLivePhoto: Bool { liveVideo != nil && !isVideo }
}

private final class ThumbnailDiskCache {
    static let shared = ThumbnailDiskCache()

    private let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("影桥/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for id: String) -> URL {
        let encoded = Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("\(encoded)-256.thumb")
    }

    func loadImage(for id: String) -> NSImage? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return NSImage(data: data)
    }

    func store(data: Data, for id: String) {
        let fileURL = url(for: id)
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func store(cgImage: CGImage, for id: String) {
        let fileURL = url(for: id)
        DispatchQueue.global(qos: .utility).async {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

final class DeviceBrowserProxy: NSObject, ICDeviceBrowserDelegate {
    weak var owner: ImporterModel?

    init(owner: ImporterModel) {
        self.owner = owner
        super.init()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor [weak owner] in
            owner?.browserDidAdd(device, moreComing: moreComing)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor [weak owner] in
            owner?.browserDidRemove(device, moreGoing: moreGoing)
        }
    }
}

final class CameraDelegateProxy: NSObject, ICCameraDeviceDelegate {
    weak var owner: ImporterModel?

    init(owner: ImporterModel) {
        self.owner = owner
        super.init()
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor [weak owner] in owner?.deviceDidOpen(device, error: error) }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor [weak owner] in owner?.deviceDidClose(device, error: error) }
    }

    func didRemove(_ device: ICDevice) {
        Task { @MainActor [weak owner] in owner?.deviceWasRemoved(device) }
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        Task { @MainActor [weak owner] in owner?.deviceBecameReady(device) }
    }

    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {
        Task { @MainActor [weak owner] in owner?.deviceReceivedStatus(device, status: status) }
    }

    func device(_ device: ICDevice, didEncounterError error: Error?) {
        Task { @MainActor [weak owner] in owner?.deviceEncounteredError(device, error: error) }
    }

    func device(_ device: ICDevice, didEjectWithError error: Error?) {
        Task { @MainActor [weak owner] in owner?.deviceWasEjected(device, error: error) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor [weak owner] in owner?.cameraDidAdd(camera, items: items) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor [weak owner] in owner?.cameraDidRemove(camera, items: items) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        Task { @MainActor [weak owner] in owner?.cameraReceivedThumbnail(camera, thumbnail: thumbnail, item: item, error: error) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: Error?) {
        Task { @MainActor [weak owner] in owner?.cameraReceivedMetadata(camera, metadata: metadata, item: item, error: error) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        Task { @MainActor [weak owner] in owner?.cameraDidRename(camera, items: items) }
    }

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor [weak owner] in owner?.cameraCapabilityChanged(camera) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        Task { @MainActor [weak owner] in owner?.cameraReceivedPTPEvent(camera, eventData: eventData) }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor [weak owner] in owner?.cameraBecameReadyWithCompleteCatalog(device) }
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor [weak owner] in owner?.cameraDidRemoveAccessRestriction(device) }
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor [weak owner] in owner?.cameraDidEnableAccessRestriction(device) }
    }

    // Visible cells request thumbnails explicitly after the catalog is ready.
    // Allowing automatic requests here makes ImageCaptureCore start one for
    // every catalog item and compete with the visible-grid queue.
    func cameraDevice(_ camera: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool { false }
    func cameraDevice(_ camera: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool { false }
}

final class DownloadDelegateProxy: NSObject, ICCameraDeviceDownloadDelegate {
    weak var owner: ImporterModel?

    init(owner: ImporterModel) {
        self.owner = owner
        super.init()
    }

    @objc func downloadedFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor [weak owner] in
            owner?.downloadedFile(file, error: error, options: options, contextInfo: contextInfo)
        }
    }

    func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String : Any], contextInfo: UnsafeMutableRawPointer?) {
        downloadedFile(file, error: error, options: options, contextInfo: contextInfo)
    }

    func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: Int64, maxBytes: Int64) {}
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case original = "保留原格式"
    case jpg = "JPG"

    var id: String { rawValue }
}

@MainActor
final class ImporterModel: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICDeviceDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    private let audit = CatalogAuditLogger.shared
    @Published var status = "正在搜索 iPhone…"
    @Published var deviceName = "未连接"
    @Published var assets: [MediaAsset] = []
    @Published var isConnected = false
    @Published private(set) var isCatalogComplete = false
    @Published private(set) var livePhotoCount = 0
    @Published var isImporting = false
    @Published var importProgress = 0.0
    @Published var lastError: String?
    @Published private(set) var browserDeviceCount = 0
    @Published var destinationURL: URL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("手机媒体导入", isDirectory: true)
    @Published var exportFormat: ExportFormat = .original
    @Published var jpgQuality: Double = 1.0

    var selectionSummary: String {
        let count = assets.filter(\.isSelected).count
        let total = isCatalogComplete ? "\(assets.count) 项媒体" : "暂时已发现 \(assets.count) 项"
        return count == 0 ? total : "已选择 \(count) 项 · \(total)"
    }

    private var browser: ICDeviceBrowser!
    private var browserProxy: DeviceBrowserProxy!
    private var cameraProxy: CameraDelegateProxy!
    private var downloadProxy: DownloadDelegateProxy!
    private var camera: ICCameraDevice?
    private var thumbnailItems: [String: ICCameraItem] = [:]
    private var assetsByID: [String: MediaAsset] = [:]
    private var mediaByID: [String: ICCameraFile] = [:]
    private var mediaOrderIDs: [String] = []
    private var metadataByID: [String: [String: Any]] = [:]
    private var metadataDebugRecords: [[String: Any]] = []
    private var requestedThumbnailIDs: Set<String> = []
    private var thumbnailQueue: [String] = []
    private var thumbnailQueuedIDs: Set<String> = []
    private var activeThumbnailIDs: Set<String> = []
    private var thumbnailCacheCheckedIDs: Set<String> = []
    private var thumbnailCacheLoadingIDs: Set<String> = []
    private var thumbnailRetryCounts: [String: Int] = [:]
    private var thumbnailAuditCount = 0
    private var thumbnailCompletionAuditCount = 0
    private let maxConcurrentThumbnails = 2
    private let thumbnailPrefetchRadius = 18
    private let thumbnailQueueLimit = 48
    private let thumbnailRetryLimit = 1
    private var importQueue: [MediaAsset] = []
    private var importIndex = 0
    private var workingDirectory: URL?
    private var livePreviewDirectory: URL?
    private var livePreviewCache: [String: URL] = [:]
    private var liveDownloadProgress: [String: Progress] = [:]
    private var hoveredLiveAssetID: String?
    private var liveHoverTask: Task<Void, Never>?
    private var completeCatalogSignal = false
    private var catalogRevision = 0
    private var lastSessionOpenAttempt: Date?
    private var isAccessRestricted = false
    private var catalogStabilityTask: Task<Void, Never>?
    private var deviceHealthTask: Task<Void, Never>?
    private var browserReconcileTask: Task<Void, Never>?
    private var emptyCatalogRetryTask: Task<Void, Never>?
    private var deviceHealthFailureCount = 0
    private let catalogStabilityRounds = 3
    private let catalogStabilityDelayNanoseconds: UInt64 = 2_000_000_000

    override init() {
        super.init()
        browserProxy = DeviceBrowserProxy(owner: self)
        cameraProxy = CameraDelegateProxy(owner: self)
        downloadProxy = DownloadDelegateProxy(owner: self)
        browser = ICDeviceBrowser()
        browser.delegate = browserProxy
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x101)!
        browser.start()
        scheduleBrowserReconcile()
        startDeviceHealthMonitor()
    }

    private func scheduleBrowserReconcile() {
        browserReconcileTask?.cancel()
        browserReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.reconcileExistingDevices()
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func reconcileExistingDevices() {
        let devices = browser.devices ?? []
        let previousCount = browserDeviceCount
        browserDeviceCount = devices.count
        if previousCount != devices.count {
            audit.record("browserSnapshot", [
                "deviceCount": devices.count,
                "devices": devices.compactMap { device in
                    [
                        "name": device.name ?? "",
                        "type": String(describing: type(of: device)),
                        "transport": device.transportType ?? ""
                    ]
                }
            ])
        }
        if let camera {
            if !isCatalogComplete,
               lastSessionOpenAttempt.map({ Date().timeIntervalSince($0) > 3 }) ?? true {
                lastSessionOpenAttempt = Date()
                camera.requestOpenSession()
            }
            return
        }
        if let existingCamera = devices.compactMap({ $0 as? ICCameraDevice }).first {
            attach(existingCamera)
        } else {
            status = "macOS 当前未发现 USB iPhone，正在持续扫描…"
        }
    }

    private func startDeviceHealthMonitor() {
        deviceHealthTask?.cancel()
        deviceHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                guard let self, let camera = self.camera else { continue }
                let devices = self.browser.devices
                let stillPresent = devices?.contains(where: { $0 === camera }) ?? true
                if !stillPresent {
                    self.deviceHealthFailureCount += 1
                } else {
                    self.deviceHealthFailureCount = 0
                }
                if self.deviceHealthFailureCount >= 3 && !self.isCatalogComplete {
                    self.invalidateDeviceState(message: "iPhone 当前不可读取，请解锁并重新信任")
                }
            }
        }
    }

    private func invalidateDeviceState(message: String) {
        audit.record("deviceInvalidated", ["message": message, "previousCount": assets.count])
        camera?.requestCloseSession()
        camera = nil
        lastSessionOpenAttempt = nil
        deviceHealthFailureCount = 0
        isConnected = false
        deviceName = "未连接"
        assets = []
        isCatalogComplete = false
        livePhotoCount = 0
        completeCatalogSignal = false
        catalogRevision += 1
        catalogStabilityTask?.cancel()
        catalogStabilityTask = nil
        emptyCatalogRetryTask?.cancel()
        emptyCatalogRetryTask = nil
        mediaByID = [:]
        mediaOrderIDs = []
        metadataByID = [:]
        metadataDebugRecords = []
        requestedThumbnailIDs = []
        thumbnailQueue = []
        thumbnailQueuedIDs = []
        activeThumbnailIDs = []
        thumbnailCacheCheckedIDs = []
        thumbnailCacheLoadingIDs = []
        thumbnailRetryCounts = [:]
        thumbnailAuditCount = 0
        thumbnailCompletionAuditCount = 0
        thumbnailItems = [:]
        assetsByID = [:]
        clearLivePreviewCache()
        lastError = nil
        status = message
    }

    private func isTransientUnlockError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("please unlock") || message.contains("请解锁")
    }

    func refresh() {
        if let camera {
            lastSessionOpenAttempt = Date()
            status = "正在重新连接 \(deviceName)…"
            camera.requestOpenSession()
            return
        }
        status = "正在搜索 iPhone…"
        reconcileExistingDevices()
    }

    func handleHover(for asset: MediaAsset, hovering: Bool) {
        if hovering, asset.isLivePhoto {
            hoveredLiveAssetID = asset.id
            liveHoverTask?.cancel()
            liveHoverTask = Task { @MainActor [weak self, weak asset] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, let asset,
                      self.hoveredLiveAssetID == asset.id else { return }
                self.prepareLivePreview(for: asset)
            }
        } else if hoveredLiveAssetID == asset.id {
            hoveredLiveAssetID = nil
            liveHoverTask?.cancel()
            if asset.isLivePreviewLoading {
                liveDownloadProgress[asset.id]?.cancel()
                liveDownloadProgress.removeValue(forKey: asset.id)
                asset.isLivePreviewLoading = false
            }
        }
    }

    private func clearLivePreviewCache() {
        liveHoverTask?.cancel()
        liveHoverTask = nil
        liveDownloadProgress.values.forEach { $0.cancel() }
        liveDownloadProgress = [:]
        hoveredLiveAssetID = nil
        if let livePreviewDirectory {
            try? FileManager.default.removeItem(at: livePreviewDirectory)
        }
        livePreviewDirectory = nil
        livePreviewCache = [:]
        assets.forEach {
            $0.livePreviewURL = nil
            $0.isLivePreviewLoading = false
        }
    }

    private func ensureLivePreviewDirectory() throws -> URL {
        if let livePreviewDirectory { return livePreviewDirectory }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("影桥-Live预览-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        livePreviewDirectory = directory
        return directory
    }

    private func prepareLivePreview(for asset: MediaAsset) {
        guard let video = asset.liveVideo, !asset.isLivePreviewLoading else { return }
        if let cached = livePreviewCache[asset.id], FileManager.default.fileExists(atPath: cached.path) {
            asset.livePreviewURL = cached
            return
        }
        do {
            let directory = try ensureLivePreviewDirectory()
            let filename = "\(asset.id)-live.mov"
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: directory as NSURL,
                .saveAsFilename: filename,
                .overwrite: true,
                .truncateAfterSuccessfulDownload: true
            ]
            asset.isLivePreviewLoading = true
            let progress = video.requestDownload(options: options) { [weak self, weak asset] savedFilename, error in
                Task { @MainActor [weak self, weak asset] in
                    guard let self, let asset else { return }
                    self.liveDownloadProgress.removeValue(forKey: asset.id)
                    asset.isLivePreviewLoading = false
                    if let error {
                        print("[影桥] Live 预览下载失败 \(asset.name)：\(error.localizedDescription)")
                        return
                    }
                    let name = savedFilename ?? filename
                    let savedURL: URL
                    if name.hasPrefix("/") {
                        savedURL = URL(fileURLWithPath: name)
                    } else {
                        savedURL = directory.appendingPathComponent(name)
                    }
                    guard FileManager.default.fileExists(atPath: savedURL.path) else { return }
                    self.livePreviewCache[asset.id] = savedURL
                    asset.livePreviewURL = savedURL
                }
            }
            liveDownloadProgress[asset.id] = progress
        } catch {
            print("[影桥] 无法创建 Live 预览缓存：\(error.localizedDescription)")
        }
    }

    private func scheduleCatalogFinalization() {
        catalogStabilityTask?.cancel()
        let revision = catalogRevision
        catalogStabilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var previousFingerprint = self.catalogFingerprint()
            for _ in 0..<self.catalogStabilityRounds {
                do {
                    try await Task.sleep(nanoseconds: self.catalogStabilityDelayNanoseconds)
                } catch {
                    return
                }
                guard self.completeCatalogSignal,
                      self.catalogRevision == revision else { return }
                let currentFingerprint = self.catalogFingerprint()
                guard currentFingerprint == previousFingerprint else { return }
                previousFingerprint = currentFingerprint
            }
            guard self.completeCatalogSignal,
                  self.catalogRevision == revision,
                  self.catalogFingerprint() == previousFingerprint else { return }
            self.isCatalogComplete = true
            self.status = "已读取 \(self.assets.count) 项可导入媒体 · Live \(self.livePhotoCount) 张"
            self.audit.record("catalogReady", [
                "finalCount": self.assets.count,
                "liveCount": self.livePhotoCount,
                "revision": self.catalogRevision,
                "fingerprint": String(self.catalogFingerprint().hashValue)
            ])
        }
    }

    private func scheduleEmptyCatalogRetry(for camera: ICCameraDevice) {
        emptyCatalogRetryTask?.cancel()
        let revision = catalogRevision
        emptyCatalogRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<12 {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard self.camera === camera,
                      self.catalogRevision == revision else { return }
                if (camera.mediaFiles?.count ?? 0) > 0 {
                    self.status = "已发现 iPhone 媒体目录，正在核对完整内容…"
                    self.catalog(camera, isComplete: true)
                    return
                }
                self.status = "iPhone 已解锁，正在等待媒体目录…"
            }
            self.status = "iPhone 已连接但媒体目录仍为空，请保持屏幕亮起并重新插拔数据线"
        }
    }

    private func catalogFingerprint() -> String {
        mediaOrderIDs.joined(separator: "|")
    }

    private func auditStats(_ items: [ICCameraItem]) -> [String: Any] {
        let files = items.compactMap { $0 as? ICCameraFile }
        let images = files.filter(isImageFile)
        let movies = files.filter(isMovieFile)
        return [
            "rawItemCount": items.count,
            "fileCount": files.count,
            "imageCount": images.count,
            "movieCount": movies.count,
            "temporaryCount": files.filter(\.isInTemporaryStore).count,
            "firstNames": files.prefix(10).compactMap(\.name),
            "lastNames": files.suffix(10).compactMap(\.name)
        ]
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择导出目录"
        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
        }
    }

    func selectAll(_ selected: Bool) {
        assets.forEach { $0.isSelected = selected }
    }

    func importSelected() {
        guard !isImporting else { return }
        let selected = assets.filter(\.isSelected)
        guard !selected.isEmpty else {
            lastError = "请先选择要导入的照片。"
            return
        }
        guard isCatalogComplete else {
            lastError = "正在核对完整媒体目录，请等待读取完成后再导入。"
            return
        }
        guard let camera else {
            lastError = "iPhone 尚未连接或尚未解锁。"
            return
        }
        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("手机媒体导入-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            workingDirectory = temp
            importQueue = selected
            importIndex = 0
            isImporting = true
            importProgress = 0
            lastError = nil
            status = exportFormat == .jpg ? "正在导出并转换为 JPG…" : "正在导出原始媒体…"
            camera.requestDownloadFile(importQueue[0].item,
                                       options: [.downloadsDirectoryURL: temp as NSURL,
                                                 .overwrite: true,
                                                 .truncateAfterSuccessfulDownload: true],
                                       downloadDelegate: downloadProxy,
                                       didDownloadSelector: #selector(DownloadDelegateProxy.downloadedFile(_:error:options:contextInfo:)),
                                       contextInfo: nil)
        } catch {
            lastError = "无法创建导入目录：\(error.localizedDescription)"
        }
    }

    private func startNextDownload() {
        guard let camera, importIndex < importQueue.count else {
            finishImport()
            return
        }
        let asset = importQueue[importIndex]
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: (workingDirectory ?? FileManager.default.temporaryDirectory) as NSURL,
            .saveAsFilename: asset.name,
            .overwrite: true,
            .truncateAfterSuccessfulDownload: true
        ]
        camera.requestDownloadFile(asset.item,
                                   options: options,
                                   downloadDelegate: downloadProxy,
                                   didDownloadSelector: #selector(DownloadDelegateProxy.downloadedFile(_:error:options:contextInfo:)),
                                   contextInfo: nil)
    }

    @objc func downloadedFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        if let error {
            lastError = "导入 \(file.name ?? "媒体") 失败：\(error.localizedDescription)"
        } else {
            let fallbackURL = (workingDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent(file.name ?? UUID().uuidString)
            let sourceURL = fallbackURL
            do {
                let ext = sourceURL.pathExtension.lowercased()
                let isVideo = file.uti?.contains("movie") == true || file.uti?.contains("video") == true || ["mov", "mp4", "m4v", "avi", "mts", "m2ts"].contains(ext)
                if exportFormat == .original || isVideo {
                    let target = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
                    try replaceFile(sourceURL, with: target)
                } else {
                    let target = destinationURL.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + ".jpg")
                    try convertToJPEG(sourceURL: sourceURL, targetURL: target, quality: jpgQuality)
                }
            } catch {
                lastError = "转换 \(file.name ?? "媒体") 失败：\(error.localizedDescription)"
            }
        }
        importIndex += 1
        importProgress = Double(importIndex) / Double(max(importQueue.count, 1))
        if importIndex < importQueue.count {
            startNextDownload()
        } else {
            finishImport()
        }
    }

    private func finishImport() {
        isImporting = false
        status = lastError == nil ? "导入完成：\(importQueue.count) 个文件" : "导入完成，但有项目需要检查"
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
        importQueue = []
        importIndex = 0
    }

    private func replaceFile(_ source: URL, with target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
    }

    private func convertToJPEG(sourceURL: URL, targetURL: URL, quality: Double) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(targetURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取图片或创建 JPG 文件"])
        }
        var destinationProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        // Preserve EXIF/TIFF orientation so a portrait source remains portrait after JPG conversion.
        destinationProperties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: appName, code: 2, userInfo: [NSLocalizedDescriptionKey: "JPG 写入失败"])
        }
    }

    private func trailingMediaNumber(_ name: String?) -> Int? {
        let stem = ((name ?? "") as NSString).deletingPathExtension
        let digits = String(stem.reversed().prefix(while: { $0.isNumber }).reversed())
        return digits.isEmpty ? nil : Int(digits)
    }

    private func attach(_ camera: ICCameraDevice) {
        guard self.camera !== camera else { return }
        self.camera = camera
        deviceHealthFailureCount = 0
        isAccessRestricted = false
        isCatalogComplete = false
        completeCatalogSignal = false
        catalogRevision += 1
        catalogStabilityTask?.cancel()
        catalogStabilityTask = nil
        camera.delegate = cameraProxy
        deviceName = camera.name ?? camera.productKind ?? "iPhone"
        isConnected = true
        audit.record("deviceAttached", [
            "deviceName": deviceName,
            "productKind": camera.productKind ?? "",
            "transportType": camera.transportType ?? "",
            "iCloudPhotosEnabled": camera.iCloudPhotosEnabled,
            "locked": camera.isLocked,
            "accessRestricted": camera.isAccessRestrictedAppleDevice,
            "presentation": "originalAssets"
        ])
        status = "已发现 \(deviceName)，正在读取媒体…"
        if #available(macOS 10.11, *) {
            camera.mediaPresentation = .originalAssets
        }
        lastSessionOpenAttempt = Date()
        camera.requestOpenSession()
    }

    private func mediaIdentifier(_ item: ICCameraItem) -> String {
        "\(item.ptpObjectHandle)-\(item.name ?? "")"
    }

    private func isMediaItem(_ item: ICCameraItem) -> Bool {
        let uti = item.uti ?? ""
        if let type = UTType(uti) {
            if type.conforms(to: .image) || type.conforms(to: .movie) { return true }
        }
        let ext = ((item.name ?? "") as NSString).pathExtension.lowercased()
        let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "gif", "webp", "avif", "dng", "raw", "arw", "cr2", "cr3", "nef"]
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "3gp", "mxf"]
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    private func isImageFile(_ file: ICCameraFile) -> Bool {
        if let type = UTType(file.uti ?? ""), type.conforms(to: .image) { return true }
        return ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "gif", "webp", "avif"].contains(
            ((file.name ?? "") as NSString).pathExtension.lowercased()
        )
    }

    private func isMovieFile(_ file: ICCameraFile) -> Bool {
        if let type = UTType(file.uti ?? ""), type.conforms(to: .movie) { return true }
        return ["mov", "mp4", "m4v"].contains(((file.name ?? "") as NSString).pathExtension.lowercased())
    }

    private func livePhotoStem(_ file: ICCameraFile) -> String {
        let stem = (((file.name ?? "") as NSString).deletingPathExtension).uppercased()
        if stem.hasPrefix("IMG_E") { return "IMG_" + String(stem.dropFirst(5)) }
        return stem
    }

    private func livePhotoPairings(in items: [ICCameraFile]) -> [String: ICCameraFile] {
        let images = items.filter(isImageFile)
        let movies = items.filter(isMovieFile)
        var byRelated: [String: [ICCameraFile]] = [:]
        var byGroup: [String: [ICCameraFile]] = [:]
        var byStem: [String: [ICCameraFile]] = [:]
        for movie in movies {
            if let related = movie.relatedUUID, !related.isEmpty { byRelated[related, default: []].append(movie) }
            if let group = movie.groupUUID, !group.isEmpty { byGroup[group, default: []].append(movie) }
            byStem[livePhotoStem(movie), default: []].append(movie)
        }

        var usedMovieIDs: Set<String> = []

        func choose(_ candidates: [ICCameraFile], for image: ICCameraFile) -> ICCameraFile? {
            let exactStem = (((image.name ?? "") as NSString).deletingPathExtension).uppercased()
            let available = candidates.filter { !usedMovieIDs.contains(mediaIdentifier($0)) }
            return available.first(where: {
                (((($0.name ?? "") as NSString).deletingPathExtension).uppercased() == exactStem)
            }) ?? available.first
        }

        func closestShortMovie(to image: ICCameraFile) -> ICCameraFile? {
            guard let imageDate = image.creationDate else { return nil }
            let candidates = movies.filter { movie in
                let id = mediaIdentifier(movie)
                guard !usedMovieIDs.contains(id),
                      (movie.duration == 0 || movie.duration <= 8),
                      let movieDate = movie.creationDate else { return false }
                return abs(movieDate.timeIntervalSince(imageDate)) <= 5
            }
            return candidates.min {
                guard let left = $0.creationDate, let right = $1.creationDate else { return false }
                return abs(left.timeIntervalSince(imageDate)) < abs(right.timeIntervalSince(imageDate))
            }
        }

        var pairings: [String: ICCameraFile] = [:]
        for image in images {
            if let sidecarMovie = image.sidecarFiles?.compactMap({ $0 as? ICCameraFile }).first(where: isMovieFile) {
                pairings[mediaIdentifier(image)] = sidecarMovie
                usedMovieIDs.insert(mediaIdentifier(sidecarMovie))
                continue
            }
            var candidates: [ICCameraFile] = []
            if let related = image.relatedUUID, !related.isEmpty { candidates = byRelated[related] ?? [] }
            if candidates.isEmpty, let group = image.groupUUID, !group.isEmpty { candidates = byGroup[group] ?? [] }
            if candidates.isEmpty {
                let exactStem = (((image.name ?? "") as NSString).deletingPathExtension).uppercased()
                candidates = movies.filter {
                    (((($0.name ?? "") as NSString).deletingPathExtension).uppercased() == exactStem)
                }
            }
            if candidates.isEmpty { candidates = byStem[livePhotoStem(image)] ?? [] }
            let movie = choose(candidates, for: image) ?? closestShortMovie(to: image)
            if let movie {
                pairings[mediaIdentifier(image)] = movie
                usedMovieIDs.insert(mediaIdentifier(movie))
            }
        }
        return pairings
    }

    private func writeLivePairingDebug(items: [ICCameraFile], pairings: [String: ICCameraFile]) {
        let records: [[String: Any]] = items.map { file in
            var record: [String: Any] = [
                "id": mediaIdentifier(file),
                "name": file.name ?? "",
                "uti": file.uti ?? "",
                "isImage": isImageFile(file),
                "isMovie": isMovieFile(file),
                "relatedUUID": file.relatedUUID ?? "",
                "groupUUID": file.groupUUID ?? "",
                "originatingAssetID": file.originatingAssetID ?? "",
                "creationDate": file.creationDate?.timeIntervalSince1970 ?? NSNull(),
                "duration": file.duration
            ]
            if let metadata = file.metadata {
                record["metadata"] = jsonSafeMetadata(metadata)
            }
            record["sidecarFiles"] = file.sidecarFiles?.compactMap(\.name) ?? []
            return record
        }
        let pairRecords: [[String: String]] = pairings.compactMap { imageID, movie in
            guard let image = items.first(where: { mediaIdentifier($0) == imageID }) else { return nil }
            return ["image": image.name ?? "", "movie": movie.name ?? ""]
        }
        let payload: [String: Any] = [
            "itemCount": items.count,
            "imageCount": items.filter(isImageFile).count,
            "movieCount": items.filter(isMovieFile).count,
            "pairCount": pairings.count,
            "pairs": pairRecords,
            "items": records
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        let url = URL(fileURLWithPath: "/tmp/yingqiao-live-debug.json")
        try? data.write(to: url, options: .atomic)
    }

    private func jsonSafeMetadata(_ value: Any) -> Any {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value }
        if let value = value as? [Any] { return value.map(jsonSafeMetadata) }
        if let value = value as? [AnyHashable: Any] {
            return value.reduce(into: [String: Any]()) { result, entry in
                result[String(describing: entry.key)] = jsonSafeMetadata(entry.value)
            }
        }
        return String(describing: value)
    }

    private func writeMetadataDebug() {
        guard !metadataDebugRecords.isEmpty else { return }
        let payload: [String: Any] = [
            "recordCount": metadataDebugRecords.count,
            "records": metadataDebugRecords
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/yingqiao-metadata-debug.json"), options: .atomic)
    }

    private func mergeMediaItems(_ items: [ICCameraItem], from camera: ICCameraDevice, isComplete: Bool = false) {
        let candidates = items.compactMap { $0 as? ICCameraFile }.filter { !$0.isInTemporaryStore && isMediaItem($0) }
        let snapshotIDs = candidates.map(mediaIdentifier)
        catalogRevision += 1
        isCatalogComplete = false
        var stats = auditStats(items)
        stats["phase"] = isComplete ? "completeCallback" : "incremental"
        stats["catalogProgress"] = camera.contentCatalogPercentCompleted
        stats["deviceName"] = camera.name ?? ""
        stats["previousMergedCount"] = mediaByID.count
        stats["sessionRevision"] = catalogRevision
        audit.record("catalogMerge", stats)
        for file in candidates {
            let id = mediaIdentifier(file)
            if mediaByID[id] == nil { mediaOrderIDs.append(id) }
            mediaByID[id] = file
        }
        if isComplete {
            // The complete ImageCaptureCore catalog is authoritative. Drop stale items
            // that appeared in earlier partial snapshots instead of unioning snapshots.
            mediaByID = Dictionary(uniqueKeysWithValues: candidates.map { (mediaIdentifier($0), $0) })
            mediaOrderIDs = snapshotIDs
            completeCatalogSignal = true
        }
        rebuildAssets(from: camera, isComplete: isComplete)
        audit.record("catalogMerged", [
            "isCompleteSignal": isComplete,
            "mergedCount": mediaByID.count,
            "orderedCount": mediaOrderIDs.count,
            "imageCount": assets.filter { !$0.isVideo }.count,
            "videoCount": assets.filter(\.isVideo).count,
            "livePairCount": livePhotoCount,
            "fingerprint": String(catalogFingerprint().hashValue)
        ])
        if completeCatalogSignal {
            scheduleCatalogFinalization()
        }
    }

    private func catalog(_ camera: ICCameraDevice, isComplete: Bool = false) {
        // mediaFiles may be a partial snapshot while ImageCaptureCore is still cataloguing.
        // Merge snapshots and didAdd batches instead of replacing the current list.
        mergeMediaItems(camera.mediaFiles ?? [], from: camera, isComplete: isComplete)
    }

    private func rebuildAssets(from camera: ICCameraDevice, isComplete: Bool) {
        let previous = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let items = mediaOrderIDs.compactMap { mediaByID[$0] }
        let orderedItems = items.enumerated().sorted { lhs, rhs in
            switch (lhs.element.creationDate, rhs.element.creationDate) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftNumber = trailingMediaNumber(lhs.element.name)
                let rightNumber = trailingMediaNumber(rhs.element.name)
                switch (leftNumber, rightNumber) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }
        }.map(\.element)
        let livePairings = livePhotoPairings(in: orderedItems)
        livePhotoCount = livePairings.count
        if isComplete {
            print("[影桥] Live Photo 配对：\(livePairings.count) 张")
            writeLivePairingDebug(items: orderedItems, pairings: livePairings)
        }
        assets = orderedItems.map { item in
            let id = mediaIdentifier(item)
            let asset = previous[id] ?? MediaAsset(item: item)
            asset.liveVideo = livePairings[id]
            return asset
        }
        assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        thumbnailItems = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.item as ICCameraItem) })
        let progress = camera.contentCatalogPercentCompleted
        // `contentCatalogPercentCompleted == 100` only means the progress
        // counter reached its upper bound. ImageCaptureCore delivers the
        // authoritative snapshot separately through
        // `deviceDidBecomeReady(withCompleteContentCatalog:)`. During the
        // gap between those callbacks, `mediaFiles` can still be a partial
        // catalog and may temporarily contain a different count (for
        // example, the 5,205 value seen in an earlier session before the
        // current complete catalog reached 9,761 items. Never label that
        // provisional count as fully read.
        if isCatalogComplete {
            status = "已读取 \(assets.count) 项可导入媒体"
        } else if progress >= 100 {
            status = "正在核对完整目录… 已发现 \(assets.count) 项"
        } else {
            status = "正在读取媒体… \(progress)% · 已发现 \(assets.count) 项"
        }
        // Thumbnail requests are demand-driven by the visible grid/list cells.
        // Do not enqueue thousands of device requests during catalog rebuild.
    }

    func requestThumbnails(around index: Int) {
        // Start with the currently visible portion even while the catalog is
        // still being verified. Final catalog reconciliation preserves assets
        // by stable ID, so completed thumbnails survive that replacement.
        guard isConnected, !isAccessRestricted, !assets.isEmpty else { return }
        if thumbnailAuditCount < 200 {
            thumbnailAuditCount += 1
            audit.record("thumbnailViewportRequested", [
                "index": index,
                "assetCount": assets.count,
                "catalogComplete": isCatalogComplete
            ])
        }
        let lower = max(0, index - thumbnailPrefetchRadius)
        let upper = min(assets.count - 1, index + thumbnailPrefetchRadius)
        var prioritizedIDs: [String] = []
        let visibleIndices = Array(lower...upper).sorted {
            let leftIsVideo = assets[$0].isVideo
            let rightIsVideo = assets[$1].isVideo
            if leftIsVideo != rightIsVideo { return !leftIsVideo }
            return abs($0 - index) < abs($1 - index)
        }
        for offset in visibleIndices {
            let item = assets[offset]
            guard item.thumbnail == nil,
                  !requestedThumbnailIDs.contains(item.id),
                  !activeThumbnailIDs.contains(item.id) else { continue }
            if !thumbnailCacheCheckedIDs.contains(item.id) {
                if !thumbnailCacheLoadingIDs.contains(item.id) {
                    thumbnailCacheLoadingIDs.insert(item.id)
                    let id = item.id
                    Task.detached(priority: .userInitiated) { [weak self] in
                        let cached = ThumbnailDiskCache.shared.loadImage(for: id)
                        await MainActor.run {
                            guard let self else { return }
                            self.thumbnailCacheLoadingIDs.remove(id)
                            self.thumbnailCacheCheckedIDs.insert(id)
                            guard let current = self.assetsByID[id], current.thumbnail == nil else {
                                self.pumpThumbnailRequests()
                                return
                            }
                            if let cached {
                                current.thumbnail = cached
                                self.requestedThumbnailIDs.insert(id)
                            } else if !self.thumbnailQueuedIDs.contains(id) {
                                self.thumbnailQueue.append(id)
                                self.thumbnailQueuedIDs.insert(id)
                            }
                            self.pumpThumbnailRequests()
                        }
                    }
                }
                continue
            }
            prioritizedIDs.append(item.id)
        }
        if !prioritizedIDs.isEmpty {
            let prioritizedSet = Set(prioritizedIDs)
            let oldQueue = thumbnailQueue
            let retainedQueue = oldQueue.filter { !prioritizedSet.contains($0) }.prefix(thumbnailQueueLimit)
            let retainedSet = Set(retainedQueue)
            let droppedIDs = oldQueue.filter { !prioritizedSet.contains($0) && !retainedSet.contains($0) }
            droppedIDs.forEach {
                requestedThumbnailIDs.remove($0)
                thumbnailQueuedIDs.remove($0)
            }
            thumbnailQueue = prioritizedIDs + retainedQueue
            thumbnailQueuedIDs = Set(thumbnailQueue)
        }
        pumpThumbnailRequests()
    }

    private func pumpThumbnailRequests() {
        while activeThumbnailIDs.count < maxConcurrentThumbnails, !thumbnailQueue.isEmpty {
            let id = thumbnailQueue.removeFirst()
            thumbnailQueuedIDs.remove(id)
            guard let asset = assetsByID[id], asset.thumbnail == nil else { continue }
            requestedThumbnailIDs.insert(id)
            activeThumbnailIDs.insert(id)
            if thumbnailAuditCount < 200 {
                thumbnailAuditCount += 1
                audit.record("thumbnailRequestStarted", ["id": id, "name": asset.name])
            }
            // Ask for the embedded thumbnail without forcing ImageCaptureCore
            // to generate a new rendition on the iPhone.
            asset.item.requestThumbnailData(options: [.imageSourceShouldCache: true]) { [weak self] data, error in
                let decodedImage = data.flatMap { NSImage(data: $0) }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeThumbnailIDs.contains(id) else { return }
                    if let decodedImage {
                        self.finishThumbnail(id: id, image: decodedImage)
                        if let data {
                            ThumbnailDiskCache.shared.store(data: data, for: id)
                        }
                    } else {
                        self.activeThumbnailIDs.remove(id)
                        self.handleThumbnailFailure(id: id, error: error)
                        self.pumpThumbnailRequests()
                    }
                }
            }
        }
    }

    private func finishThumbnail(id: String, image: CGImage) {
        if thumbnailCompletionAuditCount < 100 {
            thumbnailCompletionAuditCount += 1
            audit.record("thumbnailCompleted", ["id": id, "kind": "cgImage"])
        }
        guard let asset = assetsByID[id], asset.thumbnail == nil else {
            activeThumbnailIDs.remove(id)
            pumpThumbnailRequests()
            return
        }
        activeThumbnailIDs.remove(id)
        asset.thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnailRetryCounts.removeValue(forKey: id)
        ThumbnailDiskCache.shared.store(cgImage: image, for: id)
        pumpThumbnailRequests()
    }

    private func finishThumbnail(id: String, image: NSImage) {
        if thumbnailCompletionAuditCount < 100 {
            thumbnailCompletionAuditCount += 1
            audit.record("thumbnailCompleted", ["id": id, "kind": "nsImage"])
        }
        guard let asset = assetsByID[id], asset.thumbnail == nil else {
            activeThumbnailIDs.remove(id)
            pumpThumbnailRequests()
            return
        }
        activeThumbnailIDs.remove(id)
        asset.thumbnail = image
        thumbnailRetryCounts.removeValue(forKey: id)
        pumpThumbnailRequests()
    }

    private func handleThumbnailFailure(id: String, error: Error?) {
        let attempt = thumbnailRetryCounts[id, default: 0]
        if attempt < thumbnailRetryLimit {
            thumbnailRetryCounts[id] = attempt + 1
            requestedThumbnailIDs.remove(id)
            let delay = 1.5 * Double(attempt + 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isConnected,
                      let asset = self.assetsByID[id],
                      asset.thumbnail == nil,
                      !self.activeThumbnailIDs.contains(id),
                      !self.thumbnailQueuedIDs.contains(id) else { return }
                self.thumbnailQueue.append(id)
                self.thumbnailQueuedIDs.insert(id)
                self.pumpThumbnailRequests()
            }
        } else {
            let detail = error.map { ": \($0.localizedDescription)" } ?? ""
            print("[影桥] 缩略图不可用 \(id)\(detail)")
            status = "已读取 \(assets.count) 项可导入媒体 · 部分缩略图暂不可用"
        }
    }

    // MARK: Main-actor callback entry points
    func browserDidAdd(_ device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        attach(camera)
    }

    func browserDidRemove(_ device: ICDevice, moreGoing: Bool) {
        guard device === camera else { return }
        if isCatalogComplete {
            audit.record("deviceTemporarilyDisconnected", ["preservedCount": assets.count, "liveCount": livePhotoCount])
            camera = nil
            lastSessionOpenAttempt = nil
            isConnected = false
            status = "iPhone 连接暂时中断，已保留 \(assets.count) 项媒体"
            return
        }
        invalidateDeviceState(message: "iPhone 已断开，请重新连接并解锁")
    }

    func deviceDidOpen(_ device: ICDevice, error: Error?) {
        self.device(device, didOpenSessionWithError: error)
    }

    func deviceDidClose(_ device: ICDevice, error: Error?) {
        self.device(device, didCloseSessionWithError: error)
    }

    func deviceWasRemoved(_ device: ICDevice) {
        didRemove(device)
    }

    func deviceBecameReady(_ device: ICDevice) {
        deviceDidBecomeReady(device)
    }

    func deviceReceivedStatus(_ device: ICDevice, status: [ICDeviceStatus : Any]) {
        self.device(device, didReceiveStatusInformation: status)
    }

    func deviceEncounteredError(_ device: ICDevice, error: Error?) {
        self.device(device, didEncounterError: error)
    }

    func deviceWasEjected(_ device: ICDevice, error: Error?) {
        self.device(device, didEjectWithError: error)
    }

    func cameraDidAdd(_ camera: ICCameraDevice, items: [ICCameraItem]) {
        cameraDevice(camera, didAdd: items)
    }

    func cameraDidRemove(_ camera: ICCameraDevice, items: [ICCameraItem]) {
        cameraDevice(camera, didRemove: items)
    }

    func cameraReceivedThumbnail(_ camera: ICCameraDevice, thumbnail: CGImage?, item: ICCameraItem, error: Error?) {
        cameraDevice(camera, didReceiveThumbnail: thumbnail, for: item, error: error)
    }

    func cameraReceivedMetadata(_ camera: ICCameraDevice, metadata: [AnyHashable : Any]?, item: ICCameraItem, error: Error?) {
        cameraDevice(camera, didReceiveMetadata: metadata, for: item, error: error)
    }

    func cameraDidRename(_ camera: ICCameraDevice, items: [ICCameraItem]) {
        cameraDevice(camera, didRenameItems: items)
    }

    func cameraCapabilityChanged(_ camera: ICCameraDevice) {
        cameraDeviceDidChangeCapability(camera)
    }

    func cameraReceivedPTPEvent(_ camera: ICCameraDevice, eventData: Data) {
        cameraDevice(camera, didReceivePTPEvent: eventData)
    }

    func cameraBecameReadyWithCompleteCatalog(_ camera: ICCameraDevice) {
        deviceDidBecomeReady(withCompleteContentCatalog: camera)
    }

    func cameraDidRemoveAccessRestriction(_ device: ICDevice) {
        cameraDeviceDidRemoveAccessRestriction(device)
    }

    func cameraDidEnableAccessRestriction(_ device: ICDevice) {
        cameraDeviceDidEnableAccessRestriction(device)
    }

    // MARK: ICDeviceBrowserDelegate
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        if camera.productKind != nil || camera.transportType != nil {
            attach(camera)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard device === camera else { return }
        invalidateDeviceState(message: "iPhone 已断开，请重新连接并解锁")
    }

    // MARK: ICDeviceDelegate
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            audit.record("openSessionError", ["message": error.localizedDescription])
            if isTransientUnlockError(error) {
                status = "正在等待 iPhone 解锁确认…"
            } else {
                status = "无法打开 iPhone：\(error.localizedDescription)"
                lastError = status
            }
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) {}
    func deviceDidBecomeReady(_ device: ICDevice) {
        if let camera = device as? ICCameraDevice { catalog(camera) }
    }
    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {}
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        if let error {
            audit.record("deviceError", ["message": error.localizedDescription])
            if isTransientUnlockError(error) {
                status = "正在等待 iPhone 解锁确认…"
            } else {
                lastError = error.localizedDescription
            }
        }
    }
    func device(_ device: ICDevice, didEjectWithError error: Error?) {}

    // MARK: ICCameraDeviceDelegate
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        audit.record("didAddBatch", ["count": items.count, "names": items.compactMap(\.name).prefix(20)])
        mergeMediaItems(items, from: camera)
    }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        audit.record("didRemoveBatch", ["count": items.count, "names": items.compactMap(\.name).prefix(20)])
        catalogRevision += 1
        isCatalogComplete = false
        for item in items {
            let id = mediaIdentifier(item)
            mediaByID.removeValue(forKey: id)
            mediaOrderIDs.removeAll { $0 == id }
            requestedThumbnailIDs.remove(id)
            thumbnailQueuedIDs.remove(id)
        }
        rebuildAssets(from: camera, isComplete: isCatalogComplete)
        if completeCatalogSignal { scheduleCatalogFinalization() }
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        let id = mediaIdentifier(item)
        if let thumbnail, let asset = assetsByID[id] {
            if asset.thumbnail == nil {
                finishThumbnail(id: id, image: thumbnail)
            } else {
                activeThumbnailIDs.remove(id)
                pumpThumbnailRequests()
            }
        } else {
            activeThumbnailIDs.remove(id)
            handleThumbnailFailure(id: id, error: error)
            pumpThumbnailRequests()
        }
    }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: Error?) {
        guard let metadata else { return }
        let id = mediaIdentifier(item)
        let safeMetadata = jsonSafeMetadata(metadata)
        guard let dictionary = safeMetadata as? [String: Any] else { return }
        metadataByID[id] = dictionary
        if metadataDebugRecords.count < 500 {
            metadataDebugRecords.append([
                "id": id,
                "name": item.name ?? "",
                "metadata": dictionary
            ])
        }
    }
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        lastError = nil
        audit.record("completeCatalogCallback", [
            "deviceName": device.name ?? "",
            "progress": device.contentCatalogPercentCompleted,
            "mediaFilesCount": device.mediaFiles?.count ?? 0
        ])
        guard (device.mediaFiles?.count ?? 0) > 0 else {
            audit.record("catalogEmptyDueToCompetingClient", ["deviceName": device.name ?? ""])
            completeCatalogSignal = false
            isCatalogComplete = false
            status = "iPhone 已连接，但其他照片应用可能正在占用设备，请关闭照片或 Lightroom 后点刷新"
            scheduleEmptyCatalogRetry(for: device)
            return
        }
        catalog(device, isComplete: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.writeMetadataDebug()
        }
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        lastError = nil
        isAccessRestricted = false
        audit.record("accessRestrictionRemoved")
        completeCatalogSignal = false
        isCatalogComplete = false
        catalogRevision += 1
        catalogStabilityTask?.cancel()
        catalogStabilityTask = nil
        if let camera = device as? ICCameraDevice { catalog(camera) }
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        isAccessRestricted = true
        audit.record("accessRestrictionEnabled")
        status = "iPhone 已锁定，请解锁后自动继续"
        isCatalogComplete = false
        completeCatalogSignal = false
        catalogStabilityTask?.cancel()
        catalogStabilityTask = nil
        requestedThumbnailIDs = []
        thumbnailQueue = []
        thumbnailQueuedIDs = []
        activeThumbnailIDs = []
        thumbnailCacheCheckedIDs = []
        thumbnailCacheLoadingIDs = []
        thumbnailRetryCounts = [:]
        thumbnailAuditCount = 0
        thumbnailCompletionAuditCount = 0
        thumbnailItems = [:]
    }
    func cameraDevice(_ camera: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool { false }
    func cameraDevice(_ camera: ICCameraDevice, shouldGetMetadataOf item: ICCameraItem) -> Bool { false }

    // MARK: ICCameraDeviceDownloadDelegate
    func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String : Any], contextInfo: UnsafeMutableRawPointer?) {
        downloadedFile(file, error: error, options: options, contextInfo: contextInfo)
    }
    func didReceiveDownloadProgress(for file: ICCameraFile, downloadedBytes: Int64, maxBytes: Int64) {}
}

struct ContentView: View {
    @StateObject private var model = ImporterModel()
    @StateObject private var photoLibrary = PhotoLibraryModel()
    @State private var sourceMode: SourceMode = .usb
    @State private var listView = false
    @State private var thumbnailSize: Double = 112

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                if sourceMode == .photosLibrary {
                    if !photoLibrary.isReady || photoLibrary.assets.isEmpty {
                        photoEmptyState
                    } else {
                        photoMediaContent
                    }
                } else if model.assets.isEmpty {
                    emptyState
                } else {
                    usbMediaContent
                }
                Divider()
                footer
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("导入提示", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("知道了", role: .cancel) { model.lastError = nil }
        } message: { Text(model.lastError ?? "") }
        .onChange(of: model.isConnected) { _, connected in
            if connected { sourceMode = .usb }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来源")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            Picker("来源", selection: $sourceMode) {
                ForEach(SourceMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode == .photosLibrary ? "photo.on.rectangle" : "iphone.gen3")
                        .tag(mode)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 10)
            Text("设备")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            Button {
                if sourceMode == .photosLibrary { photoLibrary.load() } else { model.refresh() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "iphone.gen3")
                        .font(.title3)
                        .foregroundStyle(sourceMode == .usb && model.isConnected ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceMode == .usb && model.isConnected ? model.deviceName : "USB 设备")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(sourceMode == .usb && model.isConnected ? "已连接" : "仅显示当前可读取媒体")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(sourceMode == .usb && model.isConnected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            Spacer()
        }
        .padding(.top, 18)
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("影桥").font(.title2.weight(.semibold))
                Text(sourceMode == .photosLibrary
                     ? photoLibrary.status
                     : (model.isCatalogComplete
                        ? "\(model.assets.count) 项 · USB 当前可读取媒体 · Live \(model.livePhotoCount) 张"
                        : (!model.isConnected
                           ? "等待 iPhone 连接并解锁"
                           : "正在读取 USB… 已发现 \(model.assets.count) 项，正在核对完整目录")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("来源", selection: $sourceMode) {
                ForEach(SourceMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            Picker("视图", selection: $listView) {
                Image(systemName: "list.bullet").tag(true)
                Image(systemName: "square.grid.2x2").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 78)
            Button {
                if sourceMode == .photosLibrary { photoLibrary.load() } else { model.refresh() }
            } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .help("重新扫描")
            Slider(value: $thumbnailSize, in: 88...160)
                .frame(width: 115)
                .help("缩略图大小")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.isConnected ? "photo.on.rectangle.angled" : "iphone.gen3")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(model.isConnected ? "正在读取媒体…" : "请连接并解锁 iPhone")
                .font(.title3.weight(.medium))
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var photoEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: photoLibrary.isReady ? "photo.on.rectangle.angled" : "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(photoLibrary.isReady ? "照片图库为空" : "正在读取照片图库")
                .font(.title3.weight(.medium))
            Text(photoLibrary.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !photoLibrary.isReady {
                Button("重新请求照片权限") { photoLibrary.load() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var usbMediaContent: some View {
        ScrollView {
            if listView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.assets.enumerated()), id: \.element.id) { index, asset in
                        MediaListRow(asset: asset)
                            .onAppear { model.requestThumbnails(around: index) }
                    }
                }
                .padding(12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize), spacing: 10)], spacing: 10) {
                    ForEach(Array(model.assets.enumerated()), id: \.element.id) { index, asset in
                        AssetCard(asset: asset, size: thumbnailSize)
                            { hovering in model.handleHover(for: asset, hovering: hovering) }
                            .onAppear { model.requestThumbnails(around: index) }
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var photoMediaContent: some View {
        ScrollView {
            if listView {
                LazyVStack(spacing: 2) {
                    ForEach(photoLibrary.assets) { item in
                        PhotoAssetListRow(item: item, library: photoLibrary)
                    }
                }
                .padding(12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize), spacing: 10)], spacing: 10) {
                    ForEach(photoLibrary.assets) { item in
                        PhotoAssetCard(item: item, library: photoLibrary, size: thumbnailSize)
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(sourceMode == .photosLibrary
                 ? (photoLibrary.assets.isEmpty ? photoLibrary.status : "已选择 \(photoLibrary.assets.filter(\.isSelected).count) 项 · \(photoLibrary.assets.count) 项照片图库媒体")
                 : (model.assets.isEmpty ? model.status : model.selectionSummary))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if sourceMode == .photosLibrary && !photoLibrary.assets.isEmpty {
                Button("全选") { photoLibrary.assets.forEach { $0.isSelected = true } }
                Button("取消全选") { photoLibrary.assets.forEach { $0.isSelected = false } }
                Text("照片图库模式支持完整浏览与 Live Photo 悬停播放")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else if !model.assets.isEmpty {
                Button("全选") { model.selectAll(true) }
                    .disabled(!model.isCatalogComplete)
                Button("取消全选") { model.selectAll(false) }
                    .disabled(!model.isCatalogComplete)
            }
            if sourceMode == .usb {
            Picker("导出格式", selection: $model.exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.menu)
            if model.exportFormat == .jpg {
                Text("JPG 质量 100%")
                    .foregroundStyle(.secondary)
            }
            Button { model.chooseDestination() } label: {
                Label("导出到…", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .help("选择导出目录：\(model.destinationURL.path)")
            Button { model.importSelected() } label: {
                Label(model.isImporting ? "导出中…" : "开始导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isImporting || !model.isCatalogComplete || !model.assets.contains(where: { $0.isSelected }))
            if model.isImporting {
                ProgressView(value: model.importProgress).frame(width: 110)
            }
            }
        }
        .padding(12)
    }
}

struct PhotoLivePreviewView: NSViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.contentMode = .aspectFill
        view.livePhoto = livePhoto
        DispatchQueue.main.async { view.startPlayback(with: .full) }
        return view
    }

    func updateNSView(_ nsView: PHLivePhotoView, context: Context) {
        nsView.livePhoto = livePhoto
        nsView.startPlayback(with: .full)
    }

    static func dismantleNSView(_ nsView: PHLivePhotoView, coordinator: ()) {
        nsView.stopPlayback()
        nsView.livePhoto = nil
    }
}

struct PhotoAssetCard: View {
    @ObservedObject var item: PhotoLibraryAsset
    @ObservedObject var library: PhotoLibraryModel
    let size: Double
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { item.isSelected.toggle() } label: {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        if isHovering, let livePhoto = item.livePhoto {
                            PhotoLivePreviewView(livePhoto: livePhoto)
                        } else if let image = item.thumbnail {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.12)
                                .overlay(Image(systemName: item.isLive ? "livephoto" : "photo").foregroundStyle(.secondary))
                        }
                        if item.isLive && isHovering && item.livePhoto == nil && item.isLiveLoading {
                            ProgressView().controlSize(.small)
                                .padding(7)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                    }
                    .frame(width: size, height: size)
                    .clipped()
                    if item.isLive {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.68), in: Capsule())
                            .padding(7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(item.isSelected ? .white : .white.opacity(0.9), item.isSelected ? .blue : .black.opacity(0.35))
                        .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(item.isSelected ? Color.accentColor : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            Text(item.asset.creationDate?.formatted(date: .numeric, time: .omitted) ?? "照片")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(width: size, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear { library.requestThumbnail(for: item) }
        .onHover { hovering in
            isHovering = hovering
            if hovering && item.isLive { library.requestLivePhoto(for: item) }
        }
    }
}

struct PhotoAssetListRow: View {
    @ObservedObject var item: PhotoLibraryAsset
    @ObservedObject var library: PhotoLibraryModel

    var body: some View {
        Button { item.isSelected.toggle() } label: {
            HStack(spacing: 10) {
                Group {
                    if let image = item.thumbnail {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                }
                .frame(width: 58, height: 58)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(item.asset.creationDate?.formatted(date: .numeric, time: .standard) ?? "照片")
                if item.isLive { Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isSelected ? .blue : .secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { library.requestThumbnail(for: item) }
    }
}

struct LivePreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LivePreviewNSView {
        let view = LivePreviewNSView()
        view.play(url: url)
        return view
    }

    func updateNSView(_ nsView: LivePreviewNSView, context: Context) {
        nsView.play(url: url)
    }

    static func dismantleNSView(_ nsView: LivePreviewNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class LivePreviewNSView: NSView {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }

    func play(url: URL) {
        guard currentURL != url else {
            player?.play()
            return
        }
        stop()
        currentURL = url
        let queue = AVQueuePlayer()
        queue.isMuted = true
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: queue, templateItem: item)
        let playerLayer = AVPlayerLayer(player: queue)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
        player = queue
        queue.play()
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
        currentURL = nil
        layer?.sublayers?.removeAll()
    }
}

struct AssetCard: View {
    @ObservedObject var asset: MediaAsset
    let size: Double
    let onHover: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { asset.isSelected.toggle() } label: {
                ZStack(alignment: .topTrailing) {
                    preview
                        .frame(width: size, height: size)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Image(systemName: asset.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(asset.isSelected ? .white : .white.opacity(0.9), asset.isSelected ? .blue : .black.opacity(0.35))
                        .padding(6)
                    if asset.isLivePhoto {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.68), in: Capsule())
                            .padding(7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(asset.isSelected ? Color.accentColor : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            Text(asset.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(width: size, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .onHover { hovering in
            isHovering = hovering
            onHover(hovering)
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            if isHovering, let url = asset.livePreviewURL {
                LivePreviewView(url: url)
            } else if let image = asset.thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.12)
                    .overlay(Image(systemName: asset.isVideo ? "video" : "photo").foregroundStyle(.secondary))
            }
            if isHovering && asset.isLivePreviewLoading {
                ProgressView().controlSize(.small)
                    .padding(7)
                    .background(.black.opacity(0.55), in: Circle())
            }
        }
    }
}

struct MediaListRow: View {
    @ObservedObject var asset: MediaAsset

    var body: some View {
        Button { asset.isSelected.toggle() } label: {
            HStack(spacing: 10) {
                Group {
                    if let image = asset.thumbnail {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.12)
                    }
                }
                .frame(width: 58, height: 58)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(asset.name).font(.callout)
                Spacer()
                Image(systemName: asset.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(asset.isSelected ? .blue : .secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@main
struct PhoneMediaImporterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于影桥") {}
            }
        }
    }
}
