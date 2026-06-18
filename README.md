# Flask Application & Redis Deployments (Cloud Run + GKE + EKS)

This repository contains configurations and deployment scripts to run a Flask web application connected to a Redis database on GCP or AWS. It supports three target environments:
1. **Google Cloud Run (Recommended)**: Serverless app hosting connected to a managed GCP Memorystore Redis database via Direct VPC Egress.
2. **GCP GKE (Google Kubernetes Engine)**: App Deployment and a self-hosted Redis StatefulSet using Google Filestore for dynamic ReadWriteMany storage.
3. **AWS EKS (Elastic Kubernetes Service)**: App Deployment and a self-hosted Redis StatefulSet using AWS EFS for PVC storage, running over custom port layouts (VirtualService on 443, Redis Service on 6379).

---

## File Structure

```
├── app/
│   ├── app.py             # Flask application code
│   ├── Dockerfile         # Multi-stage Dockerfile
│   └── requirements.txt   # Pip dependencies
├── cloudrun/
│   └── service.yaml       # Cloud Run Knative service configuration
├── gke/
│   ├── storage.yaml       # GKE Filestore StorageClass & PVC
│   ├── configmap.yaml     # Redis configmap
│   ├── service.yaml       # Headless & ClusterIP Services
│   ├── statefulset.yaml   # Redis StatefulSet (no runAsNonRoot used)
│   ├── gateway.yaml       # Istio Gateway
│   ├── virtualservice.yaml# Istio VirtualService
│   ├── app-deployment.yaml# Flask App Deployment & Service
│   └── deploy.sh          # GKE deployment automation script
├── eks/
│   ├── storage.yaml       # EKS EFS StorageClass & PVC
│   ├── configmap.yaml     # Redis configmap
│   ├── service.yaml       # Headless & ClusterIP Services (port 6379)
│   ├── statefulset.yaml   # Redis StatefulSet (no runAsNonRoot used)
│   ├── gateway.yaml       # Istio Gateway (port 443 HTTPS TLS)
│   ├── virtualservice.yaml# Istio VirtualService (listening on port 443)
│   ├── app-deployment.yaml# Flask App Deployment & Service
│   └── deploy.sh          # EKS deployment automation script
├── gcp-cloudbuild/
│   └── cloudbuild.yaml    # CI/CD Cloud Build config
├── deploy.sh              # Cloud Run deployment automation script
├── gcp-provision-redis.sh # Script to ONLY provision Memorystore Redis
```

---

## Architecture Overview

1. **GCP Memorystore (Redis)**: Hosted privately in the `default` VPC network.
2. **Private Service Access**: A private VPC peering connection established with Google services (`servicenetworking.googleapis.com`) to allow the creation of Memorystore instances with private IP addresses.
3. **Cloud Run**: Fully serverless environment hosting the Python application.
4. **Direct VPC Egress**: Configured on Cloud Run using the `run.googleapis.com/network-interfaces` annotation. Egress traffic is routed directly through your `default` VPC subnet, allowing serverless functions to connect to the private Redis IP without requiring VPC Access Connector infrastructure (saving time and cost).

---

## How to Manage and Deploy

### Prerequisites
Ensure you have the `gcloud` SDK installed and authenticated.

### Execution
You can run the deployment script directly using default values:
```bash
./deploy.sh
```

Or pass custom parameter values for project, region, network, subnet, Artifact Registry, and enable the HTTP Load Balancer:
```bash
./deploy.sh \
  --project my-gcp-project-id \
  --region us-central1 \
  --network custom-vpc \
  --subnet custom-subnet \
  --repo my-custom-artifact-repo \
  --load-balancer
```

### Parameter Options:
* `-p, --project ID`       GCP Project ID (defaults to `alpfr-splunk-integration`)
* `-r, --region REGION`    GCP Region (defaults to `us-central1`)
* `-z, --zone ZONE`        GCP Zone (defaults to `us-central1-a`)
* `-n, --network NETWORK`  VPC Network name (defaults to `default`)
* `-s, --subnet SUBNET`    VPC Subnet name (defaults to `default`)
* `-i, --instance NAME`    Memorystore Redis instance name (defaults to `redis-cache`)
* `-k, --repo NAME`        GCP Artifact Registry repository name (defaults to GCR container registry)
* `-l, --load-balancer`    Enable Global HTTP Load Balancer with Serverless NEG (defaults to `false`)

---

## Code Breakdown

### 1. Flask App (`app/app.py`)
Connects to Redis using host and port variables from env:
```python
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))
```
If successful, it increments the key `'visitor_count'` and returns:
```json
{
  "connected_to": "10.105.0.3:6379",
  "message": "Connected to Redis successfully!",
  "status": "success",
  "visitor_count": 2
}
```

