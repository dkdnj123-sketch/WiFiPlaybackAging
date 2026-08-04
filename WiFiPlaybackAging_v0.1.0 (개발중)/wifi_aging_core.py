"""
wifi_aging_core.py (WiFi Playback Aging - 네트워크 계층 코어)
=========================
TC "WiFi Performance & Stability Verification / WiFi Playback Aging"의 네트워크 부분만
담당한다. 이 도구가 하는 일과 하지 않는 일을 명확히 구분한다.

  하는 일:
    1. 등록된 4대 중 1대(loader)에서만 adb shell로 iperf3 **TCP** 클라이언트를 반복 실행해
       Laptop(PC) 쪽 iperf3 서버로 지속 부하를 보낸다 (TC 4번: "Send iPerf (TCP) packet").
    2. 4대 전부의 adb 연결 상태를 감시한다. 끊김→재연결 소요시간으로
       "빠른 재연결(AP 로밍/채널변경 등으로 추정)"과 "재부팅 의심"을 구분해 기록한다
       (TC 마지막 줄: "AP 채널 변경 후 자동 재연결되어야 한다"의 근거 로그).

  하지 않는 일 (의도적으로 범위 밖):
    - 영상 재생 정상 여부 판정. STB 화면에 adb로 접근하는 코드가 전혀 없다
      (screencap/dumpsys 등 일체 없음 — 사용자 요청: "최대한 연결된 셋탑박스의 안정성을
      해치지 않는 방법으로"). 재생 판정은 외부 HDMI 캡처 영상을 FrameCheck(VL_LearnCheck)로
      분석해서 얻고, 이 도구의 네트워크 이슈 로그와는 RCA_Reporter가 시간축으로 합친다.
    - 연결 상태 확인도 로컬 `adb devices`(호스트 쪽 조회, 기기에 아무 명령도 보내지 않음)를
      기본으로 쓰고, 재연결 시도(`adb connect`)만 기기와 통신한다 — NetworkStatusCheck보다도
      더 가벼운 zero-touch에 가까운 방식.

설정은 CLI 인자 대신 JSON 설정 파일 하나로 받는다(기기 4대 + 역할 + 포트 등 항목이 많아
길게 나열하는 것보다 안전).

사용법:
  python wifi_aging_core.py <config.json> [scheduleId]
"""

import csv
import os
import re
import subprocess
import sys
import threading
import time
import json
from datetime import datetime

# ================================================================
# 상수 (iperf3-NetSentry의 검증된 재연결/재부팅 감지 로직을 그대로 재사용)
# ================================================================
RECONNECT_WAIT_SEC = 5
RECONNECT_WAIT_MAX_SEC = 30
MAX_RECONNECT_TRIES = 10
ADB_RESTART_COOLDOWN_SEC = 60
ENCODING = "utf-8"

# 이 시간 미만에 재연결되면 "빠른 재연결"(AP 로밍/채널변경 등 정상 동작으로 추정),
# 이상이면 "재부팅 의심"으로 분류한다. TC가 요구하는 "채널 변경 후 자동 재연결"은
# 보통 수 초 내에 끝나므로, 재부팅(수십 초~분 단위 부팅 시간)과 자연히 구분된다.
RECONNECT_FAST_THRESHOLD_SEC_DEFAULT = 30

# 순수 연결감시(observer) 스레드의 폴링 주기 — adb devices만 조회하므로 짧아도 부담 없음
WATCH_POLL_SEC = 5

FLUSH_INTERVAL_SEC = 5
MIN_RETRY_INTERVAL_SEC = 3

# STB 안정성 보호 — loader 1대에서만 도는 iperf3 TCP 클라이언트 실행 주기
STB_IPERF_RUN_SEC = 60
STB_IPERF_REST_SEC = 5
STB_IPERF_NICE = 10

# TCP 이슈 판정 — UDP처럼 손실률/지터를 직접 못 주므로(TCP는 재전송으로 스스로 복구)
# 재전송(Retr) 급증과 구간 처리량 저하를 대리 지표로 쓴다.
RETR_WARN_COUNT_DEFAULT = 50       # 한 구간(-i 1)의 Retr 수가 이 값 이상이면 이슈
STALL_MBPS_DEFAULT = 1.0           # 구간 처리량이 이 값(Mbps) 미만이면 정체 이슈

