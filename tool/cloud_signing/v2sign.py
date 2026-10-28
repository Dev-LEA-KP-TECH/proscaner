"""Sign an APK with APK Signature Scheme v2, using a PKCS#12 keystore.

Usage:
  v2sign.py info   KEYSTORE PASSFILE
  v2sign.py sign   KEYSTORE PASSFILE IN_APK OUT_APK
  v2sign.py verify APK

Follows https://source.android.com/docs/security/features/apksigning/v2:
- the ZIP entries, central directory and EOCD are left byte-for-byte as they are (so entry alignment is kept);
  only the APK Signing Block between the entries and the central directory is replaced, and the
  central-directory offset in the EOCD is updated
- content digest: 1 MiB chunks, SHA-256, algorithm 0x0103 (RSASSA-PKCS1-v1_5 with SHA2-256)
The key never leaves this process and nothing secret is printed.
"""
import hashlib
import struct
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, pkcs12

MAGIC = b'APK Sig Block 42'
V2_ID = 0x7109871A
V3_ID = 0xF05368C0
ALG_RSA_SHA256 = 0x0103
CHUNK = 1024 * 1024


def u32(v):
    return struct.pack('<I', v)


def u64(v):
    return struct.pack('<Q', v)


def lp(b):
    return u32(len(b)) + b


def lp_seq(items):
    return lp(b''.join(lp(x) for x in items))


def find_eocd(d):
    lowest = max(0, len(d) - 22 - 0xFFFF)
    for i in range(len(d) - 22, lowest - 1, -1):
        if d[i:i + 4] == b'PK\x05\x06':
            (comment_len,) = struct.unpack('<H', d[i + 20:i + 22])
            if i + 22 + comment_len == len(d):
                return i
    raise ValueError('no ZIP end-of-central-directory record')


def split(d):
    """-> (entries, signing_block or b'', central_directory, eocd)"""
    eocd = find_eocd(d)
    cd_size, cd_off = struct.unpack('<II', d[eocd + 12:eocd + 20])
    if cd_off + cd_size != eocd:
        raise ValueError('central directory is not right before the EOCD')
    start = cd_off
    if d[cd_off - 16:cd_off] == MAGIC:
        (size,) = struct.unpack('<Q', d[cd_off - 24:cd_off - 16])
        start = cd_off - (size + 8)
        if start < 0 or struct.unpack('<Q', d[start:start + 8])[0] != size:
            raise ValueError('damaged APK Signing Block')
    return d[:start], d[start:cd_off], d[cd_off:eocd], d[eocd:]


def with_cd_offset(eocd, offset):
    return eocd[:16] + u32(offset) + eocd[20:]


def content_digest(entries, cd, eocd):
    """Chunked SHA-256 over entries, central directory and EOCD (EOCD pointing at the signing block)."""
    chunks = []
    for section in (entries, cd, with_cd_offset(eocd, len(entries))):
        for off in range(0, len(section), CHUNK):
            c = section[off:off + CHUNK]
            chunks.append(hashlib.sha256(b'\xa5' + u32(len(c)) + c).digest())
    return hashlib.sha256(b'\x5a' + u32(len(chunks)) + b''.join(chunks)).digest()


def load_key(keystore, passfile):
    password = open(passfile, 'rb').read().strip()
    key, cert, _ = pkcs12.load_key_and_certificates(open(keystore, 'rb').read(), password)
    if key is None or cert is None:
        raise ValueError('keystore has no private key and certificate')
    return key, cert


def fingerprint(der, algo):
    h = hashlib.new(algo, der).hexdigest().upper()
    return ':'.join(h[i:i + 2] for i in range(0, len(h), 2))


def describe(cert):
    der = cert.public_bytes(Encoding.DER)
    pub = cert.public_key()
    print('subject  ', cert.subject.rfc4514_string())
    print('valid    ', cert.not_valid_before_utc.date(), '->', cert.not_valid_after_utc.date())
    print('key      ', type(pub).__name__, getattr(pub, 'key_size', '?'), 'bits')
    print('SHA-256  ', fingerprint(der, 'sha256'))
    print('SHA-1    ', fingerprint(der, 'sha1'))


