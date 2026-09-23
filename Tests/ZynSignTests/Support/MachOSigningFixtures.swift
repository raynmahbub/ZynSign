import Foundation

/// Public, synthetic single-image vector independently assembled and signed
/// on a host. The ephemeral RSA key was never serialized or retained.
/// No trust, Apple issuance, executable behavior, or platform acceptance.
enum MachOSigningFixtures {
    static let unsignedMachO: Data = decode("""
        z/rt/gwAAAEAAAAAAgAAAAIAAADgAAAAIAAAAAAAAAAZAAAAmAAAAF9fVEVYVAAAAAAAAAAAAAAAAAAAAQAAAAAQAAAAAAAAAAAA
        AAAAAAAAEAAAAAAAAAcAAAAFAAAAAQAAAAAAAABfX3RleHQAAAAAAAAAAAAAX19URVhUAAAAAAAAAAAAAAACAAABAAAAAA4AAAAA
        AAAAAgAAAgAAAAAAAAAAAAAAAAQAgAAAAAAAAAAAAAAAABkAAABIAAAAX19MSU5LRURJVAAAAAAAAAAQAAABAAAAABAAAAAAAAAA
        EAAAAAAAACMAAAAAAAAABwAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAClpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpTw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8
        PDw8PDw8
        """)

    static let certificateDER: Data = decode("""
        MIICwTCCAamgAwIBAgIBGjANBgkqhkiG9w0BAQsFADAkMSIwIAYDVQQDDBlaeW5TaWduIFNpbmdsZSBJbWFnZSBUZXN0MB4XDTI2
        MDEwMTAwMDAwMFoXDTI3MDEwMTAwMDAwMFowJDEiMCAGA1UEAwwZWnluU2lnbiBTaW5nbGUgSW1hZ2UgVGVzdDCCASIwDQYJKoZI
        hvcNAQEBBQADggEPADCCAQoCggEBALufQ8l9c4yOc3Jt9oF1RHeBWDk8m+yvFG3cUzKNdhUU+JlIijfDrmZsvyhSWhIpelnW/IrK
        p2fq7RHGa82w1HkmUw7rOSLW8Iz54Qa/oZFr1UA81qY231GPCCrrCA3N0eqSsic8nLjUfNUooZD6YQC6PsvyZpKdMqM6s4TCWQYj
        FXONJtfKsxQX8U5eq5vTiNrn/LFWF/QSKn2qg3BXo1zIXQwM/z/LHebqVp9AboG1RLOIeCamJTLQIsZrw9eDB4T+sAbn8otJVT8L
        HLYEkEl+LyYGT4a8p/1yB9I5vo9lYnn8/GwI+Cd9wUFH8UTvRThzcDg/Nve3kZDK1LtU0JsCAwEAATANBgkqhkiG9w0BAQsFAAOC
        AQEADI9UuwP7ZUN6eizLy9w93EEmCcMS7VbG7UqOAgVX5cjisZEUCq5We+HW6w/mPghNCjEZRiY43q878/Y0QLoS9KHN1ORSePK/
        V3yCkIFnYZYbCXYO0/XiQs1+AbyXGX20xCRaXyGpNCVj3+dJOgIBfbM7zwWvsRyJiXPvwY/FSlBE6XW4gvxwP/5eg4+rQiQR/GV7
        EkvlhAKUki/9XRFTeeHApJSSEGxcyka4Sv+ogptrX212MWtBd4sE+cq6eik4Z2KrYu+jEj8dUUYq9288kcWsNNfqK5pzhp38hhLk
        fyjaBl3KguVXkMeUaEO9XuvGFRvcsOZY0eU60XgbupnxVA==
        """)

