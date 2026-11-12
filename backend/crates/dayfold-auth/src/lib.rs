//! Trusted OIDC identity verification and RFC 9449 proof verification.
//!
//! A valid proof alone does not authorize a request. The caller must atomically
//! consume its `jti` and enforce the stored challenge/session key binding.

mod dpop;
mod json;
mod oidc;

pub use dpop::{DpopExpectation, VerifiedDpop, verify_dpop};
pub use oidc::{OidcConfig, OidcMetadata, OidcVerifier, VerifiedIdentity};

/// Deliberately excludes token contents, issuer responses, and key material.
#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum AuthError {
    #[error("invalid authentication configuration")]
    InvalidConfiguration,
    #[error("identity provider unavailable")]
    Unavailable,
    #[error("invalid identity token")]
    InvalidToken,
    #[error("invalid proof of possession")]
    InvalidProof,
}

#[cfg(test)]
mod tests;
