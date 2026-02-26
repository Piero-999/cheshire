# Guida: Pipeline PS → DRAM → ReckOn SNN via AXI

## Obiettivo

Esporre ~200 MB di dati dalla PS (Processing System), metterli nella DRAM, e poi con Cheshire (RISC-V) comandare la SNN ReckOn ad andare a prenderli nella DRAM, tutto tramite AXI.

Questa guida analizza in dettaglio:
- Lo stato attuale dell'implementazione (cosa c'è già)
- Cosa manca e va costruito
- Le possibili architetture con pro/contro
- Un piano di implementazione step-by-step

---

## 1. Lo stato attuale — Cosa C'È GIÀ

### 1.1 Cheshire SoC con AXI Crossbar

Il SoC Cheshire integra un **AXI crossbar** con connettività completa (`Connectivity = '1`): qualsiasi master può raggiungere qualsiasi slave.

**Master del crossbar (porte di ingresso):**

| Indice | Master          | Descrizione                              |
|--------|-----------------|------------------------------------------|
| 0      | CVA6 core       | Il processore RISC-V                     |
| 1      | Debug module    | JTAG debug                               |
| 2      | iDMA            | Engine DMA hardware                      |
| (3+)   | ext_base...     | Master esterni (se `AxiExtNumMst > 0`)   |

**Slave del crossbar (porte di uscita):**

| Indice | Slave           | Indirizzo                    | Descrizione               |
|--------|-----------------|------------------------------|---------------------------|
| 0      | Debug           | `0x0000_0000 – 0x0004_0000` | Debug module              |
| 1      | DMA config      | `0x0100_0000 – 0x0100_1000` | Registri iDMA             |
| 2      | Reg demux       | `0x0200_0000 – 0x0C00_0000` | Periferiche (UART, etc.)  |
| 3      | LLC/SPM         | `0x1000_0000 – 0x1400_0000` | SPM cached (128 KB)       |
| 4      | SPM uncached    | `0x1400_0000 – 0x1800_0000` | SPM senza cache           |
| 5      | LLC out (DRAM)  | `0x8000_0000 – 0x1_0000_0000`| Finestra DRAM (2 GB)      |
| 6+     | ext_base...     | Configurabile                | Slave esterni             |

> **File:** `hw/cheshire_soc.sv` (crossbar), `hw/cheshire_pkg.sv` (address map)

### 1.2 iDMA Engine (✅ IMPLEMENTATO)

L'engine DMA hardware è **già presente e funzionante** nel design:

- **1D e 2D transfers**: `DmaConfEnableTwoD = 1` (abilitato di default)
- **16 transazioni AXI in flight**: `DmaNumAxInFlight = 16`
- **Job FIFO depth 2**: può accodare 2 trasferimenti
- **Full crossbar master**: può leggere/scrivere **qualsiasi** indirizzo del crossbar

**Registri iDMA** (base: `0x0100_0000`):

| Registro         | Funzione                          |
|------------------|-----------------------------------|
| `SRC_ADDR`       | Indirizzo sorgente (48 bit)       |
| `DST_ADDR`       | Indirizzo destinazione (48 bit)   |
| `NUM_BYTES`      | Numero byte da trasferire         |
| `CONF`           | Config (decouple, deburst, etc.)  |
| `NEXT_ID`        | Leggi per lanciare il trasferimento|
| `DONE`           | Polling: trasferimento completato?|
| `STRIDE_SRC`     | Stride sorgente (2D)              |
| `STRIDE_DST`     | Stride destinazione (2D)          |
| `NUM_REPETITIONS`| Numero righe (2D)                 |

**API Software** (`sw/include/dif/dma.h`):
```c
// 1D blocking memcpy
sys_dma_blk_memcpy(dst, src, size, conf);

// 2D blocking memcpy (per batch/tile streaming)
sys_dma_2d_blk_memcpy(dst, src, size, conf,
                       src_stride, dst_stride, num_reps);
```

> **Stato: ✅ Completamente implementato in HW e SW**

### 1.3 Porta AXI Slave Esterna → axi_layer → ReckOn (✅ IMPLEMENTATO)

La config `gen_cheshire_xilinx_cfg()` in `xilinx_zcu102_reckon_chs_top.sv` imposta:
```systemverilog
ret.AxiExtNumSlv = 1;  // 1 porta slave esterna
```

Questa porta esce dal crossbar Cheshire e si connette al blocco **`axi_layer`**, che:
1. Converte AXI4 full → AXI4-Lite (via `axi_to_axi_lite`)
2. Espone 8 registri di output (`out_reg[0..7]`) scrivibili dal crossbar
3. Espone 32 registri di input (`in_reg[0..31]`) leggibili dal crossbar

**Mappatura registri attuali:**

| out_reg | Nome             | Funzione                        |
|---------|------------------|---------------------------------|
| 0       | batch_size       | Dimensione batch ReckOn         |
| 1       | n_samples        | Numero campioni                 |
| 2       | do_eprop         | Modalità e-prop learning        |
| 3       | reckon_ctrl_i[0] | NEW_EPOCH                       |
| 4       | reckon_ctrl_i[1] | NEW_BATCH                       |
| 5       | reckon_ctrl_i[2] | TEST                            |
| 6       | reckon_ctrl_i[3] | STOP                            |
| 7       | debug[0]         | Flag debug (→ LED)              |

| in_reg  | Nome             | Funzione                        |
|---------|------------------|---------------------------------|
| 0       | infer_count      | Contatore inferenze ReckOn      |
| 1       | reckon_ctrl_o[0] | EPOCH_DONE                      |
| 2       | reckon_ctrl_o[1] | BATCH_DONE                      |