    static let expectedSignedMachO: Data = decode("""
        z/rt/gwAAAEAAAAAAgAAAAMAAADwAAAAIAAAAAAAAAAZAAAAmAAAAF9fVEVYVAAAAAAAAAAAAAAAAAAAAQAAAAAQAAAAAAAAAAAA
        AAAAAAAAEAAAAAAAAAcAAAAFAAAAAQAAAAAAAABfX3RleHQAAAAAAAAAAAAAX19URVhUAAAAAAAAAAAAAAACAAABAAAAAA4AAAAA
        AAAAAgAAAgAAAAAAAAAAAAAAAAQAgAAAAAAAAAAAAAAAABkAAABIAAAAX19MSU5LRURJVAAAAAAAAAAQAAABAAAAABAAAAAAAAAA
        EAAAAAAAAJAFAAAAAAAABwAAAAEAAAAAAAAAAAAAAB0AAAAQAAAAMBAAAGAFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAClpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl
        paWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpTw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8PDw8
        PDw8PDw8AAAAAAAAAAAAAAAAAPreDMAAAAVWAAAAAgAAAAAAAAAcAAEAAAAAAKz63gwCAAAAkAACAgAAAAAAAAAAUAAAADQAAAAA
        AAAAAgAAEDAgAgAMAAAAAAAAAAAAAABHY29tLmV4YW1wbGUuc2luZ2xlAFRFU1RURUFNAN3YFTOuOIdMP7+2WrltjkwMswybl1Rm
        uoQj0rIHcjdL/oUgKWxN7DA3OWwEmmA214qz8jxM5zKadFRE7n+Kaoj63gsBAAAEqjCCBJ4GCSqGSIb3DQEHAqCCBI8wggSLAgEB
        MQ0wCwYJYIZIAWUDBAIBMAsGCSqGSIb3DQEHAaCCAsUwggLBMIIBqaADAgECAgEaMA0GCSqGSIb3DQEBCwUAMCQxIjAgBgNVBAMM
        GVp5blNpZ24gU2luZ2xlIEltYWdlIFRlc3QwHhcNMjYwMTAxMDAwMDAwWhcNMjcwMTAxMDAwMDAwWjAkMSIwIAYDVQQDDBlaeW5T
        aWduIFNpbmdsZSBJbWFnZSBUZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAu59DyX1zjI5zcm32gXVEd4FYOTyb
        7K8UbdxTMo12FRT4mUiKN8OuZmy/KFJaEil6Wdb8isqnZ+rtEcZrzbDUeSZTDus5ItbwjPnhBr+hkWvVQDzWpjbfUY8IKusIDc3R
        6pKyJzycuNR81SihkPphALo+y/Jmkp0yozqzhMJZBiMVc40m18qzFBfxTl6rm9OI2uf8sVYX9BIqfaqDcFejXMhdDAz/P8sd5upW
        n0BugbVEs4h4JqYlMtAixmvD14MHhP6wBufyi0lVPwsctgSQSX4vJgZPhryn/XIH0jm+j2Viefz8bAj4J33BQUfxRO9FOHNwOD82
        97eRkMrUu1TQmwIDAQABMA0GCSqGSIb3DQEBCwUAA4IBAQAMj1S7A/tlQ3p6LMvL3D3cQSYJwxLtVsbtSo4CBVflyOKxkRQKrlZ7
        4dbrD+Y+CE0KMRlGJjjerzvz9jRAuhL0oc3U5FJ48r9XfIKQgWdhlhsJdg7T9eJCzX4BvJcZfbTEJFpfIak0JWPf50k6AgF9szvP
        Ba+xHImJc+/Bj8VKUETpdbiC/HA//l6Dj6tCJBH8ZXsSS+WEApSSL/1dEVN54cCklJIQbFzKRrhK/6iCm2tfbXYxa0F3iwT5yrp6
        KThnYqti76MSPx1RRir3bzyRxaw01+ormnOGnfyGEuR/KNoGXcqC5VeQx5RoQ71e68YVG9yw5ljR5TrReBu6mfFUMYIBnzCCAZsC
        AQEwKTAkMSIwIAYDVQQDDBlaeW5TaWduIFNpbmdsZSBJbWFnZSBUZXN0AgEaMAsGCWCGSAFlAwQCAaBLMBgGCSqGSIb3DQEJAzEL
        BgkqhkiG9w0BBwEwLwYJKoZIhvcNAQkEMSIEIHDfrXZw8InSUo8E1vrFlNsPVZN9zbjg7oBvdZVVm8KCMA0GCSqGSIb3DQEBCwUA
        BIIBALghCKD6eXHgGtSYTnlmORyxwcZ9rXuN0Ss7tFSAa9Xg44lGV3lofeCdXSPaqxB0Vy9xD01eh7dlXg0szhJhB+p00kpc9PLQ
        1lGceDwfZgGZrdko0qEGwR5ZAWUCqonxQamceYd9iil7mppL+9KUY3Ego7AJFH/zglcuYKgBwAMNNTQtZUpnJ3Cv0+cmCjlX/NaR
        4LHY87HdfZ8CmLU1XF267SDDNcIixv8g+EMoQwanbUh/evxar7F5/e/wqtWDQ1S9JAnoFRu61mXI44Syw54wQtjCJ26H/dk6DtUq
        19pRawBTpnOcXfDdLpPHHoLa8e7/HS30M9FJKIne2MACP6sAAAAAAAAAAAAA
        """)

    static let codeDirectory: Data = decode("""
        +t4MAgAAAJAAAgIAAAAAAAAAAFAAAAA0AAAAAAAAAAIAABAwIAIADAAAAAAAAAAAAAAAR2NvbS5leGFtcGxlLnNpbmdsZQBURVNU
        VEVBTQDd2BUzrjiHTD+/tlq5bY5MDLMMm5dUZrqEI9KyB3I3S/6FIClsTewwNzlsBJpgNteKs/I8TOcymnRURO5/imqI
        """)

