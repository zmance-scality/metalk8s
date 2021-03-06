{%- set volumes = pillar.metalk8s.volumes %}
{%- set volume  = pillar.get('volume', '') %}


{%- if volume in volumes.keys() %}
Clean up backing storage for {{ volume }}:
  metalk8s_volumes.removed:
    - name: {{ volume }}
{%- else %}

{%- do salt.log.warning('Volume ' ~ volume ~ ' not found in pillar') -%}

Volume {{ volume }} not found in pillar:
  test.configurable_test_state:
    - name: {{ volume }}
    - changes: False
    - result: True
    - comment: Volume {{ volume }} not found in pillar
{%- endif %}
