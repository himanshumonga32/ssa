#!/bin/bash

# Function: Check prerequisites
check_required_tools() {
  echo "Checking prerequisites..."
  if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed. Please install it and try again." >&2
    exit 1
  fi

  if ! command -v helm &> /dev/null; then
    echo "Error: helm is not installed. Please install it and try again." >&2
    exit 1
  fi
  echo "Prerequisites are installed."
}

# Function: Connect to Kubernetes Cluster
connect_cluster() {
  echo "Connecting to the Kubernetes cluster..."
  if ! kubectl config view &> /dev/null; then
    echo "Error: Could not connect to the cluster. Ensure kubeconfig is configured correctly." >&2
    exit 1
  fi
  echo "Cluster connection successful."
}

# Function: Install Helm and KEDA
install_keda() {
  echo "Installing KEDA using Helm..."
  kubectl create namespace keda || echo "Namespace 'keda' already exists."

  helm repo add kedacore https://kedacore.github.io/charts || {
    echo "Error: Failed to add the KEDA Helm repository." >&2
    exit 1
  }

  helm repo update || {
    echo "Error: Failed to update Helm repositories." >&2
    exit 1
  }

  helm install keda kedacore/keda --namespace keda || {
    echo "Error: KEDA installation failed. Check Helm logs for more information." >&2
    exit 1
  }
  echo "KEDA installed successfully."
}

# Function: Create Deployment with KEDA Autoscaling
create_deployment() {
  local namespace=$1
  local deployment_name=$2
  local image=$3
  local tag=$4
  local port=$5
  local cpu_request=$6
  local memory_request=$7
  local cpu_limit=$8
  local memory_limit=$9
  local kafka_bootstrap_servers=${10}  # Kafka broker URL(s)
  local kafka_topic=${11}             # Kafka topic name
  local kafka_consumer_group=${12}    # Kafka consumer group name
  local lag_threshold=${13}           # Kafka lag threshold for scaling

  echo "Creating deployment '$deployment_name' in namespace '$namespace'..."
  kubectl create namespace "$namespace" || echo "Namespace '$namespace' already exists."

  # Create Deployment YAML
  deployment_file="${deployment_name}_deployment.yaml"
  cat <<EOF > "$deployment_file"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deployment_name
  namespace: $namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $deployment_name
  template:
    metadata:
      labels:
        app: $deployment_name
    spec:
      containers:
      - name: $deployment_name
        image: $image:$tag
        ports:
        - containerPort: $port
        resources:
          requests:
            memory: "$memory_request"
            cpu: "$cpu_request"
          limits:
            memory: "$memory_limit"
            cpu: "$cpu_limit"
EOF

  # Apply Deployment YAML
  echo "Applying deployment YAML..."
  kubectl apply -f "$deployment_file" || {
    echo "Error: Failed to create deployment '$deployment_name'." >&2
    exit 1
  }

  # Create ClusterIP Service YAML
  service_file="${deployment_name}_service.yaml"
  cat <<EOF > "$service_file"
apiVersion: v1
kind: Service
metadata:
  name: $deployment_name-service
  namespace: $namespace
spec:
  selector:
    app: $deployment_name
  ports:
  - protocol: TCP
    port: $port
    targetPort: $port
  type: ClusterIP
EOF

  # Apply Service YAML
  echo "Applying service YAML..."
  kubectl apply -f "$service_file" || {
    echo "Error: Failed to create service for deployment '$deployment_name'." >&2
    exit 1
  }

  # Create KEDA ScaledObject YAML
  scaledobject_file="${deployment_name}_scaledobject.yaml"
  cat <<EOF > "$scaledobject_file"
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: $deployment_name-scaledobject
  namespace: $namespace
spec:
  scaleTargetRef:
    name: $deployment_name
  pollingInterval: 30  # How often KEDA checks the metrics (in seconds)
  cooldownPeriod: 300  # Cooldown period after scaling down (in seconds)
  minReplicaCount: 1   # Minimum number of replicas
  maxReplicaCount: 10  # Maximum number of replicas
  triggers:
  - type: kafka
    metadata:
      bootstrapServers: "$kafka_bootstrap_servers" # Kafka broker URL(s)
      topic: "$kafka_topic"                       # Kafka topic name
      consumerGroup: "$kafka_consumer_group"      # Kafka consumer group name
EOF

  # Apply ScaledObject YAML
  echo "Applying KEDA ScaledObject YAML..."
  kubectl apply -f "$scaledobject_file" || {
    echo "Error: Failed to create KEDA ScaledObject for deployment '$deployment_name'." >&2
    exit 1
  }

  # Return Deployment Details
  echo "Deployment created successfully!"
  echo "Service Type: ClusterIP"
  echo "Kafka Autoscaling Configured:"
  echo "  - Bootstrap Servers: $kafka_bootstrap_servers"
  echo "  - Topic: $kafka_topic"
  echo "  - Consumer Group: $kafka_consumer_group"
  echo "Access the service within the cluster using the service name and namespace."
}

# Function: Check Deployment Health
check_health_status() {
  local namespace=$1
  local deployment_name=$2
  echo "Checking health status for deployment '$deployment_name' in namespace '$namespace'..."

  if ! kubectl get deployment "$deployment_name" -n "$namespace" &> /dev/null; then
    echo "Error: Deployment '$deployment_name' not found in namespace '$namespace'." >&2
    exit 1
  fi

  if ! kubectl top pods -n "$namespace" &> /dev/null; then
    echo "Warning: Metrics server is not installed, or pods are not running. Install Metrics Server for resource metrics." >&2
  fi

  echo "Health status check complete."
}

# Main
case $1 in
  "install")
    check_required_tools
    ;;
  "setup")
    install_keda
    ;;
  "deploy")
    create_deployment "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}"
    ;;
  "health")
    check_health_status "$2" "$3"
    ;;
  *)
    echo "Usage: $0 {installtools|setup|deploy|health}"
    echo "  installtools: Check prerequisites for the cluster."
    echo "  setup: Setup KEDA on the cluster."
    echo "  deploy <namespace> <deployment_name> <image> <tag> <port> <cpu_request> <memory_request> <cpu_limit> <memory_limit> <kafka_bootstrap_servers> <kafka_topic> <kafka_consumer_group>: Create a deployment."
    echo "  health <namespace> <deployment_name>: Check deployment health."
    exit 1
    ;;
esac

