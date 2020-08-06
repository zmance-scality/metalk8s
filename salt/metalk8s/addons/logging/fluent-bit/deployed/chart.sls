#!jinja | metalk8s_kubernetes

{%- from "metalk8s/repo/macro.sls" import build_image_name with context %}



{% raw %}

apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit
  namespace: metalk8s-logging
spec:
  allowPrivilegeEscalation: false
  fsGroup:
    rule: RunAsAny
  hostIPC: false
  hostNetwork: false
  hostPID: false
  privileged: false
  readOnlyRootFilesystem: true
  requiredDropCapabilities:
  - ALL
  runAsUser:
    rule: RunAsAny
  seLinux:
    rule: RunAsAny
  supplementalGroups:
    rule: RunAsAny
  volumes:
  - secret
  - configMap
  - hostPath
  - projected
  - downwardAPI
---
apiVersion: v1
data:
  fluent-bit.conf: |-
    [SERVICE]
        HTTP_Server    On
        HTTP_Listen    0.0.0.0
        HTTP_PORT      2020
        Flush          1
        Daemon         Off
        Log_Level      warn
        Parsers_File   parsers.conf
    [INPUT]
        Name           tail
        Tag            kube.*
        Path           /var/log/containers/*.log
        Parser         docker
        DB             /run/fluent-bit/flb_kube.db
        Mem_Buf_Limit  5MB
    [FILTER]
        Name           kubernetes
        Match          kube.*
        Kube_URL       https://kubernetes.default.svc:443
        Merge_Log On
        K8S-Logging.Parser Off
    [Output]
        Name loki
        Match *
        Url http://loki:3100/api/prom/push
        TenantID ""
        BatchWait 1
        BatchSize 10240
        Labels {job="fluent-bit"}
        RemoveKeys kubernetes,stream
        AutoKubernetesLabels false
        LabelMapPath /fluent-bit/etc/labelmap.json
        LineFormat json
        LogLevel warn
  labelmap.json: |-
    {
      "kubernetes": {
        "container_name": "container",
        "host": "node",
        "labels": {
          "app": "app",
          "release": "release"
        },
        "namespace_name": "namespace",
        "pod_name": "instance"
      },
      "stream": "stream"
    }
  parsers.conf: |-
    [PARSER]
        Name        docker
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
kind: ConfigMap
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit
  namespace: metalk8s-logging
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit
  namespace: metalk8s-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit-clusterrole
  namespace: metalk8s-logging
rules:
- apiGroups:
  - ''
  resources:
  - namespaces
  - pods
  verbs:
  - get
  - watch
  - list
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit-clusterrolebinding
  namespace: metalk8s-logging
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit-clusterrole
subjects:
- kind: ServiceAccount
  name: fluent-bit
  namespace: metalk8s-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit
  namespace: metalk8s-logging
rules:
- apiGroups:
  - extensions
  resourceNames:
  - fluent-bit
  resources:
  - podsecuritypolicies
  verbs:
  - use
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit
  namespace: metalk8s-logging
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: fluent-bit
subjects:
- kind: ServiceAccount
  name: fluent-bit
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit-headless
  namespace: metalk8s-logging
spec:
  clusterIP: None
  ports:
  - name: http-metrics
    port: 2020
    protocol: TCP
    targetPort: http-metrics
  selector:
    app: fluent-bit
    release: fluent-bit
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  annotations: {}
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: fluent-bit
  name: fluent-bit
  namespace: metalk8s-logging
spec:
  selector:
    matchLabels:
      app: fluent-bit
      release: fluent-bit
  template:
    metadata:
      annotations:
        checksum/config: 7f68240acb36d458b00bb6871eaee1d88726c42f12d28c597564b856f9b9ac4f
        prometheus.io/path: /api/v1/metrics/prometheus
        prometheus.io/port: '2020'
        prometheus.io/scrape: 'true'
      labels:
        app: fluent-bit
        release: fluent-bit
    spec:
      affinity: {}
      containers:
      - image: {% endraw -%}{{ build_image_name("fluent-bit-plugin-loki", False) }}{%- raw %}:1.5.0-amd64
        imagePullPolicy: IfNotPresent
        name: fluent-bit-loki
        ports:
        - containerPort: 2020
          name: http-metrics
        resources:
          limits:
            memory: 100Mi
          requests:
            cpu: 100m
            memory: 100Mi
        volumeMounts:
        - mountPath: /fluent-bit/etc
          name: config
        - mountPath: /run/fluent-bit
          name: run
        - mountPath: /var/log
          name: varlog
          readOnly: true
      nodeSelector: {}
      serviceAccountName: fluent-bit
      terminationGracePeriodSeconds: 10
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/bootstrap
        operator: Exists
      - effect: NoSchedule
        key: node-role.kubernetes.io/etcd
        operator: Exists
      - effect: NoSchedule
        key: node-role.kubernetes.io/infra
        operator: Exists
      - effect: NoSchedule
        key: node-role.kubernetes.io/master
        operator: Exists
      volumes:
      - configMap:
          name: fluent-bit
        name: config
      - hostPath:
          path: /run/fluent-bit
        name: run
      - hostPath:
          path: /var/log
        name: varlog
  updateStrategy:
    type: RollingUpdate
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  labels:
    app: fluent-bit
    app.kubernetes.io/managed-by: salt
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/part-of: metalk8s
    chart: fluent-bit-0.1.5
    heritage: metalk8s
    release: prometheus-operator
  name: fluent-bit
  namespace: metalk8s-logging
spec:
  endpoints:
  - path: /api/v1/metrics/prometheus
    port: http-metrics
  namespaceSelector:
    matchNames:
    - metalk8s-logging
  selector:
    matchLabels:
      app: fluent-bit
      release: fluent-bit

{% endraw %}
