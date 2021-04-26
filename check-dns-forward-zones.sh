#!/bin/bash

# Copyright © 2021 Michael Bruskov <mixanemca@yandex.ru>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

progname=$(basename $0)
shortopts="a:c:e:E:hk:Tt:u:U:"
longopts="api-url:,cacert:,cert:,exclude:,exclude-tcp:,exclude-udp:,help,key:,timeout:,tls"

# Default options
interval="${COLLECTD_INTERVAL:-30}"
hostname="${COLLECTD_HOSTNAME:-$(hostname)}"
graphite_host="graphite"
graphite_port="2003"
use_tls="false"
cacert=
cert=
key=
exclude=
exclude_tcp=
exclude_udp=
curl_opts="-s -X GET"
api_url="https://10.0.0.1"
check_timeout="2"

usage() {
  cat <<-EO
This script run checks for DNSaaS forwarding zones and print metrics in collecd's exec format.

Usage:
  ${progname} [options]

Options:
EO
  cat <<-EO | column -s\& -t
  -a --cacert & Path to TLS Certificate Authority certificate.
  -c --cert & Path to TLS certificate.
  -e --exclude & Domains that exclude from checks.
  -E --exclude-tcp & Domains that exclude from TCP checks.
  -h --help & Print this message.
  -k --key & Path to TLS key.
  -T --tls & Use TLS for connection to API.
  -t --timeout & Timeout in seconds to DNS check. (Default: ${check_timeout})
  -u --api-url & The API server URL. (Default: ${api_url})
  -U --exclude-udp & Domains that exclude from UDP checks.
EO
}

args=$(getopt -s bash --options "${shortopts}" --longoptions "${longopts}" --name "${progname}" -- "$@") || exit 1
eval set -- "${args}"

while true; do
  case "$1" in
    -h|--help)
      usage; exit 0;;
    -a|--cacert)
      cacert="$2"; shift;;
    -c|--cert)
      cert="$2"; shift;;
    -e|--exclude)
      exclude="$2"; shift;;
    -E|--exclude-tcp)
      exclude_tcp="$2"; shift;;
    -k|--key)
      key="$2"; shift;;
    -T|--tls)
      use_tls="true";;
    -t|--timeout)
      check_timeout="$2"; shift;;
    -u|--api-url)
      api_url="$2"; shift;;
    -U|--exclude-udp)
      exclude_udp="$2"; shift;;
    --)
      shift; break;;
    *)
      break;;
  esac
  shift
done

# Parse flags (--tls)
if [[ "${use_tls}" == "true" ]]; then
  if [[ -z "${cacert}" ]]; then
    echo "ERROR: cacert argument not set." >&2
    exit 1
  fi
  if [[ -z "${cert}" ]]; then
    echo "ERROR: cert argument not set." >&2
    exit 1
  fi
  if [[ -z "${key}" ]]; then
    echo "ERROR: key argument not set." >&2
    exit 1
  fi
  # Add args to curl
  curl_opts="${curl_opts} --cacert ${cacert} --cert ${cert} --key ${key}"
fi

cleanup() {
  rm -f "${fzs_file}"
}

# get_ip returns ip address of nameserver
get_ip() {
  local input="$1"
  echo "${input}" | while IFS=: read ip port; do
    echo ${ip}
  done
}

# get_port returns port number of nameserver
get_port() {
  local input="$1"
  echo "${input}" | while IFS=: read ip port; do
    port=${port:-53}
    echo ${port}
  done
}

# check_soa do DNS requests for nameserver using both TCP and UDP
# returns
# 0 OK
# 1 UDP check failed
# 2 TCP check failed
check_soa() {
  local fz="$1"
  local ip="$2"
  local port="$3"
  # UDP
  if ! fgrep -wq "${fz}" <<< "${exclude_udp}"; then
    dig +short +time=${check_timeout} @${ip} -p ${port} SOA ${fz} &>/dev/null
    if [[ $? -ne 0 ]]; then
      print_result "${fz}" "${ip}" 1
      return
    fi
  fi
  # TCP
  if ! fgrep -wq "${fz}" <<< "${exclude_tcp}"; then
    dig +tcp +short +time=${check_timeout} @${ip} -p ${port} SOA ${fz} &>/dev/null
    if [[ $? -ne 0 ]]; then
      print_result "${fz}" "${ip}" 2
      return
    fi
  fi
  # OK
  print_result "${fz}" "${ip}" 0
}

# print_result prints result in collectd exec format
print_result() {
  local fz="$1"
  local ns_ip="$2"
  local metric="$3"
  # Send to Graphite
  nc -w 10 "${graphite_host}" "${graphite_port}" <<< "resources.dns_forward_zones_checker;hostname=${hostname};fz=${fz};ns=${ns_ip} ${metric} $(date +%s)"
}

# trap signal for graceful exit
trap cleanup EXIT INT TERM

# Get forward zones list and store to temp file
fzs_file=$(mktemp)
curl ${curl_opts} ${api_url}/api/v1/servers/localhost/forward-zones > ${fzs_file}
# Iterate over forward-zones list
for fz in $(jq -r '.[] | .name' "${fzs_file}"); do
  # Exclude domains from check (see -e|--exclude option)
  if fgrep -wq "${fz}" <<< "${exclude}"; then
    continue
  fi
  # Get zone nameservers and parse to ip and port
  namservers=$(jq -r ".[] | select(.name==\"${fz}\") | .nameservers | @tsv" "${fzs_file}")
  for ns in ${namservers}; do
    ip=$(get_ip "${ns}")
    port=$(get_port "${ns}")
    # Check SOA in background
    check_soa "${fz}" "${ip}" "${port}" &
  done
done

# wait background tasks
while true; do
  wait -n || {
    code="$?"
    ([[ $code = "127" ]] && exit 0 || exit "$code")
    break
  }
done;
