<?php
/**
 * Readonly non-blocking sessions for Swoole
 *
 * @link https://www.egroupware.org
 * @author Ralf Becker <rb-At-egroupware.org>
 * @package swoolpush
 * @copyright (c) 2019-24 by Ralf Becker <rb-At-egroupware.org>
 * @license http://opensource.org/licenses/gpl-license.php GPL - GNU General Public License
 */

namespace EGroupware\SwoolePush\Session;

use EasySwoole\Memcache\Config;
use EasySwoole\MemcachePool\MemcachePool;
use EasySwoole\Memcache\Memcache;

/**
 * Readonly non-blocking sessions for Swoole
 */
class Memcached implements Backend
{
	protected $id;
	/**
	 * @var Config[]
	 */
	protected static $memcached;
	protected static $save_path;
	/**
	 * Timestamp of the last successful call to each backend, keyed by host_port
	 *
	 * @var int[]
	 */
	protected static $last_success = [];
	/**
	 * How long a single backend may stay unreachable before we give up and exit, to force
	 * a restart (eg. by Kubernetes) and thus a guaranteed fresh reconnect / DNS resolution.
	 *
	 * A single dead backend, while others stay healthy, is NOT detected by the reconnect
	 * logic below (that only triggers when ALL backends fail for the very same lookup), so
	 * without this, sessions sharded onto the dead backend just keep silently failing as
	 * "unknown session" forever, eg. after a Kubernetes node-rebuild that recreates the push
	 * pod and the memcached pods in an unpredictable order.
	 */
	const BACKEND_DOWN_TIMEOUT = 60;

	/**
	 * Constructor
	 *
	 * @param string $id
	 * @param string $path =null "server1[:11211][,server2[:11211]]"
	 * @throws \RuntimeException
	 */
	function __construct($id, $path=null, $reconnect=false)
	{
		$this->id = $id;

		if (!isset(self::$memcached) || $reconnect)
		{
			foreach(explode(',', self::$save_path = $path ?? ini_get('session.save_path')) as $host_port)
			{
				// MemcachePool is a singleton for the whole worker process and has NO way to unregister
				// a pool: registering the same $host_port a 2nd time (eg. on reconnect) always throws
				// PoolException "is already been register", crashing the whole push-server uncaught!
				// --> reuse the already registered pool instead of re-registering it
				if (($pool = MemcachePool::getInstance()->getPool($host_port)))
				{
					self::$memcached[$host_port] = $pool->getConfig();
					continue;
				}
				list ($host, $port) = explode(':', $host_port);
				$config = new Config([
					'host' => $host,
					'port' => $port ?? 11211,
				]);
				self::$memcached[$host_port] = MemcachePool::getInstance()->register($config, $host_port);
				// EasySwoole\Pool\Config defaults maxObjectNum to just 20, far too small for a burst
				// of concurrent handshakes (eg. after a mass client reconnect): a burst exceeding it
				// makes initObject() fail exactly like a real connection failure, up to triggering a
				// reconnect --> raise it well above the expected concurrent push-client count
				self::$memcached[$host_port]->setMaxObjectNum(256);
				self::$last_success[$host_port] ??= time();
			}
		}
	}

	/**
	 * Check if given session exists
	 *
	 * @return bool
	 * @throws \Exception on failed connection AFTER reconnect
	 */
	public function exists()
	{
		try {
			return $this->open() !== null;
		}
		catch(\RuntimeException $e) {
			error_log(__METHOD__."() ".$e->getMessage());
			return false;
		}
	}

	/**
	 * Open session readonly and return its values
	 *
	 * @param bool $try_reconnect
	 * @return array
	 * @throws \RuntimeException if session is not found
	 * @throws \Exception on failed connection AFTER reconnect, or session_open() returns false
	 */
	public function open(bool $try_reconnect=true)
	{
		if (session_status() !== PHP_SESSION_ACTIVE)
		{
			if (!session_start())
			{
				throw new \Exception('session_start() failed');
			}
		}
		$_SESSION = [];	// session_decode does NOT clear it

		$key = $this->key();
		$exceptions = [];
		foreach(self::$memcached as $host_port => $memcached)
		{
			try {
				$data = MemcachePool::invoke(static function (Memcache $memcache) use ($key) {
					return $memcache->get($key);
				}, $host_port);
				//var_dump("memcached->get('$key')=", $data);
				self::$last_success[$host_port] = time();
				if ($data !== null) break;
			}
			catch (\Exception $e) {
				$exceptions[$host_port] = $e;
				error_log(__METHOD__."('$key', $try_reconnect) ".$e->getMessage());
				// this single backend might be down while others stay fine, in which case the
				// "all backends failed" check below never triggers: without this, sessions
				// sharded onto it would silently keep failing as "unknown session" forever
				// --> force a restart once it's been down for too long
				$down_for = time() - (self::$last_success[$host_port] ?? time());
				if ($down_for > self::BACKEND_DOWN_TIMEOUT)
				{
					error_log(__METHOD__."('$key') FATAL: memcached backend '$host_port' unreachable for {$down_for}s (> ".
						self::BACKEND_DOWN_TIMEOUT."s), last error: ".$e->getMessage().' --> exiting to force a restart/reconnect');
					exit(1);
				}
				continue;
			}
		}
		// if all memcached gave an exception (not finding the session/key does NOT!)
		if (isset($e) && count($exceptions) === count(self::$memcached))
		{
			if ($try_reconnect)
			{
				error_log(__METHOD__."('$key', $try_reconnect) trying to reconnect now");
				self::$memcached = null;
				self::__construct($this->id, self::$save_path, true);
				return $this->open(false);
			}
			// throw our original (connection-failed) exception
			throw $e;
		}
		if (!$data || !session_decode($data))
		{
			throw new \RuntimeException("Could not open session $this->id!");
		}
		return $_SESSION;
	}

	/**
	 * Get the key used for the session
	 */
	protected function key()
	{
		return (ini_get('memcached.sess_prefix') ?: 'memc.sess.key.').$this->id;
	}
}