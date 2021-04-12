# dns-scripts
Accessory scripts to work with DNS.

|Name|Description|Dependencies|
|:--:|:---------:|:----------:|
| `dns-stress-test` | This script run DNS stress test. Used [flamefrower](https://github.com/DNS-OARC/flamethrower) | `bc`, `getopt`, `flamethrower`, `jq`, `pssh` |
| `check-forward-zones` | This script run checks for DNSaaS forwarding zones and print metrics in collecd's exec format. | `gnu-getopt`, `jq`, `curl` |
