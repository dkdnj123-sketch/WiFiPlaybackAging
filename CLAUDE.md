# WiFiPlaybackAging

TC "WiFi Performance & Stability Verification / WiFi Playback Aging"(4대 STB, 48H)의
**네트워크 계층만** 검증하는 독립 도구. 전체 V-Audit Agent 제품군 공통 규칙은 상위 폴더의
`../CLAUDE.md` 참고.

## TC 원문과 이 도구의 역할 분담

```
1. Connect STB #1~#4 at AP #1
2. Set Laptop#1 as iperf server
3. Connect ADB with STB #1
4. Send iPerf (TCP) packet to Laptop #1
5. Check All 4 STBs's playback is normal (during 48H)
기대 동작: AP 채널 변경 후 STB WiFi가 자동으로 재연결되어야 한다.
```

- **1~4번, 기대 동작** → 이 도구(WiFiPlaybackAging)가 담당.
- **5번(재생 정상 여부)** → 이 도구는 **전혀 담당하지 않는다.** 별도로 HDMI 등 외부 캡처로
  녹화한 영상을 `VL_LearnCheck/FrameCheck`로 분석해서 판정한다.
- 두 도구의 로그(이 도구의 `wifi_aging_issues.csv` + FrameCheck의 프레임에러 CSV)를
  시간축으로 합쳐 보고 싶으면 `RCA_Reporter`를 쓴다.

## 설계 결정: Zero-touch (2026-08-04, 사용자 요청 반영)

기존 `iperf3-NetSentry`(UDP 부하 발생)를 참고해 만들었지만, 이 TC는 UDP가 아니라
**TCP** 부하를 요구하고, 4대 중 **1대(loader)만** 부하를 발생시키며 나머지는 공유 AP
간섭 상태에서 재생만 관찰하는 구조다. 또한 사용자가 "최대한 연결된 셋탑박스의 안정성을
해치지 않는 방법으로" 만들어달라고 명시적으로 요청했다.

이에 따라 이 도구는 다른 자매 프로젝트(NetworkStatusCheck 등)보다도 더 가볍게 동작한다:

- **재생 화면에 아예 접근하지 않는다.** `wifi_aging_core.py`에 adb screencap, dumpsys 등
  화면/재생 관련 명령이 전혀 없다(의도적 설계, 우회가 아님).
- **연결 상태 확인도 `adb devices`(호스트 쪽 조회, 기기에 아무 명령도 보내지 않음)만 쓴다.**
  NetworkStatusCheck처럼 getprop/ping/top/meminfo를 주기적으로 쏘지 않는다. 재연결이
  필요할 때(`adb connect`)만 기기와 통신한다.
- iperf3 TCP 클라이언트도 loader 1대에서만 돈다. 나머지 3대(observer)는 순수 연결 감시만
  하는 스레드가 붙는다(`watch_connection_only`).

## 재부팅 vs AP 채널변경 재연결 구분

`ensure_connected()`가 끊김→재연결 소요시간을 측정해 분류한다(`reconnect_fast_threshold_sec`,
기본 30초, iperf3-NetSentry의 `REBOOT_THRESHOLD_SEC`와 동일 관례):

- 임계치 미만 → "빠른 재연결(AP 로밍/채널변경 등으로 추정)" — TC의 "기대 동작" 검증 근거
- 임계치 이상 → "재부팅 의심"

AP 채널 변경 자체는 테스터가 수동으로 트리거하는 TC 스텝이라, 이 도구는 그 이벤트를 직접
발생시키지 않고 그 시점 전후의 재연결 로그만 남긴다.

## TCP 이슈 판정 (UDP와 다름)

iperf3-NetSentry(UDP)는 손실률/지터로 이슈를 판정했지만, TCP는 재전송으로 스스로 복구하므로
같은 지표가 없다. 대신:

- `retr_warn_count` (기본 50): 한 구간(-i 1)의 Retr(재전송) 수가 이 값 이상이면 "재전송급증"
- `stall_mbps` (기본 1.0): 구간 처리량이 이 값 미만이면 "처리량정체"

두 값 모두 설정 다이얼로그에서 조정 가능. `bandwidth_mbps`를 비워두면 iperf3가 TCP 최대
처리량으로 보낸다(TC가 특정 목표 대역폭을 요구하지 않으므로 기본값).

## 구성

```
WiFiPlaybackAging/
├── CLAUDE.md
└── WiFiPlaybackAging_v0.1.0 (개발중)/     # 최초 버전, 아직 실기기 검증 전
    ├── WiFiPlaybackAging.ps1              # GUI (NetworkStatusCheck.ps1 패턴 재사용)
    ├── wifi_aging_core.py                 # 코어 (iperf3-NetSentry 패턴을 TCP/멀티기기로 변형)
    ├── WiFiPlaybackAging_run.bat / _run_hidden.vbs
    ├── device_config.json                 # 기기 목록 + loader_ip (GUI "기기 관리"에서 편집)
    ├── WiFiPlaybackAging_settings.json    # 포트/PC iperf 경로/저장경로/임계값
    └── iperf/iperf3.exe (+ cygwin dll 3종) # iperf3-NetSentry에서 복사한 PC용 바이너리
```

- `device_config.json`은 기기 IP 목록과 그중 어느 것이 loader(TCP 부하 발생)인지만 담는다.
  GUI가 시작할 때 이 파일 + 설정을 합쳐 `_runtime_config.json`(런타임 임시 파일, 매 실행마다
  덮어씀)을 만들어 파이썬 코어에 통째로 넘긴다 — CLI 인자를 길게 나열하지 않기 위함.

## 상태 (2026-08-04)

- Python 코어: `python -m py_compile` 통과 + 가짜 IP(192.0.2.x)로 기동 스모크 테스트 완료
  (PC 서버 기동, loader/observer 스레드 분리 기동, STATUS|json 출력, 재연결 루프 정상 확인).
- PowerShell GUI: `[System.Management.Automation.Language.Parser]::ParseFile` 문법 검증 통과.
- **아직 실기기(STB) 4대로는 검증하지 않음.** 실기기 테스트 시 주의: iperf3-NetSentry가 이미
  라이브 48h 테스트 중일 수 있는 기기를 건드리지 않도록, 다른 기기/포트로 먼저 병행 검증할 것
  (관련 원칙은 `../CLAUDE.md`가 아니라 사용자 메모리의 "안전한 실기기 테스트 기법" 참고).
- git: `dkdnj123-sketch/WiFiPlaybackAging` (신규 repo, public), branch `master`, 초기 커밋 push 완료.
