"""SQLite 存储层。

选型理由：个人自用量级，SQLite 零运维、单文件、易备份。
所有写入使用参数化查询防止注入。
"""

from __future__ import annotations

import json
import logging
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS charge_records (
    record_id   TEXT PRIMARY KEY,
    timestamp   TEXT NOT NULL,
    amount      REAL NOT NULL,
    energy_kwh  REAL,
    provider    TEXT,
    channel     TEXT,
    merchant    TEXT,
    station     TEXT,
    unit_price  REAL,
    order_no    TEXT,
    created_at  TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_charge_ts ON charge_records(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_charge_provider ON charge_records(provider);

-- 官方充电流水（`ms-charge-manage/.../charge/log/queryGroupMouth`）。
--
-- 与 `charge_records` 的分工是**刻意的、不要合并**：
--   · 这张表 = 「车到底充进去多少度」，极氪官方接口自动同步，权威且零操作；
--   · `charge_records` = 「支付账单解析出来的金额」，历史遗留通道，实测 0 行。
-- 两个数据来源根本不同（电来自车、钱来自支付），合成一行就会逼着二选一 ——
-- 历史上的 `charge_records.energy_kwh` 恒为 NULL 就是这么来的。
-- 金额能不能补上（截图 OCR / 手工）是另一条链路，补上就写 amount，
-- 并必须同时写 amount_source，否则「真值」与「估算」会被混算成单价。
--
-- ⚠️ **不存 VIN**：本机是单车主场景，落一份车架号只会凭空多一处敏感数据，
-- 而它对这个页面没有任何用处（查询靠月份，不靠车辆）。
-- ⚠️ `raw_json` 里上游确实带 VIN，所以**整列不落库**，只保留归一化后的字段。
CREATE TABLE IF NOT EXISTS charge_sessions (
    session_id    TEXT PRIMARY KEY,      -- zeekr:<eventId>
    source        TEXT NOT NULL DEFAULT 'zeekr',
    start_ts      TEXT NOT NULL,         -- 本地时间 'YYYY-MM-DD HH:MM:SS'
    end_ts        TEXT,
    duration_min  REAL,
    energy_kwh    REAL,
    charge_type   TEXT,                  -- dc / ac / unknown
    station_name  TEXT,                  -- 上游没有站点字段，只能来自 OCR/手工
    amount        REAL,                  -- 可空；有值时必须同时有 amount_source
    amount_source TEXT,                  -- zeekr_order / ocr / manual / estimate
    updated_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_session_start ON charge_sessions(start_ts DESC);

-- 金额证据层：每一笔"支付"（截图识别 / 手工录入）先落这里，配对成功后再回写
-- `charge_sessions.amount`。
--
-- 为什么不直接写 session：
--   1. 有些支付**根本配不上**（停车费 / 占位费 / 别人付的），但它们也是事实，
--      静默丢掉等于吞数据；
--   2. 同一张截图重跑要能幂等（`payment_id` 由 image_sha + 金额 + 时间算出）；
--   3. 原始证据要可追溯：用户改过一次金额，得能看出改之前是多少。
CREATE TABLE IF NOT EXISTS charge_payments (
    payment_id   TEXT PRIMARY KEY,      -- sha256(imageSha|amount|paidAt)[:16] 或 manual:<uuid>
    source       TEXT NOT NULL,         -- ocr / manual
    paid_at      TEXT,                  -- 支付/充电开始时间（本地时间）
    amount       REAL NOT NULL,
    energy_kwh   REAL,
    station_name TEXT,
    order_tail   TEXT,                  -- 订单号只留后四位
    confidence   REAL,
    status       TEXT NOT NULL,         -- matched / pending / unmatched
    note         TEXT,
    image_sha    TEXT,                  -- 截图 hash 前 8 位，仅用于去重
    created_at   TEXT
);

CREATE INDEX IF NOT EXISTS idx_payment_paid ON charge_payments(paid_at DESC);
CREATE INDEX IF NOT EXISTS idx_payment_status ON charge_payments(status);

-- 配对关系：一个 session 只能有一笔已确认金额（PRIMARY KEY 保证），
-- 一笔 payment 也只能落到一个 session（UNIQUE 保证）。
CREATE TABLE IF NOT EXISTS charge_matches (
    session_id TEXT PRIMARY KEY,
    payment_id TEXT UNIQUE NOT NULL,
    kind       TEXT,                    -- strong / weak / manual
    confidence TEXT,                    -- high / low
    matched_at TEXT
);

CREATE TABLE IF NOT EXISTS trips (
    trip_id     TEXT PRIMARY KEY,
    start_time  TEXT,
    end_time    TEXT,
    distance_km REAL,
    energy_kwh  REAL,
    avg_speed   REAL,
    max_speed   REAL,
    consumption REAL,
    start_place TEXT,
    end_place   TEXT,
    duration    REAL,
    created_at  TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_trip_start ON trips(start_time DESC);

CREATE TABLE IF NOT EXISTS snapshots (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    vin         TEXT NOT NULL,
    soc         REAL,
    range_km    REAL,
    odometer_km REAL,
    payload     TEXT,
    created_at  TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_snapshot_vin_time ON snapshots(vin, created_at DESC);
-- 官方「行程统计」的逐日电耗。存在的意义是把 60 天窗口外的历史留下来：
-- 日统计接口只允许回查 60 天（A010），不落库的话三个月前的逐日数据就永久没了。
CREATE TABLE IF NOT EXISTS energy_daily (
    vin         TEXT NOT NULL,
    date        TEXT NOT NULL,          -- 2026-10-23（官方给 2026/10/23，落库前已归一）
    distance_km REAL NOT NULL DEFAULT 0,
    energy_kwh  REAL NOT NULL DEFAULT 0,-- 动态 + 静态（ecy 恒 0，不能用）
    dynamic_kwh REAL,                   -- 行驶中耗电（官方 dynamicEcY）；NULL = 老数据没有拆分
    static_kwh  REAL,                   -- 停车时空调/哨兵/待机（官方 staticEcY）；NULL = 没有拆分
    minutes     INTEGER NOT NULL DEFAULT 0,
    consumption REAL,                   -- energy/distance*100，距离为 0 时为 NULL
    updated_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (vin, date)
);


-- 逆地理编码结果缓存。坐标不变就不该重复向腾讯请求 ——
-- 既省免费额度，也减少"车的位置被发给第三方"的次数（这是实打实的隐私收益）。
-- 键是 5 位小数网格（≈1 米）：车静止时坐标连 6 位都完全一致，5 位足够命中，
-- 还能容忍轻微的定位抖动。value 存的是精简后的 JSON（不含原始响应）。
-- ⚠️ 这张表属于个人位置数据，随 zeekr.db 一起被 .gitignore 覆盖，不要导出。
CREATE TABLE IF NOT EXISTS geocode_cache (
    coord_key   TEXT PRIMARY KEY,
    address     TEXT NOT NULL,
    created_at  TEXT DEFAULT CURRENT_TIMESTAMP
);
"""


class Store:
    """数据存储。"""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        """借出一个 SQLite 连接，退出时提交/回滚并**显式关闭**。

        为什么不用裸连接：`with sqlite3.connect(...) as conn` 只做事务提交，
        **不会 close()** —— sqlite3 的上下文管理器管的是事务语义，不是资源
        生命周期。当前单进程 asyncio 下靠局部变量被 GC 回收勉强能用，但一旦
        换成多 worker 部署、或连接被缓存复用，文件句柄就会堆积。

        这里显式管理生命周期，同时保留原调用写法不变
        （`with self._connect() as conn:` 对生成器上下文管理器同样成立）。
        WAL 模式在建库时已是持久属性，这里保留设置以兼容旧库。
        """
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA journal_mode=WAL")
            yield conn
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()

    def _init_schema(self) -> None:
        with self._connect() as conn:
            conn.executescript(SCHEMA)
            self._migrate_energy_split(conn)

    @staticmethod
    def _migrate_energy_split(conn: sqlite3.Connection) -> None:
        # 给老库的 energy_daily 补上动态/静态两列。
        #
        # CREATE TABLE IF NOT EXISTS 对已存在的表是空操作，加列只能显式 ALTER；
        # 新库走 SCHEMA 已带上两列，所以这里只有老库需要补。
        # 两列允许 NULL：老数据只有合并值，拆分未知必须与「真的是 0」区分开，
        # 前端见 null 就退回画合并柱。
        for ddl in (
            "ALTER TABLE energy_daily ADD COLUMN dynamic_kwh REAL",
            "ALTER TABLE energy_daily ADD COLUMN static_kwh REAL",
        ):
            try:
                conn.execute(ddl)
            except sqlite3.OperationalError:
                pass  # 列已存在

    # MARK: - 充电记录

    def save_charges(self, charges: list[dict[str, Any]]) -> int:
        """批量写入充电记录（按 record_id 幂等）。"""
        if not charges:
            return 0

        rows = [
            (
                c.get("recordId"),
                str(c.get("timestamp") or ""),
                float(c.get("amount") or 0),
                c.get("energyKwh"),
                c.get("provider"),
                c.get("channel"),
                c.get("merchant"),
                c.get("stationName"),
                c.get("unitPrice"),
                c.get("orderNo"),
            )
            for c in charges
        ]

        with self._connect() as conn:
            before = conn.total_changes
            conn.executemany(
                """
                INSERT OR IGNORE INTO charge_records
                    (record_id, timestamp, amount, energy_kwh, provider,
                     channel, merchant, station, unit_price, order_no)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
            # 用 total_changes 差值，而不是 len(rows)。
            # len(rows) 是"尝试写入数"—— 被 OR IGNORE 跳过的重复行也被算进去，
            # 接口语义不准（调用方据此判断"导入了几笔"会偏大）。
            inserted = conn.total_changes - before
        return inserted

    def list_charges(self, limit: int = 100, months: int | None = None) -> list[dict[str, Any]]:
        """查询充电记录。"""
        sql = "SELECT * FROM charge_records"
        params: list[Any] = []

        if months:
            cutoff = (datetime.now() - timedelta(days=months * 31)).strftime("%Y-%m-%d")
            sql += " WHERE timestamp >= ?"
            params.append(cutoff)

        sql += " ORDER BY timestamp DESC LIMIT ?"
        params.append(limit)

        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()

        return [
            {
                "recordId": row["record_id"],
                "timestamp": row["timestamp"],
                "amount": row["amount"],
                "energyKwh": row["energy_kwh"],
                "provider": row["provider"],
                "channel": row["channel"],
                "merchant": row["merchant"],
                "stationName": row["station"],
                "unitPrice": row["unit_price"],
                "orderNo": row["order_no"],
            }
            for row in rows
        ]

    def clear_charges(self) -> int:
        """清空充电记录。"""
        with self._connect() as conn:
            cursor = conn.execute("DELETE FROM charge_records")
            return cursor.rowcount

    # MARK: - 官方充电流水

    def save_sessions(self, sessions: list[dict[str, Any]]) -> dict[str, int]:
        """批量写入官方充电流水（按 `session_id` upsert，重复同步无副作用）。

        为什么用 upsert 而不是 `INSERT OR IGNORE`：上游会修正历史记录
        （实测同一 `eventId` 的 `chargedTime`/`power` 有过变化），
        IGNORE 会让库里永远停在第一次同步那份。upsert 同时保住已配对的
        `amount`/`station_name` —— 那两个值上游根本没有，覆盖掉就白配了。

        Returns:
            {"inserted": 新增条数, "updated": 覆盖条数}
        """
        if not sessions:
            return {"inserted": 0, "updated": 0}

        rows = [
            (
                str(s.get("sessionId") or ""),
                str(s.get("source") or "zeekr"),
                str(s.get("startTime") or ""),
                s.get("endTime"),
                s.get("durationMin"),
                s.get("energyKwh"),
                s.get("chargeType"),
                s.get("stationName"),
                s.get("amount"),
                s.get("amountSource"),
                datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            )
            for s in sessions
            if s.get("sessionId") and s.get("startTime")
        ]
        if not rows:
            return {"inserted": 0, "updated": 0}

        ids = [r[0] for r in rows]
        placeholders = ",".join("?" * len(ids))
        with self._connect() as conn:
            existing = {
                row["session_id"]
                for row in conn.execute(
                    f"SELECT session_id FROM charge_sessions WHERE session_id IN ({placeholders})",
                    ids,
                ).fetchall()
            }
            conn.executemany(
                """
                INSERT INTO charge_sessions
                    (session_id, source, start_ts, end_ts, duration_min, energy_kwh,
                     charge_type, station_name, amount, amount_source, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    start_ts     = excluded.start_ts,
                    end_ts       = excluded.end_ts,
                    duration_min = excluded.duration_min,
                    energy_kwh   = excluded.energy_kwh,
                    charge_type  = excluded.charge_type,
                    -- 站点与金额来自 OCR/手工，上游没有 ⇒ 只在本地为空时补，绝不覆盖
                    station_name  = COALESCE(charge_sessions.station_name, excluded.station_name),
                    amount        = COALESCE(charge_sessions.amount, excluded.amount),
                    amount_source = COALESCE(charge_sessions.amount_source, excluded.amount_source),
                    updated_at   = excluded.updated_at
                """,
                rows,
            )

        updated = sum(1 for i in ids if i in existing)
        return {"inserted": len(ids) - updated, "updated": updated}

    def list_sessions(
        self, year_month: str | None = None, limit: int = 500
    ) -> list[dict[str, Any]]:
        """查询充电流水，可按 `YYYY-MM` 过滤（`start_ts` 前 7 位即年月）。"""
        sql = "SELECT * FROM charge_sessions"
        params: list[Any] = []
        if year_month:
            sql += " WHERE substr(start_ts, 1, 7) = ?"
            params.append(year_month)
        sql += " ORDER BY start_ts DESC LIMIT ?"
        params.append(limit)

        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()

        return [
            {
                "sessionId": row["session_id"],
                "source": row["source"],
                "startTime": row["start_ts"],
                "endTime": row["end_ts"],
                "durationMin": row["duration_min"],
                "energyKwh": row["energy_kwh"],
                "chargeType": row["charge_type"],
                "stationName": row["station_name"],
                "amount": row["amount"],
                "amountSource": row["amount_source"],
            }
            for row in rows
        ]

    def session_months(self) -> list[dict[str, Any]]:
        """按月聚合（月份倒序），供月份选择器与趋势图使用。

        口径：`kwh` 是**该月所有流水之和**，与官方 App「充电记录」页的
        `sumPower` 一致；`dcCount`/`acCount` 按 `charge_type` 计。
        缺 `energy_kwh` 的记录不参与求和（`SUM` 天然跳过 NULL），
        但仍计入 `count` —— 「充了几次」和「充了多少度」是两件事。

        `minutes` / `avgMinutes` 供趋势图的第二根轴用：
        电量只能看出"这个月充了多少"，看不出"每次充了多久"，
        而慢充一充一整夜、快充二十分钟，差的就是这个数。

        `amount` / `amountCount` 是**已补录的真值**（截图识别 / 手工录入），
        估算（`amount_source='estimate'`）不计入 —— 与 `_summarize_month` 同一口径：
        把估算混进合计，"这个月花了多少"就成了第三种数字。
        """
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT substr(start_ts, 1, 7)              AS ym,
                       COUNT(*)                            AS cnt,
                       COALESCE(SUM(energy_kwh), 0)        AS kwh,
                       COALESCE(SUM(duration_min), 0)      AS mins,
                       COALESCE(SUM(CASE WHEN amount_source = 'estimate' THEN 0
                                         ELSE amount END), 0) AS amt,
                       SUM(CASE WHEN amount IS NOT NULL
                                 AND COALESCE(amount_source, '') <> 'estimate'
                                THEN 1 ELSE 0 END)         AS amt_n,
                       SUM(CASE WHEN charge_type = 'dc' THEN 1 ELSE 0 END) AS dc,
                       SUM(CASE WHEN charge_type = 'ac' THEN 1 ELSE 0 END) AS ac
                FROM charge_sessions
                WHERE start_ts IS NOT NULL AND start_ts <> ''
                GROUP BY ym
                ORDER BY ym DESC
                """
            ).fetchall()

        out = []
        for row in rows:
            if not row["ym"]:
                continue
            count = int(row["cnt"] or 0)
            minutes = round(float(row["mins"] or 0))
            amount_count = int(row["amt_n"] or 0)
            out.append(
                {
                    "yearMonth": row["ym"],
                    "count": count,
                    "kwh": round(float(row["kwh"] or 0), 1),
                    "minutes": minutes,
                    "avgMinutes": round(minutes / count) if count else None,
                    "amount": round(float(row["amt"] or 0), 2) if amount_count else 0.0,
                    "amountCount": amount_count,
                    "dcCount": int(row["dc"] or 0),
                    "acCount": int(row["ac"] or 0),
                }
            )
        return out

    def count_sessions(self) -> int:
        with self._connect() as conn:
            row = conn.execute("SELECT COUNT(*) AS n FROM charge_sessions").fetchone()
        return int(row["n"] or 0)

    def clear_sessions(self) -> int:
        """清空充电流水（跟随退出登录的数据清理，见 AppStore 侧约定）。"""
        with self._connect() as conn:
            cursor = conn.execute("DELETE FROM charge_sessions")
            return cursor.rowcount

    # MARK: - 金额证据（截图识别 / 手工录入）

    def save_payments(self, payments: list[dict[str, Any]]) -> dict[str, int]:
        """写入支付证据（按 `payment_id` 幂等）。

        用 `INSERT OR IGNORE` 而不是 upsert：`payment_id` 本身就是内容指纹
        （图片 hash + 金额 + 时间），同一条重跑应当**什么都不做**，
        而不是把用户后来改过的金额又覆盖回模型识别的原值。
        """
        if not payments:
            return {"inserted": 0, "skipped": 0}

        rows = [
            (
                str(p.get("paymentId")),
                str(p.get("source") or "ocr"),
                p.get("paidAt"),
                float(p.get("amount") or 0),
                p.get("energyKwh"),
                p.get("stationName"),
                p.get("orderTail"),
                p.get("confidence"),
                str(p.get("status") or "pending"),
                p.get("note"),
                p.get("imageSha"),
                datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            )
            for p in payments
            if p.get("paymentId") and isinstance(p.get("amount"), (int, float))
        ]
        if not rows:
            return {"inserted": 0, "skipped": 0}

        with self._connect() as conn:
            before = conn.total_changes
            conn.executemany(
                """
                INSERT OR IGNORE INTO charge_payments
                    (payment_id, source, paid_at, amount, energy_kwh, station_name,
                     order_tail, confidence, status, note, image_sha, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
            inserted = conn.total_changes - before
        return {"inserted": inserted, "skipped": len(rows) - inserted}

    def list_payments(
        self, status: str | None = None, limit: int = 200
    ) -> list[dict[str, Any]]:
        # 带上绑定关系：界面要能显示"这笔钱挂在哪次充电上"，并给一个解绑入口 ——
        # 绑错了却撤不回来，比当初不自动绑还难受。
        sql = (
            "SELECT p.*, m.session_id FROM charge_payments p "
            "LEFT JOIN charge_matches m ON m.payment_id = p.payment_id"
        )
        params: list[Any] = []
        if status:
            sql += " WHERE p.status = ?"
            params.append(status)
        sql += " ORDER BY p.paid_at DESC, p.created_at DESC LIMIT ?"
        params.append(limit)

        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()

        return [
            {
                "paymentId": row["payment_id"],
                "sessionId": row["session_id"],
                "source": row["source"],
                "paidAt": row["paid_at"],
                "amount": row["amount"],
                "energyKwh": row["energy_kwh"],
                "stationName": row["station_name"],
                "orderTail": row["order_tail"],
                "confidence": row["confidence"],
                "status": row["status"],
                "note": row["note"],
                "imageSha": row["image_sha"],
            }
            for row in rows
        ]

    def get_payment(self, payment_id: str) -> dict[str, Any] | None:
        for item in self.list_payments(limit=1000):
            if item["paymentId"] == payment_id:
                return item
        return None

    def payment_status(self, payment_id: str) -> str | None:
        """查一笔支付当前状态。commit 用它在覆盖前判断"是不是已经配好了"。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT status FROM charge_payments WHERE payment_id = ?",
                (payment_id,),
            ).fetchone()
        return row["status"] if row is not None else None

    def link_payment(
        self,
        session_id: str,
        payment_id: str,
        kind: str = "manual",
        confidence: str = "high",
    ) -> None:
        """把一笔支付绑到一次充电上，并回写 session 的金额/来源/站点名。

        三件事必须在**同一事务**里：
          1. 这笔 payment 原来若绑在别的 session 上，要先把那边解绑；
          2. `charge_matches` 里 session / payment 都是唯一键，重复绑要先删；
          3. `charge_sessions.amount` 是汇总口径的唯一真值来源。
        """
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        with self._connect() as conn:
            payment = conn.execute(
                "SELECT amount, source, station_name FROM charge_payments WHERE payment_id = ?",
                (payment_id,),
            ).fetchone()
            if payment is None:
                raise KeyError(f"payment not found: {payment_id}")

            # 目标流水必须存在。原来直接 UPDATE（不符合就影响 0 行）却照样插 match、
            # 照样把支付置为 matched —— 结果钱既不进任何月份统计，也不在待确认队列里。
            session = conn.execute(
                "SELECT session_id FROM charge_sessions WHERE session_id = ?",
                (session_id,),
            ).fetchone()
            if session is None:
                raise KeyError(f"session not found: {session_id}")

            # ① 这笔支付原来绑过的 session，先解绑
            old = conn.execute(
                "SELECT session_id FROM charge_matches WHERE payment_id = ?", (payment_id,)
            ).fetchone()
            if old is not None and old["session_id"] != session_id:
                self._detach(conn, old["session_id"])

            # ② 目标 session 上若已有别的支付，也解绑对方的 payment
            existing = conn.execute(
                "SELECT payment_id FROM charge_matches WHERE session_id = ?", (session_id,)
            ).fetchone()
            if existing is not None:
                conn.execute(
                    "UPDATE charge_payments SET status = 'pending' WHERE payment_id = ?",
                    (existing["payment_id"],),
                )
                conn.execute("DELETE FROM charge_matches WHERE session_id = ?", (session_id,))

            conn.execute(
                """
                INSERT INTO charge_matches (session_id, payment_id, kind, confidence, matched_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    payment_id = excluded.payment_id,
                    kind = excluded.kind,
                    confidence = excluded.confidence,
                    matched_at = excluded.matched_at
                """,
                (session_id, payment_id, kind, confidence, now),
            )

            conn.execute(
                """
                UPDATE charge_sessions SET
                    amount = ?,
                    amount_source = ?,
                    -- 站点名只可能来自 OCR，已有值不覆盖
                    station_name = COALESCE(station_name, ?)
                WHERE session_id = ?
                """,
                (float(payment["amount"]), payment["source"], payment["station_name"], session_id),
            )
            conn.execute(
                "UPDATE charge_payments SET status = 'matched' WHERE payment_id = ?",
                (payment_id,),
            )

    @staticmethod
    def _detach(conn: sqlite3.Connection, session_id: str) -> None:
        """解除某次充电的金额绑定，并把支付退回待确认。"""
        row = conn.execute(
            "SELECT payment_id FROM charge_matches WHERE session_id = ?", (session_id,)
        ).fetchone()
        if row is not None:
            conn.execute(
                "UPDATE charge_payments SET status = 'pending' WHERE payment_id = ?",
                (row["payment_id"],),
            )
        conn.execute("DELETE FROM charge_matches WHERE session_id = ?", (session_id,))
        conn.execute(
            "UPDATE charge_sessions SET amount = NULL, amount_source = NULL WHERE session_id = ?",
            (session_id,),
        )

    def unlink_session(self, session_id: str) -> bool:
        with self._connect() as conn:
            exists = conn.execute(
                "SELECT 1 FROM charge_matches WHERE session_id = ?", (session_id,)
            ).fetchone()
            if exists is None:
                return False
            self._detach(conn, session_id)
        return True

    def session_for_payment(self, payment_id: str) -> str | None:
        """这笔支付当前绑在哪次充电上（没绑返回 None）。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT session_id FROM charge_matches WHERE payment_id = ?", (payment_id,)
            ).fetchone()
        return row["session_id"] if row is not None else None

    def session_ids_without_amount(self) -> list[str]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT session_id FROM charge_sessions WHERE amount IS NULL ORDER BY start_ts DESC"
            ).fetchall()
        return [row["session_id"] for row in rows]

    def payment_counts(self, year_month: str | None = None) -> dict[str, int]:
        """按状态统计支付笔数（界面上的「待确认 N 笔」用它）。"""
        sql = "SELECT status, COUNT(*) AS n FROM charge_payments"
        params: list[Any] = []
        if year_month:
            sql += " WHERE substr(paid_at, 1, 7) = ?"
            params.append(year_month)
        sql += " GROUP BY status"
        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()
        return {row["status"]: int(row["n"]) for row in rows}

    def set_payment_status(self, payment_id: str, status: str, note: str | None = None) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE charge_payments SET status = ?, note = COALESCE(?, note) WHERE payment_id = ?",
                (status, note, payment_id),
            )

    def clear_payments(self) -> int:
        with self._connect() as conn:
            cleared = conn.execute("DELETE FROM charge_payments").rowcount
            conn.execute("DELETE FROM charge_matches")
            conn.execute("UPDATE charge_sessions SET amount = NULL, amount_source = NULL")
        return cleared

    # MARK: - 行程

    def save_trips(self, trips: list[dict[str, Any]]) -> int:
        """批量写入行程（按 trip_id 幂等）。

        防御性兜底：`trip_id` 是主键且用 `INSERT OR REPLACE`，因此**任何**
        空值都会让后续行程覆盖前面的，静默丢数据（历史缺陷：写 3 条只剩
        1 条）。适配器层已用 `build_trip_id` 生成派生指纹，这里再做一道
        拦截 —— 空 id 直接跳过并告警，宁可少写一条也不要覆盖一条。
        """
        if not trips:
            return 0

        rows = []
        for t in trips:
            trip_id = t.get("tripId")
            if trip_id is None or not str(trip_id).strip():
                logger.warning(
                    "跳过 trip_id 为空的行程（防止主键碰撞覆盖）：start=%s",
                    t.get("startTime"),
                )
                continue
            rows.append(
                (
                    str(trip_id),
                    t.get("startTime"),
                    t.get("endTime"),
                    t.get("distanceKm"),
                    t.get("energyKwh"),
                    t.get("avgSpeedKmh"),
                    t.get("maxSpeedKmh"),
                    t.get("consumption"),
                    t.get("startPlace"),
                    t.get("endPlace"),
                    t.get("durationMinutes"),
                )
            )

        if not rows:
            return 0

        with self._connect() as conn:
            conn.executemany(
                """
                INSERT OR REPLACE INTO trips
                    (trip_id, start_time, end_time, distance_km, energy_kwh,
                     avg_speed, max_speed, consumption, start_place, end_place, duration)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
        return len(rows)

    def list_trips(self, days: int = 30, limit: int = 200) -> list[dict[str, Any]]:
        """按天数查询行程。"""
        cutoff = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM trips
                WHERE start_time >= ?
                ORDER BY start_time DESC
                LIMIT ?
                """,
                (cutoff, limit),
            ).fetchall()

        return [
            {
                "tripId": row["trip_id"],
                "startTime": row["start_time"],
                "endTime": row["end_time"],
                "distanceKm": row["distance_km"],
                "energyKwh": row["energy_kwh"],
                "avgSpeedKmh": row["avg_speed"],
                "maxSpeedKmh": row["max_speed"],
                "consumption": row["consumption"],
                "startPlace": row["start_place"],
                "endPlace": row["end_place"],
                "durationMinutes": row["duration"],
            }
            for row in rows
        ]

    # MARK: - 日电耗（官方「行程统计」逐日数据）

    def save_energy_daily(self, vin: str, series: list[dict[str, Any]]) -> int:
        """按 (vin, date) 幂等写入逐日电耗。

        官方日统计的 X 轴只含「有数据的日期」，同一天重查会得到同样的值，
        所以重复拉取必须覆盖而不是累加。

        distance_km 为 0 的行也要写：实测 10-18 返回了 0 km，那是「车有上报但
        当天没开」，与「完全没有记录」不是一回事，不能都当没数据。
        """
        if not series:
            return 0

        rows = []
        for item in series:
            date = str(item.get("date") or "").strip()
            # 主键的一部分，格式错会污染整张表，宁可跳过
            if len(date) != 10 or date[4] != "-" or date[7] != "-":
                logger.warning("跳过日期非法的日电耗行：%r", item.get("date"))
                continue
            dynamic = item.get("dynamicKwh")
            static = item.get("staticKwh")
            rows.append(
                (
                    vin,
                    date,
                    float(item.get("distanceKm") or 0),
                    float(item.get("energyKwh") or 0),
                    None if dynamic is None else float(dynamic),
                    None if static is None else float(static),
                    int(item.get("minutes") or 0),
                    item.get("consumption"),
                )
            )

        if not rows:
            return 0

        with self._connect() as conn:
            conn.executemany(
                """
                INSERT INTO energy_daily
                    (vin, date, distance_km, energy_kwh, dynamic_kwh, static_kwh,
                     minutes, consumption, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                ON CONFLICT(vin, date) DO UPDATE SET
                    distance_km = excluded.distance_km,
                    energy_kwh  = excluded.energy_kwh,
                    -- 只拿到合并值的写入不许把已有拆分抹成 NULL
                    dynamic_kwh = COALESCE(excluded.dynamic_kwh, energy_daily.dynamic_kwh),
                    static_kwh  = COALESCE(excluded.static_kwh, energy_daily.static_kwh),
                    minutes     = excluded.minutes,
                    consumption = excluded.consumption,
                    updated_at  = CURRENT_TIMESTAMP
                """,
                rows,
            )
        return len(rows)

    def list_energy_daily(self, vin: str, days: int = 30) -> list[dict[str, Any]]:
        """读最近 N 天（含今天）的逐日电耗，按日期升序。"""
        days = max(1, int(days))
        cutoff = (datetime.now() - timedelta(days=days - 1)).strftime("%Y-%m-%d")
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT date, distance_km, energy_kwh, dynamic_kwh, static_kwh,
                       minutes, consumption
                FROM energy_daily
                WHERE vin = ? AND date >= ?
                ORDER BY date
                """,
                (vin, cutoff),
            ).fetchall()

        return [
            {
                "date": row["date"],
                "distanceKm": row["distance_km"],
                "energyKwh": row["energy_kwh"],
                "dynamicKwh": row["dynamic_kwh"],
                "staticKwh": row["static_kwh"],
                "minutes": row["minutes"],
                "consumption": row["consumption"],
            }
            for row in rows
        ]

    def energy_daily_latest(self, vin: str) -> str | None:
        """库里最新一天是哪天；没有数据返回 None。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT MAX(date) AS latest FROM energy_daily WHERE vin = ?", (vin,)
            ).fetchone()
        return row["latest"] if row and row["latest"] else None

    # MARK: - 状态快照

    # 每辆车保留的最大快照数。前端按秒级轮询时，一天即可写入数万行，
    # 不设上限会让 SQLite 文件无限膨胀（且 list_snapshots 只需最近 200 条）。
    SNAPSHOT_KEEP = 2000
    # 两次快照的最小间隔（秒）。轮询比这更频繁时，只有状态**实质变化**
    # 才值得再存一行，否则就是纯冗余。
    SNAPSHOT_MIN_INTERVAL_SEC = 60

    def save_snapshot(self, status: dict[str, Any]) -> None:
        """保存一条状态快照，用于回溯电量变化。

        两道防膨胀：
        1. **节流**：距上一条不足 `SNAPSHOT_MIN_INTERVAL_SEC` 且 SOC /
           续航 / 里程都未变时直接丢弃（轮询噪声不落库）。
        2. **保留上限**：每辆车只留最近 `SNAPSHOT_KEEP` 条，超出即删。

        时钟一致性：`created_at` 显式由 Python 写入**本地时钟**，而不是
        用 SQLite 的 `CURRENT_TIMESTAMP` 默认值 —— 后者是 UTC，与本地
        `datetime.now()` 差一个时区，会让上面的间隔比较直接失效。
        """
        vin = status.get("vin")
        if not vin:
            logger.debug("状态无 vin，跳过快照")
            return

        soc = status.get("soc")
        range_km = status.get("rangeKm")
        odometer = status.get("odometerKm")

        with self._connect() as conn:
            last = conn.execute(
                """
                SELECT soc, range_km, odometer_km, created_at
                FROM snapshots
                WHERE vin = ?
                ORDER BY created_at DESC, id DESC
                LIMIT 1
                """,
                (vin,),
            ).fetchone()

            if last is not None and not self._snapshot_worth_saving(
                last, soc, range_km, odometer
            ):
                return

            conn.execute(
                """
                INSERT INTO snapshots (vin, soc, range_km, odometer_km, payload, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    vin,
                    soc,
                    range_km,
                    odometer,
                    json.dumps(status, ensure_ascii=False),
                    datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                ),
            )
            self._prune_snapshots(conn, vin)

    def _snapshot_worth_saving(
        self,
        last: sqlite3.Row,
        soc: Any,
        range_km: Any,
        odometer: Any,
    ) -> bool:
        """判断新状态是否值得落库。

        状态有实质变化 → 存；完全没变且间隔太短 → 丢。
        时间解析失败时保守选择「存」，宁可多一条也不要丢数据。
        """
        changed = (
            last["soc"] != soc
            or last["range_km"] != range_km
            or last["odometer_km"] != odometer
        )
        if changed:
            return True

        try:
            last_at = datetime.strptime(str(last["created_at"]), "%Y-%m-%d %H:%M:%S")
        except (TypeError, ValueError):
            return True

        elapsed = (datetime.now() - last_at).total_seconds()
        return elapsed >= self.SNAPSHOT_MIN_INTERVAL_SEC

    def _prune_snapshots(self, conn: sqlite3.Connection, vin: str) -> None:
        """删除该车辆超出保留上限的旧快照。"""
        conn.execute(
            """
            DELETE FROM snapshots
            WHERE vin = ?
              AND id NOT IN (
                  SELECT id FROM snapshots
                  WHERE vin = ?
                  ORDER BY created_at DESC, id DESC
                  LIMIT ?
              )
            """,
            (vin, vin, self.SNAPSHOT_KEEP),
        )

    def list_snapshots(self, vin: str, limit: int = 200) -> list[dict[str, Any]]:
        """查询状态快照。"""
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT soc, range_km, odometer_km, created_at
                FROM snapshots
                WHERE vin = ?
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """,
                (vin, limit),
            ).fetchall()

        return [
            {
                "soc": row["soc"],
                "rangeKm": row["range_km"],
                "odometerKm": row["odometer_km"],
                "createdAt": row["created_at"],
            }
            for row in rows
        ]

    # MARK: - 逆地理编码缓存

    def get_geocode(self, coord_key: str) -> dict[str, Any] | None:
        """按坐标网格取缓存的地址。没有就返回 None（由调用方去请求腾讯）。

        为什么缓存要落库而不是只放内存：车静止时坐标可以几天不变，
        内存缓存一重启就没了，等于每次开服务都重新把位置发给腾讯一次。
        """
        with self._connect() as conn:
            row = conn.execute(
                "SELECT address FROM geocode_cache WHERE coord_key = ?",
                (coord_key,),
            ).fetchone()
        if row is None:
            return None
        try:
            data = json.loads(row["address"])
        except (TypeError, ValueError):
            # 旧数据损坏就当作没有，让调用方重新解析 —— 不要因为一条脏记录报错
            return None
        return data if isinstance(data, dict) else None

    def save_geocode(self, coord_key: str, address: dict[str, Any]) -> None:
        """写入/覆盖一条地址缓存。"""
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO geocode_cache (coord_key, address, created_at)
                VALUES (?, ?, ?)
                ON CONFLICT(coord_key) DO UPDATE SET
                    address = excluded.address,
                    created_at = excluded.created_at
                """,
                (coord_key, json.dumps(address, ensure_ascii=False),
                 datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
            )