print_lock = threading.Lock()
status_lock = threading.Lock()


def get_pc_ip(peer_ip: str) -> str:
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((peer_ip, 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def now_str(fmt="%Y%m%d_%H%M%S"):
    return datetime.now().strftime(fmt)


def log(msg, session_log_path=None, tag="INFO", device_tag=None):
    prefix = f"[{device_tag}] " if device_tag else ""
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{tag}] {prefix}{msg}"
    try:
        with print_lock:
            print(line, flush=True)
    except Exception:
        pass
    if session_log_path:
        try:
            with open(session_log_path, "a", encoding=ENCODING) as f:
                f.write(line + "\n")
        except Exception:
            pass


def emit_status(payload):
    try:
        with print_lock:
            sys.stdout.write("STATUS|" + json.dumps(payload, ensure_ascii=False) + "\n")
            sys.stdout.flush()
    except Exception:
        pass


def safe_ip_str(ip):
    return ip.replace(".", "_").replace(":", "_")


# ================================================================
# ADB 연결 관리 — 호스트 쪽 조회(adb devices)는 기기에 아무 명령도 보내지 않는다.
# 재연결(adb connect)만 기기와 통신하며, 그 외 getprop/shell 명령은 전혀 쓰지 않는다.
# ================================================================
def adb_is_connected(ip):
    try:
        result = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=10)
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1] == "device":
                serial = parts[0]
                if serial == ip or serial.split(":")[0] == ip:
                    return True
    except Exception:
        pass
    return False


def adb_connect(ip):
    try:
        subprocess.run(["adb", "connect", ip], capture_output=True, timeout=10)
        time.sleep(3)
        return adb_is_connected(ip)
    except Exception:
        return False


def adb_restart_server():
    try:
        subprocess.run(["adb", "kill-server"], capture_output=True, timeout=10)
        time.sleep(2)
        subprocess.run(["adb", "start-server"], capture_output=True, timeout=10)
        time.sleep(2)
    except Exception:
        pass


def adb_server_healthy():
    try:
        result = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=10)
        return result.returncode == 0
    except Exception:
        return False


_adb_restart_lock = threading.Lock()
_adb_last_restart = [0.0]


def maybe_restart_adb_server(session_log, device_tag):
    if adb_server_healthy():
        return
    with _adb_restart_lock:
        if time.time() - _adb_last_restart[0] < ADB_RESTART_COOLDOWN_SEC:
            return
        _adb_last_restart[0] = time.time()
    log("adb 서버가 응답하지 않아 재시작합니다 (다른 수집의 연결도 잠시 끊겼다가 자동 복구됩니다)",
        session_log, "WARN", device_tag)
    adb_restart_server()


def ensure_connected(ip, session_log, reconnect_stats, device_tag, fast_threshold_sec, outdir,
                      role, stop_event=None):
    """연결 확인 → 끊겨 있으면 성공하거나 stop_event까지 계속 재연결 시도.
    재연결 소요시간으로 '빠른 재연결(AP 로밍/채널변경 추정)' vs '재부팅 의심'을 구분한다."""
    if adb_is_connected(ip):
        return True

    disconnect_time = datetime.now()
    log(f"연결 끊김 감지 ({disconnect_time.strftime('%H:%M:%S')})", session_log, "WARN", device_tag)

    attempt = 0
    while not (stop_event is not None and stop_event.is_set()):
        attempt += 1
        if attempt <= MAX_RECONNECT_TRIES or attempt % 10 == 0:
            log(f"재연결 {attempt}회 시도...", session_log, "RECONNECT", device_tag)
        if attempt % MAX_RECONNECT_TRIES == 0:
            maybe_restart_adb_server(session_log, device_tag)

        if adb_connect(ip):
            reconnect_time = datetime.now()
            elapsed = (reconnect_time - disconnect_time).total_seconds()
            is_fast = elapsed < fast_threshold_sec
            kind = "빠른 재연결(AP 로밍/채널변경 추정)" if is_fast else "재부팅 의심"
            reconnect_stats["count"] += 1
            event = {
                "index": reconnect_stats["count"],
                "disconnect_at": disconnect_time.strftime("%Y-%m-%d %H:%M:%S"),
                "reconnect_at": reconnect_time.strftime("%Y-%m-%d %H:%M:%S"),
                "elapsed_sec": round(elapsed, 1),
                "kind": kind,
            }
            reconnect_stats["events"].append(event)
            log(f"★ {kind} (끊김: {event['disconnect_at']} / 복구: {event['reconnect_at']} / "
                f"소요: {event['elapsed_sec']}초) [누적 {reconnect_stats['count']}회]",
                session_log, "RECONNECT" if is_fast else "REBOOT", device_tag)
            write_issue_csv(outdir, {
                "timestamp": reconnect_time.strftime("%Y-%m-%d %H:%M:%S"),
                "device": device_tag, "role": role, "types": kind,
                "mbps": "", "retr": "", "elapsed_sec": event["elapsed_sec"],
                "result_file": "", "detail": f"끊김 {event['disconnect_at']} → 복구 {event['reconnect_at']}",
            })
            return True

        wait_sec = min(RECONNECT_WAIT_SEC * attempt, RECONNECT_WAIT_MAX_SEC)
        if stop_event is not None:
            stop_event.wait(wait_sec)
        else:
            time.sleep(wait_sec)

    log("종료 요청으로 재연결 시도를 중단합니다.", session_log, "INFO", device_tag)
    return False


