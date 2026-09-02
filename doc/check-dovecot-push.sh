#!/usr/bin/env bash
#
# Check the Dovecot --> EGroupware push server path for IMAP push notifications
#
# Run as root on the host running Dovecot (and usually EGroupware + the push server):
#
#   bash check-dovecot-push.sh [imap-user e.g. user@example.org] [--simulate] [--push-url URL] [--token TOKEN] [--push-container NAME]
#
# --simulate sends ONE fake "MessageNew" for the given imap-user to the push server, exactly like
#            Dovecot's push_notification plugin does: the user sees a "New mail from push-test" toast
#            in every browser logged into EGroupware. Nothing else is modified.
# --push-url / --token override what is auto-detected from doveconf / the push container
# --push-container names the push container to compare against, if several stacks run on this box
#            (default: the one publishing the port of the Dovecot push URL, else the first found)
#
# Everything else is read-only. Docker containers are auto-detected (egroupware-docker setup),
# native installations are handled too.
#
# See https://github.com/EGroupware/egroupware/wiki/IMAP-Push-Notifications
#
# @package swoolepush
# @license http://opensource.org/licenses/gpl-license.php GPL - GNU General Public License

IMAP_USER=""
SIMULATE=0
PUSH_URL_OVERRIDE=""
TOKEN_OVERRIDE=""
PUSH_CONTAINER_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--simulate) SIMULATE=1;;
		--push-url) shift; PUSH_URL_OVERRIDE="$1";;
		--token) shift; TOKEN_OVERRIDE="$1";;
		--push-container) shift; PUSH_CONTAINER_OVERRIDE="$1";;
		-h|--help) sed -n '2,20p' "$0"; exit 0;;
		*) IMAP_USER="$1";;
	esac
	shift
done

if [ -t 1 ]; then
	RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BOLD=$'\e[1m'; NORM=$'\e[0m'
else
	RED=""; GREEN=""; YELLOW=""; BOLD=""; NORM=""
fi
declare -a SUMMARY=()
ok()   { echo "${GREEN}OK${NORM}   $*"; SUMMARY+=("OK   $*"); }
fail() { echo "${RED}FAIL${NORM} $*"; SUMMARY+=("FAIL $*"); }
warn() { echo "${YELLOW}WARN${NORM} $*"; SUMMARY+=("WARN $*"); }
info() { echo "     $*"; }
section() { echo; echo "${BOLD}== $* ==${NORM}"; }
evidence() { sed 's/^/     | /'; }

have() { command -v "$1" >/dev/null 2>&1; }

########################################################################
section "1. Locate components"
########################################################################