> **Stato: ✅ Cheshire può controllare ReckOn via questi registri**

### 1.4 BRAM Duale per Dati AER (✅ IMPLEMENTATO)

ReckOn ha una BRAM dual-port interna (`BRAM2_we_inst` in `reckon_axi_top.v`):

- **Capacità**: 2^16 = 65536 entry × 32 bit = **256 KB**
- **Porta A**: scrivibile dalla PS (via MPSoC → AXI BRAM Controller → BRAM port)
- **Porta B**: letta dall'`aer_decoder` di ReckOn (dati AER: code + data + tick)

**Formato dati AER** (32 bit per entry):
```
[31:28] unused | [27:24] code | [23:12] data | [11:0] tick
```

> **Stato: ✅ Funziona, ma è limitato a 256 KB — insufficiente per 200 MB**

### 1.5 PS → BRAM via MPSoC (✅ IMPLEMENTATO)

Il block design (`chs-bd-zcu102.tcl`) configura:
- **PS (Zynq UltraScale+)** con `M_AXI_HPM0` (32 bit, PS→PL)
- **SmartConnect** → **AXI BRAM Controller** a `0xA000_0000`
- La porta BRAM esce ed è collegata a `BRAM_PORTA` di `reckon_axi_top`

Flusso attuale: **PS scrive 256 KB di dati AER nella BRAM** → aer_decoder li legge → ReckOn li processa.

> **Stato: ✅ Funziona, ma solo per 256 KB**

---

## 2. Cosa NON È Implementato

### 2.1 PS DDR4 Controller (❌ DISABILITATO)

Nel block design TCL:
```tcl
CONFIG.PSU__DDRC__ENABLE {0}   # DDR4 controller SPENTO!
```

Il controller DDR4 della PS (che gestisce i **4 GB di DDR4** sulla ZCU102) è **esplicitamente disabilitato**. Senza di esso, la DRAM della board non è accessibile da nessuno.

> **Questo è il blocco fondamentale: nessuna DRAM disponibile nel design attuale.**

### 2.2 Porte S_AXI_HP (PL → PS DDR) (❌ NON CONFIGURATE)

Le porte **S_AXI_HP0-3** (High Performance) e **S_AXI_HPC0-1** (High Performance Coherent) della PS permettono ai master **nella PL** di accedere alla DDR4 della PS. Ma nel block design attuale **nessuna** è configurata.

Per portare dati dalla DRAM alla PL serve almeno una S_AXI_HP.

### 2.3 DRAM Path di Cheshire (❌ MORTO)

In `xilinx_zcu102_reckon_chs_top.sv`, il codice DRAM è condizionato a `USE_DDR`:
```systemverilog
`ifdef USE_DDR
  dram_wrapper_xilinx #(...) i_dram_wrapper (...);
`endif
```

Siccome `USE_DDR` **non è definito**, il `dram_wrapper_xilinx` **non viene mai istanziato**. Il segnale `axi_dram_mst_rsp` resta non driven (→ il crossbar Cheshire riceve una risposta nulla/errore per qualsiasi accesso a `0x8000_0000`–`0xFFFF_FFFF`).

### 2.4 Porta AXI Master Esterna (❌ TIE-OFF a '0)

In `cheshire_soc`, la porta `axi_ext_mst_req_i` permette a un master **esterno** (es. PS, DMA esterno) di accedere al crossbar Cheshire. Ma nel top-level:
```systemverilog
.axi_ext_mst_req_i  ( '0 ),   // MORTO — nessun master esterno collegato
```

Inoltre `DefaultCfg` ha `AxiExtNumMst = 0` (via `default: '0`), e `gen_cheshire_xilinx_cfg()` **non lo overrida**, quindi **il supporto per master esterni non è nemmeno sintetizzato**.

### 2.5 Nessun Meccanismo di Streaming DDR → BRAM (❌ NON ESISTE)

Non c'è nessuna logica per:
- Streamare dati dalla DDR alla BRAM di ReckOn a chunk
- Pingpong buffer tra DDR e BRAM
- DMA-driven refill della BRAM
- Interrupts o segnali di "BRAM vuota, riempimi"

---

## 3. Il Problema: 200 MB non entrano in 256 KB

| Memoria         | Capacità  | Accessibile da       | Stato       |
|-----------------|-----------|----------------------|-------------|
| BRAM ReckOn     | 256 KB    | PS (porta A), aer_decoder (porta B) | ✅ Attivo |
| SPM (LLC)       | 128 KB    | Cheshire crossbar    | ✅ Attivo   |
| BRAM PL totale  | ~4 MB     | Dipende da config    | Parziale    |
| UltraRAM PL     | ~2.8 MB   | Dipende da config    | Non usato   |
| **PS DDR4**     | **4 GB**  | **PS, PL (via S_AXI_HP)** | **❌ Spento** |
| PL DDR4 (MIG)   | 0–512 MB  | Cheshire (via USE_DDR) | ❌ Non istanziato |

**Unica opzione per 200 MB → PS DDR4 (4 GB)**. Tutto il resto è troppo piccolo.

---

## 4. Architetture Possibili

### 4.1 Architettura A: PS DDR4 + Cheshire iDMA + BRAM Chunking

