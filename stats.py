"""本机连接事件采集与 SQLite 查询，仅使用 Python 标准库"""
import argparse
from contextlib import closing
import datetime as dt
import http.client
import ipaddress
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import socket
import sqlite3
import struct
import subprocess
import sys
import threading
import tempfile
import time
import unicodedata

MAX_FRAME = 4 * 1024 * 1024
STATS_VERSION = "1.3.8"
OWNER = "singbox-local-stats-v1"
API_TAG = "singbox-local-stats-api"
RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
CYAN = "\033[0;36m"
BLUE = "\033[1;36m"
NC = "\033[0m"
MENU_WIDTH = 39
ANSI_COLOR = re.compile(r"\033\[[0-9;]*m")
SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY,v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS nodes(tag TEXT PRIMARY KEY,name TEXT,protocol TEXT);
CREATE TABLE IF NOT EXISTS flows(id TEXT PRIMARY KEY,node TEXT,target TEXT,kind TEXT,
 up INTEGER,down INTEGER,created INTEGER,closed INTEGER,counted INTEGER);
CREATE TABLE IF NOT EXISTS daily(day TEXT,node TEXT,target TEXT,kind TEXT,
 up INTEGER NOT NULL,down INTEGER NOT NULL,count INTEGER NOT NULL,
 PRIMARY KEY(day,node,target,kind));
CREATE TABLE IF NOT EXISTS totals(node TEXT,target TEXT,kind TEXT,
 up INTEGER NOT NULL,down INTEGER NOT NULL,count INTEGER NOT NULL,
 PRIMARY KEY(node,target,kind));
