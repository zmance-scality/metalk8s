#!/usr/bin/env bash

LOGGER_LINE_LENGTH=${LOGGER_LINE_LENGTH:-1024}
LOGGER_RATE=${LOGGER_RATE:-60000}  # Line per minutes
LOGGER_TIME=${LOGGER_TIME:-600}  # Time to run in seconds
LOGGER_MODE=${LOGGER_MODE:-single}
LOGGER_NAMESPACE=${LOGGER_NAMESPACE:-logger}
LOGGER_MAX_RATE_PER_POD=60000
LOGGER_STREAMS=${LOGGER_STREAMS:-0}
KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
KEEP=${KEEP:-0}
PURGE_PROMETHEUS_DB=${PURGE_PROMETHEUS_DB:-0}
WORKING_DIR=$(mktemp -d)
LOGGER_MANIFEST="$WORKING_DIR/logger-deployment.yml"


cleanup() {
    if (( KEEP )); then
        echo "KEEP option is set, working directory at '$WORKING_DIR'" \
             "and namespace '$LOGGER_NAMESPACE' will be preserved"
    else
        rm -rf "${WORKING_DIR}" || true
        kubectl delete namespace "$LOGGER_NAMESPACE"
    fi
}

trap cleanup EXIT

prometheus_get_endpoint() {
    kubectl get endpoints prometheus-operator-prometheus \
      --kubeconfig="$KUBECONFIG" \
      --namespace=metalk8s-monitoring \
      --output=jsonpath='{ .subsets[0].addresses[0].ip }:{ .subsets[0].ports[0].port }'
}

prometheus_enable_admin_api() {
    local api_is_enabled

    api_is_enabled=$(
      kubectl get prometheus prometheus-operator-prometheus \
      --kubeconfig="$KUBECONFIG" \
      --namespace=metalk8s-monitoring -o jsonpath='{ .spec.enableAdminAPI }'
    )

    if [[ $api_is_enabled != true ]]; then
        kubectl patch prometheus prometheus-operator-prometheus \
          --kubeconfig="$KUBECONFIG" \
          --namespace=metalk8s-monitoring \
          --type=merge --patch '{"spec": {"enableAdminAPI": true}}'
    fi
}

prometheus_purge_database() {
    local prometheus=$(prometheus_get_endpoint)

    curl -X POST -g \
      'http://'$prometheus'/api/v1/admin/tsdb/delete_series?match[]={__name__=~".+"}'
    curl -X POST -g \
      'http://'$prometheus'/api/v1/admin/tsdb/clean_tombstones'
}

prometheus_snapshot_database() {
    local snapshot_name
    local prometheus=$(prometheus_get_endpoint)

    mkdir -p snapshots

    snapshot_name=$(
      curl -s -XPOST "http://$prometheus/api/v1/admin/tsdb/snapshot" | \
      python -c 'import json, sys; print(json.load(sys.stdin)["data"]["name"])'
    )

    kubectl cp --container=prometheus \
      --kubeconfig="$KUBECONFIG" \
      --namespace=metalk8s-monitoring \
      "prometheus-prometheus-operator-prometheus-0:/prometheus/snapshots/$snapshot_name" \
      "snapshots/prometheus-snapshot-$snapshot_name"

    echo "Prometheus database snapshot is available at" \
         "snapshots/prometheus-snapshot-$snapshot_name"

}

prometheus_extract_metrics() {
    # TODO: extract metrics for CPU & RAM and compute the average resources
    # consumption for each pods in loki namespace
    :
}

logger_create_namespace() {
    if ! kubectl --kubeconfig="$KUBECONFIG" get namespace "$LOGGER_NAMESPACE" &> /dev/null; then
        kubectl --kubeconfig="$KUBECONFIG" create namespace "$LOGGER_NAMESPACE"
    fi
}

logger_create_configmap() {
    cat > "$WORKING_DIR/ocp_logtest_wrapper.sh" <<EOF
#!/usr/bin/env bash

yum -y install python-pip
pip install json-logging

python "\${0%/*}/ocp_logtest.py" "\$@"

sleep infinity
EOF

    wget --quiet --output-document="$WORKING_DIR/ocp_logtest.py" \
      https://raw.githubusercontent.com/openshift/svt/master/openshift_scalability/content/logtest/root/ocp_logtest.py
    # small bugfix, otherwise we can't use the --file option
    sed -i 's/options\.length/options.line_length/' "$WORKING_DIR/ocp_logtest.py"

    kubectl create configmap ocp-logtest \
      --kubeconfig="$KUBECONFIG" \
      --namespace "$LOGGER_NAMESPACE" \
      --from-file="$WORKING_DIR/ocp_logtest.py" \
      --from-file="$WORKING_DIR/ocp_logtest_wrapper.sh"
}

