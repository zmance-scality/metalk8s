#!/usr/bin/env python3

'''
This script takes a Helm release name, a namespace name, a Helm chart
`values` file and a chart, and turns it into a YAML document that can be
deployed in a Kubernetes cluster as part of MetalK8s.

It performs the following tasks:

- Run `helm template` to render the chart, passing in the values provided on the
  command-line
- Fix up the resulting objects to include the desired namespace (which is not
  always part of chart templates) in the metadata section
- Fix up the resulting objects labels and annotations replace their `Tiller`
  heritage by `metalk8s`, set the `app.kubernetes.io/part-of` and
  `app.kubernetes.io/managed-by` to `salt`, and copy any `app` and
  `component` fields to the canonical `app.kubernetes.io/name` and
  `app.kubernetes.io/component` fields
- Replace YAML-safe special strings (used in Helm values definitions) with the
  appropriate Jinja syntax. Supports:
    - "__var__(<varname>)", to replace with "{{ <varname> }}" (useful when
      retrieving variables from service configuration ConfigMaps)
    - "__image__(<imgname>)", to replace with
      "{{ build_image_name("<imgname>", False) }}"
    - "__full_image__(<imgname>)", to replace with
      "{{ build_image_name("<imgname>") }}"
'''

import argparse
import copy
import io
import re
import sys
import subprocess

import yaml
from yaml.dumper import SafeDumper
from yaml.representer import SafeRepresenter


START_BLOCK = """
#!jinja | metalk8s_kubernetes

{{%- from "metalk8s/repo/macro.sls" import build_image_name with context %}}
{csc_defaults}
{configlines}

{{% raw %}}
"""

END_BLOCK = """
{% endraw %}
"""


def fixup_metadata(namespace, doc):
    if 'metadata' in doc and 'namespace' not in doc['metadata']:
        doc['metadata']['namespace'] = namespace

    if doc.get('kind', None) == 'ConfigMapList':
        doc['items'] = [fixup_metadata(namespace, configmap)
                        for configmap in doc['items']]

    return doc


def maybe_copy(doc, src, dest):
    try:
        doc[dest] = doc[src]
    except KeyError:
        pass


def fixup_dict(doc):
    if doc.get('heritage') == 'Tiller' or \
            doc.get('app.kubernetes.io/managed-by') == 'Tiller':
        maybe_copy(doc, 'app', 'app.kubernetes.io/name')
        maybe_copy(doc, 'component', 'app.kubernetes.io/component')

        doc['heritage'] = 'metalk8s'
        doc['app.kubernetes.io/part-of'] = 'metalk8s'
        doc['app.kubernetes.io/managed-by'] = 'salt'

    return dict((key, fixup_doc(value)) for (key, value) in doc.items())

# Represent multiline strings as literal blocks {{{
class multiline_str(str): pass

def representer_multiline_str(dumper, data):
    scalar = SafeRepresenter.represent_str(dumper, data)
    scalar.style = '|'
    return scalar

SafeDumper.add_representer(multiline_str, representer_multiline_str)

def fixup_string(value):
    if '\n' in value:
        # Remove empty lines
        value = '\n'.join(
            line for line in value.splitlines()
            if not re.match('^\s*$', line)
        )
        return multiline_str(value)
    return value
# }}}


def fixup_doc(doc):
    if isinstance(doc, dict):
        return fixup_dict(doc)
    elif isinstance(doc, list):
        return [fixup_doc(d) for d in doc]
    elif isinstance(doc, str):
        return fixup_string(doc)
    else:
        return doc


def remove_doc(doc, remove_manifests):
    for to_remove in remove_manifests:
        if doc.get('kind') == to_remove[0] and \
                doc.get('metadata').get('name') == to_remove[1]:
            return True

    return False


def keep_doc(doc):
    if not doc:
        return False

    if doc.get('metadata', {}) \
            .get('annotations', {}) \
            .get('helm.sh/hook') == 'test-success':
        return False

    return True


def replace_magic_strings(rendered_yaml):
    # Handle __var__
    result = re.sub(
        r'__var__\((?P<varname>[\w\-_]+(?:\.[\w\-_()]+)*)\)',
        r'{% endraw -%}{{ \g<varname> }}{%- raw %}',
        rendered_yaml,
    )

    # Handle __var_tojson__
    result = re.sub(
        r'__var_tojson__\((?P<varname>[\w\-_]+(?:\.[\w\-_()|]+)*)\)',
        r'  {% endraw -%}{{ \g<varname> | tojson }}{%- raw %}',
        result,
    )

    # Handle __escape__
    result = re.sub(
        r'__escape__\((?P<varname>.*)\)',
        r'"{% endraw -%}\g<varname>{%- raw %}"',
        result,
    )

    # Handle __image__
    result = re.sub(
        r'__image__\((?P<imgname>[\w\-]+)\)',
        r'{% endraw -%}{{ build_image_name("\g<imgname>", False) }}{%- raw %}',
        result,
    )

    # Handle __full_image__ (include version tag in the rendered name)
    result = re.sub(
        r'__full_image__\((?P<imgname>[\w\-]+)\)',
        r'{% endraw -%}{{ build_image_name("\g<imgname>") }}{%- raw %}',
        result,
    )

    return result


