#!/usr/bin/env python3

import os
import subprocess
import json
import re
import csv
import pandas as pd
from io import StringIO
from pathlib import Path
from collections import defaultdict
from enum import Enum, unique
import ruamel.yaml
#import xml.etree.ElementTree as ET
#from xml.dom.minidom import parseString
from lxml import etree
import pdb

yaml = ruamel.yaml.YAML()
yaml.default_flow_style = False
component_map = {}
list_map = defaultdict(dict)
leaf_map = {}
ll_map = defaultdict(list)

@unique
class PROD_TYPE(Enum):
    NOT  = 0
    HSS  = 1
    UDM  = 2
    HELM = 3
prod_type = PROD_TYPE.NOT
prod_map = {PROD_TYPE.HSS: "NREG", PROD_TYPE.UDM: "REGISTERS"}

COLORS = {
    'DEBUG'    : '\033[36m',  # 青色
    'INFO'     : '\033[32m',  # 绿色
    'WARNING'  : '\033[33m',  # 黄色
    'ERROR'    : '\033[31m',  # 红色
    'CRITICAL' : '\033[41m',  # 红色背景
    'RESET'    : '\033[0m',   # 重置颜色
}

def check_label(directory, force, label):
    if force or not isinstance(label, list):
        return force
    old_label = []
    output_file = os.path.join(directory, 'output')
    os.makedirs(output_file, exist_ok=True)
    with open(f"{directory}/output/.label", 'a+') as f:
        f.seek(0)
        line = f.readline()
        if line:
            old_label = line.split()
    if label and set(label) != set(old_label):
        force = True
        with open(f"{directory}/output/.label", 'w') as f:
            f.write(' '.join(sorted(label)))
    if not label:
        label[:] = ["X"] if not old_label else old_label
    else:
        label[:] = sorted(set(label))
    return force


def parse_yang_lcm(directory, force=False, label=[]):
    if not os.path.exists(directory):
        return None,None,None

    global prod_type
    prod_type = PROD_TYPE.HELM
    yang_files = [f for f in os.listdir(directory) if f.endswith('.yang')]
    force = check_label(directory, force, label)
    all_leaf_nodes_list = []
    all_leaf_nodes_leaf = []
    all_leaf_nodes_other = []

    for file in yang_files:
        file_path = os.path.join(directory, file)
        output_file = os.path.join(directory, 'output', f"{file[:-5]}.json")

        if not force and os.path.exists(output_file):
            with open(output_file, 'r') as f:
                yang_data = json.load(f)
        else:
            try:
                os.makedirs(os.path.dirname(output_file), exist_ok=True)
                label_format = ' '.join('--label ' + i for i in sorted(label))
                command = f"pyang --plugindir=./plugins -f jsonWithValue {label_format} -p {directory} {file_path} > {output_file}"
                subprocess.run(command, shell=True, check=True)
                with open(output_file, 'r') as f:
                    yang_data = json.load(f)
            except subprocess.CalledProcessError as e:
                print(f"Error processing file {file}: {e}")
                continue
            except json.JSONDecodeError as e:
                print(f"Error parsing JSON for file {file}: {e}")
                continue

        list_nodes, leaf_nodes, leaf_list_nodes = extract_leaf_nodes(yang_data['tree'], file)
        all_leaf_nodes_list.extend(list_nodes)
        all_leaf_nodes_leaf.extend(leaf_nodes)
        all_leaf_nodes_other.extend(leaf_list_nodes)

    return all_leaf_nodes_list, all_leaf_nodes_leaf, all_leaf_nodes_other

def parse_yang_cm(directory, force=False, label=[]):
    if not os.path.exists(directory):
        return None,None,None

    global prod_type
    yang_files = [f for f in os.listdir(directory) if f.endswith('.yang')]
    capitalized_files = [f for f in yang_files if f.split('.')[0].isupper() and f not in ['REGISTERS.yang', 'NREG.yang']]

    if 'REGISTERS.yang' in yang_files:
        base_yang = 'REGISTERS.yang'
        prod_type = PROD_TYPE.UDM
    elif 'NREG.yang' in yang_files:
        base_yang = 'NREG.yang'
        capitalized_files.append(('cnsbaroot.yang','cnsbaconfiguration.yang'))
        #capitalized_files.clear()
        capitalized_files.append('hlrcallp.yang')
        prod_type = PROD_TYPE.HSS
    else:
        raise FileNotFoundError("Neither REGISTERS.yang nor NREG.yang found in the directory.")

    #pdb.set_trace()
    force = check_label(directory, force, label)
    base_yang_path = os.path.join(directory, base_yang)
    all_leaf_nodes_list = []
    all_leaf_nodes_leaf = []
    all_leaf_nodes_other = []

    for file in capitalized_files:
        if isinstance(file, str):
            file_path = os.path.join(directory, file)
            output_file = os.path.join(directory, 'output', f"{file[:-5]}.json")
        else:
            file_path = ' '.join(os.path.join(directory, f) for f in file)
            output_file = os.path.join(directory, 'output', f"{file[0][:-5]}.json")

        if not force and os.path.exists(output_file):
            with open(output_file, 'r') as f:
                yang_data = json.load(f)
        else:
            try:
                os.makedirs(os.path.dirname(output_file), exist_ok=True)
                label_format = ' '.join('--label ' + i for i in sorted(label))
                command = f"pyang --plugindir=./plugins -f jsonWithValue {label_format} -p {directory} {base_yang_path} {file_path} > {output_file}"
                subprocess.run(command, shell=True, check=True)
                with open(output_file, 'r') as f:
                    yang_data = json.load(f)
            except subprocess.CalledProcessError as e:
                print(f"Error processing file {file}: {e}")
                continue
            except json.JSONDecodeError as e:
                print(f"Error parsing JSON for file {file}: {e}")
                continue

        list_nodes, leaf_nodes, leaf_list_nodes = extract_leaf_nodes(yang_data['tree'], file)
        all_leaf_nodes_list.extend(list_nodes)
        all_leaf_nodes_leaf.extend(leaf_nodes)
        all_leaf_nodes_other.extend(leaf_list_nodes)

    return all_leaf_nodes_list, all_leaf_nodes_leaf, all_leaf_nodes_other