# ================================================================
# 파일 분할 저장 (iperf3-NetSentry와 동일: 바이너리 직접 기록)
# ================================================================
class LogFileWriter:
    def __init__(self, outdir, split_mode, split_value):
        self.outdir = outdir
        self.device_prefix = os.path.basename(outdir)
        self.split_mode = split_mode
        self.max_bytes = split_value * 1024 * 1024 if split_mode == "size" else None
        self.max_seconds = split_value * 60 if split_mode == "time" else None
        self.file_index = 0
        self.written = 0
        self.opened_at = None
        self.last_flush = 0
        self._f = None
        self._path = None
        self._open_next()

    def _open_next(self):
        if self._f:
            self._f.flush()
            self._f.close()
        self.file_index += 1
        self.written = 0
        self.opened_at = time.time()
        self.last_flush = self.opened_at
        fname = f"{self.device_prefix}_{now_str()}_part{self.file_index:04d}.txt"
        self._path = os.path.join(self.outdir, fname)
        self._f = open(self._path, "wb")
        with print_lock:
            print(f"\n[파일 생성] {fname}", flush=True)

    def _should_rotate(self, incoming_len):
        if self.written == 0:
            return False
        if self.split_mode == "size":
            return self.written + incoming_len > self.max_bytes
        return (time.time() - self.opened_at) >= self.max_seconds

    def write_line_bytes(self, data):
        if self._should_rotate(len(data)):
            self._open_next()
        self._f.write(data)
        self.written += len(data)
        now = time.time()
        if now - self.last_flush >= FLUSH_INTERVAL_SEC:
            self._f.flush()
            self.last_flush = now

    def flush(self):
        if self._f:
            self._f.flush()

    def close(self):
        if self._f:
            self._f.flush()
            self._f.close()
            self._f = None

    @property
    def current_path(self):
        return self._path


# ================================================================
# PID 파일
# ================================================================
pid_file_lock = threading.Lock()


def write_pid_file(save_dir, schedule_id, pids):
    if not schedule_id:
        return
    try:
        run_dir = os.path.join(save_dir, "_run")
        os.makedirs(run_dir, exist_ok=True)
        path = os.path.join(run_dir, f"{schedule_id}.pid.json")
        with pid_file_lock:
            existing = {}
            if os.path.exists(path):
                try:
                    with open(path, "r", encoding=ENCODING) as f:
                        existing = json.load(f)
                except Exception:
                    existing = {}
            existing.update(pids)
            with open(path, "w", encoding=ENCODING) as f:
                json.dump(existing, f)
    except Exception:
        pass


# ================================================================
# 이슈 로그 CSV (재전송 급증 / 처리량 정체 / 재연결·재부팅 이벤트)
# ================================================================
ISSUE_CSV_COLUMNS = [
    "timestamp", "device", "role", "types", "mbps", "retr", "elapsed_sec",
    "result_file", "detail",
]
issue_csv_lock = threading.Lock()