### 2. Dockerfile (`app/Dockerfile`)
Uses a multi-stage build starting from `python:3.11-alpine`. It builds dependencies in the first stage and copies them to the runtime container to ensure a minimal footprint.
To satisfy the security requirements, it runs without the `runAsNonRoot: true` restriction (defaulting to container root execution).

### 3. Cloud Run Service Definition (`cloudrun/service.yaml`)
Utilizes Knative specs to define the network attachments:
```yaml
spec:
  template:
    metadata:
      annotations:
        run.googleapis.com/network-interfaces: '[{"network":"default","subnetwork":"default"}]'
        run.googleapis.com/vpc-access-egress: "private-ranges-only"
```
The script dynamically replaces the image tag and private Redis IP address when deploying.

---

## CI/CD Deployment using GCP Cloud Build

We have included a `cloudbuild.yaml` file under the `gcp-cloudbuild/` directory to automate compilation and deployment through Google Cloud Build.

### 1. Manual Invocation
To trigger the build and deployment pipeline manually from your local command line:
```bash
gcloud builds submit --config=gcp-cloudbuild/cloudbuild.yaml .
```

### 2. Automated Git Triggers (CI/CD)
To set up continuous deployment upon pushing to your GitHub repository:
1. Go to the **Cloud Build Triggers** console in GCP.
2. Click **Create Trigger**.
3. Link your GitHub repository `https://github.com/alpfr/cloudrun-redis-gcp.git`.
4. Set the event type to **Push to a branch** (select `main`).
5. Select **Cloud Build configuration file (yaml)** as the configuration type.
6. Set the path to `gcp-cloudbuild/cloudbuild.yaml`.
7. Click **Create**.
Now, any git push to `main` will automatically build your image, verify/provision Memorystore, and update your Cloud Run service!

> [!IMPORTANT]
> Ensure the **Cloud Build Service Account** in your GCP project has the following roles:
> * `roles/run.admin` (Cloud Run Admin)
> * `roles/redis.admin` (Cloud Memorystore Admin)
> * `roles/compute.networkAdmin` (VPC Network/PSA Admin)
> * `roles/iam.serviceAccountUser` (ActAs role for deployment)

---

## Alternative Deployment: GCP GKE (Google Kubernetes Engine)

If you need to deploy the application inside a Kubernetes cluster:

### GKE Execution
Navigate to the `gke/` folder and execute the deployment script. The GKE cluster name is required:
```bash
cd gke
./deploy.sh --cluster my-gke-cluster --zone us-central1-a
```

### Parameter Options:
* `-c, --cluster NAME`     GKE Cluster Name (Required)
* `-p, --project ID`       GCP Project ID (defaults to `alpfr-splunk-integration`)
* `-r, --region REGION`    GCP Region (defaults to `us-central1`)
* `-z, --zone ZONE`        GCP Zone (defaults to `us-central1-a`)
* `-k, --repo NAME`        GCP Artifact Registry repository name (defaults to GCR container registry)

### What the GKE deploy script does:
1. **Enables APIs**: Compute, Kubernetes Engine, Cloud Build, and Filestore APIs.
2. **Cluster Authentication**: Retrieves `kubectl` credentials for the GKE cluster.
3. **Builds Container**: Submits the Flask application to Cloud Build, compiling it into a Docker image.
4. **Applies Manifests**: Deploys the GKE StorageClass (Filestore), PVC, ConfigMap, headless/standard Services, Redis StatefulSet, and the Flask application.
5. **Applies Istio Routing**: Configures the Istio Gateway and VirtualService (if Istio is installed in the GKE cluster).

---

## Alternative Deployment: AWS EKS (Elastic Kubernetes Service)

If you need to deploy the application inside an AWS EKS cluster:

### EKS Execution
Navigate to the `eks/` folder and execute the deployment script. The EKS cluster name and AWS Account ID are required:
```bash
cd eks
./deploy.sh --cluster my-eks-cluster --account 123456789012 --region us-east-1
```

### Parameter Options:
* `-c, --cluster NAME`     EKS Cluster Name (Required)
* `-a, --account ID`       AWS Account ID (Required for ECR registry URL)
* `-r, --region REGION`    AWS Region (defaults to `us-east-1`)

### What the EKS deploy script does:
1. **Cluster Authentication**: Updates local `kubeconfig` for EKS using `aws eks update-kubeconfig`.
2. **Registry Login**: Authenticates local Docker daemon to Amazon ECR.
3. **Registry Check/Create**: Verifies or provisions the Amazon ECR repository `flask-redis-app`.
4. **Builds Container**: Compiles the Flask application container and pushes it to ECR.
5. **Applies Manifests**: Deploys EKS StorageClass (AWS EFS), PVC, ConfigMap, headless/standard Services (listening on port **6379**), Redis StatefulSet, and the Flask application.
6. **Applies Istio Routing**: Configures the Istio Gateway and VirtualService (routing incoming traffic on port **443** to the Flask application).