DOCKER=0
have docker && docker ps >/dev/null 2>&1 && DOCKER=1
PUSH_CONTAINER=""; EGW_CONTAINER=""; DOVECOT_CONTAINER=""
if [ $DOCKER = 1 ]; then
	# a container which has doveconf inside
	for c in $(docker ps --format '{{.Names}}'); do
		if docker exec "$c" sh -c 'command -v doveconf' >/dev/null 2>&1; then
			DOVECOT_CONTAINER=$c; break
		fi
	done
	PUSH_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -i push)
	PUSH_CONTAINER=$(echo "$PUSH_CONTAINERS" | head -1)
	if [ -n "$PUSH_CONTAINER_OVERRIDE" ]; then
		PUSH_CONTAINER=$PUSH_CONTAINER_OVERRIDE
		info "using push container $PUSH_CONTAINER from --push-container"
	elif [ "$(echo "$PUSH_CONTAINERS" | wc -l)" -gt 1 ]; then
		# several stacks on this box: prefer the container publishing the port Dovecot's push URL points to
		EARLY_URL=$PUSH_URL_OVERRIDE
		if [ -z "$EARLY_URL" ]; then
			if have doveconf; then EARLY_CONF=$(doveconf -P -n 2>/dev/null)
			elif [ -n "$DOVECOT_CONTAINER" ]; then EARLY_CONF=$(docker exec "$DOVECOT_CONTAINER" doveconf -P -n 2>/dev/null)
			else EARLY_CONF=""; fi
			EARLY_URL=$(echo "$EARLY_CONF" | sed -n 's/^ *push_lua_url *= *//p' | head -1)
			[ -z "$EARLY_URL" ] && EARLY_URL=$(echo "$EARLY_CONF" | sed -n 's/^ *push_notification_driver *= *ox:url=\([^ ]*\).*/\1/p' | head -1)
		fi
		EARLY_PORT=$(echo "$EARLY_URL" | sed -E 's#^[a-z]*://([^@/]*@)?##' | sed -nE 's#^[^/:]*:([0-9]+).*#\1#p')
		BY_PORT=""
		[ -n "$EARLY_PORT" ] && BY_PORT=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E ":$EARLY_PORT->" | cut -f1 | head -1)
		if [ -n "$BY_PORT" ]; then
			PUSH_CONTAINER=$BY_PORT
			ok "several push containers running, using $PUSH_CONTAINER as it publishes port $EARLY_PORT of the Dovecot push URL"
		else
			warn "several push containers running, using $PUSH_CONTAINER (pass --push-container NAME to use another one):"
		fi
		docker ps --format '{{.Names}}\t{{.Ports}}' | grep -i push | evidence
	fi
	# the egroupware container of the same stack (same name prefix), else the first one
	STACK=${PUSH_CONTAINER%%egroupware*}
	EGW_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE "^${STACK}egroupware$" | head -1)
	[ -z "$EGW_CONTAINER" ] && EGW_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE '^(egroupware|.*egroupware)$' | grep -viE 'push|nginx|db|mail|phpmyadmin|collabora|rocket' | head -1)
	info "docker: push=${PUSH_CONTAINER:-none} egroupware=${EGW_CONTAINER:-none} dovecot=${DOVECOT_CONTAINER:-none}"
else
	info "docker not available or not running --> assuming native installation"
fi

# how to run dovecot commands
if have doveconf; then
	dove() { "$@"; }
	ok "Dovecot found on host: $(dovecot --version 2>/dev/null)"
elif [ -n "$DOVECOT_CONTAINER" ]; then
	dove() { docker exec "$DOVECOT_CONTAINER" "$@"; }
	ok "Dovecot found in container $DOVECOT_CONTAINER: $(dove dovecot --version 2>/dev/null)"
else
	fail "No doveconf found on host nor in a running container: is Dovecot on this box? (Cyrus/other IMAP servers are not supported by this script)"
	dove() { return 127; }
fi

# run curl from where Dovecot runs (same network namespace matters for docker)
if [ -n "$DOVECOT_CONTAINER" ] && ! have doveconf; then
	if docker exec "$DOVECOT_CONTAINER" sh -c 'command -v curl' >/dev/null 2>&1; then
		dcurl() { docker exec "$DOVECOT_CONTAINER" curl "$@"; }
		info "curl runs inside container $DOVECOT_CONTAINER"
	else
		dcurl() { curl "$@"; }
		warn "No curl in $DOVECOT_CONTAINER, running curl on the host: DNS/network differences to the container are NOT detected"
	fi
else
	dcurl() { curl "$@"; }
fi
have curl || [ -n "$DOVECOT_CONTAINER" ] || fail "curl is not installed, HTTP checks will fail"

# bearer token of the push server
PUSH_TOKEN=""
if [ -n "$TOKEN_OVERRIDE" ]; then
	PUSH_TOKEN=$TOKEN_OVERRIDE
	info "using bearer token from --token"
else
	for f in /var/lib/egroupware-push/config.inc.php /var/lib/egroupware/push/config.inc.php /usr/share/egroupware/swoolepush/config.inc.php; do
		[ -r "$f" ] && PUSH_TOKEN=$(sed -n "s/.*bearer_token *= *'\([^']*\)'.*/\1/p" "$f") && [ -n "$PUSH_TOKEN" ] && info "bearer token read from $f" && break
	done
	if [ -z "$PUSH_TOKEN" ] && [ -n "$PUSH_CONTAINER" ]; then
		PUSH_TOKEN=$(docker exec "$PUSH_CONTAINER" cat /var/www/config.inc.php 2>/dev/null | sed -n "s/.*bearer_token *= *'\([^']*\)'.*/\1/p")
		[ -n "$PUSH_TOKEN" ] && info "bearer token read from container $PUSH_CONTAINER:/var/www/config.inc.php"
	fi
	if [ -z "$PUSH_TOKEN" ] && [ $DOCKER = 1 ]; then
		vol=$(docker volume ls -q | grep -i push-config | head -1)
		[ -n "$vol" ] && PUSH_TOKEN=$(docker run --rm -v "$vol":/mnt:ro busybox cat /mnt/config.inc.php 2>/dev/null | sed -n "s/.*bearer_token *= *'\([^']*\)'.*/\1/p")
		[ -n "$PUSH_TOKEN" ] && info "bearer token read from docker volume $vol"
	fi
