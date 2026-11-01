import Testing
@testable import PAR2Kit

struct GaloisField16Tests {
    @Test func multiplicationBasics() {
        #expect(GaloisField16.multiply(0, 5) == 0)
        #expect(GaloisField16.multiply(1, 1234) == 1234)
        #expect(GaloisField16.multiply(1234, 1) == 1234)
    }

    @Test func inverseRoundTrips() {
        for a: UInt16 in [1, 2, 255, 0x1234, 0xABCD, 0xFFFF] {
            #expect(GaloisField16.multiply(a, GaloisField16.inverse(a)) == 1)
        }
    }

    @Test func distributiveLaw() {
        let a: UInt16 = 0xABCD, b: UInt16 = 0x1234, c: UInt16 = 0x9876
        let lhs = GaloisField16.multiply(a, b ^ c)
        let rhs = GaloisField16.multiply(a, b) ^ GaloisField16.multiply(a, c)
        #expect(lhs == rhs)
    }

    @Test func powMatchesRepeatedMultiply() {
        let a: UInt16 = 0xABCD
        #expect(GaloisField16.pow(a, 0) == 1)
        #expect(GaloisField16.pow(a, 1) == a)
        #expect(GaloisField16.pow(a, 2) == GaloisField16.multiply(a, a))
        #expect(GaloisField16.pow(a, 3) == GaloisField16.multiply(GaloisField16.multiply(a, a), a))
    }

    @Test func antilogGenerator() {
        #expect(GaloisField16.antilog(0) == 1)
        #expect(GaloisField16.antilog(1) == 2)  // generator is 2
        #expect(GaloisField16.antilog(2) == 4)
    }

    @Test func validLogBaseRule() {
        // 0 is excluded (gcd 65535), 1 and 2 are valid, 3 is not (shares factor 3 with 65535).
        #expect(!GaloisField16.isValidLogBase(0))
        #expect(GaloisField16.isValidLogBase(1))
        #expect(GaloisField16.isValidLogBase(2))
        #expect(!GaloisField16.isValidLogBase(3))
        #expect(GaloisField16.isValidLogBase(4))
    }
}
