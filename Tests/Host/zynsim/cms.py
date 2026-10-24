"""Detached CMS ``SignedData`` for code signatures, and verification of one.

Apple's detached signature is not a generic PKCS#7 file. It is a blob whose
content is a CMS ``SignedData`` with:

* the content absent (``id-data``, detached), because the content is the
  CodeDirectory and the CodeDirectory is hashed by the CodeDirectory itself;
* one signed attribute set carrying ``content-type`` and ``message-digest``,
  where the digest is SHA-256 of the CodeDirectory bytes — the same digest the
  CodeDirectory announces in its ``hashType`` field;
* the signing certificate (and any intermediates the caller has);
* the signature over the DER encoding of that attribute set, not over the
  content.

This module builds exactly that, signs with the host ``openssl`` binary, and
verifies with ``openssl cms -verify -noverify`` so the suite's evidence is
produced by an implementation that shares no code with this one.
"""

from __future__ import annotations

import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from . import der

OID_DATA = "1.2.840.113549.1.7.1"
OID_SIGNED_DATA = "1.2.840.113549.1.7.2"
OID_CONTENT_TYPE = "1.2.840.113549.1.9.3"
OID_MESSAGE_DIGEST = "1.2.840.113549.1.9.4"
OID_SHA256 = "2.16.840.1.101.3.4.2.1"
OID_RSA_ENCRYPTION = "1.2.840.113549.1.1.1"


class CMSError(ValueError):
    """The CMS structure could not be built or did not verify."""


def _sha256_algorithm() -> bytes:
    return der.sequence(der.oid(OID_SHA256), der.null())


def _rsa_algorithm() -> bytes:
    return der.sequence(der.oid(OID_RSA_ENCRYPTION), der.null())


@dataclass(frozen=True)
class CertificateIdentity:
    """The public half of a signing identity plus where its key lives.

    ``intermediates`` are the CA certificates between the leaf and the trust
    anchor. A device has the Apple root; it does not have your developer
    intermediate, so a CMS blob that omits it fails verification on a phone
    while passing against a capture of the leaf alone. They travel with the
    identity, not with each call site.
    """

    der_bytes: bytes
    key_path: Path | None = None
    intermediates: tuple[bytes, ...] = ()

    def _tbs_name_and_serial(self) -> tuple[bytes, bytes]:
        """The issuer ``Name`` and the serial number, both DER encoded.

        ``children`` are parsed from the ``tbsCertificate`` value, so their
        offsets are relative to that value — slice ``tbs.raw``, not the
        certificate. Certificate fields must appear in this order: version
        (optional), serial, signature, issuer.
        """
        certificate = der.read(self.der_bytes)
        tbs = certificate.child(0)
        tbs_bytes = tbs.raw
        children = tbs.children()
        serial_index = next(i for i, node in enumerate(children) if node.tag == der.INTEGER)
        serial = children[serial_index]
        issuer = children[serial_index + 2]
        return tbs_bytes[issuer.start:issuer.end], tbs_bytes[serial.start:serial.end]

    @property
    def issuer(self) -> bytes:
        return self._tbs_name_and_serial()[0]

    @property
    def serial(self) -> bytes:
        return self._tbs_name_and_serial()[1]

    @property
    def signature_size(self) -> int:
        """Length of this key's signature — the RSA modulus width in bytes."""
        certificate = der.read(self.der_bytes)
        tbs = certificate.child(0)
        children = tbs.children()
        spki = [node for node in children if node.tag == der.SEQUENCE][-1]
        bit_string = spki.child(1)
        # The first octet of a BIT STRING counts unused trailing bits.
        key = der.read(bit_string.raw, 1)
        modulus = key.child(0).raw.lstrip(b"\x00")
        return len(modulus)

    def sign(self, payload: bytes) -> bytes:
        if self.key_path is None:
            raise CMSError("this certificate has no private key on disk")
        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(self.key_path)],
            input=payload, capture_output=True, check=False,
        )
        if result.returncode != 0:
            raise CMSError(f"openssl could not sign: {result.stderr.decode(errors='replace').strip()}")
        signature = result.stdout
        if len(signature) != self.signature_size:
            raise CMSError("the signer produced a signature of an unexpected length")
        return signature


def _attribute_set(content_digest: bytes) -> tuple[bytes, bytes]:
    """Return the signed attributes twice: as a SET and with an implicit tag.

    The signature covers the SET encoding; the same attributes appear inside
    ``SignerInfo`` under context tag 0, which changes only the outer tag. Both
    forms share one body.
    """
    content_type = der.sequence(der.oid(OID_CONTENT_TYPE), der.set_of(der.oid(OID_DATA)))
    message_digest = der.sequence(
        der.oid(OID_MESSAGE_DIGEST), der.set_of(der.octet_string(content_digest))
    )
    body = content_type + message_digest
    return der.tlv(der.SET, body), der.tlv(der.CONTEXT_0, body)


