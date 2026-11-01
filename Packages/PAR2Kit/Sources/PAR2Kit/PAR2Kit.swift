//
//  PAR2Kit.swift
//  PAR2Kit
//
//  Clean-room implementation of the PAR2 specification: packet parsing, slice verification,
//  and Reed-Solomon (GF(2^16)) repair. Permissively licensed — contains no GPL code — so it is
//  safe for App Store distribution. No app/UI dependencies; unit-tested with `swift test`.
//

/// Marker for the PAR2Kit module; real entry points are added in Phase 2/3.
public enum PAR2Kit {
    public static let version = "0.1.0"
}