```
┌──────────────────────────────────────────────────────────────────┐
│                        PS (ARM A53)                              │
│  1. Copia 200 MB dati AER in PS DDR4 (range 0x00_0000_0000+)    │
│  2. Segnala a Cheshire "dati pronti" (via registri/interrupt)    │
└────────────────────────────┬─────────────────────────────────────┘
                             │ S_AXI_HP0 (PL → PS DDR4)
                             │ 128-bit, fino a ~6.4 GB/s
┌────────────────────────────┴─────────────────────────────────────┐
│                      Cheshire SoC (PL)                           │
│                                                                  │
│   CVA6 (RISC-V) orchestra il flusso:                             │
│   ┌──────────┐    ┌──────────┐    ┌─────────────────┐            │
│   │   iDMA   │───►│ S_AXI_HP │───►│   PS DDR4       │            │
│   │ (master) │◄───│  (map a  │◄───│   (200MB dati)  │            │
│   │          │    │ 0x8000..)│    │                  │            │
│   └────┬─────┘    └──────────┘    └─────────────────┘            │
│        │                                                         │
│        │ DMA copia 256KB chunk in BRAM                           │
│        ▼                                                         │
│   ┌──────────┐    ┌──────────┐    ┌─────────────────┐            │
│   │  BRAM    │───►│aer_decode│───►│    ReckOn SNN    │            │
│   │ (256KB)  │    │          │    │   (256 neuroni)  │            │
│   └──────────┘    └──────────┘    └─────────────────┘            │
│                                                                  │
│   Loop: per ogni chunk da 256KB {                                │
│     1. iDMA: DDR[offset] → BRAM[0]                              │
│     2. CVA6 via axi_layer: ctrl_i → NEW_BATCH/NEW_EPOCH         │
│     3. Poll axi_layer in_reg: BATCH_DONE? → next chunk          │
│   }                                                              │
└──────────────────────────────────────────────────────────────────┘
```

**Pro:**
- Usa l'iDMA **già implementato** come data mover
- Il software CVA6 controlla tutto il flusso (facile da debuggare)
- ReckOn non va modificato (continua a leggere dalla BRAM)

**Contro:**
- Serve collegare la S_AXI_HP al crossbar Cheshire (modifiche HW)
- Latenza: ogni chunk 256 KB richiede ~5-10 µs via DMA + processing time
- ~800 chunk per 200 MB → overhead di gestione

**Modifiche richieste:**
| Cosa | File | Tipo |
|------|------|------|
| Abilitare PS DDR4 | `chs-bd-zcu102.tcl` | TCL block design |
| Aggiungere S_AXI_HP0 | `chs-bd-zcu102.tcl` | TCL block design |
| Connettere S_AXI_HP alla DRAM path | `xilinx_zcu102_reckon_chs_top.sv` | RTL |
| Mappare DDR nel crossbar Cheshire | `xilinx_zcu102_reckon_chs_top.sv` | RTL config |
| iDMA copia DDR→BRAM | `sw/tests/reckon_dram_test.c` | Software |
| Abilitare AxiExtNumMst (opzionale) | `xilinx_zcu102_reckon_chs_top.sv` | RTL config |

---

### 4.2 Architettura B: PS DDR4 + AXI Master Esterno (PS DMA diretto)

```
┌──────────────────────────────────────────────────────────────────┐
│                        PS (ARM A53)                              │
│  1. Copia dati in DDR4                                           │
│  2. Usa DMA PS-side per scrivere direttamente nella BRAM        │
│     attraverso M_AXI_HPM0 → SmartConnect → BRAM Controller      │
│  3. Notifica Cheshire quando il chunk è pronto                  │
└────────────────────────────┬─────────────────────────────────────┘
                             │ M_AXI_HPM0 (PS → PL, già presente!)
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                      BRAM (256KB, PL)                            │
│   PS scrive chunk, aer_decoder legge → ReckOn processa           │
└──────────────────────────────────────────────────────────────────┘
```

**Pro:**
- M_AXI_HPM0 è **già collegato** alla BRAM nel block design!
- La PS (ARM) ha il suo DMA controller (ZDMA) per bulk copy
- Cheshire e ReckOn non servono DRAM access dalla PL

**Contro:**
- La PS deve gestire il chunking (software Linux/bare-metal)
- Coordinamento PS↔Cheshire più complesso (shared memory? mailbox?)
- M_AXI_HPM0 è solo 32 bit → bandwidth limitata (~200 MB/s max teorico)
- Cheshire non "vede" la DDR → non può fare pre-processing sui dati

**Modifiche richieste:**
| Cosa | File | Tipo |
|------|------|------|
| Abilitare PS DDR4 | `chs-bd-zcu102.tcl` | TCL block design |
| Software PS per DMA chunking | (nuovo) | Software ARM (C) |
| Protocollo handshake PS↔Cheshire | via registri `axi_layer` | SW entrambi i lati |

---

### 4.3 Architettura C: PL DDR4 (MIG) + Cheshire nativo (il design "pulito")

```
┌──────────────────────────────────────────────────────────────────┐
│                        PS (ARM A53)                              │
│  1. Riceve 200MB via Ethernet/USB/SD                             │
│  2. Via M_AXI_HPM0 → AXI master esterno → scrive in PL DDR4    │
│     OPPURE via S_AXI_HP nella direzione inversa                  │
└────────────────────────────┬─────────────────────────────────────┘
                             │
┌────────────────────────────┴─────────────────────────────────────┐
│                      Cheshire SoC (PL)                           │
│                                                                  │
│   PL DDR4 (MIG IP) → dram_wrapper_xilinx                        │
│     Mapped @ 0x8000_0000 – 0xFFFF_FFFF (2 GB nativi)            │
│                                                                  │
│   CVA6 / iDMA accedono alla DDR4 nativamente                    │
│   iDMA copia da DDR4 PL → BRAM ReckOn a chunk                  │
└──────────────────────────────────────────────────────────────────┘
```

