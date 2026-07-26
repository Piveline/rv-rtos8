# ============================================================================
# Makefile — FreeRTOS Shell for RV64IM SoC
# ============================================================================
#
# 사전 준비:
#   1. FreeRTOS-Kernel clone:
#      git clone https://github.com/FreeRTOS/FreeRTOS-Kernel.git
#
#   2. 이 Makefile과 같은 디렉토리에 배치:
#      freertos_shell/
#      ├── FreeRTOS-Kernel/     ← git clone 결과
#      ├── crt0.S
#      ├── main_freertos.c
#      ├── mmio.h
#      ├── FreeRTOSConfig.h
#      ├── freertos_risc_v_chip_specific_extensions.h
#      ├── link.ld
#      └── Makefile
#
# [RV32→RV64] 변경 사항:
#   - PREFIX: riscv32-unknown-elf → riscv64-unknown-elf
#   - ARCH:   rv32im_zicsr → rv64im_zicsr
#   - ABI:    ilp32 → lp64
#   - hexdump: 그대로 (ROM word는 4-byte 단위, RTL $readmemh 호환)
#
# ============================================================================

# --- Toolchain ---
PREFIX  = riscv64-unknown-elf
CC      = $(PREFIX)-gcc
AS      = $(PREFIX)-gcc
OBJCOPY = $(PREFIX)-objcopy
OBJDUMP = $(PREFIX)-objdump
SIZE    = $(PREFIX)-size

# --- Architecture ---
ARCH    = rv64im_zicsr
ABI     = lp64

# --- FreeRTOS paths ---
FREERTOS_DIR   = FreeRTOS-Kernel
FREERTOS_SRC   = $(FREERTOS_DIR)/
FREERTOS_PORT  = $(FREERTOS_DIR)/portable/GCC/RISC-V/
FREERTOS_HEAP  = $(FREERTOS_DIR)/portable/MemMang/

# --- Include paths ---
INCLUDES = -I. \
           -I$(FREERTOS_DIR)/include \
           -I$(FREERTOS_PORT) \
           -Irhealstone \
           -Idhrystone \
           -Icoremark

# --- Compiler flags ---
CFLAGS  = -march=$(ARCH) -mabi=$(ABI) -Os \
          -ffreestanding -nostdlib -nostartfiles \
          -fno-builtin -ffunction-sections -fdata-sections \
          -Wall -Wextra \
          $(INCLUDES)

ASFLAGS = -march=$(ARCH) -mabi=$(ABI) -nostdlib \
          $(INCLUDES)

# --- Dhrystone/CoreMark configuration from uploaded RV64 bare-metal packages ---
DHRY_CFLAGS = -std=gnu89 -DTIMES -DNOENUM -DDHRY_ITERS=300000 -DHZ=48611110 \
              -Wno-implicit -Wno-return-type -Wno-builtin-declaration-mismatch \
              -Wno-int-to-pointer-cast -Wno-pointer-to-int-cast

COREMARK_CFLAGS = -O2 -funroll-loops \
                  -DITERATIONS=0 \
                  -DTOTAL_DATA_SIZE=2000 \
                  -DFLAGS_STR='"-O2 -march=$(ARCH) -mabi=$(ABI) -fno-common -funroll-loops"' \
                  -DPERFORMANCE_RUN=1 \
                  -Wno-unused-parameter -Wno-unused-variable -Wno-format

LDFLAGS = -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles \
          -T link.ld \
          -Wl,--gc-sections \
          -Wl,-u,freertos_risc_v_trap_handler \
          -Wl,-Map=firmware.map

# --- Source files ---
SRCS_C = main_freertos.c \
         $(FREERTOS_SRC)tasks.c \
         $(FREERTOS_SRC)queue.c \
         $(FREERTOS_SRC)list.c \
         $(FREERTOS_PORT)port.c \
         $(FREERTOS_HEAP)heap_4.c

SRCS_S = crt0.S \
         $(FREERTOS_PORT)portASM.S

# --- Object files (모두 현재 디렉토리에 생성) ---
OBJS = crt0.o \
	   nosys.o \
       main_freertos.o \
       tasks.o \
       queue.o \
       list.o \
       port.o \
       portASM.o \
       heap_4.o \
       rhealstone_task_switch.o \
       rhealstone_task_preempt.o \
       rhealstone_message_latency.o \
       rhealstone_semaphore_shuffle.o \
       rhealstone_deadlock_break.o \
       rhealstone_interrupt_latency.o \
       dhrystone_dhry_1.o \
       dhrystone_dhry_2.o \
       dhrystone_mini_libc.o \
       dhrystone_syscalls.o \
       dhrystone_strcmp.o \
       coremark_core_list_join.o \
       coremark_core_main.o \
       coremark_core_matrix.o \
       coremark_core_state.o \
       coremark_core_util.o \
       coremark_core_portme.o \
       coremark_ee_printf.o

TARGET = firmware
MEM_IMAGE = firmware_RV64.mem

# ============================================================================
# Build rules
# ============================================================================

all: $(MEM_IMAGE) $(TARGET).lst
	@echo "=== Build complete ==="
	@$(SIZE) $(TARGET).elf

# --- App sources ---
crt0.o: crt0.S
	$(AS) $(ASFLAGS) -c $< -o $@

nosys.o: nosys.c
	$(CC) $(CFLAGS) -c $< -o $@

