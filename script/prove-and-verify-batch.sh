#!/usr/bin/env bash

# Script to prove and verify a batch of continuous blocks using SGX batch proof

set -e

# Default values
raiko_endpoint=${raiko_endpoint:-"http://localhost:8080"}
raiko_api_key=${raiko_api_key:-"4cbd753fbcbc2639de804f8ce425016a50e0ecd53db00cb5397912e83f5e570e"}
prover=${prover:-"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}
graffiti=${graffiti:-"8008500000000000000000000000000000000000000000000000000000000000"}

usage() {
    echo "Usage:"
    echo "  prove-and-verify-batch.sh <chain> <start_block> <end_block> [rpc_url]"
    echo ""
    echo "Arguments:"
    echo "  chain          Network name (e.g., devnet, taiko_a7, taiko_mainnet)"
    echo "  start_block    Starting block number (inclusive)"
    echo "  end_block      Ending block number (inclusive)"
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
if [ $# -lt 3 ]; then
    usage
fi

chain="$1"
start_block="$2"
end_block="$3"
rpc_url="${4:-http://52.48.173.231:18545}"

# Validate block range
if [ "$start_block" -ge "$end_block" ]; then
    echo "Error: start_block ($start_block) must be less than end_block ($end_block)"
    exit 1
fi

block_count=$((end_block - start_block + 1))
if [ "$block_count" -gt 1000 ]; then
    echo "Error: Block range too large (max 1000 blocks, got $block_count)"
    exit 1
fi

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

echo "=== Proving batch blocks $start_block to $end_block on $chain ==="
echo "L1 Network: $l1_network"
echo "Block Count: $block_count"
echo ""

# Build block numbers array
block_numbers="["
for ((i=start_block; i<=end_block; i++)); do
    if [ $i -gt $start_block ]; then
        block_numbers+=", "
    fi
    block_numbers+="$i"
done
block_numbers+="]"

# Build the request JSON for batch proof
request_json=$(cat <<EOF
{
    "network": "$chain",
    "l1_network": "$l1_network",
    "batches": [{
        "batch_id": 0,
        "l1_inclusion_block_number": 0
    }],
    "prover": "$prover",
    "aggregate": false,
    "prover_args": {
        "start_block": $start_block,
        "end_block": $end_block,
        "block_numbers": $block_numbers
    },
    "proof_type": "sgx",
    "sgx": {
        "instance_id": 123,
        "setup": false,
        "bootstrap": false,
        "prove": true,
        "input_path": null
    }
}
EOF
)

# Step 1: Submit batch proof request
echo "Submitting batch proof request..."
proof_response=$(curl -s --location --request POST "$raiko_endpoint/v3/proof/batch" \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $raiko_api_key" \
    --data-raw "$request_json")

# Check if proof request was successful
if ! echo "$proof_response" | jq -e '.status == "ok" or .status == "Ok"' > /dev/null 2>&1; then
    echo "Error: Batch proof request failed"
    echo "$proof_response" | jq '.' 2>/dev/null || echo "$proof_response"
    exit 1
fi

status=$(echo "$proof_response" | jq -r '.data.status // .status // empty' 2>/dev/null)
echo "Batch proof request status: ${status:-none}"

# Check if proof is already in response
has_proof=$(echo "$proof_response" | jq -e '.data.proof != null or .data.batch_proof != null' 2>/dev/null && echo "yes" || echo "no")

# Wait for proof to be ready if status is "registered" or "work_in_progress" and no proof yet
if [ "$has_proof" != "yes" ] && ([ "$status" = "registered" ] || [ "$status" = "work_in_progress" ] || [ -z "$status" ]); then
    echo "Waiting for batch proof to be generated..."
    
    # Extract task key from response
    task_key=$(echo "$proof_response" | jq -r '.data.task_key // .task_key // empty' 2>/dev/null)
    
    if [ -z "$task_key" ]; then
        echo "Warning: Could not extract task key, will poll by resending request"
        task_key=""
    fi
    
    # Poll for proof status
    max_attempts=600  # Batch proofs may take longer
    attempt=0
    proof_data=""
    
    while [ $attempt -lt $max_attempts ]; do
        sleep 5  # Poll every 5 seconds for batch proofs
        
        if [ -n "$task_key" ]; then
            # Poll using task key if available
            proof_data=$(curl -s --location --request GET "$raiko_endpoint/v3/proof/batch?task_key=$task_key" \
                --header "Authorization: Bearer $raiko_api_key")
        else
            # Resend the same batch proof request to check status
            proof_data=$(curl -s --location --request POST "$raiko_endpoint/v3/proof/batch" \
                --header 'Content-Type: application/json' \
                --header "Authorization: Bearer $raiko_api_key" \
                --data-raw "$request_json")
        fi
        
        current_status=$(echo "$proof_data" | jq -r '.data.status // .status // empty' 2>/dev/null)
        
        # Check if proof is ready
        if echo "$proof_data" | jq -e '.data.proof or .data.batch_proof' > /dev/null 2>&1; then
            echo "Batch proof is ready!"
            break
        elif [ "$current_status" = "success" ]; then
            echo "Batch proof status is success!"
            break
        elif [ "$current_status" = "failed" ] || [ "$current_status" = "error" ]; then
            echo "Error: Batch proof generation failed with status: $current_status"
            echo "$proof_data" | jq '.' 2>/dev/null || echo "$proof_data"
            exit 1
        fi
        
        attempt=$((attempt + 1))
        if [ $((attempt % 20)) -eq 0 ]; then
            echo "Still waiting... (attempt $attempt/$max_attempts, status: $current_status)"
        fi
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo "Error: Batch proof generation timed out"
        echo "Last response:"
        echo "$proof_data" | jq '.' 2>/dev/null || echo "$proof_data"
        exit 1
    fi
else
    # If proof is already available, use the response
    proof_data="$proof_response"
fi

# Extract proof fields from response
# v3 batch API response structure may vary, try different paths
proof_json=$(echo "$proof_data" | jq -r '
    if .data.batch_proof then
        {
            proof: (if .data.batch_proof.proof then .data.batch_proof.proof else "" end),
            quote: (if .data.batch_proof.quote then .data.batch_proof.quote else "" end),
            input: (if .data.batch_proof.input then .data.batch_proof.input else "" end),
            instance_address: (if .data.batch_proof.instance_address then .data.batch_proof.instance_address else "" end),
            public_key: (if .data.batch_proof.public_key then .data.batch_proof.public_key else "" end)
        }
    elif .data.proof then
        {
            proof: (if .data.proof.proof then .data.proof.proof else "" end),
            quote: (if .data.proof.quote then .data.proof.quote else "" end),
            input: (if .data.proof.input then .data.proof.input else "" end),
            instance_address: (if .data.proof.instance_address then .data.proof.instance_address else "" end),
            public_key: (if .data.proof.public_key then .data.proof.public_key else "" end)
        }
    elif .batch_proof then
        {
            proof: (if .batch_proof.proof then .batch_proof.proof else "" end),
            quote: (if .batch_proof.quote then .batch_proof.quote else "" end),
            input: (if .batch_proof.input then .batch_proof.input else "" end),
            instance_address: (if .batch_proof.instance_address then .batch_proof.instance_address else "" end),
            public_key: (if .batch_proof.public_key then .batch_proof.public_key else "" end)
        }
    elif .proof then
        {
            proof: (if .proof then .proof else "" end),
            quote: (if .quote then .quote else "" end),
            input: (if .input then .input else "" end),
            instance_address: (if .instance_address then .instance_address else "" end),
            public_key: (if .public_key then .public_key else "" end)
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
' 2>/dev/null)

# Check if proof fields are present
proof_value=$(echo "$proof_json" | jq -r '.proof' 2>/dev/null)
if [ -z "$proof_value" ] || [ "$proof_value" = "null" ] || [ "$proof_value" = "" ]; then
    echo "Error: Could not extract proof from response"
    echo "$proof_data" | jq '.' 2>/dev/null || echo "$proof_data"
    exit 1
fi

# Check proof length (should be 89 bytes for batch proof)
proof_hex=$(echo "$proof_value" | sed 's/^0x//')
proof_length=$(( ${#proof_hex} / 2 ))

if [ "$proof_length" -eq 89 ]; then
    echo "Proof length verified: $proof_length bytes (batch proof)"
elif [ "$proof_length" -eq 109 ]; then
    echo "Proof length verified: $proof_length bytes (aggregation, will extract batch info)"
else
    echo "Warning: Unexpected proof length. Expected 89 (batch) or 109 (aggregation) bytes, got $proof_length bytes"
fi

# Save proof to temporary file
proof_file=$(mktemp)
echo "$proof_json" > "$proof_file"
echo ""
echo "Proof saved to: $proof_file"
echo ""

# Step 2: Verify the batch proof
echo "=== Verifying batch proof ==="
echo ""

# Get project root directory
project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier_binary="$project_root/target/release/sgx-verifier"

# Check if release binary exists, if not, build it
if [ ! -f "$verifier_binary" ]; then
    echo "Release binary not found. Building sgx-verifier in release mode..."
    cd "$project_root"
    cargo build -p raiko-verifier --release --bin sgx-verifier
    if [ ! -f "$verifier_binary" ]; then
        echo "Error: Failed to build sgx-verifier"
        exit 1
    fi
    echo "Build complete!"
    echo ""
fi

# Build verifier command for batch proof
verifier_cmd="$verifier_binary --file $proof_file --batch"

# Add optional parameters for full verification
if [ -n "$rpc_url" ]; then
    verifier_cmd="$verifier_cmd --generate-batch-guest-input --network $chain --start-block $start_block --end-block $end_block --l1-network $l1_network --prover $prover --graffiti $graffiti --rpc-url $rpc_url"
elif command -v jq > /dev/null 2>&1; then
    # Try to get RPC URL from chain spec or use default
    verifier_cmd="$verifier_cmd --generate-batch-guest-input --network $chain --start-block $start_block --end-block $end_block --l1-network $l1_network --prover $prover --graffiti $graffiti"
fi

# Run verifier
cd "$project_root"
if eval "$verifier_cmd"; then
    echo ""
    echo "=== Batch proof verification successful! ==="
    rm -f "$proof_file"
    exit 0
else
    echo ""
    echo "=== Batch proof verification failed! ==="
    echo "Proof file kept at: $proof_file"
    exit 1
fi

