// vt - VideoToolbox probes for the video rows of the 10/10 list. Each prints one JSON object.
//   vt list                                 encoders VideoToolbox lists (hardware or not) and hardware decode per codec
//   vt encode CODEC W H FPS SECONDS OUT     hardware-only encode of a synthetic clip; CODEC is h264, hevc or hevc10
//   vt make CODEC W H FPS SECONDS OUT       the same, falling back to Apple's software encoder: test clips for decode
//   vt decode FILE                          hardware-only decode of FILE as fast as it goes
//   vt play FILE SECONDS                    AVPlayer in a window (the QuickTime path) and its dropped-frame count
import AVFoundation
import AppKit
import Metal
import VideoToolbox

// The plugin registers its decoders and encoders with VideoToolbox only in a process that makes a Metal device, and
// the registration is asynchronous, so every probe makes one and gives it a moment first.
func metal() -> String {
    let d = MTLCreateSystemDefaultDevice()
    usleep(500_000)
    return d?.name ?? "none"
}

let a = CommandLine.arguments
func out(_ d: [String: Any]) -> Never {
    print(String(data: try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
func fourcc(_ c: FourCharCode) -> String {
    String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((c >> $0) & 0xff))) })
}
func prop(_ s: VTSession, _ k: CFString) -> Any? {
    var v: CFTypeRef?
    let st = withUnsafeMutablePointer(to: &v) { VTSessionCopyProperty(s, key: k, allocator: nil, valueOut: $0) }
    return st == noErr ? v : nil
}
func ms(_ d: Date) -> Double { (Date().timeIntervalSince(d) * 10000).rounded() / 10 }

