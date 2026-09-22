import Foundation
@testable import ZynSign

/// Synthetic certificate fixtures for tests.
///
/// All certificates are synthetic, generated with OpenSSL for testing only.
/// They contain no real private signing credentials, no production identities,
/// and no sensitive material. See `SECURITY.md`.
///
/// The DER bytes are embedded as Base64 to keep tests self-contained and to
/// avoid committing binary files.
enum CertificateFixtures {

    /// An RSA 2048 certificate.
    /// Subject: CN=ZynSign Test Valid
    /// Issuer: CN=Test CA, O=ZynSign Test, C=US
    /// Validity: 2026-09-22 18:14:30Z to 2027-09-22 18:14:30Z
    /// Key: RSA 2048, signature: sha256WithRSAEncryption
    /// Fingerprint SHA256: 4aea4f8b88d249d4612ec2101efa985d75ab500640372e07ae82aa29c9c8c575
    static let validDER: Data = {
        let base64 = "MIIDPjCCAiagAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwNjEQMA4GA1UEAwwHVGVzdCBDQTEVMBMGA1UECgwMWnluU2lnbiBUZXN0MQswCQYDVQQGEwJVUzAeFw0yNjA5MjIxODE0MzBaFw0yNzA5MjIxODE0MzBaMB0xGzAZBgNVBAMMElp5blNpZ24gVGVzdCBWYWxpZDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALrTDu6g5WwhXVYFVN+AvLDoc+VQMy6eXueKFikP0mych0zSMEjF4guYgfoh4GcOuIJr+69WYH/++ACwstZTvjYM7nNP3jXptyI10FlFlJ8keCbJIYhyA1O3nc3CgwdgmJmTz4Kd0tdbYK3waFrPX2lb3cpfSRloUhO4DqVkFpEEcBd4BjrvVWyBUtQW33h8uaY7QwdRhfI3AQGwv5iFkV9ickyYqQ2o/a2/5bxmLsGjAIsFqdvBPuxLZqGoyOzbBVkJG8SmRMwHsRm2FCY1Atr5RlrelfZZgvIz+VwUlj7LlfOWWaVNL83rtcbcIZmloc5j2sYgutl++PC4FZjPGQECAwEAAaNvMG0wCQYDVR0TBAIwADALBgNVHQ8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwHQYDVR0OBBYEFDo0suwDKQE/+Az2WC9cYil1CpI1MB8GA1UdIwQYMBaAFC+k7w4oUu01qbQVqCmzyw2WWcqAMA0GCSqGSIb3DQEBCwUAA4IBAQArW5Z2mt9lPcxuoLNt2wbYrSHLDIJ0t20sY16b73fWOiCW+lJMYcgrH82wHs8RuowgCa44xrk+8pJdnG32Dgwcv6v3TR+lMrzZ1RlrDAdURZaLYmeWYaflwfjtanqHA+jtikf9lkUv8+BFSGnUtRgh1gtC0uZGwuxHK0Bw7B/z0g4sIRZqyosG6fvf7alclIfbv47AP2NGEUTf4tPnNLocI6PDewDXt4evIIIg3XjRfks+4nwJr/Top5AyhsLEd9wGKjGthscfX/D9YsJeZrOi1Y78401+tfgyPirys8o+D5zoWV/NiF2zqiVeTjKfpqe5oxHLTD8WUq3LAl46MYH4"
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode valid DER fixture")
        }
        return data
    }()

    /// An expired RSA 2048 certificate.
    /// Validity: 2020-01-01 to 2021-01-01 (expired)
    static let expiredDER: Data = {
        let base64 = "MIIDQDCCAiigAwIBAgICEAEwDQYJKoZIhvcNAQELBQAwNjEQMA4GA1UEAwwHVGVzdCBDQTEVMBMGA1UECgwMWnluU2lnbiBUZXN0MQswCQYDVQQGEwJVUzAeFw0yMDAxMDEwMDAwMDBaFw0yMTAxMDEwMDAwMDBaMB8xHTAbBgNVBAMMFFp5blNpZ24gVGVzdCBFeHBpcmVkMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkFgJAtMdUwLQONC6w52AxRR7NX4S8OsQlJe6iXedZ8kffiaE9ZngGiRyUm16HRDl/s6k+rf62TnrqKdI+wvHcXDGieiAXiBkwvvtV/kS/NxlPraWR77d3OGZ38qG0B5lsJecKEW7Ssx+B5uXafd78YlQ9PZ0cvjrK0SgkpxKvGopWL1tCAr2rwiRjnLosghcINkcIBP4knD5LgGQtmV9c5Xfg0XB+vtVlhtYEbKcC28wGZxE4P+FmamiIeM2nNqoel9v4uVV+EisgHzcCo8V0c2Z7pPGHSQsGJ9QSq6F3ghjKfa64XJkoHlOP2UYDBXj6J06L7wl+kaVDqkVJGBhUwIDAQABo28wbTAJBgNVHRMEAjAAMAsGA1UdDwQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDAzAdBgNVHQ4EFgQU1cswrIB49spZInzsQvNwNbI0h9IwHwYDVR0jBBgwFoAUL6TvDihS7TWptBWoKbPLDZZZyoAwDQYJKoZIhvcNAQELBQADggEBAEpC7BicY9keCi2oil5+oi07cZsPPbWdGBrFBKT9ZkGLOJnmp8aBx95E/Wtjt76gV/1arhOKIF7CoqrRk6M2OtxIMvP5k42T+cLXtVQK3S5VAVglTgCrXYFvOan6mnYfwfla+4DZ8M4CA38Gmv9LDQMDwMJYkB7CmQirMCupTXl07XPfifl9GFlFImpmw2M2P4aWCkFu2ZxhM1SOpZc4VRhsJ5TJHVdzzhkviWQjeJSBmIDKAVlTIaW3aj/QeMxT7XUhjDO+wwe8L60hnV6xFiFEQGP5Nsn6CEzAwftRK5fC42aBSn3M1kujvcwPDyxWXjfqQKE9fsM2tkBFTVz8bdo="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode expired DER fixture")
        }
        return data
    }()

    /// A not-yet-valid RSA 2048 certificate.
    /// Validity: 2027-01-01 to 2028-01-01 (future)
    static let futureDER: Data = {
        let base64 = "MIIDKjCCAhKgAwIBAgICEAIwDQYJKoZIhvcNAQELBQAwNjEQMA4GA1UEAwwHVGVzdCBDQTEVMBMGA1UECgwMWnluU2lnbiBUZXN0MQswCQYDVQQGEwJVUzAeFw0yNzAxMDEwMDAwMDBaFw0yODAxMDEwMDAwMDBaMB4xHDAaBgNVBAMME1p5blNpZ24gVGVzdCBGdXR1cmUwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCfytWGuzQZ2AeA/8/+feQyShR+dixTy5RFRwEGtKU8tPtbWHnhBMaGOM7XefnB3w3mqPFdFjul1vOknU2tS9obPFV8Rwk4B4FCu1hjcnyJmA425PZmapvYxcn/czWNCfiScVdIxwSfl1NOD4H1sRs5PWIkEnO0Apw+BRmml/VYwvCy4eIbppVcsFfoz4O3+53uk2BoqjhNp4jII1BAlKqadQfrOU1XurVble7awvRym1ERKvlkD1h/wIlwMHCjktuLKPsIWnj1+aSZ0RiRJH7u3RSwRr4lvbBLZzsWmHT3aLn40xZ+6d82OpwbpvnqooxXwqDOT4l+LrnZ1FgPMKf1AgMBAAGjWjBYMAkGA1UdEwQCMAAwCwYDVR0PBAQDAgWgMB0GA1UdDgQWBBQj9OK0KU6vWEw/DJ5msQQoJu4YnDAfBgNVHSMEGDAWgBQvpO8OKFLtNam0Fagps8sNllnKgDANBgkqhkiG9w0BAQsFAAOCAQEAzQu4H+vRKffV3T9kFF4Cs5T2d5g9SDY3zP+rQIaeEdPQsk2Or1OYsgl2KGSQ8VxbInz86up4miVjiTo5PQ+eVbujMI2RTIgY9tYlqmDLeIxycGt43BG/ZV8ShzvdBlnufuXSolcKgxuhYmGQ3ThfTCrzbOYx5+ll1DCaETaIrr5iSMnIwIVkHB2hq69Diwxnka/PLbimWKtVSE11W+kxzopM2eMdbZkZzZZkCPIA94hzHtcXZPnpmMj6vIk8mYROCavCn9eqy62tkftZraP36dSMO6CCmn8UGSPqmmBxCwOmWachVmZZiL8mxsBWLzEWRvQztZLyvfH4ZFOwMDxdLg=="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode future DER fixture")
        }
        return data
    }()

    /// An EC P-256 certificate signed with sha256WithRSAEncryption.
    /// The signature algorithm and the public-key algorithm are not the same.
    static let ecDER: Data = {
        let base64 = "MIICcDCCAVigAwIBAgICEAMwDQYJKoZIhvcNAQELBQAwNjEQMA4GA1UEAwwHVGVzdCBDQTEVMBMGA1UECgwMWnluU2lnbiBUZXN0MQswCQYDVQQGEwJVUzAeFw0yNjA5MjIxODE0MzFaFw0yNzA5MjIxODE0MzFaMBoxGDAWBgNVBAMMD1p5blNpZ24gVGVzdCBFQzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKx2DChaQ9Dbr3sgRBniibJBjS/zdpcVVZGElRj07hLpHQgP528G1d4aloMgoMxpGpMTJrizole9LuWPBEjAFGajbzBtMAkGA1UdEwQCMAAwCwYDVR0PBAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBTX1M0dT4fMo4EbnT+fe6i/q1C4BDAfBgNVHSMEGDAWgBQvpO8OKFLtNam0Fagps8sNllnKgDANBgkqhkiG9w0BAQsFAAOCAQEAFGlDdk3pLKntxKzxgPKBbr3Jslt39YRaeiCwkN27AixgfD2/L52JDqzZzju85oI5yi+rHi9VLZfu3dJ76409XMB4LpqAnUlFixu/tZR5Kz2f+zE3O/sUDgszE4OSYqmV8MT/5ClTpz86EK2mRbZ4lPniYJBUh1KP8ls41xT9rfqf67OsAwc+nEMphBGNv1nIzydBhf/CVQB/vXiStnoQGiAm/W6kAuWUOGGFQTpIdp6CGZ4hGd3V5w7m7B1lsY9WaSSyTjMkHdIDyoFtcWe+fkgdrjVOiFok/ccxfrQ5DeEQdmHAMH+KPKNMqoElpczZ4DECZlRN9c2C05Z/t1ctXQ=="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode EC DER fixture")
        }
        return data
    }()

    /// A certificate whose subject is a single common name of one space.
    /// The organization is on the issuer, not the subject.
    static let unusualDER: Data = {
        let base64 = "MIIDCzCCAfOgAwIBAgICEAQwDQYJKoZIhvcNAQELBQAwNjEQMA4GA1UEAwwHVGVzdCBDQTEVMBMGA1UECgwMWnluU2lnbiBUZXN0MQswCQYDVQQGEwJVUzAeFw0yNjA5MjIxODE0MzFaFw0yNzA5MjIxODE0MzFaMAwxCjAIBgNVBAMMASAwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDBA6GX8MzKgvpMVgbyZUZaM9N60ijwvN45KGjXYWBi20cJxcXNGNSXYtFTL69TF2J32PVr35DiNOO0G/xLzpnnWAiUks9x285HLNEW6Tx+ZH1wvOu4etMMzVuFXINUt38EV5967e6adKFvJBOwpbtpz22zO0H+Tllouq+1LgEiSNBRc8DxWzkx2Tg1pJaRMPH9nDqdyQ3CaLGsMN6ie7Vf632V/FwLx8EuRw2qyYBngKxcwqkcZUJifgiG+wk7qt0UeKprgsx5f95Rv1jABzlsEnmih/jrJ9v/ePUd5J89Ga/Ohy9BHJK5F0vQAvGU7VjnBPDSI+gnMVwIWs4VWfvZAgMBAAGjTTBLMAkGA1UdEwQCMAAwHQYDVR0OBBYEFHImmAiLbAPSyZeB6OmGiw80MLGWMB8GA1UdIwQYMBaAFC+k7w4oUu01qbQVqCmzyw2WWcqAMA0GCSqGSIb3DQEBCwUAA4IBAQACAryollBrJTsy503XdHf8HhIUM8hIbUJydtuBeWIPS62HdDC7IeZqxY0+Hj+YhmKca1NIjJv9yZXO0WavRUluqHQMLce7z088R9ubK3ipP+qlhI9/AgDjk1d57S6bs4M2nmVLyt4xMoD3MJttq7MjChta3233zE9KXSaaKq9HpdXOaVvTtr6r5+k2ijFBS8IGiYqtqiu6z+/EbeGBmD7oCnOIY38kT+9fODnTrElrWsX158C99bcOkB5fyXMqWRQrCKdkw9gC0bj9qI11udcNH5+EnjtUySX9m8Uo0zahC1mvsQ8shscYOzvOl0ccZbWuP9gmaQQg98ExtzzzIXKG"
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode unusual DER fixture")
        }
        return data
    }()

    /// Malformed data that is not a certificate.
    static let malformedDER: Data = Data("not a certificate".utf8)

    /// Fixed non-certificate bytes. Not generated per run, so the failure is
    /// the same every time.
    static let randomDER: Data = Data((1...100).map { UInt8($0) })

    /// Empty data.
    static let emptyDER: Data = Data()

    /// A synthetic fingerprint for testing fingerprint validation.
    static let validFingerprintHex = "4aea4f8b88d249d4612ec2101efa985d75ab500640372e07ae82aa29c9c8c575"
    static let expiredFingerprintHex = "724a8650f739ed9a6dc45099cbe66b519c8a7c9c99132f99c0917e591d9debb4"

    // Synthetic public certificates. No private keys.
    /// Serial content is the single octet 0x07.
    static let shortSerialDER: Data = {
        let base64 = "MIIC/DCCAeSgAwIBAgIBBzANBgkqhkiG9w0BAQsFADAXMRUwEwYDVQQDDAxTaG9ydCBTZXJpYWwwHhcNMjYwOTIyMTg0MTI0WhcNMjYxMDIyMTg0MTI0WjAXMRUwEwYDVQQDDAxTaG9ydCBTZXJpYWwwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCP3MHwQAk+IT1RAWIAv4YzPEeytOMzD3zmK9nUVnxNypcSW/NNDLInL6/f6HElKTUZqd7g213KZZVOWHSqZOyIQgiHsSqSfzjjVYCckqxuzD7VewyzKBXK/7FHEfGotRvekZWuM05X4rlzrlu5XVkc+5r/wi91XyaNL1GpY4Tu1LUu+j5qp9NgAVWIuT8R2gh6RlMO10AAZF9qpDPyOSFSCVeO2zsfeRcpEUcqeOVJFGwo5w5L4RnProIvEboIsSsnZ4OLfZqLxC7sC/GPEspHgFyppmzTYv3XfmMNZg4zRaezPGgVkLhnYse4bJ6+1SaZayTQi4vrYF/e+YLlK+mzAgMBAAGjUzBRMB0GA1UdDgQWBBQC6crmWhBLFG4CJC8zXWdDoS86XTAfBgNVHSMEGDAWgBQC6crmWhBLFG4CJC8zXWdDoS86XTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAcCwYrSQ9W0wOHH9N2fIktr5zzNRY6XWDy8AXRJix1sQbSdUcwnueZZcIUbZbtK902bVBtDe2H2oSLWQcCHWSRiCWoNOlb4o+CF45iMzoyaTt2uenqelrRAlJ8CbDT6YgJZT4KULzXH2JGRZ3BjN+0XEggJsEtDDwUpfh9HhwGkSDs4xI6u8WhxTcF06dcq4MmpYSIFTQknNxv9rDtljs0cQbqDNorxHZTlSyX7d6EHG5mCUz65c4IgpOAa6k+lC5m6cbvJquwj0vFXb/h1LKM6KWlKnl1K+xrYMx1DrN/7kVCw2vk/RIIy6avcFzwC/NGkXe6nkaHP88YufTmiduv"
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode shortSerialDER fixture")
        }
        return data
    }()

    /// Serial INTEGER content is 0x00 0x80. The leading zero octet is significant.
    static let leadingZeroSerialDER: Data = {
        let base64 = "MIIDCzCCAfOgAwIBAgICAIAwDQYJKoZIhvcNAQELBQAwHjEcMBoGA1UEAwwTTGVhZGluZyBaZXJvIFNlcmlhbDAeFw0yNjA5MjIxODQxMjRaFw0yNjEwMjIxODQxMjRaMB4xHDAaBgNVBAMME0xlYWRpbmcgWmVybyBTZXJpYWwwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDwzSMi7rrRpb9Wx+RxJmrnz43fa4ATIsUwC7oKPNjpmVFBoaVEiX4iieF510Jky90e8fkKQ/66Y3MnjuGSRySgDilTcRFtyESRhv/akZXa/C05Fkf886Mik01MrquQiwRRvPMSyPoENyTLPelKU5tYljTyGDxMM9TE3UurKGN4lxUnceS6coMXSpSK0tLqQ/xi/RZ3p0I+jnm3LIrTcs67ShYC0uoqtc3wSVWWzOra6Hn5b3MAOGD0MEKCAEPRif8C9Ur+GY/yYJbzJ2qwbGQFQVh8Z4qrvbTSwmmMyGgjNf443o/YUDQBEz5yDHmuBSRa532Uwp0ROASj04nCn2xRAgMBAAGjUzBRMB0GA1UdDgQWBBSllF6QcNfGFisNmSAeSt+F1k4IJzAfBgNVHSMEGDAWgBSllF6QcNfGFisNmSAeSt+F1k4IJzAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQA047jWW3sGNvNKZ7eZqA4EBCgJ4flfVy4PitqT5HFhPJOEH/fSRzqmFZcKPhGha0e4xBscODxnPXjK5CYLSq7nOYrDIn8dGuLEqJoo1nsewbrkCv1wixNAc2+gd/gghEpnPGgfj0cAMgb4+Fl8HWCJXAT1nJBIQHhNS8EmKix3pfh5d+uCM3Vvt9BZMiCjbRwZUgRaFY2GvChsnfuQ+AAwUU6sHLRvTxNZkYs++vqZNAi8LH/bZnQL5Kr5Us6oWV+8ZZzyS3iFjTDonppw0qTlPHfaNQSNUMvZTiGEAhywz+idllsEIyrJ0Wi56rI6Er2ooMTJiqbyoKfNqnVq3x0b"
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode leadingZeroSerialDER fixture")
        }
        return data
    }()

    /// Serial is 20 octets, longer than a 64-bit integer.
    static let longSerialDER: Data = {
        let base64 = "MIIDDTCCAfWgAwIBAgIUAQIDBAUGBwgJCgsMDQ4PEBESExQwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLTG9uZyBTZXJpYWwwHhcNMjYwOTIyMTg0MTI1WhcNMjYxMDIyMTg0MTI1WjAWMRQwEgYDVQQDDAtMb25nIFNlcmlhbDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJ6qCxj/Ebe5u4nP+FjRDE7WtuUeuEawTQhyLnrSYFuD7UescjET+kmlRRxvB+HlMOK4/xX3KF6u0YTZX+6mY16AnN/oZXv66njK5hK+Ia1aEJALvrBzqn77FyF40nOmnaUsZ2K9qJIGdwUCi6QtaEPj3iMADX1I3hTi/XwlNqBBdiRKEFw1/CThG8r7jXT0G91yWULq12NLYKEgVsLAnvdRikqgn9pY1tmLIB4WFfJiWOyu/pws0mK2281WZhuC7htPCJxgTGadvJSlparjagohjh/TMMMFmgzaEFutGBPuGk20wJ3Xs6FdCKn/3kUXbRTN4bdGzTrZYkOo5fcROCcCAwEAAaNTMFEwHQYDVR0OBBYEFN7rmM78EmXf6/1vMCH76V9wBP7yMB8GA1UdIwQYMBaAFN7rmM78EmXf6/1vMCH76V9wBP7yMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAGOA9KCMdCfUgt7jlB2GVmNusJRN7IowTNCs8GOOUBJ8PvyIGcdR58Ti6hQM7jIzMsH2YOlqfmHo/o3EOPamz+KZoOOrC4TcDx5WZMkNX60KM9r6E6weKzt80jZ1+nHdUmbbVtnTeRxvgL0NieHtgo50VubRZOJUrob6p9gtDcM+zN1xMvXNJDSYQo50w8867VAVL+mUSceSYkVXlub85rF3kgc0as1KPzQ+uRocogIYMNkKCB2YZPTa/CO+fMwh0Rgdr8Dmpf6K40L72UHfx/944HNu+9C11ApHPzxM/+wHRxluL9dDVpnBIWj9zpugGKZ3P+pyjHLSkC4c9wC6iac="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode longSerialDER fixture")
        }
        return data
    }()

    /// Subject carries C, ST, L, O, two OU values, CN, and an email address.
    static let multiAttributeDER: Data = {
        let base64 = "MIIEQDCCAyigAwIBAgIBETANBgkqhkiG9w0BAQsFADCBuDELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExEjAQBgNVBAcMCUN1cGVydGlubzEZMBcGA1UECgwQWnluU2lnbiBUZXN0IE9yZzESMBAGA1UECwwJVGVzdCBVbml0MRQwEgYDVQQLDAtTZWNvbmQgVW5pdDEWMBQGA1UEAwwNWnluU2lnbiBNdWx0aTEjMCEGCSqGSIb3DQEJARYUdGVzdEBleGFtcGxlLmludmFsaWQwHhcNMjYwOTIyMTg0MTI1WhcNMjYxMDIyMTg0MTI1WjCBuDELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExEjAQBgNVBAcMCUN1cGVydGlubzEZMBcGA1UECgwQWnluU2lnbiBUZXN0IE9yZzESMBAGA1UECwwJVGVzdCBVbml0MRQwEgYDVQQLDAtTZWNvbmQgVW5pdDEWMBQGA1UEAwwNWnluU2lnbiBNdWx0aTEjMCEGCSqGSIb3DQEJARYUdGVzdEBleGFtcGxlLmludmFsaWQwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCT/QlciiBlkImHT5iU0Hu+H6DiPH/CY/A9T910kaQAR5Rpyo/YMBP6Z297uKbKsPDeiseGkyBDKSqjTSfO2KFsHp0Asjm5Xy6MEB7Ote3oeH7Dh0c1Uc/TyLabouvBuJFaRguh097Kx7Rzz/BdRabbjzCetfQI+8agDGQY2TLXBZPi8LrY4g3gTJ4W4qI6fpKTmwgFjTED26DkdqK2Y2YYJrlcZqc27JCawF0klnNUnSaimKQxWnauHP7RFhLsDXPqN8n+XI4NDSCL/d2tnpzEf66RzQY9g79yKXQmHfS5THIs9xx2akvO2IbxRgWDma5bL7TXc2gndcWECKV1lLCHAgMBAAGjUzBRMB0GA1UdDgQWBBTnG17yee7ZbB87nhTcpZAx1hQADTAfBgNVHSMEGDAWgBTnG17yee7ZbB87nhTcpZAx1hQADTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQA4Grg7DlBKJvDK+72iLooxcZ9AtHOD1caScWX1NnYxnaKVqMjgN76lq/VvTwIqC6Y3fS2ygk5iPqohkqm6ljw7uXpiy5TxH6gz1qkvH0TeqI2rMl2Ql/GZBLVsZY5YEasUIbvl1Zmsv044CDdvFhn4Z9SlZoXQDBoJe81JRo+mDGyjGXmGZcSW3adDkdYQl1NULYqhab1KhyZGRPhv8e52t3pHxz5NKhIuCuK7k8EL/4PWy6NdgOO4cBuLeL6xbrx+p4Cif2WHC/8Brq/X3kjHagrJLwcDLXc3XfNn4x5NCyWSYN0GU96KYJKfwQrrbd+Y095qObkQX6N7RrMuDgQl"
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode multiAttributeDER fixture")
        }
        return data
    }()

    /// Version 1 certificate with an unrecognised name attribute. The attribute is preserved.
    static let unknownAttributeDER: Data = {
        let base64 = "MIIDNjCCAh4CASEwDQYJKoZIhvcNAQELBQAwYTEiMCAGA1UEAwwZWnluU2lnbiBVbmtub3duIEF0dHJpYnV0ZTEZMBcGA1UECgwQWnluU2lnbiBUZXN0IE9yZzEgMB4GCSsGAQQBho0fAQwRcHJlc2VydmVkLXVua25vd24wHhcNMjYwOTIyMTg0MjA0WhcNMjYxMDIyMTg0MjA0WjBhMSIwIAYDVQQDDBlaeW5TaWduIFVua25vd24gQXR0cmlidXRlMRkwFwYDVQQKDBBaeW5TaWduIFRlc3QgT3JnMSAwHgYJKwYBBAGGjR8BDBFwcmVzZXJ2ZWQtdW5rbm93bjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAL9HxDmCMdCjd63M1zUax0DSL+L7UNDxZHpe3fG/N9Vj9I5q3jubpvhomCWEL2tv/dPLX6xjEcfSimoe+Wgs9uLmcTuYA8niR7ZtcaLz3zG+ji5QE4aPqHI3dy7W060uAGd86TM4Pcbp4MdOmw2i3ymIZTrYNKhSTSe0gvz7PgI/M4JyGo1/5KVlk6bDhTrQ2U3HcoHBXFKiMSt1B6cPh2pgrAP3MgEzn58i9dduzbPsURwd/6uswNWA4MJcUrYjVUNOiKdedggBb455u0JD1i/kcLh5EaHEqyBcUFfKOZ4U/PkB+j55JuLA7L/E0D+bElUAHbcMS1t49ZDlJuwcfxkCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAbFcOm8sVT7LAq0cfkxnC0qqxfWBZNXLmf7VTIg95jITXA+c1cUCvqw0Co3Tlod86Y77l0XMTvrxd6NssCthEopjqWBoNC0IcOGoaINL9bcJTlejlZCwj6ibHurp8Ioe3P6S0LWw+L7ZcZ0J1GvJJNmupqM0JDnn6uk9SZ2sqVNLLbhcuvp+Ar83RUhFykFI1GqO7YbQYE551c0bHg3LquNtOHxtF6Q9V9Hs/j3BVikkNE69sbJy7sq7q43Ial1CGyVo51uZOpp0vaXjc2UejFhfCFoZX6tmfcS+4O8rxZ0UUCaE8gmDLi7tGJvjd/bajhLJ/WvJp7ZRVZpFzrbBMPw=="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode unknownAttributeDER fixture")
        }
        return data
    }()

    /// Signature algorithm ecdsa-with-SHA256 and a P-256 public key.
    static let ecdsaDER: Data = {
        let base64 = "MIIBbzCCARSgAwIBAgIBIjAKBggqhkjOPQQDAjAWMRQwEgYDVQQDDAtFQ0RTQSBQLTI1NjAeFw0yNjA5MjIxODQyMDRaFw0yNjEwMjIxODQyMDRaMBYxFDASBgNVBAMMC0VDRFNBIFAtMjU2MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDZYep75jRSGNA+UTDvxHTNPh3DCeVaXlHau+YxKJ+YPrCi/le9/aCQSoPCpgJ61egs0Kj1+LUq4wkizsuKW1i6NTMFEwHQYDVR0OBBYEFGxLAWPNerA5tOrxtcpxc1fpn1c+MB8GA1UdIwQYMBaAFGxLAWPNerA5tOrxtcpxc1fpn1c+MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIhAKbLKjKDJRIBBVPG/eit18bHPH+MJ5/8WMvpxpGx6vTNAiEA4f+aRBruHEdvjngWXnZ+VjKM5LOpsHsddWEu7qwoNYs="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode ecdsaDER fixture")
        }
        return data
    }()

    /// Ed25519 signature and key. Parsing must not reject the certificate.
    static let ed25519DER: Data = {
        let base64 = "MIIBLzCB4qADAgECAgEjMAUGAytlcDAXMRUwEwYDVQQDDAxFZDI1NTE5IExlYWYwHhcNMjYwOTIyMTg0MjA0WhcNMjYxMDIyMTg0MjA0WjAXMRUwEwYDVQQDDAxFZDI1NTE5IExlYWYwKjAFBgMrZXADIQC8guhzLoLr6cNnkPpeykNgovVQlGmJAyMns6VFIgRlZKNTMFEwHQYDVR0OBBYEFMW7FK8o8hQJDdgsK9EAQSMDy030MB8GA1UdIwQYMBaAFMW7FK8o8hQJDdgsK9EAQSMDy030MA8GA1UdEwEB/wQFMAMBAf8wBQYDK2VwA0EA6ckeEg69qX6k2qFOwDbRKorrLorXa3l6H0s2TOgaK8DjrgqitnON59y4U8htEvA5KnB9xY4QYicusKfYEtHqAQ=="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode ed25519DER fixture")
        }
        return data
    }()

    /// Validity uses GeneralizedTime, including a fractional second. The RSA modulus is the octet 0x80.
    static let generalizedTimeDER: Data = {
        let base64 = "MIGqMIGUoAMCAQICASowDQYJKoZIhvcNAQELBQAwGzEZMBcGA1UEAwwQR2VuZXJhbGl6ZWQgVGltZTAkGA8yMDUwMDEwMTAwMDAwMFoYETIwNTEwMTAxMDAwMDAwLjVaMBsxGTAXBgNVBAMMEEdlbmVyYWxpemVkIFRpbWUwGzANBgkqhkiG9w0BAQEFAAMKADAHAgIAgAIBAzANBgkqhkiG9w0BAQsFAAMCABE="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode generalizedTimeDER fixture")
        }
        return data
    }()

    /// Signature algorithm OID 1.2.840.113549.1.1.99. The public key remains RSA.
    static let unknownSignatureDER: Data = {
        let base64 = "MIIC/DCCAeSgAwIBAgIBBzANBgkqhkiG9w0BAWMFADAXMRUwEwYDVQQDDAxTaG9ydCBTZXJpYWwwHhcNMjYwOTIyMTg0MTI0WhcNMjYxMDIyMTg0MTI0WjAXMRUwEwYDVQQDDAxTaG9ydCBTZXJpYWwwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCP3MHwQAk+IT1RAWIAv4YzPEeytOMzD3zmK9nUVnxNypcSW/NNDLInL6/f6HElKTUZqd7g213KZZVOWHSqZOyIQgiHsSqSfzjjVYCckqxuzD7VewyzKBXK/7FHEfGotRvekZWuM05X4rlzrlu5XVkc+5r/wi91XyaNL1GpY4Tu1LUu+j5qp9NgAVWIuT8R2gh6RlMO10AAZF9qpDPyOSFSCVeO2zsfeRcpEUcqeOVJFGwo5w5L4RnProIvEboIsSsnZ4OLfZqLxC7sC/GPEspHgFyppmzTYv3XfmMNZg4zRaezPGgVkLhnYse4bJ6+1SaZayTQi4vrYF/e+YLlK+mzAgMBAAGjUzBRMB0GA1UdDgQWBBQC6crmWhBLFG4CJC8zXWdDoS86XTAfBgNVHSMEGDAWgBQC6crmWhBLFG4CJC8zXWdDoS86XTAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBYwUAA4IBAQAcCwYrSQ9W0wOHH9N2fIktr5zzNRY6XWDy8AXRJix1sQbSdUcwnueZZcIUbZbtK902bVBtDe2H2oSLWQcCHWSRiCWoNOlb4o+CF45iMzoyaTt2uenqelrRAlJ8CbDT6YgJZT4KULzXH2JGRZ3BjN+0XEggJsEtDDwUpfh9HhwGkSDs4xI6u8WhxTcF06dcq4MmpYSIFTQknNxv9rDtljs0cQbqDNorxHZTlSyX7d6EHG5mCUz65c4IgpOAa6k+lC5m6cbvJquwj0vFXb/h1LKM6KWlKnl1K+xrYMx1DrN/7kVCw2vk/RIIy6avcFzwC/NGkXe6nkaHP88YufTmiduv"
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode unknownSignatureDER fixture")
        }
        return data
    }()

}
