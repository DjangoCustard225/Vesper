import Foundation

public enum DownloadFileIO {
    /// Drain Foundation's temporary objects for every chunk, including in long synchronous workers.
    public static func copyChunk(from input: FileHandle, to output: FileHandle) throws -> Int64 {
        #if canImport(ObjectiveC)
        return try autoreleasepool { try copyBuffer(from: input, to: output) }
        #else
        return try copyBuffer(from: input, to: output)
        #endif
    }
    private static func copyBuffer(from input: FileHandle, to output: FileHandle) throws -> Int64 {
        guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { return 0 }
        try output.write(contentsOf: data)
        return Int64(data.count)
    }
}
