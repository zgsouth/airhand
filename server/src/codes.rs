//! Fixed control codes: authoritative in-memory index plus a dedicated SQLite
//! writer. Broker locks never cover disk I/O. Writes are coalesced per code (the
//! namespace has 900,000 entries), retried on failure, and drained on shutdown.
//! A disk error never makes an existing binding appear unowned.
//!
//! 持久化屏障按**写入序号**等待（[`Bindings::barrier`]）：只等到调用之前排进来的那些写入落盘，
//! 之后别人的写入不算。之前的做法是等到"没有待写的数据"，持续有注册时可能一直等不到。
//! 等待是异步的（tokio 的 watch），不占阻塞线程。
//!
//! 数据库里还存着服务器自己的密钥（[`Bindings::server_key`]，用来给发出去的控制码密钥签名，见 broker）：
//! 和绑定表放在一起，服务器重启之后还认得以前发的密钥。
//!
//! 被控端放弃了的控制码（更换控制码）不是删掉就算了，而是**作废**（[`Bindings::retire`]），记在 `retired_codes` 表里
//! （控制码和作废的时间）：谁的密钥都不认，[`RETIRED_HOLD`] 之内也不分给别人；之后可以分给新的被控端（作废的记录随之去掉），
//! 没分出去的旧密钥照样不认，[`BINDING_TTL`] 之后清理。同一个控制码不会既绑定着、又作废了。
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::watch;
use tracing::{info, warn};

pub const BINDING_TTL: Duration = Duration::from_secs(180 * 24 * 3600);
/// 作废了的控制码（[`Bindings::retire`]）多久之内不分给别人
pub const RETIRED_HOLD: Duration = Duration::from_secs(7 * 24 * 3600);
const SCHEMA_VERSION: i64 = 3;

/// 绑定（`fixed_codes` 表的一行）：控制码绑定给了持有某个密钥的被控端
#[derive(Clone)]
struct Binding {
    /// 现在的密钥的哈希
    hash: Vec<u8>,
    /// 换过密钥、但还没确认被控端已经保存了新密钥时，旧密钥的哈希（见 [`Owner::Previous`]）
    prev: Option<Vec<u8>>,
    last_seen: i64,
}

/// 一个控制码在数据库里的样子（写入队列按控制码合并，只写最新的）
#[derive(Clone)]
enum Row {
    /// 绑定着（`fixed_codes` 表）
    Bound(Binding),
    /// 作废了（`retired_codes` 表）：作废的时间
    Retired(i64),
}

/// 被控端出示的密钥和绑定的关系
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Owner {
    /// 没有绑定
    Free,
    /// 是现在的密钥
    Current,
    /// 是换密钥之前的那个：被控端没来得及保存新密钥（例如换密钥时断线、崩溃了），仍然是它
    Previous,
    /// 绑定给了别人
    Other,
}

#[derive(Default)]
struct Writes {
    /// `None`：两张表里都没有这个控制码了
    dirty: HashMap<u32, Option<Row>>,
    /// 排进来的最后一次写入的序号
    queued: u64,
    writing: bool,
    stop: bool,
}

struct Store {
    state: Mutex<Writes>,
    cv: Condvar,
    /// 已经落盘的写入序号
    committed: watch::Sender<u64>,
}

pub struct Bindings {
    entries: HashMap<u32, Binding>,
    /// 作废了的控制码和作废的时间（[`Bindings::retire`]）。和 `entries` 不会有同一个控制码
    retired: HashMap<u32, i64>,
    store: Option<Arc<Store>>,
    key: [u8; 32],
}

/// 等到某一时刻之前排进来的写入都落盘（[`Bindings::barrier`]）
pub struct Barrier {
    target: u64,
    committed: Option<watch::Receiver<u64>>,
}

