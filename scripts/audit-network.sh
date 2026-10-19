#!/usr/bin/env bash
# Fails when a Keeplight binary links networking code. Backs the Transparency page's
# "no network" claim. Usage: audit-network.sh [bin-dir]  (defaults to `swift build -c release --show-bin-path`)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${1:-${BIN_PATH:-$(cd "$root" && swift build -c release --show-bin-path)}}"

# Undefined symbols that mean sockets, URL loading or Network.framework.
symbols='(_socket|_connect|_getaddrinfo|_gethostbyname|_CFSocket|_CFStreamCreatePairWithSocket|_CFNetwork|_nw_|NSURLSession|NSURLConnection|NSURLRequest|_OBJC_CLASS_\$_NSURL(Session|Connection)|URLSession)'
# Frameworks that only exist to talk to the network.
frameworks='(Network\.framework|CFNetwork\.framework|WebKit\.framework)'

status=0
for name in KeeplightApp keeplight; do
    binary="$bin/$name"
    [[ -f "$binary" ]] || { echo "audit-network: missing $binary" >&2; exit 2; }
    if hits=$(nm -u "$binary" 2>/dev/null | grep -E "$symbols"); then
        echo "audit-network: $name references networking symbols:" >&2
        echo "$hits" | sed 's/^/  /' >&2
        status=1
    fi
    if libs=$(otool -L "$binary" | grep -E "$frameworks"); then
        echo "audit-network: $name links a networking framework:" >&2
        echo "$libs" | sed 's/^/  /' >&2
        status=1
    fi
done
[[ $status -eq 0 ]] && echo "audit-network: no networking symbols or frameworks in KeeplightApp, keeplight"
exit $status
