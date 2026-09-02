<?php
/**
 * Testing Push Server for EGroupware using PHP Swoole extension
 *
 * To use on commandline:
 * docker exec -it egroupware bash
 * HTTP_HOST=example.org php /usr/share/egroupware/swoolepush/test.php [--all] [--simulate]
 *
 * Please note:
 * - backoff-time and failed-attempts are stored in APCu / shared memory and
 *   therefore are NOT the same for web-usage and command-line!
 * - for command-line the host need to be specified as shown above for the test to succeed!
 *
 * What is tested:
 * 1. PHP --> push server: onlyFallback(), failed attempts / backoff and online users
 * 2. push server --> browser: a message is pushed to the current session, the push server reports
 *    how many websocket subscribers got it (deterministic) and the browser shows a green message
 * 3. IMAP push: for each mail account of the current user, if the IMAP server is configured for push
 *    and if a push token is registered as METADATA on the IMAP server, plus an optional
 *    "Simulate IMAP push" doing exactly the request Dovecot's push_notification plugin does
 *
 * @link https://www.egroupware.org
 * @author Ralf Becker <rb-At-egroupware.org>
 * @package swoolepush
 * @copyright (c) 2020 by Ralf Becker <rb-At-egroupware.org>
 * @license http://opensource.org/licenses/gpl-license.php GPL - GNU General Public License
 */
use EGroupware\Api;
use EGroupware\Api\Json\Push;
use EGroupware\SwoolePush\Backend;
use EGroupware\SwoolePush\Tokens;

// timeout in seconds for IMAP connections in the test
const IMAP_TIMEOUT = 5;

$GLOBALS['egw_info'] = [
	'flags' => [
		'currentapp' => PHP_SAPI !== 'cli' ? 'admin' : 'login',
		'noheader' => true,
	]
];

require_once __DIR__.'/../header.inc.php';

// this is a diagnostic page for admins: show errors instead of a truncated page
ini_set('display_errors', '1');
error_reporting(E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED);

if (PHP_SAPI !== 'cli')
{
	// Random per-request token, round-tripped through the actual push, so the client can tell a
	// real push for THIS test apart from a stale one arriving late from a previous run - avoids
	// assuming a fixed ordering between this synchronous response and the async push, which used
	// to be safe (push always arrived after the response) but is no longer deterministic.
	// pushTestStart() arms a client-side timeout, only showing the failure message if no
	// matching-token push arrives within it - no separate "checking..." message, only ever one
	// of the two final (success/failure) messages is shown, egw.message() replaces any prior one.
	// Framework::set_extra() is for real (non-AJAX/JSON) requests like this one - it's embedded
	// as a data-app-call attribute on egw's own script tag and executed by egw.js once the
	// framework (incl. the app object) is ready, same mechanism as eg. Framework::message()'s
	// data-message. Targets window.top explicitly (egw.js's data-app-call reader does too): this
	// page (Admin > Test Push) is normally loaded inside an iframe within the admin app, and that
	// iframe never instantiates its own app objects - only the top window does, which is also the
	// only place the actual push WebSocket connection lives, matching where the push-delivered
	// pushTestMessage() call always lands.
	$push_test_token = bin2hex(random_bytes(8));
	Api\Framework::set_extra('app', 'call', [
		'app' => 'admin',
		'method' => 'pushTestStart',
		'args' => [$push_test_token, 2000, lang('Push server is NOT working')],
	]);

	echo $egw->framework->header();
	echo "<pre>\n";
	$success_start = "<span style='color: green; font-weight: bold'>";
	$failure_start = "<span style='color: red; font-weight: bold'>";
	$end = '</span>';
}
else
{
	echo "\n";
	$success_start = $failure_start = $end = '';
}

/**
 * Format a result green or red
 *
 * @param bool $success
 * @param string $text
 * @return string
 */
function push_result($success, $text)
{
	global $success_start, $failure_start, $end;
	return ($success ? $success_start : $failure_start).$text.$end;
}

function check_push($ignore_cache=false)
{
	$only_fallback = Push::onlyFallback($ignore_cache);
	$result = push_result(!$only_fallback, $only_fallback ?
		lang('Using fallback via regular JSON requests') : lang('Using native Swoole Push'));
	echo "Push::onlyFallback()=".json_encode($only_fallback).' --> '.$result."\n\n";
	echo "SwoolePush\Backend::failedAttempts()=".Backend::failedAttempts().", SwoolePush\Backend::backoffTime=".Backend::backoffTime();
}

check_push();

if (Backend::failedAttempts() > Backend::MAX_FAILED_ATTEMPTS)
{
	if (empty($_POST['reset']) && PHP_SAPI !== 'cli')
	{
		echo " <form style='display:inline-block; margin:0' method='post'><input type='submit' name='reset' value='Reset' class='padding: 5px'/></form>\n";
	}
	else
	{
		echo "\nresetting to SwoolePush\Backend::failedAttempts()=".Backend::failedAttempts(-2*Backend::MAX_FAILED_ATTEMPTS).
			" and SwoolePush\Backend::backoffTime()=".Backend::backoffTime()."seconds\n";
	}
}
else echo "\n";
echo "\n";