impl Barrier {
    /// 返回是否在 `timeout` 之内落盘了（没有数据库时总是 `true`）
    pub async fn wait(self, timeout: Duration) -> bool {
        let Some(mut rx) = self.committed else {
            return true;
        };
        let target = self.target;
        matches!(
            tokio::time::timeout(timeout, rx.wait_for(|c| *c >= target)).await,
            Ok(Ok(_))
        )
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

fn secret_hash(secret: &[u8; 16]) -> Vec<u8> {
    let mut h = Sha256::new();
    h.update(b"airhand code binding v1\0");
    h.update(secret);
    h.finalize().to_vec()
}

fn open(path: &Path) -> Result<Connection> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let db = Connection::open(path)?;
    db.busy_timeout(Duration::from_secs(5))?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version > SCHEMA_VERSION {
        bail!("database schema {version} is newer than this server");
    }
    db.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")?;
    if version < 1 {
        db.execute_batch("BEGIN;
            CREATE TABLE fixed_codes (code INTEGER PRIMARY KEY, secret_hash BLOB NOT NULL, last_seen INTEGER NOT NULL);
            CREATE INDEX fixed_codes_last_seen ON fixed_codes (last_seen);
            PRAGMA user_version = 1; COMMIT;")?;
    }
    if version < 2 {
        // 2：换密钥时记下旧密钥的哈希；服务器自己的密钥
        db.execute_batch(
            "BEGIN;
            ALTER TABLE fixed_codes ADD COLUMN prev_hash BLOB;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            PRAGMA user_version = 2; COMMIT;",
        )?;
    }
    if version < 3 {
        // 3：作废了的控制码（被控端更换了控制码）
        db.execute_batch(
            "BEGIN;
            CREATE TABLE retired_codes (code INTEGER PRIMARY KEY, retired_at INTEGER NOT NULL);
            CREATE INDEX retired_codes_retired_at ON retired_codes (retired_at);
            PRAGMA user_version = 3; COMMIT;",
        )?;
    }
    Ok(db)
}

/// 绑定着的控制码，作废了的控制码和作废的时间
type Loaded = (HashMap<u32, Binding>, HashMap<u32, i64>);

fn load(db: &Connection) -> Result<Loaded> {
    let mut stmt = db.prepare("SELECT code, secret_hash, prev_hash, last_seen FROM fixed_codes")?;
    let bound = stmt
        .query_map([], |r| {
            Ok((
                r.get(0)?,
                Binding {
                    hash: r.get(1)?,
                    prev: r.get(2)?,
                    last_seen: r.get(3)?,
                },
            ))
        })?
        .collect::<rusqlite::Result<_>>()?;
    let mut stmt = db.prepare("SELECT code, retired_at FROM retired_codes")?;
    let retired = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    Ok((bound, retired))
}

/// 服务器自己的密钥：第一次启动时生成，之后一直用同一个
fn load_key(db: &Connection) -> Result<[u8; 32]> {
    let saved: Option<Vec<u8>> = db
        .query_row("SELECT value FROM meta WHERE key = 'server_key'", [], |r| {
            r.get(0)
        })
        .optional()?;
    if let Some(v) = saved {
        return <[u8; 32]>::try_from(v.as_slice()).context("the saved server key is corrupt");
    }
    let key: [u8; 32] = rand::random();
    db.execute(
        "INSERT INTO meta (key, value) VALUES ('server_key', ?1)",
        [key.as_slice()],
    )?;
    Ok(key)
}

fn writer(mut db: Connection, store: Arc<Store>) {
    loop {
        let (batch, upto) = {
            let mut s = store.state.lock().unwrap();
            while s.dirty.is_empty() && !s.stop {
                s = store.cv.wait(s).unwrap();
            }
            if s.dirty.is_empty() && s.stop {
                break;
            }
            s.writing = true;
            (std::mem::take(&mut s.dirty), s.queued)
        };
        let result = (|| -> rusqlite::Result<()> {
            let tx = db.transaction()?;
            // 每个控制码两张表都写：从一张换到另一张（作废、作废了的分给新的被控端）在同一个事务里
            for (code, row) in &batch {
                if !matches!(row, Some(Row::Bound(_))) {
                    tx.execute("DELETE FROM fixed_codes WHERE code = ?1", [code])?;
                }
                if !matches!(row, Some(Row::Retired(_))) {
                    tx.execute("DELETE FROM retired_codes WHERE code = ?1", [code])?;
                }
                match row {
                    Some(Row::Bound(b)) => {
                        tx.execute(
                        "INSERT INTO fixed_codes (code, secret_hash, prev_hash, last_seen) VALUES (?1, ?2, ?3, ?4)
                         ON CONFLICT (code) DO UPDATE SET secret_hash = excluded.secret_hash,
                           prev_hash = excluded.prev_hash, last_seen = excluded.last_seen",
                        params![code, &b.hash, &b.prev, b.last_seen])?;
                    }
                    Some(Row::Retired(at)) => {
                        tx.execute(
                            "INSERT INTO retired_codes (code, retired_at) VALUES (?1, ?2)
                             ON CONFLICT (code) DO UPDATE SET retired_at = excluded.retired_at",
                            params![code, at],
                        )?;
                    }
                    None => {}
                }
            }
            tx.commit()
        })();
        let failed = result.is_err();
        let mut s = store.state.lock().unwrap();
        s.writing = false;
        match result {
            // 这一批包含了 upto 之前排进来的全部写入（同一个控制码只留最新的值）
            Ok(()) => {
                store.committed.send_modify(|c| *c = (*c).max(upto));
            }
            Err(e) => {
                warn!(
                    "control code database: write failed ({e}); the changes are still in effect in memory, retrying"
                );
                if s.stop {
                    store.cv.notify_all();
                    break;
                }
                for (code, b) in batch {
                    s.dirty.entry(code).or_insert(b);
                }
            }
        }
        store.cv.notify_all();
        drop(s);
        if failed {
            std::thread::sleep(Duration::from_millis(250));
        }
    }
}

impl Bindings {
    /// `None` 显式选择内存模式；配置了数据库时，任何初始化错误都必须阻止启动。
    /// 否则空绑定表会把已有控制码重新分配，新的服务器密钥也会使旧凭证失效。
    pub fn open(path: Option<&Path>) -> Result<Self> {
        let Some(path) = path else {
            return Ok(Self {
                entries: HashMap::new(),
                retired: HashMap::new(),
                store: None,
                key: rand::random(),
            });
        };
        let ((entries, retired), key, db) = open(path)
            .and_then(|db| Ok((load(&db)?, load_key(&db)?, db)))
            .with_context(|| {
                format!("can't load control code ownership from {}", path.display())
            })?;
        info!(
            "control code database {}: {} fixed control code(s), {} retired control code(s)",
            path.display(),
            entries.len(),
            retired.len()
        );
        let store = Arc::new(Store {
            state: Mutex::default(),
            cv: Condvar::new(),
            committed: watch::Sender::new(0),
        });
        let worker = store.clone();
        std::thread::Builder::new()
            .name("airhand-codes".into())
            .spawn(move || writer(db, worker))
            .context("can't start the code persistence worker")?;
        Ok(Self {
            entries,
            retired,
            store: Some(store),
            key,
        })
    }

    /// 服务器自己的密钥（随数据库保存；没有数据库时每次启动随机生成）
    pub fn server_key(&self) -> [u8; 32] {
        self.key
    }

    /// 固定的控制码（绑定给了保存控制码的被控端，不管它在不在线）有几个
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// 作废了的控制码有几个（[`Bindings::retire`]，包括已经可以分给别人的）
    pub fn retired_len(&self) -> usize {
        self.retired.len()
    }

    /// `code` 绑定给了某个被控端（作废了的不算）
    pub fn contains(&self, code: u32) -> bool {
        self.entries.contains_key(&code)
    }

    /// `code` 作废了（[`Bindings::retire`]）。只有测试用
    #[cfg(test)]
    pub fn is_retired(&self, code: u32) -> bool {
        self.retired.contains_key(&code)
    }

    /// 哪些控制码可以分给新的被控端（在线的、保留着的由 broker 另外看）：没有绑定、也没有作废的，
    /// 以及作废超过 [`RETIRED_HOLD`] 的。分出去的作废了的控制码，作废的记录随之去掉（[`Bindings::bind`]、
    /// [`Bindings::remove`]）
    pub fn assignable(&self) -> impl Fn(u32) -> bool + '_ {
        let limit = now() - RETIRED_HOLD.as_secs() as i64;
        move |code| {
            !self.entries.contains_key(&code)
                && self.retired.get(&code).is_none_or(|at| *at < limit)
        }
    }

    pub fn check(&self, code: u32, secret: &[u8; 16]) -> Owner {
        let Some(b) = self.entries.get(&code) else {
            // 作废了的：谁的密钥都不认
            return if self.retired.contains_key(&code) {
                Owner::Other
            } else {
                Owner::Free
            };
        };
        let h = secret_hash(secret);
        if b.hash == h {
            Owner::Current
        } else if b.prev.as_ref() == Some(&h) {
            Owner::Previous
        } else {
            Owner::Other
        }
    }

    fn persist(&self, code: u32) {
        if let Some(store) = &self.store {
            let row = match (self.entries.get(&code), self.retired.get(&code)) {
                (Some(b), _) => Some(Row::Bound(b.clone())),
                (None, Some(at)) => Some(Row::Retired(*at)),
                (None, None) => None,
            };
            let mut s = store.state.lock().unwrap();
            s.queued += 1;
            s.dirty.insert(code, row);
            store.cv.notify_one();
        }
    }

    /// 把 `code` 绑定给持有 `secret` 的被控端；`prev`：换了密钥、被控端可能还没保存时的旧密钥。
    /// 返回绑定有没有实质的变化（新绑定、换了密钥）：有的话调用方要等它落盘（[`Bindings::barrier`]）
    /// 再告诉被控端，否则服务器崩溃之后被控端拿着新密钥也取不回控制码。作废了的控制码分给它时，作废的记录随之去掉
    pub fn bind(&mut self, code: u32, secret: &[u8; 16], prev: Option<&[u8; 16]>) -> bool {
        self.retired.remove(&code);
        let hash = secret_hash(secret);
        let changed = self.entries.get(&code).is_none_or(|b| b.hash != hash);
        self.entries.insert(
            code,
            Binding {
                hash,
                prev: prev.map(secret_hash),
                last_seen: now(),
            },
        );
        self.persist(code);
        changed
    }

    pub fn touch(&mut self, code: u32) {
        if let Some(b) = self.entries.get_mut(&code) {
            b.last_seen = now();
            self.persist(code);
        }
    }

    /// 被控端放弃了控制码（更换控制码）：作废，谁的密钥都不再认（[`Bindings::check`] 一律是 [`Owner::Other`]），
    /// [`RETIRED_HOLD`] 之内也不分给别人（[`Bindings::assignable`]）。之后可以分给新的被控端，但旧密钥照样不认，
    /// 直到分给了别人，或者 [`BINDING_TTL`] 之后清理。
    ///
    /// 不能直接删掉绑定：空闲的控制码只要出示本服务器为它签发过的密钥就能取回（服务器重启之后也认得，见 broker），
    /// 删掉的话，还拿着旧密钥的被控端（例如老版本的客户端停下再启动被控端时）又把它取回去，
    /// 换掉的控制码、用旧密钥算的重连凭证就又能用了。调用方要等它落盘（[`Bindings::barrier`]）
    pub fn retire(&mut self, code: u32) {
        self.entries.remove(&code);
        self.retired.insert(code, now());
        self.persist(code);
    }

    /// 解除绑定；作废了的控制码去掉作废的记录（分给了不保存控制码的被控端、过期了）。返回有没有去掉什么
    pub fn remove(&mut self, code: u32) -> bool {
        let bound = self.entries.remove(&code).is_some();
        let retired = self.retired.remove(&code).is_some();
        if bound || retired {
            self.persist(code);
        }
        bound || retired
    }

    /// 清理 [`BINDING_TTL`] 没有上线的绑定、作废了这么久的控制码。`online`：在线的不算
    pub fn expire(&mut self, online: impl Fn(u32) -> bool) {
        let limit = now() - BINDING_TTL.as_secs() as i64;
        let bound = self.entries.iter().map(|(code, b)| (*code, b.last_seen));
        let retired = self.retired.iter().map(|(code, at)| (*code, *at));
        let old: Vec<_> = bound
            .chain(retired)
            .filter(|(code, at)| *at < limit && !online(*code))
            .map(|(code, _)| code)
            .collect();
        for code in old {
            self.remove(code);
        }
    }

    /// 到现在为止排进来的写入的屏障：在持有 broker 锁时取，**放开锁之后**再等（[`Barrier::wait`]）
    pub fn barrier(&self) -> Barrier {
        match &self.store {
            Some(store) => Barrier {
                target: store.state.lock().unwrap().queued,
                committed: Some(store.committed.subscribe()),
            },
            None => Barrier {
                target: 0,
                committed: None,
            },
        }
    }
}

impl Drop for Bindings {
    fn drop(&mut self) {
        if let Some(store) = &self.store {
            store.state.lock().unwrap().stop = true;
            store.cv.notify_one();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn temp() -> std::path::PathBuf {
        std::env::temp_dir()
            .join(format!("airhand-codes-test-{:016x}", rand::random::<u64>()))
            .join("airhand.db")
    }

    /// 数据库里 `code` 在 `(fixed_codes, retired_codes)` 里各有几行
    fn rows(path: &Path, code: u32) -> (i64, i64) {
        let db = Connection::open(path).unwrap();
        let count = |table: &str| {
            db.query_row(
                &format!("SELECT count(*) FROM {table} WHERE code = ?1"),
                [code],
                |r| r.get(0),
            )
            .unwrap()
        };
        (count("fixed_codes"), count("retired_codes"))
    }

    #[tokio::test]
    async fn roundtrip_and_expiry() {
        let path = temp();
        let mut b = Bindings::open(Some(&path)).unwrap();
        let key = b.server_key();
        assert!(b.bind(123456, &[1; 16], None));
        assert!(b.bind(654321, &[2; 16], None));
        // 同一个密钥再绑一次（被控端取回控制码）不算变化
        assert!(!b.bind(654321, &[2; 16], None));
        b.entries.get_mut(&654321).unwrap().last_seen = 1;
        b.persist(654321);
        assert!(b.barrier().wait(Duration::from_secs(5)).await);
        drop(b);
        let mut b = Bindings::open(Some(&path)).unwrap();
        assert_eq!(b.server_key(), key, "the server key survives a restart");
        assert_eq!(b.len(), 2);
        assert_eq!(b.check(123456, &[1; 16]), Owner::Current);
        assert_eq!(b.check(123456, &[2; 16]), Owner::Other);
        assert_eq!(b.check(111111, &[2; 16]), Owner::Free);
        b.expire(|_| false);
        assert!(!b.contains(654321));
        b.remove(123456);
        b.bind(123456, &[3; 16], None); // latest write wins, including remove/rebind
        assert!(b.barrier().wait(Duration::from_secs(5)).await);
        let again = Bindings::open(Some(&path)).unwrap();
        assert_eq!(again.check(123456, &[3; 16]), Owner::Current);
        assert_eq!(again.len(), 1);
    }

    #[tokio::test]
    async fn rekey_keeps_the_previous_secret_until_confirmed() {
        let path = temp();
        let mut b = Bindings::open(Some(&path)).unwrap();
        b.bind(123456, &[1; 16], None);
        assert!(b.bind(123456, &[2; 16], Some(&[1; 16])));
        assert!(b.barrier().wait(Duration::from_secs(5)).await);
        let mut again = Bindings::open(Some(&path)).unwrap();
        assert_eq!(again.check(123456, &[2; 16]), Owner::Current);
        assert_eq!(again.check(123456, &[1; 16]), Owner::Previous);
        assert_eq!(again.check(123456, &[3; 16]), Owner::Other);
        // 被控端拿着新密钥回来了：旧的不再认
        again.bind(123456, &[2; 16], None);
        assert_eq!(again.check(123456, &[1; 16]), Owner::Other);
    }

    /// 作废了的控制码记在 retired_codes 表里，谁的密钥都不认（包括原来的和换密钥之前的），服务器重启之后也一样；
    /// [`RETIRED_HOLD`] 之内不分给别人，之后可以分了（分出去之前旧密钥照样不认），[`BINDING_TTL`] 之后清理
    #[tokio::test]
    async fn retired_codes_accept_no_secret() {
        let path = temp();
        let mut b = Bindings::open(Some(&path)).unwrap();
        b.bind(123456, &[2; 16], Some(&[1; 16]));
        b.retire(123456);
        assert!(!b.contains(123456) && b.is_retired(123456));
        for secret in [[1; 16], [2; 16], [3; 16]] {
            assert_eq!(b.check(123456, &secret), Owner::Other);
        }
        // 没绑定过的（不保存控制码的被控端放弃的）也一样作废
        b.retire(654321);
        assert_eq!(b.check(654321, &[1; 16]), Owner::Other);
        assert!(b.barrier().wait(Duration::from_secs(5)).await);
        drop(b);
        assert_eq!(rows(&path, 123456), (0, 1));
        assert_eq!(rows(&path, 654321), (0, 1));

        let mut again = Bindings::open(Some(&path)).unwrap();
        assert_eq!((again.len(), again.retired_len()), (0, 2));
        assert!(again.is_retired(123456));
        for secret in [[1; 16], [2; 16]] {
            assert_eq!(again.check(123456, &secret), Owner::Other);
        }
        assert!(!again.assignable()(123456), "just retired");

        // 作废超过 RETIRED_HOLD：可以分给新的被控端了，但还没清理，旧密钥照样不认
        let held = now() - RETIRED_HOLD.as_secs() as i64 - 60;
        again.retired.insert(123456, held);
        again.retired.insert(654321, held);
        assert!(again.assignable()(123456));
        again.expire(|_| false);
        assert!(
            again.is_retired(123456),
            "retired a week ago, not expired yet"
        );
        assert_eq!(again.check(123456, &[2; 16]), Owner::Other);
        // 别的绑定一样久没上线也不分给别人；什么都没有的可以分
        again.bind(111111, &[4; 16], None);
        again.entries.get_mut(&111111).unwrap().last_seen = held;
        assert!(!again.assignable()(111111));
        assert!(again.assignable()(222222));

        // 分给了新的被控端：保存控制码的绑定给它，不保存的去掉作废的记录；数据库里跟着变
        assert!(again.bind(123456, &[5; 16], None));
        assert!(!again.is_retired(123456));
        assert_eq!(again.check(123456, &[5; 16]), Owner::Current);
        assert_eq!(again.check(123456, &[2; 16]), Owner::Other);
        assert!(again.remove(654321));
        assert_eq!(again.check(654321, &[1; 16]), Owner::Free);
        assert!(again.barrier().wait(Duration::from_secs(5)).await);
        assert_eq!(rows(&path, 123456), (1, 0));
        assert_eq!(rows(&path, 654321), (0, 0));

        // BINDING_TTL 之后清理
        again.retire(333333);
        again.retired.insert(333333, 1);
        again.expire(|_| false);
        assert_eq!(again.check(333333, &[2; 16]), Owner::Free);
        assert!(again.barrier().wait(Duration::from_secs(5)).await);
        assert_eq!(rows(&path, 333333), (0, 0));
    }

    /// 别人一直在写，屏障也只等调用之前的那些
    #[test]
    fn barrier_does_not_wait_for_later_writes() {
        let path = temp();
        let mut b = Bindings::open(Some(&path)).unwrap();
        b.bind(100000, &[1; 16], None);
        let barrier = b.barrier();
        let writes = std::thread::scope(|s| {
            let busy = s.spawn(|| {
                let start = Instant::now();
                let mut n = 0u32;
                while start.elapsed() < Duration::from_millis(300) {
                    b.bind(200000 + n % 1000, &[n as u8; 16], None);
                    n += 1;
                }
                n
            });
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_time()
                .build()
                .unwrap();
            let start = Instant::now();
            assert!(rt.block_on(barrier.wait(Duration::from_secs(5))));
            assert!(start.elapsed() < Duration::from_secs(2));
            busy.join().unwrap()
        });
        assert!(writes > 0);
    }

    #[tokio::test]
    async fn locked_database_does_not_block_broker_or_lose_ownership() {
        let path = temp();
        let mut b = Bindings::open(Some(&path)).unwrap();
        let db = Connection::open(&path).unwrap();
        db.execute_batch("BEGIN IMMEDIATE").unwrap();
        let start = Instant::now();
        b.bind(123456, &[1; 16], None);
        assert_eq!(b.check(123456, &[2; 16]), Owner::Other);
        assert!(start.elapsed() < Duration::from_millis(100));
        assert!(!b.barrier().wait(Duration::from_millis(20)).await);
        db.execute_batch("ROLLBACK").unwrap();
        assert!(b.barrier().wait(Duration::from_secs(6)).await);
    }

    #[test]
    fn newer_schema_is_left_alone() {
        let path = temp();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        Connection::open(&path)
            .unwrap()
            .execute_batch("PRAGMA user_version = 99")
            .unwrap();
        assert!(Bindings::open(Some(&path)).is_err());
        let v: i64 = Connection::open(&path)
            .unwrap()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, 99);
    }

    #[test]
    fn startup_failure_preserves_saved_ownership_and_server_key() {
        let path = temp();
        let db = open(&path).unwrap();
        let key = load_key(&db).unwrap();
        db.execute(
            "INSERT INTO fixed_codes (code, secret_hash, last_seen) VALUES (?1, ?2, ?3)",
            params![123456, secret_hash(&[7; 16]), now()],
        )
        .unwrap();
        db.execute_batch("PRAGMA user_version = 99").unwrap();
        assert!(Bindings::open(Some(&path)).is_err());
        db.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION}"))
            .unwrap();
        let saved = Bindings::open(Some(&path)).unwrap();
        assert_eq!(saved.check(123456, &[7; 16]), Owner::Current);
        assert_eq!(saved.server_key(), key);

        let invalid = path.with_file_name("corrupt.db");
        std::fs::write(&invalid, b"not a SQLite database").unwrap();
        assert!(Bindings::open(Some(&invalid)).is_err());
        assert!(Bindings::open(Some(path.parent().unwrap())).is_err());
        assert_eq!(Bindings::open(None).unwrap().len(), 0);
    }

    /// 版本 1 的数据库（之前的服务器建的）一路升级到现在的版本，原来的绑定都还在，有了记作废的表
    #[test]
    fn upgrades_a_version_1_database() {
        let path = temp();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let db = Connection::open(&path).unwrap();
        db.execute_batch("BEGIN;
            CREATE TABLE fixed_codes (code INTEGER PRIMARY KEY, secret_hash BLOB NOT NULL, last_seen INTEGER NOT NULL);
            CREATE INDEX fixed_codes_last_seen ON fixed_codes (last_seen);
            PRAGMA user_version = 1; COMMIT;").unwrap();
        db.execute(
            "INSERT INTO fixed_codes (code, secret_hash, last_seen) VALUES (?1, ?2, ?3)",
            params![123456, secret_hash(&[7; 16]), now()],
        )
        .unwrap();
        drop(db);
        let b = Bindings::open(Some(&path)).unwrap();
        assert_eq!(b.check(123456, &[7; 16]), Owner::Current);
        assert_eq!(b.retired_len(), 0);
        let v: i64 = Connection::open(&path)
            .unwrap()
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);
        assert_eq!(rows(&path, 123456), (1, 0));
    }
}
