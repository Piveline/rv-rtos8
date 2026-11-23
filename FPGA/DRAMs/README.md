Piveline 메모리 팀 작업 : [rv-rtos8 — BRAM] 구조를 [캐시 + DDR3] 구조로 바꾸기 위한 메모리 경로(SmartConnect + MIG + DDR3) 설계와 검증

## 진도 요약

| # | 진도 | 작업 날짜 | 결과 |
| --- | --- | --- | --- |
| 1 | 구조 분석과 개념 정리 | 10.29 ~ 10.30 | 메모리 그룹 작업 범위 확정 |
| 2 | Vivado 개발 환경 구성 | 11.3 | 보드 파일 적용, 실험용 프로젝트 생성 |
| 3 | MIG 7-series DDR3 설정 | 11.4 ~ 11.5 | MIG IP 생성 |
| 4 | 메모리 Block Design 구성 | 11.7 ~ 11.8 | SmartConnect + MIG + 클럭 + 리셋 + 주소 맵 |
| 5 | Validate 오류 수정과 포트 확정 | 11.10 | Validate 통과, AXI 64비트 포트 확정 |
| 6 | 검증 방향 변경과 시뮬레이션 준비 | 11.11 | iverilog 대신 Vivado 시뮬레이션, DDR3 모델 확보 |
| 7 | 테스트벤치 작성과 시뮬레이션 통과 | 11.13 ~ 11.14 | TEST PASSED, 읽기 지연 56사이클 |
| 8 | 검증 결과 정리와 통합 준비 | 11.16 | 통합 시 변경 사항 정리 |

---------------------------------------------

## 1. 기존 구조 분석과 개념 정리

- 작업 날짜: 10.29 ~ 10.30
- 내용
  - 기존 구조: 8단계 파이프라인 코어가 BRAM을 1사이클로 직접 접근하는 구조
  - 바꿀 구조: 코어 → I-cache / D-cache → AXI4 → SmartConnect → MIG → DDR3
  - 필요한 개념 정리: AXI4(채널 5개, VALID/READY 핸드셰이크, burst), MIG(AXI를 DDR3 명령으로 바꾸고 보정 수행), SmartConnect(여러 마스터 중재, 클럭 도메인 변환)
  - (캐시 = AXI 마스터, 메모리 = AXI 슬레이브)

## 2. Vivado 개발 환경 구성

- 작업 날짜: 11.3
- 내용
  - Vivado 설치, 라이선스 확인
  - Nexys Video 보드 파일 설치 (XDC로 핀을 직접 잡는 대신 보드 파일로 MIG와 클럭 핀을 자동 지정)
  - 실험용 프로젝트 `project_exp_1` 생성 (보드: Nexys Video)
  - 팀 저장소 `FPGA/Piveline.xpr`는 수정X, 실험은 별도 프로젝트에서 진행

## 3. MIG 7-series DDR3 설정

- 작업 날짜:11.4 ~ 11.5
- 내용
  - MIG 7-series IP 생성, 보드의 DDR3 칩 MT41K256M16에 맞춤
  - DDR3 클럭 400MHz, 4:1 비율로 사용자 클럭 `ui_clk` 100MHz
  - AXI4 인터페이스: 데이터 64비트, 주소 29비트(512MB), ORDERING Strict
  - Data Mask 사용, Internal Vref
  - System Clock은 No Buffer로 변경 (팀의 `clk_wiz_0`과 같은 보드 클럭 핀을 쓰지 않도록)
  - Pin Selection Validate 통과

## 4. 메모리 Block Design 구성

