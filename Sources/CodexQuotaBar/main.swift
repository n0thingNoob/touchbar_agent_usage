import AppKit
import Foundation
import TouchBarPrivateSupport

private let codexBinaryPath = "/Applications/Codex.app/Contents/Resources/codex"
private let codexTemplateIconPath = "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png"
private let automaticRefreshInterval: TimeInterval = 5 * 60
private let taskStatusRefreshInterval: TimeInterval = 2

struct RateLimit: Equatable {
    enum Kind: String {
        case fiveHour
        case weekly
    }

    let kind: Kind
    let usedPercent: Double
    let resetAt: Date?
    let resetDescription: String?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct RateLimitSnapshot: Equatable {
    let fiveHour: RateLimit?
    let weekly: RateLimit?
    let fetchedAt: Date
}

struct TaskActivitySnapshot: Equatable {
    enum State: Equatable {
        case idle
        case running
        case completed
        case unknown
    }

    let state: State
    let activeCount: Int
    let updatedAt: Date

    static let idle = TaskActivitySnapshot(state: .idle, activeCount: 0, updatedAt: Date())

    var displayText: String {
        switch state {
        case .idle:
            return "无任务"
        case .running:
            return activeCount > 1 ? "执行中 x\(activeCount)" : "执行中"
        case .completed:
            return "已完成"
        case .unknown:
            return "--"
        }
    }
}

enum RateLimitError: Error, LocalizedError {
    case codexMissing
    case launchFailed(String)
    case timedOut
    case serverError(String)
    case invalidResponse
    case limitsNotFound

    var errorDescription: String? {
        switch self {
        case .codexMissing:
            return "找不到 Codex 可执行文件"
        case .launchFailed(let message):
            return "Codex app-server 启动失败：\(message)"
        case .timedOut:
            return "Codex app-server 请求超时"
        case .serverError(let message):
            return message
        case .invalidResponse:
            return "Codex app-server 返回了无法解析的数据"
        case .limitsNotFound:
            return "返回数据中没有找到 5 小时或周额度"
        }
    }
}

final class CodexRateLimitsClient {
    func fetch(timeout: TimeInterval = 20, completion: @escaping (Result<RateLimitSnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.isExecutableFile(atPath: codexBinaryPath) else {
                completion(.failure(RateLimitError.codexMissing))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexBinaryPath)
            process.arguments = ["app-server", "--listen", "stdio://"]

            let input = Pipe()
            let output = Pipe()
            let errorOutput = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorOutput

            let state = LockedResponseState()

            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                state.append(data)
            }

            errorOutput.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                state.appendError(text)
            }

            do {
                try process.run()
            } catch {
                completion(.failure(RateLimitError.launchFailed(error.localizedDescription)))
                return
            }

            let initialize: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "CodexQuotaBar",
                        "version": "0.1.0"
                    ]
                ]
            ]

            let request: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "account/rateLimits/read",
                "params": [:]
            ]

            let initialized: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [:]
            ]

            do {
                try self.write(initialize, to: input)
                try self.write(initialized, to: input)
                try self.write(request, to: input)
            } catch {
                process.terminate()
                completion(.failure(error))
                return
            }

            let deadline = Date().addingTimeInterval(timeout)
            var result: Result<RateLimitSnapshot, Error>?

            while Date() < deadline {
                if let response = state.response(id: 2) {
                    result = Self.decodeRateLimitResponse(response)
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }

            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }

            completion(result ?? .failure(RateLimitError.timedOut))
        }
    }

    private func write(_ object: [String: Any], to pipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private static func decodeRateLimitResponse(_ response: [String: Any]) -> Result<RateLimitSnapshot, Error> {
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex app-server 返回错误"
            return .failure(RateLimitError.serverError(message))
        }

        guard let result = response["result"] else {
            return .failure(RateLimitError.invalidResponse)
        }

        let extractor = RateLimitExtractor()
        let limits = extractor.extract(from: result)

        let snapshot = RateLimitSnapshot(
            fiveHour: limits[.fiveHour],
            weekly: limits[.weekly],
            fetchedAt: Date()
        )

        if snapshot.fiveHour == nil && snapshot.weekly == nil {
            return .failure(RateLimitError.limitsNotFound)
        }

        return .success(snapshot)
    }
}