echo "SwoolePush\Backend->online()=";
try {
	echo json_encode(array_map(function($account_id) {
			return Api\Accounts::id2name($account_id);
		},(new Backend())->online()))."\n\n";

	if (PHP_SAPI !== 'cli')
	{
		// the push server tells us how many websocket connections are subscribed to our session-token,
		// which does NOT depend on the client-side round-trip test above
		$response = (new Backend())->addGeneric(Push::SESSION, 'apply', [
			'func' => 'app.admin.pushTestMessage',
			'parms' => [$push_test_token, lang('Push server is working')],
		]);
		$subscribers = $response !== false && preg_match('/^(\d+) subscribers?/', $response, $matches) ? (int)$matches[1] : 0;
		echo "SwoolePush\Backend->addGeneric(session-token ".substr(Tokens::session(), 0, 8)."...)=".
			push_result($subscribers > 0, $response === false ? lang('Push server not reachable or returned an error!') : trim($response)).
			(!$subscribers && $response !== false ?
				"\n".push_result(false, lang('Push server reachable, but NO websocket connection subscribed to this session: push tokens rotate daily, so reload the browser first, then check the websocket proxy for %1 and the browser console!', Api\Framework::link('/push'))) : '').
			"\n\n";
	}
}
catch (Exception $e) {
	echo push_result(false, $e->getMessage())."\n";
}

check_push(true);

echo "\n\nPush->online()=".json_encode(array_map(function($account_id) {
	return Api\Accounts::id2name($account_id);
},(new Push())->online()))."\n\n";

/**
 * Check the IMAP push configuration for mail accounts of the current user
 *
 * By default only the default account is checked, as every account requires an IMAP connection
 * (with a short timeout of IMAP_TIMEOUT seconds), which can take a while with many accounts.
 *
 * @param ?int $simulate_acc_id acc_id to send a simulated Dovecot push for
 * @param bool $all_accounts false: check only the default account, true: all accounts of the user
 */
