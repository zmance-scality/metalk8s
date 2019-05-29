{%- set node_name = pillar.orchestrate.node_name %}
{%- set version = pillar.metalk8s.nodes[node_name].version %}

{%- set kubeconfig = "/etc/kubernetes/admin.conf" %}
{%- set context = "kubernetes-admin@kubernetes" %}

{%- set event_prefix = "metalk8s/orchestrate/deploy_node/$jid" %}

Annotate Node with orchestration JID:
  metalk8s.node_orchestration_marked:
    - name: {{ node_name }}
    - kubeconfig: {{ kubeconfig }}
    - context: {{ context }}
    - order: 1

Send start event:
  metalk8s.send_orchestration_event:
    - name: {{ event_prefix }}/start
    - data:
        name: {{ node_name }}
    - require:
      - metalk8s: Annotate Node with orchestration JID

{%- if node_name not in salt.saltutil.runner('manage.up') %}
Send event for "deploy-minion" step:
  metalk8s.send_orchestration_event:
    - name: {{ event_prefix }}/step
    - data:
        key: deploy-minion
        node: {{ node_name }}
        message: Deploying Salt Minion
    - require:
      - metalk8s: Send start event

Deploy salt-minion on a new node:
  salt.state:
    - ssh: true
    - roster: kubernetes
    - tgt: {{ node_name }}
    - saltenv: metalk8s-{{ version }}
    - sls:
      - metalk8s.roles.minion
    - require:
      - metalk8s: Send event for "deploy-minion" step

Accept key:
  module.run:
    - saltutil.wheel:
      - key.accept
      - {{ node_name }}
    - require:
      - salt: Deploy salt-minion on a new node

Wait minion available:
  salt.runner:
    - name: metalk8s_saltutil.wait_minions
    - tgt: {{ node_name }}
    - require:
      - module: Accept key
    - require_in:
      - salt: Set grains
      - salt: Refresh the mine
{%- endif %}

Set grains:
  salt.state:
    - tgt: {{ node_name }}
    - saltenv: metalk8s-{{ version }}
    - sls:
      - metalk8s.node.grains
    - require:
      - metalk8s: Send start event

Refresh the mine:
  salt.function:
    - name: mine.update
    - tgt: '*'
    - require:
      - metalk8s: Send start event

Send event for "drain-node" step:
  metalk8s.send_orchestration_event:
    - name: {{ event_prefix }}/step
    - data:
        key: drain-node
        node: {{ node_name }}
        message: Draining Node
    - require:
      - salt: Set grains
      - salt: Refresh the mine

Cordon the node:
  metalk8s_cordon.node_cordoned:
    - name: {{ node_name }}
    - kubeconfig: {{ kubeconfig }}
    - context: {{ context }}
    - require:
      - metalk8s: Send event for "drain-node" step

Drain the node:
  metalk8s_drain.node_drained:
    - name: {{ node_name }}
    - ignore_daemonset: True
    - delete_local_data: True
    - force: True
    - kubeconfig: {{ kubeconfig }}
    - context: {{ context }}
    - require:
      - metalk8s_cordon: Cordon the node

Send event for "highstate" step:
  metalk8s.send_orchestration_event:
    - name: {{ event_prefix }}/step
    - data:
        key: highstate
        node: {{ node_name }}
        message: Bringing up to highstate
    - require:
      - salt: Set grains
      - salt: Refresh the mine
      - metalk8s_drain: Drain the node

Run the highstate:
  salt.state:
    - tgt: {{ node_name }}
    - highstate: True
    - require:
      - metalk8s: Send event for "highstate" step

Send event for "finalize" step:
  metalk8s.send_orchestration_event:
    - name: {{ event_prefix }}/step
    - data:
        key: finalize
        node: {{ node_name }}
        message: Finalizing
    - require:
      - salt: Run the highstate

Uncordon the node:
  metalk8s_cordon.node_uncordoned:
    - name: {{ node_name }}
    - kubeconfig: {{ kubeconfig }}
    - context: {{ context }}
    - require:
      - metalk8s: Send event for "finalize" step

{%- set master_minions = salt['metalk8s.minions_by_role']('master') %}

# Work-around for https://github.com/scality/metalk8s/pull/1028
Kill kube-controller-manager on all master nodes:
  salt.function:
    - name: ps.pkill
    - tgt: "{{ master_minions | join(',') }}"
    - tgt_type: list
    - fail_minions: "{{ master_minions | join(',') }}"
    - kwarg:
        pattern: kube-controller-manager
    - require:
      - salt: Run the highstate

{%- if 'etcd' in pillar.get('metalk8s', {}).get('nodes', {}).get(node_name, {}).get('roles', []) %}

Register the node into etcd cluster:
  salt.runner:
    - name: state.orchestrate
    - pillar: {{ pillar | json  }}
    - mods:
      - metalk8s.orchestrate.register_etcd
    - require:
      - salt: Run the highstate

{%- endif %}

Remove orchestration annotation:
  metalk8s.node_orchestration_unmarked:
    - name: {{ node_name }}
    - kubeconfig: {{ kubeconfig }}
    - context: {{ context }}
    - order: last
