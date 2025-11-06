#!/usr/bin/env bash

# Test script for continuous block batch proof functionality
# This script tests the new continuous block batch feature that supports
# generating a single proof for multiple continuous blocks
#
# NOTE: This script requires the API to support continuous block ranges.
# If the API doesn't support it yet, you may need to modify the backend
# to handle batch_id=0 as a special case for continuous blocks.
#
# For testing the core functionality directly, you can also use the Rust API:
#   raiko.prove_continuous_blocks(provider, start_block, end_block).await
#
# Usage examples:
#   ./test-continuous-batch.sh ethereum native 100 105
#   ./test-continuous-batch.sh taiko_a7 native 1000 1005 --wait
#   ./test-continuous-batch.sh holesky sp1 5000 5010 --endpoint http://localhost:8080

set -e

# Default values
RAIKO_ENDPOINT=${RAIKO_ENDPOINT:-"http://localhost:8080"}
PROVER=${PROVER:-"0x70997970C51812dc3A010C7d01b50e0d17dc79C8"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 <chain> <proof_type> <start_block> <end_block> [options]"
    echo ""
    echo "Arguments:"
    echo "  chain          Chain name (e.g., ethereum, holesky, taiko_a7, taiko_mainnet, taiko_dev)"
    echo "  proof_type     Proof type (native, sp1, risc0, sgx, sgxgeth)"
    echo "  start_block    Starting block number"
    echo "  end_block      Ending block number (inclusive)"
    echo ""
    echo "Options:"
    echo "  --endpoint     Raiko API endpoint (default: http://localhost:8080)"
    echo "  --prover       Prover address (default: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8)"
    echo "  --wait         Wait for proof completion and show result"
    echo "  --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 ethereum native 100 105"
    echo "  $0 taiko_a7 native 1000 1005 --wait"
    echo "  $0 holesky sp1 5000 5010 --endpoint http://localhost:8080"
    exit 1
}

# Parse arguments
if [ $# -lt 4 ]; then
    usage
fi

CHAIN="$1"
PROOF_TYPE="$2"
START_BLOCK="$3"
END_BLOCK="$4"
WAIT_FOR_COMPLETION=false

shift 4

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --endpoint)
            RAIKO_ENDPOINT="$2"
            shift 2
            ;;
        --prover)
            PROVER="$2"
            shift 2
            ;;
        --wait)
            WAIT_FOR_COMPLETION=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Validate block range
if [ "$START_BLOCK" -ge "$END_BLOCK" ]; then
    echo -e "${RED}Error: start_block ($START_BLOCK) must be less than end_block ($END_BLOCK)${NC}"
    exit 1
fi

BLOCK_COUNT=$((END_BLOCK - START_BLOCK + 1))
if [ "$BLOCK_COUNT" -gt 1000 ]; then
    echo -e "${RED}Error: Block range too large (max 1000 blocks, got $BLOCK_COUNT)${NC}"
    exit 1
fi

# Determine L1 network based on chain
case "$CHAIN" in
    ethereum)
        L1_NETWORK="ethereum"
        ;;
    holesky)
        L1_NETWORK="holesky"
        ;;
    taiko_mainnet)
        L1_NETWORK="ethereum"
        ;;
    taiko_a7)
        L1_NETWORK="holesky"
        ;;
    taiko_hoodi)
        L1_NETWORK="hoodi"
        ;;
    taiko_dev)
        L1_NETWORK="taiko_dev_l1"
        ;;
    devnet)
        L1_NETWORK="devnet"
        ;;
    *)
        echo -e "${YELLOW}Warning: Unknown chain '$CHAIN', using holesky as L1 network${NC}"
        L1_NETWORK="holesky"
        ;;
esac

# Build proof parameters based on proof type
case "$PROOF_TYPE" in
    native)
        PROOF_PARAM='
    "proof_type": "native",
    "blob_proof_type": "proof_of_equivalence",
    "native": {
        "json_guest_input": null
    }'
        ;;
    sp1)
        PROOF_PARAM='
    "proof_type": "sp1",
    "blob_proof_type": "proof_of_equivalence",
    "sp1": {
        "recursion": "plonk",
        "prover": "network",
        "verify": true
    }'
        ;;
    risc0)
        PROOF_PARAM='
    "proof_type": "risc0",
    "blob_proof_type": "proof_of_equivalence",
    "risc0": {
        "bonsai": false,
        "snark": false,
        "profile": true,
        "execution_po2": 18
    }'
        ;;
    risc0-bonsai)
        PROOF_PARAM='
    "proof_type": "risc0",
    "blob_proof_type": "proof_of_equivalence",
    "risc0": {
        "bonsai": true,
        "snark": true,
        "profile": false,
        "execution_po2": 20
    }'
        ;;
    sgx)
        PROOF_PARAM='
    "proof_type": "sgx",
    "sgx": {
        "instance_id": 123,
        "setup": false,
        "bootstrap": false,
        "prove": true,
        "input_path": null
    }'
        ;;
    sgxgeth)
        PROOF_PARAM='
    "proof_type": "sgxgeth",
    "sgxgeth": {
        "instance_id": 456,
        "setup": false,
        "bootstrap": false,
        "prove": true,
        "input_path": null
    }'
        ;;
    *)
        echo -e "${RED}Error: Invalid proof type '$PROOF_TYPE'${NC}"
        echo "Valid proof types: native, sp1, risc0, risc0-bonsai, sgx, sgxgeth"
        exit 1
        ;;
esac

# Build block numbers array
BLOCK_NUMBERS="["
for ((i=START_BLOCK; i<=END_BLOCK; i++)); do
    if [ $i -gt $START_BLOCK ]; then
        BLOCK_NUMBERS+=", "
    fi
    BLOCK_NUMBERS+="$i"