def parse_union_type(union_data):
    if isinstance(union_data, list) and union_data[0] == 'union':
        types = set()
        for item in union_data[1]:
            if isinstance(item, list):
                types.update(parse_union_type(item))
            else:
                types.add(item)
        return sorted(types) if len(types) > 1 else list(types)
    return union_data

def extract_leaf_nodes(tree, module_name, path='', parent_type=None):
    global list_map, leaf_map, ll_map
    nodes_list = []
    nodes_leaf = []
    nodes_leaf_list = []

    for key, value in tree.items():
        new_path = f"{path}/{key}" if path else key

        if isinstance(value, list) and len(value) > 1:
            if value[0] in ['leaf', "leaf-list"]:
                leaf_type = parse_union_type(value[1])
                if isinstance(leaf_type, list):
                    leaf_type = '|'.join(leaf_type) if len(leaf_type) > 1 else leaf_type[0]
                if leaf_type != 'unknown':
                    full_path = f"{module_name}:{new_path}"
                    label = None if len(value) < 5 else value[4]
                    if value[0] == 'leaf-list':
                        nodes_leaf_list.append((key.split(':')[-1], leaf_type, value[2], value[3], label, full_path))
                        #print(f"List parent: {nodes_leaf_list[-1]}")
                    elif parent_type == 'list':
                        tmp_k1 = path2netconf(full_path).rsplit(' ',1)[0]
                        tmp_k2 = key.split(':')[-1]
                        list_map[tmp_k1][tmp_k2] = value[2]
                        #if value[3]:
                        #    list_map[tmp_k1].setdefault('K1E1Y1', []).append(tmp_k2)
                        nodes_list.append((tmp_k2, leaf_type, value[2], value[3], label, full_path))
                        #print(f"List parent: {nodes_list[-1]}")
                    else:
                        tmp_k1 = path2netconf(full_path)
                        tmp_k2 = key.split(':')[-1]
                        leaf_map[tmp_k1] = value[2]
                        nodes_leaf.append((tmp_k2, leaf_type, value[2], value[3], label, full_path))
                        #print(f"Other parent: {nodes_leaf[-1]}")
            elif value[0] == 'list' and isinstance(value[1], dict):
                # Extract list keys
                if len(value) > 2 and isinstance(value[2], list):
                    list_keys = []
                    for key_item in value[2]:
                        if isinstance(key_item, list) and len(key_item) > 1:
                            list_keys.append(key_item[1])
                    if list_keys:
                        tmp_k1 = path2netconf(f"{module_name}:{new_path}")
                        list_map[tmp_k1]['K1E1Y1'] = list_keys
                node_list, node_leaf, node_leaf_list = extract_leaf_nodes(value[1], module_name, new_path, 'list')
                nodes_list.extend(node_list)
                nodes_leaf.extend(node_leaf)
                nodes_leaf_list.extend(node_leaf_list)
            elif isinstance(value[1], dict):
                node_list, node_leaf, node_leaf_list = extract_leaf_nodes(value[1], module_name, new_path, value[0] if parent_type != "list" else "list")
                nodes_list.extend(node_list)
                nodes_leaf.extend(node_leaf)
                nodes_leaf_list.extend(node_leaf_list)

    return nodes_list, nodes_leaf, nodes_leaf_list