final class CodexTaskStatusClient {
    struct Observation {
        let activeThreadIds: Set<String>
    }

    func fetch(completion: @escaping (Result<Observation, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: sessionsURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                completion(.success(Observation(activeThreadIds: [])))
                return
            }

            let now = Date()
            let runningThreshold: TimeInterval = 8
            var activeIds = Set<String>()

            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                      fileURL.pathExtension == "jsonl",
                      let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      now.timeIntervalSince(modifiedAt) <= runningThreshold else {
                    continue
                }

                activeIds.insert(Self.threadId(from: fileURL))
            }

            completion(.success(Observation(activeThreadIds: activeIds)))
        }
    }

    private static func threadId(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #"rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-"#, options: .regularExpression) {
            return String(name[range.upperBound...])
        }
        return name
    }
}

private final class LockedResponseState {
    private var buffer = Data()
    private var responses: [[String: Any]] = []
    private var errors: [String] = []
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !lineData.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else {
                continue
            }
            responses.append(object)
        }
    }

    func appendError(_ text: String) {
        lock.lock()
        errors.append(text)
        lock.unlock()
    }

    func response(id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return responses.first { ($0["id"] as? Int) == id }
    }
}

private final class RateLimitExtractor {
    private struct Candidate {
        let path: String
        let dictionary: [String: Any]
    }

    func extract(from object: Any) -> [RateLimit.Kind: RateLimit] {
        var limits: [RateLimit.Kind: RateLimit] = [:]

        for candidate in collectCandidates(object, path: []) {
            guard let usedPercent = number(in: candidate.dictionary, keys: [
                "usedPercent", "used_percent", "used_percentage", "usedPct", "used_pct",
                "percentUsed", "percent_used", "usagePercent", "usage_percent"
            ]) else {
                continue
            }

            let resetDescription = string(in: candidate.dictionary, keys: [
                "resetAt", "reset_at", "resetsAt", "resets_at", "resetTime", "reset_time",
                "windowResetAt", "window_reset_at", "nextResetAt", "next_reset_at"
            ])

            let label = candidate.path + " " + candidate.dictionary.compactMap { key, value -> String? in
                guard ["name", "label", "title", "bucket", "window", "period", "type"].contains(key.lowercased()) else {
                    return nil
                }
                return "\(value)"
            }.joined(separator: " ")

            if classify(label) == .fiveHour {
                limits[.fiveHour] = RateLimit(
                    kind: .fiveHour,
                    usedPercent: normalize(percent: usedPercent),
                    resetAt: parseDate(resetDescription),
                    resetDescription: resetDescription
                )
            } else if classify(label) == .weekly {
                limits[.weekly] = RateLimit(
                    kind: .weekly,
                    usedPercent: normalize(percent: usedPercent),
                    resetAt: parseDate(resetDescription),
                    resetDescription: resetDescription
                )
            }
        }

        limits.merge(extractFlatKeys(from: object)) { current, _ in current }
        return limits
    }

    private func collectCandidates(_ object: Any, path: [String]) -> [Candidate] {
        if let dictionary = object as? [String: Any] {
            var results = [Candidate(path: path.joined(separator: "."), dictionary: dictionary)]
            for (key, value) in dictionary {
                results.append(contentsOf: collectCandidates(value, path: path + [key]))
            }
            return results
        }

        if let array = object as? [Any] {
            return array.enumerated().flatMap { index, value in
                collectCandidates(value, path: path + ["[\(index)]"])
            }
        }

        return []
    }