def sign(keystore, passfile, src, dst):
    key, cert = load_key(keystore, passfile)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise ValueError('expected an RSA key')
    d = open(src, 'rb').read()
    entries, _old_block, cd, eocd = split(d)
    digest = content_digest(entries, cd, eocd)
    cert_der = cert.public_bytes(Encoding.DER)
    pub_der = cert.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    if key.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo) != pub_der:
        raise ValueError('private key does not match the certificate')
    # same layout as Google's apksig: digests, certificates, additional attributes, then one empty element
    signed_data = (
        lp_seq([u32(ALG_RSA_SHA256) + lp(digest)])  # digests
        + lp_seq([cert_der])  # certificates
        + lp_seq([])  # additional attributes
        + lp(b'')
    )
    signature = key.sign(signed_data, padding.PKCS1v15(), hashes.SHA256())
    signer = lp(signed_data) + lp_seq([u32(ALG_RSA_SHA256) + lp(signature)]) + lp(pub_der)
    v2_block = lp_seq([signer])
    pairs = u64(4 + len(v2_block)) + u32(V2_ID) + v2_block
    size = len(pairs) + 8 + 16
    block = u64(size) + pairs + u64(size) + MAGIC
    out = entries + block + cd + with_cd_offset(eocd, len(entries) + len(block))
    open(dst, 'wb').write(out)
    print('signed   ', dst, len(out), 'bytes')


def read_lp(b, i):
    (n,) = struct.unpack('<I', b[i:i + 4])
    if i + 4 + n > len(b):
        raise ValueError('length prefix runs past the end')
    return b[i + 4:i + 4 + n], i + 4 + n


def items(b):
    out = []
    i = 0
    while i < len(b):
        x, i = read_lp(b, i)
        out.append(x)
    return out


def verify(path):
    d = open(path, 'rb').read()
    entries, block, cd, eocd = split(d)
    if not block:
        raise ValueError('no APK Signing Block')
    if struct.unpack('<I', eocd[16:20])[0] != len(entries) + len(block):
        raise ValueError('EOCD central-directory offset is wrong')
    pairs = {}
    i = 8
    while i < len(block) - 24:
        (n,) = struct.unpack('<Q', block[i:i + 8])
        (pid,) = struct.unpack('<I', block[i + 8:i + 12])
        pairs[pid] = block[i + 12:i + 8 + n]
        i += 8 + n
    print('blocks   ', ', '.join(hex(k) for k in pairs))
    if V2_ID not in pairs:
        raise ValueError('no v2 signature')
    expected = content_digest(entries, cd, eocd)
    (signers_seq,) = items(pairs[V2_ID])
    signers = items(signers_seq)
    for s in signers:
        signed_data, sigs, pub_der = items(s)
        parts = items(signed_data)
        if len(parts) < 3:
            raise ValueError('signed data is too short')
        digests_seq, certs_seq, attrs_seq = parts[:3]
        digests = {}
        for item in items(digests_seq):
            (alg,) = struct.unpack('<I', item[:4])
            digests[alg], _ = read_lp(item, 4)
        certs = items(certs_seq)
        cert = x509.load_der_x509_certificate(certs[0])
        if cert.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo) != pub_der:
            raise ValueError('public key does not match the first certificate')
        pub = cert.public_key()
        for item in items(sigs):
            (alg,) = struct.unpack('<I', item[:4])
            sig, _ = read_lp(item, 4)
            if alg != ALG_RSA_SHA256:
                raise ValueError('unexpected algorithm %#x' % alg)
            pub.verify(sig, signed_data, padding.PKCS1v15(), hashes.SHA256())
        if digests.get(ALG_RSA_SHA256) != expected:
            raise ValueError('content digest does not match the APK')
        print('signer    signature OK, content digest OK, attributes', len(items(attrs_seq)))
        describe(cert)
    print('VERIFIED ', path)


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'info':
        describe(load_key(sys.argv[2], sys.argv[3])[1])
    elif cmd == 'sign':
        sign(*sys.argv[2:6])
    elif cmd == 'verify':
        verify(sys.argv[2])
    else:
        raise SystemExit(__doc__)