"""


def read_json(path):
    path = Path(path)
    if path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("配置文件过大")
    return json.loads(path.read_text(encoding="utf-8"))


def database(directory, readonly=False):
    path = Path(directory).resolve() / "traffic.db"
    if path.is_symlink():
        raise ValueError("统计数据库不能是符号链接")
    if readonly:
        return sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5)
    connection = sqlite3.connect(path, timeout=5)
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=FULL")
    connection.execute("PRAGMA cache_size=-2048")
    connection.execute("PRAGMA journal_size_limit=4194304")
    connection.executescript(SCHEMA)
    connection.execute("PRAGMA user_version=1")
    os.chmod(path, 0o600)
    return connection


def meta_get(db, key, default=""):
    row = db.execute("SELECT v FROM meta WHERE k=?", (key,)).fetchone()
    return row[0] if row else default


def meta_set(db, key, value):
    db.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", (key, str(value)))


def initialize(directory, reset=False):
    with closing(database(directory)) as db:
        if reset:
            for table in ("flows", "daily", "totals", "meta"):
                db.execute("DELETE FROM " + table)
        if not meta_get(db, "started"):
            meta_set(db, "started", int(time.time() * 1000))
        meta_set(db, "status", "已停止")
        db.commit()


# 仅解码官方 ConnectionEvents 使用的 protobuf 字段，未知字段按 wire type 跳过
def varint(data, position=0):
    value = 0
    for shift in range(0, 70, 7):
        if position >= len(data):
            raise ValueError("连接事件不完整")
        byte = data[position]
        position += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, position
    raise ValueError("连接事件整数无效")


def fields(data):
    position = 0
    while position < len(data):
        key, position = varint(data, position)
        number, wire = key >> 3, key & 7
        if number == 0:
            raise ValueError("连接事件字段无效")
        if wire == 0:
            value, position = varint(data, position)
        elif wire in (1, 2, 5):
            size = 8 if wire == 1 else 4
            if wire == 2:
                size, position = varint(data, position)
            if size > len(data) - position:
                raise ValueError("连接事件长度无效")
            value = data[position:position + size]
            position += size
        else:
            raise ValueError("连接事件编码不受支持")
        yield number, value


def encode_varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def rpc_connection(settings, method, payload=b""):
    connection = http.client.HTTPConnection("127.0.0.1", int(settings["port"]), timeout=10)
    frame = b"\0" + struct.pack(">I", len(payload)) + payload
    connection.request("POST", "/daemon.StartedService/" + method, body=frame, headers={
        "Content-Type": "application/grpc-web+proto", "X-Grpc-Web": "1",
        "Authorization": "Bearer " + settings["secret"]})
    response = connection.getresponse()
    if response.status != 200:
        connection.close()
        raise OSError("统计接口返回 HTTP " + str(response.status))
    return connection, response


def exact_read(response, size):
    content = bytearray()
    while len(content) < size:
        piece = response.read(size - len(content))
        if not piece:
            raise EOFError("统计接口连接结束")
        content.extend(piece)
    return bytes(content)


def frames(response):
    while True:
        header = exact_read(response, 5)
        size = struct.unpack(">I", header[1:])[0]
        if size > MAX_FRAME:
            raise ValueError("统计事件超过长度限制")
        payload = exact_read(response, size)
        if header[0] == 128:
            text = payload.decode("ascii", "replace")
            if "grpc-status: 0" not in text:
                raise OSError("统计接口认证失败或不支持连接事件")
            return
        if header[0] != 0:
            raise ValueError("统计接口返回了不支持的压缩事件")
        yield payload


def text(value):
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


def clean(value, limit=253):
    return "".join(c for c in str(value) if not unicodedata.category(c).startswith("C"))[:limit]


def target_of(connection):
    domain = clean(text(connection.get(8, b""))).lower().rstrip(".")
    destination = text(connection.get(7, b""))
    host = domain or destination.rsplit(":", 1)[0].strip("[]")
    host = clean(host).lower().rstrip(".") or "未知目标"
    try:
        return str(ipaddress.ip_address(host)), "IP"
    except ValueError:
        return host, "域名" if host != "未知目标" else "未知"


class Ledger:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.settings = read_json(self.directory / "settings.json")
        self.db = database(directory)
        self.started = int(meta_get(self.db, "started", int(time.time() * 1000)))
        self.cutoff = int(meta_get(self.db, "last_flush", self.started))
        self.resume = bool(self.settings.get("resume")) and str(self.settings["resume"]) != meta_get(self.db, "resume")
        self.batch = 0
        self.last_commit = time.monotonic()
        self.last_cleanup = 0
        self.known = {}
        self.load_nodes()

    def load_nodes(self):
        self.known = {r[0]: (r[1], r[2]) for r in self.db.execute("SELECT * FROM nodes")}
        for node in read_json(self.settings["meta_file"]).get("nodes", []):
            tag = node.get("tag", "")
            if tag:
                name = clean(node.get("name", tag), 80)
                protocol = node.get("protocol", "vless-reality")
                self.known[tag] = (name, protocol)
                self.db.execute("INSERT OR REPLACE INTO nodes VALUES(?,?,?)", (tag, name, protocol))

    def add(self, row, up, down, moment, count):
        if not (up or down or count):
            return
        day = dt.datetime.fromtimestamp(moment / 1000).date().isoformat()
        node, target, kind = row[1:4]
        self.db.execute("""INSERT INTO daily VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(day,node,target,kind) DO UPDATE SET
            up=up+excluded.up,down=down+excluded.down,count=count+excluded.count""",
            (day, node, target, kind, up, down, count))
        self.db.execute("""INSERT INTO totals VALUES(?,?,?,?,?,?)
            ON CONFLICT(node,target,kind) DO UPDATE SET
            up=up+excluded.up,down=down+excluded.down,count=count+excluded.count""",
            (node, target, kind, up, down, count))

    def connection(self, connection, snapshot=False):
        ident = text(connection.get(1, b""))
        tag = text(connection.get(2, b""))
        if not ident or not tag:
            return
        if tag not in self.known:
            self.load_nodes()
        if tag not in self.known:
            return
        up, down = int(connection.get(16, 0)), int(connection.get(17, 0))
        created, closed = int(connection.get(12, 0)), int(connection.get(13, 0))
        old = self.db.execute("SELECT * FROM flows WHERE id=?", (ident,)).fetchone()
        target, kind = target_of(connection)
        row = (ident, tag, target, kind, up, down, created, closed, 0)
        seed = snapshot and (self.resume or (old is None and (created < self.started or (closed and closed <= self.cutoff))))
        if seed:
            counted = old[8] if old else 0
        else:
            delta_up = max(0, up - (old[4] if old else 0))
            delta_down = max(0, down - (old[5] if old else 0))
            counted = old[8] if old else 0
            first = int(not counted and bool(delta_up or delta_down))
            self.add(row, delta_up, delta_down, closed or int(time.time() * 1000), first)
            counted |= first
        self.db.execute("INSERT OR REPLACE INTO flows VALUES(?,?,?,?,?,?,?,?,?)", row[:8] + (counted,))

    def event_batch(self, content):
        decoded = list(fields(content))
        snapshot = any(n == 2 and v for n, v in decoded)
        for number, content in decoded:
            if number != 1:
                continue
            event = dict(fields(content))
            kind = int(event.get(1, 0))
            connection = dict(fields(event[3])) if 3 in event else None
            if connection is not None:
                if kind == 2 and 13 not in connection:
                    connection[13] = event.get(6, int(time.time() * 1000))
                self.connection(connection, snapshot)
            elif kind == 1:
                ident = text(event.get(2, b""))
                row = self.db.execute("SELECT * FROM flows WHERE id=?", (ident,)).fetchone()
                if row:
                    up, down = int(event.get(4, 0)), int(event.get(5, 0))
                    if up > 2**63 - 1 or down > 2**63 - 1:
                        raise ValueError("连接流量计数无效")
                    first = int(not row[8] and bool(up or down))
                    self.add(row, up, down, int(time.time() * 1000), first)
                    self.db.execute("UPDATE flows SET up=up+?,down=down+?,counted=? WHERE id=?",
                                    (up, down, row[8] | first, ident))
        if snapshot and self.resume:
            self.resume = False
            meta_set(self.db, "resume", self.settings["resume"])
        self.batch += 1
        meta_set(self.db, "last_event", int(time.time() * 1000))
        meta_set(self.db, "status", "采集中")
        self.flush()

    def flush(self, force=False):
        if not force and self.batch < 1000 and time.monotonic() - self.last_commit < 5:
            return
        now = int(time.time() * 1000)
        self.load_nodes()
        if not self.last_cleanup or time.monotonic() - self.last_cleanup > 86400:
            cutoff = (dt.date.today() - dt.timedelta(days=365)).isoformat()
            self.db.execute("DELETE FROM daily WHERE day<?", (cutoff,))
            self.db.execute("DELETE FROM flows WHERE closed>0 AND closed<?", (now - 86400000,))
            self.last_cleanup = time.monotonic()
        meta_set(self.db, "last_flush", now)
        self.db.commit()
        self.batch = 0
        self.last_commit = time.monotonic()


def write_settings(directory, settings):
    path = Path(directory) / "settings.json"
    temp = path.with_suffix(".tmp")
    if path.is_symlink() or temp.is_symlink():
        raise ValueError("统计配置不能是符号链接")
    with temp.open("w", encoding="utf-8") as handle:
        json.dump(settings, handle, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temp, 0o600)
    temp.replace(path)


def daemon(directory):
    import fcntl
    directory = Path(directory).resolve()
    lock = os.open(directory / "collector.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise ValueError("流量采集实例已在运行")
    pid_file = directory / "collector.pid"
    if pid_file.is_symlink():
        raise ValueError("统计 PID 文件不能是符号链接")
    pid_file.write_text(str(os.getpid()), encoding="ascii")
    stop = threading.Event()
    messages = queue.Queue(maxsize=8)
    active = [None]

    def terminate(_signal, _frame):
        stop.set()
        connection = active[0]
        if connection and connection.sock:
            try:
                connection.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)

    def send(item):
        while not stop.is_set():
            try:
                messages.put(item, timeout=0.5)
                return
            except queue.Full:
                pass

    def reader():
        while not stop.is_set():
            connection = None
            try:
                settings = read_json(directory / "settings.json")
                connection, response = rpc_connection(settings, "SubscribeConnections", b"\x08" + encode_varint(1_000_000_000))
                active[0] = connection
                if connection.sock:
                    connection.sock.settimeout(None)
                for payload in frames(response):
                    if stop.is_set():
                        break
                    send(("event", payload))
                if not stop.is_set():
                    raise EOFError("统计连接已关闭")
            except (OSError, EOFError, ValueError, http.client.HTTPException) as error:
                if not stop.is_set():
                    send(("error", clean(error, 160)))
                    stop.wait(3)
            finally:
                if connection:
                    connection.close()
                active[0] = None

    ledger = Ledger(directory)
    meta_set(ledger.db, "version", STATS_VERSION)
    worker = threading.Thread(target=reader, daemon=True)
    worker.start()
    try:
        while not stop.is_set():
            try:
                kind, value = messages.get(timeout=1)
                if kind == "event":
                    ledger.event_batch(value)
                else:
                    meta_set(ledger.db, "status", "等待核心连接")
                    meta_set(ledger.db, "last_error", value)
                    meta_set(ledger.db, "interruptions", int(meta_get(ledger.db, "interruptions", "0")) + 1)
                    ledger.flush(True)
            except queue.Empty:
                ledger.flush()
    finally:
        terminate(0, None)
        worker.join(timeout=3)
        try:
            while not messages.empty():
                kind, value = messages.get_nowait()
                if kind == "event":
                    ledger.event_batch(value)
            meta_set(ledger.db, "status", "已停止")
            ledger.flush(True)
        finally:
            ledger.db.close()
            if pid_file.exists() and pid_file.read_text() == str(os.getpid()):
                pid_file.unlink()
            os.close(lock)


def human(value):
    number = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if number < 1024 or unit == "TB":
            return f"{number:.2f} {unit}"
        number /= 1024


def character_width(char):
    if unicodedata.combining(char) or unicodedata.category(char).startswith("C"):
        return 0
    return 2 if unicodedata.east_asian_width(char) in "WF" else 1


def display_width(value):
    # 与主菜单一样按显示列补齐，不依赖服务器是否配置 UTF-8 locale
    return sum(character_width(char) for char in ANSI_COLOR.sub("", str(value)))


def aligned(value, width):
    result = ""
    count = 0
    for char in clean(value):
        size = character_width(char)
        if count + size > width:
            break
        result += char
        count += size
    return result + " " * (width - count)


def clear_terminal():
    if sys.stdout.isatty():
        print("\033[3J\033[2J\033[H\033[0m", end="")


def menu_row(value):
    padding = " " * max(0, MENU_WIDTH - display_width(value))
    print(f"  {BLUE}║{value}{padding}{BLUE}║{NC}")


def menu_frame(title, sections, details=()):
    print(f"\n{BLUE}  ╔{'═' * MENU_WIDTH}╗{NC}")
    menu_row(f"    {BLUE}{title}{NC}")
    for label, value in details:
        menu_row(f"    {BLUE}{label}：{GREEN}{value}{NC}")
    print(f"{BLUE}  ╠{'═' * MENU_WIDTH}╣{NC}")
    for index, (heading, options) in enumerate(sections):
        if index:
            menu_row("")
        if heading:
            menu_row(f"  {BLUE}{heading}{NC}")
        for number, label in options:
            menu_row(f"  {GREEN}[{number}]{BLUE}  {label}{NC}")
    menu_row("")
    menu_row(f"  {GREEN}[0]{BLUE}  返回{NC}")
    print(f"{BLUE}  ╚{'═' * MENU_WIDTH}╝{NC}\n")


def result_field(label, value):
    prefix = f"  {BLUE}{aligned(label, 8)}：{NC} "
    indent = display_width(prefix)
    width = max(1, shutil.get_terminal_size((80, 24)).columns - indent)
    lines, current, count = [], "", 0
    for char in str(value):
        size = character_width(char)
        if count + size > width and current:
            lines.append(current)
            current, count = "", 0
        current += char
        count += size
    lines.append(current)
    for index, line in enumerate(lines):
        print(f"{prefix if index == 0 else ' ' * indent}{GREEN}{line}{NC}")


def print_traffic_rows(rows, columns):
    # 窄终端改用纵向明细，避免流量列折行后与域名错位
    if columns < 64:
        for target, up, down in rows:
            result_field("域名/IP", target)
            for label, value in (("上传流量", up), ("下载流量", down), ("合计流量", up + down)):
                result_field(label, human(value))
            print()
        return
    target_width = min(40, columns - 44)
    headers = aligned("域名/IP", target_width) + "".join(aligned(label, 14) for label in ("上传流量", "下载流量", "合计流量"))
    print(f"  {BLUE}{headers}{NC}")
    for target, up, down in rows:
        values = "".join(aligned(human(value), 14) for value in (up, down, up + down))
        print(f"  {GREEN}{aligned(target, target_width)}{values}{NC}")


def available_nodes(directory, db):
    settings = read_json(Path(directory) / "settings.json")
    current = read_json(settings["meta_file"])["nodes"]
    result = [(n["tag"], n["name"], n.get("protocol", "vless-reality")) for n in current]
    seen = {n[0] for n in result}
    result.extend((tag, name + "（已删除）", protocol) for tag, name, protocol in
                  db.execute("SELECT * FROM nodes ORDER BY name,tag") if tag not in seen)
    return result


def query_data(directory, args):
    with closing(database(directory, True)) as db:
        nodes = available_nodes(directory, db)
        if args.command == "nodes":
            settings = read_json(Path(directory) / "settings.json")
            ports = {node["tag"]: node.get("port") for node in read_json(settings["meta_file"])["nodes"]}
            for index, (tag, name, protocol) in enumerate(nodes, 1):
                protocol = "Vless" if protocol == "vless-reality" else clean(protocol)
                port = ports.get(tag)
                suffix = f" @ {BLUE}{clean(port)}{NC}" if port is not None else ""
                print(f"  {GREEN}[{index}]{NC} {clean(name, 80)} ({protocol}){suffix}{NC}")
            return
        today = dt.date.today()
        starts = {"today": today, "yesterday": today - dt.timedelta(days=1),
                  "month": today.replace(day=1), "30d": today - dt.timedelta(days=29)}
        begin = starts.get(args.period)
        end = today - dt.timedelta(days=1) if args.period == "yesterday" else today
        if args.period == "custom":
            if not args.start or not args.end:
                raise ValueError("自定义日期需要 --start 和 --end")
            begin, end = dt.date.fromisoformat(args.start), dt.date.fromisoformat(args.end)
        if begin and begin > end:
            raise ValueError("开始日期不能晚于结束日期")
        clauses, params = [], []
        if args.node:
            if args.node.isdecimal():
                index = int(args.node) - 1
                if index < 0 or index >= len(nodes):
                    raise ValueError("节点序号无效")
                tag = nodes[index][0]
            else:
                tag = next((tag for tag, name, _ in nodes if args.node in (tag, name)), "")
                if not tag:
                    raise ValueError("节点不存在")
            clauses.append("node=?")
            params.append(tag)
        if args.target:
            target = clean(args.target).lower().rstrip(".")
            clauses.append("(target=? OR target LIKE ? ESCAPE '\\')")
            escaped = target.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            params.extend((target, "%." + escaped))
        table = "totals" if args.period == "all" else "daily"
        if begin:
            clauses.extend(("day>=?", "day<=?"))
            params.extend((begin.isoformat(), end.isoformat()))
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        summary = db.execute("SELECT coalesce(sum(up),0),coalesce(sum(down),0),coalesce(sum(count),0) FROM " + table + where, params).fetchone()
        names = {"today": "今日", "yesterday": "昨日", "month": "本月", "30d": "最近 30 天", "all": "全部累计", "custom": "自定义日期"}
        message("信息", "=== 流量统计 ===")
        print()
        result_field("统计范围", names[args.period] + (f"（{begin} 至 {end}）" if begin else ""))
        started = int(meta_get(db, "started", "0"))
        result_field("开始记录", dt.datetime.fromtimestamp(started / 1000).strftime("%Y-%m-%d %H:%M:%S"))
        result_field("最近保存", dt.datetime.fromtimestamp(int(meta_get(db, "last_flush", "0")) / 1000).strftime("%Y-%m-%d %H:%M:%S"))
        for label, value in (("上传流量", human(summary[0])), ("下载流量", human(summary[1])),
                             ("合计流量", human(summary[0] + summary[1])), ("连接数量", str(summary[2]))):
            result_field(label, value)
        print()
        rows = db.execute("SELECT target,sum(up),sum(down) FROM " + table + where +
                          " GROUP BY target ORDER BY sum(up)+sum(down) DESC,target LIMIT ?", params + [args.limit]).fetchall()
        print_traffic_rows(rows, shutil.get_terminal_size((80, 24)).columns)
        if not rows:
            message("信息", "暂无统计记录")
        print()
        message("信息", "按域名/IP 汇总，最多显示 " + str(args.limit) + " 项")
        if int(meta_get(db, "interruptions", "0")):
            message("信息", "采集曾中断，记录可能存在缺口")


def api_service(settings):
    return {"type": "api", "tag": API_TAG, "listen": "127.0.0.1", "listen_port": settings["port"],
            "secret": settings["secret"], "dashboard": False}


def sniff_rule(metadata):
    tags = sorted(n["tag"] for n in metadata.get("nodes", []) if n.get("tag"))
    return {"inbound": tags, "action": "sniff", "sniffer": ["http", "tls", "quic"]} if tags else None


def prepare_config(settings, current, candidate, old_meta, new_meta, action="normal"):
    # 只替换本模块拥有的 API 和精确匹配的嗅探规则，保留用户的其他设置
    expected = api_service(settings)
    existing = [s for s in current.get("services", []) if s.get("tag") == API_TAG]
    if existing and existing != [expected]:
        raise ValueError("统计 API 已被外部修改，未覆盖配置")
    if settings.get("enabled") and not existing:
        raise ValueError("统计 API 缺失，请先停止统计或恢复配置")
    services = candidate.get("services", [])
    if any(s.get("tag") == API_TAG and s != expected for s in services):
        raise ValueError("统计 API 标识被其他服务使用")
    candidate["services"] = [s for s in services if s.get("tag") != API_TAG]
    if action != "disable":
        candidate["services"].append(expected)
    if not candidate["services"] and "services" not in settings.get("original_keys", []):
        del candidate["services"]
    old_rule = sniff_rule(old_meta)
    rules = candidate.get("route", {}).get("rules", [])
    if old_rule:
        count = rules.count(old_rule)
        if count > 1 or (existing and settings.get("enabled") and count != 1):
            raise ValueError("统计域名识别规则已被外部修改，未覆盖配置")
        # 未安装本模块时，用户即使有相同规则也不属于本模块
        if existing:
            rules = [r for r in rules if r != old_rule]
        elif count:
            raise ValueError("已有相同域名识别规则，请先移除冲突规则再开启统计")
    new_rule = sniff_rule(new_meta) if action != "disable" else None
    if new_rule:
        candidate.setdefault("route", {})["rules"] = [new_rule] + rules
    elif "route" in candidate:
        candidate["route"]["rules"] = rules
        if not rules and not settings.get("original_rules", False):
            del candidate["route"]["rules"]
        if not candidate["route"] and "route" not in settings.get("original_keys", []):
            del candidate["route"]
    return candidate


class Cancelled(Exception):
    pass


class EndOfInput(Exception):
    pass


def prompt(question):
    try:
        result = input("  " + NC + question).strip()
    except EOFError:
        raise EndOfInput()
    if result.lower() == "q":
        raise Cancelled()
    return result


def message(kind, value, file=None):
    colors = {"信息": CYAN, "成功": GREEN, "错误": RED, "注意": YELLOW}
    print("  " + colors[kind] + "[" + kind + "] " + clean(value, 240) + NC, file=file, flush=True)


class Management:
    def __init__(self, directory):
        if Path(directory).is_symlink():
            raise ValueError("统计目录不能是符号链接")
        self.directory = Path(directory).resolve()
        self.program = Path(__file__).resolve()
        self.context = json.loads(os.environ.get("SINGBOX_STATS_CONTEXT", "{}"))
        self.settings_path = self.directory / "settings.json"
        self.owner_path = self.directory / ".owner"
        self.systemd = Path(self.context.get("STATS_SYSTEMD_UNIT", "/etc/systemd/system/singbox-stats.service"))
        self.openrc = Path(self.context.get("STATS_OPENRC_UNIT", "/etc/init.d/singbox-stats"))
        self.log = Path(self.context.get("STATS_LOG_FILE", "/var/log/singbox-stats.log"))
        self.init = self.context.get("INIT_SYSTEM", "direct")

    def settings(self):
        if not self.owner_path.is_file() or self.owner_path.is_symlink() or self.owner_path.read_text().strip() != OWNER:
            raise ValueError("无法确认统计目录归属")
        if self.settings_path.is_symlink():
            raise ValueError("统计配置不能是符号链接")
        result = read_json(self.settings_path)
        if result.get("owner") != OWNER:
            raise ValueError("统计配置归属无效")
        return result

    def pid(self):
        try:
            path = self.directory / "collector.pid"
            if path.is_symlink():
                return 0
            pid = int(path.read_text())
            if pid < 2:
                return 0
            os.kill(pid, 0)
            args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            expected = [os.fsencode(self.program), b"daemon", os.fsencode(self.directory)]
            return pid if all(value in args for value in expected) else 0
        except (OSError, ValueError):
            return 0

    def state(self):
        if self.pid():
            try:
                with closing(database(self.directory, True)) as db:
                    status = meta_get(db, "status")
                if status in ("采集中", "等待核心连接"):
                    return status
            except (OSError, ValueError, sqlite3.Error):
                pass
            return "启动中"
        if not self.settings_path.exists():
            return "未开启"
        try:
            settings = self.settings()
            if settings.get("enabled"):
                return "未启动"
            config_path = self.context.get("CONFIG_FILE", settings.get("context", {}).get("CONFIG_FILE"))
            if config_path and any(v.get("tag") == API_TAG for v in read_json(config_path).get("services", [])):
                return "待恢复"
            return "已停止"
        except (OSError, ValueError):
            return "配置异常"

    def run(self, args):
        return subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True).returncode == 0

    def check_units(self):
        for path in (self.systemd, self.openrc):
            if not path.exists() and not path.is_symlink():
                continue
            if path.is_symlink() or not path.is_file():
                raise ValueError("无法确认统计服务归属：" + str(path))
            contents = path.read_text()
            if "# " + OWNER not in contents or str(self.program) not in contents or str(self.directory) not in contents:
                raise ValueError("检测到外部统计服务，未覆盖：" + str(path))

    def write_units(self):
        self.check_units()
        # 服务不继承管理锁；采集失败只影响统计，不影响 sing-box 转发
        if self.init == "systemd":
            contents = "\n".join(["# " + OWNER, "[Unit]", "Description=sing-box local traffic statistics",
                "After=network.target", "[Service]", "Type=simple",
                f"ExecStart={sys.executable} {self.program} daemon {self.directory}",
                "Restart=on-failure", "RestartSec=5", "UMask=0077", "[Install]", "WantedBy=multi-user.target", ""])
            self.systemd.parent.mkdir(parents=True, exist_ok=True)
            self.systemd.write_text(contents)
            self.systemd.chmod(0o644)
            if not self.run(["systemctl", "daemon-reload"]):
                raise ValueError("统计服务管理器重新加载失败")
        elif self.init == "openrc":
            contents = "\n".join(["#!/sbin/openrc-run", "# " + OWNER,
                'description="sing-box local traffic statistics"', f'command="{sys.executable}"',
                f'command_args="{self.program} daemon {self.directory}"', 'supervisor="supervise-daemon"',
                'respawn_delay=5', f'output_log="{self.log}"', f'error_log="{self.log}"', 'depend() { use net; }', ""])
            self.openrc.parent.mkdir(parents=True, exist_ok=True)
            self.openrc.write_text(contents)
            self.openrc.chmod(0o755)
            if not self.run(["sh", "-n", str(self.openrc)]):
                raise ValueError("OpenRC 统计服务语法检查失败")

    def start(self):
        if self.pid():
            return
        self.write_units()
        if self.init == "systemd":
            okay = self.run(["systemctl", "enable", "--now", "singbox-stats"])
        elif self.init == "openrc":
            okay = self.run(["rc-update", "add", "singbox-stats", "default"]) and self.run(["rc-service", "singbox-stats", "start"])
        else:
            self.log.parent.mkdir(parents=True, exist_ok=True)
            if self.log.is_symlink():
                raise ValueError("统计日志不能是符号链接")
            with self.log.open("ab") as log:
                subprocess.Popen([sys.executable, str(self.program), "daemon", str(self.directory)],
                    stdin=subprocess.DEVNULL, stdout=log, stderr=log, close_fds=True, start_new_session=True)
            okay = True
        for _ in range(30):
            if okay and self.pid():
                return
            time.sleep(0.1)
        raise ValueError("流量采集启动失败")

    def stop(self):
        self.check_units()
        if self.init == "systemd" and self.systemd.exists():
            if not self.run(["systemctl", "stop", "singbox-stats"]):
                raise ValueError("停止统计服务失败")
            if not self.run(["systemctl", "disable", "singbox-stats"]):
                raise ValueError("关闭统计开机自启失败")
        elif self.init == "openrc" and self.openrc.exists():
            self.run(["rc-update", "del", "singbox-stats", "default"])
            if not self.run(["rc-service", "singbox-stats", "stop"]) and self.pid():
                raise ValueError("停止统计服务失败")
        pid = self.pid()
        if pid:
            os.kill(pid, signal.SIGTERM)
            for _ in range(60):
                if not self.pid():
                    return
                time.sleep(0.1)
            raise ValueError("流量采集仍在运行，未继续操作")

    def apply(self, config):
        keys = ["SINGBOX_DIR", "CONFIG_FILE", "META_FILE", "SINGBOX_BIN", "PID_FILE", "LOG_FILE",
                "SYSTEMD_UNIT", "OPENRC_UNIT", "SYSTEMD_STARTUP", "OPENRC_STARTUP", "INIT_SYSTEM"]
        values = [self.context[key] for key in keys]
        base = Path(self.context["SINGBOX_DIR"])
        candidate, metadata = None, None
        try:
            fd, name = tempfile.mkstemp(prefix=".stats-config.", dir=base)
            candidate = Path(name)
            with os.fdopen(fd, "w") as handle:
                json.dump(config, handle)
            fd, name = tempfile.mkstemp(prefix=".stats-meta.", dir=base)
            metadata = Path(name)
            with os.fdopen(fd, "w") as handle:
                json.dump(read_json(self.context["META_FILE"]), handle)
            assignments = "\n".join(f'{key}="${{{i + 2}}}"' for i, key in enumerate(keys))
            code = 'source "$1"\n' + assignments + '\napply_transaction "${13}" "${14}" "${15}"'
            count = len(read_json(self.context["META_FILE"])["nodes"])
            env = dict(os.environ, SINGBOX_STATS_TRANSACTION="1")
            result = subprocess.run(["bash", "-c", code, "stats-transaction", self.context["SCRIPT_PATH"],
                *values, str(candidate), str(metadata), str(count)], env=env, close_fds=True)
            if result.returncode:
                raise ValueError("统计配置应用失败，原配置已保留或回滚")
        finally:
            for path in (candidate, metadata):
                if path:
                    path.unlink(missing_ok=True)

    def enable(self):
        core = self.context["SINGBOX_BIN"]
        output = subprocess.check_output([core, "version"], text=True)
        version = re.search(r"sing-box version (\d+)\.(\d+)", output)
        if not version or tuple(map(int, version.groups())) < (1, 14):
            raise ValueError("本地流量统计需要 sing-box 1.14.0 或更新版本")
        if not read_json(self.context["META_FILE"])["nodes"]:
            raise ValueError("请先添加节点再开启流量统计")
        self.check_units()
        original = read_json(self.context["CONFIG_FILE"])
        metadata = read_json(self.context["META_FILE"])
        previous = self.settings() if self.settings_path.exists() else None
        existing = [v for v in original.get("services", []) if v.get("tag") == API_TAG]
        if existing:
            if not previous or existing != [api_service(previous)]:
                raise ValueError("统计 API 标识已存在且归属不匹配，未接管外部配置")
            rule = sniff_rule(metadata)
            if original.get("route", {}).get("rules", []).count(rule) != 1:
                raise ValueError("统计域名识别规则不完整，请先停止统计后重新开启")
            # 配置已应用但采集启动中断时，复用自己的接口，不检测或更换已占用的端口
            settings = dict(previous, enabled=True, context=self.context)
            if not previous.get("enabled"):
                settings["resume"] = str(time.time_ns())
                initialize(self.directory)
            write_settings(self.directory, settings)
            was_running = bool(self.pid())
            try:
                self.start()
            except BaseException:
                try:
                    if not was_running:
                        self.stop()
                finally:
                    write_settings(self.directory, previous)
                raise
            message("成功", "流量统计已开启")
            return
        if previous and previous.get("enabled"):
            raise ValueError("统计 API 缺失，请先停止统计后重新开启")
        port = int(previous["port"]) if previous else 9090
        while True:
            try:
                with socket.socket() as sock:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    sock.bind(("127.0.0.1", port))
                break
            except OSError:
                value = prompt(f"本机端口 {port} 已占用，请输入统计接口端口 (0 返回): ")
                if value == "0":
                    raise Cancelled()
                if not value.isdecimal() or not 1 <= int(value) <= 65535:
                    message("错误", "端口应为 1–65535")
                    continue
                port = int(value)
        if self.directory.is_symlink() or (self.directory.exists() and not self.owner_path.exists()):
            raise ValueError("统计目录已存在且未确认归属，未覆盖")
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.directory.chmod(0o700)
        self.owner_path.write_text(OWNER)
        secret = previous["secret"] if previous else subprocess.check_output([core, "generate", "rand", "--hex", "32"], text=True).strip()
        if not re.fullmatch(r"[0-9a-f]{64}", secret):
            raise ValueError("生成统计接口密钥失败")
        settings = dict(previous or {}, owner=OWNER, port=port, secret=secret, meta_file=self.context["META_FILE"],
                        enabled=False, resume=str(time.time_ns()), context=self.context)
        if not previous:
            settings.update(original_keys=list(original), original_rules="rules" in original.get("route", {}))
        write_settings(self.directory, settings)
        initialize(self.directory)
        candidate = prepare_config(settings, original, json.loads(json.dumps(original)), metadata, metadata, "enable")
        applied = False
        try:
            message("信息", "正在开启本地流量统计")
            self.apply(candidate)
            applied = True
            settings["enabled"] = True
            write_settings(self.directory, settings)
            self.start()
        except Exception as error:
            try:
                self.stop()
                if applied:
                    self.apply(original)
                settings["enabled"] = False
                write_settings(self.directory, previous or settings)
            except Exception as rollback_error:
                raise ValueError(f"开启失败：{error}；回滚未完成：{rollback_error}") from error
            raise
        message("成功", "流量统计已开启，本机接口不对外开放")

    def disable(self):
        settings = self.settings()
        was_running = bool(self.pid())
        self.stop()
        try:
            original = read_json(self.context["CONFIG_FILE"])
            # 关闭标志不能替代配置归属检查，失败或中断后仍可能残留本组件的接口
            if settings.get("enabled") or any(v.get("tag") == API_TAG for v in original.get("services", [])):
                metadata = read_json(self.context["META_FILE"])
                candidate = prepare_config(settings, original, json.loads(json.dumps(original)), metadata, metadata, "disable")
                self.apply(candidate)
        except Exception:
            if was_running:
                self.start()
            raise
        settings["enabled"] = False
        write_settings(self.directory, settings)
        message("成功", "流量统计已停止，历史数据已保留")

    def remove(self, full=False):
        if self.directory.exists():
            if self.owner_path.is_symlink() or not self.owner_path.is_file() or self.owner_path.read_text().strip() != OWNER:
                raise ValueError("无法确认统计目录归属，未执行删除")
            if full:
                self.stop()
            else:
                self.disable()
        else:
            self.stop()
        for unit in (self.systemd, self.openrc):
            unit.unlink(missing_ok=True)
        if self.init == "systemd":
            if not self.run(["systemctl", "daemon-reload"]):
                raise ValueError("统计服务管理器重新加载失败")
            self.run(["systemctl", "reset-failed", "singbox-stats"])
        # 不递归删除整个目录；只清理模块创建的明确文件
        for name in ("settings.json", "settings.tmp", "traffic.db", "traffic.db-wal", "traffic.db-shm",
                     "collector.lock", "collector.pid"):
            path = self.directory / name
            if path.is_dir() and not path.is_symlink():
                raise ValueError("统计文件路径被目录占用：" + str(path))
            path.unlink(missing_ok=True)
        if self.directory.exists():
            if any(path.name != ".owner" for path in self.directory.iterdir()):
                message("注意", "统计目录包含未识别文件，已保留：" + str(self.directory))
            else:
                self.owner_path.unlink(missing_ok=True)
                self.directory.rmdir()
        for path in (self.log, *self.log.parent.glob(self.log.name + ".*")):
            if path.is_file() or path.is_symlink():
                path.unlink()
        message("成功", "流量统计组件和历史数据已清理")

    def query_menu(self):
        self.settings()
        clear_terminal()
        menu_frame("流量统计查询", [("统计范围", [(1, "今日"), (2, "昨日"), (3, "本月"),
                   (4, "最近 30 天"), (5, "全部累计"), (6, "自定义日期")])])
        choice = prompt("请选择统计范围 (默认 1): ") or "1"
        if choice == "0":
            raise Cancelled()
        periods = {"1": "today", "2": "yesterday", "3": "month", "4": "30d", "5": "all", "6": "custom"}
        if choice not in periods:
            raise ValueError("无效选择")
        args = argparse.Namespace(command="query", period=periods[choice], node="", target="", limit=20, start=None, end=None)
        if choice == "6":
            args.start = prompt("开始日期 (YYYY-MM-DD): ")
            args.end = prompt("结束日期 (YYYY-MM-DD): ")
        node_args = argparse.Namespace(command="nodes")
        print()
        query_data(self.directory, node_args)
        args.node = prompt("节点序号 (回车查询全部，0 返回): ")
        if args.node == "0":
            raise Cancelled()
        print()
        query_data(self.directory, args)

    def menu(self):
        while True:
            clear_terminal()
            state = self.state()
            menu_frame("sing-box 流量统计", [
                ("查询统计", [(1, "查看统计")]),
                ("采集管理", [(2, "开启统计"), (3, "停止统计")]),
                ("数据维护", [(4, "清空统计"), (5, "卸载统计")])],
                [("采集状态", state)])
            try:
                choice = prompt("请输入选项 [0-5]: ")
                if choice == "0":
                    return
                if choice == "1":
                    self.query_menu()
                elif choice == "2":
                    self.enable()
                elif choice == "3":
                    self.disable()
                elif choice == "4":
                    self.settings()
                    if prompt("确认清空全部流量统计？(Y/N): ").lower() != "y":
                        continue
                    active = bool(self.pid())
                    self.stop()
                    initialize(self.directory, True)
                    if active:
                        self.start()
                    message("成功", "流量统计已清空")
                elif choice == "5":
                    if prompt("确认卸载统计组件并删除全部历史数据？(Y/N): ").lower() != "y":
                        continue
                    self.remove()
                else:
                    message("错误", "无效选项")
                prompt("按回车返回流量统计菜单...")
            except Cancelled:
                continue
            except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
                message("错误", str(error))
                try:
                    prompt("按回车返回流量统计菜单...")
                except Cancelled:
                    pass


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", choices=["daemon", "init", "clear", "query", "nodes", "menu", "prepare", "remove-all", "sync"])
    parser.add_argument("directory")
    parser.add_argument("period", nargs="?", default="today", choices=["today", "yesterday", "month", "30d", "all", "custom"])
    parser.add_argument("--node", default="")
    parser.add_argument("--target", default="")
    parser.add_argument("--start")
    parser.add_argument("--end")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--config")
    parser.add_argument("--metadata")
    args = parser.parse_args()
    if not 1 <= args.limit <= 1000:
        raise ValueError("显示数量应为 1–1000")
    if args.command == "menu":
        Management(args.directory).menu()
    elif args.command == "remove-all":
        Management(args.directory).remove(True)
    elif args.command == "sync":
        manager = Management(args.directory)
        settings = manager.settings()
        if settings.get("enabled"):
            with closing(database(args.directory, True)) as db:
                version = meta_get(db, "version")
            if manager.pid() and version != STATS_VERSION:
                manager.stop()
            manager.start()
    elif args.command == "prepare":
        manager = Management(args.directory)
        settings = manager.settings()
        if settings.get("enabled"):
            context = manager.context
            current = read_json(context["CONFIG_FILE"])
            candidate = prepare_config(settings, current, read_json(args.config),
                read_json(context["META_FILE"]), read_json(args.metadata))
            with open(args.config, "w", encoding="utf-8") as handle:
                json.dump(candidate, handle)
    elif args.command in ("init", "clear"):
        initialize(args.directory, args.command == "clear")
    elif args.command == "daemon":
        daemon(args.directory)
    else:
        query_data(args.directory, args)


if __name__ == "__main__":
    try:
        main()
    except (Cancelled, EndOfInput, KeyboardInterrupt):
        sys.exit(0)
    except (OSError, ValueError, sqlite3.Error, http.client.HTTPException, TypeError, KeyError, subprocess.SubprocessError) as error:
        message("错误", clean(error, 180), file=sys.stderr)
        sys.exit(1)