    private func extractFlatKeys(from object: Any) -> [RateLimit.Kind: RateLimit] {
        guard let dictionary = object as? [String: Any] else {
            return [:]
        }

        var limits: [RateLimit.Kind: RateLimit] = [:]
        for kind in [RateLimit.Kind.fiveHour, .weekly] {
            let needles = kind == .fiveHour
                ? ["5h", "five", "5_hour", "five_hour", "fivehour", "hour"]
                : ["week", "weekly", "7d", "seven"]

            let usedPair = dictionary.first { key, value in
                let lower = key.lowercased()
                return needles.contains { lower.contains($0) }
                    && lower.contains("used")
                    && number(from: value) != nil
            }

            guard let usedValue = usedPair.flatMap({ number(from: $0.value) }) else {
                continue
            }

            let resetValue = dictionary.first { key, _ in
                let lower = key.lowercased()
                return needles.contains { lower.contains($0) } && lower.contains("reset")
            }.flatMap { "\($0.value)" }

            limits[kind] = RateLimit(
                kind: kind,
                usedPercent: normalize(percent: usedValue),
                resetAt: parseDate(resetValue),
                resetDescription: resetValue
            )
        }

        return limits
    }

    private func classify(_ text: String) -> RateLimit.Kind? {
        let lower = text.lowercased()
        if lower.contains("week") || lower.contains("weekly") || lower.contains("7d") || lower.contains("seven")
            || lower.contains("secondary") || lower.contains("long") {
            return .weekly
        }
        if lower.contains("5h") || lower.contains("five") || lower.contains("5_hour") || lower.contains("fivehour")
            || lower.contains("primary") || lower.contains("short") {
            return .fiveHour
        }
        return nil
    }

    private func number(in dictionary: [String: Any], keys: [String]) -> Double? {
        let lowerMap = lowercasedKeyMap(dictionary)
        for key in keys {
            if let value = lowerMap[key.lowercased()], let number = number(from: value) {
                return number
            }
        }
        return nil
    }

    private func string(in dictionary: [String: Any], keys: [String]) -> String? {
        let lowerMap = lowercasedKeyMap(dictionary)
        for key in keys {
            if let value = lowerMap[key.lowercased()] {
                return "\(value)"
            }
        }
        return nil
    }

    private func lowercasedKeyMap(_ dictionary: [String: Any]) -> [String: Any] {
        var map: [String: Any] = [:]
        for (key, value) in dictionary where map[key.lowercased()] == nil {
            map[key.lowercased()] = value
        }
        return map
    }

    private func number(from value: Any) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")) }
        return nil
    }

    private func normalize(percent: Double) -> Double {
        let value = percent <= 1 ? percent * 100 : percent
        return max(0, min(100, value))
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }
}

final class QuotaStore {
    private let client = CodexRateLimitsClient()
    private let taskClient = CodexTaskStatusClient()
    private var refreshTimer: Timer?
    private var taskStatusTimer: Timer?
    private var activeThreadIds = Set<String>()
    private var lastCompletedAt: Date?
    private(set) var snapshot: RateLimitSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var taskStatus: TaskActivitySnapshot = .idle
    var onChange: (() -> Void)?

    func startAutomaticRefresh(interval: TimeInterval = automaticRefreshInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        taskStatusTimer?.invalidate()
        taskStatusTimer = Timer.scheduledTimer(withTimeInterval: taskStatusRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshTaskStatus()
        }
        refresh()
        refreshTaskStatus()
    }

    func stopAutomaticRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        taskStatusTimer?.invalidate()
        taskStatusTimer = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        onChange?()

        client.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
                self.onChange?()
            }
        }
    }

    func refreshTaskStatus() {
        taskClient.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let observation):
                    self.applyTaskObservation(observation)
                case .failure:
                    self.taskStatus = TaskActivitySnapshot(state: .unknown, activeCount: 0, updatedAt: Date())
                    self.onChange?()
                }
            }
        }
    }

    private func applyTaskObservation(_ observation: CodexTaskStatusClient.Observation) {
        let now = Date()
        if !observation.activeThreadIds.isEmpty {
            activeThreadIds = observation.activeThreadIds
            lastCompletedAt = nil
            taskStatus = TaskActivitySnapshot(
                state: .running,
                activeCount: observation.activeThreadIds.count,
                updatedAt: now
            )
        } else if !activeThreadIds.isEmpty {
            activeThreadIds.removeAll()
            lastCompletedAt = now
            taskStatus = TaskActivitySnapshot(state: .completed, activeCount: 0, updatedAt: now)
        } else if let lastCompletedAt, now.timeIntervalSince(lastCompletedAt) < 90 {
            taskStatus = TaskActivitySnapshot(state: .completed, activeCount: 0, updatedAt: now)
        } else {
            taskStatus = TaskActivitySnapshot(state: .idle, activeCount: 0, updatedAt: now)
        }
        onChange?()
    }
}

