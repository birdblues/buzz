final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// True for a lowercase 64-hex SHA-256, the shape Blossom `x` tags and the
/// relay's app door path (`/app/{sha256}.html`) require.
bool isSha256Hex(String? value) => value != null && _sha256Hex.hasMatch(value);