def find_default_leaves(leaf_nodes_list, leaf_nodes_leaf, leaf_nodes_other, helm = False, label = ["plato-labelling"], default_restricted = False):
    combined_list = set()
    netconf_str = StringIO()
    day_map = {}
    NREG_deployedServices_services = False

    writer = None
    if not default_restricted:
        f = open('cm.csv','w')
        writer = csv.writer(f)
        writer.writerow(["yang"])
        writer.writerow(["name", "type", "default", "mandatory", *[i for i in label], "T", "Day0/1/2", "comments"])

    with open('day_map_helm.yaml' if helm else "day_map.yaml",'r') as f:
        day_map = yaml.load(f)

    for name, type_, value, valueM, label, path in leaf_nodes_list:
        netconf_str.truncate(0)
        netconf_str.seek(0)
        for i in path.split('/')[:-1]:
            netconf_str.write(i.split(':')[-1])
            netconf_str.write(' ')
        ss = netconf_str.getvalue()[:-1]
        combined_list.add(ss)

        name = "{} {}".format(ss, path.split('/')[-1].split(':')[-1])
        prefix = "NREG" if prod_type == PROD_TYPE.HSS else "REGISTERS"
        if name == f"{prefix} deployedServices services":
            if NREG_deployedServices_services:
                continue
            else:
                NREG_deployedServices_services = True
        if writer:
            writer.writerow([name, type_, value, valueM, *[i for i in label.split('|')], "list", day_map.get(name)])
    for name, type_, value, valueM, label, path in leaf_nodes_other:
        netconf_str.truncate(0)
        netconf_str.seek(0)
        for i in path.split('/')[:-1]:
            netconf_str.write(i.split(':')[-1])
            netconf_str.write(' ')
        ss = netconf_str.getvalue()[:-1]
        combined_list.add(ss)

        name = "{} {}".format(ss, path.split('/')[-1].split(':')[-1])
        if writer:
            writer.writerow([name, type_, value, valueM, *[i for i in label.split('|')], "leaf-list", day_map.get(name)])

    combined = set()
    for name, type_, value, valueM, label, path in leaf_nodes_leaf:
        #print(f"default -- {name} {type_} {value} {valueM} {path}")
        if default_restricted and not value:
            continue
        netconf_str.truncate(0)
        netconf_str.seek(0)
        for i in path.split('/'):
            netconf_str.write(i.split(':')[-1])
            netconf_str.write(' ')
        netconf_str.write(value if value else "WITHOUT_DEFAULT")
        ss = netconf_str.getvalue()
        combined.add(ss)

        name = ss.rsplit(' ',1)[0]
        if writer:
            writer.writerow([name, type_, value, valueM, *[i for i in label.split('|')], None, day_map.get(name)])

    netconf_str.close()
    if writer:
        f.close()
    return combined, combined_list

def find_deviation_cm(leaf_nodes_list, leaf_nodes_leaf, leaf_nodes_other, xml_rel, xml_user):
    '''
    Just for demo ,

    '''
    #for k,v in list_map.items():
    #    print(f"{k} --> {v}")
    if not xml_rel or not xml_user:
        return
    def custom_sort_key(s):
        m = re.search(r'\[(\d+)\]',s)
        if m:
            num = int(m.group(1))
            prefix = s[:m.start()]
            suffix = s[m.end():]
            return (prefix, num, suffix)
        return (s,0,'')
    def custom_sort_key_2(s):
        parts = re.split(r'(\[\d+\])',s)
        sort_key = []
        for p in parts:
            if re.fullmatch(r'\[\d+\]', p):
                sort_key.append(int(p[1:-1]))
            else:
                sort_key.append(p)
        return sort_key

    combined = set()
    combined_list = set()
    netconf_str = StringIO()
    NREG_deployedServices_services = False

    writer = None
    if True:
        f = open('deviation.csv','w')
        writer = csv.writer(f)
        writer.writerow(["customer setting deviation"])
        writer.writerow(["name", "type", "default merged", "customer", "diff", "mandatory", "T", "T_element"])

    tree_rel = etree.parse(xml_rel)
    root_rel = tree_rel.getroot()

    tree_user = etree.parse(xml_user)
    root_user = tree_user.getroot()

    key_list = set()
    key_list_type = set()
    rel_list_map = {}
    user_list_map = {}
    _, rel_list, _ = parse_xml(xml_rel)
    _, user_list, _ = parse_xml(xml_user)

    for i in rel_list:
        tmp = i.rsplit('|||',1)
        key_list.add(tmp[0])
        key_list_type.add(re.sub(r'\[\d+\]', '', tmp[0]))
        rel_list_map[tmp[0]] = tmp[1]
    for i in user_list:
        tmp = i.rsplit('|||',1)
        key_list.add(tmp[0])
        key_list_type.add(re.sub(r'\[\d+\]', '', tmp[0]))
        user_list_map[tmp[0]] = tmp[1]

    path_map = {path2netconf(i[-1]): i for i in leaf_nodes_list}
    for k in sorted(key_list, key = custom_sort_key):
        type_e = re.sub(r'\[\d+\]', '', k)
        try:
            type_raw = path_map[type_e]
        except KeyError as e:
            print(f"Can't found: {type_e} {e}")
            continue

        type_e = re.split(r'(\[\d+\])', k)[0]
        name, type_, value, valueM, label, path = type_raw
        if writer:
            r1 = rel_list_map.get(k)
            u1 = user_list_map.get(k)
            d1 = None if r1 == u1 else "yes"
            writer.writerow([k, type_, r1, u1, d1, valueM, "list", type_e])

    for name, type_, value, valueM, label, path in leaf_nodes_leaf:
        #print(f"default -- {name} {type_} {value} {valueM} {path}")
        netconf_str.truncate(0)
        netconf_str.seek(0)
        for i in path.split('/'):
            netconf_str.write(i.split(':')[-1])
            netconf_str.write(' ')
        netconf_str.write(value if value else "WITHOUT_DEFAULT")
        ss = netconf_str.getvalue()
        combined.add(ss)

        name = ss.rsplit(' ',1)[0]

        valueR = None
        valueC = None
        try:
            elem =  root_rel.xpath(path2xpath(path), namespaces = root_rel.nsmap)
            if elem:
                valueR = elem[0].text
                #print(f"Rel -- {path} {path2xpath(path)}: {valueR}")
        except Exception as e:
            print(f"Exception -- {path} {path2xpath(path)}: {e}")

        try:
            elem =  root_user.xpath(path2xpath(path), namespaces = root_user.nsmap)
            if elem:
                valueC = elem[0].text
                #print(f"User -- {path} {path2xpath(path)}: {valueC}")
        except Exception as e:
            print(f"Exception -- {path} {path2xpath(path)}: {e}")
        value = valueR if valueR != None else value
        valueC = valueC if valueC != None else value

        if writer:
            d1 = None if value == valueC else "yes"
            writer.writerow([name, type_, value, valueC, d1, valueM, None])

    netconf_str.close()
    if writer:
        f.close()
    return