final class SegmentedBatteryView: NSView {
    var percent: Double = 0 {
        didSet { needsDisplay = true }
    }

    var segmentCount = 12 {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 150, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let gap: CGFloat = 2
        let segmentWidth = (bounds.width - CGFloat(segmentCount - 1) * gap) / CGFloat(segmentCount)
        let filledSegments = Int(ceil((max(0, min(100, percent)) / 100) * Double(segmentCount)))

        for index in 0..<segmentCount {
            let rect = NSRect(
                x: CGFloat(index) * (segmentWidth + gap),
                y: 1,
                width: segmentWidth,
                height: bounds.height - 2
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            if index < filledSegments {
                color(for: percent).setFill()
            } else {
                NSColor.separatorColor.withAlphaComponent(0.45).setFill()
            }
            path.fill()
        }
    }

    private func color(for percent: Double) -> NSColor {
        if percent < 20 { return .systemRed }
        if percent < 45 { return .systemOrange }
        return .systemGreen
    }
}

final class QuotaRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let batteryView = SegmentedBatteryView()
    private let detailLabel = NSTextField(labelWithString: "--")

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailLabel.alignment = .right
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with limit: RateLimit?) {
        guard let limit else {
            batteryView.percent = 0
            detailLabel.stringValue = "--"
            return
        }
        batteryView.percent = limit.remainingPercent
        detailLabel.stringValue = "\(Int(round(limit.remainingPercent)))%  \(formatReset(limit))"
    }

    private func setup() {
        let stack = NSStackView(views: [titleLabel, batteryView, detailLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalToConstant: 48),
            batteryView.widthAnchor.constraint(equalToConstant: 142),
            detailLabel.widthAnchor.constraint(equalToConstant: 114),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func formatReset(_ limit: RateLimit) -> String {
        if let date = limit.resetAt {
            let formatter = DateFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
            return formatter.string(from: date)
        }
        return limit.resetDescription ?? "--"
    }
}

final class QuotaContentView: NSView {
    private let fiveHourRow = QuotaRowView(title: "5小时")
    private let weeklyRow = QuotaRowView(title: "周限额")
    private let statusLabel = NSTextField(labelWithString: "准备刷新")
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)

    var onRefresh: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: RateLimitSnapshot?, isRefreshing: Bool, error: String?) {
        fiveHourRow.update(with: snapshot?.fiveHour)
        weeklyRow.update(with: snapshot?.weekly)
        refreshButton.isEnabled = !isRefreshing

        if isRefreshing {
            statusLabel.stringValue = snapshot == nil ? "正在读取 Codex 额度..." : "正在刷新，保留旧数据..."
        } else if let error {
            statusLabel.stringValue = error
        } else if let fetchedAt = snapshot?.fetchedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            statusLabel.stringValue = "更新于 \(formatter.string(from: fetchedAt))"
        } else {
            statusLabel.stringValue = "点击刷新读取额度"
        }
    }

    private func setup() {
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let footer = NSStackView(views: [statusLabel, refreshButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [fiveHourRow, weeklyRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 330),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            statusLabel.widthAnchor.constraint(equalToConstant: 250)
        ])
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }
}