fi
if [ -n "$PUSH_TOKEN" ]; then
	ok "push server bearer token: ${PUSH_TOKEN:0:4}...${PUSH_TOKEN: -2} (${#PUSH_TOKEN} chars)"
	case "$PUSH_TOKEN" in *[+/]*) warn "bearer token contains + or / which breaks URLs: replace them in config.inc.php (see wiki) and restart push + egroupware";; esac
else
	fail "Could not find the push server bearer token (docker exec -it egroupware-push cat /var/www/config.inc.php), pass it with --token"
fi
# the EGroupware side must use the same file/token
EGW_TOKEN=""
if [ -n "$EGW_CONTAINER" ]; then
	EGW_TOKEN=$(docker exec "$EGW_CONTAINER" sh -c 'cat /usr/share/egroupware/swoolepush/config.inc.php 2>/dev/null || cat /var/www/egroupware/swoolepush/config.inc.php 2>/dev/null' | sed -n "s/.*bearer_token *= *'\([^']*\)'.*/\1/p")
	if [ -n "$EGW_TOKEN" ] && [ -n "$PUSH_TOKEN" ]; then
		[ "$EGW_TOKEN" = "$PUSH_TOKEN" ] && ok "EGroupware container uses the same bearer token" || fail "EGroupware container ($EGW_CONTAINER) uses a DIFFERENT bearer token than the push server: the push-config volume is not shared"
	fi
fi

########################################################################
section "2. Dovecot version and push configuration"
########################################################################

DOVE_VERSION=$(dove dovecot --version 2>/dev/null | awk '{print $1}')
# -P is needed to show the token in push_lua_url, doveconf -n masks it as #hidden_use-P_to_show#
DOVE_CONF=$(dove doveconf -P -n 2>/dev/null)
if [ -z "$DOVE_CONF" ]; then
	fail "doveconf -n returned nothing: cannot check the Dovecot configuration, run this script where Dovecot runs"
else
	echo "$DOVE_CONF" | grep -E 'mail_plugins|push_notification|push_lua|mail_attribute_dict|imap_metadata|mail_lua|^protocol|^plugin' | sed 's#//Bearer:[^@]*@#//Bearer:***@#' | evidence
fi
# version comparison: 2.3.7 or newer supports lua + https + all events
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
if [ -n "$DOVE_VERSION" ]; then
	if ver_ge "$DOVE_VERSION" 2.3.7; then
		ok "Dovecot $DOVE_VERSION supports the Lua driver (all events, https)"
	elif ver_ge "$DOVE_VERSION" 2.2.0; then
		warn "Dovecot $DOVE_VERSION: only the OX driver is possible --> only new mails in INBOX and ONLY http:// URLs (no https)"
	else
		fail "Dovecot $DOVE_VERSION is too old for push notifications (need 2.2+)"
	fi
fi
DRIVER=$(echo "$DOVE_CONF" | sed -n 's/^ *push_notification_driver *= *//p' | head -1)
if [ -z "$DRIVER" ]; then
	fail "push_notification_driver is not set in Dovecot: Dovecot never calls the push server"
else
	ok "push_notification_driver = $DRIVER"
fi
if echo "$DOVE_CONF" | grep -qE '^ *imap_metadata *= *yes'; then
	ok "imap_metadata = yes"
else
	fail "imap_metadata = yes missing (protocol imap { imap_metadata = yes }): EGroupware cannot store the push token"
fi
if echo "$DOVE_CONF" | grep -qE '^ *mail_attribute_dict *= *.'; then
	ok "mail_attribute_dict = $(echo "$DOVE_CONF" | sed -n 's/^ *mail_attribute_dict *= *//p' | head -1)"
