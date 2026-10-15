import Foundation

public enum PlaybackDestination: Equatable { case native(URL), external(URL) }

public enum StreamResolver {
    public static func resolve(_ stream: StreamSource) throws -> PlaybackDestination {
        if let external = stream.externalUrl { return .external(try AddonURL.http(external)) }
        if let ytID = stream.ytId {
            return .external(try AddonURL.http("https://www.youtube.com/watch?v=" + AddonURL.encode(ytID)))
        }
        if let raw = stream.url {
            let url = try AddonURL.http(raw)
            if let headers = stream.behaviorHints?.proxyHeaders,
                !(headers.request ?? [:]).isEmpty || !(headers.response ?? [:]).isEmpty
            {
                throw AddonError.unsupportedStream
            }
            return .native(url)
        }
        throw AddonError.unsupportedStream
    }
}