main_freertos.o: main_freertos.c mmio.h FreeRTOSConfig.h
	$(CC) $(CFLAGS) -c $< -o $@

# --- FreeRTOS kernel ---
tasks.o: $(FREERTOS_SRC)tasks.c
	$(CC) $(CFLAGS) -c $< -o $@

queue.o: $(FREERTOS_SRC)queue.c
	$(CC) $(CFLAGS) -c $< -o $@

list.o: $(FREERTOS_SRC)list.c
	$(CC) $(CFLAGS) -c $< -o $@

# --- FreeRTOS RISC-V port ---
port.o: $(FREERTOS_PORT)port.c
	$(CC) $(CFLAGS) -c $< -o $@

portASM.o: $(FREERTOS_PORT)portASM.S
	$(AS) $(ASFLAGS) -c $< -o $@

# --- Heap ---
heap_4.o: $(FREERTOS_HEAP)heap_4.c
	$(CC) $(CFLAGS) -c $< -o $@

# --- Rhealstone benchmarks ---
rhealstone_task_switch.o: rhealstone/task_switch_freertos.c rhealstone/rhealstone_io.h
	$(CC) $(CFLAGS) -c $< -o $@

rhealstone_task_preempt.o: rhealstone/task_preempt_freertos.c rhealstone/rhealstone_io.h
	$(CC) $(CFLAGS) -c $< -o $@

rhealstone_message_latency.o: rhealstone/message_latency_freertos.c rhealstone/rhealstone_io.h
	$(CC) $(CFLAGS) -c $< -o $@

rhealstone_semaphore_shuffle.o: rhealstone/semaphore_shuffle_freertos.c rhealstone/rhealstone_io.h
	$(CC) $(CFLAGS) -c $< -o $@

rhealstone_deadlock_break.o: rhealstone/deadlock_break_freertos.c rhealstone/rhealstone_io.h
	$(CC) $(CFLAGS) -c $< -o $@

rhealstone_interrupt_latency.o: rhealstone/interrupt_latency_freertos.c rhealstone/rhealstone_io.h
	$(CC) $(CFLAGS) -c $< -o $@

# --- RV64 Dhrystone 2.1 ---
dhrystone_dhry_1.o: dhrystone/dhry_1.c dhrystone/dhry.h dhrystone/sys/times.h
	$(CC) $(CFLAGS) $(DHRY_CFLAGS) -Dmain=dhrystone_run -c $< -o $@

dhrystone_dhry_2.o: dhrystone/dhry_2.c dhrystone/dhry.h
	$(CC) $(CFLAGS) $(DHRY_CFLAGS) -c $< -o $@

dhrystone_mini_libc.o: dhrystone/mini_libc.c
	$(CC) $(CFLAGS) -c $< -o $@

dhrystone_syscalls.o: dhrystone/syscalls.c dhrystone/sys/times.h
	$(CC) $(CFLAGS) $(DHRY_CFLAGS) -c $< -o $@

dhrystone_strcmp.o: dhrystone/strcmp.S
	$(AS) $(ASFLAGS) -c $< -o $@

# --- RV64 CoreMark ---
coremark_core_list_join.o: coremark/core_list_join.c coremark/coremark.h coremark/core_portme.h
	$(CC) $(CFLAGS) $(COREMARK_CFLAGS) -c $< -o $@

coremark_core_main.o: coremark/core_main.c coremark/coremark.h coremark/core_portme.h
	$(CC) $(CFLAGS) $(COREMARK_CFLAGS) -Dmain=coremark_run -c $< -o $@

coremark_core_matrix.o: coremark/core_matrix.c coremark/coremark.h coremark/core_portme.h
	$(CC) $(CFLAGS) $(COREMARK_CFLAGS) -c $< -o $@

coremark_core_state.o: coremark/core_state.c coremark/coremark.h coremark/core_portme.h
	$(CC) $(CFLAGS) $(COREMARK_CFLAGS) -c $< -o $@

coremark_core_util.o: coremark/core_util.c coremark/coremark.h coremark/core_portme.h
	$(CC) $(CFLAGS) $(COREMARK_CFLAGS) -c $< -o $@

coremark_core_portme.o: coremark/core_portme.c coremark/coremark.h coremark/core_portme.h
	$(CC) $(CFLAGS) $(COREMARK_CFLAGS) -c $< -o $@

coremark_ee_printf.o: coremark/ee_printf.c coremark/coremark.h coremark/core_portme.h
	$(CC) $(CFLAGS) $(COREMARK_CFLAGS) -c $< -o $@

# --- Link ---
$(TARGET).elf: $(OBJS)
	$(CC) $(LDFLAGS) $(OBJS) -lgcc -o $@

# --- Binary ---
$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

# --- Vivado hex ---
$(MEM_IMAGE): $(TARGET).bin
	hexdump -v -e '1/4 "%08x\n"' $< > $@
	@echo "Generated $(MEM_IMAGE) ($$(wc -l < $(MEM_IMAGE)) words)"
	@if [ -d ../RTL_RV64_FreeRTOS_port ]; then cp $@ ../RTL_RV64_FreeRTOS_port/$@; fi

# --- Disassembly ---
$(TARGET).lst: $(TARGET).elf
	$(OBJDUMP) -d -M no-aliases $< > $@

# --- Clean ---
clean:
	rm -f *.o *.elf *.bin *.mem *.map *.lst

.PHONY: all clean
