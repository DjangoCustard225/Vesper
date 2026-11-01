//
//  DownloadEngine.swift
//  DownloadEngine
//
//  Pure-Swift Usenet download engine: NNTP transport, yEnc decoding, segment scheduling,
//  connection pooling, file assembly, and checkpoint/resume. No app/UI dependencies so it
//  can be unit-tested in isolation with `swift test`.
//

/// Marker for the engine module; real entry points are added in Phase 2.
public enum DownloadEngine {
    public static let version = "0.1.0"
}
