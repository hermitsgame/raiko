use anyhow::{anyhow, Result};
use raiko_lib::primitives::Address;

#[derive(Debug, Clone)]
pub enum ProofType {
    /// One-shot proof: 89 bytes = 4(id) + 20(new) + 65(sig)
    OneShot,
}

#[derive(Debug, Clone)]
pub struct SgxProof {
    pub proof_type: ProofType,
    pub instance_id: u32,
    /// New instance address
    pub new_instance_address: Address,
    pub signature: [u8; 65],
}

/// Parse SGX proof bytes
/// Supports both formats:
/// - One-shot: 89 bytes = 4(id) + 20(new) + 65(sig)
/// - Aggregation: 109 bytes = 4(id) + 20(old) + 20(new) + 65(sig)
/// For aggregation proofs, we extract the new_instance_address and signature for one-shot verification
pub fn parse_proof_bytes(proof_bytes: &[u8]) -> Result<SgxProof> {
    if proof_bytes.len() < 89 {
        return Err(anyhow!(
            "Invalid proof length: expected at least 89 bytes, got {}",
            proof_bytes.len()
        ));
    }

    // Parse instance_id (4 bytes, big-endian)
    let instance_id = u32::from_be_bytes([
        proof_bytes[0],
        proof_bytes[1],
        proof_bytes[2],
        proof_bytes[3],
    ]);

    let (new_instance_address, signature) = if proof_bytes.len() == 89 {
        // One-shot proof: 4(id) + 20(new) + 65(sig) = 89
        let new_instance_address = Address::from_slice(&proof_bytes[4..24]);
        let signature: [u8; 65] = proof_bytes[24..89]
            .try_into()
            .map_err(|_| anyhow!("Failed to extract signature from proof bytes"))?;
        (new_instance_address, signature)
    } else if proof_bytes.len() == 109 {
        // Aggregation proof: 4(id) + 20(old) + 20(new) + 65(sig) = 109
        // Extract new_instance_address and signature for one-shot verification
        let new_instance_address = Address::from_slice(&proof_bytes[24..44]);
        let signature: [u8; 65] = proof_bytes[44..109]
            .try_into()
            .map_err(|_| anyhow!("Failed to extract signature from proof bytes"))?;
        (new_instance_address, signature)
    } else {
        return Err(anyhow!(
            "Invalid proof length: expected 89 (one-shot) or 109 (aggregation) bytes, got {}",
            proof_bytes.len()
        ));
    };

    Ok(SgxProof {
        proof_type: ProofType::OneShot,
        instance_id,
        new_instance_address,
        signature,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use hex;

    #[test]
    fn test_parse_one_shot_proof() {
        // Example one-shot proof: 89 bytes
        let proof_hex = "01000000c13bd882edb37ffbabc9f9e34a0d9789633b850fe55e625b768cc8e5feed7d9f7ab536cbc210c2fcc1385aaf88d8a91d8adc2740245f9deee5fd3d61dd2a71662fb6639515f1e2f3354361a82d86c1952352c1a81b";
        let proof_bytes = hex::decode(proof_hex).unwrap();
        let proof = parse_proof_bytes(&proof_bytes).unwrap();
        assert_eq!(proof.instance_id, 1);
        assert!(matches!(proof.proof_type, ProofType::OneShot));
        let expected_addr = Address::from_slice(&hex::decode("c13bd882edb37ffbabc9f9e34a0d9789633b850").unwrap());
        assert_eq!(proof.new_instance_address, expected_addr);
    }

}