final class TouchBarQuotaView: NSView {
    private let logoButton = NSButton()
    private let fiveHourRow = TouchBarQuotaRowView(title: "5小时")
    private let weeklyRow = TouchBarQuotaRowView(title: "周限额")
    private let taskLightsView = TaskStatusLightsView()
    var onLogoTapped: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: RateLimitSnapshot?, isRefreshing: Bool, error: String?, taskStatus: TaskActivitySnapshot) {
        fiveHourRow.update(with: snapshot?.fiveHour, isRefreshing: isRefreshing)
        weeklyRow.update(with: snapshot?.weekly, isRefreshing: isRefreshing)
        taskLightsView.update(state: taskStatus.state)
    }

    private func setup() {
        if let image = NSImage(contentsOfFile: codexTemplateIconPath) {
            image.isTemplate = true
            logoButton.image = image
        }
        logoButton.imageScaling = .scaleProportionallyUpOrDown
        logoButton.contentTintColor = .labelColor
        logoButton.bezelStyle = .texturedRounded
        logoButton.isBordered = false
        logoButton.target = self
        logoButton.action = #selector(logoTapped)

        let rows = NSStackView(views: [fiveHourRow, weeklyRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1

        let stack = NSStackView(views: [logoButton, rows, taskLightsView])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 685),
            heightAnchor.constraint(equalToConstant: 30),
            logoButton.widthAnchor.constraint(equalToConstant: 26),
            logoButton.heightAnchor.constraint(equalToConstant: 26),
            taskLightsView.widthAnchor.constraint(equalToConstant: 44),
            taskLightsView.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func logoTapped() {
        onLogoTapped?()
    }
}

final class TaskStatusLightsView: NSView {
    private let idleLight = CALayer()
    private let runningLight = CALayer()
    private let completedLight = CALayer()
    private var currentState: TaskActivitySnapshot.State = .unknown

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 44, height: 18)
    }

    override func layout() {
        super.layout()
        layoutLights()
    }

    func update(state: TaskActivitySnapshot.State) {
        guard state != currentState else {
            return
        }
        currentState = state
        applyState()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        [idleLight, runningLight, completedLight].forEach { light in
            light.masksToBounds = true
            light.opacity = 1
            layer?.addSublayer(light)
        }

        applyState()
    }

    private func layoutLights() {
        let diameter: CGFloat = 8
        let gap: CGFloat = 6
        let totalWidth = (diameter * 3) + (gap * 2)
        let startX = max(0, (bounds.width - totalWidth) / 2)
        let y = max(0, (bounds.height - diameter) / 2)

        [idleLight, runningLight, completedLight].enumerated().forEach { index, light in
            light.frame = CGRect(
                x: startX + CGFloat(index) * (diameter + gap),
                y: y,
                width: diameter,
                height: diameter
            )
            light.cornerRadius = diameter / 2
        }
    }

    private func applyState() {
        stopBreathing()

        let dimColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        [idleLight, runningLight, completedLight].forEach { light in
            light.backgroundColor = dimColor
            light.opacity = 1
        }

        switch currentState {
        case .idle:
            idleLight.backgroundColor = NSColor.systemGray.withAlphaComponent(0.95).cgColor
        case .running:
            runningLight.backgroundColor = NSColor.systemGreen.cgColor
            startBreathing()
        case .completed:
            completedLight.backgroundColor = NSColor.systemBlue.cgColor
        case .unknown:
            [idleLight, runningLight, completedLight].forEach { light in
                light.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor
            }
        }
    }

    private func startBreathing() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.35
        animation.toValue = 1.0
        animation.duration = 1.2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        runningLight.add(animation, forKey: "breathing")
    }

    private func stopBreathing() {
        runningLight.removeAnimation(forKey: "breathing")
        runningLight.opacity = 1
    }
}

