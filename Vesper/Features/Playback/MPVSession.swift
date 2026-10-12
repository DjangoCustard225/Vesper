import Foundation
import Libmpv
import QuartzCore

// The handle and all C calls belong to this queue. Retain the render layer until
// mpv has completely stopped its GPU threads, even after the view is dismissed.
final class MPVSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.vesper.mpv.engine", qos: .userInitiated)
    private let layer: CAMetalLayer
    private let receive: @Sendable (MPVPlaybackEvent) -> Void
    private var handle: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var loaded = false
    private var ended = false
    private var awaitingSeek = false
    private var ticks = 0
    private var lastSnapshot: MPVSnapshot?
    private var audio: [PlaybackTrack] = []
    private var subtitles: [PlaybackTrack] = []

    init(layer: CAMetalLayer, receive: @escaping @Sendable (MPVPlaybackEvent) -> Void) {
        self.layer = layer
        self.receive = receive
    }

    func start(url: URL) {
        queue.async { [self] in
            guard !stopped, handle == nil else { return }
            guard let context = mpv_create() else { fail("The video player could not start."); return }
            handle = context
            let options = [
                "config": "no", "terminal": "no", "osd-level": "0", "osd-on-seek": "no",
                "input-default-bindings": "no", "input-vo-keyboard": "no",
                "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "moltenvk",
                "hwdec": "videotoolbox", "keep-open": "yes", "idle": "yes",
                "cache": "yes", "demuxer-readahead-secs": "10",
                "demuxer-max-bytes": "67108864", "audio-buffer": "0.1",
                "audio-pitch-correction": "yes",
                "sub-font-size": "38", "sub-back-color": "#80000000",
                "sub-border-style": "background-box",
                "sub-border-size": "0", "sub-shadow-offset": "4"
            ]
            for (name, value) in options {
                if mpv_set_option_string(context, name, value) < 0 {
                    fail("The video player could not configure \(name).")
                    return
                }
            }
            // OSC belongs to Lua, which the iOS distribution may omit. The
            // missing optional script must never prevent the renderer starting.
            mpv_set_option_string(context, "osc", "no")
            var windowID = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
            guard mpv_set_option(context, "wid", MPV_FORMAT_INT64, &windowID) >= 0,
                  mpv_initialize(context) >= 0 else {
                fail("The video renderer could not start."); return
            }
            // State notifications are drained at 20 Hz; timeline updates stay at
            // 4 Hz so SwiftUI does not redraw controls for every decoded frame.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
            command(["loadfile", url.absoluteString])
        }
    }

    func pause(_ paused: Bool) {
        queue.async { [self] in
            guard let handle else { return }
            var value: Int32 = paused ? 1 : 0
            mpv_set_property_async(handle, 0, "pause", MPV_FORMAT_FLAG, &value)
        }
    }

    func rate(_ rate: Float) { setDouble(Double(rate), for: "speed") }

    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        queue.async { [self] in
            guard handle != nil, loaded else { return }
            awaitingSeek = true
            ended = false
            command(["seek", String(max(0, seconds)), "absolute+exact"])
        }
    }

    func select(track: Int32, subtitle: Bool) {
        queue.async { [self] in
            guard let handle else { return }
            mpv_set_property_string(handle, subtitle ? "sid" : "aid", track < 0 ? "no" : String(track))
        }
    }

    func fill(_ fill: Bool) { setDouble(fill ? 1 : 0, for: "panscan") }

    private func setDouble(_ value: Double, for property: String) {
        guard value.isFinite else { return }
        queue.async { [self] in
            guard let handle else { return }
            var value = value
            mpv_set_property_async(handle, 0, property, MPV_FORMAT_DOUBLE, &value)
        }
    }

    func suspendVideo(_ suspended: Bool) {
        queue.async { [self] in
            guard let handle else { return }
            // iOS cannot present Metal drawables while the app is in background.
            mpv_set_property_string(handle, "vid", suspended ? "no" : "auto")
        }
    }

    func stop() {
        queue.async { [self] in shutdown() }
    }

    private func shutdown() {
        stopped = true
        timer?.cancel()
        timer = nil
        if let context = handle {
            handle = nil
            mpv_terminate_destroy(context)
        }
    }

    private func fail(_ message: String) {
        receive(.failure(message))
        shutdown()
    }

    private func command(_ arguments: [String]) {
        guard let handle else { return }
        let allocated = arguments.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var pointers = allocated.map { $0.map { UnsafePointer($0) } }
        pointers.append(nil)
        let status = mpv_command_async(handle, 0, &pointers)
        if status < 0 { fail("This source could not be played. Try another source or an external player.") }
    }

    private func poll() {
        guard let context = handle, !stopped else { return }
        var changed = false
        while let pointer = mpv_wait_event(context, 0) {
            let event = pointer.pointee
            if event.event_id == MPV_EVENT_NONE { break }
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                loaded = true; ended = false
                readTracks(); changed = true
            case MPV_EVENT_PLAYBACK_RESTART:
                awaitingSeek = false; ended = false; changed = true
            case MPV_EVENT_END_FILE:
                if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    if data.reason == MPV_END_FILE_REASON_ERROR {
                        fail("This source could not be played. Try another source or an external player.")
                        return
                    }
                    if data.reason == MPV_END_FILE_REASON_EOF, !awaitingSeek { ended = true; changed = true }
                }
            case MPV_EVENT_COMMAND_REPLY:
                if event.error < 0 {
                    fail("This source could not be played. Try another source or an external player.")
                    return
                }
            case MPV_EVENT_SHUTDOWN:
                shutdown(); return
            default: break
            }
        }
        ticks += 1
        guard changed || ticks % 5 == 0 else { return }
        if ticks % 20 == 0 { readTracks() }
        if !awaitingSeek, loaded, flag("eof-reached") { ended = true }
        let state = MPVSnapshot(elapsed: number("time-pos"), duration: number("duration"),
                                seekable: flag("seekable"), loaded: loaded,
                                buffering: !loaded || flag("paused-for-cache"), ended: ended,
                                audio: audio, subtitles: subtitles,
                                selectedAudio: trackID("aid"), selectedSubtitle: trackID("sid"))
        if state != lastSnapshot { lastSnapshot = state; receive(.state(state)) }
    }

    private func number(_ name: String) -> Double {
        var value: Double = 0
        guard let handle, mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return 0 }
        return value
    }

    private func flag(_ name: String) -> Bool {
        var value: Int32 = 0
        guard let handle, mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 else { return false }
        return value != 0
    }

    private func trackID(_ name: String) -> Int32 {
        var value: Int64 = -1
        guard let handle, mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 else { return -1 }
        return Int32(exactly: value) ?? -1
    }

    private func readTracks() {
        guard let handle else { return }
        var root = mpv_node()
        guard mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &root) >= 0 else { return }
        defer { mpv_free_node_contents(&root) }
        guard root.format == MPV_FORMAT_NODE_ARRAY, let list = root.u.list?.pointee else { return }
        var audio: [PlaybackTrack] = [], subtitles: [PlaybackTrack] = []
        for index in 0..<Int(list.num) {
            let node = list.values[index]
            guard node.format == MPV_FORMAT_NODE_MAP, let map = node.u.list?.pointee else { continue }
            var fields: [String: String] = [:]
            var trackID: Int32?
            for field in 0..<Int(map.num) {
                guard let keyPointer = map.keys[field] else { continue }
                let key = String(cString: keyPointer)
                let value = map.values[field]
                if value.format == MPV_FORMAT_STRING, let string = value.u.string {
                    fields[key] = String(cString: string)
                } else if key == "id", value.format == MPV_FORMAT_INT64 {
                    trackID = Int32(exactly: value.u.int64)
                }
            }
            guard let id = trackID, id >= 0, let type = fields["type"], type == "audio" || type == "sub" else { continue }
            let title = [fields["title"], fields["lang"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let name = title.isEmpty ? "\(type == "audio" ? "Audio" : "Subtitle") \(id)" : title
            let track = PlaybackTrack(id: id, name: name)
            if type == "audio" { audio.append(track) } else { subtitles.append(track) }
        }
        self.audio = audio; self.subtitles = subtitles
    }
}
