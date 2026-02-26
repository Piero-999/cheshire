# Guida: BRAM, DRAM e Aspetti Utili della ZCU102

## Indice

1. [Cos'è la ZCU102](#1-cosè-la-zcu102)
2. [PS vs PL: due mondi in un chip](#2-ps-vs-pl-due-mondi-in-un-chip)
3. [BRAM — Block RAM](#3-bram--block-ram)
4. [DRAM — Dynamic RAM (DDR4)](#4-dram--dynamic-ram-ddr4)
5. [Scratchpad Memory (SPM) in Cheshire](#5-scratchpad-memory-spm-in-cheshire)
6. [BRAM nel design attuale (ReckOn)](#6-bram-nel-design-attuale-reckon)
7. [Come la PS comunica con la PL](#7-come-la-ps-comunica-con-la-pl)
8. [Risorse della ZCU102 — numeri chiave](#8-risorse-della-zcu102--numeri-chiave)
9. [Confronto: BRAM vs DRAM vs SPM](#9-confronto-bram-vs-dram-vs-spm)
10. [Il block design MPSoC attuale](#10-il-block-design-mpsoc-attuale)
11. [Xilinx IP utili per data movement](#11-xilinx-ip-utili-per-data-movement)

---

## 1. Cos'è la ZCU102

La **ZCU102** è una scheda di valutazione Xilinx basata sul chip **Zynq UltraScale+ MPSoC** (part: `XCZU9EG-2FFVB1156E`). "MPSoC" sta per Multi-Processor System-on-Chip: nello stesso die convivono un processore ARM e una FPGA.

```
┌──────────────────────────────────────────────────────┐
│                    XCZU9EG                            │
│                                                      │
│  ┌─────────────────────┐   ┌──────────────────────┐  │
│  │     PS (Processing  │   │    PL (Programmable   │  │
│  │        System)      │   │       Logic)          │  │
│  │                     │   │                       │  │
│  │  • 4x ARM Cortex-A53│   │  • 600K Logic Cells   │  │
│  │  • 2x ARM Cortex-R5 │   │  • 2520 DSP Slices    │  │
│  │  • DDR4 Controller  │   │  • 912 BRAM (36Kb)    │  │
│  │  • GigE, USB, UART  │   │  • 32.1 Mb BRAM tot   │  │
│  │  • SD/eMMC, I2C     │   │  • ~4 MB BRAM max     │  │
│  │  • PCIe, SATA       │   │  • 80 UltraRAM (288Kb)│  │
│  │                     │   │  • ~27 MB UltraRAM    │  │
│  └──────────┬──────────┘   └──────────┬────────────┘  │
│             │      AXI Interconnect   │               │
│             └─────────────────────────┘               │
└──────────────────────────────────────────────────────┘
```

Sulla **scheda** ZCU102 ci sono anche:
- **4 GB DDR4 SDRAM** connessa al PS (controller DDR integrato nel PS)
- **512 MB DDR4** opzionale (connessa alla PL, ma spesso non montata o non usata)
- Connettori FMC, PMOD, USB, HDMI, SFP+, ecc.

---

## 2. PS vs PL: due mondi in un chip

### PS (Processing System)
Il PS è un **processore ARM hardwired** (non programmabile FPGA). È sempre presente e funziona indipendentemente dalla PL.

- **CPU**: Quad-core ARM Cortex-A53 (APU, 64-bit) + Dual-core Cortex-R5F (RPU)
- **Memoria**: Controller DDR4 integrato → collega i **4 GB DDR4** sulla scheda
- **Periferiche**: GigE, USB 3.0, UART, SD/eMMC, I2C, SPI, CAN, PCIe, SATA, DisplayPort
- **Software**: Gira Linux (PetaLinux/Ubuntu), RTOS, o bare-metal

### PL (Programmable Logic)
La PL è la **FPGA vera e propria**. È dove vive il design Cheshire + ReckOn.

- **Logica**: LUT, flip-flop, BRAM, UltraRAM, DSP
- **Non ha CPU propria** (a meno che non ne istanzi una, come fa Cheshire col CVA6)
- **Non ha controller DDR proprio** a meno che non lo istanzi come IP

### Come comunicano?
PS e PL comunicano via **porte AXI** nel chip:

| Porta | Direzione | Larghezza Dati | Scopo |
|---|---|---|---|
| **M_AXI_HPM0_FPD** | PS → PL | 32/64/128 bit | PS è master, accede a slave nella PL |
| **M_AXI_HPM1_FPD** | PS → PL | 32/64/128 bit | Secondo master PS → PL |
| **S_AXI_HP0/1/2/3_FPD** | PL → PS | 32/64/128 bit | PL è master, accede alla DDR4 del PS |
| **S_AXI_HPC0/1_FPD** | PL → PS | 32/64/128 bit | Come HP ma con cache coherency |
| **S_AXI_LPD** | PL → PS | 32/64/128 bit | Accesso alla Low-Power Domain del PS |

**Nomenclatura**: 
- **M_AXI** = il **PS è master** (il PS inizia le transazioni, la PL risponde)
- **S_AXI** = il **PS è slave** (la PL inizia le transazioni, la DDR del PS risponde)
- **HP** = High Performance (con burst, senza coherency)
- **HPC** = High Performance Coherent (con coherency hardware)

---

## 3. BRAM — Block RAM

### Cos'è

Le **BRAM** (Block RAM) sono piccole memorie SRAM integrate **dentro il tessuto FPGA** (nella PL). Ogni blocco BRAM è un blocchetto fisico hardwired nella FPGA.

### Caratteristiche XCZU9EG (ZCU102)

| Proprietà | Valore |
|---|---|
| Numero blocchi BRAM | **912** (36 Kb ciascuno) |
| Capacità totale BRAM | **912 × 36 Kb = 32.832 Kb ≈ 4 MB** |
| Ogni blocco può essere configurato | 36 Kb × 1, o 2× 18 Kb |
| Porte | **True Dual-Port** (2 porte indipendenti, stesso blocco) |
| Latenza | **1 clock cycle** (read synchronous) |
| Larghezza dati | Configurabile: 1, 2, 4, 9, 18, 36 bit |
| Velocità | **Massima frequenza del clock FPGA** (~500 MHz) |

### UltraRAM (URAM)

La ZCU102 ha anche **UltraRAM**, blocchi di memoria più grandi:

| Proprietà | Valore |
|---|---|
| Numero blocchi URAM | **80** (288 Kb ciascuno) |
| Capacità totale URAM | **80 × 288 Kb = 23.040 Kb ≈ 2.8 MB** |
| Porte | **True Dual-Port** |
| Latenza | 1 clock cycle |
| Nota | Solo Single-clock (entrambe le porte usano lo stesso clock) |

### Totale memoria on-chip PL

```
BRAM:     ~4.0 MB
UltraRAM: ~2.8 MB
──────────────────
Totale:   ~6.8 MB di memoria veloce on-chip
```

### Quando usare BRAM

- **Piccoli buffer** (< qualche MB): scratchpad, FIFO, register file, LUT
- **Latenza minima**: 1 ciclo di clock, nessun controller complesso
- **Dual-port**: un lato scrive, l'altro legge contemporaneamente (diversi clock possibili)
- **Allocazione automatica**: Vivado mappa automaticamente array HDL su BRAM

### Limiti

- **Capacità limitata**: 4-7 MB massimo sulla ZCU102, **impossibile** metterci 200 MB
- **Ogni BRAM usata = risorse FPGA in meno** per la logica
- Non è dinamica: non puoi "aggiungerne" a runtime

---

## 4. DRAM — Dynamic RAM (DDR4)

### Cos'è

La **DRAM** (Dynamic RAM, qui DDR4) è la memoria esterna grande, collegata al chip tramite un **controller DDR** e un **bus fisico** dedicato (pin sul package).

### DDR4 sulla ZCU102

La scheda ha **due** banchi DDR4:

| Banco | Capacità | Connesso a | Controller |
|---|---|---|---|
| **PS DDR4** | **4 GB** (2× 2GB IC) | PS (ARM A53) | Controller DDR4 **hardwired** nel PS |
| **PL DDR4** | 512 MB (opzionale, component option) | PL (FPGA) | Richiede MIG IP nella PL |

### PS DDR4 (4 GB) — la tua risorsa principale

Il controller DDR4 nel PS è **già funzionante** senza bisogno di IP FPGA. L'ARM A53 ci accede direttamente. Per accederci dalla PL, devi passare tramite le porte **S_AXI_HP** o **S_AXI_HPC**.

```
Spazio indirizzi PS DDR4:
  0x0000_0000 – 0x7FFF_FFFF  (2 GB, Low)
  0x8_0000_0000 – 0x8_7FFF_FFFF  (2 GB, High)  [indirizzi a 40 bit]
```

### PL DDR4 (512 MB) — NON usata nel design attuale

Per usarla servirebbe istanziare il **Xilinx DDR4 MIG IP** nella PL. Il design attuale (`xilinx_zcu102_reckon_chs_top.sv`) **non definisce `USE_DDR4`** né `USE_DDR`, quindi il MIG non è istanziato e questa memoria non è usata.

### Caratteristiche DDR4 vs BRAM

| Proprietà | DDR4 (PS) | BRAM |
|---|---|---|
| Capacità | 4 GB | ~4 MB |
| Latenza | ~50-100 ns (burst) | ~2 ns (1 clock @ 500 MHz) |
| Bandwidth | ~17 GB/s (PS DDR4) | Dipende da port width e clock |
| Accesso dalla PL | Via S_AXI_HP port | Diretto (istanziazione) |
| Complessità | Serve controller + CDC | Zero (hardwired nella FPGA) |
| Persistenza | Volatile (refresh continuo) | Volatile (perde dati a power-off) |

---

## 5. Scratchpad Memory (SPM) in Cheshire

Cheshire ha una **SPM interna** implementata come **LLC configurata in modalità scratchpad**. Non è né BRAM grezza né DRAM esterna.

### Come funziona

Il modulo `axi_llc_reg_wrap` (Last-Level Cache) può funzionare in due modalità:
1. **Cache mode**: agisce come cache per la DRAM esterna
2. **SPM mode** (scratchpad): agisce come memoria indirizzabile direttamente

### Indirizzi SPM

| Regione | Indirizzo | Descrizione |
|---|---|---|
| SPM Cached | `0x1000_0000` – `0x1000_0000 + LlcSize` | Accesso cached |
| SPM Uncached | `0x1400_0000` – `0x1400_0000 + LlcSize` | Accesso uncached |

Con `DefaultCfg`:
- `LlcSetAssoc = 8`, `LlcNumLines = 256`, `LlcNumBlocks = 8`, `AxiDataWidth = 64 bit`
- **Size = 8 × 256 × 8 × 8 = 131.072 bytes = 128 KiB**

### Nel design ZCU102 attuale

Poiché `USE_DDR` non è definito, il percorso DRAM è **morto** (`axi_dram_mst_rsp` non è mai pilotato). La LLC **non funziona come cache** perché non c'è nessun backend DRAM che risponde. Può funzionare **solo come SPM** (tutta la capacità è mappata come scratchpad).

---

## 6. BRAM nel design attuale (ReckOn)

Nel design corrente, la BRAM è usata per i **dati AER** (spike) di ReckOn. Ecco il path:

```
PS ARM A53                           PL (FPGA)
    │                                    │
    │  AXI Master M_AXI_HPM0_FPD        │
    │  (32-bit data, addr 0xA000_0000)   │
    ▼                                    │
┌───────────────┐                        │
│ SmartConnect  │                        │
└───────┬───────┘                        │
        │                                │
        ▼                                │
┌───────────────┐                        │
│  AXI BRAM     │                        │
│  Controller   │                        │
│  (256 KB)     │                        │
└───────┬───────┘                        │
        │ BRAM Port A                    │
        ▼                                │
┌──────────────────────┐                 │
│  BRAM Dual-Port      │                 │
│  (BRAM2_we_inst)     │                 │
│                      │                 │
│  Port A: PS write/   │                 │
│          read data   │                 │
│                      │                 │
│  Port B: ReckOn      │──→ aer_decoder ──→ reckon (SNN)
│          reads data  │    (clk_15)
│  (read-only)         │
└──────────────────────┘
```

### Parametri BRAM attuale

```verilog
BRAM2_we_inst #(
    .NB_COL(4),          // 4 colonne (byte-write enable)
    .COL_WIDTH(8),       // 8 bit per colonna
    .RAM_WIDTH(32),      // 32 bit totali per parola
    .RAM_DEPTH(2**16),   // 65536 entries = 64K parole
    .INIT_FILE("")       // Nessun file di inizializzazione
)
```

**Capacità**: 64K × 32 bit = **256 KB** = circa 250 BRAM blocks (1/4 delle risorse BRAM della ZCU102)

### Limitazione fondamentale

I **200 MB di dati** che vuoi caricare **non entrano nella BRAM**. La BRAM totale è ~4 MB, e quella già usata per i dati AER è 256 KB. Anche usando tutta la BRAM disponibile, non arrivi neanche a 1/50 dei 200 MB necessari.

---

## 7. Come la PS comunica con la PL

### Direzione PS → PL (PS scrive nella PL)

La PS usa le porte **M_AXI_HPM0/1** per accedere a periferiche nella PL. Nel design attuale:

- **M_AXI_HPM0_FPD** (32 bit) → SmartConnect → AXI BRAM Controller → BRAM (dati AER)
- Indirizzo PS: `0x00A0_0000_0000` (range 256 KB)

### Direzione PL → PS (PL accede alla DDR del PS)

La PL può accedere alla DDR4 del PS usando le porte **S_AXI_HP_FPD** (slave del PS). Questo permette a un master nella PL di leggere/scrivere la DDR4 da 4 GB.

**Nel design attuale queste porte NON sono usate.** Il block design MPSoC non configura nessuna porta S_AXI_HP, e la DDR4 del PS è disabilitata (`PSU__DDRC__ENABLE {0}`).

### Riepilogo comunicazione attuale

| Path | Usato? | Descrizione |
|---|---|---|
| PS → PL via M_AXI_HPM0 | **Sì** | PS scrive dati AER nella BRAM |
| PS → PL via VIO | **Sì** | Reset, boot mode, UART select |
| PS → PL via ClkWiz | **Sì** | Genera clock 50/15 MHz |
| PL → PS DDR4 via S_AXI_HP | **No** | Non configurato |
| PL DDR4 via MIG | **No** | Non istanziato |

---

## 8. Risorse della ZCU102 — numeri chiave

### Chip XCZU9EG

| Risorsa | Quantità |
|---|---|
| Logic Cells | 600K |
| CLB LUTs | 274,080 |
| CLB Flip-Flops | 548,160 |
| BRAM (36Kb) | 912 (~4 MB) |
| UltraRAM (288Kb) | 80 (~2.8 MB) |
| DSP Slices | 2,520 |
| PS ARM Cortex-A53 | 4 core @ 1.5 GHz |
| PS ARM Cortex-R5F | 2 core @ 600 MHz |
| PS DDR4 Controller | 1 (fino a 2400 MT/s) |

### Scheda ZCU102

| Componente | Dettaglio |
|---|---|
| PS DDR4 | 4 GB, 2400 MT/s, 64-bit |
| PL DDR4 | 512 MB (component option) |
| Flash QSPI | 512 Mb |
| SD Card slot | MicroSD (PS-side) |
| USB | 2× USB 3.0, 1× USB-UART (CP2108) |
| Ethernet | 2× GigE |
| PMOD | 4 connettori |
| FMC | 2× HPC, 1× LPC |
| JTAG | Header + USB-JTAG integrato |

### Clock disponibili

| Sorgente | Frequenza | Connesso a |
|---|---|---|
| Si570 user clock | 300 MHz (programmabile) | PL |
| US+ SS clock | 125 MHz differenziale | PL (usato nel design) |
| PS reference clock | 33.33 MHz | PS |

---

## 9. Confronto: BRAM vs DRAM vs SPM

| | BRAM (PL) | UltraRAM (PL) | PS DDR4 | PL DDR4 | SPM (LLC) |
|---|---|---|---|---|---|
| **Capacità totale** | ~4 MB | ~2.8 MB | 4 GB | 512 MB | 128 KB |
| **Latenza** | 1 clk (~2 ns) | 1 clk | ~50-100 ns | ~50-100 ns | 1-2 clk |
| **Bandwidth** | Altissimo | Alto | ~17 GB/s | ~2-4 GB/s | Alto |
| **Accesso dalla PL** | Diretto | Diretto | Via S_AXI_HP | Via MIG IP | Via AXI xbar |
| **Dual-port** | Sì | Sì (same clk) | No (singolo per porta) | No | No |
| **Controller necessario** | No | No | No (built-in PS) | Sì (MIG IP) | No (built-in) |
| **Consumo risorse FPGA** | Sì (contende con logica) | Sì | No | Sì (MIG usa LUT) | Sì (LLC logic) |
| **200 MB ci stanno?** | **NO** | **NO** | **SÌ** | **SÌ** | **NO** |

### Conclusione chiave

Per 200 MB di dati, l'unica opzione realistica è la **PS DDR4** (4 GB). La BRAM e la SPM sono ordini di grandezza troppo piccole.

---

## 10. Il block design MPSoC attuale

Il file `chs-bd-zcu102.tcl` crea il block design Vivado. Ecco cosa contiene:

```
┌─────────────────────────────────────────────────────┐
│                 Block Design MPSoC                   │
│                                                      │
│  ┌─────────────┐     ┌──────────┐                   │
│  │   Zynq PS   │────→│SmartConn.│──→┌──────────┐    │
│  │(A53, no DDR)│     └──────────┘   │AXI BRAM  │    │
│  │             │                    │Controller │    │
│  │M_AXI_HPM0  │──────────────────→ │(256KB)    │    │
│  │(32-bit)    │                    └────┬──────┘    │
│  └──────┬──────┘                        │           │
│         │                          BRAM_PORTA       │
│  ┌──────┴──────┐                  (export to PL)    │
│  │Proc Sys Rst │                        │           │
│  └─────────────┘                        │           │
│                                         ▼           │
│  ┌─────────────┐         ┌──────────────────┐       │
│  │  Clock Wiz  │──clk50──│      VIO         │       │
│  │ 125→50/48/  │──clk15──│  probe_out0..3   │       │
│  │   20/15 MHz │         │  probe_in0..1    │       │
│  └─────────────┘         └──────────────────┘       │
└─────────────────────────────────────────────────────┘
```

### Cosa c'è

- **Zynq PS**: ARM A53 attivo, M_AXI_HPM0 a 32 bit, DDR **disabilitato**, nessun S_AXI_HP
- **Clock Wizard**: 4 uscite (50, 48, 20, 15 MHz) da 125 MHz diff input
- **VIO**: 4 output probe (reset, boot_mode, boot_sel, uart_sel), 2 input probe
- **AXI BRAM Controller**: Single port, 256 KB, addr `0xA000_0000` nel PS
- **BRAM port**: Esportata verso la PL (connessa alla BRAM dual-port di ReckOn)
- **Proc Sys Reset**: Sincronizzatore reset

### Cosa NON c'è (e potrebbe servire)

- **DDR Controller PS abiltiato**: Disabilitato → nessun accesso ai 4 GB DDR4
- **Porte S_AXI_HP**: Non configurate → la PL non può accedere alla DDR
- **AXI DMA/CDMA**: Non istanziato → nessun engine DMA PS-side
- **Porte M_AXI aggiuntive**: Solo HPM0 usata → una sola via PS→PL

---

## 11. Xilinx IP utili per data movement

Per spostare 200 MB di dati dalla PS alla PL, potresti aver bisogno di queste IP Xilinx:

### AXI DMA (Xilinx)
- Trasferimenti scatter-gather tra PS DDR e stream/memory nella PL
- Supporta burst AXI4 per alto throughput

### AXI CDMA (Central DMA)
- Memory-to-memory: sposta blocchi tra due regioni di memoria AXI (es. DDR → PL memory)
- Più semplice dell'AXI DMA (no streaming)

### AXI SmartConnect
- Interconnessione AXI4 flessibile con clock crossing, data width conversion
- Già usato nel design per collegare PS a BRAM controller

### AXI Interconnect / Crossbar
- Simile a SmartConnect ma con più opzioni di configurazione manuale

### MIG (Memory Interface Generator) / DDR4
- Per usare la PL DDR4 (512 MB) — **non necessario se usi la PS DDR4 via S_AXI_HP**

---

*Guida specifica per ZCU102, design Cheshire + ReckOn, branch `main`.*
