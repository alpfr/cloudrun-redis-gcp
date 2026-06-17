#!/bin/bash
set -eo pipefail

# ==============================================================================
# DEFAULT CONFIGURATION VARIABLES
# ==============================================================================
PROJECT_ID="alpfr-splunk-integration"
REGION="us-central1"
ZONE="us-central1-a"
NETWORK="default"
SUBNET="default"
REDIS_INSTANCE_NAME="redis-cache"
ARTIFACT_REPO="" # If left empty, GCR (gcr.io) is used. If set, GCP Artifact Registry is used.

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
    echo "  -s, --subnet SUBNET    VPC Subnet name (default: $SUBNET)"
    echo "  -i, --instance NAME    Memorystore Redis instance name (default: $REDIS_INSTANCE_NAME)"
    echo "  -k, --repo NAME        GCP Artifact Registry repository name (default: use GCR)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --project my-project --repo my-docker-repo --region us-east4"
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
        -s|--subnet)
            SUBNET="$2"
            shift 2
            ;;
        -i|--instance)
            REDIS_INSTANCE_NAME="$2"
            shift 2
            ;;
        -k|--repo)
            ARTIFACT_REPO="$2"
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
echo "Preparing deployment on GCP"
echo "  Project:    $PROJECT_ID"
echo "  Region:     $REGION"
echo "  Zone:       $ZONE"
echo "  Network:    $NETWORK"
echo "  Subnet:     $SUBNET"
echo "  Instance:   $REDIS_INSTANCE_NAME"
if [[ -n "$ARTIFACT_REPO" ]]; then
echo "  Registry:   Artifact Registry (Repo: $ARTIFACT_REPO)"
else
echo "  Registry:   Google Container Registry (gcr.io)"
fi
echo "======================================================================"

# 1. Enable GCP Services
echo "Enabling GCP APIs..."
gcloud services enable \
    compute.googleapis.com \
    redis.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    servicenetworking.googleapis.com \
    --project="$PROJECT_ID"

if [[ -n "$ARTIFACT_REPO" ]]; then
    gcloud services enable artifactregistry.googleapis.com --project="$PROJECT_ID"
fi

# 1.5. Configure Private Service Access (Required for Memorystore)
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

# 2. Check/Create GCP Memorystore Redis Instance
echo "Checking/creating Memorystore Redis instance..."
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

# 3. Retrieve Redis Host IP
echo "Retrieving Memorystore IP address..."
REDIS_IP=$(gcloud redis instances describe "$REDIS_INSTANCE_NAME" --region "$REGION" --project="$PROJECT_ID" --format="value(host)")
echo "Redis Private IP: $REDIS_IP"

# 4. Check/Create Artifact Registry Repository if specified
if [[ -n "$ARTIFACT_REPO" ]]; then
    echo "Checking/creating Artifact Registry repository '$ARTIFACT_REPO'..."
    if ! gcloud artifacts repositories describe "$ARTIFACT_REPO" --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        gcloud artifacts repositories create "$ARTIFACT_REPO" \
            --repository-format=docker \
            --location="$REGION" \
            --description="Docker repository for Flask Redis App" \
            --project="$PROJECT_ID"
        echo "Artifact Registry repository created successfully."
    else
        echo "Artifact Registry repository '$ARTIFACT_REPO' already exists."
    fi
    IMAGE_TAG="$REGION-docker.pkg.dev/$PROJECT_ID/$ARTIFACT_REPO/flask-redis-app:latest"
else
    IMAGE_TAG="gcr.io/$PROJECT_ID/flask-redis-app:latest"
fi

# 5. Build and Push Python Container via Cloud Build
echo "Building the Python application container..."
echo "Target Image Tag: $IMAGE_TAG"
gcloud builds submit app/ --tag "$IMAGE_TAG" --project="$PROJECT_ID"

# 6. Update service.yaml with actual values and Deploy to Cloud Run
echo "Preparing service.yaml with actual configurations..."
TEMP_SERVICE_YAML="cloudrun/service_temp.yaml"

# Replace placeholders in template service.yaml (using Direct VPC Egress)
sed -e "s|gcr.io/alpfr-splunk-integration/flask-redis-app:latest|$IMAGE_TAG|g" \
    -e "s|YOUR_PROJECT_ID|$PROJECT_ID|g" \
    -e "s|YOUR_REGION|$REGION|g" \
    -e "s|YOUR_NETWORK|$NETWORK|g" \
    -e "s|YOUR_SUBNET|$SUBNET|g" \
    -e "s|YOUR_REDIS_IP|$REDIS_IP|g" \
    cloudrun/service.yaml > "$TEMP_SERVICE_YAML"

echo "Deploying container to Cloud Run..."
gcloud beta run services replace "$TEMP_SERVICE_YAML" --region "$REGION" --project="$PROJECT_ID"

# Clean up temp file
rm -f "$TEMP_SERVICE_YAML"

# 7. Allow unauthenticated requests (Public Ingress)
echo "Setting Cloud Run IAM policy to allow public access..."
gcloud run services add-iam-policy-binding flask-redis-app \
    --region="$REGION" \
    --member="allUsers" \
    --role="roles/run.invoker" \
    --project="$PROJECT_ID"

# Get Cloud Run Service URL
SERVICE_URL=$(gcloud run services describe flask-redis-app --region "$REGION" --project="$PROJECT_ID" --format="value(status.url)")

echo "======================================================================"
echo "Deployment Complete!"
echo "Cloud Run Service URL: $SERVICE_URL"
echo "======================================================================"