**Pro:**
- È il design "canonico" di Cheshire: DRAM mappata a `0x8000_0000`
- Cheshire vede la DDR nel suo address space nativo
- `dram_wrapper_xilinx` **esiste già** nel codice (basta definire `USE_DDR`)
- Prestazioni teoriche migliori (DDR4 a piena larghezza 64-bit)

**Contro:**
- La ZCU102 ha **un solo slot SODIMM per la PL** (max 4 GB, se presente)
- Richiede un DIMM fisicamente installato sulla board
- Il MIG IP è complesso (calibrazione, timing constraints, pin planning)
- Come fa la PS a scrivere i 200 MB nella PL DDR4? Serve un path PS→PL DDR

**Modifiche richieste:**
| Cosa | File | Tipo |
|------|------|------|
| Definire `USE_DDR` / `USE_DDR4` | Makefile/defines | Compilazione |
| Pin constraints DDR4 PL | `target/xilinx/constraints/` | XDC |
| Generare MIG IP | Vivado IP integrator | TCL/GUI |
| Path PS → PL DDR4 (ext master o M_AXI) | RTL + block design | HW |
| iDMA DDR→BRAM | Software CVA6 | SW |

---

### 4.4 Confronto Architetture

| Criterio          | A: PS DDR + iDMA | B: PS DDR + PS DMA | C: PL DDR (MIG) |
|-------------------|:-----------------:|:-------------------:|:----------------:|
| Complessità HW    | Media             | Bassa               | Alta             |
| Complessità SW    | Media             | Alta (PS+PL)        | Media            |
| Banda             | Alta (128b HP)    | Media (32b HPM)     | Alta (64b MIG)   |
| Risorse PL        | Basse             | Minime              | Alte (MIG)       |
| Modifiche RTL     | Significative     | Minime              | Significative    |
| DIMM extra?       | No                | No                  | Sì (fisico)      |
| Latenza chunk     | ~5 µs/chunk       | ~10 µs/chunk        | ~5 µs/chunk      |
| Chi controlla     | CVA6 (RISC-V)     | ARM A53             | CVA6 (RISC-V)    |

**Raccomandazione: Architettura A** — è il miglior compromesso perché:
1. Usa l'iDMA già implementato
2. CVA6 gestisce tutto il flusso (singolo punto di controllo)
3. Non richiede hardware aggiuntivo (DIMM)
4. La PS DDR4 è un componente on-board della ZCU102

---

## 5. Piano di Implementazione — Architettura A (Dettagliato)

### Step 1: Abilitare PS DDR4 nel Block Design

**File:** `target/xilinx/scripts/chs-bd-zcu102.tcl`

Cambiare:
```tcl
# PRIMA (attuale):
CONFIG.PSU__DDRC__ENABLE {0}

# DOPO:
CONFIG.PSU__DDRC__ENABLE {1}
```

Questo abilita il controller DDR4 nella PS, rendendo i 4 GB di DDR4 accessibili dallo spazio indirizzi PS: `0x00_0000_0000 – 0x00_7FFF_FFFF` (primi 2 GB DDR Low) e `0x08_0000_0000 – 0x08_7FFF_FFFF` (DDR High).

### Step 2: Aggiungere S_AXI_HP0 nel Block Design

**File:** `target/xilinx/scripts/chs-bd-zcu102.tcl`

Aggiungere alla configurazione della PS:
```tcl
set_property -dict [list \
  CONFIG.PSU__DDRC__ENABLE {1} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
  # ... (resto della config esistente)
] [get_bd_cells zynq_ultra_ps_e_0]
```

Spiegazione:
- `S_AXI_GP2` è il nome Vivado per **S_AXI_HP0** (le prime 2 GP sono i master, le successive sono gli HP)
- 128 bit di larghezza per massima bandwidth (~6.4 GB/s @ 50 MHz con burst)

Poi collegare l'interfaccia:
```tcl
# Creare porte per S_AXI_HP0
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_HP0
set_property -dict [list \
  CONFIG.DATA_WIDTH {128} \
  CONFIG.ADDR_WIDTH {49} \
  CONFIG.ID_WIDTH {6} \
  CONFIG.PROTOCOL {AXI4} \
] [get_bd_intf_ports S_AXI_HP0]

connect_bd_net [get_bd_pins /clk_wiz_0/clk_50] \
  [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]

connect_bd_intf_net [get_bd_intf_ports S_AXI_HP0] \
  [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
```

### Step 3: Collegare S_AXI_HP0 alla DRAM Path di Cheshire

**File:** `hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv`

L'idea: il segnale `axi_llc_mst_req` (che esce dall'LLC di Cheshire e normalmente va al DRAM controller) viene rediretto **verso S_AXI_HP0** della PS, che lo serve leggendo/scrivendo nella DDR4.

Bisogna fare **width conversion** perché:
- Cheshire crossbar usa: 48-bit addr, 64-bit data, `AxiSlvIdWidth`-bit ID
- S_AXI_HP0 accetta: 49-bit addr, 128-bit data, 6-bit ID

Soluzione con AXI Data Width Converter + AXI Protocol Converter (oppure SmartConnect):

```systemverilog
// Nella sezione DRAM MIG, sostituire:
// `ifdef USE_DDR
//   dram_wrapper_xilinx #(...) i_dram_wrapper (...);
// `endif

