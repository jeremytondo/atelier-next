// Decode every captured frame into numbered contact sheets, preserving actual
// presentation times. These sheets aid visual review; no automated flash verdict.
import AppKit
import AVFoundation
import CoreImage

let args = Array(CommandLine.arguments.dropFirst()).drop(while: { $0 == "--" })
guard args.count == 2 else { fputs("Usage: review-recording movie.mov /new/output-directory\n", stderr); exit(64) }
let paths = Array(args)
let directory = URL(fileURLWithPath: paths[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let asset = AVURLAsset(url: URL(fileURLWithPath: paths[0]))
guard let track = try await asset.loadTracks(withMediaType: .video).first else { fatalError("No video track") }
let frameRate = try await track.load(.nominalFrameRate)
let duration = try await asset.load(.duration)
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(output)
guard reader.startReading() else { fatalError("Could not start reading") }
let columns = 6, rows = 6, tileWidth = 320, tileHeight = 220
let context = CIContext(options: [.cacheIntermediates: false])
var canvas: NSBitmapImageRep!
var graphics: NSGraphicsContext!
var times: [Double] = [], page = 0
func savePage() throws {
  guard let canvas else { return }
  let url = directory.appendingPathComponent(String(format: "frames-%03d.jpg", page))
  try canvas.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: url)
}
while let sample = output.copyNextSampleBuffer() {
  try autoreleasepool {
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw NSError(domain: "Missing frame", code: 1) }
    let index = times.count, position = index % (columns * rows)
    if position == 0 {
      try savePage(); page += 1
      canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: columns * tileWidth, pixelsHigh: rows * tileHeight,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
      graphics = NSGraphicsContext(bitmapImageRep: canvas)!
    }
    let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    times.append(time)
    let ci = CIImage(cvPixelBuffer: buffer)
    guard let frame = context.createCGImage(ci, from: ci.extent) else { throw NSError(domain: "Frame decode", code: 1) }
    let x = (position % columns) * tileWidth, y = (rows - 1 - position / columns) * tileHeight
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    NSColor.black.setFill(); NSRect(x: x, y: y, width: tileWidth, height: tileHeight).fill()
    NSImage(cgImage: frame, size: .zero).draw(in: NSRect(x: x, y: y + 20, width: tileWidth, height: tileHeight - 20))
    (String(format: "frame %d   %.4f s", index, time) as NSString).draw(at: NSPoint(x: x + 4, y: y + 3),
      withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.white])
    NSGraphicsContext.restoreGraphicsState()
  }
}
try savePage()
guard reader.status == .completed else { fatalError("Incomplete decode: \(String(describing: reader.error))") }
let sortedTimes = times.sorted()
let gaps = zip(sortedTimes.dropFirst(), sortedTimes).map(-)
let report: [String: Any] = ["source": paths[0], "frames": times.count, "nominalFrameRate": frameRate,
  "durationSeconds": CMTimeGetSeconds(duration), "maximumFrameGapSeconds": gaps.max() ?? 0,
  "contactSheets": page, "presentationTimesSeconds": times]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: directory.appendingPathComponent("frames.json"))
print("Decoded \(times.count) frames, nominal \(frameRate) fps, \(page) contact sheets in \(directory.path)")