def remove_prometheus_rules(template, drop_rules):
    updated_template = None
    groups = []

    existing_groups = template.get('spec', {}).get('groups', [])
    for group in existing_groups:
        group_rules = group.get('rules', [])
        new_rules = group_rules[:]
        to_drop = drop_rules.get(group.get('name'), [])
        if to_drop:
            for rule in group_rules:
                if any(rule.get(key) in to_drop
                        for key in ['alert', 'record']):
                    new_rules.remove(rule)
        if new_rules:
            groups.append(dict(group, rules=new_rules))

    if groups:
        updated_template = copy.deepcopy(template)
        updated_template['spec']['groups'] = groups

    return updated_template


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('name', help="Denotes the name of the chart")
    parser.add_argument(
        '-n',
        '--namespace',
        default="default",
        help="Namespace to deploy this chart in"
    )
    parser.add_argument('values', help="Our custom chart values")

    '''
    To use this argument, follow the format below:
        --service-config service_name service_configmap_name
    where service_name is actually the jinja variable which will hold
    ConfigMap contents.
    Note that you can specify multiple service config arguments using:
        --service-config grafana metalk8s-grafana-config
        --service-config prometheus metalk8s-prometheus-config
    '''
    # Todo: Add kind & apiVersion to the service-config nargs
    parser.add_argument(
        '--service-config',
        action='append',
        nargs=2,
        required=False,
        dest="service_configs",
        help="Example: --service-config grafana metalk8s-grafana-config"
    )
    parser.add_argument(
        '--drop-prometheus-rules',
        help="YAML formatted file to drop some pre-defined Prometheus rules"
    )
    parser.add_argument(
        '--remove-manifest',
        action='append',
        nargs=2,
        dest="remove_manifests",
        metavar=('kind', 'name'),
        help="Remove a given manifest from the resulting chart",
    )
    parser.add_argument('path', help="Path to the chart directory")
    args = parser.parse_args()

    template = subprocess.check_output([
        'helm', 'template',
        '--name', args.name,
        '--namespace', args.namespace,
        '--values', args.values,
        args.path,
    ])

    drop_prometheus_rules = {}
    if args.drop_prometheus_rules:
        with open(args.drop_prometheus_rules, "r") as fd:
            drop_prometheus_rules = yaml.safe_load(fd)

    def fixup(doc):
        if drop_prometheus_rules and isinstance(doc, dict) \
               and doc.get('kind') == 'PrometheusRule':
            doc = remove_prometheus_rules(doc, drop_prometheus_rules)

        return fixup_metadata(
            namespace=args.namespace,
            doc=fixup_doc(
                doc=doc
            )
        ) if doc else None

    if args.service_configs:
        import_csc_yaml = '\n'.join(
            ("{{% import_yaml 'metalk8s/addons/{0}/config/{1}.yaml' as "
                "{1}_defaults with context %}}").format(
                args.name, service_config[0]
            ) for service_config in args.service_configs
        )

        config = '\n'.join(
            ("{{%- set {0} = salt.metalk8s_service_configuration"
                ".get_service_conf('{1}', '{2}', {0}_defaults) %}}").format(
                service_config[0], args.namespace, service_config[1]
            ) for service_config in args.service_configs
        )
    else:
        import_csc_yaml = ''
        config = ''

    sys.stdout.write(START_BLOCK.format(
        csc_defaults=import_csc_yaml, configlines=config).lstrip()
    )
    sys.stdout.write('\n')

    manifests = []
    for doc in yaml.safe_load_all(template):
        if keep_doc(doc):
            doc = fixup(doc)
        if doc and not remove_doc(doc, args.remove_manifests):
            manifests.append(doc)

    stream = io.StringIO()
    yaml.safe_dump_all(
        manifests,
        stream,
        default_flow_style=False,
    )
    stream.seek(0)

    sys.stdout.write(replace_magic_strings(stream.read()))

    sys.stdout.write(END_BLOCK)


if __name__ == '__main__':
    main()
