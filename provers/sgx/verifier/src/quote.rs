use anyhow::{anyhow, Result};
use raiko_lib::primitives::{Address, B256};
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct QuoteInfo {
    pub version: [u8; 2],
    pub attestation_key_type: [u8; 2],
    pub tee_type: [u8; 4],
    pub mr_enclave: B256,
    pub mr_signer: B256,
    pub isv_prod_id: u16,
    pub isv_svn: u16,
    #[serde(serialize_with = "serialize_bytes")]
    pub report_data: [u8; 64],
    /// Instance address extracted from REPORTDATA (first 20 bytes of reportData)
    pub report_data_address: Option<Address>,
}

fn serialize_bytes<S>(bytes: &[u8; 64], serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    serializer.serialize_bytes(bytes)
}

/// Parse SGX Quote V3 structure
/// Format:
/// - Header (48 bytes): version (2) + attestationKeyType (2) + teeType (4) + qeSvn (2) + pceSvn (2) + qeVendorId (16) + userData (20)
/// - Enclave Report (384 bytes): cpuSvn (16) + miscSelect (4) + reserved1 (28) + attributes (16) + mrEnclave (32) + reserved2 (32) + mrSigner (32) + reserved3 (96) + isvProdId (2) + isvSvn (2) + reserved4 (60) + reportData (64)
/// - Authentication Data: variable length
pub fn parse_quote(quote_bytes: &[u8]) -> Result<QuoteInfo> {
    if quote_bytes.len() < 432 {
        return Err(anyhow!(
            "Quote too short: expected at least 432 bytes, got {}",
            quote_bytes.len()
        ));
    }

    // Parse header
    let version = [quote_bytes[0], quote_bytes[1]];
    let attestation_key_type = [quote_bytes[2], quote_bytes[3]];
    let tee_type = [quote_bytes[4], quote_bytes[5], quote_bytes[6], quote_bytes[7]];

    // Parse enclave report (starts at offset 48)
    let report_offset = 48;
    let mr_enclave = B256::from_slice(&quote_bytes[report_offset + 64..report_offset + 96]);
    let mr_signer = B256::from_slice(&quote_bytes[report_offset + 128..report_offset + 160]);
    
    // Parse ISV fields (little-endian)
    let isv_prod_id = u16::from_le_bytes([
        quote_bytes[report_offset + 256],
        quote_bytes[report_offset + 257],
    ]);
    let isv_svn = u16::from_le_bytes([
        quote_bytes[report_offset + 258],
        quote_bytes[report_offset + 259],
    ]);

    // Parse reportData (64 bytes)
    let report_data_offset = report_offset + 320;
    let report_data: [u8; 64] = quote_bytes[report_data_offset..report_data_offset + 64]
        .try_into()
        .map_err(|_| anyhow!("Failed to extract reportData from quote"))?;

    // Extract instance address from REPORTDATA (first 20 bytes)
    let report_data_address = Some(Address::from_slice(&report_data[0..20]));

    Ok(QuoteInfo {
        version,
        attestation_key_type,
        tee_type,
        mr_enclave,
        mr_signer,
        isv_prod_id,
        isv_svn,
        report_data,
        report_data_address,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_quote_minimal() {
        // Create a minimal quote structure for testing
        let mut quote_bytes = vec![0u8; 432];
        // Set version
        quote_bytes[0] = 0x03;
        quote_bytes[1] = 0x00;
        // Set MRENCLAVE
        quote_bytes[48 + 64] = 0x01;
        // Set MRSIGNER
        quote_bytes[48 + 128] = 0x02;
        // Set ISV fields
        quote_bytes[48 + 256] = 0x01;
        quote_bytes[48 + 257] = 0x00;
        quote_bytes[48 + 258] = 0x01;
        quote_bytes[48 + 259] = 0x00;
        // Set REPORTDATA address
        quote_bytes[48 + 320] = 0x11;
        quote_bytes[48 + 321] = 0x22;

        let quote_info = parse_quote(&quote_bytes).unwrap();
        assert_eq!(quote_info.version, [0x03, 0x00]);
        assert_eq!(quote_info.isv_prod_id, 1);
        assert_eq!(quote_info.isv_svn, 1);
        assert!(quote_info.report_data_address.is_some());
    }
}

