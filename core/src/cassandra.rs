use anyhow::{anyhow, Result};
use cassandra_cpp::*;
use raiko_lib::input::Vspc;
use reth_primitives::B256;
use tracing::{info, warn, debug};

/// Cassandra configuration (hardcoded for now, matching verify_block.go)
pub struct CassandraConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub pass: String,
    pub space: String,
    pub crt: String,
}

impl Default for CassandraConfig {
    fn default() -> Self {
        Self {
            host: "cassandra.eu-west-1.amazonaws.com".to_string(),
            port: 9142,
            user: "kpdb01-kasplex-mainnet-ro2-at-730335342669".to_string(),
            pass: "XJ3DXWzET/R6ZQtMURwjiAbM5DJlKIWRrKX39YRX7HTggvcUuEfTgSUUya8=".to_string(),
            space: "kpdb01mainnet".to_string(),
            crt: "sf-class2-root.crt".to_string(),
        }
    }
}

const DAA_SCORE_OF_BLOCK: u64 = 10;

/// Create a Cassandra session with TLS and authentication using cassandra-cpp
pub async fn create_session(config: &CassandraConfig) -> Result<Session> {
    info!(
        "Connecting to Cassandra: {}:{} (keyspace: {})",
        config.host, config.port, config.space
    );

    // Create cluster
    let mut cluster = Cluster::default();
    
    // Set contact points
    cluster.set_contact_points(&config.host)
        .map_err(|e| anyhow!("Failed to set contact points: {}", e))?;
    
    // Set port separately
    cluster.set_port(config.port)
        .map_err(|e| anyhow!("Failed to set port: {}", e))?;
    
    // Set credentials
    cluster.set_credentials(&config.user, &config.pass)
        .map_err(|e| anyhow!("Failed to set credentials: {}", e))?;
    
    // Configure TLS/SSL
    let mut ssl = Ssl::default();
    
    // Resolve certificate path (relative to project root)
    let cert_path = if config.crt.starts_with("/") {
        config.crt.clone()
    } else {
        // If relative path, resolve from current working directory or project root
        // Try to find certificate file
        let current_dir = std::env::current_dir()
            .map_err(|e| anyhow!("Failed to get current directory: {}", e))?;
        
        // Try current directory first
        let mut path = current_dir.join(&config.crt);
        if !path.exists() {
            // Try parent directory (project root)
            if let Some(parent) = current_dir.parent() {
                path = parent.join(&config.crt);
            }
        }
        
        path.canonicalize()
            .map_err(|e| anyhow!("Failed to canonicalize certificate path {:?}: {}", path, e))?
            .to_string_lossy()
            .to_string()
    };
    
    info!("Loading certificate from: {}", cert_path);
    
    // Read certificate content and pass it directly (DataStax C++ driver expects certificate content, not file path)
    let cert_content = std::fs::read_to_string(&cert_path)
        .map_err(|e| anyhow!("Failed to read certificate file {}: {}", cert_path, e))?;
    
    ssl.add_trusted_cert(&cert_content)
        .map_err(|e| anyhow!("Failed to add trusted certificate: {}", e))?;
    
    // Set SSL verification flags
    // Use PEER_CERT only (certificate chain validation, no hostname check)
    // This works because cassandra-cpp resolves hostname to IP and uses IP for TLS verification,
    // but the certificate is only valid for hostname, not IP.
    // Using PEER_CERT only validates the certificate chain without hostname verification.
    info!("Setting SSL verification flags: PEER_CERT only (certificate chain validation, no hostname check)");
    ssl.set_verify_flags(&[SslVerifyFlag::PEER_CERT]);
    
    // Set SSL context
    cluster.set_ssl(ssl);
    
    // Connect to cluster with keyspace directly (async)
    info!("Connecting to cluster with keyspace {}...", config.space);
    let session = cluster.connect_keyspace(&config.space).await
        .map_err(|e| anyhow!("Failed to connect to cluster with keyspace {}: {}", config.space, e))?;
    
    info!("Successfully connected to Cassandra");
    Ok(session)
}