def parse_xml(xml_file):
    rel_leaf = set()
    rel_list = set()
    rel_all  = {}
    tree = etree.parse(xml_file)
    root = tree.getroot()
    for element in root.iter():
        if len(element) == 0:
            xpath = tree.getpath(element)
            value = element.text.strip() if element.text and element.text.strip() else ""
            value = "WITHOUT_VALUE" if not value else value
            path = xpath2netconf(xpath)
            rel_all[path] = value
            if '[' in xpath:
                rel_list.add(f"{path}|||{value}")
            else:
                rel_leaf.add(f"{path}|||{value}")
    return rel_leaf, rel_list, rel_all


def find_customer(directory, combined, combined_list):
    if not os.path.exists(directory):
        return
    common_set = set()
    repo = Path(directory)
    files = [f for f in repo.rglob("*") if f.suffix in ['.txt', '.db']]
    print("component_map ")
    max_len = max(len(str(key)) for key in component_map.keys())
    for k,v in component_map.items():
        print("\t{:<{}} {}".format(k, max_len, v))
    for file in files:
        type_netconf = True
        try:
            with open(file, 'r') as f:
                if "Sending Request to CMREPO" in f.readline():
                    type_netconf = False
        except Exception as e:
            print(f"ERROR in file {file} for {e}")
            continue
        if type_netconf:
            tmp = find_customer_netconf(file, combined, combined_list)
            common_set = (common_set & tmp) if common_set else tmp
        else:
            find_customer_misc(file, combined, combined_list)

    print("\n\nCOMMON " + '*'*40)
    for i in sorted(common_set):
        print(f"\t{i}")


def parse_netconf_dump(file, combined = None, combined_list = None):
    if os.path.splitext(file)[1] != '.txt':
        raise TypeError("netconf dump data need suffix with .txt")

    def check_list(line):
        parts = line.split()
        if len(parts) < 2 or parts[0] != "NREG":
            return None, None
        for k,v in list_map.items():
            if not line.startswith(f"{k} "):
                continue
            if 'K1E1Y1' not in v or not v['K1E1Y1']:
                return k, v
            key_values = {}
            remaining_parts = line[len(k):].strip().split()
            if len(remaining_parts) >= len(v['K1E1Y1']):
                for i, key_name in enumerate(v['K1E1Y1']):
                    key_values[key_name] = remaining_parts[i]
                result_v = v.copy()
                for key_name, key_value in key_values.items():
                    result_v[key_name] = key_value
                return k, result_v
        return None, None

    def check_leaf(line):
        parts = line.split()
        if len(parts) < 2 or parts[0] != "NREG":
            return None, None
        if '"' in line:
            parts = line.split('"')
            path = parts[0].strip()
            value = parts[1] if len(parts) > 1 else ""
        else:
            last_space = line.rstrip().rfind(' ')
            if last_space > 0:
                path = line[:last_space].strip()
                value = line[last_space+1:].strip()
            else:
                return None, None
        return path, value

    def peek_generator(f):
        prev_line = None
        for line in f:
            if prev_line is not None:
                yield prev_line, line
            prev_line = line
        if prev_line is not None:
            yield prev_line, None

    netconf_data = {}
    warning = set()
    try:
        with open(file,'r', encoding='utf-8') as f:
            it = peek_generator(f)
            for cur,nxt in it:
                line = cur.strip()
                if not line:
                    continue
                path, value = check_leaf(line)
                if path in leaf_map:
                    netconf_data[path] = value
                    continue
                else:
                    k, v = check_list(line)
                    if not k:
                        #raise ValueError(f"something wrong for {line}")
                        if path:
                            warning.add(path)
                        continue
                    m = v['K1E1Y1']
                    if m:
                        for i in range(0, len(m)):
                            netconf_data[f"{k}[0] {m[i]}"] = v[m[i]]
                    if not nxt:
                        break
                    k1, _ = check_list(nxt.strip())
                    index = 0
                    while nxt.strip().split(' ',1)[0] != "NREG" or k1 == k:
                        cur, nxt = next(it)
                        if not cur:
                            break
                        if cur.startswith(' '):
                            parts = cur.strip().split(' ',1)
                            if len(parts) == 2:
                                key, value = parts
                                netconf_data[f"{k}[{index}] {key}"] = value.strip()
                            continue
                        elif cur.strip() == '!':
                            if not nxt:
                                break
                            k1, _ = check_list(nxt.strip())
                            if not k1 or k1 != k:
                                break;
                            else:
                                index += 1
                            continue
                        elif cur.startswith(k+' '):
                            _,v = check_list(cur.strip())
                            for i in range(0, len(m)):
                                netconf_data[f"{k}[{index}] {m[i]}"] = v[m[i]]
                        else:
                            print(f"what wrong: {cur}: {nxt}")

    except Exception as e:
        print(f"can not read {file} : {e}")
    #for k,v in netconf_data.items():
    #    print(f"{k}: {v}")
    if warning:
        print(f"check available in yang :")
    for i in sorted(warning):
        print(i)
    return netconf_data