// CON:
`ifdef USE_MPSOC
  // Route LLC output → S_AXI_HP0 → PS DDR4
  // Potrebbe servire un axi_dw_converter (64→128 bit)
  // e un axi_id_remap se necessario
  
  // Connettere axi_llc_mst_req/rsp direttamente alla porta HP
  // (oppure attraverso un converter se i parametri non matchano)
  assign s_axi_hp0_req = axi_llc_mst_req;  // dopo conversion
  assign axi_llc_mst_rsp = s_axi_hp0_rsp;  // dopo conversion
`endif
```

**Nota importante sul width conversion**: se la S_AXI_HP0 è configurata a 128 bit nel block design, ma Cheshire produce 64 bit, serve un `axi_dw_converter` IP o un modulo equivalente. In alternativa, si può configurare S_AXI_HP0 a 64 bit:
```tcl
CONFIG.PSU__SAXIGP2__DATA_WIDTH {64}  # Match Cheshire data width
```

### Step 4: Aggiornare l'Address Mapping

Il crossbar Cheshire mappa la DRAM a `0x8000_0000 – 0xFFFF_FFFF` (2 GB). La PS DDR4 è a `0x00_0000_0000 – 0x7FFF_FFFF` (dal punto di vista PS).

Quando il crossbar Cheshire invia una richiesta a `0x8000_0000` sulla porta LLC, la S_AXI_HP0 deve tradurla nell'indirizzo fisico DDR4 della PS. Ci sono due opzioni:

**Opzione 1**: Address remapping nel RTL (sottrarre `0x8000_0000` prima di inviare a S_AXI_HP0)

**Opzione 2**: Configurare la S_AXI_HP0 window nel PS per accettare range `0x8000_0000–0xFFFF_FFFF` (possibile via Vivado address editor)

### Step 5: Software CVA6 — Chunking Loop

Una volta che il path DRAM funziona, CVA6 può accedere a `0x8000_0000` per leggere dalla DDR4 della PS. Il flusso:

```c
#include "dif/dma.h"
#include "dif/uart.h"

// Indirizzi
#define DDR_BASE       0x80000000ULL   // PS DDR4 vista da Cheshire
#define BRAM_BASE      0xXXXXXXXXULL   // Indirizzo BRAM ReckOn (da definire)
#define CHUNK_SIZE     (256 * 1024)     // 256 KB = dimensione BRAM ReckOn
#define TOTAL_SIZE     (200 * 1024 * 1024)  // 200 MB

// Registri ReckOn (via axi_layer, ext slave del crossbar)
#define RECKON_BASE    0xXXXXXXXXULL   // Da mappare nel crossbar
#define REG_BATCH_SIZE (RECKON_BASE + 0*8)
#define REG_N_SAMPLES  (RECKON_BASE + 1*8)
#define REG_DO_EPROP   (RECKON_BASE + 2*8)
#define REG_CTRL_I0    (RECKON_BASE + 3*8)  // NEW_EPOCH
#define REG_CTRL_I1    (RECKON_BASE + 4*8)  // NEW_BATCH
// ...

volatile uint32_t* reckon_reg(uint64_t addr) {
    return (volatile uint32_t*)addr;
}

int main(void) {
    // Configurazione iniziale ReckOn
    *reckon_reg(REG_BATCH_SIZE) = 128;   // es. batch di 128 campioni
    *reckon_reg(REG_N_SAMPLES)  = ...;
    *reckon_reg(REG_DO_EPROP)   = 0;     // inference only
    
    uint64_t ddr_offset = 0;
    int num_chunks = TOTAL_SIZE / CHUNK_SIZE;  // ~800 chunks
    
    for (int chunk = 0; chunk < num_chunks; chunk++) {
        // 1. DMA: copia 256 KB da DDR → BRAM
        sys_dma_blk_memcpy(
            BRAM_BASE,                    // destinazione: BRAM ReckOn
            DDR_BASE + ddr_offset,        // sorgente: DDR4 PS
            CHUNK_SIZE,                   // 256 KB
            0                              // conf: no decouple/deburst
        );
        
        // 2. Avvia batch ReckOn
        *reckon_reg(REG_CTRL_I1) = 1;    // NEW_BATCH = 1
        *reckon_reg(REG_CTRL_I1) = 0;    // Pulse
        
        // 3. Attendi completamento
        while (!(*reckon_reg(RECKON_BASE + 0x28) & 1)) {
            // Poll BATCH_DONE (in_reg[2])
            asm volatile("nop");
        }
        
        // 4. (Opzionale) Leggi risultati inferenza
        uint32_t infer = *reckon_reg(RECKON_BASE + 0x20);  // in_reg[0]
        
        ddr_offset += CHUNK_SIZE;
    }
    
    return 0;
}
```

### Step 6: Software PS — Caricare Dati nella DDR4

Lato PS (ARM A53, es. bare-metal o Linux):

```c
// Bare-metal su ARM A53
#include <stdint.h>

#define DDR_DATA_BASE  0x10000000UL  // Regione DDR4 dedicata ai dati AER
// (scegliere un'area non usata dal sistema operativo)