- 작업 날짜:11.7 ~ 11.8
- 내용
  - Block Design `design_1` 구성
    - SmartConnect: 입력 2개(S00 = I-cache, S01 = D-cache), 출력 1개(MIG)
    - Clocking Wizard: 보드 100MHz로 `clk_out1` 100MHz, `clk_out2` 200MHz 생성
    - Processor System Reset 2개: `rst_cpu`(100MHz 쪽), `rst_mig`(`ui_clk` 쪽)
  - 클럭 연결
    - `clk_out1` 100MHz → SmartConnect `aclk`, MIG `sys_clk_i`, `rst_cpu`, `cpu_clk` 포트
    - `clk_out2` 200MHz → MIG `clk_ref_i` (IDELAYCTRL 기준 클럭)
    - MIG `ui_clk` → SmartConnect `aclk1`, `rst_mig`, MIG AXI 포트
  - 주소 맵: DDR3를 0x8000_0000 ~ 0x9FFF_FFFF (512MB)에 배치, S00과 S01 모두 같은 영역
  - S00, S01을 외부 AXI 포트(`S00_AXI_0`, `S01_AXI_0`)로 꺼냄

## 5. Validate 오류 수정과 포트 확정

- 작업 날짜:11.10
- 내용
  - 문제 1: 외부 AXI 포트에 클럭이 연결되지 않아 Validate에서 critical warning 4건 발생
    - 해결: `cpu_clk` 클럭 포트를 만들고 `ASSOCIATED_BUSIF`로 S00, S01에 연결
      ```tcl
      create_bd_port -dir O -type clk cpu_clk
      connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_ports cpu_clk]
      set_property CONFIG.ASSOCIATED_BUSIF {S00_AXI_0:S01_AXI_0} [get_bd_ports cpu_clk]
      ```
  - 문제 2: 외부 AXI 포트의 데이터 폭이 기본값 32비트로 잡혀 있음 (wrapper에서 확인)
    - 해결: 두 포트를 64비트로 변경
      ```tcl
      set_property CONFIG.DATA_WIDTH {64} [get_bd_intf_ports S00_AXI_0]
      set_property CONFIG.DATA_WIDTH {64} [get_bd_intf_ports S01_AXI_0]
      ```
  - Validate 통과, HDL wrapper(`design_1_wrapper.v`) 생성
  - 확정된 외부 인터페이스
    - AXI4 포트 2개: 주소 32비트, 데이터 64비트
    - 그 외 포트: `sys_clock`, `reset`, `cpu_clk`, `init_calib_complete_0`, `ddr3_sdram_*`


## 6. 검증 방향 변경과 시뮬레이션 준비

- 작업 날짜:11.11
- 내용
  - 회의 결정: 남은 단계는 3단계(시뮬레이션 검증)와 4단계(보드 검증). IP화 방향으로 통합
  - MIG의 Open IP Example Design으로 예제 프로젝트(`mig_exp_1_ex`) 생성
  - 예제에서 시뮬레이션용 DDR3 칩 모델 확보: `ddr3_model.sv`, `ddr3_model_parameters.vh` (x16, 4Gb, 보드 칩과 같은 규격)
  - MIG 시뮬레이션 설정 확인: `SIMULATION = "TRUE"`, `SIM_BYPASS_INIT_CAL = "FAST"` (보정 시간 단축)

## 7. 테스트벤치 작성과 시뮬레이션 통과

- 작업 날짜: 11.13 ~ 11.14
- 내용
  - 테스트벤치 `tb_design_1.v` 작성: 캐시 대신 AXI 주문을 내고 응답을 자동 비교
    - 구성: 테스트벤치(가짜 캐시) → `design_1_wrapper`(검증 대상) → `ddr3_model`
  - 검사 항목과 결과 (모두 통과, ERROR 0건)

    | # | 검사 | 결과 |
    | --- | --- | --- |
    | 1 | DDR3 보정 | 106,664ns에 `init_calib_complete` = 1, 이후 계속 유지 |
    | 2 | S01 4-beat 쓰기 후 읽기 (0x8000_0000) | 4개 값 모두 일치, bresp OKAY, `rlast` 정확 |
    | 3 | S01 부분 쓰기 (`wstrb` = 0x0F) | `11111111ccccdddd`, 하위 4바이트만 변경 |
    | 4 | S00으로 S01이 쓴 주소 읽기 | 4개 값 모두 일치, 두 포트가 같은 DDR3 공유 |
    | 5 | 읽기 지연 | S00, S01 모두 56사이클(100MHz 기준 약 560ns) |