else
	fail "mail_attribute_dict is not set: METADATA (the push token) has nowhere to be stored"
fi
# the plugins must be active for the delivery protocol (lmtp/lda) not only for imap
PLUGINS_ALL=$(echo "$DOVE_CONF" | grep -E '^ *mail_plugins *=' | head -1)
PLUGINS_LMTP=$(echo "$DOVE_CONF" | awk '/^protocol lmtp/,/^}/' | grep mail_plugins)
PLUGINS_LDA=$(echo "$DOVE_CONF" | awk '/^protocol lda/,/^}/' | grep mail_plugins)
info "global: ${PLUGINS_ALL:-<none>}"
info "lmtp:   ${PLUGINS_LMTP:-<none>}"
info "lda:    ${PLUGINS_LDA:-<none>}"
PLUGINS_EFFECTIVE="$PLUGINS_ALL $PLUGINS_LMTP $PLUGINS_LDA"
for p in notify push_notification; do
	echo "$PLUGINS_EFFECTIVE" | grep -qw "$p" && ok "plugin $p enabled" || fail "plugin $p NOT in mail_plugins (global or protocol lmtp/lda)"
done
case "$DRIVER" in
	lua:*)
		for p in mail_lua push_notification_lua; do
			echo "$PLUGINS_EFFECTIVE" | grep -qw "$p" && ok "plugin $p enabled" || fail "plugin $p NOT in mail_plugins, required for the lua driver"
		done
		LUA_FILE=$(echo "$DRIVER" | sed -n 's/.*file=\([^ ]*\).*/\1/p')
		if dove test -r "$LUA_FILE" 2>/dev/null; then
			ok "lua script $LUA_FILE exists"
			dove grep -q 'dovecot_lua_notify_end_txn' "$LUA_FILE" 2>/dev/null || warn "$LUA_FILE does not look like doc/dovecot-push.lua"
		else
			fail "lua script $LUA_FILE not found where Dovecot runs"
		fi
		if dove sh -c 'ls /usr/lib/dovecot/modules/*lua* /usr/lib64/dovecot/modules/*lua* /usr/lib/dovecot/*lua* 2>/dev/null' | grep -q lua; then
			ok "dovecot lua plugins installed"
		else
			fail "no dovecot lua plugin files found: install dovecot-lua"
		fi
		if dove sh -c 'command -v lua >/dev/null 2>&1 || command -v lua5.3 >/dev/null 2>&1 || command -v lua5.4 >/dev/null 2>&1'; then
			if dove sh -c 'L=$(command -v lua || command -v lua5.3 || command -v lua5.4); $L -e "require \"socket.http\"; require \"json\"; require \"ltn12\""' >/dev/null 2>&1; then
				ok "lua modules socket.http, json and ltn12 load (lua-socket, lua-json)"
			else
				fail "lua cannot load socket.http / json / ltn12: install lua-socket and lua-json (for the same lua version Dovecot uses)"
			fi
		else
			warn "no lua interpreter found to test the modules, checking packages instead"
			dove sh -c 'dpkg -l lua-socket lua-json 2>/dev/null | grep ^ii || rpm -q lua-socket lua-json 2>/dev/null' | evidence
		fi
		PUSH_URL=$(echo "$DOVE_CONF" | sed -n 's/^ *push_lua_url *= *//p' | head -1)
		[ -n "$PUSH_URL" ] && ok "push_lua_url = $(echo "$PUSH_URL" | sed 's#//Bearer:[^@]*@#//Bearer:***@#')" || fail "push_lua_url is not set in plugin {}"
		;;
	ox:*)
		PUSH_URL=$(echo "$DRIVER" | sed -n 's/^ox:url=\([^ ]*\).*/\1/p')
		echo "$DRIVER" | grep -q user_from_metadata && ok "ox driver uses user_from_metadata" || fail "ox driver needs 'user_from_metadata', otherwise the user field does not contain EGroupware's token"
		[ -n "$PUSH_URL" ] && ok "ox url = $(echo "$PUSH_URL" | sed 's#//Bearer:[^@]*@#//Bearer:***@#')" || fail "no url= in the ox driver"
		case "$PUSH_URL" in https://*) fail "ox driver (Dovecot 2.2 style) can NOT do https: use http://<internal-ip-or-host>/egroupware/push and let the proxy forward it, see help.egroupware.org/t/push-geht-nicht/75630";; esac
		;;
	"") PUSH_URL="";;
	*) warn "unknown push_notification_driver '$DRIVER'"; PUSH_URL="";;
