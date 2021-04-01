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
shortopts="d:f:g:hl:n:o:q:r:s:"
longopts="duration:,global-options:,help,hosts-file:,no-clean:,out-dir:,queries-file:,rate-limit:,results-file:,requests-per-host:,rsync-options:"

# Default options
hosts_file="hosts.txt"
global_options="-t 0 -h ${hosts_file}"
rsync_options="-a"

out_dir="$(pwd)/out"
results_file="/tmp/flame_metrics.json"
queries_file=""
duration="30m"
requests_per_host="3000"
no_clean="false"

usage() {
  cat <<-EO
This script run DNS stress test.

Usage:
  ${progname} [options]

Options:
EO
  cat <<-EO | column -s\& -t
  -d --duration & Test duration. Floating point number with an optional suffix: 's' for seconds (the default), 'm' for minutes, 'h' for hours or 'd' for days.
 & A duration of 0 disables the associated timeout. [Default: ${duration}]
  -f --hosts-file & File with target hosts, one per line and can include blank lines and comments (lines beginning with "#"). [Default: ${hosts_file}]
  -g --global-options & Global options for pssh commands. [Default: ${global_options}]
  -h --help & Show this message
  -l --rate-limit & Rate limit to a maximum of RPS per host. [Default: ${requests_per_host}]
  -n --no-clean & Don't clean up temporary files. [Default: ${no_clean}]
  -o --out-dir & Local directory for storing results by host. Default: [${out_dir}]
  -q --queries-file & File with DNS queries, one per row. Format: QNAME QTYPE.
  -r --results-file & Path to file for storing 'flame' output. [Default: ${results_file}]
  -s --rsync-options & Options for parallel-rsync command. [Default: ${rsync_options}]
EO
  cat <<-EO

Example:
  ${progname} --duration ${duration} --hosts-file ${hosts_file} --no-clean true --queries-file dns-queries-with-types.txt --rate-limit 5000
EO
}

args=$(getopt -s bash --options "${shortopts}" --longoptions "${longopts}" --name "${progname}" -- "$@") || exit 1
eval set -- "${args}"

while true; do
  case "$1" in
    -h|--help)
      usage; exit 0;;
    -d|--duration)
      duration=$2; shift;;
    -f|--hosts-file)
      hosts_file="$2"; shift;;
    -g|--global-options)
      global_options="$2"; shift;;
    -n|--no-clean)
      no_clean=$2; shift;;
    -o|--out-dir)
      out_dir="$2"; shift;;
    -q|--queries-file)
      queries_file="$2"; shift;;
    -l|--rate-limit)
      requests_per_host="$2"; shift;;
    -r|--results-file)
      results_file="$2"; shift;;
    -s|--rsync-options)
      rsync_options="$2"; shift;;
    --)
      shift; break;;
    *)
      break;;
  esac
  shift
done

if [[ -z ${queries_file} || ! -r ${queries_file} ]]; then
  echo "ERROR: you must set queries-file." >&2
  exit 1
fi

mkdir -p "${out_dir}"
hosts_count=$(grep -E -c -v '^$|^#' ${hosts_file})

# Distribute requests file
echo "Sync queries file..."
parallel-rsync $global_options $rsync_options -- "${queries_file}" "/tmp/${queries_file}"

echo "Kill running tests (maybe failed)..."
parallel-nuke ${global_options} -- flame
sleep 5

echo "Trancate file with results..."
parallel-ssh ${global_options} -- "cat /dev/null > ${results_file}"

echo "Run test with ${requests_per_host} RPS per host on ${duration}..."
parallel-ssh ${global_options} -- "timeout --preserve-status ${duration} flame -Q ${requests_per_host} -F inet -f /tmp/${queries_file} -v 0 -o ${results_file} \$(hostname -i)"

# Get results
echo "Get test results..."
parallel-ssh ${global_options} -o "${out_dir}" -- "tail -1 ${results_file} | jq .total_responses"

if [[ "${no_clean}" == "false" ]]; then
  echo "Remove temporary files..."
  parallel-ssh ${global_options} -- "rm -f /tmp/${queries_file} ${results_file}"
fi

echo "------"
# Summarise total results and print per host stats
NOERROR=0
NXDOMAIN=0
SERVFAIL=0
for file in ${out_dir}/*; do
  # per host
  HOST=$(basename ${file})
  NOERROR_HOST=$(jq -r .NOERROR ${file})
  NXDOMAIN_HOST=$(jq -r .NXDOMAIN ${file})
  SERVFAIL_HOST=$(jq -r .SERVFAIL ${file})
  ALL_HOST=$((NOERROR_HOST + NXDOMAIN_HOST + SERVFAIL_HOST))
  NOERROR_HOST_PERCENTS=$(echo "scale=2; ${NOERROR_HOST} * 100 / ${ALL_HOST}" | bc -l)
  NXDOMAIN_HOST_PERCENTS=$(echo "scale=2; ${NXDOMAIN_HOST} * 100 / ${ALL_HOST}" | bc -l)
  SERVFAIL_HOST_PERCENTS=$(echo "scale=2; ${SERVFAIL_HOST} * 100 / ${ALL_HOST}" | bc -l)
  echo "Responses from ${HOST}:"
  cat <<-EO | column -s\& -t
  NOERROR: & ${NOERROR_HOST} & ${NOERROR_HOST_PERCENTS}%
  NXDOMAIN: & ${NXDOMAIN_HOST} & ${NXDOMAIN_HOST_PERCENTS}%
  SERVFAIL: & ${SERVFAIL_HOST} & ${SERVFAIL_HOST_PERCENTS}%
EO

  # total
  #NOERROR=$((NOERROR + $(jq -r .NOERROR $file)))
  NOERROR=$((NOERROR + NOERROR_HOST))
  NXDOMAIN=$((NXDOMAIN + NXDOMAIN_HOST))
  SERVFAIL=$((SERVFAIL + SERVFAIL_HOST))
done

ALL=$((NOERROR + NXDOMAIN + SERVFAIL))
NOERROR_PERCENTS=$(echo "scale=2; ${NOERROR} * 100 / ${ALL}" | bc -l)
NXDOMAIN_PERCENTS=$(echo "scale=2; ${NXDOMAIN} * 100 / ${ALL}" | bc -l)
SERVFAIL_PERCENTS=$(echo "scale=2; ${SERVFAIL} * 100 / ${ALL}" | bc -l)

# Print total result
echo "Responses TOTAL (from ${HOSTS} hosts):"
cat <<-EO | column -s\& -t
  NOERROR: & ${NOERROR} & ${NOERROR_PERCENTS}%
  NXDOMAIN: & ${NXDOMAIN} & ${NXDOMAIN_PERCENTS}%
  SERVFAIL: & ${SERVFAIL} & ${SERVFAIL_PERCENTS}%
EO