## 8. 검증 결과 정리와 통합 준비

- 작업 날짜:11.16
- 내용
  - 검증 결과 문서 작성 (변화, 구성, 검사 항목, 측정값, 남은 과제)
  - 연구용 첫 비교 수치: BRAM 1사이클 대비 DDR3 읽기 56사이클, 캐시 미스 한 번에 약 60사이클
  - 통합 때 바꿀 것
    - Block Design 안의 Clocking Wizard를 빼고, 100MHz와 200MHz 클럭을 입력 포트로 받기
    - 팀 `clk_wiz_0`에 200MHz 출력 추가
    - 클럭 위자드 `locked`로 리셋 해제
    - `init_calib_complete`를 플립플롭 2단으로 동기화해 보정이 끝날 때까지 CPU를 리셋 상태로 유지
    - 코어와 캐시가 쓰는 클럭을 확인해 SmartConnect `aclk`에 맞추기
  - 아직 확인하지 않은 것: S00/S01 동시 접근, 연속 주문과 리프레시, 쓰기 지연, 실제 보드에서의 보정·타이밍·자원 사용량
--------------------------------------------------

## 저장소에 올린 파일 (`FPGA/DRAMs/`)

| 파일 | 역할 |
| --- | --- |
| `bd/design_1.tcl` | 메모리 Block Design 재생성 스크립트 (Vivado 2025.2) |
| `bd/mig_b.prj` | MIG 설정 원본 (`design_1.tcl` 안에도 같은 내용이 들어 있음, 백업용) |
| `sim/tb_design_1.v` | 시뮬레이션 테스트벤치 |
| `sim/ddr3_model.sv`, `sim/ddr3_model_parameters.vh` | 시뮬레이션용 Micron DDR3 칩 모델 (MIG 예제 디자인에서 가져옴) |
| `docs/MIG_setting_log.xlsx` | MIG 설정값 기록 |
| `README.md` | 이 문서 |

Vivado 생성 파일(`.gen`, `.runs`, `.sim`, `.cache`, `.Xil`, `*.jou`, `*.log`)은 올리지 않음.

## 재현 방법

필요 조건: Vivado 2025.2, Nexys Video 보드 파일 설치 (`design_1.tcl`이 보드 인터페이스를 사용함)

1. Vivado에서 보드를 Nexys Video로 지정해 새 프로젝트를 만든다. (프로젝트를 열지 않고 `source`하면 tcl이 `myproj/project_1`을 Nexys Video 보드로 자동 생성한다.)
2. Tcl Console에서 `source FPGA/DRAMs/bd/design_1.tcl`을 실행해 Block Design을 만든다.
3. Validate Design 후 `design_1`을 우클릭해 Create HDL Wrapper를 실행한다.
4. Simulation Sources에 `sim/` 폴더의 세 파일을 추가하고 `tb_design_1`을 top으로 둔다.
5. Run Behavioral Simulation을 실행하고 Tcl Console에서 `=== TEST PASSED ===`를 확인한다. (시뮬레이션 시간 약 110µs)

## 기존 프로젝트(SoCs)에 붙일 때

- 팀 프로젝트 `FPGA/SoCs/Piveline.xpr`는 보드가 지정되지 않은 상태(part만 xc7a200tsbg484-1)이므로, `source` 전에 Settings → General → Project device에서 보드를 Nexys Video로 지정해야 한다. part가 같아 기존 설계에는 영향이 없다.
- 통합 시에는 Block Design 안의 Clocking Wizard를 빼고, 100MHz와 200MHz 클럭을 외부(팀 `clk_wiz_0`)에서 입력 포트로 받는다. (8번 항목 참고)