void load_aer_data(const uint8_t* source, size_t size) {
    // source potrebbe venire da: SD card, Ethernet, USB, UART
    volatile uint8_t* ddr = (volatile uint8_t*)DDR_DATA_BASE;
    
    for (size_t i = 0; i < size; i++) {
        ddr[i] = source[i];
    }
    
    // Flush cache ARM per garantire che i dati siano in DDR
    // (necessario se si usa la cache L1/L2 della PS)
    __asm__ volatile("dsb sy");
    
    // Segnalare a Cheshire che i dati sono pronti
    // (via registri condivisi, interrupt, o polling)
}
```

---

## 6. Il Problema della BRAM: iDMA e Porta di Accesso

### Situazione critica

La BRAM di ReckOn ha **due porte** e sono **entrambe occupate**:
- **Porta A** → PS (via MPSoC AXI BRAM Controller)  
- **Porta B** → `aer_decoder` (read-only, interna a ReckOn)

Se iDMA deve scrivere nella BRAM, serve **una terza via di accesso**, che non esiste in una true dual-port BRAM.

### Soluzioni possibili

#### 6.1 Usare iDMA al posto della PS (sostituire Porta A)

Invece di far scrivere la PS nella BRAM, si fa scrivere **iDMA** (Cheshire) nella BRAM.

**Richiede:**
1. Collegare la Porta A della BRAM **al crossbar Cheshire** (come slave esterno) anziché alla PS
2. Mappare la BRAM nell'address space Cheshire (es. `AxiExtRegionStart[1]`)
3. iDMA copia: DDR(`0x8000_0000 + offset`) → BRAM(`0xYYYY_YYYY`)

**Modifiche:**
- `gen_cheshire_xilinx_cfg()`: cambiare `AxiExtNumSlv = 2` (1 per axi_layer registri, 1 per BRAM)
- Aggiungere address rules per la BRAM nell'address map
- Creare un secondo `axi_ext_slv` tipo AXI BRAM controller
- Oppure: instradare la Porta A via SmartConnect con arbitraggio multiplo (PS **e** Cheshire)

#### 6.2 Mantenere la PS come writer di BRAM (Architettura B ibrida)

La PS continua a scrivere nella BRAM come fa ora, ma legge i dati dalla **DDR4 PS** (che ora è abilitata):

```
PS DDR4 (200MB) --[memcpy ARM interno]--> PS AXI HPM0 → BRAM (256KB chunk)
```

Questo richiede **zero modifiche RTL** (solo abilitare DDR4 nel TCL e scrivere SW lato PS).

#### 6.3 Aggiungere un AXI Interconnect davanti alla BRAM

Mettere un **AXI SmartConnect** (o equivalente) con 2 porte master davanti alla porta A della BRAM:
- Master 0: PS (via M_AXI_HPM0)
- Master 1: Cheshire (iDMA, via ext slave port)

```
PS ──────┐                  ┌──── Porta A BRAM
         ├── SmartConnect ──┤
Cheshire ┘                  └──── (arbitra tra PS e Cheshire)
```

> **Nota bene per l'eventuale soluzione 6.1**: nel design attuale la BRAM è un modulo RTL (`BRAM2_we_inst`) istanziato direttamente in `reckon_axi_top.v`, NON un IP Vivado. Quindi per collegare una porta AXI serve wrappare con un AXI BRAM controller (Xilinx IP), oppure usare quello già instanziato nel block design e ricollegarne il path.

---

## 7. Approccio Consigliato: Architettura A + Soluzione 6.2

L'approccio più pragmatico minimizza le modifiche RTL:

### Flusso proposto

```
╔════════════════════════════════════════════════════════════════╗
║                     PS (ARM A53 + DDR4)                        ║
║                                                                ║
║  1. Carica 200 MB sulla DDR4 della PS                          ║
║  2. Loop: per ogni chunk da 256 KB {                           ║
║       a. Copia DDR → BRAM via M_AXI_HPM0 (32-bit, ~200MB/s)  ║
║       b. Segnala a Cheshire "chunk pronto" (via BRAM o flag)  ║
║       c. Attende segnale "chunk processato" da Cheshire       ║
║     }                                                          ║
╚════════════════════════╤═══════════════════════════════════════╝
                         │ M_AXI_HPM0 (già cablato alla BRAM)
                         ▼
╔════════════════════════════════════════════════════════════════╗
║                  BRAM 256KB (PL, dual-port)                    ║
║  Porta A ← PS scrive dati AER                                 ║
║  Porta B → aer_decoder legge → ReckOn processa                ║
╚════════════════════════════════════════════════════════════════╝
                         │ out_reg / in_reg (axi_layer)
                         │