esac
[ -n "$PUSH_URL_OVERRIDE" ] && PUSH_URL=$PUSH_URL_OVERRIDE && info "using --push-url instead"

########################################################################
section "3. Push URL sanity (from where Dovecot runs)"
########################################################################

URL_TOKEN=""; URL_HOST=""; URL_NOAUTH=""
if [ -n "$PUSH_URL" ]; then
	URL_TOKEN=$(echo "$PUSH_URL" | sed -n 's#^[a-z]*://Bearer:\([^@]*\)@.*#\1#p')
	URL_HOST=$(echo "$PUSH_URL" | sed -E 's#^[a-z]*://([^@/]*@)?([^/:]*).*#\2#')
	URL_NOAUTH=$(echo "$PUSH_URL" | sed -E 's#^([a-z]*://)[^@/]*@#\1#')
	if [ -z "$URL_TOKEN" ]; then
		fail "URL has no 'Bearer:<token>@' user-info part: the push server will answer 401"
	elif [ -n "$PUSH_TOKEN" ] && [ "$URL_TOKEN" != "$PUSH_TOKEN" ]; then
		fail "token in Dovecot URL (${URL_TOKEN:0:4}...) differs from the push server token (${PUSH_TOKEN:0:4}...)"
	else
		ok "token in URL matches push server token"
	fi
	case "$URL_NOAUTH" in */egroupware/push|*/push) ok "URL path ends with /push";; *) warn "URL path is not .../push: must be the same path the browser uses for its websocket (EGroupware base URL + /push)";; esac
	if dove getent hosts "$URL_HOST" >/dev/null 2>&1 || dcurl -s -o /dev/null --connect-timeout 3 "$URL_NOAUTH" 2>/dev/null || [ "$URL_HOST" != "${URL_HOST#[0-9]}" ]; then
		ok "host $URL_HOST resolves/connects from Dovecot's context: $(dove getent hosts "$URL_HOST" 2>/dev/null | head -1)"
	else
		fail "host $URL_HOST does not resolve where Dovecot runs (container DNS? add extra_hosts / --add-host)"
	fi
	URL_PORT=$(echo "$URL_NOAUTH" | sed -nE 's#^[a-z]*://[^/:]*:([0-9]+).*#\1#p')
	if [ -n "$URL_PORT" ] && [ $DOCKER = 1 ]; then
		BY_PORT=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E ":$URL_PORT->" | cut -f1 | head -1)
		if [ -n "$BY_PORT" ] && [ "$BY_PORT" != "$PUSH_CONTAINER" ]; then
			warn "port $URL_PORT of the Dovecot URL is published by container $BY_PORT, not by $PUSH_CONTAINER: its token is $(docker exec "$BY_PORT" cat /var/www/config.inc.php 2>/dev/null | sed -n "s/.*bearer_token *= *'\([^']*\)'.*/\1/p" | sed -E 's/^(....).*(..)$/\1...\2/')"
		elif [ -n "$BY_PORT" ]; then
			ok "port $URL_PORT is published by $PUSH_CONTAINER"
		fi
	fi
	TESTTOKEN=${URL_TOKEN:-$PUSH_TOKEN}
	RESP=$(dcurl -sS -i --connect-timeout 5 --max-time 10 -u "Bearer:$TESTTOKEN" "$URL_NOAUTH?token=x" 2>&1)
	STATUS=$(echo "$RESP" | head -1 | tr -d '\r')
	echo "$RESP" | head -12 | evidence
	case "$STATUS" in
		*" 200"*) ok "push server answers GET with 200 (Basic auth accepted, proxy forwards /push)";;
		*" 401"*) fail "401 from push server: wrong bearer token in URL";;
		*" 502"*|*" 503"*|*" 504"*) fail "$STATUS: the proxy cannot reach the push container (port 9501)";;
		*" 404"*|*" 30"[0-9]*) fail "$STATUS: /push is NOT proxied to the push server (it hits the PHP app or a redirect), fix the nginx/apache location for /egroupware/push";;
		"") fail "no answer from $URL_NOAUTH (connection refused / timeout / TLS error): $(echo "$RESP" | tail -1)";;
		*) warn "unexpected answer: $STATUS";;
	esac