def write_issue_csv(outdir, row):
    try:
        path = os.path.join(outdir, "wifi_aging_issues.csv")
        with issue_csv_lock:
            is_new = not os.path.exists(path)
            with open(path, "a", newline="", encoding="utf-8-sig") as f:
                w = csv.DictWriter(f, fieldnames=ISSUE_CSV_COLUMNS)
                if is_new:
                    w.writeheader()
                w.writerow(row)
    except Exception:
        pass


# ================================================================
# STB 쪽 iperf3 바이너리 탐색 (loader 전용)
# ================================================================
def stb_iperf_prefix():
    return (
        f"IPERF3=''; "
        f"for p in /data/local/tmp/iperf3 /system/bin/iperf3 /vendor/bin/iperf3; do "
        f"  if [ -f \"$p\" ]; then IPERF3=$p; break; fi; "
        f"done; "
        f"if [ -z \"$IPERF3\" ]; then echo 'LOG_ERR: STB_FILE_NOT_FOUND'; exit 1; fi; "
        f"case \"$IPERF3\" in /data/local/tmp/*) chmod 755 \"$IPERF3\" 2>/dev/null;; esac; "
        f"FF='--forceflush'; \"$IPERF3\" --forceflush -v >/dev/null 2>&1 || FF=''; "
    )


def cleanup_remote_iperf(ip):
    try:
        subprocess.run(["adb", "-s", ip, "shell", "pkill -f '[i]perf3'"],
                        capture_output=True, timeout=10)
    except Exception:
        pass