    static let cms: Data = decode("""
        MIIEngYJKoZIhvcNAQcCoIIEjzCCBIsCAQExDTALBglghkgBZQMEAgEwCwYJKoZIhvcNAQcBoIICxTCCAsEwggGpoAMCAQICARow
        DQYJKoZIhvcNAQELBQAwJDEiMCAGA1UEAwwZWnluU2lnbiBTaW5nbGUgSW1hZ2UgVGVzdDAeFw0yNjAxMDEwMDAwMDBaFw0yNzAx
        MDEwMDAwMDBaMCQxIjAgBgNVBAMMGVp5blNpZ24gU2luZ2xlIEltYWdlIFRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEK
        AoIBAQC7n0PJfXOMjnNybfaBdUR3gVg5PJvsrxRt3FMyjXYVFPiZSIo3w65mbL8oUloSKXpZ1vyKyqdn6u0RxmvNsNR5JlMO6zki
        1vCM+eEGv6GRa9VAPNamNt9Rjwgq6wgNzdHqkrInPJy41HzVKKGQ+mEAuj7L8maSnTKjOrOEwlkGIxVzjSbXyrMUF/FOXqub04ja
        5/yxVhf0Eip9qoNwV6NcyF0MDP8/yx3m6lafQG6BtUSziHgmpiUy0CLGa8PXgweE/rAG5/KLSVU/Cxy2BJBJfi8mBk+GvKf9cgfS
        Ob6PZWJ5/PxsCPgnfcFBR/FE70U4c3A4Pzb3t5GQytS7VNCbAgMBAAEwDQYJKoZIhvcNAQELBQADggEBAAyPVLsD+2VDenosy8vc
        PdxBJgnDEu1Wxu1KjgIFV+XI4rGRFAquVnvh1usP5j4ITQoxGUYmON6vO/P2NEC6EvShzdTkUnjyv1d8gpCBZ2GWGwl2DtP14kLN
        fgG8lxl9tMQkWl8hqTQlY9/nSToCAX2zO88Fr7EciYlz78GPxUpQROl1uIL8cD/+XoOPq0IkEfxlexJL5YQClJIv/V0RU3nhwKSU
        khBsXMpGuEr/qIKba19tdjFrQXeLBPnKunopOGdiq2LvoxI/HVFGKvdvPJHFrDTX6iuac4ad/IYS5H8o2gZdyoLlV5DHlGhDvV7r
        xhUb3LDmWNHlOtF4G7qZ8VQxggGfMIIBmwIBATApMCQxIjAgBgNVBAMMGVp5blNpZ24gU2luZ2xlIEltYWdlIFRlc3QCARowCwYJ
        YIZIAWUDBAIBoEswGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAvBgkqhkiG9w0BCQQxIgQgcN+tdnDwidJSjwTW+sWU2w9Vk33N
        uODugG91lVWbwoIwDQYJKoZIhvcNAQELBQAEggEAuCEIoPp5ceAa1JhOeWY5HLHBxn2te43RKzu0VIBr1eDjiUZXeWh94J1dI9qr
        EHRXL3EPTV6Ht2VeDSzOEmEH6nTSSlz08tDWUZx4PB9mAZmt2SjSoQbBHlkBZQKqifFBqZx5h32KKXuamkv70pRjcSCjsAkUf/OC
        Vy5gqAHAAw01NC1lSmcncK/T5yYKOVf81pHgsdjzsd19nwKYtTVcXbrtIMM1wiLG/yD4QyhDBqdtSH96/FqvsXn97/Cq1YNDVL0k
        CegVG7rWZcjjhLLDnjBC2MInbof92ToO1SrX2lFrAFOmc5xd8N0uk8cegtrx7v8dLfQz0Ukoid7YwAI/qw==
        """)

    static let signature: Data = decode("""
        uCEIoPp5ceAa1JhOeWY5HLHBxn2te43RKzu0VIBr1eDjiUZXeWh94J1dI9qrEHRXL3EPTV6Ht2VeDSzOEmEH6nTSSlz08tDWUZx4
        PB9mAZmt2SjSoQbBHlkBZQKqifFBqZx5h32KKXuamkv70pRjcSCjsAkUf/OCVy5gqAHAAw01NC1lSmcncK/T5yYKOVf81pHgsdjz
        sd19nwKYtTVcXbrtIMM1wiLG/yD4QyhDBqdtSH96/FqvsXn97/Cq1YNDVL0kCegVG7rWZcjjhLLDnjBC2MInbof92ToO1SrX2lFr
        AFOmc5xd8N0uk8cegtrx7v8dLfQz0Ukoid7YwAI/qw==
        """)

    static let signingDigest: Data = decode("""
        OSnbvDh+WqAYOIlSF4Eqa5Tw3F9NiC5sWDm+wVuT/JU=
        """)

    private static func decode(_ text: String) -> Data {
        guard let bytes = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
            preconditionFailure("Invalid public signing fixture")
        }
        return bytes
    }
}
