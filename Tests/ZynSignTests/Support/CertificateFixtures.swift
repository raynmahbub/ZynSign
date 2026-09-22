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

    /// A valid, currently valid RSA 2048 certificate, self-signed via test CA.
    /// Subject: CN=ZynSign Test Valid, O=ZynSign Test Org, OU=Test Unit, C=US
    /// Validity: 2026-09-22 to 2027-09-22 (currently valid at time of generation)
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

    /// An EC P-256 certificate.
    static let ecDER: Data = {
        let base64 = "MIICcDCCAVigAwIBAgICEAMwDQYJKoZIhvcNAQELBQAwNjEQMA4GA1UEAwwHVGVzdCBDQTEVMBMGA1UECgwMWnluU2lnbiBUZXN0MQswCQYDVQQGEwJVUzAeFw0yNjA5MjIxODE0MzFaFw0yNzA5MjIxODE0MzFaMBoxGDAWBgNVBAMMD1p5blNpZ24gVGVzdCBFQzBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABKx2DChaQ9Dbr3sgRBniibJBjS/zdpcVVZGElRj07hLpHQgP528G1d4aloMgoMxpGpMTJrizole9LuWPBEjAFGajbzBtMAkGA1UdEwQCMAAwCwYDVR0PBAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBTX1M0dT4fMo4EbnT+fe6i/q1C4BDAfBgNVHSMEGDAWgBQvpO8OKFLtNam0Fagps8sNllnKgDANBgkqhkiG9w0BAQsFAAOCAQEAFGlDdk3pLKntxKzxgPKBbr3Jslt39YRaeiCwkN27AixgfD2/L52JDqzZzju85oI5yi+rHi9VLZfu3dJ76409XMB4LpqAnUlFixu/tZR5Kz2f+zE3O/sUDgszE4OSYqmV8MT/5ClTpz86EK2mRbZ4lPniYJBUh1KP8ls41xT9rfqf67OsAwc+nEMphBGNv1nIzydBhf/CVQB/vXiStnoQGiAm/W6kAuWUOGGFQTpIdp6CGZ4hGd3V5w7m7B1lsY9WaSSyTjMkHdIDyoFtcWe+fkgdrjVOiFok/ccxfrQ5DeEQdmHAMH+KPKNMqoElpczZ4DECZlRN9c2C05Z/t1ctXQ=="
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode EC DER fixture")
        }
        return data
    }()

    /// A certificate with unusual subject (space as CN).
    static let unusualDER: Data = {
        let base64 = "MIIDCzCCAfOgAwIBAgICEAQwDQYJKoZIhvcNAQELBQAwNjEQMA4GA1UEAwwHVGVzdCBDQTEVMBMGA1UECgwMWnluU2lnbiBUZXN0MQswCQYDVQQGEwJVUzAeFw0yNjA5MjIxODE0MzFaFw0yNzA5MjIxODE0MzFaMAwxCjAIBgNVBAMMASAwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDBA6GX8MzKgvpMVgbyZUZaM9N60ijwvN45KGjXYWBi20cJxcXNGNSXYtFTL69TF2J32PVr35DiNOO0G/xLzpnnWAiUks9x285HLNEW6Tx+ZH1wvOu4etMMzVuFXINUt38EV5967e6adKFvJBOwpbtpz22zO0H+Tllouq+1LgEiSNBRc8DxWzkx2Tg1pJaRMPH9nDqdyQ3CaLGsMN6ie7Vf632V/FwLx8EuRw2qyYBngKxcwqkcZUJifgiG+wk7qt0UeKprgsx5f95Rv1jABzlsEnmih/jrJ9v/ePUd5J89Ga/Ohy9BHJK5F0vQAvGU7VjnBPDSI+gnMVwIWs4VWfvZAgMBAAGjTTBLMAkGA1UdEwQCMAAwHQYDVR0OBBYEFHImmAiLbAPSyZeB6OmGiw80MLGWMB8GA1UdIwQYMBaAFC+k7w4oUu01qbQVqCmzyw2WWcqAMA0GCSqGSIb3DQEBCwUAA4IBAQACAryollBrJTsy503XdHf8HhIUM8hIbUJydtuBeWIPS62HdDC7IeZqxY0+Hj+YhmKca1NIjJv9yZXO0WavRUluqHQMLce7z088R9ubK3ipP+qlhI9/AgDjk1d57S6bs4M2nmVLyt4xMoD3MJttq7MjChta3233zE9KXSaaKq9HpdXOaVvTtr6r5+k2ijFBS8IGiYqtqiu6z+/EbeGBmD7oCnOIY38kT+9fODnTrElrWsX158C99bcOkB5fyXMqWRQrCKdkw9gC0bj9qI11udcNH5+EnjtUySX9m8Uo0zahC1mvsQ8shscYOzvOl0ccZbWuP9gmaQQg98ExtzzzIXKG"
        guard let data = Data(base64Encoded: base64) else {
            fatalError("Failed to decode unusual DER fixture")
        }
        return data
    }()

    /// Malformed data that is not a certificate.
    static let malformedDER: Data = Data("not a certificate".utf8)

    /// Random bytes, not a certificate.
    static let randomDER: Data = Data((0..<100).map { _ in UInt8.random(in: 0...255) })

    /// Empty data.
    static let emptyDER: Data = Data()

    /// A synthetic fingerprint for testing fingerprint validation.
    static let validFingerprintHex = "4aea4f8b88d249d4612ec2101efa985d75ab500640372e07ae82aa29c9c8c575"
    static let expiredFingerprintHex = "724a8650f739ed9a6dc45099cbe66b519c8a7c9c99132f99c0917e591d9debb4"
}