final class TouchBarActionView: NSView {
    var onRefresh: (() -> Void)?
    var onOpenPanel: (() -> Void)?
    var onBack: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let logoButton = NSButton()
        if let image = NSImage(contentsOfFile: codexTemplateIconPath) {
            image.isTemplate = true
            logoButton.image = image
        }
        logoButton.imageScaling = .scaleProportionallyUpOrDown
        logoButton.contentTintColor = .labelColor
        logoButton.bezelStyle = .texturedRounded
        logoButton.isBordered = false
        logoButton.target = self
        logoButton.action = #selector(backTapped)

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshTapped))
        refreshButton.bezelStyle = .rounded

        let panelButton = NSButton(title: "打开浮窗", target: self, action: #selector(openPanelTapped))
        panelButton.bezelStyle = .rounded

        let backButton = NSButton(title: "返回", target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded

        let stack = NSStackView(views: [logoButton, refreshButton, panelButton, backButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 685),
            heightAnchor.constraint(equalToConstant: 30),
            logoButton.widthAnchor.constraint(equalToConstant: 26),
            logoButton.heightAnchor.constraint(equalToConstant: 26),
            refreshButton.widthAnchor.constraint(equalToConstant: 72),
            panelButton.widthAnchor.constraint(equalToConstant: 96),
            backButton.widthAnchor.constraint(equalToConstant: 72),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }

    @objc private func openPanelTapped() {
        onOpenPanel?()
    }

    @objc private func backTapped() {
        onBack?()
    }
}

final class TouchBarQuotaRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let batteryView = SegmentedBatteryView()
    private let detailLabel = NSTextField(labelWithString: "--")

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        titleLabel.textColor = .labelColor
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        detailLabel.alignment = .right
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with limit: RateLimit?, isRefreshing: Bool) {
        guard let limit else {
            batteryView.percent = 0
            detailLabel.stringValue = isRefreshing ? "刷新中" : "--"
            return
        }
        batteryView.percent = limit.remainingPercent
        detailLabel.stringValue = "\(Int(round(limit.remainingPercent)))% \(formatReset(limit))"
    }

    private func setup() {
        batteryView.segmentCount = 18

        let stack = NSStackView(views: [titleLabel, batteryView, detailLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 14),
            titleLabel.widthAnchor.constraint(equalToConstant: 34),
            batteryView.widthAnchor.constraint(equalToConstant: 185),
            batteryView.heightAnchor.constraint(equalToConstant: 10),
            detailLabel.widthAnchor.constraint(equalToConstant: 92),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func formatReset(_ limit: RateLimit) -> String {
        if let date = limit.resetAt {
            let formatter = DateFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
            return formatter.string(from: date)
        }
        return limit.resetDescription ?? "--"
    }
}

final class QuotaViewController: NSViewController {
    private let store: QuotaStore
    private let quotaView = QuotaContentView()
    private weak var touchBarContentView: QuotaContentView?

    init(store: QuotaStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = quotaView
        quotaView.onRefresh = { [weak store] in
            store?.refresh()
        }
        update()
    }

    func update() {
        quotaView.update(snapshot: store.snapshot, isRefreshing: store.isRefreshing, error: store.lastError)
        touchBarContentView?.update(snapshot: store.snapshot, isRefreshing: store.isRefreshing, error: store.lastError)
    }

    override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [.quotaLimits]
        return touchBar
    }
}

extension NSTouchBarItem.Identifier {
    static let quotaLimits = NSTouchBarItem.Identifier("local.codex-quota-bar.limits")
}

extension QuotaViewController: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == .quotaLimits else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let compact = QuotaContentView(frame: NSRect(x: 0, y: 0, width: 330, height: 58))
        compact.onRefresh = { [weak store] in
            store?.refresh()
        }
        compact.update(snapshot: store.snapshot, isRefreshing: store.isRefreshing, error: store.lastError)
        touchBarContentView = compact
        item.view = compact
        return item
    }
}

final class StatusController {
    private let store: QuotaStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controlStripController: ControlStripController
    private let popover = NSPopover()
    private var panel: NSPanel?
    private lazy var popoverViewController = QuotaViewController(store: store)
    private lazy var panelViewController = QuotaViewController(store: store)

    init(store: QuotaStore) {
        self.store = store
        self.controlStripController = ControlStripController(store: store)
        self.controlStripController.onOpenPanel = { [weak self] in
            self?.showTouchBarPanel()
        }
        setupStatusItem()
        setupPopover()
        store.onChange = { [weak self] in
            self?.update()
        }
    }