else
	fail "no push URL to test"
fi

########################################################################
section "4. METADATA push token of the IMAP user"
########################################################################

META=""
if [ -z "$IMAP_USER" ]; then
	warn "no imap-user given: pass the IMAP login (e.g. user@example.org) as first argument to check the registered push token"
else
	# 2.3 wants -s for the server (empty mailbox) attribute, older versions the plain form
	META=$(dove doveadm mailbox metadata get -u "$IMAP_USER" -s "" /private/vendor/vendor.dovecot/http-notify 2>&1)
	if ! echo "$META" | grep -q '^user='; then
		META2=$(dove doveadm mailbox metadata get -u "$IMAP_USER" "" /private/vendor/vendor.dovecot/http-notify 2>&1)
		echo "$META2" | grep -q '^user=' && META=$META2
	fi
	if echo "$META" | grep -q '^user='; then
		ok "METADATA /private/vendor/vendor.dovecot/http-notify for $IMAP_USER:"
		echo "$META" | tr ';' '\n' | sed '/^;*$/d' | evidence
		HOSTS_IN_META=$(echo "$META" | grep -oE '@[^;]+' | tr -d '@' | sort -u)
		for h in $HOSTS_IN_META; do
			info "token registered for EGroupware host: $h"
		done
		echo "$META" | grep -qE 'user=[0-9]+::[0-9]+;[0-9a-f]{40}@' || fail "METADATA value does not look like '<account_id>::<acc_id>;<sha1-token>@<host>'"
	else
		fail "no push token registered for $IMAP_USER (empty/invalid METADATA): the user must open the Mail app in a browser once (it is registered by mail_ui::get_rows), and the IMAP host:port must be listed in Admin > Applications > Mail > Site configuration > Push"
		[ -n "$META" ] && echo "$META" | evidence
	fi
fi

########################################################################
section "5. Recent log lines"
########################################################################

if [ -n "$PUSH_CONTAINER" ]; then
	info "push server ($PUSH_CONTAINER) last 200 lines filtered:"
	docker logs --tail 200 "$PUSH_CONTAINER" 2>&1 | grep -E 'Pushed for|Invalid request|Bearer|Can NOT parse|Invalid JSON|Returned for instance' | tail -15 | evidence
	if docker logs --tail 200 "$PUSH_CONTAINER" 2>&1 | grep -q '"app":"mail"'; then
		ok "push server has recently pushed mail events (Dovecot --> push server works, at least sometimes)"
	else
		warn "no mail events in the last 200 push server log lines"
	fi
elif [ -n "$(pgrep -f 'server.php' 2>/dev/null)" ]; then
	info "native push server process found: $(pgrep -af server.php | head -1)"
fi
DOVE_LOG=""
if [ -n "$DOVECOT_CONTAINER" ] && ! have doveconf; then
	DOVE_LOG=$(docker logs --tail 500 "$DOVECOT_CONTAINER" 2>&1)
elif have journalctl; then
	DOVE_LOG=$(journalctl -u dovecot --since "-2 hours" --no-pager 2>/dev/null)
fi
for f in /var/log/mail.log /var/log/maillog /var/log/dovecot.log /var/log/dovecot-info.log; do
	[ -r "$f" ] && DOVE_LOG="$DOVE_LOG
$(tail -n 500 "$f")"
done
if [ -n "$DOVE_LOG" ]; then
	info "Dovecot log lines about push/lua/notify:"
	echo "$DOVE_LOG" | grep -iE 'push|lua|notify|metadata' | tail -15 | evidence
	echo "$DOVE_LOG" | grep -q 'Mail notify status 2' && ok "Dovecot logged successful pushes ('Mail notify status 2xx')"
	echo "$DOVE_LOG" | grep -qiE 'lua.*(error|fail)|push_notification.*(error|fail)' && fail "Dovecot logged push/lua errors, see above"