done
BLOCK_NUMBERS+="]"

# Build the request JSON
# For continuous blocks, we use batch_id=0 and l1_inclusion_block_number=0 as special markers
# The block range is passed via prover_args for now (until API is updated)
REQUEST_JSON=$(cat <<EOF
{
    "network": "$CHAIN",
    "l1_network": "$L1_NETWORK",
    "batches": [{
        "batch_id": 0,
        "l1_inclusion_block_number": 0
    }],
    "prover": "$PROVER",
    "aggregate": false,
    "prover_args": {
        "start_block": $START_BLOCK,
        "end_block": $END_BLOCK,
        "block_numbers": $BLOCK_NUMBERS
    },
    $PROOF_PARAM
}
EOF
)

echo -e "${GREEN}=== Continuous Block Batch Proof Test ===${NC}"
echo "Chain: $CHAIN"
echo "L1 Network: $L1_NETWORK"
echo "Proof Type: $PROOF_TYPE"
echo "Block Range: $START_BLOCK to $END_BLOCK ($BLOCK_COUNT blocks)"
echo "Endpoint: $RAIKO_ENDPOINT"
echo "Prover: $PROVER"
echo ""
echo -e "${YELLOW}Sending request...${NC}"

# Check if endpoint is reachable
if ! curl -s --connect-timeout 2 "$RAIKO_ENDPOINT/health" > /dev/null 2>&1; then
    echo -e "${RED}Error: Cannot connect to $RAIKO_ENDPOINT${NC}"
    echo "Please make sure raiko-host is running."
    echo "You can check with: curl $RAIKO_ENDPOINT/health"
    exit 1
fi

# Send the request
RESPONSE=$(curl -s -w "\n%{http_code}" \
    --connect-timeout 10 \
    --max-time 30 \
    --location --request POST "$RAIKO_ENDPOINT/v3/proof/batch" \
    --header 'Content-Type: application/json' \
    --header 'Authorization: Bearer' \
    --data-raw "$REQUEST_JSON")

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
# Extract response body (all but last line)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n -1)

# Handle curl errors
if [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" = "000" ]; then
    echo -e "${RED}Error: Failed to connect to $RAIKO_ENDPOINT${NC}"
    echo "Please check:"
    echo "  1. Is raiko-host running?"
    echo "  2. Is the endpoint correct? (current: $RAIKO_ENDPOINT)"
    echo "  3. Check firewall/network settings"
    exit 1
fi

echo -e "${GREEN}HTTP Status: $HTTP_CODE${NC}"
echo "Response:"
echo "$RESPONSE_BODY" | jq '.' 2>/dev/null || echo "$RESPONSE_BODY"

# Check if request was successful
if [ "$HTTP_CODE" -ne 200 ]; then
    echo -e "${RED}Request failed with HTTP status $HTTP_CODE${NC}"
    exit 1
fi

# Extract task key if available
TASK_KEY=$(echo "$RESPONSE_BODY" | jq -r '.data.key // empty' 2>/dev/null)
STATUS=$(echo "$RESPONSE_BODY" | jq -r '.data.status // empty' 2>/dev/null)

if [ -n "$TASK_KEY" ]; then
    echo ""
    echo -e "${GREEN}Task submitted successfully!${NC}"
    echo "Task Key: $TASK_KEY"
    echo "Status: $STATUS"
    
    if [ "$WAIT_FOR_COMPLETION" = true ]; then
        echo ""
        echo -e "${YELLOW}Waiting for proof completion...${NC}"
        
        # Poll for completion
        MAX_ATTEMPTS=300  # 5 minutes max (1 second intervals)
        ATTEMPT=0
        
        while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
            sleep 1
            ATTEMPT=$((ATTEMPT + 1))
            
            # Query status
            STATUS_RESPONSE=$(curl -s \
                --location --request POST "$RAIKO_ENDPOINT/v3/proof/batch" \
                --header 'Content-Type: application/json' \
                --header 'Authorization: Bearer' \
                --data-raw "$REQUEST_JSON")
            
            CURRENT_STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.data.status // empty' 2>/dev/null)
            
            if [ "$CURRENT_STATUS" = "success" ] || [ "$CURRENT_STATUS" = "completed" ]; then
                echo -e "${GREEN}Proof completed!${NC}"
                echo "Final Response:"
                echo "$STATUS_RESPONSE" | jq '.' 2>/dev/null || echo "$STATUS_RESPONSE"
                exit 0
            elif [ "$CURRENT_STATUS" = "failed" ] || [ "$CURRENT_STATUS" = "error" ]; then
                echo -e "${RED}Proof failed!${NC}"
                echo "Error Response:"
                echo "$STATUS_RESPONSE" | jq '.' 2>/dev/null || echo "$STATUS_RESPONSE"
                exit 1
            fi
            
            # Show progress every 10 seconds
            if [ $((ATTEMPT % 10)) -eq 0 ]; then
                echo -e "${YELLOW}Still processing... (attempt $ATTEMPT/$MAX_ATTEMPTS, status: $CURRENT_STATUS)${NC}"
            fi
        done
        
        echo -e "${RED}Timeout waiting for proof completion${NC}"
        exit 1
    else
        echo ""
        echo -e "${YELLOW}To check status, run:${NC}"
        echo "curl -X POST '$RAIKO_ENDPOINT/v3/proof/batch' \\"
        echo "  -H 'Content-Type: application/json' \\"
        echo "  -H 'Authorization: Bearer' \\"
        echo "  -d '$REQUEST_JSON'"
    fi
else
    echo -e "${YELLOW}Note: Could not extract task key from response${NC}"
fi

echo ""
echo -e "${GREEN}Test completed!${NC}"

