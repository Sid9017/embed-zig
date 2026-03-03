//! Runtime crypto PKI/signature contracts.

fn validateSignatureScheme(comptime Scheme: type, comptime scheme_name: []const u8) void {
    if (!@hasDecl(Scheme, "Signature") or @TypeOf(Scheme.Signature) != type) {
        @compileError(scheme_name ++ " missing Signature type");
    }
    if (!@hasDecl(Scheme, "PublicKey") or @TypeOf(Scheme.PublicKey) != type) {
        @compileError(scheme_name ++ " missing PublicKey type");
    }

    _ = @as(*const fn (Scheme.Signature, []const u8, Scheme.PublicKey) bool, &Scheme.verify);
}

/// PKI contract validator.
///
/// Required declaration set:
/// - `Ed25519`
/// - `EcdsaP256Sha256`
/// - `EcdsaP384Sha384`
pub fn from(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "Ed25519")) @compileError("PKI missing Ed25519");
        if (!@hasDecl(Impl, "EcdsaP256Sha256")) @compileError("PKI missing EcdsaP256Sha256");
        if (!@hasDecl(Impl, "EcdsaP384Sha384")) @compileError("PKI missing EcdsaP384Sha384");

        validateSignatureScheme(Impl.Ed25519, "Ed25519");
        validateSignatureScheme(Impl.EcdsaP256Sha256, "EcdsaP256Sha256");
        validateSignatureScheme(Impl.EcdsaP384Sha384, "EcdsaP384Sha384");
    }
    return Impl;
}