# ================================================================
# PC iperf3 서버
# ================================================================
def start_pc_server(pc_exe, port, session_log):
    if not pc_exe or not os.path.exists(pc_exe):
        log(f"[서버] PC 실행파일이 없어 서버 없이 진행합니다: {pc_exe}", session_log, "WARN")
        return None
    proc = subprocess.Popen([pc_exe, "-s", "-p", str(port)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log(f"[서버] PC iperf3 서버 가동 (Port {port}, PID {proc.pid})", session_log, "INFO")
    return proc


# ================================================================
# loader: STB 1대에서만 iperf3 TCP 클라이언트를 반복 실행 (TC 4번)
# ================================================================
TCP_LINE_RE = re.compile(r'([\d.]+)\s+Mbits/sec\s+(\d+)')


def stream_iperf_tcp(ip, port, pc_exe, bandwidth_mbps, outdir, split_mode, split_value,
                      stop_event, device_tag, schedule_id, cfg, pc_ip, shared_status):
    reconnect_stats = {"count": 0, "events": []}
    session_dir = os.path.join(outdir, "session_logs")
    os.makedirs(session_dir, exist_ok=True)
    session_log = os.path.join(session_dir, f"{device_tag}_{now_str()}.log")

    fast_th = cfg.get("reconnect_fast_threshold_sec", RECONNECT_FAST_THRESHOLD_SEC_DEFAULT)
    retr_warn = cfg.get("retr_warn_count", RETR_WARN_COUNT_DEFAULT)
    stall_mbps = cfg.get("stall_mbps", STALL_MBPS_DEFAULT)

    def check_connected():
        return ensure_connected(ip, session_log, reconnect_stats, device_tag, fast_th,
                                 outdir, "loader(TCP)", stop_event)

    unit = "MB" if split_mode == "size" else "분"
    bw_desc = f"{bandwidth_mbps}M 제한" if bandwidth_mbps else "무제한(최대처리량)"
    log(f"TCP 부하 시작 | 대상: {ip}:{port} | 대역폭: {bw_desc} | 저장: {outdir} | "
        f"분할: {split_value}{unit} ({split_mode})", session_log, "INFO", device_tag)

    if not check_connected():
        log("초기 연결 실패. 부하 발생을 종료합니다.", session_log, "ERROR", device_tag)
        return

    writer = LogFileWriter(outdir, split_mode, split_value)
    target_ip = pc_ip or get_pc_ip(ip)
    bw_opt = f"-b {bandwidth_mbps}M " if bandwidth_mbps else ""

    while not stop_event.is_set():
        client_pid = None
        try:
            cleanup_remote_iperf(ip)
            inner = (
                stb_iperf_prefix() +
                f"while true; do "
                f"  nice -n {STB_IPERF_NICE} \"$IPERF3\" -c {target_ip} -p {port} {bw_opt}"
                f"-t {STB_IPERF_RUN_SEC} -i 1 --format m $FF; "
                f"  if [ $? -ne 0 ]; then echo 'LOG_ERR: TEST_INTERRUPTED'; fi; "
                f"  sleep {STB_IPERF_REST_SEC}; "
                f"done"
            )
            proc = subprocess.Popen(["adb", "-s", ip, "shell", inner],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            client_pid = proc.pid
            write_pid_file(outdir, schedule_id, {"loader_client_pid": client_pid})

            got_any_line = False
            start_time = time.time()
            for raw_line in proc.stdout:
                if stop_event.is_set():
                    break
                line_b = raw_line.strip()
                if not line_b:
                    continue
                got_any_line = True
                writer.write_line_bytes(line_b + b"\n")

                if b"Mbits/sec" in line_b:
                    line = line_b.decode(ENCODING, errors="replace")
                    m = TCP_LINE_RE.search(line)
                    if m:
                        mbps_val, retr_val = float(m.group(1)), int(m.group(2))
                        status = (f"✅ {mbps_val} Mbps | Retr {retr_val} | "
                                  f"{os.path.basename(writer.current_path or '')}")
                        with status_lock:
                            shared_status[ip] = {**shared_status.get(ip, {}), "mbps": mbps_val, "retr": retr_val}
                        issues = []
                        if retr_val >= retr_warn:
                            issues.append(("재전송급증", f"Retr {retr_val} >= 기준 {retr_warn}"))
                        if mbps_val < stall_mbps:
                            issues.append(("처리량정체", f"측정 {mbps_val}Mbps < 기준 {stall_mbps}Mbps"))
                        if issues:
                            kinds = "/".join(k for k, _ in issues)
                            detail = "; ".join(d for _, d in issues)
                            log(f"이슈 감지 [{kinds}]: {detail}", session_log, "ISSUE", device_tag)
                            write_issue_csv(outdir, {
                                "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                                "device": device_tag, "role": "loader(TCP)", "types": kinds,
                                "mbps": mbps_val, "retr": retr_val, "elapsed_sec": "",
                                "result_file": os.path.basename(writer.current_path or ""),
                                "detail": detail,
                            })
                    else:
                        status = line.strip()
                    with print_lock:
                        print(f"[{device_tag}] {status}", flush=True)
                elif b"LOG_ERR" in line_b or b"error" in line_b.lower() or b"not found" in line_b.lower():
                    line = line_b.decode(ENCODING, errors="replace")
                    with print_lock:
                        print(f"[{device_tag}] ⚠️ {line.strip()}", flush=True)
                    log(line, session_log, "WARN", device_tag)

            try:
                proc.wait(timeout=5)
            except Exception:
                pass
            elapsed = time.time() - start_time
            writer.flush()

            if stop_event.is_set():
                break
            if not got_any_line and elapsed < 5:
                log("STB에서 응답이 없습니다. 연결 상태를 확인합니다.", session_log, "WARN", device_tag)
            if not check_connected():
                break
            if elapsed < MIN_RETRY_INTERVAL_SEC:
                stop_event.wait(MIN_RETRY_INTERVAL_SEC - elapsed)

        except Exception as e:
            log(f"예외 발생: {e}", session_log, "ERROR", device_tag)
            if not check_connected():
                break
            stop_event.wait(MIN_RETRY_INTERVAL_SEC)
        finally:
            try:
                if client_pid:
                    subprocess.run(["taskkill", "/f", "/pid", str(client_pid), "/t"],
                                    capture_output=True, timeout=5)
            except Exception:
                pass

    writer.close()
    log("TCP 부하 발생 종료.", session_log, "INFO", device_tag)


# ================================================================
# observer: iperf 없이 adb 연결 상태만 감시 (zero-touch)
# ================================================================
def watch_connection_only(ip, outdir, stop_event, device_tag, cfg):
    session_dir = os.path.join(outdir, "session_logs")
    os.makedirs(session_dir, exist_ok=True)
    session_log = os.path.join(session_dir, f"{device_tag}_{now_str()}_watch.log")
    reconnect_stats = {"count": 0, "events": []}
    fast_th = cfg.get("reconnect_fast_threshold_sec", RECONNECT_FAST_THRESHOLD_SEC_DEFAULT)

    log("연결 감시 시작 (adb devices만 조회, 기기에 명령을 보내지 않음)",
        session_log, "INFO", device_tag)

    while not stop_event.is_set():
        if not adb_is_connected(ip):
            ensure_connected(ip, session_log, reconnect_stats, device_tag, fast_th,
                              outdir, "observer", stop_event)
        stop_event.wait(WATCH_POLL_SEC)

    log("연결 감시 종료.", session_log, "INFO", device_tag)


# ================================================================
# 상태 보고 스레드 (GUI STATUS|json 폴링용)
# ================================================================
def status_reporter(devices, loader_ip, shared_status, stop_event, interval_sec=2):
    while not stop_event.is_set():
        for ip in devices:
            connected = adb_is_connected(ip)
            with status_lock:
                extra = shared_status.get(ip, {})
            emit_status({
                "ip": ip,
                "role": "loader(TCP)" if ip == loader_ip else "observer",
                "connected": connected,
                "mbps": extra.get("mbps"),
                "retr": extra.get("retr"),
                "ts": datetime.now().strftime("%H:%M:%S"),
            })
        stop_event.wait(interval_sec)


# ================================================================
# 진입점
# ================================================================
def load_config(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def main():
    os.system("chcp 65001 >nul")
    if len(sys.argv) < 2:
        print("사용법: python wifi_aging_core.py <config.json> [scheduleId]")
        sys.exit(1)

    cfg = load_config(sys.argv[1])
    schedule_id = sys.argv[2] if len(sys.argv) > 2 else None

    devices = cfg["devices"]
    loader_ip = cfg["loader_ip"]
    port = cfg["port"]
    pc_exe = cfg["pc_exe"]
    save_dir = cfg["save_dir"]
    bandwidth_mbps = cfg.get("bandwidth_mbps") or ""
    split_mode = cfg.get("split_mode", "time")
    split_value = cfg.get("split_value", 60)

    if loader_ip not in devices:
        print(f"[오류] loader_ip({loader_ip})가 devices 목록에 없습니다.")
        sys.exit(1)

    os.makedirs(save_dir, exist_ok=True)
    boot_session_dir = os.path.join(save_dir, "session_logs")
    os.makedirs(boot_session_dir, exist_ok=True)
    boot_log = os.path.join(boot_session_dir, "boot.log")

    pc_ip = get_pc_ip(loader_ip)
    log(f"PC IP 자동 감지: {pc_ip} | 기기 {len(devices)}대 (loader: {loader_ip})", boot_log)

    server_proc = start_pc_server(pc_exe, port, boot_log)
    write_pid_file(save_dir, schedule_id, {"server_pid": server_proc.pid if server_proc else None})
    time.sleep(1.0)

    stop_event = threading.Event()
    shared_status = {}
    threads = []

    loader_outdir = os.path.join(save_dir, f"loader_{safe_ip_str(loader_ip)}")
    os.makedirs(loader_outdir, exist_ok=True)
    t_loader = threading.Thread(
        target=stream_iperf_tcp,
        args=(loader_ip, port, pc_exe, bandwidth_mbps, loader_outdir, split_mode, split_value,
              stop_event, loader_ip, schedule_id, cfg, pc_ip, shared_status),
        daemon=True,
    )
    threads.append(t_loader)
    t_loader.start()

    for ip in devices:
        if ip == loader_ip:
            continue
        obs_outdir = os.path.join(save_dir, f"observer_{safe_ip_str(ip)}")
        os.makedirs(obs_outdir, exist_ok=True)
        t = threading.Thread(target=watch_connection_only, args=(ip, obs_outdir, stop_event, ip, cfg),
                              daemon=True)
        threads.append(t)
        t.start()
        time.sleep(0.3)

    t_status = threading.Thread(target=status_reporter, args=(devices, loader_ip, shared_status, stop_event),
                                 daemon=True)
    t_status.start()

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        stop_event.set()
    finally:
        stop_event.set()
        if server_proc:
            try:
                server_proc.kill()
            except Exception:
                pass


if __name__ == "__main__":
    main()