/// Get VSPC list from Cassandra for the given daaScore
pub async fn get_vspc_list(daa_score: u64) -> Result<Vec<Vspc>> {
    let config = CassandraConfig::default();
    let session = create_session(&config).await?;

    // Calculate start_daa_score (same logic as verify_block.go)
    let start_daa_score = (daa_score / DAA_SCORE_OF_BLOCK) * DAA_SCORE_OF_BLOCK;
    let end_daa_score = start_daa_score + DAA_SCORE_OF_BLOCK;
    
    info!("Querying VSPC for daaScore {} (range: {} to {})", daa_score, start_daa_score, end_daa_score);
    
    // Query VSPC list from Cassandra
    // Table name is "vspc", column name is "daascore" (not "daa_score")
    // Build IN clause for daascore range
    let mut daascore_values = Vec::new();
    for i in start_daa_score..end_daa_score {
        daascore_values.push(i.to_string());
    }
    let daascore_in = daascore_values.join(",");
    
    let query_str = format!(
        "SELECT daascore, hash FROM vspc WHERE daascore IN ({})",
        daascore_in
    );
    
    info!("Executing query: {}", query_str);
    info!("Query range: start_daa_score={}, end_daa_score={}, daa_score={}", start_daa_score, end_daa_score, daa_score);
    
    let result = session.execute(&query_str).await
        .map_err(|e| anyhow!("Failed to execute query: {}", e))?;
    
    let mut vspc_list: Vec<Vspc> = Vec::new();
    
    // Iterate over rows
    // Note: cassandra-cpp uses ResultIterator which needs to be converted to iterator
    let mut iter = result.iter();
    while let Some(row) = iter.next() {
        let daa_score: i64 = row.get_by_name("daascore")
            .map_err(|e| anyhow!("Failed to get daascore: {}", e))?;
        
        // Hash is stored as hex string (64 chars) in Cassandra
        // Get as String, then decode hex to binary
        let hex_str: String = row.get_by_name("hash")
            .map_err(|e| anyhow!("Failed to get hash: {}", e))?;
        
        if hex_str.len() != 64 {
            warn!("Hex hash length is {} (expected 64)", hex_str.len());
            continue;
        }
        
        let decoded = hex::decode(&hex_str)
            .map_err(|e| anyhow!("Failed to decode hex hash: {}", e))?;
        if decoded.len() != 32 {
            warn!("Decoded hash length is {} (expected 32)", decoded.len());
            continue;
        }
        
        let hash = B256::from_slice(&decoded);
        vspc_list.push(Vspc {
            daa_score: daa_score as u64,
            hash,
        });
    }
    
    if vspc_list.is_empty() {
        warn!("No VSPC found for daaScore {} (start: {}, end: {})", daa_score, start_daa_score, end_daa_score);
        // Return empty list instead of error, as this might be valid (no data in range)
        // The caller can decide whether empty list is acceptable
        return Ok(vspc_list);
    }
    
    // Sort by DaaScore (matching verify_block.go behavior)
    // IMPORTANT: Must sort before calculating MixHash, exactly like Go code does
    vspc_list.sort_by(|a, b| a.daa_score.cmp(&b.daa_score));
    
    info!(
        "Retrieved {} VSPC entries for daaScore {} (after sorting)",
        vspc_list.len(),
        daa_score
    );
    
    // Log sorted VSPC list for debugging
    for (i, vspc) in vspc_list.iter().enumerate() {
        info!("  VSPC[{}]: daa_score={}, hash={:?}", i, vspc.daa_score, vspc.hash);
    }
    
    Ok(vspc_list)
}

/// Calculate MixHash from VSPC list (matching verify_block.go logic)
/// 
/// Go implementation:
/// ```go
/// // Sort by DaaScore
/// sort.Slice(vspcList, func(i, j int) bool {
///     return vspcList[i].DaaScore < vspcList[j].DaaScore
/// })
/// 
/// // Build data array
/// data := []byte{}
/// for _, vspc := range vspcList {
///     data = binary.BigEndian.AppendUint64(data, vspc.DaaScore)
///     data = append(data, []byte(vspc.Hash)...)
/// }
/// 
/// // Calculate Keccak256 hash
/// b := crypto.Keccak256(data)
/// return common.BytesToHash(b), nil
/// ```
/// 
/// Note: vspc_list MUST be sorted by daa_score before calling this function!
pub fn calculate_mix_hash_from_vspc(vspc_list: &[Vspc]) -> Result<B256> {
    use raiko_lib::primitives::keccak::keccak;
    use std::io::Write;
    use tracing::{info, debug};

    // Verify that vspc_list is sorted (for debugging)
    for i in 1..vspc_list.len() {
        if vspc_list[i-1].daa_score > vspc_list[i].daa_score {
            warn!("VSPC list is not sorted! VSPC[{}].daa_score={} > VSPC[{}].daa_score={}", 
                i-1, vspc_list[i-1].daa_score, i, vspc_list[i].daa_score);
        }
    }

    info!("Calculating MixHash from {} VSPC entries (must be sorted by daa_score)", vspc_list.len());
    
    // Build data array: for each vspc, append daa_score (8 bytes big-endian) and hash as hex string (ASCII)
    // This matches Go: binary.BigEndian.AppendUint64(data, vspc.DaaScore) + append(data, []byte(vspc.Hash)...)
    // IMPORTANT: In Go, vspc.Hash is a hex string, and []byte(vspc.Hash) converts it to ASCII bytes, not binary!
    // So we need to convert hash to hex string first, then append as bytes
    let mut data = Vec::new();
    for (idx, vspc) in vspc_list.iter().enumerate() {
        // Append daa_score as 8 bytes big-endian (matching binary.BigEndian.AppendUint64)
        let daa_score_bytes = vspc.daa_score.to_be_bytes();
        debug!("VSPC[{}]: daa_score={} -> bytes: {:?}", idx, vspc.daa_score, daa_score_bytes);
        data.write_all(&daa_score_bytes)
            .map_err(|e| anyhow!("Failed to write daa_score: {}", e))?;
        
        // Append hash as hex string (ASCII bytes) - matching append(data, []byte(vspc.Hash)...)
        // vspc.Hash in Go is a hex string, so []byte(vspc.Hash) gives ASCII bytes
        let hash_hex = hex::encode(vspc.hash.as_slice());
        debug!("VSPC[{}]: hash={:?} -> hex string: {}", idx, vspc.hash, hash_hex);
        data.write_all(hash_hex.as_bytes())
            .map_err(|e| anyhow!("Failed to write hash hex string: {}", e))?;
    }

    info!("Built data array: {} bytes total ({} VSPC entries × 40 bytes each)", data.len(), vspc_list.len());
    debug!("Data bytes (first 80): {:?}", &data[..data.len().min(80)]);
    
    // Print data in hex format for debugging (matching Go implementation)
    let data_hex = hex::encode(&data);
    info!("Data array (hex): {}", data_hex);
    info!("Data array (hex, formatted):");
    for (i, chunk) in data.chunks(32).enumerate() {
        info!("  [{}]: {}", i * 32, hex::encode(chunk));
    }

    // Calculate Keccak256 hash (matching crypto.Keccak256(data))
    let hash_bytes = keccak(&data);
    let result = B256::from_slice(&hash_bytes);
    info!("Calculated MixHash: {:?}", result);
    Ok(result)
}
