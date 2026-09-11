// Disconnected, single-file ZIP decoding. This does not authenticate a producer,
// validate receipt JSON, or establish that a review covered the target diff.
import { types } from "node:util";
import { inflateRawSync } from "node:zlib";

export const REVIEW_ARCHIVE_LIMITS = Object.freeze({
  archiveBytes: 262144,
  receiptBytes: 65536,
});
const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
const byteLengthOf = Object.getOwnPropertyDescriptor(
  typedArrayPrototype,
  "byteLength",
).get;
const bufferOf = Object.getOwnPropertyDescriptor(
  typedArrayPrototype,
  "buffer",
).get;
const byteOffsetOf = Object.getOwnPropertyDescriptor(
  typedArrayPrototype,
  "byteOffset",
).get;

class ReviewArchiveError extends Error {
  constructor(code) {
    super(`Review archive: ${code}`);
    this.name = "ReviewArchiveError";
    this.code = code;
  }
}
function requireThat(condition, code = "invalid_archive") {
  if (!condition) throw new ReviewArchiveError(code);
}
function snapshot(value) {
  // Native getters avoid shadowed byteLength/buffer/offset and never invoke an
  // input iterator. Reject proxies before any reflective operation on them.
  requireThat(
    !types.isProxy(value) &&
      types.isUint8Array(value) &&
      [Buffer.prototype, Uint8Array.prototype].includes(
        Object.getPrototypeOf(value),
      ),
    "invalid_bytes",
  );
  const length = byteLengthOf.call(value);
  requireThat(
    length >= 22 && length <= REVIEW_ARCHIVE_LIMITS.archiveBytes,
    "archive_limit",
  );
  const backing = bufferOf.call(value);
  requireThat(!types.isSharedArrayBuffer(backing), "invalid_bytes");
  const keys = Reflect.ownKeys(value);
  requireThat(
    keys.length === length && keys.every((key, index) => key === String(index)),
    "invalid_bytes",
  );
  return Buffer.from(new Uint8Array(backing, byteOffsetOf.call(value), length));
}
function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++)
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function extras(bytes) {
  // GitHub's small ZIPs need no extras. Also accept the standard mtime extra;
  // reject every other extension, including ZIP64 and alternate path metadata.
  let offset = 0;
  let timestamp = false;
  while (offset < bytes.length) {
    requireThat(offset + 4 <= bytes.length);
    const id = bytes.readUInt16LE(offset);
    const length = bytes.readUInt16LE(offset + 2);
    offset += 4;
    requireThat(offset + length <= bytes.length);
    requireThat(
      id === 0x5455 && !timestamp && length === 5 && bytes[offset] === 1,
      "unsupported_extra",
    );
    timestamp = true;
    offset += length;
  }
}