logger_create_input_file() {
    local -ri streams=$1
    local -r input_file=$WORKING_DIR/input.log

    rm -f "$input_file"

    for index in $(seq 1 "$streams"); do
        prefix="index=$index "
        chars_needed=$(( LOGGER_LINE_LENGTH - ${#prefix} ))
        if (( chars_needed > 0 )); then
            line=$(tr -cd '[:alnum:]' < /dev/urandom | head -c "$chars_needed")
        else
            line=''
        fi
        echo "$prefix$line" >> "$input_file"
    done

    kubectl delete configmap input-file \
      --kubeconfig="$KUBECONFIG" \
      --namespace "$LOGGER_NAMESPACE" &> /dev/null
    kubectl create configmap input-file \
      --kubeconfig="$KUBECONFIG" \
      --namespace "$LOGGER_NAMESPACE" \
      --from-file="$input_file"
}

logger_create_deployment() {
    local -i pod_replicas pod_logger_rate
    local pod_tolerations=''
    local -a script_args=(
        "--line-length=$LOGGER_LINE_LENGTH"
        "--time=$LOGGER_TIME"
    )

    if (( LOGGER_RATE > LOGGER_MAX_RATE_PER_POD )); then
        pod_replicas=$(( LOGGER_RATE / LOGGER_MAX_RATE_PER_POD ))
        (( LOGGER_RATE % LOGGER_MAX_RATE_PER_POD && ++pod_replicas )) ||:
        pod_logger_rate=$(( LOGGER_RATE / pod_replicas ))
    else
        pod_replicas=1
        pod_logger_rate=$LOGGER_RATE
    fi

    if [[ $LOGGER_MODE = multiple ]]; then
        local -i node_number
        node_number=$(
          kubectl get nodes --kubeconfig="$KUBECONFIG" --no-headers | wc -l
        )
        pod_replicas=$((pod_replicas * node_number))
        pod_logger_rate=$((pod_logger_rate / node_number))
        read -r -d '' pod_tolerations << EOF
      tolerations:
        - key: "node-role.kubernetes.io/infra"
          operator: "Exists"
          effect: "NoSchedule"
        - key: "node-role.kubernetes.io/bootstrap"
          operator: "Exists"
          effect: "NoSchedule"
EOF
    fi

    script_args+=("--rate=$pod_logger_rate")

    if (( LOGGER_STREAMS > pod_replicas )); then
        script_args+=(
            "--text-type=input"
            "--file=/input/input.log"
        )
        read -r -d '' cm_input_file << EOF
      - configMap:
          defaultMode: 0444
          name: input-file
        name: input
EOF
        read -r -d '' volume_input_file << EOF
        - mountPath: /input/
          name: input
EOF
        # That's not really accurate, as in most cases we end up with more
        # streams than requested, but it's to keep this thing simple.
        logger_create_input_file "$((
          LOGGER_STREAMS / pod_replicas + (LOGGER_STREAMS % pod_replicas > 0) ))"
    fi

    cat > "$LOGGER_MANIFEST" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logger
  namespace: $LOGGER_NAMESPACE
  labels:
    app: logger
spec:
  replicas: $pod_replicas
  selector:
    matchLabels:
      app: logger
  template:
    metadata:
      labels:
        app: logger
    spec:
      terminationGracePeriodSeconds: 0
      containers:
      - name: logger
        image: metalk8s-registry-from-config.invalid/metalk8s-2.5.1-dev/metalk8s-utils:2.5.1-dev
        imagePullPolicy: IfNotPresent
        command:
          - /scripts/ocp_logtest_wrapper.sh
        args: $(echo; for script_arg in "${script_args[@]}"; do echo "          - $script_arg"; done)
        volumeMounts:
        - mountPath: /scripts/
          name: scripts
        $volume_input_file
      volumes:
      - configMap:
          defaultMode: 0544
          name: ocp-logtest
        name: scripts
      $cm_input_file
      $pod_tolerations
EOF

    kubectl apply --kubeconfig="$KUBECONFIG" --filename "$LOGGER_MANIFEST"
}

prometheus_enable_admin_api
(( PURGE_PROMETHEUS_DB )) && prometheus_purge_database

logger_create_namespace
logger_create_configmap
logger_create_deployment

sleep "$(( LOGGER_TIME + 60 ))"  # let 1 extra minute to be sure everything is finished

prometheus_extract_metrics
prometheus_snapshot_database