func encoders() -> [[String: Any]] {
    var encs: [[String: Any]] = []
    var cf: CFArray?
    if VTCopyVideoEncoderList(nil, &cf) == noErr, let l = cf as? [[String: Any]] {
        for e in l {
            encs.append(["id": e[kVTVideoEncoderList_EncoderID as String] ?? "", "codec": fourcc((e[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value ?? 0),
                         "name": e[kVTVideoEncoderList_DisplayName as String] ?? "",
                         "hardware": (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false])
        }
    }
    return encs
}

func list() -> Never {
    let before = encoders().filter { ($0["hardware"] as? Bool) == true }
    let dev = metal()
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
    let codecs: [(String, CMVideoCodecType)] = [("h264", kCMVideoCodecType_H264), ("hevc", kCMVideoCodecType_HEVC),
                                                 ("vp9", kCMVideoCodecType_VP9), ("av1", kCMVideoCodecType_AV1)]
    var dec: [String: Bool] = [:]
    for (n, c) in codecs { dec[n] = VTIsHardwareDecodeSupported(c) }
    out(["metal_device": dev, "hardware_encoders_before_device": before, "encoders": encoders(), "hardware_decode": dec])
}

// A moving bar over a gradient, so the encoder sees motion; 30 prebuilt frames reused keep CPU fill out of the timing.
func frames(_ w: Int, _ h: Int, ten: Bool) -> [CVPixelBuffer] {
    let fmt = ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    return (0..<30).map { i in
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        let bar = (w * i / 30)
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(b, plane)!, stride = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            let ph = CVPixelBufferGetHeightOfPlane(b, plane), pw = CVPixelBufferGetWidthOfPlane(b, plane)
            for y in 0..<ph {
                if ten {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<(pw * (plane == 0 ? 1 : 2)) {
                        let v = plane == 0 ? (abs(x - bar) < 64 ? 940 : 64 + (x + y) % 800) : 512 + (y % 64)
                        row[x] = UInt16(v) << 6
                    }
                } else {
                    let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<(pw * (plane == 0 ? 1 : 2)) {
                        row[x] = plane == 0 ? (abs(x - bar) < 64 ? 235 : UInt8(16 + (x + y) % 200)) : UInt8(128 + (y % 16))
                    }
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }
}

func encode(_ codec: String, _ w: Int, _ h: Int, _ fps: Int, _ secs: Double, _ path: String, software: Bool) -> Never {
    let ten = codec == "hevc10", type = codec == "h264" ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
    let dev = metal()
    func session(_ hw: Bool) -> (OSStatus, VTCompressionSession?) {
        let spec: [String: Any] = hw ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] : [:]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: type,
                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        return (st, s)
    }
    var (st, s) = session(true)
    let hwStatus = st
    if st != noErr && software { (st, s) = session(false) }
    guard st == noErr, let sess = s else { out(["codec": codec, "metal_device": dev, "error": "no hardware encoder (\(st))"]) }
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: 40_000_000 as CFNumber)
    if ten { VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel) }
    let hw = prop(sess, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
    let eid = prop(sess, kVTCompressionPropertyKey_EncoderID)

    try? FileManager.default.removeItem(atPath: path)
    let wr = try! AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mov)
    var input: AVAssetWriterInput?
    let lock = NSLock()
    var encoded = 0, keyframes = 0, failures = 0
    let pool = frames(w, h, ten: ten)
    let n = Int(secs * Double(fps))
    let t0 = Date()
    for i in 0..<n {
        let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
        VTCompressionSessionEncodeFrame(sess, imageBuffer: pool[i % pool.count], presentationTimeStamp: pts,
                                        duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: nil,
                                        infoFlagsOut: nil) { status, _, sb in
            lock.lock(); defer { lock.unlock() }
            guard status == noErr, let sb = sb else { failures += 1; return }
            if input == nil {
                input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(sb))
                input!.expectsMediaDataInRealTime = false
                wr.add(input!); wr.startWriting(); wr.startSession(atSourceTime: .zero)
            }
            let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
            if !((att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false) { keyframes += 1 }
            while !input!.isReadyForMoreMediaData { usleep(1000) }
            input!.append(sb); encoded += 1
        }
    }
    VTCompressionSessionCompleteFrames(sess, untilPresentationTimeStamp: .invalid)
    let took = Date().timeIntervalSince(t0)
    input?.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    wr.finishWriting { done.signal() }
    done.wait()
    out(["codec": codec, "metal_device": dev, "hardware_session_status": Int(hwStatus), "size": "\(w)x\(h)", "fps_target": fps, "frames_in": n, "frames_out": encoded, "keyframes": keyframes,
         "failures": failures, "encode_fps": (Double(encoded) / took * 10).rounded() / 10, "hardware": (hw as? Bool) ?? NSNull(),
         "encoder_id": (eid as? String) ?? NSNull(), "file": path, "writer_error": wr.error.map { "\($0)" } ?? NSNull()])
}

func decode(_ path: String) -> Never {
    let dev = metal()
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first, let rd = try? AVAssetReader(asset: asset)
    else { out(["file": path, "error": "no video track"]) }
    let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    rd.add(o); rd.startReading()
    let fd = track.formatDescriptions.first as! CMVideoFormatDescription
    let spec: [String: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true]
    var s: VTDecompressionSession?
    let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec as CFDictionary,
                                          imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &s)
    guard st == noErr, let sess = s else { out(["file": path, "metal_device": dev, "codec": fourcc(CMFormatDescriptionGetMediaSubType(fd)), "error": "no hardware decoder (\(st))"]) }
    let hw = prop(sess, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)
    let lock = NSLock()
    var decoded = 0, failures = 0, worst = 0.0
    let t0 = Date()
    while let sb = o.copyNextSampleBuffer() {
        let ts = Date()
        VTDecompressionSessionDecodeFrame(sess, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, img, _, _ in
            lock.lock(); defer { lock.unlock() }
            if status == noErr && img != nil { decoded += 1 } else { failures += 1 }
            worst = max(worst, Date().timeIntervalSince(ts) * 1000)
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(sess)
    let took = Date().timeIntervalSince(t0)
    out(["file": path, "metal_device": dev, "codec": fourcc(CMFormatDescriptionGetMediaSubType(fd)), "hardware": (hw as? Bool) ?? NSNull(), "frames": decoded,
         "failures": failures, "decode_fps": (Double(decoded) / took * 10).rounded() / 10, "worst_frame_ms": (worst * 10).rounded() / 10])
}

func play(_ path: String, _ secs: Double) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let item = AVPlayerItem(url: URL(fileURLWithPath: path))
    let player = AVPlayer(playerItem: item)
    let scr = NSScreen.main!.frame
    let win = NSWindow(contentRect: scr.insetBy(dx: scr.width * 0.1, dy: scr.height * 0.1), styleMask: [.titled], backing: .buffered, defer: false)
    let v = NSView(frame: win.contentView!.bounds); v.wantsLayer = true
    let pl = AVPlayerLayer(player: player); pl.frame = v.bounds; v.layer!.addSublayer(pl)
    win.contentView = v; win.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    // loop the clip so a short file still covers SECONDS
    NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
        player.seek(to: .zero); player.play()
    }
    // AVPlayer's access log stays empty for a local file, so drops are counted from the frames themselves: a video
    // output polled at 1 kHz sees each new picture's item time, and a step of more than one frame duration is a drop.
    let vo = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(vo)
    player.play()
    let t0 = Date()
    var shown = 0, dropped = 0, lastTime = CMTime.invalid
    var frameDur = 1.0 / 60
    if let t = item.asset.tracks(withMediaType: .video).first, t.nominalFrameRate > 0 { frameDur = 1 / Double(t.nominalFrameRate) }
    Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in
        let now = vo.itemTime(forHostTime: CACurrentMediaTime())
        guard vo.hasNewPixelBuffer(forItemTime: now) else { return }
        var shownTime = CMTime.invalid
        guard vo.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &shownTime) != nil else { return }
        if lastTime.isValid {
            let step = (shownTime - lastTime).seconds
            if step > 0 { dropped += max(Int((step / frameDur).rounded()) - 1, 0) }
        }
        lastTime = shownTime; shown += 1
    }
    Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { _ in
        player.pause()
        let wall = ms(t0) / 1000
        out(["file": path, "seconds": wall, "status": item.status.rawValue, "error": item.error.map { "\($0)" } ?? NSNull(),
             "frames_shown": shown, "frames_dropped": dropped, "shown_fps": (Double(shown) / wall * 10).rounded() / 10,
             "content_fps": (1 / frameDur * 10).rounded() / 10])
    }
    app.run()
    exit(1)
}

switch a.count > 1 ? a[1] : "" {
case "list": list()
case "encode" where a.count == 8: encode(a[2], Int(a[3])!, Int(a[4])!, Int(a[5])!, Double(a[6])!, a[7], software: false)
case "make" where a.count == 8: encode(a[2], Int(a[3])!, Int(a[4])!, Int(a[5])!, Double(a[6])!, a[7], software: true)
case "decode" where a.count == 3: decode(a[2])
case "play" where a.count == 4: play(a[2], Double(a[3])!)
default:
    FileHandle.standardError.write("usage: vt list | encode|make CODEC W H FPS SECONDS OUT | decode FILE | play FILE SECONDS\n".data(using: .utf8)!)
    exit(2)
}
