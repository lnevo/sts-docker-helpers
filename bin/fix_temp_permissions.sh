#!/usr/bin/env bash
# Fix temp/sessions ownership when CLI scripts ran as root inside the web container.
set -euo pipefail

_script_home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/paths.sh
source "${_script_home}/../lib/paths.sh"
sts_helpers_resolve_paths "${_script_home}/$(basename "${BASH_SOURCE[0]}")"

WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null || true)"
if [[ -z "${WEB_CID}" ]]; then
  echo "Web container is not running." >&2
  exit 1
fi

docker exec -u root "${WEB_CID}" sh -c \
  'chown -R www-data:www-data /var/www/html/sts/temp && chmod -R u+rwX,g+rwX /var/www/html/sts/temp'
echo "Fixed ownership on /var/www/html/sts/temp (www-data can write session output)."
