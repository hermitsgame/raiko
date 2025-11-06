use raiko_lib::primitives::{keccak256, Address};
use secp256k1::{
    ecdsa::{RecoverableSignature, RecoveryId},
    Error, Message, PublicKey, Secp256k1,
};

/// Recovers the address of the sender using secp256k1 pubkey recovery.
///
/// Converts the public key into an ethereum address by hashing the public key with
/// keccak256.
///
/// This does not ensure that the `s` value in the signature is low, and _just_ wraps the
/// underlying secp256k1 library.
pub fn recover_signer(sig: &[u8; 65], msg: &[u8; 32]) -> Result<Address, Error> {
    let sig = RecoverableSignature::from_compact(
        &sig[0..64],
        RecoveryId::from_i32(sig[64] as i32 - 27)?,
    )?;

    let secp = Secp256k1::new();
    let public = secp.recover_ecdsa(&Message::from_digest_slice(&msg[..32])?, &sig)?;
    Ok(public_key_to_address(&public))
}

/// Converts a public key into an ethereum address by hashing the encoded public key with
/// keccak256.
fn public_key_to_address(public: &PublicKey) -> Address {
    // strip out the first byte because that should be the SECP256K1_TAG_PUBKEY_UNCOMPRESSED
    // tag returned by libsecp's uncompressed pubkey serialization
    let hash = keccak256(&public.serialize_uncompressed()[1..]);
    Address::from_slice(&hash[12..])
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex;

    #[test]
    fn test_recover_signer() {
        // Test case from provers/sgx/guest/src/signature.rs
        let proof_hex = "01000000c13bd882edb37ffbabc9f9e34a0d9789633b850fe55e625b768cc8e5feed7d9f7ab536cbc210c2fcc1385aaf88d8a91d8adc2740245f9deee5fd3d61dd2a71662fb6639515f1e2f3354361a82d86c1952352c1a81b";
        let proof_bytes = hex::decode(proof_hex).unwrap();
        let msg_hex = "216ac5cd5a5e13b0c9a81efb1ad04526b9f4ddd2fe6ebc02819c5097dfb0958c";
        let msg_bytes = hex::decode(msg_hex).unwrap();
        let sig: [u8; 65] = proof_bytes[24..89].try_into().unwrap();
        let msg: [u8; 32] = msg_bytes.try_into().unwrap();
        
        let recovered = recover_signer(&sig, &msg).unwrap();
        let expected = Address::from_slice(&hex::decode("c13bd882edb37ffbabc9f9e34a0d9789633b850").unwrap());
        assert_eq!(recovered, expected);
    }
}

