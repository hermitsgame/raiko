#!/usr/bin/env bash

# Script to prove and verify a block using SGX one-shot proof

set -e

# Default values
raiko_endpoint=${raiko_endpoint:-"http://localhost:8080"}
raiko_api_key=${raiko_api_key:-"4cbd753fbcbc2639de804f8ce425016a50e0ecd53db00cb5397912e83f5e570e"}
prover=${prover:-"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}
graffiti=${graffiti:-"8008500000000000000000000000000000000000000000000000000000000000"}

usage() {
    echo "Usage:"
    echo "  prove_and_verify_block.sh <chain> <block_number> [rpc_url]"
    echo ""
    echo "Arguments:"
    echo "  chain          Network name (e.g., devnet, taiko_a7, taiko_mainnet)"
    echo "  block_number   Block number to prove and verify"
    echo "  rpc_url        (Optional) Custom RPC URL for the network"
    echo ""
    echo "Environment variables:"
    echo "  raiko_endpoint Raiko API endpoint (default: http://localhost:8080)"
    echo "  raiko_api_key  API key for Raiko (default: 4cbd753fbcbc2639de804f8ce425016a50e0ecd53db00cb5397912e83f5e570e)"
    echo "  prover         Prover address (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)"
    echo "  graffiti       Graffiti value (default: 8008500000000000000000000000000000000000000000000000000000000000)"
    exit 1
}

# Check arguments
if [ $# -lt 2 ]; then
    usage
fi

chain="$1"
block_number="$2"
rpc_url="${3:-http://52.48.173.231:18545}"

# Check the chain name and set the corresponding L1 network
get_l1_network() {
    local chain="$1"
    case "$chain" in
        ethereum)
            echo "ethereum"
            ;;
        devnet)
            echo "devnet"
            ;;
        holesky)
            echo "holesky"
            ;;
        taiko_mainnet)
            echo "ethereum"
            ;;
        taiko_a7)
            echo "holesky"
            ;;
        taiko_dev)
            echo "taiko_dev_l1"
            ;;
        *)
            echo "Using customized chain name $chain. Please double check the RPCs." >&2
            echo "holesky"
            ;;
    esac
}

l1_network=$(get_l1_network "$chain")

echo "=== Proving block $block_number on $chain ==="
echo "L1 Network: $l1_network"
echo ""

# Step 1: Submit proof request
echo "Submitting proof request..."
proof_response=$(curl -s --location --request POST "$raiko_endpoint/v2/proof" \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $raiko_api_key" \
    --data-raw "{
        \"network\": \"$chain\",
        \"l1_network\": \"$l1_network\",
        \"block_numbers\": [[$block_number, null], [$(($block_number+1)), null]],
        \"block_number\": $block_number,
        \"prover\": \"$prover\",
        \"graffiti\": \"$graffiti\",
        \"proof_type\": \"sgx\",
        \"sgx\": {
            \"instance_id\": 123,
            \"setup\": false,
            \"bootstrap\": false,
            \"prove\": true,
            \"input_path\": null
        }
    }")

# Check if proof request was successful
if ! echo "$proof_response" | jq -e '.status == "ok"' > /dev/null 2>&1; then
    echo "Error: Proof request failed"
    echo "$proof_response" | jq '.'
    exit 1
fi

status=$(echo "$proof_response" | jq -r '.data.status // empty')
echo "Proof request status: ${status:-none}"

# Check if proof is already in response
has_proof=$(echo "$proof_response" | jq -e '.data.proof != null' 2>/dev/null && echo "yes" || echo "no")

# Wait for proof to be ready if status is "registered" or "work_in_progress" and no proof yet
if [ "$has_proof" != "yes" ] && ([ "$status" = "registered" ] || [ "$status" = "work_in_progress" ] || [ -z "$status" ]); then
    echo "Waiting for proof to be generated..."
    
    # Poll by resending the same POST request
    max_attempts=300
    attempt=0
    proof_data=""
    
    while [ $attempt -lt $max_attempts ]; do
        sleep 2
        
        # Resend the same proof request to check status
        proof_data=$(curl -s --location --request POST "$raiko_endpoint/v2/proof" \
            --header 'Content-Type: application/json' \
            --header "Authorization: Bearer $raiko_api_key" \
            --data-raw "{
                \"network\": \"$chain\",
                \"l1_network\": \"$l1_network\",
                \"block_numbers\": [[$block_number, null], [$(($block_number+1)), null]],
                \"block_number\": $block_number,
                \"prover\": \"$prover\",
                \"graffiti\": \"$graffiti\",
                \"proof_type\": \"sgx\",
                \"sgx\": {
                    \"instance_id\": 123,
                    \"setup\": false,
                    \"bootstrap\": false,
                    \"prove\": true,
                    \"input_path\": null
                }
            }")
        
        current_status=$(echo "$proof_data" | jq -r '.data.status // .status')
        
        # Check if proof is ready
        if echo "$proof_data" | jq -e '.data.proof' > /dev/null 2>&1; then
            echo "Proof is ready!"
            break
        elif [ "$current_status" = "success" ]; then
            echo "Proof status is success!"
            break
        elif [ "$current_status" = "failed" ] || [ "$current_status" = "error" ]; then
            echo "Error: Proof generation failed with status: $current_status"
            echo "$proof_data" | jq '.'
            exit 1
        fi
        
        attempt=$((attempt + 1))
        if [ $((attempt % 10)) -eq 0 ]; then
            echo "Still waiting... (attempt $attempt/$max_attempts, status: $current_status)"
        fi
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo "Error: Proof generation timed out"
        echo "Last response:"
        echo "$proof_data" | jq '.'
        exit 1
    fi
