/// The frame shapes of each protocol version, append-only: a new version adds its entry and
/// never edits an older one. `WireShapeTests` prints the current shapes when they differ.
enum WireShapesFixture {
    static let json = """
    {
      "3": {
        "abort": ["reason", "type"],
        "accept": ["offset", "type"],
        "ack": ["stored_as", "type"],
        "auth": ["hmac", "type"],
        "challenge": ["nonce", "type"],
        "done": ["sha256", "type"],
        "forget": ["ids", "type"],
        "forgotten": ["count", "type"],
        "hello": ["build", "device_id", "nonce", "type", "v"],
        "hold": ["type"],
        "manifest": ["entries", "first", "type", "entries[].path", "entries[].sha256", "entries[].size", "entries[].type"],
        "manifest_end": ["count", "type"],
        "mismatch": ["build", "type", "v"],
        "offer": ["clip_kind", "entries", "id", "intent", "keep", "kind", "mime", "name", "sha256", "size", "skipped", "type"],
        "ok": ["hmac", "type"],
        "reject": ["limit", "reason", "type"],
        "want_manifest": ["type"]
      }
    }
    """
}