else
	warn "no Dovecot log found (journalctl -u dovecot, /var/log/mail.log)"
fi

########################################################################
section "6. Simulated Dovecot push"
########################################################################

if [ $SIMULATE = 1 ]; then
	if ! echo "$META" | grep -q '^user='; then
		fail "cannot simulate without a registered METADATA token (see section 4)"
	elif [ -z "$URL_NOAUTH" ]; then
		fail "cannot simulate without a push URL"
	else
		USERFIELD=${META#user=}
		BODY=$(printf '{"user":"%s","imap-uidvalidity":1,"imap-uid":1,"folder":"INBOX","event":"MessageNew","from":"push-test@%s","subject":"Simulated IMAP push from check-dovecot-push.sh","snippet":"%s","unseen":1,"messages":1}' \
			"$USERFIELD" "$(hostname -f 2>/dev/null || hostname)" "$(date '+%Y-%m-%d %H:%M:%S')")
		info "PUT $URL_NOAUTH"
		echo "$BODY" | evidence
		RESP=$(dcurl -sS -i --connect-timeout 5 --max-time 10 -u "Bearer:${URL_TOKEN:-$PUSH_TOKEN}" -X PUT -H 'Content-Type: application/json; charset=utf-8' --data "$BODY" "$URL_NOAUTH" 2>&1)
		echo "$RESP" | evidence
		N=$(echo "$RESP" | grep -oE '^[0-9]+ subscribers' | head -1 | awk '{print $1}')
		if [ -n "$N" ] && [ "$N" -gt 0 ]; then
			ok "$N subscriber(s) notified: the user should now see 'New mail from push-test' in the browser. Dovecot --> push server --> browser is fine, so if real mails do not push, Dovecot does not send them (plugins/driver/log, sections 2 and 5)"
		elif [ "$N" = 0 ]; then
			fail "push server accepted the request but no browser is subscribed to that user token: is $IMAP_USER logged into EGroupware in a browser? Token is rotated daily, reload the browser and open Mail once, then rerun"
		else
			fail "push server did not accept the simulated push, see response above"
		fi
	fi
else
	info "skipped, rerun with --simulate to send one fake MessageNew for $IMAP_USER"
fi

########################################################################
section "Summary"
########################################################################
for line in "${SUMMARY[@]}"; do
	case "$line" in
		OK*) echo "${GREEN}${line}${NORM}";;
		FAIL*) echo "${RED}${line}${NORM}";;
		*) echo "${YELLOW}${line}${NORM}";;
	esac
done

if [ -n "$DOVE_VERSION" ]; then
	echo
	echo "${BOLD}Reference configuration for Dovecot $DOVE_VERSION (wiki: IMAP-Push-Notifications):${NORM}"
	if ver_ge "$DOVE_VERSION" 2.3.7; then
		cat <<'EOF'
# /etc/dovecot/conf.d/14-egroupware-push.conf  (must sort BEFORE 15-lda.conf and 20-lmtp.conf)
mail_attribute_dict = file:%h/dovecot-metadata
protocol imap {
  imap_metadata = yes
}
mail_plugins = $mail_plugins mail_lua notify push_notification push_notification_lua
plugin {
  push_notification_driver = lua:file=/etc/dovecot/dovecot-push.lua
  push_lua_url = https://Bearer:<push-token>@<egroupware-domain>/egroupware/push
}
# apt install dovecot-lua lua-socket lua-json
# curl https://raw.githubusercontent.com/EGroupware/swoolepush/master/doc/dovecot-push.lua > /etc/dovecot/dovecot-push.lua
# systemctl restart dovecot
EOF
	else
		cat <<'EOF'
# /etc/dovecot/conf.d/99-egroupware-push.conf  (Dovecot 2.2: INBOX only, http only!)
mail_attribute_dict = file:%h/dovecot-metadata
protocol imap {
  imap_metadata = yes
}
protocol lmtp {
  mail_plugins = $mail_plugins notify push_notification
}
plugin {
  push_notification_driver = ox:url=http://Bearer:<push-token>@<egroupware-domain-or-docker-ip>/egroupware/push user_from_metadata
}
# systemctl restart dovecot
EOF
	fi
fi
