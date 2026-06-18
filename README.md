# Flask Application & Google Cloud Memorystore Deployment

This repository contains a Flask web application that connects to a managed GCP Memorystore Redis database. The application is deployed to Google Cloud Run, utilizing **Direct VPC Egress** to communicate with the Redis instance over a private IP.

---

## File Structure

```
├── app/
│   ├── app.py             # Flask application code
│   ├── Dockerfile         # Multi-stage Dockerfile
│   └── requirements.txt   # Pip dependencies
├── cloudrun/
│   └── service.yaml       # Cloud Run Knative service configuration
└── deploy.sh              # Bash script to automate provisioning & deployment
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

We have included a `cloudbuild.yaml` file to automate compilation and deployment through Google Cloud Build.

### 1. Manual Invocation
To trigger the build and deployment pipeline manually from your local command line:
```bash
gcloud builds submit --config=cloudbuild.yaml .
```

### 2. Automated Git Triggers (CI/CD)
To set up continuous deployment upon pushing to your GitHub repository:
1. Go to the **Cloud Build Triggers** console in GCP.
2. Click **Create Trigger**.
3. Link your GitHub repository `https://github.com/alpfr/cloudrun-redis-gcp.git`.
4. Set the event type to **Push to a branch** (select `main`).
5. Select **Cloud Build configuration file (yaml)** as the configuration type.
6. Set the path to `cloudbuild.yaml`.
7. Click **Create**.
Now, any git push to `main` will automatically build your image, verify/provision Memorystore, and update your Cloud Run service!

> [!IMPORTANT]
> Ensure the **Cloud Build Service Account** in your GCP project has the following roles:
> * `roles/run.admin` (Cloud Run Admin)
> * `roles/redis.admin` (Cloud Memorystore Admin)
> * `roles/compute.networkAdmin` (VPC Network/PSA Admin)
> * `roles/iam.serviceAccountUser` (ActAs role for deployment)