╔════════════════════════╧═══════════════════════════════════════╗
║                   Cheshire SoC (RISC-V CVA6)                   ║
║                                                                ║
║  1. Configura ReckOn via axi_layer (batch_size, n_samples...)  ║
║  2. Loop: per ogni chunk {                                     ║
║       a. Attende segnale "chunk pronto" dalla PS               ║
║       b. Comanda NEW_BATCH a ReckOn (via axi_layer out_reg)   ║
║       c. Polling BATCH_DONE (via axi_layer in_reg)            ║
║       d. Segnala "chunk processato" alla PS                    ║
║     }                                                          ║
║  3. Colleziona risultati inferenza                             ║
╚════════════════════════════════════════════════════════════════╝
```

### Modifiche richieste (minimali)

| # | Cosa | File | Tipo | Difficoltà |
|---|------|------|------|------------|
| 1 | Abilitare PS DDR4 | `chs-bd-zcu102.tcl` | TCL | ⭐ Facile |
| 2 | SW PS: load dati + chunking loop | (nuovo) arm_loader.c | SW ARM | ⭐⭐ Media |
| 3 | Handshake PS↔Cheshire | Può usare i registri esistenti di `axi_layer` | SW | ⭐⭐ Media |
| 4 | SW CVA6: orchestrazione ReckOn | (nuovo) `sw/tests/reckon_dram.c` | SW RISC-V | ⭐⭐ Media |

**Nessuna modifica RTL** necessaria (a parte il TCL per DDR4).

### Handshake PS↔Cheshire via axi_layer

L'`axi_layer` ha 8 registri output (Cheshire→ReckOn) e 32 registri input (ReckOn→Cheshire). Attualmente solo 8 out e 3 in sono usati. Si possono riusare i rimanenti per il protocollo di handshake:

| Registro | Direzione | Significato proposto |
|----------|-----------|---------------------|
| `out_reg[7]` | Cheshire → | bit[1]: CHUNK_PROCESSED (ho finito, manda il prossimo) |
| `in_reg[3]` | → Cheshire | CHUNK_READY (PS ha scritto un nuovo chunk nella BRAM) |
| `in_reg[4]` | → Cheshire | CHUNK_INDEX (indice del chunk corrente, 0..799) |

**Problema**: i registri `in_reg` di `axi_layer` sono **letti** da Cheshire ma **scritti** da chi? Attualmente sono collegati a segnali di ReckOn (`infer_count`, `ctrl_o`). La PS **non** può scriverli direttamente perché non ha un path verso il lato "input" di `axi_layer`.

**Soluzione pragmatica**: Usare la **BRAM stessa** come canale di comunicazione. Dato che la BRAM è visibile sia dalla PS (porta A) sia da ReckOn (porta B, ma read-only), si può:
- Riservare gli ultimi N indirizzi della BRAM come "mailbox"
- La PS scrive `BRAM[0xFFFC] = chunk_index` e `BRAM[0xFFF8] = CHUNK_READY_MAGIC`
- Il software CVA6 legge queste locazioni per sapere quando un chunk è pronto

...ma CVA6 (Cheshire) **non ha accesso diretto alla BRAM** nel design attuale!

### Alternativa handshake: VIO + Interrupt

Un'alternativa più semplice per il prototipo:
1. PS scrive il chunk nella BRAM
2. PS segnala via **GPIO** o **interrupt PS→PL** (collegabile a `intr_ext_i` di Cheshire)
3. Cheshire riceve l'interrupt, comanda ReckOn, e al termine segnala via GPIO/LED

---

## 8. Architettura A "Full" — Con iDMA Come Data Mover

Se si vuole la soluzione più performante e "pulita" dal punto di vista architetturale, serve investire in più modifiche HW:

### 8.1 Modifiche RTL necessarie

#### a) Config Cheshire: aggiungere master esterno e secondo slave esterno

```systemverilog
// In gen_cheshire_xilinx_cfg():
ret.AxiExtNumMst    = 0;      // Non serve master esterno per questa architettura
ret.AxiExtNumSlv    = 2;      // 2 slave esterni: axi_layer + BRAM
ret.AxiExtNumRules  = 2;      // 2 regole di routing
// Slave 0: axi_layer (registri) @ 0x2000_0000 – 0x2000_1000
ret.AxiExtRegionIdx   [0] = 0;
ret.AxiExtRegionStart [0] = 64'h2000_0000;
ret.AxiExtRegionEnd   [0] = 64'h2000_1000;
// Slave 1: BRAM (256KB) @ 0x2001_0000 – 0x2005_0000
ret.AxiExtRegionIdx   [1] = 1;
ret.AxiExtRegionStart [1] = 64'h2001_0000;
ret.AxiExtRegionEnd   [1] = 64'h2005_0000;
```

#### b) Collegare il secondo slave esterno alla BRAM

```systemverilog
// axi_ext_slv_req_o[0] → axi_layer (esistente)
// axi_ext_slv_req_o[1] → AXI BRAM controller → BRAM Porta A

// Serve un AXI BRAM controller che converte AXI4 → segnali BRAM
// (Xilinx IP `axi_bram_ctrl` oppure wrapper RTL)
axi_bram_ctrl_wrapper #(...) i_axi_bram_ctrl (
    .s_axi_req  (axi_slv_i[1]),
    .s_axi_rsp  (axi_slv_o[1]),
    .bram_addr  (AERAM_add),
    .bram_clk   (AERAM_clk),
    .bram_din   (AERAM_din),
    .bram_dout  (AERAM_dout),
    .bram_en    (AERAM_cs),
    .bram_rst   (AERAM_rst),
    .bram_we    (AERAM_we)
);
```

#### c) Collegare la DRAM path a S_AXI_HP0

Come descritto nello Step 3 della Sezione 5.

#### d) Disconnettere la PS dalla BRAM

La PS non scrive più direttamente nella BRAM; il path M_AXI_HPM0→BRAM Controller nel block design diventa inutile (o viene mantenuto come fallback).

### 8.2 Flusso Software (tutto su CVA6)

```c
// CVA6 bare-metal — tutto gestito dal RISC-V
#define DDR_BASE    0x80000000ULL  // PS DDR4 via S_AXI_HP0
#define BRAM_BASE   0x20010000ULL  // BRAM via ext slave[1]
#define RECKON_REG  0x20000000ULL  // axi_layer via ext slave[0]
#define CHUNK_SIZE  (256 * 1024)
#define TOTAL_SIZE  (200 * 1024 * 1024)