    func start() {
        controlStripController.install()
        update()
        store.startAutomaticRefresh()
    }

    private func setupStatusItem() {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 330, height: 92)
        popover.contentViewController = popoverViewController
    }

    private func update() {
        popoverViewController.update()
        panelViewController.update()
        controlStripController.update()

        if let fiveHour = store.snapshot?.fiveHour {
            statusItem.button?.title = "Codex \(Int(round(fiveHour.remainingPercent)))%"
        } else if store.isRefreshing {
            statusItem.button?.title = "Codex ..."
        } else {
            statusItem.button?.title = "Codex --"
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "刷新", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "显示额度", action: #selector(showControlStripModal), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "打开浮窗", action: #selector(showTouchBarPanel), keyEquivalent: "t"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refresh() {
        store.refresh()
    }

    @objc private func showControlStripModal() {
        controlStripController.presentModal()
    }

    @objc private func showTouchBarPanel() {
        NSApp.activate(ignoringOtherApps: true)

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Codex 额度"
            panel.contentViewController = panelViewController
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            self.panel = panel
        }

        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panelViewController.view)
    }

    @objc private func quit() {
        store.stopAutomaticRefresh()
        controlStripController.remove()
        NSApp.terminate(nil)
    }
}

final class ControlStripController: NSObject {
    private static let identifier = "local.codex-quota-bar.control-strip"

    private let store: QuotaStore
    private let trayButton = NSButton(title: "Codex --", target: nil, action: nil)
    private let modalView = TouchBarQuotaView(frame: NSRect(x: 0, y: 0, width: 685, height: 30))
    private let actionView = TouchBarActionView(frame: NSRect(x: 0, y: 0, width: 685, height: 30))
    private var installed = false
    var onOpenPanel: (() -> Void)?

    init(store: QuotaStore) {
        self.store = store
        super.init()
        trayButton.target = self
        trayButton.action = #selector(presentModal)
        trayButton.bezelStyle = .texturedRounded
        trayButton.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        trayButton.setButtonType(.momentaryPushIn)
        trayButton.translatesAutoresizingMaskIntoConstraints = false
        trayButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        trayButton.heightAnchor.constraint(equalToConstant: 30).isActive = true

        modalView.onLogoTapped = { [weak self] in
            self?.presentActions()
        }

        actionView.onRefresh = { [weak self] in
            self?.store.refresh()
            self?.presentModal()
        }
        actionView.onOpenPanel = { [weak self] in
            self?.onOpenPanel?()
            self?.presentModal()
        }
        actionView.onBack = { [weak self] in
            self?.presentModal()
        }
    }

    func install() {
        installed = TBInstallSystemTrayItem(trayButton, Self.identifier)
        update()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.presentModal()
        }
    }

    func update() {
        if let fiveHour = store.snapshot?.fiveHour {
            trayButton.title = "Codex \(Int(round(fiveHour.remainingPercent)))%"
        } else if store.isRefreshing {
            trayButton.title = "Codex ..."
        } else {
            trayButton.title = "Codex --"
        }

        modalView.update(
            snapshot: store.snapshot,
            isRefreshing: store.isRefreshing,
            error: store.lastError,
            taskStatus: store.taskStatus
        )
    }

    @objc func presentModal() {
        modalView.update(
            snapshot: store.snapshot,
            isRefreshing: store.isRefreshing,
            error: store.lastError,
            taskStatus: store.taskStatus
        )
        _ = TBPresentSystemModalTouchBar(modalView, Self.identifier)
    }

    @objc func presentActions() {
        _ = TBPresentSystemModalTouchBar(actionView, Self.identifier)
    }

    func remove() {
        TBRemoveSystemTrayItem()
        installed = false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = QuotaStore()
    private var statusController: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApplication.shared.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        statusController = StatusController(store: store)
        statusController?.start()
    }
}

@main
struct CodexQuotaBarApp {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