function check_imap_push($simulate_acc_id=null, $all_accounts=false)
{
	echo "\n".push_result(true, "IMAP push")."\n\n";

	$config = Api\Config::read('mail');
	$hosts_with_push = $GLOBALS['egw_info']['server']['imap_hosts_with_push'] ?? [];
	if (!is_array($hosts_with_push)) $hosts_with_push = preg_split('/[, ]+/', $hosts_with_push);
	foreach(!empty($config['imap_hosts_with_push']) ? preg_split('/[, ]+/', $config['imap_hosts_with_push']) : [] as $host)
	{
		$hosts_with_push[] = $host;
	}
	$hosts_with_push = array_values(array_filter($hosts_with_push));
	echo "Mail site-configuration 'imap_hosts_with_push' (Admin > Applications > Mail > Site configuration)=".
		push_result((bool)$hosts_with_push, json_encode($hosts_with_push) ?: '[]').
		(!$hosts_with_push ? "\n".push_result(false, lang('No IMAP server configured for push --> no push for mail!')) : '')."\n\n";

	if (empty($GLOBALS['egw_info']['user']['apps']['mail']))
	{
		echo push_result(false, lang('Mail is not enabled for the current user!'))."\n";
		return;
	}
	$found = false;
	$default_acc_id = Api\Mail\Account::get_default_acc_id();
	// search() returns an iterator
	$accounts = iterator_to_array(Api\Mail\Account::search(true, 'acc_name'));
	if (!$all_accounts)
	{
		$all = $accounts;
		$accounts = $default_acc_id ? [$default_acc_id => $all[$default_acc_id] ?? "#$default_acc_id"] : [];
		echo lang('Checking only the default mail account (%1 accounts in total).', count($all));
		if (PHP_SAPI !== 'cli')
		{
			echo " <form style='display:inline-block; margin:0' method='post'><input type='submit' name='all_accounts' value='".lang('Check all mail accounts')."' style='padding: 5px'/></form>";
		}
		else
		{
			echo ' '.lang('Use --all to check all accounts.');
		}
		echo "\n\n";
	}
	// every account needs an IMAP connection, up to IMAP_TIMEOUT seconds each
	@set_time_limit(30 + 2 * IMAP_TIMEOUT * count($accounts));
	foreach($accounts as $acc_id => $acc_name)
	{
		$found = true;
		echo "Account #$acc_id '".$acc_name."' ";
		flush();	// show progress, if the webserver does not buffer
		try {
			// read() (unlike search()) also reads the credentials
			$account = Api\Mail\Account::read($acc_id);
			if (empty($account->acc_imap_host))
			{
				echo lang('no IMAP server')."\n\n";
				continue;
			}
			echo "IMAP ".$account->acc_imap_host.':'.$account->acc_imap_port.": ";
			$imap = $account->imapServer(false, IMAP_TIMEOUT);
			if (!($imap instanceof Api\Mail\Imap\PushIface))
			{
				echo push_result(false, get_class($imap).' '.lang('does not support push'))."\n";
				continue;
			}
			$available = $imap->pushAvailable();
			echo "pushAvailable()=".push_result($available, json_encode($available).' '.
				($available ? '' : lang('(host or host:port not in imap_hosts_with_push)')))."\n";
			if (!$available || !($imap instanceof Api\Mail\Imap))
			{
				continue;
			}
			// (re-)register our token like mail_ui::get_rows does and show what the IMAP server has stored
			$enabled = $imap->enablePush(null, $acc_id.'::INBOX');
			echo "\tenablePush()=".push_result($enabled, json_encode($enabled))."\n";
			$metadata = $imap->getMetadata(Api\Mail\Imap::METADATA_MAILBOX, [Api\Mail\Imap::METADATA_NAME])[Api\Mail\Imap::METADATA_MAILBOX][Api\Mail\Imap::METADATA_NAME] ?? null;
			$my_token_preg = '/^'.$GLOBALS['egw_info']['user']['account_id'].'::'.$acc_id.';[^@]+@(.*)$/';
			$my_token = null;
			$host_ok = null;
			foreach($metadata ? explode(Api\Mail\Imap::METADATA_SEPARATOR, substr($metadata, strlen(Api\Mail\Imap::METADATA_PREFIX))) : [] as $token)
			{
				if (preg_match($my_token_preg, $token, $matches))
				{
					$my_token = $token;
					$host_ok = $matches[1] === Api\Header\Http::host();
					break;
				}
			}
			echo "\tMETADATA ".Api\Mail\Imap::METADATA_NAME."=".push_result(!empty($my_token), $metadata ?: 'NULL')."\n";
			if (empty($my_token))
			{
				echo "\t".push_result(false, lang('No push token for the current user registered on the IMAP server!'))."\n";
				continue;
			}
			if (!$host_ok)
			{
				echo "\t".push_result(false, lang('Host in registered token %1 does NOT match current host %2!', $matches[1], Api\Header\Http::host()))."\n";
			}
			$url = (new Backend())->url();
			echo "\tDovecot needs to PUT to ".push_result(true, $url).
				" with Basic auth 'Bearer:<bearer-token>' (see ".dirname(__FILE__)."/doc/dovecot-push.lua)\n";

			if (PHP_SAPI !== 'cli' && (int)$simulate_acc_id !== (int)$acc_id)
			{
				echo "\t<form style='display:inline-block; margin:0' method='post'><input type='submit' name='simulate_imap' value='Simulate IMAP push for account #$acc_id' style='padding: 5px'/><input type='hidden' name='acc_id' value='$acc_id'/></form>\n";
			}
			elseif (PHP_SAPI !== 'cli' || (int)$simulate_acc_id === (int)$acc_id)
			{
				// send exactly what doc/dovecot-push.lua sends for a new message in the INBOX
				$data = [
					'user' => substr($metadata, strlen(Api\Mail\Imap::METADATA_PREFIX)),
					'imap-uidvalidity' => 1,
					'imap-uid' => 1,
					'folder' => 'INBOX',
					'event' => 'MessageNew',
					'from' => 'push-test@'.Api\Header\Http::host(),
					'subject' => 'Simulated IMAP push from '.__FILE__,
					'snippet' => date('Y-m-d H:i:s'),
					'unseen' => 1,
					'messages' => 1,
				];
				$status = null;
				$response = (new Backend())->imapPush($data, $status);
				$subscribers = $response !== false && preg_match('/^(\d+) subscribers?/', $response, $matches) ? (int)$matches[1] : 0;
				echo "\tSimulated Dovecot PUT ".json_encode($data)."\n\t--> ".
					push_result($subscribers > 0, ($status ?: '').' '.($response !== false ? $response : ''))."\n";
				if (!$subscribers)
				{
					echo "\t".push_result(false, $response === false ?
						lang('Push server did not accept the request: check the URL, the Bearer token and the proxy configuration!') :
						lang('Push server accepted the request, but found no browser subscribed to the user token: reload the browser and try again!'))."\n";
				}
				else
				{
					echo "\t".push_result(true, lang('Push server and EGroupware are working, if you see no "New mail from" notification in the browser now, check the mail notification preference.')).
						"\n\t".lang('If this works but real mails do not push, the problem is between Dovecot and the push server: run doc/check-dovecot-push.sh on the mail server.')."\n";
				}
			}
		}
		catch (\Throwable $e) {
			echo push_result(false, get_class($e).': '.$e->getMessage())."\n";
		}
		echo "\n";
	}
	if (!$found)
	{
		echo push_result(false, lang('No mail account found for the current user!'))."\n";
	}
}

check_imap_push(!empty($_POST['simulate_imap']) ? (int)$_POST['acc_id'] : (PHP_SAPI === 'cli' && in_array('--simulate', $argv) ? Api\Mail\Account::get_default_acc_id() : null),
	!empty($_POST['all_accounts']) || PHP_SAPI === 'cli' && in_array('--all', $argv));

if (PHP_SAPI !== 'cli')
{
	echo "\n<form style='display:inline-block; margin:0'><input type='submit' value='Retry' style='padding: 5px'/></form>\n";
}