/** Decode one top-level receipt into a new Buffer, without filesystem access. */
export function extractReviewReceipt(archiveBytes, expectedName) {
  try {
    requireThat(
      typeof expectedName === "string" &&
        /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.json$/.test(expectedName),
      "invalid_expected_name",
    );
    const bytes = snapshot(archiveBytes);
    const name = Buffer.from(expectedName, "ascii");
    // No preamble, archive comment, extra directory records, or trailing bytes.
    const end = bytes.length - 22;
    requireThat(bytes.readUInt32LE(end) === 0x06054b50);
    requireThat(
      bytes.readUInt16LE(end + 4) === 0 &&
        bytes.readUInt16LE(end + 6) === 0 &&
        bytes.readUInt16LE(end + 8) === 1 &&
        bytes.readUInt16LE(end + 10) === 1 &&
        bytes.readUInt16LE(end + 20) === 0,
    );
    const centralSize = bytes.readUInt32LE(end + 12);
    const central = bytes.readUInt32LE(end + 16);
    requireThat(
      central >= 30 && centralSize >= 46 && central + centralSize === end,
    );
    requireThat(bytes.readUInt32LE(central) === 0x02014b50);
    const platform = bytes[central + 5];
    const version = bytes.readUInt16LE(central + 6);
    const flags = bytes.readUInt16LE(central + 8);
    const method = bytes.readUInt16LE(central + 10);
    const checksum = bytes.readUInt32LE(central + 16);
    const compressedSize = bytes.readUInt32LE(central + 20);
    const size = bytes.readUInt32LE(central + 24);
    const nameLength = bytes.readUInt16LE(central + 28);
    const extraLength = bytes.readUInt16LE(central + 30);
    const external = bytes.readUInt32LE(central + 38);
    const fileType = (external >>> 16) & 0xf000;
    requireThat(
      [0, 3].includes(platform) &&
        [10, 20].includes(version) &&
        (flags & ~0x0808) === 0 &&
        [0, 8].includes(method) &&
        (method !== 8 || version === 20),
      "unsupported_format",
    );
    requireThat(
      (external & 0x10) === 0 && [0, 0x8000].includes(fileType),
      "nonregular_entry",
    );
    requireThat(
      size > 0 &&
        size <= REVIEW_ARCHIVE_LIMITS.receiptBytes &&
        compressedSize > 0 &&
        compressedSize <= REVIEW_ARCHIVE_LIMITS.archiveBytes,
      "receipt_limit",
    );
    requireThat(
      bytes.readUInt16LE(central + 32) === 0 &&
        bytes.readUInt16LE(central + 34) === 0 &&
        (bytes.readUInt16LE(central + 36) & ~1) === 0 &&
        bytes.readUInt32LE(central + 42) === 0 &&
        centralSize === 46 + nameLength + extraLength &&
        nameLength === name.length,
    );
    requireThat(
      bytes.subarray(central + 46, central + 46 + nameLength).equals(name),
      "name_mismatch",
    );
    extras(bytes.subarray(central + 46 + nameLength, end));

    requireThat(bytes.readUInt32LE(0) === 0x04034b50);
    requireThat(
      bytes.readUInt16LE(4) === version &&
        bytes.readUInt16LE(6) === flags &&
        bytes.readUInt16LE(8) === method &&
        bytes.readUInt32LE(10) === bytes.readUInt32LE(central + 12) &&
        bytes.readUInt16LE(26) === nameLength,
    );
    const localExtraLength = bytes.readUInt16LE(28);
    const data = 30 + nameLength + localExtraLength;
    requireThat(data + compressedSize <= central);
    requireThat(
      bytes.subarray(30, 30 + nameLength).equals(name),
      "name_mismatch",
    );
    extras(bytes.subarray(30 + nameLength, data));
    const localChecksum = bytes.readUInt32LE(14);
    const localCompressedSize = bytes.readUInt32LE(18);
    const localSize = bytes.readUInt32LE(22);
    if ((flags & 8) === 0) {
      requireThat(
        localChecksum === checksum &&
          localCompressedSize === compressedSize &&
          localSize === size &&
          data + compressedSize === central,
      );
    } else {
      // Streamed ZIP producers use zero local values; also permit the complete
      // known values. Partial/inconsistent local declarations are rejected.
      requireThat(
        (localChecksum === 0 && localCompressedSize === 0 && localSize === 0) ||
          (localChecksum === checksum &&
            localCompressedSize === compressedSize &&
            localSize === size),
      );
      let descriptor = data + compressedSize;
      const descriptorSize = central - descriptor;
      requireThat([12, 16].includes(descriptorSize));
      if (descriptorSize === 16) {
        requireThat(bytes.readUInt32LE(descriptor) === 0x08074b50);
        descriptor += 4;
      }
      requireThat(
        bytes.readUInt32LE(descriptor) === checksum &&
          bytes.readUInt32LE(descriptor + 4) === compressedSize &&
          bytes.readUInt32LE(descriptor + 8) === size,
      );
    }
    const compressed = bytes.subarray(data, data + compressedSize);
    let receipt;
    if (method === 0) {
      requireThat(compressedSize === size);
      receipt = Buffer.from(compressed);
    } else {
      try {
        const result = inflateRawSync(compressed, {
          maxOutputLength: REVIEW_ARCHIVE_LIMITS.receiptBytes,
          info: true,
        });
        requireThat(result.engine.bytesWritten === compressedSize);
        receipt = result.buffer;
      } catch {
        throw new ReviewArchiveError("invalid_compressed_data");
      }
    }
    requireThat(receipt.length === size, "size_mismatch");
    requireThat(crc32(receipt) === checksum, "checksum_mismatch");
    return receipt;
  } catch (error) {
    if (error instanceof ReviewArchiveError) throw error;
    throw new ReviewArchiveError("invalid_archive");
  }
}