def find_customer_netconf(file, combined, combined_list):
    netconf_str = set()
    try:
        with open(file,'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and line.split()[0] == "NREG" and line.split()[1] != "hlrcallp":
                    netconf_str.add(line)

        exclusion = combined_list.copy()
        info_list =  set()
        for i in combined_list:
            for j in netconf_str:
                if i in j:
                    #print(f'{COLORS["ERROR"]}{j}{COLORS["RESET"]}')
                    if i in exclusion:
                        exclusion.remove(i)
        print(f"\n\n{file} default netconf:**********************")
        for i in sorted(netconf_str & combined):
            #print(f'{COLORS["INFO"]}{i}{COLORS["RESET"]}')
            print(f"\t{i}")
        print(f"{file} customer netconf:----------------------")
        for i in sorted(netconf_str - (netconf_str & combined)):
            skip_list = False
            for j in combined_list:
                if j in i:
                    info_list.add(i)
                    skip_list = True
                    break
            if skip_list:
                continue
            #print(f'{COLORS["ERROR"]}{i}{COLORS["RESET"]}')
            print(f"\t{i}")

        print(f"{file} LIST default netconf:----------------------")
        for i in sorted(exclusion):
            #print(f'{COLORS["INFO"]}{i}{COLORS["RESET"]}')
            print(f"\t{i}")
        print(f"{file} LIST customer netconf:**********************")
        for i in sorted(combined_list - exclusion):
            #print(f'{COLORS["INFO"]}{i}{COLORS["RESET"]}')
            print(f"\t{i}")
    except Exception as e:
        print(f"can not read {file} : {e}")
    return netconf_str  & combined


def find_customer_misc(file, combined, combined_list):
    # Patterns to identify components and their content
    component_pattern = re.compile(r'^COMPONENT=([^:]+):')
    param_pattern = re.compile(r'^\s*([^=#\s][^=]*?)\s*=\s*(.*)')
    array_name_pattern = re.compile(r'^([\w\.]+)\[\d+\]')

    current_component = None

    # Data structures to store results
    arrays = defaultdict(set)  # Using set to avoid duplicates
    params = defaultdict(dict) # Using dict to store param-value pairs

    with open(file, 'r') as f:
        for line in f:
            line = line.strip()

            # Check for component start
            component_match = component_pattern.match(line)
            if component_match:
                current_component = component_match.group(1)
                continue

            # Only process if we're in a relevant component
            if current_component and any(current_component.startswith(prefix) 
                                       for prefix in ['ims/', 'platform/', 'ngc/']):
                # Check for parameter
                param_match = param_pattern.match(line)
                if param_match:
                    param_name = param_match.group(1).strip()
                    param_value = param_match.group(2).strip()

                    # Check if it's an array parameter
                    array_match = array_name_pattern.match(param_name)
                    if array_match:
                        array_name = array_match.group(1)
                        arrays[current_component].add(array_name)
                    else:
                        params[current_component][param_name] = param_value

    # Print arrays first, sorted by component and array name
    print(f"\n\n{file} === LIST ===")
    for component in sorted(arrays.keys()):
        for array_name in sorted(arrays[component]):
            print(f"\t{component} {array_name}")

    # Print parameters, sorted by component and parameter name
    print(f"{file} === Parameters ===")
    for component in sorted(params.keys()):
        for param_name in sorted(params[component].keys()):
            print(f"\t{component} {param_name} {params[component][param_name]}")



def find_duplicate_leaves(leaf_nodes_list, leaf_nodes_other):
    # Find duplicates in list nodes
    list_dict = defaultdict(list)
    for name, type_, value, valueM, label, path in leaf_nodes_list:
        list_dict['/'.join(path.split('/')[-2:])].append((type_, value, label, path))

    # Find duplicates in other nodes
    other_dict = defaultdict(list)
    for name, type_, value, valueM, label, path in leaf_nodes_other:
        other_dict[name].append((type_, value, label, path))

    # Combine duplicates
    duplicates_list = {name: occurrences for name, occurrences in list_dict.items() if len(occurrences) > 1}
    duplicates_other = {name: occurrences for name, occurrences in other_dict.items() if len(occurrences) > 1}

    # Find nodes that appear in both list and other
    common_names = set(list_dict.keys()) & set(other_dict.keys())
    duplicates_mixed = {}
    for name in common_names:
        duplicates_mixed[name] = list_dict[name] + other_dict[name]

    return duplicates_list, duplicates_other, duplicates_mixed

def sort_duplicates(duplicates):
    sorted_duplicates = {}
    for name, occurrences in duplicates.items():
        # Sort by type, then by leaf_info
        sorted_occurrences = sorted(occurrences, key=lambda x: (x[0], '/'.join(x[1].split('/')[-2:])))
        sorted_duplicates[name] = sorted_occurrences

    # Sort the dictionary by leaf name
    return dict(sorted(sorted_duplicates.items(), key=lambda item: str.casefold(item[0])))

def print_consistent_duplicates(duplicates_list, duplicates_other, duplicates_mixed):
    print("=== DUPLICATES IN LIST NODES ===")
    for leaf_name, occurrences in duplicates_list.items():
        types = set(occ[0] for occ in occurrences)
        leaf_info = {'/'.join(occ[2].split('/')[-3:]) for occ in occurrences}
        if len(types) == 1:
            print(f"Leaf node '{leaf_name}' parent {len(leaf_info)} (type: {types.pop()}) appears in:")
            for _, value, path in occurrences:
                print(f"  - [{value}] {path}")
            print()

    print("=== DUPLICATES IN OTHER NODES ===")
    for leaf_name, occurrences in duplicates_other.items():
        types = set(occ[0] for occ in occurrences)
        leaf_info = {'/'.join(occ[2].split('/')[-2:]) for occ in occurrences}
        if len(types) == 1:
            print(f"Leaf node '{leaf_name}' parent {len(leaf_info)} (type: {types.pop()}) appears in:")
            for _, value, path in occurrences:
                print(f"  - [{value}] {path}")
            print()

    #print("=== DUPLICATES IN MIXED NODES ===")
    #for leaf_name, occurrences in duplicates_mixed.items():
    #    types = set(occ[0] for occ in occurrences)
    #    leaf_info = {'/'.join(occ[1].split('/')[-2:]) for occ in occurrences}
    #    if len(types) == 1:
    #        print(f"Leaf node '{leaf_name}' parent {len(leaf_info)} (type: {types.pop()}) appears in:")
    #        for _, value, path in occurrences:
    #            print(f"  - [{value}] {path}")
    #        print()

    print("#"*80)
    print("=== INCONSISTENT TYPES IN LIST NODES ===")
    for leaf_name, occurrences in duplicates_list.items():
        types = set(occ[0] for occ in occurrences)
        if len(types) > 1:
            print(f"Leaf node '{leaf_name}' (type: {types}) appears in:")
            for type_, value, path in occurrences:
                print(f" - [{type_}:{value}] {path}")
            print()

    print("=== INCONSISTENT TYPES IN OTHER NODES ===")
    for leaf_name, occurrences in duplicates_other.items():
        types = set(occ[0] for occ in occurrences)
        if len(types) > 1:
            print(f"Leaf node '{leaf_name}' (type: {types}) appears in:")
            for type_, value, path in occurrences:
                print(f" - [{type_}:{value}] {path}")
            print()

    #print("=== INCONSISTENT TYPES IN MIXED NODES ===")
    #for leaf_name, occurrences in duplicates_mixed.items():
    #    types = set(occ[0] for occ in occurrences)
    #    if len(types) > 1:
    #        print(f"Leaf node '{leaf_name}' (type: {types}) appears in:")
    #        for type_, value, path in occurrences:
    #            print(f" - [{type_}:{value}] {path}")
    #        print()

def generate_yaml(duplicates_list, duplicates_other, duplicates_mixed, output_file):
    def convert_value(value):
        try:
            return int(value)
        except ValueError:
            try:
                if value.lower() == 'true':
                    return True
                elif value.lower() == 'false':
                    return False
            except ValueError:
                return value

    yaml_data = {}

    # Process list nodes
    for leaf_name, occurrences in duplicates_list.items():
        types = set(occ[0] for occ in occurrences)
        if len(types) == 1:
            yaml_data[leaf_name] = {
                'typeCommon': occurrences[0][0],
                'set': None,
                'occurrences': [
                    {
                        'default': convert_value(occ[1]),
                        'path': occ[2]
                    }
                    for occ in occurrences
                ]
            }

    # Process other nodes
    for leaf_name, occurrences in duplicates_other.items():
        types = set(occ[0] for occ in occurrences)
        if len(types) == 1:
            yaml_data[leaf_name] = {
                'typeCommon': occurrences[0][0],
                'set': None,
                'occurrences': [
                    {
                        'default': convert_value(occ[1]),
                        'path': occ[2]
                    }
                    for occ in occurrences
                ]
            }

    # Process inconsistent types
    for leaf_name, occurrences in duplicates_list.items():
        types = set(occ[0] for occ in occurrences)
        if len(types) > 1:
            yaml_data[leaf_name] = {
                'set': None,
                'occurrences': [
                    {
                        'type': occ[0],
                        'default': convert_value(occ[1]),
                        'path': occ[2]
                    }
                    for occ in occurrences
                ]
            }

    for leaf_name, occurrences in duplicates_other.items():
        types = set(occ[0] for occ in occurrences)
        if len(types) > 1:
            yaml_data[leaf_name] = {
                'set': None,
                'occurrences': [
                    {
                        'type': occ[0],
                        'default': convert_value(occ[1]),
                        'path': occ[2]
                    }
                    for occ in occurrences
                ]
            }

    with open(output_file, 'w') as f:
        yaml.dump(yaml_data, f)

def flatten_json(data, parent_key='', sep=' ', index_sep='[', with_index=True):
    flatten = {}
    if isinstance(data, dict):
        for key, value in data.items():
            key_path = f"{parent_key}{sep}{key}" if parent_key else key
            flatten.update(flatten_json(value, key_path, sep, index_sep, with_index))
    elif isinstance(data, list):
        for idx, item in enumerate(data):
            key_path = f"{parent_key}{index_sep}{idx}]" if with_index else parent_key
            flatten.update(flatten_json(item, key_path, sep, index_sep, with_index))
    else:
        flatten[parent_key] = data
    return flatten


def path2xpath(path):
    element = path.split('/')
    header = ':'.join(element[0].split(':')[1:])
    header = f"{header}/{element[1]}"
    namespace = element[1].split(':')[1]
    xpath = [f"{namespace}:{p}" for p in element[2:]]
    xpath = f"/ns0:config/{header}/{'/'.join(xpath)}"
    return xpath

def path2netconf(path):
    prefix = prod_map.get(prod_type)
    element = path.split('/')
    if prefix and element[0].split(':')[-1] != prefix:
        raise TypeError("xml file is not compatible to cm project")

    path = [i.split(':')[-1] if ':' in i else i for i in element]
    return ' '.join(path)

def xpath2netconf(xpath):
    prefix = prod_map.get(prod_type)
    element = xpath.split('/')
    if prefix and element[2].split(':')[1] != prefix:
        raise TypeError("xml file is not compatible to cm project")

    path = [p.split(':')[1] for p in element[2:]]
    return ' '.join(path)

def xml_instances(root):
    prefix = "NREG" if prod_type == PROD_TYPE.HSS else "REGISTERS"
    instances = {i.text for i in root.xpath(f"/ns0:config/{prefix}:{prefix}/{prefix}:deployedServices/{prefix}:services",namespaces = root.nsmap)}
    if prod_type == PROD_TYPE.HSS:
        instances.add("HSSCALLP")
    else:
        instances.update(["UDM_UECM", "UDM_SDM", "UDM_EE", "UDM_MT", "UDM_PP", "UDM_NIDD", "NIM"])
    return instances


def create_element(root, xpath, value):
    "xpath: /ns0:config/NREG:NREG/HSSLI:HSSLI/HSSLI:HssliLia/HSSLI:LIA.liAckWaitTimer"
    namespaces = root.nsmap
    elements = xpath.split('/')
    ns_alias = f"{elements[-1].split(':')[0]}"
    namespace = namespaces[ns_alias]
    instances = xml_instances(root)
    if not ns_alias in instances:
        print(f"instance {ns_alias} not exists in {instances}")
        return
    else:
        print(f"create {xpath} {value}")

    xpath_create = '/'.join(elements[:4])
    parent = root.xpath(xpath_create, namespaces=root.nsmap)[0]
    for i, p in enumerate(elements[4:]):
        tag = f"{{{namespace}}}{p.split(':')[1]}"
        node = parent.find(tag)
        if node is None:
            parent = etree.SubElement(parent, tag)
            if i+1 == len(elements[4:]):
                parent.text = str(value)
        else:
            parent = node

def update_xml(xml_file, value=None, yaml_file=""):
    """
    path format
        HSSCALLP.yang:NREG:NREG/HSSCALLP:HSSCALLP/HsscallpDiameterdisp/DiameterCommon.OverwriteOriginHostAndRealm
    absolute xpath
        /ns0:config/NREG:NREG/HSSCALLP:HSSCALLP/HSSCALLP:HsscallpDiameterdisp/HSSCALLP:DiameterCommon.OverwriteOriginHostAndRealm
    invoke style
        root.xpath('XPATH', namespaces=root.nsmap)[0].text
    """

    if not value:
        with open(yaml_file, 'r') as f:
            value = yaml.load(f)

    tree = etree.parse(xml_file)
    root = tree.getroot()

    for _, leaf_data in value.items():
        if leaf_data['set'] is not None:
            for occurrence in leaf_data['occurrences']:
                xpath = path2xpath(occurrence['path'])
                node = root.xpath(xpath, namespaces=root.nsmap)
                if not node:
                    create_element(root, xpath, leaf_data['set'])
                    continue
                for n in node:
                    print(f"{xpath}:{n.text} --> {leaf_data['set']}")
                    n.text = str(leaf_data['set'])
    with open(xml_file, 'wb') as f:
        tree.write(f, encoding=tree.docinfo.encoding, xml_declaration=True, pretty_print=True)
        #subprocess.run(f"xmllint --format {xml_file} --output {xml_file}", shell=True)

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Parse YANG files and find duplicate leaf nodes.")
    parser.add_argument("directory", help="Directory containing YANG files")
    parser.add_argument("--force", action="store_true", help="Force parsing of YANG files even if output exists")
    parser.add_argument("--manual", action="store_true", help="Generate YAML file with duplicate leaves")
    parser.add_argument("--xml", help="Expand/overwrite input XML file with duplicated values")
    parser.add_argument("--xml_user", help="Expand/overwrite input XML file with duplicated values")
    parser.add_argument("--netconf_user", help="User netconf dump data")
    parser.add_argument("--customer", help="set registercet customer config directory")
    parser.add_argument("--label", nargs='+', help="parse yang extension label")
    parser.add_argument("--helm", action="store_true", help="indicator lcm parse")
    parser.add_argument("--yaml", help="Specify yaml file in release package")
    parser.add_argument("--yaml_user", help="Specify yaml file user used")
    parser.add_argument("--deviation", action="store_true", help="get deviation between user setting and release instance")

    args = parser.parse_args()

    if args.xml and args.manual:
        parser.error("--manual and --xml options cannot be used together")
    if args.xml_user and args.netconf_user:
        parser.error("--xml_user and --netconf_user options cannot be used together")

    if not args.label:
        args.label = []
    if not args.helm:
        leaf_nodes_list, leaf_nodes_leaf, leaf_nodes_other = parse_yang_cm(args.directory, args.force, args.label)
    else:
        leaf_nodes_list, leaf_nodes_leaf, leaf_nodes_other = parse_yang_lcm(args.directory, args.force, args.label)
    duplicates_list, duplicates_other, duplicates_mixed = find_duplicate_leaves(leaf_nodes_list, leaf_nodes_leaf)

    combined, combined_list = find_default_leaves(leaf_nodes_list, leaf_nodes_leaf, leaf_nodes_other, args.helm, args.label)

    if args.customer:
        file = './component_map.yaml'
        try:
            with open(file, 'r') as f:
                component_map = yaml.load(f)
        except Exception as e:
            print(f"can not load {file} : {e}")

        find_customer(args.customer, combined, combined_list)

    if args.deviation and args.yaml:
        with open(args.yaml, 'r')as f_rel ,open(args.yaml_user, 'r') as f_usr:
            value_rel = yaml.load(f_rel)
            value_usr = yaml.load(f_usr)
            flatten_rel = flatten_json(value_rel)
            flatten_usr = flatten_json(value_usr)
            df_1 = pd.DataFrame.from_dict(flatten_json(value_rel), orient = 'index', columns=['release'])
            df_2 = pd.DataFrame.from_dict(flatten_json(value_usr), orient = 'index', columns=['user'])
            df = pd.concat([df_1, df_2], axis=1)        # 默认索引对齐
            #df = pd.DataFrame()
            #df['release'] = pd.Series(flatten_rel)     # 不强制对齐索引
            #df['user'] = pd.Series(flatten_usr).reindex(df.index)

            pd.set_option('display.max_rows', None)     # 显示所有行
            pd.set_option('display.max_columns', None)  # 显示所有列
            pd.set_option('display.width', None)        # 不限制每行的字符数
            pd.set_option('display.max_colwidth', None) # 不限制列宽
            df = df.fillna('None')
            mask = df['release'] != df['user']
            #df.loc[mask, 'release'] = df.loc[mask, 'user']
            print(df[mask])
        with open('flatten_rel.json','w') as rel, open('flatten_usr.json','w') as usr:
            json.dump(flatten_rel, rel, indent = 2)
            json.dump(flatten_usr, usr, indent = 2)



    if args.deviation and args.xml:
        find_deviation_cm(leaf_nodes_list, leaf_nodes_leaf, leaf_nodes_other, args.xml, args.xml_user)

        rel_leaf, rel_list, _ = parse_xml(args.xml)
        rel_leaf = set(map(lambda i : re.sub(r'\|\|\|', ' ', i), rel_leaf))
        for i in combined.copy():
            ret = set(filter(lambda j: j.startswith(i.rsplit(" ",1)[0]), rel_leaf))
            if ret and i != next(iter(ret)) and len(ret) == 1:
                combined.remove(i)
                combined.add(*ret)

        combined_def, combined_list = find_default_leaves(leaf_nodes_list, leaf_nodes_leaf, leaf_nodes_other, args.helm, args.label, True)
        user_leaf = set()
        user_list = set()
        if args.netconf_user:
            netconf_data = parse_netconf_dump(args.netconf_user, combined, combined_list)
            for k,v in netconf_data.items():
                print(f"{k}: {v}")
                if '[' in k:
                    user_list.add(f"{k} {v}")
                else:
                    user_leaf.add(f"{k} {v}")
        elif args.xml_user:
            user_leaf, user_list, _ = parse_xml(args.xml_user)
            user_leaf = set(map(lambda i : re.sub(r'\|\|\|', ' ', i), user_leaf))
        def should_ignore(x, target):
            converted = path2netconf(x[-1])
            return converted if converted == target.rsplit(" ",1)[0] and x[3] else None
        for i in sorted(combined - (user_leaf & combined) - combined_def):
            if not leaf_nodes_leaf:
                break
            # need python 3.8
            #mandatory = next((j for x in leaf_nodes_leaf if (j := path2netconf(x[-1])) == i) and x[3], None)
            from functools import partial
            mandatory = next(filter(None, map(partial(should_ignore, target=i), leaf_nodes_leaf)), None)
            if not mandatory:
                print(f"ignore: {i}")
            else:
                print(f"{COLORS['ERROR']}HAVE TO SET: {mandatory}{COLORS['RESET']}")


    if args.manual:
        sorted_list = sort_duplicates(duplicates_list)
        sorted_other = sort_duplicates(duplicates_other)
        sorted_mixed = sort_duplicates(duplicates_mixed)
        print_consistent_duplicates(sorted_list, sorted_other, sorted_mixed)
        generate_yaml(sorted_list, sorted_other, sorted_mixed, f"{args.directory}/output/user.yaml")
    elif args.xml:
        pass
        #update_xml(args.xml, yaml_file=f"{args.directory}/output/user.yaml")



