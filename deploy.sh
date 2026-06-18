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
ENABLE_LB="false" # Set to true via argument --load-balancer to configure HTTP Load Balancer.

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
    echo "  -l, --load-balancer    Enable Global HTTP Load Balancer with Serverless NEG (default: $ENABLE_LB)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --project my-project --repo my-docker-repo --load-balancer"
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
        -l|--load-balancer)
            ENABLE_LB="true"
            shift 1
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
echo "  Load Balancer: $ENABLE_LB"
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

# 7. Ingress Access configurations
if [[ "$ENABLE_LB" == "true" ]]; then
    echo "======================================================================"
    echo "Configuring Global External HTTP Load Balancer..."
    echo "======================================================================"

    # 1. Create Serverless Network Endpoint Group (NEG)
    echo "Checking/creating Serverless Network Endpoint Group (NEG)..."
    if ! gcloud compute network-endpoint-groups describe flask-app-neg --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute network-endpoint-groups create flask-app-neg \
            --region="$REGION" \
            --network-endpoint-type=serverless \
            --cloud-run-service=flask-redis-app \
            --project="$PROJECT_ID"
        echo "Serverless NEG created."
    else
        echo "Serverless NEG 'flask-app-neg' already exists."
    fi

    # 2. Create Backend Service
    echo "Checking/creating Backend Service..."
    if ! gcloud compute backend-services describe flask-app-backend --global --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute backend-services create flask-app-backend \
            --global \
            --load-balancing-scheme=EXTERNAL_MANAGED \
            --project="$PROJECT_ID"
        echo "Backend service created."
    else
        echo "Backend service 'flask-app-backend' already exists."
    fi

    # 3. Attach Serverless NEG to Backend Service
    echo "Checking/attaching Serverless NEG to Backend Service..."
    if ! gcloud compute backend-services describe flask-app-backend --global --project="$PROJECT_ID" --format="value(backends[0].group)" | grep -q "flask-app-neg"; then
        gcloud compute backend-services add-backend flask-app-backend \
            --global \
            --network-endpoint-group=flask-app-neg \
            --network-endpoint-group-region="$REGION" \
            --project="$PROJECT_ID"
        echo "Serverless NEG attached to backend service."
    else
        echo "Serverless NEG is already attached to backend service."
    fi

    # 4. Create URL Map
    echo "Checking/creating URL Map..."
    if ! gcloud compute url-maps describe flask-app-url-map --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute url-maps create flask-app-url-map \
            --default-service=flask-app-backend \
            --project="$PROJECT_ID"
        echo "URL Map created."
    else
        echo "URL Map 'flask-app-url-map' already exists."
    fi

    # 5. Create Target HTTP Proxy
    echo "Checking/creating Target HTTP Proxy..."
    if ! gcloud compute target-http-proxies describe flask-app-http-proxy --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute target-http-proxies create flask-app-http-proxy \
            --url-map=flask-app-url-map \
            --project="$PROJECT_ID"
        echo "Target HTTP Proxy created."
    else
        echo "Target HTTP Proxy 'flask-app-http-proxy' already exists."
    fi

    # 6. Allocate Global Static IP
    echo "Checking/allocating Global External Static IP..."
    if ! gcloud compute addresses describe flask-app-lb-ip --global --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute addresses create flask-app-lb-ip \
            --global \
            --ip-version=IPV4 \
            --project="$PROJECT_ID"
        echo "Global External Static IP allocated."
    else
        echo "Static IP 'flask-app-lb-ip' already allocated."
    fi
    LB_IP=$(gcloud compute addresses describe flask-app-lb-ip --global --project="$PROJECT_ID" --format="value(address)")

    # 7. Create Global Forwarding Rule
    echo "Checking/creating Global Forwarding Rule..."
    if ! gcloud compute forwarding-rules describe flask-app-http-forwarding-rule --global --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute forwarding-rules create flask-app-http-forwarding-rule \
            --global \
            --load-balancing-scheme=EXTERNAL_MANAGED \
            --target-http-proxy=flask-app-http-proxy \
            --ports=80 \
            --address=flask-app-lb-ip \
            --project="$PROJECT_ID"
        echo "Global Forwarding Rule created."
    else
        echo "Forwarding Rule 'flask-app-http-forwarding-rule' already exists."
    fi

    # 8. Security Best Practice: Restrict direct Cloud Run access, only allow traffic through Load Balancer
    echo "Restricting Cloud Run service to internal and load balancer traffic only..."
    gcloud run services update flask-redis-app \
        --ingress=internal-and-cloud-load-balancing \
        --region="$REGION" \
        --project="$PROJECT_ID"

    # Fetch Cloud Run URL (internally only for reference)
    SERVICE_URL=$(gcloud run services describe flask-redis-app --region "$REGION" --project="$PROJECT_ID" --format="value(status.url)")

    echo "======================================================================"
    echo "Deployment Complete (with Load Balancer)!"
    echo "Load Balancer Frontend IP: http://$LB_IP"
    echo "Cloud Run URL (Restricted Access): $SERVICE_URL"
    echo "======================================================================"

else
    # Allow unauthenticated direct public requests to Cloud Run
    echo "Setting Cloud Run IAM policy to allow public access..."
    gcloud run services add-iam-policy-binding flask-redis-app \
        --region="$REGION" \
        --member="allUsers" \
        --role="roles/run.invoker" \
        --project="$PROJECT_ID"

    # Make sure direct public ingress is allowed
    gcloud run services update flask-redis-app \
        --ingress=all \
        --region="$REGION" \
        --project="$PROJECT_ID"

    # Get Cloud Run Service URL
    SERVICE_URL=$(gcloud run services describe flask-redis-app --region "$REGION" --project="$PROJECT_ID" --format="value(status.url)")

    echo "======================================================================"
    echo "Deployment Complete!"
    echo "Cloud Run Service URL: $SERVICE_URL"
    echo "======================================================================"
fi
