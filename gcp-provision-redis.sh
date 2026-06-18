#!/bin/bash
set -eo pipefail

# ==============================================================================
# DEFAULT CONFIGURATION VARIABLES
# ==============================================================================
PROJECT_ID="alpfr-splunk-integration"
REGION="us-central1"
ZONE="us-central1-a"
NETWORK="default"
REDIS_INSTANCE_NAME="redis-cache"

# ==============================================================================
# USAGE HELP
# ==============================================================================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --project ID       GCP Project ID (default: $PROJECT_ID)"
    echo "  -r, --region REGION    GCP Region (default: $REGION)"
    echo "  -z, --zone ZONE        GCP Zone (default: $ZONE)"
    echo "  -n, --network NETWORK  VPC Network name (default: $NETWORK)"
    echo "  -i, --instance NAME    Memorystore Redis instance name (default: $REDIS_INSTANCE_NAME)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --project my-gcp-project --network prod-vpc --instance my-redis"
    exit 1
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--project)
            PROJECT_ID="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -z|--zone)
            ZONE="$2"
            shift 2
            ;;
        -n|--network)
            NETWORK="$2"
            shift 2
            ;;
        -i|--instance)
            REDIS_INSTANCE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

echo "======================================================================"
echo "Provisioning GCP Memorystore Redis Instance"
echo "  Project:    $PROJECT_ID"
echo "  Region:     $REGION"
echo "  Zone:       $ZONE"
echo "  Network:    $NETWORK"
echo "  Instance:   $REDIS_INSTANCE_NAME"
echo "======================================================================"

# 1. Enable GCP Services
echo "Enabling GCP APIs..."
gcloud services enable \
    compute.googleapis.com \
    redis.googleapis.com \
    servicenetworking.googleapis.com \
    --project="$PROJECT_ID"

# 2. Configure Private Service Access (Required for Memorystore)
echo "Configuring Private Service Access for network '$NETWORK'..."
if ! gcloud compute addresses describe google-managed-services-"$NETWORK" --global --project="$PROJECT_ID" &>/dev/null; then
    gcloud compute addresses create google-managed-services-"$NETWORK" \
        --global \
        --purpose=VPC_PEERING \
        --prefix-length=16 \
        --network="$NETWORK" \
        --project="$PROJECT_ID"
    echo "Allocated IP range for Google services."
else
    echo "IP range google-managed-services-$NETWORK is already allocated."
fi

# Establish the private connection
echo "Establishing VPC Peering with Google services..."
if ! gcloud services vpc-peerings list --network="$NETWORK" --project="$PROJECT_ID" 2>/dev/null | grep -q "servicenetworking.googleapis.com"; then
    gcloud services vpc-peerings connect \
        --service=servicenetworking.googleapis.com \
        --ranges=google-managed-services-"$NETWORK" \
        --network="$NETWORK" \
        --project="$PROJECT_ID"
    echo "Private Service Access connection established."
else
    echo "Private Service Access connection already exists."
fi

# 3. Create GCP Memorystore Redis Instance
echo "Creating Memorystore Redis instance (this can take 2-4 minutes)..."
if ! gcloud redis instances describe "$REDIS_INSTANCE_NAME" --region "$REGION" --project="$PROJECT_ID" &>/dev/null; then
    gcloud redis instances create "$REDIS_INSTANCE_NAME" \
        --size=1 \
        --region="$REGION" \
        --zone="$ZONE" \
        --redis-version=redis_7_0 \
        --network="projects/$PROJECT_ID/global/networks/$NETWORK" \
        --connect-mode=private-service-access \
        --project="$PROJECT_ID"
    echo "Memorystore Redis instance created successfully."
else
    echo "Memorystore Redis instance '$REDIS_INSTANCE_NAME' already exists."
fi

# 4. Retrieve and Print Redis Host IP
echo "Retrieving Memorystore IP address..."
REDIS_IP=$(gcloud redis instances describe "$REDIS_INSTANCE_NAME" --region "$REGION" --project="$PROJECT_ID" --format="value(host)")

echo "======================================================================"
echo "Memorystore Provisioning Complete!"
echo "Redis Instance IP: $REDIS_IP"
echo "Port:              6379"
echo "Connection String: $REDIS_IP:6379"
echo "======================================================================"