int main(void) {
    // Config ReckOn
    *(volatile uint32_t*)(RECKON_REG + 0*8) = 128;  // batch_size
    *(volatile uint32_t*)(RECKON_REG + 1*8) = 1000; // n_samples
    *(volatile uint32_t*)(RECKON_REG + 2*8) = 0;    // inference
    
    int num_chunks = TOTAL_SIZE / CHUNK_SIZE;
    
    for (int c = 0; c < num_chunks; c++) {
        // iDMA: DDR → BRAM (256 KB)
        sys_dma_blk_memcpy(
            BRAM_BASE,
            DDR_BASE + (uint64_t)c * CHUNK_SIZE,
            CHUNK_SIZE,
            0  // conf
        );
        
        // Start batch
        *(volatile uint32_t*)(RECKON_REG + 4*8) = 1; // NEW_BATCH
        *(volatile uint32_t*)(RECKON_REG + 4*8) = 0; // Clear
        
        // Wait BATCH_DONE
        while (!(*(volatile uint32_t*)(RECKON_REG + 0x28) & 1))
            ;
    }
    return 0;
}
```

**Vantaggio chiave**: il CVA6 controlla **tutto** — iDMA muove i dati, CVA6 orchestra ReckOn. La PS deve solo caricare i 200 MB in DDR4 e poi può andare in idle.

---

## 9. Riepilogo: Cosa Esiste vs Cosa Serve

### ✅ Già implementato e funzionante

| Componente | Dove | Funzione |
|------------|------|----------|
| Cheshire SoC + CVA6 | `cheshire_soc.sv` | Processore RISC-V + crossbar AXI |
| iDMA 1D/2D | `cheshire_idma_wrap.sv` | DMA engine con API SW |
| axi_layer + registri | `axi_layer.sv` | Bridge Cheshire↔ReckOn (8 out, 32 in) |
| ReckOn SNN | `reckon_axi_top.v` | Rete SNN 256 neuroni |
| BRAM 256KB | `reckon_axi_top.v` | Storage dati AER dual-port |
| PS→BRAM path | `chs-bd-zcu102.tcl` | M_AXI_HPM0 → BRAM Controller |
| AxiExtNumSlv=1 | `xilinx_zcu102_reckon_chs_top.sv` | 1 porta slave esterna |
| Clock generation | Block design + RTL | 50/48/20/15 MHz |
| VIO debug | Block design | Reset, boot mode, UART select |

### ❌ Non implementato (da costruire)

| Componente | Priorità | Architettura A | Architettura B |
|------------|----------|:--------------:|:--------------:|
| PS DDR4 enabled | **Critico** | ✅ Serve | ✅ Serve |
| S_AXI_HP0 (PL→PS DDR) | **Critico per A** | ✅ Serve | ❌ Non serve |
| DRAM path Cheshire | **Critico per A** | ✅ Da collegare | ❌ Non serve |
| BRAM come ext slave | Utile per A | ✅ Da aggiungere | ❌ Non serve |
| SW chunking loop | **Critico** | Lato CVA6 | Lato ARM PS |
| Protocollo handshake | **Critico per B** | Non serve | ✅ Serve |
| Address remapping | Media | Possibile | N/A |

### ⚠️ Parzialmente implementato

| Componente | Stato | Cosa manca |
|------------|-------|------------|
| AxiExtNumMst | Codice esiste in `cheshire_soc.sv` | Config a 0 in FPGA, tie-off a '0 |
| dram_wrapper_xilinx | Modulo RTL esiste | `USE_DDR` non definito |
| Ext slave address map | Infrastruttura c'è | `AxiExtNumRules=0`, nessun indirizzo mappato per ext slave |

---

## 10. Stima Tempi e Performance

### Bandwidth per chunk (256 KB)

| Path | Larghezza | Frequenza | BW teorica | Tempo 256KB |
|------|-----------|-----------|------------|-------------|
| S_AXI_HP0 (128b) | 128 bit | 50 MHz | 800 MB/s | ~0.3 ms |
| S_AXI_HP0 (64b) | 64 bit | 50 MHz | 400 MB/s | ~0.6 ms |
| M_AXI_HPM0 (32b) | 32 bit | 50 MHz | 200 MB/s | ~1.3 ms |
| iDMA interno | 64 bit | 50 MHz | 400 MB/s | ~0.6 ms |

### Tempo totale per 200 MB (800 chunk)

| Scenario | Tempo DMA/chunk | Tempo ReckOn/chunk* | Totale stimato |
|----------|-----------------|---------------------|----------------|
| Arch. A (S_AXI_HP 128b) | ~0.3 ms | ~1-10 ms | ~1-8 s |
| Arch. A (S_AXI_HP 64b) | ~0.6 ms | ~1-10 ms | ~1.3-8.5 s |
| Arch. B (HPM0 32b) | ~1.3 ms | ~1-10 ms | ~1.8-9 s |

*Il tempo di processing ReckOn dipende da: batch_size, n_samples, configurazione SNN.

### Ottimizzazione: Double Buffering

Per nascondere la latenza del DMA, si può implementare un **double buffer**:

1. Dividere la BRAM in 2 metà da 128 KB
2. Mentre ReckOn processa la metà A, iDMA carica la metà B
3. Al termine, swap e ripeti

Questo richiede modificare l'`aer_decoder` per lavorare su metà BRAM, ma eliminerebbe quasi tutto l'overhead di trasferimento.

---

## 11. Glossario Rapido

| Termine | Significato |
|---------|-------------|
| **PS** | Processing System — ARM A53 quad-core + DDR controller + periferiche |
| **PL** | Programmable Logic — FPGA fabric (LUT, BRAM, UltraRAM, DSP) |
| **M_AXI_HPM** | Master AXI High Performance Master — PS è master, PL è slave |
| **S_AXI_HP** | Slave AXI High Performance — PL è master, PS (DDR) è slave |
| **S_AXI_HPC** | Come S_AXI_HP ma con coerenza cache (CCI) |
| **iDMA** | Integrated DMA — engine DMA dentro Cheshire, master del crossbar |
| **LLC** | Last-Level Cache — 128KB, può funzionare come SPM |
| **SPM** | Scratchpad Memory — memoria SRAM mappata in address space |
| **MIG** | Memory Interface Generator — Xilinx IP per DDR nel PL |
| **AER** | Address-Event Representation — formato dati per SNN |
| **ext slave** | Porta output del crossbar Cheshire verso IP esterni |
| **ext master** | Porta input del crossbar Cheshire da IP esterni |
| **VIO** | Virtual I/O — Xilinx debug IP per controllare segnali via JTAG |
| **SmartConnect** | Xilinx AXI interconnect IP con protocol/width conversion |