def _signer_info(
    identity: CertificateIdentity,
    attributes_with_implicit_tag: bytes,
    signature: bytes,
) -> bytes:
    return der.sequence(
        der.integer(1),
        der.sequence(identity.issuer, identity.serial),
        _sha256_algorithm(),
        attributes_with_implicit_tag,
        _rsa_algorithm(),
        der.octet_string(signature),
    )


def _signed_data(
    identity: CertificateIdentity,
    signer_info: bytes,
    intermediates: list[bytes] | None,
) -> bytes:
    chain = b"".join(intermediates or ()) + b"".join(identity.intermediates)
    return der.sequence(
        der.integer(1),
        der.set_of(_sha256_algorithm()),
        der.sequence(der.oid(OID_DATA)),
        der.tlv(der.CONTEXT_0, identity.der_bytes + chain),
        der.set_of(signer_info),
    )


def _content_info(signed_data: bytes) -> bytes:
    return der.sequence(der.oid(OID_SIGNED_DATA), der.tlv(der.CONTEXT_0, signed_data))


def build(content: bytes, identity: CertificateIdentity, intermediates: list[bytes] | None = None) -> bytes:
    """Build the detached CMS blob that signs ``content``."""
    signed_input, implicit = _attribute_set(digest(content))
    signature = identity.sign(signed_input)
    return _content_info(_signed_data(identity, _signer_info(identity, implicit, signature), intermediates))


def planned_length(identity: CertificateIdentity, intermediates: list[bytes] | None = None) -> int:
    """The blob length for a signature of this key's size.

    The signature writer allocates the blob before the CodeDirectory exists, so
    it needs the length first. An RSA signature is fixed-width, and every other
    field is content-independent, so a placeholder signature of the right width
    yields the exact length. ``build`` asserts the real blob matches it.
    """
    _, implicit = _attribute_set(b"\x00" * 32)
    signature = b"\x00" * identity.signature_size
    return len(_content_info(_signed_data(identity, _signer_info(identity, implicit, signature), intermediates)))


def verify(cms_der: bytes, content: bytes, *, trust_anchor: bytes | None = None,
           purpose: str = "any") -> bool:
    """Verify a detached CMS blob against its content with the host OpenSSL.

    Without ``trust_anchor`` OpenSSL is told not to evaluate the chain
    (``-noverify``): that answers "is the signature the signer's?" and nothing
    more. With a trust anchor — the root a device would hold — it also answers
    "does the blob carry the chain from the leaf to that root?", which is the
    check a phone performs and the reason a missing intermediate installs
    nowhere.

    ``purpose`` defaults to ``any`` because a code-signing certificate carries
    the ``codeSigning`` extended key usage, which OpenSSL's default
    ``smimesign`` purpose rejects — a distinction that has nothing to do with
    whether the signature is genuine.
    """
    with tempfile.TemporaryDirectory() as directory:
        signature_path = Path(directory) / "signature.der"
        content_path = Path(directory) / "content.bin"
        signature_path.write_bytes(cms_der)
        content_path.write_bytes(content)
        command = ["openssl", "cms", "-verify", "-binary", "-inform", "DER",
                   "-in", str(signature_path), "-content", str(content_path),
                   "-out", "/dev/null"]
        if trust_anchor is None:
            command.append("-noverify")
        else:
            anchor_path = Path(directory) / "anchor.pem"
            anchor_path.write_bytes(_pem(trust_anchor))
            command += ["-CAfile", str(anchor_path), "-purpose", purpose]
        return subprocess.run(command, capture_output=True, check=False).returncode == 0


def sign_attached(content: bytes, identity: CertificateIdentity) -> bytes:
    """A CMS message that carries its content — the shape a profile has.

    Provisioning profiles are attached signatures, not detached ones: the
    property list travels inside ``EncapsulatedContentInfo``. OpenSSL produces
    this form directly, so the fixture is a message real tooling could have
    written rather than one assembled from this module's own encoder.
    """
    if identity.key_path is None:
        raise CMSError("this certificate has no private key on disk")
    with tempfile.TemporaryDirectory() as directory:
        certificate_path = Path(directory) / "certificate.pem"
        content_path = Path(directory) / "content.bin"
        certificate_path.write_bytes(_pem(identity.der_bytes))
        content_path.write_bytes(content)
        result = subprocess.run(
            ["openssl", "cms", "-sign", "-nodetach", "-binary", "-outform", "DER",
             "-signer", str(certificate_path), "-inkey", str(identity.key_path),
             "-md", "sha256", "-in", str(content_path)],
            capture_output=True, check=False)
        if result.returncode != 0:
            raise CMSError(f"openssl could not sign the profile: {result.stderr.decode(errors='replace').strip()}")
        return result.stdout


def _pem(der_bytes: bytes) -> bytes:
    import base64
    body = base64.encodebytes(der_bytes).replace(b"\n", b"")
    lines = [body[index:index + 64] for index in range(0, len(body), 64)]
    return b"-----BEGIN CERTIFICATE-----\n" + b"\n".join(lines) + b"\n-----END CERTIFICATE-----\n"


def digest(content: bytes) -> bytes:
    import hashlib
    return hashlib.sha256(content).digest()
