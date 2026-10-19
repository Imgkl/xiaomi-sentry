import AVFoundation
import SentryCore

enum PlayerState: Equatable {
    case idle
    case connecting
    case live
    case offline(String)
    case unauthorized
}

/// Plays one go2rtc stream natively: WebSocket in `mse` mode, fMP4 demux in Swift,
/// hardware HEVC decode in AVSampleBufferDisplayLayer. Video only.
/// The open socket is also what keeps go2rtc's camera connection alive for pan commands.
final class StreamPlayer: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()
    /// Called on the main queue.
    var onState: ((PlayerState) -> Void)?

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "XiaomiSentry.player")
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var demuxer = FMP4Demuxer()
    private var waitingForKeyframe = true
    private var isLive = false
    private var watchdog: DispatchWorkItem?

    private var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    init() {
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = CGColor(gray: 0.05, alpha: 1)
    }

    func start(client: Go2RTCClient, stream: String) {
        let request: URLRequest
        do { request = try client.webSocketRequest(stream: stream) } catch {
            emit(.offline("The server address is not valid."))
            return
        }
        queue.async {
            self.teardown()
            self.generation += 1
            let gen = self.generation
            self.demuxer = FMP4Demuxer()
            self.waitingForKeyframe = true
            self.isLive = false
            self.renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            self.emit(.connecting)

            let task = client.streaming.webSocketTask(with: request)
            task.maximumMessageSize = 16 << 20
            self.task = task
            task.resume()
            // Ask for video only. WebKit-style codec list: go2rtc picks what the camera has.
            // The player lives as long as the app, so these closures hold it strongly.
            task.send(.string(#"{"type":"mse","value":"hvc1.1.6.L153.B0,avc1.640029"}"#)) { error in
                guard let error else { return }
                self.queue.async { self.fail(gen, self.describe(error, task)) }
            }
            self.receive(task, gen)

            // A new Xiaomi connection fetches keys from the cloud and waits for a keyframe.
            let watchdog = DispatchWorkItem {
                guard gen == self.generation, !self.isLive else { return }
                self.fail(gen, "The camera did not send video.")
            }
            self.watchdog = watchdog
            self.queue.asyncAfter(deadline: .now() + 25, execute: watchdog)
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.teardown()
            self.emit(.idle)
        }
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isLive = false
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.fail(gen, self.describe(error, task))
                case .success(.string(let text)):
                    self.handleText(text, gen)
                    self.receive(task, gen)
                case .success(.data(let data)):
                    self.handleData(data)
                    self.receive(task, gen)
                @unknown default:
                    self.receive(task, gen)
                }
            }
        }
    }

    private func handleText(_ text: String, _ gen: Int) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if obj["type"] as? String == "error" {
            let value = obj["value"] as? String ?? "go2rtc reported an error."
            fail(gen, value.contains("stream not found") ? "go2rtc has no stream with this name." : value)
        }
    }

    private func handleData(_ data: Data) {
        for frame in demuxer.append(data) {
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush(removingDisplayedImage: false, completionHandler: nil)
                waitingForKeyframe = true
            }
            if waitingForKeyframe {
                guard frame.isKeyframe else { continue }
                waitingForKeyframe = false
            }
            renderer.enqueue(frame.sampleBuffer)
            if !isLive {
                isLive = true
                watchdog?.cancel()
                emit(.live)
            }
        }
    }

    private func fail(_ gen: Int, _ message: String) {
        guard gen == generation else { return }
        generation += 1
        let unauthorized = message == Self.unauthorizedMarker
        teardown()
        emit(unauthorized ? .unauthorized : .offline(message))
    }

    private static let unauthorizedMarker = "\u{1}401"

    private func describe(_ error: Error, _ task: URLSessionWebSocketTask) -> String {
        if let http = task.response as? HTTPURLResponse {
            if http.statusCode == 401 { return Self.unauthorizedMarker }
            if http.statusCode != 101 { return "go2rtc answered HTTP \(http.statusCode)." }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .notConnectedToInternet, .networkConnectionLost:
                return "Can't reach go2rtc. Check that it runs and that Local Network access is on."
            default:
                break
            }
        }
        return isLive ? "The stream stopped." : error.localizedDescription
    }

    private func emit(_ state: PlayerState) {
        DispatchQueue.main.async { self.onState?(state) }
    }
}
