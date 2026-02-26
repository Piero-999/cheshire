# Guida al Repository Cheshire + ReckOn per ZCU102

## Indice

1. [Panoramica del Progetto](#1-panoramica-del-progetto)
2. [Struttura della Repository](#2-struttura-della-repository)
3. [hw/ — Hardware RTL del SoC Cheshire](#3-hw--hardware-rtl-del-soc-cheshire)
4. [hw/axi_reckon/ — Acceleratore SNN ReckOn](#4-hwaxireckon--acceleratore-snn-reckon)
5. [Architettura di Integrazione Cheshire + ReckOn su ZCU102](#5-architettura-di-integrazione-cheshire--reckon-su-zcu102)
6. [Mappa dei Registri AXI per ReckOn](#6-mappa-dei-registri-axi-per-reckon)
7. [Domini di Clock e Reset](#7-domini-di-clock-e-reset)
8. [target/xilinx/ — Flow FPGA per ZCU102](#8-targetxilinx--flow-fpga-per-zcu102)
9. [sw/ — Software Embedded (Bare-Metal)](#9-sw--software-embedded-bare-metal)
10. [Build System (Makefile, Bender, cheshire.mk)](#10-build-system-makefile-bender-cheshiremk)
11. [Simulazione RTL (QuestaSim / VCS)](#11-simulazione-rtl-questasim--vcs)
12. [Flow Completo: dalla Sintesi al Debug su ZCU102](#12-flow-completo-dalla-sintesi-al-debug-su-zcu102)
13. [Documentazione e Risorse](#13-documentazione-e-risorse)

---

## 1. Panoramica del Progetto

Questo repository contiene il **Cheshire SoC**, una piattaforma RISC-V basata sul core **CVA6** (ex-Ariane), sviluppata da **PULP Platform** (ETH Zürich / Università di Bologna). Il SoC è stato esteso con l'integrazione dell'acceleratore **ReckOn**, un processore per Spiking Recurrent Neural Network (SNN) sviluppato dall'Institute of Neuroinformatics (INI) dell'Università di Zurigo.

**Componenti principali:**

| Componente | Descrizione |
|---|---|
| **Cheshire SoC** | SoC RISC-V a 64 bit (CVA6), Linux-capable, con periferiche (UART, SPI, GPIO, JTAG, DMA) |
| **ReckOn** | Acceleratore SNN con 256 neuroni (N=256), 8 uscite (M=8), supporto e-prop on-chip learning |
| **ZCU102** | Scheda FPGA Xilinx Zynq UltraScale+ MPSoC (XCZU9EG), target di deployment |
| **AXI Layer** | Bridge AXI4 → AXI4-Lite → Register File per il controllo di ReckOn dal CVA6 |

Il branch `main` contiene l'integrazione completa: il CVA6 funge da host che programma e controlla ReckOn tramite registri AXI memory-mapped, mentre il Zynq MPSoC fornisce clock, BRAM controller e VIO per il debug.

---

## 2. Struttura della Repository

```
cheshire/
├── Bender.yml              # Manifest IP: dipendenze HW e source list
├── cheshire.mk             # Makefile principale (include sw.mk, xilinx.mk)
├── Makefile                 # Entry point (include cheshire.mk)
├── conda_cheshire.yml       # Ambiente Conda (Python + tools)
├── requirements.txt         # Dipendenze Python (hjson, mako, pyyaml, ...)
│
├── hw/                      # RTL del SoC Cheshire
│   ├── cheshire_pkg.sv      # Package con configurazione parametrica del SoC
│   ├── cheshire_soc.sv      # Top-level del SoC (CPU, bus AXI, periferiche)
│   ├── cheshire_idma_wrap.sv# Wrapper iDMA
│   ├── bootrom/             # Boot ROM (crt0, loader, generazione SV)
│   ├── regs/                # Registri di configurazione (generati da regtool)
│   ├── include/             # Macro e typedef SystemVerilog
│   ├── future/              # IP sperimentali (USB OHCI)
│   └── axi_reckon/          # ★ Integrazione ReckOn SNN (dettaglio in §4)
│
├── sw/                      # Stack software bare-metal
│   ├── sw.mk                # Regole di compilazione SW
│   ├── include/             # Header (HAL, DIF, registri)
│   ├── lib/                 # Librerie runtime (crt0, UART, SPI, I2C, ...)
│   ├── link/                # Linker script (SPM, DRAM, ROM)
│   ├── boot/                # Device tree, bootloader ZSL, flash
│   ├── tests/               # Test bare-metal (helloworld, DMA, AXI-RT, ...)
│   └── deps/                # Dipendenze (printf, cva6-sdk)
│
├── target/
│   ├── sim/                 # Simulazione RTL (QuestaSim, VCS)
│   │   └── src/             # Testbench, fixture, elfloader
│   └── xilinx/              # ★ Flow FPGA Vivado (dettaglio in §8)
│       ├── xilinx.mk        # Regole Make per bitstream
│       ├── constraints/     # XDC (pin mapping per board)
│       ├── scripts/         # TCL (block design, synthesis, impl)
│       └── src/             # IP Xilinx (DRAM wrapper, fan, regs)
│
├── util/                    # Script di utilità
│   ├── gen_bootrom.py       # Genera boot ROM SV da binario
│   ├── openocd.*.tcl        # Config OpenOCD per debug JTAG
│   ├── pyserial.py          # Monitor seriale
│   ├── flash_disk.sh/.gdb   # Flash GPT su SPI NOR
│   └── ssh_load_bitstream.py# Upload bitstream remoto
│
└── docs/                    # Documentazione MkDocs
    ├── um/                  # User Manual (architettura, SW)
    ├── tg/                  # Target Guide (sim, Xilinx)
    └── gs.md                # Getting Started
```

---

## 3. hw/ — Hardware RTL del SoC Cheshire

### 3.1 cheshire_pkg.sv

Package SystemVerilog che definisce la **configurazione parametrica** completa del SoC tramite la struct `cheshire_cfg_t`. Ogni istanza di Cheshire (simulazione, FPGA, ASIC) passa una configurazione specifica.

Parametri chiave per ZCU102 (impostati in `gen_cheshire_xilinx_cfg()` nel top-level):

| Parametro | Valore ZCU102 | Significato |
|---|---|---|
| `RtcFreq` | 1 MHz | Frequenza del Real-Time Clock |
| `AxiExtNumSlv` | 1 | 1 porta AXI slave esterna (usata per ReckOn) |
| `SpiHost` | 1 | SPI host abilitato |
| `Gpio` | 1 | GPIO abilitato |
| `SerialLink` | 0 | Disabilitato su FPGA |
| `Vga` | 0 | Disabilitato su ZCU102 |
| `I2c` | 0 | Disabilitato |
| `BusErr` | 0 | Disabilitato |
| `Usb` | 0 | Disabilitato (controllato da `USE_USB` define) |

### 3.2 cheshire_soc.sv

Modulo top-level del SoC (1745 righe). Istanzia e interconnette:

- **CVA6** — Core RISC-V RV64GC con MMU SV39, branch prediction, PMP
- **AXI Crossbar** — Interconnessione master/slave con arbitraggio
- **AXI LLC** — Last-Level Cache con porta verso DRAM esterna
- **Boot ROM** — ROM di avvio (2 KiB)  
- **SPM** — Scratchpad Memory (AXI SRAM, tipicamente 128 KiB)
- **CLINT** — Core Local Interrupter (timer, IPI)
- **PLIC / CLIC** — Interrupt controller (Platform-Level o RISC-V CLIC)
- **UART** — Console seriale (APB UART 16550-compatibile)
- **SPI Host** — Master SPI (per SD card, flash NOR)
- **GPIO** — General Purpose I/O (32 bit)
- **DMA (iDMA)** — DMA engine per trasferimenti 1D/2D
- **Debug Module** — RISC-V Debug (JTAG TAP)
- **AXI External Slave Ports** — Porte AXI per acceleratori esterni (ReckOn)

Le porte `axi_ext_slv_req_o` / `axi_ext_slv_rsp_i` sono il punto di connessione per ReckOn.

### 3.3 bootrom/

| File | Ruolo |
|---|---|
| `cheshire_bootrom.S` | Entry pointasm: inizializza hart, salta a `_boot_sequence` in C |
| `cheshire_bootrom.c` | Logica di boot: legge `boot_mode` e carica firmware (JTAG preload, SD card GPT, SPI flash) |
| `cheshire_bootrom.ld` | Linker script per la ROM |
| `cheshire_bootrom.sv` | Modulo SV generato automaticamente da `gen_bootrom.py` |

### 3.4 regs/

Registri di configurazione del SoC generati da `regtool` (lowRISC) a partire da `cheshire_regs.hjson`. Contengono informazioni di boot, scratch registers, e pad configuration.

---

## 4. hw/axi_reckon/ — Acceleratore SNN ReckOn

Questa directory contiene **tutto l'hardware** necessario per integrare ReckOn nel SoC Cheshire.

```
hw/axi_reckon/
├── include/
│   └── axi_macros.svh         # Macro per segnali AXI flat (port flattening)
└── rtl/
    ├── xilinx_zcu102_reckon_chs_top.sv  # ★ Top-level FPGA (784 righe)
    ├── axi_layer.sv                      # Bridge AXI4 → AXI-Lite → Register File
    ├── axi_rf.sv                         # AXI4-Lite Register File slave (629 righe)
    ├── reckon_axi_top.v                  # Wrapper ReckOn con BRAM + AER decoder
    ├── aer_decoder.v                     # Decoder Address-Event Representation
    ├── BRAM_1port.v                      # BRAM single port
    ├── BRAM_1port_we.v                   # BRAM single port con write-enable
    ├── BRAM_2ports.v                     # BRAM dual port
    ├── BRAM_2ports_we.v                  # BRAM dual port con write-enable per byte
    ├── RAM_wrapper.v                     # Wrapper per le 4 SRAM di ReckOn
    ├── RAM_wrapper_new.v                 # Versione aggiornata RAM wrapper
    ├── axi_layer_bad.sv                  # Versione alternativa/deprecata
    └── reckon/                           # Core SNN ReckOn
        ├── reckon.v                      # Toplevel ReckOn (442 righe)
        ├── srnn.v                        # Spiking RNN core (1682 righe)
        ├── spi_slave.v                   # SPI slave per configurazione
        ├── lfsr_winp_wrec.v              # LFSR per pesi input/recurrent
        ├── lfsr_wout.v                   # LFSR per pesi output
        ├── lfsr_neur_stochround.v        # LFSR stochastic rounding (neuroni)
        ├── lfsr_oneur_stochround.v       # LFSR stochastic rounding (output neuroni)
        └── lfsr_noise_neur.v             # LFSR per noise injection
```

### 4.1 reckon.v — Core ReckOn

Il processore SNN originale (Frenkel & Indiveri, ISSCC 2022). Parametri principali:

- **N = 256** — Neuroni ricorrenti
- **M = 8** — Uscite (classi)
- Supporta **e-prop** (eligibility propagation) per on-chip learning
- 4 SRAM interne: `WINP` (pesi input), `WREC` (pesi ricorrenti), `WOUT` (pesi output), `NEUR` (stato neuroni)
- Interfaccia AER (Address-Event Representation) per input spike
- SPI slave per configurazione parametri (learning rate, threshold, seed, ...)

### 4.2 srnn.v — Spiking Recurrent Neural Network

Il core computazionale (1682 righe). Implementa:
- Leaky integrate-and-fire (LIF) neurons
- Connessioni ricorrenti
- E-prop learning rule (modified eligibility traces)
- Stochastic rounding
- Clock-driven time stepping

### 4.3 reckon_axi_top.v — Wrapper AXI per ReckOn

Collega ReckOn al resto del sistema. Include:
- Istanza di `reckon` (N=256, M=8)
- Istanza di `aer_decoder` — decodifica i dati AER dalla BRAM e genera spike per ReckOn
- Istanza di `BRAM2_we_inst` — BRAM dual-port:
  - **Porta A**: accessibile dal MPSoC (via AXI BRAM Controller) per caricare dati AER
  - **Porta B**: letta dall'`aer_decoder` per alimentare ReckOn

Segnali di controllo:

| Segnale | Direzione | Descrizione |
|---|---|---|
| `reckon_ctrl_i[0]` | Host → ReckOn | Bit 0: NEW_EPOCH, Bit 1: STOP |
| `reckon_ctrl_i[1]` | Host → ReckOn | Bit 0: TEST, Bit 1: NEW_BATCH |
| `reckon_ctrl_i[2..3]` | Host → ReckOn | Riservati per estensioni |
| `reckon_ctrl_o[0]` | ReckOn → Host | Bit 0: EPOCH_DONE, Bit 1: BATCH_DONE |
| `reckon_ctrl_o[1]` | ReckOn → Host | Riservato |
| `batch_size_i` | Host → ReckOn | Dimensione del batch (12 bit) |
| `n_samples_i` | Host → ReckOn | Numero di campioni (12 bit) |
| `do_eprop_i` | Host → ReckOn | Modalità e-prop (3 bit) |
| `infer_count_o` | ReckOn → Host | Contatore inferenze corrette (32 bit) |

### 4.4 axi_layer.sv — Bridge AXI

Catena di conversione: **AXI4 full** → **AXI4-Lite** → **Register File**

```
Cheshire AXI Slave Port ──→ axi_to_axi_lite ──→ AXI4_RF_slave_lite ──→ Registri
     (64-bit data)          (conversione)         (32 registri IN, 8 registri OUT)
```

- Usa il modulo PULP `axi_to_axi_lite` con `AxiMaxWriteTxns=4`, `AxiMaxReadTxns=4`
- Il register file (`axi_rf.sv`) espone:
  - **N1 = 32** registri in lettura (input dal HW, `in_reg[0..31]`)
  - **N2 = 8** registri in scrittura (output verso HW, `out_reg[0..7]`)
  - **3 registri GPIO** aggiuntivi

### 4.5 aer_decoder.v — Decoder AER

Gestisce la sequenza di feeding dei dati a ReckOn:
- Legge dalla BRAM i dati codificati AER (formato: `code[27:24] | data[23:12] | tick[11:0]`)
- Genera segnali `AERIN_ADDR`, `AERIN_REQ`, `TIME_TICK`, `SAMPLE`, `TARGET_VALID`
- Controlla le epoche (`cnt_epochs`) e i batch (`cnt_sample_batch`)
- Segnala `EPOCH_DONE` e `BATCH_DONE` al termine

---

## 5. Architettura di Integrazione Cheshire + ReckOn su ZCU102

Il file chiave è `xilinx_zcu102_reckon_chs_top.sv` (784 righe). Ecco lo schema architetturale:

```
                    ┌──────────────────────────────────────────────────┐
                    │          Zynq UltraScale+ MPSoC (PS)            │
                    │  ┌───────────┐  ┌─────┐  ┌──────────────────┐  │
                    │  │  ARM A53  │  │ VIO │  │  AXI BRAM Ctrl   │  │
                    │  │ (unused)  │  │     │  │ @0x00A0_0000_0000│  │
                    │  └───────────┘  └──┬──┘  └────────┬─────────┘  │
                    │  ┌─────────┐       │              │            │
                    │  │ ClkWiz  │       │              │            │
                    │  │125→50/15│       │              │ BRAM Port  │
                    │  └────┬────┘       │              │            │
                    └───────┼────────────┼──────────────┼────────────┘
                            │            │              │
               ┌────────────┼────────────┼──────────────┼────────────────┐
               │   PL       │            │              │                │
               │            │            │              │                │
               │   clk_50   │   VIO      │     BRAM PortA               │
               │   (SoC)    │ signals    │     (AER data load)          │
               │            │            │              │                │
               │   ┌────────▼──────┐     │    ┌─────────▼───────────┐   │
               │   │               │     │    │                     │   │
               │   │  Cheshire SoC │     │    │  reckon_axi_top     │   │
               │   │   (CVA6)      │     │    │  ┌───────────────┐  │   │
               │   │               │     │    │  │  BRAM Dual    │◄─┘   │
               │   │  AXI Slave ───┼─┐   │    │  │  Port B ──────┤      │
               │   │  Port [0]     │ │   │    │  └───────────────┘  │   │
               │   │               │ │   │    │  ┌───────────────┐  │   │
               │   └───────────────┘ │   │    │  │  aer_decoder  │  │   │
               │                     │   │    │  └───────┬───────┘  │   │
               │   ┌─────────────────▼─┐ │    │  ┌───────▼───────┐  │   │
               │   │   axi_layer       │ │    │  │   reckon      │  │   │
               │   │  AXI4→Lite→RF     │ │    │  │  (N=256,M=8)  │  │   │
               │   │                   │ │    │  │   @clk_15     │  │   │
               │   │  out_reg[0..7] ───┼─┼────┼──► ctrl_i, cfg   │  │   │
               │   │  in_reg[0..2]  ◄──┼─┼────┼──┤ ctrl_o, count │  │   │
               │   └───────────────────┘ │    │  └───────────────┘  │   │
               │                         │    └─────────────────────┘   │
               │                         │                              │
               │   Reset Sync ◄──────────┼── VIO probe_out0            │
               │   Boot Mode  ◄──────────┼── VIO probe_out1/2          │
               │   UART Mux   ◄──────────┘── VIO probe_out3            │
               │                                                        │
               │   UART TX ──→ uart_tx_o_cp2108 (onboard CP2108)       │
               │              ──→ uart_tx_o_gpio  (PMOD header)         │
               └────────────────────────────────────────────────────────┘
```

### 5.1 Flusso Dati

1. **Caricamento dati AER**: Il MPSoC (PS) scrive i dati spike nella BRAM tramite il suo BRAM Controller AXI (indirizzo PS: `0x00A0_0000_0000`, range 256 KB). Questa BRAM è dual-port: la porta A è controllata dal PS, la porta B è letta da `reckon_axi_top`.

2. **Configurazione ReckOn**: Il CVA6 (nella PL, Cheshire SoC) scrive nei registri AXI della `axi_layer` per impostare `batch_size`, `n_samples`, `do_eprop`, e i segnali di controllo (`ctrl_i[0..3]`).

3. **Esecuzione SNN**: ReckOn legge i dati spike dalla BRAM (porta B), processa la rete neurale spiking, e segnala il completamento (`EPOCH_DONE`, `BATCH_DONE`) e il conteggio inferenze (`infer_count`).

4. **Lettura risultati**: Il CVA6 legge i registri di stato (`in_reg[0..2]`) per ottenere `infer_count` e `ctrl_o`.

---

## 6. Mappa dei Registri AXI per ReckOn

L'`axi_layer` espone i registri all'indirizzo della prima porta AXI slave esterna di Cheshire. I registri sono a 32 bit, accessibili dal CVA6 via load/store.

### Registri di Scrittura (Host → ReckOn) — `out_reg[0..7]`

| Registro | Indice | Bit | Descrizione |
|---|---|---|---|
| `axi_batch_size` | 0 | [11:0] | Dimensione del batch |
| `axi_n_samples` | 1 | [11:0] | Numero di campioni per epoca |
| `axi_do_eprop` | 2 | [2:0] | Modalità e-prop (0=off, altre=varianti) |
| `reckon_ctrl_i[0]` | 3 | [0] NEW_EPOCH, [1] STOP | Controllo epoca |
| `reckon_ctrl_i[1]` | 4 | [0] TEST, [1] NEW_BATCH | Controllo batch/test |
| `reckon_ctrl_i[2]` | 5 | [31:0] | Riservato / estensione |
| `reckon_ctrl_i[3]` | 6 | [31:0] | Riservato / estensione |
| `debug_axi` | 7 | [0] | Bit di debug (connesso a LED) |

### Registri di Lettura (ReckOn → Host) — `in_reg[0..2]`

| Registro | Indice | Descrizione |
|---|---|---|
| `infer_count` | 0 | Contatore inferenze corrette (32 bit) |
| `reckon_ctrl_o[0]` | 1 | Bit 0: EPOCH_DONE, Bit 1: BATCH_DONE |
| `reckon_ctrl_o[1]` | 2 | Riservato |

> **Nota**: L'indirizzo base nello spazio AXI di Cheshire dipende dalla configurazione `AxiExtRegionStart/End` nel package. Di default la regione AXI slave esterna è nella zona `0x2000_0000 - 0x8000_0000` (range non-CIE del CVA6).

---

## 7. Domini di Clock e Reset

Il sistema ha **due domini di clock** principali, generati dal Clock Wizard nel block design MPSoC:

| Clock | Frequenza | Sorgente | Utilizzatori |
|---|---|---|---|
| `clk_50` (soc_clk) | 50 MHz | ClkWiz da 125 MHz diff. | Cheshire SoC (CVA6, AXI crossbar, periferiche, axi_layer) |
| `clk_15` | 15 MHz | ClkWiz da 125 MHz diff. | ReckOn core (`reckon_axi_top`) |
| RTC | 1 MHz | Divider da soc_clk (/50) | CLINT timer |
| JTAG | ≤10 MHz | Esterno (Olimex/FTDI) | Debug module |

Il **clock di ingresso** è un differenziale a 125 MHz dai pin `sys_clk_p/n` (connettore Si570 sulla ZCU102).

### Reset

```
sys_reset (pulsante AM13) ──┐
vio_reset (VIO probe_out0) ─┤──→ sys_rst ──→ rstgen ──→ rst_n (sincrono a soc_clk)
                             │
                             └──→ reckon: ~rst_n (invertito, active-high)
```

Il modulo `rstgen` sincronizza il reset al dominio `soc_clk` e genera `rst_n` (active-low).

### Boot Mode

```
boot_mode_i[1:0] (pin/switch) ──┐
vio_boot_mode[1:0]              ├──→ MUX (sel: vio_boot_mode_sel) ──→ boot_mode[1:0]
                                │
```

Modalità: `00` = JTAG preload, `01` = SD card GPT, `10` = SPI flash, `11` = UART.

---

## 8. target/xilinx/ — Flow FPGA per ZCU102

### 8.1 Struttura

```
target/xilinx/
├── xilinx.mk                    # Regole Make per IPs e bitstream
├── constraints/
│   ├── cheshire.xdc             # Vincoli comuni (JTAG timing, UART, CDC)
│   └── zcu102.xdc               # ★ Pin mapping specifico ZCU102
├── scripts/
│   ├── common.tcl               # Init progetto Vivado (board part, parallelismo)
│   ├── impl_sys.tcl             # Flow completo: sintesi → implementazione → bitstream
│   ├── impl_ip.tcl              # Generazione IP Xilinx
│   ├── chs-bd-zcu102.tcl        # ★ Block Design MPSoC per ZCU102
│   └── util/                    # Script utilità (program, flash)
└── src/
    ├── dram_wrapper_xilinx.sv   # Wrapper DDR (non usato su ZCU102)
    ├── fan_ctrl.sv              # Controller ventola
    ├── phy_definitions.svh      # Define PHY per DDR
    └── regs/                    # Registri FPGA-level (generati)
```

### 8.2 zcu102.xdc — Pin Mapping

| Segnale | Package Pin | Standard I/O | Note |
|---|---|---|---|
| `sys_reset` | AM13 | LVCMOS33 | Pulsante reset CPU |
| `uart_rx_i_gpio` | H14 | LVCMOS33 | UART RX su PMOD |
| `uart_tx_o_gpio` | J14 | LVCMOS33 | UART TX su PMOD |
| `uart_rx_i_cp2108` | E13 | LVCMOS33 | UART RX onboard (CP2108) |
| `uart_tx_o_cp2108` | F13 | LVCMOS33 | UART TX onboard (CP2108) |
| `jtag_tms_i` | A20 | LVCMOS33 | JTAG TMS |
| `jtag_tdi_i` | B20 | LVCMOS33 | JTAG TDI |
| `jtag_tdo_o` | A22 | LVCMOS33 | JTAG TDO |
| `jtag_tck_i` | A21 | LVCMOS33 | JTAG TCK |
| `sys_clk_p/n` | G21/F21 | LVDS_25 | Clock differenziale 125 MHz |
| `led_o[0]` | AG14 | LVCMOS33 | LED debug (connesso a `debug_axi`) |

> **Nota UART**: Il sistema ha **due uscite UART** selezionabili via VIO (`vio_uart_sel`):
> - CP2108: il convertitore USB-UART onboard della ZCU102
> - GPIO: pin PMOD per collegamento esterno (es. FTDI)

### 8.3 chs-bd-zcu102.tcl — Block Design MPSoC

Questo script TCL crea il block design Vivado per la ZCU102 con:

1. **Zynq UltraScale+ PS** (`zynq_ultra_ps_e`):
   - DDR disabilitato (`PSU__DDRC__ENABLE=0`)
   - 1 porta AXI master (`M_AXI_HPM0_FPD`, 32 bit)
   - UART0 abilitato
   - PL clock 0 disabilitato (usa ClkWiz esterno)

2. **Clock Wizard** (`clk_wiz`):
   - Input: 125 MHz differenziale
   - Output: `clk_50` (50 MHz), `clk_48` (48 MHz), `clk_20` (20 MHz), `clk_15` (15 MHz)

3. **VIO** (Virtual I/O):
   - 4 probe output: reset, boot_mode[1:0], boot_mode_sel, uart_sel
   - 2 probe input: SPI_EN_CONF, debug_axi

4. **AXI BRAM Controller** + SmartConnect:
   - Porta BRAM singola esportata verso la PL
   - Indirizzo PS: `0x00A0_0000_0000`, range 256 KB
   - Connesso via SmartConnect al PS AXI master

5. **Proc Sys Reset**: gestione reset sincronizzato

### 8.4 xilinx.mk — Regole di Build

La board ZCU102 è definita come target:

```makefile
CHS_XILINX_BOARDS := genesys2 vcu128 vcu118 zcu102
CHS_XILINX_IPS_zcu102 :=    # Nessun IP pre-generato (usa block design)
```

Comandi Make principali:

| Comando | Descrizione |
|---|---|
| `make chs-xilinx-zcu102` | Genera bitstream per ZCU102 |
| `make chs-xilinx-program-zcu102` | Programma la FPGA via HW server |
| `make chs-xilinx-flash-zcu102` | Flash immagine su memoria onboard |

### 8.5 impl_sys.tcl — Flow di Implementazione

Il flow completo eseguito da Vivado:

1. Crea progetto con `init_impl` (part: `xczu9eg-ffvb1156-2-e`)
2. Importa constraint (`cheshire.xdc` + `zcu102.xdc`)
3. Carica sorgenti RTL (`add_sources.zcu102.tcl`, generato da Bender)
4. Imposta top module: `cheshire_top_xilinx`
5. Sorgente block design MPSoC (`chs-bd-zcu102.tcl`)
6. Sintesi (`Flow_PerfOptimized_high`)
7. Report clock e inserimento ILA (debug)
8. Implementazione (`Performance_ExtraTimingOpt`)
9. Generazione bitstream → `target/xilinx/out/cheshire.zcu102.bit`

---

## 9. sw/ — Software Embedded (Bare-Metal)

### 9.1 Compilazione

Il cross-compiler è **riscv64-unknown-elf-gcc** con flag:
```
-march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany -O2
```

### 9.2 Struttura SW

| Directory | Contenuto |
|---|---|
| `sw/include/` | Header per periferiche: `dif/uart.h`, `dif/clint.h`, `hal/spi_sdcard.h`, `regs/*.h` |
| `sw/lib/` | Implementazioni: `crt0.S` (startup), `dif/uart.c`, `hal/spi_sdcard.c`, ecc. |
| `sw/link/` | Linker script: `spm.ld` (esecuzione da SPM), `dram.ld` (da DRAM), `rom.ld` (da ROM) |
| `sw/tests/` | Test bare-metal: `helloworld.c`, `dma_1d.spm.c`, `counter.c`, ecc. |
| `sw/boot/` | Device tree (`.dts/.dtsi`), Zero-Stage Loader (`zsl.c`), flash loader |

### 9.3 Come Scrivere un Driver per ReckOn

Per controllare ReckOn dal CVA6, devi scrivere in C accessi memory-mapped ai registri dell'`axi_layer`. Esempio concettuale:

```c
#include <stdint.h>

// Indirizzo base della porta AXI slave esterna (da verificare nel device tree / config)
#define RECKON_BASE  0x20000000  // esempio, dipende da AxiExtRegionStart[0]

// Registri di scrittura (out_reg)
#define RECKON_BATCH_SIZE   (*(volatile uint32_t *)(RECKON_BASE + 0x00))
#define RECKON_N_SAMPLES    (*(volatile uint32_t *)(RECKON_BASE + 0x04))
#define RECKON_DO_EPROP     (*(volatile uint32_t *)(RECKON_BASE + 0x08))
#define RECKON_CTRL_I0      (*(volatile uint32_t *)(RECKON_BASE + 0x0C))
#define RECKON_CTRL_I1      (*(volatile uint32_t *)(RECKON_BASE + 0x10))

// Registri di lettura (in_reg, offset dipende da N2*4 nel RF)
// L'offset esatto dipende dal layout di axi_rf.sv

void reckon_start_epoch(uint32_t batch_size, uint32_t n_samples) {
    RECKON_BATCH_SIZE = batch_size;
    RECKON_N_SAMPLES  = n_samples;
    RECKON_DO_EPROP   = 0;        // nessun e-prop per inferenza
    RECKON_CTRL_I0    = 0x01;     // NEW_EPOCH = 1
}
```

> **Nota**: Al momento non esiste un driver SW per ReckOn nel repository. Va scritto basandosi sulla mappa registri in §6.

### 9.4 Test Esistenti

| Test | Tipo | Descrizione |
|---|---|---|
| `helloworld.c` | UART | Stampa "Hello World" su UART |
| `dma_1d.spm.c` | DMA | Test trasferimento DMA 1D in SPM |
| `dma_2d.spm.c` | DMA | Test trasferimento DMA 2D |
| `counter.c` | CPU | Ciclo con contatore e uscita UART |
| `nn.c` | CPU | CNN toy (conv2d + ReLU, **non** usa ReckOn) |
| `axirt_*.c` | AXI-RT | Test real-time AXI bandwidth regulation |

---

## 10. Build System (Makefile, Bender, cheshire.mk)

### 10.1 Bender (gestione IP)

`Bender.yml` dichiara ~20 dipendenze hardware (PULP IPs) e la lista sorgenti, con target condizionali:

```yaml
- target: all(fpga, xilinx)
    files:
      - hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv
      - hw/axi_reckon/rtl/axi_layer.sv
      - hw/axi_reckon/rtl/reckon/reckon.v
      - hw/axi_reckon/rtl/reckon/srnn.v
      # ... (tutti i file ReckOn)
    defines:
        ADDR_WIDTH: 16
```

I file ReckOn sono inclusi **solo** nel target `fpga + xilinx` e vengono compilati con `ADDR_WIDTH=16`.

Comandi Bender utili:

```bash
bender checkout                    # Scarica tutte le dipendenze in .bender/
bender script vivado -t fpga -t zcu102  # Genera script TCL per Vivado
bender script vsim -t sim -t test       # Genera script per QuestaSim
```

### 10.2 Makefile / cheshire.mk

Struttura gerarchica:

```
Makefile (entry point)
  └── cheshire.mk
        ├── sw/sw.mk         (compilazione SW, test, disk image)
        └── target/xilinx/xilinx.mk  (sintesi FPGA)
```

Target principali:

| Target | Descrizione |
|---|---|
| `make all` | Compila SW, genera HW (registri), scarica modelli sim |
| `make sw-all` | Compila tutte le librerie e test SW |
| `make hw-all` | Genera registri (regtool) per tutte le periferiche |
| `make bootrom-all` | Rigenera boot ROM |
| `make sim-all` | Prepara simulazione (modelli, script compile) |
| `make xilinx-zcu102` | Bitstream per ZCU102 |
| `make xilinx-program-zcu102` | Programma FPGA |

### 10.3 Dipendenze principali

Per lavorare servono:

| Tool | Versione | Scopo |
|---|---|---|
| **Vivado** | 2022.1+ (consigliato 2024.2) | Sintesi, implementazione, bitstream |
| **riscv64-unknown-elf-gcc** | 12.x+ | Cross-compilazione SW |
| **Bender** | 0.28+ | Gestione dipendenze HW |
| **Python 3** | 3.8+ | regtool, gen_bootrom.py |
| **OpenOCD + GDB** | 0.12+ | Debug JTAG |
| **dtc** | 1.6+ | Compilazione device tree |

---

## 11. Simulazione RTL (QuestaSim / VCS)

Per simulare **senza** ReckOn (flusso standard Cheshire):

```bash
make sim-all                                  # Prepara script e modelli
# QuestaSim:
cd target/sim/vsim && vsim -do compile.cheshire_soc.tcl
vsim -do "run -all" tb_cheshire_soc

# VCS:
cd target/sim/vcs && ./compile.cheshire_soc.sh
./simv +BINARY=../../sw/tests/helloworld.spm.elf
```

> **Nota**: I file ReckOn sono nel target `fpga` di Bender, quindi **non** sono inclusi nella simulazione standard. Per simularli bisogna aggiungere il target `-t fpga -t xilinx` o creare un testbench dedicato.

---

## 12. Flow Completo: dalla Sintesi al Debug su ZCU102

### Step 1: Setup Ambiente

```bash
# Installa dipendenze
conda env create -f conda_cheshire.yml
conda activate cheshire
pip install -r requirements.txt

# Checkout IP dependencies
make -C cheshire/ all    # o: bender checkout
```

### Step 2: Compila Software

```bash
# Compila librerie e test
make sw-all

# Compila un test specifico
make sw/tests/helloworld.spm.elf
```

### Step 3: Genera Bitstream

```bash
# Assicurati che Vivado sia nel PATH
export VIVADO=<path_to_vivado>/vivado

# Genera bitstream (può richiedere 1-3 ore)
make xilinx-zcu102
# Output: target/xilinx/out/cheshire.zcu102.bit
```

### Step 4: Programma la FPGA

```bash
# Via Vivado HW Manager
make xilinx-program-zcu102

# Oppure manualmente con Vivado GUI:
# Open Hardware Manager → Open Target → Auto Connect → Program Device
# Seleziona: target/xilinx/out/cheshire.zcu102.bit
```

### Step 5: Connetti UART

```bash
# Identifica la porta seriale
ls /dev/ttyUSB*

# Connessione con minicom (115200 baud default)
minicom -D /dev/ttyUSB0 -b 115200

# Oppure con pyserial
python3 util/pyserial.py /dev/ttyUSB0 115200
```

### Step 6: Debug JTAG con OpenOCD + GDB

```bash
# Avvia OpenOCD (in un terminale separato)
openocd -f util/openocd.hs2.tcl  # per probe Digilent HS2

# In un altro terminale, avvia GDB
riscv64-unknown-elf-gdb sw/tests/helloworld.spm.elf
(gdb) target remote :3333
(gdb) load                    # Carica ELF nella SPM
(gdb) break main
(gdb) continue
```

### Step 7: Controlla VIO (da Vivado)

```
Hardware Manager → Open Target → VIO
- probe_out0: reset (0=run, 1=reset)
- probe_out1: boot_mode[1:0] (00=JTAG)
- probe_out2: boot_mode_sel (1=usa VIO, 0=usa pin)
- probe_out3: uart_sel (1=CP2108 onboard, 0=GPIO PMOD)
- probe_in0: SPI_EN_CONF (stato configurazione ReckOn)
- probe_in1: debug_axi (echo del bit debug)
```

### Step 8: Carica Dati AER nella BRAM (per ReckOn)

I dati AER devono essere scritti nella BRAM del MPSoC. Questo può avvenire:

1. **Da software ARM (PS)**: usando il SDK Xilinx/Petalinux per scrivere all'indirizzo `0x00A0_0000_0000`
2. **Via JTAG del MPSoC**: usando XSDB (Xilinx System Debugger)
3. **Pre-caricamento nel block design**: modificando il script TCL per inizializzare la BRAM

### Step 9: Avvia ReckOn dal CVA6

Una volta caricati i dati AER nella BRAM e programmato il bitstream:

1. Il CVA6 scrive nei registri dell'`axi_layer` per configurare batch_size, n_samples, do_eprop
2. Il CVA6 attiva NEW_EPOCH tramite `ctrl_i[0]`
3. ReckOn processa gli spike e aggiorna `infer_count`
4. Il CVA6 legge `infer_count` e `ctrl_o` per verificare il completamento

---

## 13. Documentazione e Risorse

| Risorsa | Percorso / Link |
|---|---|
| Docs Cheshire | `docs/` (compilabile con `mkdocs serve`) |
| Getting Started | `docs/gs.md` |
| User Manual | `docs/um/arch.md` (architettura), `docs/um/sw.md` (software) |
| Target Guide Xilinx | `docs/tg/xilinx.md` |
| Paper ReckOn | Frenkel & Indiveri, ISSCC 2022 |
| Repo ReckOn originale | https://github.com/chfrenkel/reckon |
| PULP Platform | https://pulp-platform.org |
| CVA6 core | https://github.com/pulp-platform/cva6 |
| ZCU102 User Guide | Xilinx UG1182 |
| Bender docs | https://github.com/pulp-platform/bender |

---

*Guida generata per il branch `main` del repository Cheshire + ReckOn, specificamente per l'implementazione su Xilinx ZCU102.*