else
    # If proof is already available, use the response
    proof_data="$proof_response"
fi

# Extract proof fields from response
# v2 API response structure: { "status": "ok", "proof_type": "sgx", "data": { "proof": { "proof": "...", "quote": "...", "input": "..." } } }
proof_json=$(echo "$proof_data" | jq -r '
    if .data.proof then
        {
            proof: (if .data.proof.proof then .data.proof.proof else "" end),
            quote: (if .data.proof.quote then .data.proof.quote else "" end),
            input: (if .data.proof.input then .data.proof.input else "" end),
            instance_address: "",
            public_key: ""
        }
    elif .proof then
        {
            proof: (if .proof then .proof else "" end),
            quote: (if .quote then .quote else "" end),
            input: (if .input then .input else "" end),
            instance_address: "",
            public_key: ""
        }
    else
        {
            proof: "",
            quote: "",
            input: "",
            instance_address: "",
            public_key: ""
        }
    end
')

# Check if proof fields are present
proof_value=$(echo "$proof_json" | jq -r '.proof')
if [ -z "$proof_value" ] || [ "$proof_value" = "null" ]; then
    echo "Error: Could not extract proof from response"
    echo "$proof_data" | jq '.'
    exit 1
fi

# Check proof length (should be 89 bytes for one-shot or 109 bytes for aggregation)
proof_hex=$(echo "$proof_value" | sed 's/^0x//')
proof_length=$(( ${#proof_hex} / 2 ))

if [ "$proof_length" -eq 89 ]; then
    echo "Proof length verified: $proof_length bytes (one-shot)"
elif [ "$proof_length" -eq 109 ]; then
    echo "Proof length verified: $proof_length bytes (aggregation, will extract one-shot info)"
else
    echo "Error: Invalid proof length. Expected 89 (one-shot) or 109 (aggregation) bytes, got $proof_length bytes"
    exit 1
fi

# Save proof to temporary file
proof_file=$(mktemp)
echo "$proof_json" > "$proof_file"
echo ""
echo "Proof saved to: $proof_file"
echo ""

# Step 2: Verify the proof
echo "=== Verifying proof ==="
echo ""

# Get project root directory
project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier_binary="$project_root/target/release/sgx-verifier"

# Check if release binary exists, if not, build it
if [ ! -f "$verifier_binary" ]; then
    echo "Release binary not found. Building sgx-verifier in release mode..."
    cd "$project_root"
    cargo build -p raiko-verifier --release
    if [ ! -f "$verifier_binary" ]; then
        echo "Error: Failed to build sgx-verifier"
        exit 1
    fi
    echo "Build complete!"
    echo ""
fi

# Build verifier command
verifier_cmd="$verifier_binary --file $proof_file"

# Add optional parameters for full verification
if [ -n "$rpc_url" ]; then
    verifier_cmd="$verifier_cmd --generate-guest-input --network $chain --block-number $block_number --l1-network $l1_network --prover $prover --graffiti $graffiti --rpc-url $rpc_url"
elif command -v jq > /dev/null 2>&1; then
    # Try to get RPC URL from chain spec or use default
    verifier_cmd="$verifier_cmd --generate-guest-input --network $chain --block-number $block_number --l1-network $l1_network --prover $prover --graffiti $graffiti"
fi

# Run verifier
cd "$project_root"
if eval "$verifier_cmd"; then
    echo ""
    echo "=== Verification successful! ==="
    rm -f "$proof_file"
    exit 0
else
    echo ""
    echo "=== Verification failed! ==="
    echo "Proof file kept at: $proof_file"
    exit 1
fi

