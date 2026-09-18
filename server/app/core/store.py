"""SQLite 存储层。

选型理由：个人自用量级，SQLite 零运维、单文件、易备份。
所有写入使用参数化查询防止注入。
"""

from __future__ import annotations

import json
import logging
import sqlite3
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
"""


class Store:
    """数据存储。"""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        # WAL 模式提升并发读性能
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def _init_schema(self) -> None:
        with self._connect() as conn:
            conn.executescript(SCHEMA)

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
            conn.executemany(
                """
                INSERT OR IGNORE INTO charge_records
                    (record_id, timestamp, amount, energy_kwh, provider,
                     channel, merchant, station, unit_price, order_no)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
        return len(rows)

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
