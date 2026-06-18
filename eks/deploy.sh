#!/bin/bash
set -eo pipefail

# ==============================================================================
# DEFAULT CONFIGURATION VARIABLES (Update these as needed)
# ==============================================================================
AWS_ACCOUNT_ID="" # AWS Account ID (required for ECR registry)
REGION="us-east-1"
CLUSTER_NAME=""   # EKS Cluster name (required)

# ==============================================================================
# USAGE HELP
# ==============================================================================
usage() {
    echo "Usage: $0 --cluster CLUSTER_NAME --account ACCOUNT_ID [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -c, --cluster NAME     EKS Cluster Name (Required)"
    echo "  -a, --account ID       AWS Account ID (Required)"
    echo "  -r, --region REGION    AWS Region (default: $REGION)"
    echo "  -h, --help             Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --cluster my-eks-cluster --account 123456789012 --region us-west-2"
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
        -a|--account)
            AWS_ACCOUNT_ID="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
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

if [[ -z "$CLUSTER_NAME" || -z "$AWS_ACCOUNT_ID" ]]; then
    echo "Error: Cluster name (--cluster) and AWS Account ID (--account) are required."
    usage
fi

IMAGE_TAG="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/flask-redis-app:latest"

echo "======================================================================"
echo "Preparing EKS Deployment on AWS"
echo "  Project/Account: $AWS_ACCOUNT_ID"
echo "  Cluster:         $CLUSTER_NAME"
echo "  Region:          $REGION"
echo "  Registry ECR:    $IMAGE_TAG"
echo "======================================================================"

# 1. Update kubeconfig for EKS Cluster
echo "Retrieving EKS cluster credentials..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# 2. Login to ECR Registry
echo "Logging in to Amazon ECR..."
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# 3. Check/Create ECR Repository
echo "Checking if ECR Repository exists..."
if ! aws ecr describe-repositories --repository-names flask-redis-app --region "$REGION" &>/dev/null; then
    echo "Creating Amazon ECR Repository 'flask-redis-app'..."
    aws ecr create-repository --repository-name flask-redis-app --region "$REGION"
else
    echo "ECR Repository 'flask-redis-app' already exists."
fi

# 4. Build and Push Python Container via Docker
echo "Building the Python application container..."
docker build -t "$IMAGE_TAG" ../app/

echo "Pushing Docker image to Amazon ECR..."
docker push "$IMAGE_TAG"

# 5. Update app-deployment.yaml with the target container image
echo "Configuring app-deployment.yaml with the target ECR image..."
TEMP_DEPLOYMENT_YAML="app-deployment_temp.yaml"

sed "s|YOUR_AWS_ACCOUNT_ID.dkr.ecr.YOUR_AWS_REGION.amazonaws.com/flask-redis-app:latest|$IMAGE_TAG|g" \
    app-deployment.yaml > "$TEMP_DEPLOYMENT_YAML"

# 6. Apply Kubernetes Manifests to EKS
echo "Applying EKS manifests..."
kubectl apply -f storage.yaml
kubectl apply -f configmap.yaml
kubectl apply -f service.yaml
kubectl apply -f statefulset.yaml
kubectl apply -f "$TEMP_DEPLOYMENT_YAML"

# Apply cert-manager Issuer and Certificate (Requires cert-manager to be installed)
echo "Checking and applying cert-manager configurations..."
if kubectl get crd certificates.cert-manager.io &>/dev/null; then
    kubectl apply -f issuer.yaml
    kubectl apply -f certificate.yaml
    echo "cert-manager Issuer and Certificate applied."
else
    echo "Warning: cert-manager CRDs are not installed in the cluster. Skipping certificate manifests."
fi

# Apply Gateway/VirtualService (Requires Istio to be installed in the EKS cluster)
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
echo "EKS Deployment Complete!"
echo "Verify status: kubectl get pods,pvc,svc"
echo "======================================================================"
