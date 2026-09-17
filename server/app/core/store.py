"""SQLite 存储层。

选型理由：个人自用量级，SQLite 零运维、单文件、易备份。
所有写入使用参数化查询防止注入。
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

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
        """批量写入行程（按 trip_id 幂等）。"""
        if not trips:
            return 0

        rows = [
            (
                t.get("tripId"),
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
            for t in trips
        ]

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

    def save_snapshot(self, status: dict[str, Any]) -> None:
        """保存一条状态快照，用于回溯电量变化。"""
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO snapshots (vin, soc, range_km, odometer_km, payload)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    status.get("vin"),
                    status.get("soc"),
                    status.get("rangeKm"),
                    status.get("odometerKm"),
                    json.dumps(status, ensure_ascii=False),
                ),
            )

    def list_snapshots(self, vin: str, limit: int = 200) -> list[dict[str, Any]]:
        """查询状态快照。"""
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT soc, range_km, odometer_km, created_at
                FROM snapshots
                WHERE vin = ?
                ORDER BY created_at DESC
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
