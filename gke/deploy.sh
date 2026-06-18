#!/bin/bash
set -eo pipefail

# ==============================================================================
# DEFAULT CONFIGURATION VARIABLES
# ==============================================================================
PROJECT_ID="alpfr-splunk-integration"
REGION="us-central1"
ZONE="us-central1-a"
CLUSTER_NAME="" # GKE cluster name (required)
ARTIFACT_REPO="" # Optional: GCP Artifact Registry repo. If blank, GCR is used.

# ==============================================================================
# USAGE HELP
# ==============================================================================
usage() {
    echo "Usage: $0 --cluster CLUSTER_NAME [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --cluster NAME     GKE Cluster Name (Required)"
    echo "  -p, --project ID       GCP Project ID (default: $PROJECT_ID)"
    echo "  -r, --region REGION    GCP Region (default: $REGION)"
    echo "  -z, --zone ZONE        GCP Zone (default: $ZONE)"
    echo "  -k, --repo NAME        GCP Artifact Registry repository name (default: use GCR)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --cluster my-gke-cluster --project my-project"
    exit 1
}

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
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

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "Error: Cluster name (--cluster) is required."
    usage
fi

echo "======================================================================"
echo "Preparing GKE Deployment on GCP"
echo "  Project:    $PROJECT_ID"
echo "  Cluster:    $CLUSTER_NAME"
echo "  Region:     $REGION"
echo "  Zone:       $ZONE"
if [[ -n "$ARTIFACT_REPO" ]]; then
echo "  Registry:   Artifact Registry (Repo: $ARTIFACT_REPO)"
else
echo "  Registry:   Google Container Registry (gcr.io)"
fi
echo "======================================================================"

# 1. Enable GCP Services
echo "Enabling GCP APIs..."
gcloud services enable \
    container.googleapis.com \
    cloudbuild.googleapis.com \
    compute.googleapis.com \
    filestore.googleapis.com \
    --project="$PROJECT_ID"

if [[ -n "$ARTIFACT_REPO" ]]; then
    gcloud services enable artifactregistry.googleapis.com --project="$PROJECT_ID"
fi

# 2. Get GKE Cluster Credentials
echo "Retrieving GKE cluster credentials..."
# GKE standard clusters are zonal or regional. We check both paths for convenience.
if [[ -n "$ZONE" ]]; then
    gcloud container clusters get-credentials "$CLUSTER_NAME" --zone="$ZONE" --project="$PROJECT_ID"
else
    gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID"
fi

# 3. Check/Create Artifact Registry Repository if specified
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

# 4. Build and Push Python Container via Cloud Build
echo "Building the Python application container..."
echo "Target Image Tag: $IMAGE_TAG"
gcloud builds submit ../app/ --tag "$IMAGE_TAG" --project="$PROJECT_ID"

# 5. Update app-deployment.yaml with the new image
echo "Configuring app-deployment.yaml with the target container image..."
TEMP_DEPLOYMENT_YAML="app-deployment_temp.yaml"

sed "s|gcr.io/alpfr-splunk-integration/flask-redis-app:latest|$IMAGE_TAG|g" \
    app-deployment.yaml > "$TEMP_DEPLOYMENT_YAML"

# 6. Apply Kubernetes Manifests to GKE
echo "Applying GKE manifests..."
kubectl apply -f storage.yaml
kubectl apply -f configmap.yaml
kubectl apply -f service.yaml
kubectl apply -f statefulset.yaml
kubectl apply -f "$TEMP_DEPLOYMENT_YAML"

# Apply Gateway/VirtualService (Requires Istio to be installed in the GKE cluster)
echo "Checking and applying Istio configurations..."
if kubectl get crd gateways.networking.istio.io &>/dev/null; then
    kubectl apply -f gateway.yaml
    kubectl apply -f virtualservice.yaml
    echo "Istio Gateway and VirtualService applied."
else
    echo "Warning: Istio CRDs are not installed in the cluster. Skipping Istio manifests."
fi

# Clean up temp file
rm -f "$TEMP_DEPLOYMENT_YAML"

echo "======================================================================"
echo "GKE Deployment Complete!"
echo "Verify status: kubectl get pods,pvc,svc"
echo "======================================================================"
