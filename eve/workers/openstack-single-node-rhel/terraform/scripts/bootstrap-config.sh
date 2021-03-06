#!/bin/bash

set -xue -o pipefail

OUTPUT_FILE="/etc/metalk8s/bootstrap.yaml"

mkdir -p "$(dirname $OUTPUT_FILE)"

mkdir -p /etc/salt
echo "bootstrap-rhel" > /etc/salt/minion_id

cat > "$OUTPUT_FILE" << EOF
apiVersion: metalk8s.scality.com/v1alpha3
kind: BootstrapConfiguration
networks:
  controlPlane:
    cidr: 10.100.0.0/16
  workloadPlane:
    cidr:
      - 10.100.0.0/16
ca:
  minion: $(cat /etc/salt/minion_id)
archives:
  - /var/tmp/metalk8s
debug: ${DEBUG:-false}
EOF

ls "$(dirname $OUTPUT_FILE)"
cat "$OUTPUT_FILE"
