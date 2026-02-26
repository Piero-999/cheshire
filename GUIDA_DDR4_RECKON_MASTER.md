# Guida: ReckOn Legge dalla DDR4 via AXI — Architettura Dettagliata

## 0. Coerenza con la Richiesta Originale

La tua richiesta era:

> *"Esporre ~200 MB di dati dalla PS, metterli sulla DRAM, e poi con Cheshire dire alla SNN di andarli a prendere lì nella DRAM, tutto tramite AXI"*

E ora chiarisci:

> *"Deve essere ReckOn che va a prendere i dati dalla DRAM. Cheshire deve fornire a ReckOn l'indirizzo AXI a cui prendere i dati."*

**Le guide precedenti (GUIDA_PS_DRAM_SNN.md) propongono architetture NON coerenti con questa richiesta.** Quelle architetture "pushano" i dati nella BRAM di ReckOn (tramite iDMA o PS DMA), e ReckOn li legge localmente dalla BRAM. In quel caso ReckOn non va a prendere niente dalla DRAM — è passivo.

**Quello che vuoi è fondamentalmente diverso:**

| Aspetto | Guide precedenti (ERRATO) | Tua richiesta (CORRETTO) |
|---------|---------------------------|--------------------------|
| Chi muove i dati | iDMA o PS DMA | **ReckOn stesso** |
| ReckOn legge da | BRAM locale (256 KB) | **DRAM (200 MB) via AXI** |
| Ruolo di Cheshire | Copia dati e controlla | **Fornisce l'indirizzo, non muove dati** |
| ReckOn come AXI | Solo slave (registri) | **Deve diventare anche master** |
| BRAM | Usata come buffer | **Non serve più (o serve come cache)** |

Questa guida descrive la **corretta architettura**: ReckOn diventa un AXI master, legge direttamente dalla DRAM, e Cheshire gli dice solo "a che indirizzo andare".

---

## 1. Architettura Target

```
╔══════════════════════════════════════════════════════════════════════╗
║                          PS (ARM A53)                                ║
║                                                                      ║
║  1. Carica 200 MB di dati AER nella DDR4 della PS                    ║
║     (da SD card, Ethernet, USB, ecc.)                                ║
║  2. Comunica a Cheshire "dati pronti a indirizzo X"                  ║
║     (via registri condivisi, interrupt, o semplicemente              ║
║      Cheshire conosce già dove sono)                                 ║
╚══════════════════════════╤═══════════════════════════════════════════╝
                           │
                           │  S_AXI_HP0 (PL → PS DDR4)
                           │  Il path che permette ai master nella PL
                           │  di leggere/scrivere la DDR4 della PS
                           │
╔══════════════════════════╧═══════════════════════════════════════════╗
║                     AXI Crossbar Cheshire                            ║
║                                                                      ║
║  ┌─────────────────────────────────────────────────────────────┐     ║
║  │                    AXI CROSSBAR (Connectivity = '1)          │     ║
║  │                                                              │     ║
║  │  MASTER (Input) Ports:                                       │     ║
║  │    [0] CVA6 core (RISC-V)                                    │     ║
║  │    [1] Debug module                                          │     ║
║  │    [2] iDMA                                                  │     ║
║  │    [3] ★ ReckOn AXI Reader (NUOVO - ext master) ★           │     ║
║  │                                                              │     ║
║  │  SLAVE (Output) Ports:                                       │     ║
║  │    [0] Debug       (0x0000_0000)                             │     ║
║  │    [1] DMA config  (0x0100_0000)                             │     ║
║  │    [2] Reg demux   (0x0200_0000)                             │     ║
║  │    [3] SPM cached  (0x1000_0000)                             │     ║
║  │    [4] SPM uncached(0x1400_0000)                             │     ║
║  │    [5] LLC out→DRAM(0x8000_0000 – 0xFFFF_FFFF) → S_AXI_HP  │     ║
║  │    [6] axi_layer   (ext slave - registri ReckOn)             │     ║
║  │                                                              │     ║
║  └─────────────────────────────────────────────────────────────┘     ║
║                                                                      ║
║  CVA6 scrive in axi_layer:                                           ║
║    out_reg[0] = DRAM_BASE_ADDR_LO (32 bit bassi dell'indirizzo)     ║
║    out_reg[1] = DRAM_BASE_ADDR_HI (32 bit alti, opzionale)          ║
║    out_reg[2] = batch_size, n_samples, do_eprop...                   ║
║    out_reg[3] = NEW_EPOCH (start!)                                   ║
║                                                                      ║
║  ★ ReckOn AXI Reader (NUOVO modulo) ★                               ║
║  ┌───────────────────────────────────────────────────────────┐       ║
║  │                                                           │       ║
║  │  Input: base_addr (da axi_layer out_reg)                  │       ║
║  │  Input: CS, RAM_ADDR (da aer_decoder — non cambia!)       │       ║
║  │  Output: DIN (32 bit dato AER → aer_decoder)              │       ║
║  │                                                           │       ║
║  │  Quando aer_decoder chiede un dato:                       │       ║
║  │    1. Calcola: axi_addr = base_addr + RAM_ADDR × 4       │       ║
║  │    2. Emette AXI AR (read request) sul crossbar           │       ║
║  │    3. Riceve AXI R (read data) dal crossbar               │       ║
║  │    4. Passa i 32 bit a DIN per aer_decoder                │       ║
║  │                                                           │       ║
║  │  AXI Master Port → crossbar input [3] (ext master)       │       ║
║  │                                                           │       ║
║  └───────────────────────────────────────────────────────────┘       ║
║         │                                                            ║
║         ▼                                                            ║
║  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐        ║
║  │ aer_decoder   │───▶│  reckon SNN  │───▶│  Risultati      │        ║
║  │ (invariato!)  │    │  (invariato!)│    │  (infer_count)   │        ║
║  └──────────────┘    └──────────────┘    └──────────────────┘        ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## 2. Cosa Cambia Rispetto al Design Attuale

### 2.1 Oggi (design attuale)

```
aer_decoder ──CS/RAM_ADDR──▶ BRAM (porta B, read-only) ──DIN──▶ aer_decoder
                             BRAM (porta A, write)     ◀────── PS via M_AXI_HPM0
```

- `aer_decoder` genera `RAM_ADDR` (16 bit) e `CS` (chip select)
- La BRAM risponde con `DIN` (32 bit) in **1 ciclo di clock** (sincrona)
- La PS pre-carica la BRAM con i 256 KB di dati AER

### 2.2 Domani (architettura target)

```
aer_decoder ──CS/RAM_ADDR──▶ ★ reckon_dram_reader ★ ──DIN──▶ aer_decoder
                                     │
                                     │ AXI Master Port
                                     ▼
                              AXI Crossbar Cheshire
                                     │
                                     ▼
                              LLC out → S_AXI_HP0 → PS DDR4 (200 MB)
```

- `aer_decoder` genera lo **stesso** `RAM_ADDR` e `CS` — **non cambia**
- Il nuovo modulo `reckon_dram_reader` traduce `RAM_ADDR` in un indirizzo AXI
- Legge dalla DRAM via il crossbar Cheshire
- La risposta arriva in **N cicli** (latenza AXI, ~10-50 cicli)
- Serve un meccanismo per gestire la latenza (stallo o prefetch)

---

## 3. Analisi Dettagliata: Come aer_decoder Accede alla Memoria

Dall'analisi del codice in `aer_decoder.v`, l'interfaccia memoria è questa:

### 3.1 La FSM di Lettura (Memory Interface FSM)

```
Stati: MEM_IDLE → MEM_READ1 → MEM_READ2 → MEM_IDLE

MEM_IDLE:   CS=0, data_ram_valid=0
            Se READ=1 → MEM_READ1

MEM_READ1:  CS=1, data_ram_valid=0    ← "chip select attivo, la BRAM inizia a leggere"
            → MEM_READ2 (automatico, 1 ciclo)

MEM_READ2:  CS=0, data_ram_valid=1    ← "dato pronto su DIN, lo campiono"
            ADD_REG_EN=1              ← "incrementa RAM_ADDR per la prossima lettura"
            → MEM_IDLE
```

**Tempi**: la FSM assume che il dato sia disponibile su `DIN` **1 ciclo dopo** che `CS` va alto. Questo è esattamente il comportamento di una BRAM sincrona.

### 3.2 Come RAM_ADDR Avanza

```verilog
// Da aer_decoder.v, riga ~580:
always @(posedge CLK) begin
    if ((curr_state == IDLE) || (curr_state == END_E) || (curr_state == END_B))
        RAM_ADDR_reg <= {ADDR_WIDTH{1'b0}};          // Reset a 0
    else if (ADD_REG_EN)
        RAM_ADDR_reg <= RAM_ADDR + {{ADDR_WIDTH-2{1'b0}}, 1'd1};  // +1
end
```

Quindi `RAM_ADDR` parte da 0 e **incrementa di 1** ad ogni dato letto. La lettura è **strettamente sequenziale**.

### 3.3 Segnali Chiave

| Segnale | Direzione | Larghezza | Funzione |
|---------|-----------|-----------|----------|
| `CS` | aer_decoder → memoria | 1 bit | Chip select: "leggi ora" |
| `RAM_ADDR` | aer_decoder → memoria | 16 bit | Indirizzo (0 – 65535) |
| `DIN` | memoria → aer_decoder | 32 bit | Dato letto (AER format) |
| `READ` | FSM principale → memory FSM | 1 bit | "voglio leggere" (trigger) |
| `data_ram_valid` | memory FSM → FSM principale | 1 bit | "il dato è pronto" |

### 3.4 Il Punto Critico: Timing a 1 Ciclo

La FSM assume:
1. Ciclo N: `CS=1` (richiesta)
2. Ciclo N+1: `data_ram_valid=1`, `DIN` ha il dato valido

Con la DRAM via AXI, il dato arriva dopo **~10-50 cicli** (latenza AXI + DDR4). Bisogna **modificare la memory FSM** di `aer_decoder` per supportare latenza variabile, OPPURE mettere un buffer/FIFO nel modulo `reckon_dram_reader` che nasconde la latenza facendo **prefetch**.

---

## 4. Il Nuovo Modulo: `reckon_dram_reader`

### 4.1 Concetto

Questo modulo si inserisce tra `aer_decoder` e il crossbar AXI di Cheshire:

```
                    reckon_dram_reader
                 ┌────────────────────────────┐
 aer_decoder ──▶ │  CS, RAM_ADDR              │
                 │                            │──▶ AXI Master (AR/R)
 aer_decoder ◀── │  DIN, data_ready           │    verso crossbar
                 │                            │◀── Cheshire
 axi_layer   ──▶ │  base_addr (48 bit)        │
 (registri)      │  prefetch_en, start        │
                 └────────────────────────────┘
```

### 4.2 Funzionamento

**Modalità semplice (senza prefetch):**

1. Cheshire scrive `base_addr` in un registro (via axi_layer)
   - Es: `base_addr = 0x8000_0000` (inizio area DRAM dove la PS ha messo i dati)
2. `aer_decoder` asserisce `CS=1` con `RAM_ADDR = N`
3. `reckon_dram_reader` calcola: `axi_addr = base_addr + N × 4`
4. Emette una transazione AXI AR (read request) con quell'indirizzo
5. Attende la risposta AXI R (read data)
6. Mette il dato su `DIN` e segnala `data_ready`
7. `aer_decoder` campiona il dato

**Modalità con prefetch (per performance):**

1. All'avvio, `reckon_dram_reader` fa burst read di un blocco (es. 256 entry = 1 KB)
2. Riempe un **piccolo FIFO/buffer** interno
3. Quando `aer_decoder` chiede un dato, lo preleva dal buffer (1 ciclo!)
4. Quando il buffer si svuota, lancia un nuovo burst AXI
5. Questo nasconde la latenza DRAM quasi completamente

### 4.3 Interfaccia del Modulo (proposta)

```systemverilog
module reckon_dram_reader #(
    parameter int unsigned AddrWidth    = 48,   // Cheshire address width
    parameter int unsigned DataWidth    = 64,   // AXI data width
    parameter int unsigned IdWidth      = 2,    // AXI master ID width
    parameter int unsigned UserWidth    = 2,    // AXI user width
    parameter int unsigned RamAddrWidth = 16,   // aer_decoder RAM_ADDR width
    parameter int unsigned BurstLen     = 64,   // Prefetch burst length (AXI words)
    parameter type axi_mst_req_t = logic,
    parameter type axi_mst_rsp_t = logic
)(
    input  logic                      clk_i,
    input  logic                      rst_ni,
    
    // === Interfaccia verso aer_decoder (stessi segnali della BRAM) ===
    input  logic                      cs_i,        // Chip select da aer_decoder
    input  logic [RamAddrWidth-1:0]   ram_addr_i,  // Indirizzo da aer_decoder
    output logic [31:0]               din_o,       // Dato verso aer_decoder
    output logic                      data_ready_o,// Dato valido (per FSM modificata)
    
    // === Configurazione (da axi_layer / registri Cheshire) ===
    input  logic [AddrWidth-1:0]      base_addr_i, // Indirizzo base DRAM
    input  logic                      enable_i,    // Abilitazione modulo
    
    // === AXI Master Port (verso crossbar Cheshire) ===
    output axi_mst_req_t              axi_req_o,
    input  axi_mst_rsp_t              axi_rsp_i
);
```

### 4.4 Pseudo-codice della FSM Interna

```
STATI: IDLE → FETCH_AR → FETCH_R → READY

IDLE:
    Se cs_i == 1:
        axi_addr = base_addr_i + {ram_addr_i, 2'b00}   // × 4 (byte address)
        → FETCH_AR

FETCH_AR:
    Emetti AXI AR:
        ar.addr  = axi_addr
        ar.len   = 0          // singola lettura (o burst per prefetch)
        ar.size  = 3'b010     // 4 byte (32 bit)
        ar.burst = 2'b01      // INCR
        ar.id    = 2'b00
        ar_valid = 1
    Se ar_ready → FETCH_R

FETCH_R:
    Aspetta AXI R:
        Se r_valid:
            din_o = r.data[31:0]   // primi 32 bit (il dato AER)
            data_ready_o = 1
            r_ready = 1
            → READY

READY:
    data_ready_o = 1
    Se cs_i torna a 0 → IDLE
```

### 4.5 Nota sull'AXI Data Width

Il crossbar Cheshire ha `DataWidth = 64` bit (8 byte). Una AXI read da 4 byte va gestita con:
- `ar.size = 3'b010` (4 byte per beat)
- Il dato torna nel campo `r.data[63:0]` — bisogna estrarre i 32 bit corretti in base all'allineamento dell'indirizzo (bit 2)

Se `axi_addr[2] == 0`: il dato è in `r.data[31:0]`
Se `axi_addr[2] == 1`: il dato è in `r.data[63:32]`

Oppure si può usare `ar.size = 3'b011` (8 byte) e leggere **2 entry AER alla volta** per ottimizzare.

---

## 5. Modifiche RTL Necessarie (Elenco Completo)

### 5.1 Abilitare AxiExtNumMst nella Config

**File:** `hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv`

Nella funzione `gen_cheshire_xilinx_cfg()`, aggiungere:

```systemverilog
ret.AxiExtNumMst = 1;   // 1 master esterno: reckon_dram_reader
```

Oggi `AxiExtNumMst` è `0` (dal `default: '0` di `DefaultCfg`) e non viene mai overridato. Senza questa modifica, il crossbar non ha una porta di ingresso per il master esterno.

**Effetto in `cheshire_soc.sv`:**
- Viene generato il blocco `gen_ext_axi_mst` (riga ~278)
- `axi_in_req[AxiIn.ext_base]` diventa disponibile
- La porta `axi_ext_mst_req_i` del SoC accetta richieste dall'esterno

### 5.2 Collegare il reader al posto del tie-off

**File:** `hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv`

Oggi:
```systemverilog
.axi_ext_mst_req_i  ( '0 ),    // MORTO — nessun master
.axi_ext_mst_rsp_o  ( ),
```

Deve diventare:
```systemverilog
.axi_ext_mst_req_i  ( reckon_reader_axi_req ),   // ← dal nuovo modulo
.axi_ext_mst_rsp_o  ( reckon_reader_axi_rsp ),   // → verso il nuovo modulo
```

### 5.3 Creare il modulo `reckon_dram_reader` (NUOVO)

**File:** `hw/axi_reckon/rtl/reckon_dram_reader.sv` (da creare)

Questo è il cuore della modifica. Vedi Sezione 4 per l'interfaccia e la logica.

### 5.4 Modificare `aer_decoder` per Supportare Latenza

**File:** `hw/axi_reckon/rtl/aer_decoder.v`

La memory FSM attuale assume 1 ciclo di latenza. Ci sono due approcci:

**Approccio A — Modificare la FSM (semplice, meno performante):**

Aggiungere uno stato di attesa:

```
MEM_IDLE → MEM_READ1 → MEM_WAIT → MEM_READ2 → MEM_IDLE
                            ↻ (finché data_ready == 0)
```

Serve aggiungere un input `data_ready` alla memory FSM e uno stato `MEM_WAIT` che cicla finché il dato non è pronto dal modulo AXI reader.

**Approccio B — Prefetch con buffer (complesso, performante):**

Il `reckon_dram_reader` prefetcha un blocco in un buffer FIFO. Quando `aer_decoder` chiede un dato, il buffer risponde in 1 ciclo (come la BRAM). Se il buffer è vuoto, stallare.

In questo caso `aer_decoder` **non cambia affatto**, perché il timing resta a 1 ciclo.

> **Raccomandazione**: Approccio A per il prototipo, Approccio B per ottimizzazione futura.

### 5.5 Rimuovere la BRAM (o renderla opzionale)

**File:** `hw/axi_reckon/rtl/reckon_axi_top.v`

La `BRAM2_we_inst` attuale viene sostituita dal `reckon_dram_reader`. I segnali che vanno ad `aer_decoder` restano gli stessi (`CS`, `RAM_ADDR`, `DIN`), ma ora li gestisce il reader AXI.

La porta A della BRAM (che va alla PS) non serve più — la PS scrive direttamente in DDR4.

### 5.6 Passare l'Indirizzo Base da Cheshire a ReckOn

**File:** `hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv`

I registri `axi_layer` hanno 8 uscite (`out_reg[0..7]`) larghe 32 bit. Attualmente usati:

| out_reg | Uso attuale | Nuovo uso proposto |
|---------|-------------|---------------------|
| 0 | batch_size | **DRAM_BASE_ADDR_LO** (32 bit bassi) |
| 1 | n_samples | **DRAM_BASE_ADDR_HI** (16 bit alti, pad a 48 bit) |
| 2 | do_eprop | batch_size (spostato) |
| 3 | reckon_ctrl_i[0] (NEW_EPOCH) | n_samples (spostato) |
| 4 | reckon_ctrl_i[1] (NEW_BATCH) | do_eprop (spostato) |
| 5 | reckon_ctrl_i[2] (TEST) | reckon_ctrl_i[0] (NEW_EPOCH) |
| 6 | reckon_ctrl_i[3] (STOP) | reckon_ctrl_i[1..3] combinati |
| 7 | debug | debug + enable |

**Oppure** (soluzione più pulita): aumentare `AxiRegsNout` da 8 a 10 e aggiungere i registri indirizzo **in coda**, senza spostare quelli esistenti:

| out_reg | Uso |
|---------|-----|
| 0–7 | Come oggi (batch_size, n_samples, ctrl...) |
| 8 | **DRAM_BASE_ADDR_LO** (32 bit bassi) |
| 9 | **DRAM_BASE_ADDR_HI** (16 bit alti) |

Poi nel top-level:
```systemverilog
wire [47:0] reckon_dram_base_addr;
assign reckon_dram_base_addr = {axi_reg_o[9][15:0], axi_reg_o[8]};
```

### 5.7 Abilitare la PS DDR4

**File:** `target/xilinx/scripts/chs-bd-zcu102.tcl`

```tcl
CONFIG.PSU__DDRC__ENABLE {1}     # Era {0}
```

### 5.8 Aggiungere S_AXI_HP0

**File:** `target/xilinx/scripts/chs-bd-zcu102.tcl`

Aggiungere:
```tcl
CONFIG.PSU__USE__S_AXI_GP2 {1}          # Abilita S_AXI_HP0
CONFIG.PSU__SAXIGP2__DATA_WIDTH {64}    # 64 bit (match Cheshire)
```

E collegare la porta alla LLC output di Cheshire.

### 5.9 Collegare la LLC Output a S_AXI_HP0

**File:** `hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv`

Oggi la `axi_llc_mst_req` / `axi_dram_mst_rsp` non vanno da nessuna parte (`USE_DDR` non definito). Bisogna instradare la porta LLC verso la S_AXI_HP0 del MPSoC:

```systemverilog
`ifdef USE_MPSOC
  // La LLC output va alla PS DDR4 via S_AXI_HP0
  // (potrebbe servire un width/protocol converter)
  assign s_axi_hp0_req = axi_dram_mst_req;
  assign axi_dram_mst_rsp = s_axi_hp0_rsp;
`endif
```

---

## 6. Riepilogo delle Modifiche — Mappa Completa

```
File da MODIFICARE:
━━━━━━━━━━━━━━━━━━

 ① xilinx_zcu102_reckon_chs_top.sv
    ├── gen_cheshire_xilinx_cfg(): AxiExtNumMst = 1
    ├── Collegare axi_ext_mst_req_i al reckon_dram_reader
    ├── Instanziare reckon_dram_reader
    ├── Passare base_addr da axi_reg_o al reader
    ├── Collegare LLC output → S_AXI_HP0
    └── Aggiornare MPSoC wrapper per S_AXI_HP0 + DDR4

 ② reckon_axi_top.v
    ├── Aggiungere porte per AXI master + base_addr
    ├── Sostituire/bypassare la BRAM con il reader
    └── Collegare reader ↔ aer_decoder (CS, RAM_ADDR, DIN)

 ③ aer_decoder.v  (opzionale con Approccio A)
    └── Aggiungere stato MEM_WAIT alla memory FSM

 ④ chs-bd-zcu102.tcl
    ├── Abilitare PS DDR4
    └── Aggiungere S_AXI_HP0

File da CREARE:
━━━━━━━━━━━━━━━

 ⑤ reckon_dram_reader.sv (NUOVO)
    └── Modulo AXI master che legge dalla DRAM
```

---

## 7. Dettaglio: `reckon_dram_reader.sv` (Implementazione Completa)

### 7.1 Versione Base (Senza Prefetch)

```systemverilog
// reckon_dram_reader.sv
// Legge dati AER dalla DRAM via AXI, su richiesta di aer_decoder.
// Si comporta come una BRAM ma accede alla DDR4 tramite il crossbar.

module reckon_dram_reader #(
    parameter int unsigned AddrWidth    = 48,
    parameter int unsigned DataWidth    = 64,
    parameter int unsigned IdWidth      = 2,
    parameter int unsigned UserWidth    = 2,
    parameter int unsigned RamAddrWidth = 16
)(
    input  logic                      clk_i,
    input  logic                      rst_ni,
    
    // Interfaccia aer_decoder (rimpiazza porta B della BRAM)
    input  logic                      cs_i,
    input  logic [RamAddrWidth-1:0]   ram_addr_i,
    output logic [31:0]               din_o,
    output logic                      data_ready_o,
    
    // Configurazione da Cheshire (via axi_layer registri)
    input  logic [AddrWidth-1:0]      base_addr_i,
    input  logic                      enable_i,
    
    // AXI Master Port
    // AR channel (read address)
    output logic [AddrWidth-1:0]      axi_ar_addr_o,
    output logic [7:0]                axi_ar_len_o,
    output logic [2:0]                axi_ar_size_o,
    output logic [1:0]                axi_ar_burst_o,
    output logic [IdWidth-1:0]        axi_ar_id_o,
    output logic                      axi_ar_valid_o,
    input  logic                      axi_ar_ready_i,
    
    // R channel (read data)
    input  logic [DataWidth-1:0]      axi_r_data_i,
    input  logic [1:0]                axi_r_resp_i,
    input  logic                      axi_r_last_i,
    input  logic [IdWidth-1:0]        axi_r_id_i,
    input  logic                      axi_r_valid_i,
    output logic                      axi_r_ready_o,
    
    // AW/W/B channels tied off (solo letture)
    output logic                      axi_aw_valid_o,
    output logic                      axi_w_valid_o,
    output logic                      axi_b_ready_o
);

    // FSM States
    typedef enum logic [1:0] {
        IDLE,
        SEND_AR,
        WAIT_R,
        DATA_VALID
    } state_t;
    
    state_t state_q, state_d;
    logic [31:0] data_q;
    logic [AddrWidth-1:0] axi_addr;
    
    // Calcolo indirizzo AXI
    // ram_addr_i è l'indice (0..65535), ogni entry è 4 byte
    assign axi_addr = base_addr_i + {{(AddrWidth-RamAddrWidth-2){1'b0}}, ram_addr_i, 2'b00};
    
    // Write channels sempre inattivi (solo letture)
    assign axi_aw_valid_o = 1'b0;
    assign axi_w_valid_o  = 1'b0;
    assign axi_b_ready_o  = 1'b1;  // Accetta qualsiasi B response spuria
    
    // AR channel defaults
    assign axi_ar_len_o   = 8'd0;       // 1 beat (single transfer)
    assign axi_ar_size_o  = 3'b010;     // 4 byte per beat
    assign axi_ar_burst_o = 2'b01;      // INCR
    assign axi_ar_id_o    = '0;
    
    // Outputs
    assign din_o        = data_q;
    assign data_ready_o = (state_q == DATA_VALID);
    
    // FSM
    always_comb begin
        state_d        = state_q;
        axi_ar_addr_o  = '0;
        axi_ar_valid_o = 1'b0;
        axi_r_ready_o  = 1'b0;
        
        case (state_q)
            IDLE: begin
                if (cs_i && enable_i) begin
                    state_d = SEND_AR;
                end
            end
            
            SEND_AR: begin
                axi_ar_addr_o  = axi_addr;
                axi_ar_valid_o = 1'b1;
                if (axi_ar_ready_i) begin
                    state_d = WAIT_R;
                end
            end
            
            WAIT_R: begin
                axi_r_ready_o = 1'b1;
                if (axi_r_valid_i) begin
                    state_d = DATA_VALID;
                end
            end
            
            DATA_VALID: begin
                // Dato disponibile, aer_decoder lo campiona
                if (!cs_i) begin
                    state_d = IDLE;
                end
            end
        endcase
    end
    
    // Registri
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= IDLE;
            data_q  <= '0;
        end else begin
            state_q <= state_d;
            if (state_q == WAIT_R && axi_r_valid_i) begin
                // Estrai 32 bit dalla word AXI da 64 bit
                if (axi_addr[2])
                    data_q <= axi_r_data_i[63:32];
                else
                    data_q <= axi_r_data_i[31:0];
            end
        end
    end
    
endmodule
```

### 7.2 Integrazione con i Tipi AXI Packed di Cheshire

La versione sopra usa segnali "sfusi" per chiarezza. In pratica, per integrarsi con Cheshire serve usare i tipi packed `axi_mst_req_t` / `axi_mst_rsp_t`. L'integrazione sarebbe:

```systemverilog
// Nel top-level, istanziare così:
axi_mst_req_t reckon_reader_axi_req;
axi_mst_rsp_t reckon_reader_axi_rsp;

// Popolare la request:
assign reckon_reader_axi_req.ar.addr  = reader_ar_addr;
assign reckon_reader_axi_req.ar.len   = 8'd0;
assign reckon_reader_axi_req.ar.size  = 3'b010;
assign reckon_reader_axi_req.ar.burst = 2'b01;
assign reckon_reader_axi_req.ar.id    = '0;
assign reckon_reader_axi_req.ar.lock  = 1'b0;
assign reckon_reader_axi_req.ar.cache = 4'b0010;  // Normal non-cacheable
assign reckon_reader_axi_req.ar.prot  = 3'b000;
assign reckon_reader_axi_req.ar.qos   = 4'b0000;
assign reckon_reader_axi_req.ar.user  = '0;
assign reckon_reader_axi_req.ar_valid = reader_ar_valid;

// AW/W canali morti (solo letture)
assign reckon_reader_axi_req.aw_valid = 1'b0;
assign reckon_reader_axi_req.w_valid  = 1'b0;
assign reckon_reader_axi_req.aw       = '0;
assign reckon_reader_axi_req.w        = '0;
assign reckon_reader_axi_req.b_ready  = 1'b1;
assign reckon_reader_axi_req.r_ready  = reader_r_ready;

// Leggere la response:
wire reader_ar_ready = reckon_reader_axi_rsp.ar_ready;
wire reader_r_valid  = reckon_reader_axi_rsp.r_valid;
wire [63:0] reader_r_data = reckon_reader_axi_rsp.r.data;
```

---

## 8. Modifica di `aer_decoder` — Approccio A (Stato MEM_WAIT)

L'unica modifica a `aer_decoder.v` è aggiungere un input `data_ready_i` e uno stato `MEM_WAIT`:

### 8.1 Aggiungere la Porta

```verilog
// Aggiungere nella port list:
input wire data_ready_i,    // NUOVO: segnale dal reckon_dram_reader
```

### 8.2 Modificare la FSM di Memoria

```verilog
// PRIMA (attuale):
localparam MEM_IDLE  = 2'b00;
localparam MEM_READ1 = 2'b01;
localparam MEM_READ2 = 2'b10;
localparam MEM_WRITE = 2'b11;  // non usato

// DOPO:
localparam MEM_IDLE  = 3'b000;
localparam MEM_READ1 = 3'b001;
localparam MEM_WAIT  = 3'b010;   // ← NUOVO
localparam MEM_READ2 = 3'b011;

// Aggiornare la FSM combinatoria:
always @(mem_c_state, READ, RST_sync, data_ready_i) begin
    case (mem_c_state)
        MEM_IDLE: begin
            mem_n_state <= READ ? MEM_READ1 : MEM_IDLE;
        end
        MEM_READ1: begin
            mem_n_state <= MEM_WAIT;    // Era MEM_READ2
        end
        MEM_WAIT: begin                  // ← NUOVO STATO
            mem_n_state <= data_ready_i ? MEM_READ2 : MEM_WAIT;
        end
        MEM_READ2: begin
            mem_n_state <= MEM_IDLE;
        end
        default: begin
            mem_n_state <= MEM_IDLE;
        end
    endcase
end

// Aggiornare le uscite:
always @(mem_c_state) begin
    case (mem_c_state)
        MEM_IDLE: begin
            CS_reg         <= 1'b0;
            ADD_REG_EN     <= 1'b0;
            data_ram_valid <= 1'b0;
        end
        MEM_READ1: begin
            CS_reg         <= 1'b1;    // Attiva CS → il reader lancia AXI AR
            ADD_REG_EN     <= 1'b0;
            data_ram_valid <= 1'b0;
        end
        MEM_WAIT: begin                 // ← NUOVO
            CS_reg         <= 1'b1;    // CS resta alto durante attesa
            ADD_REG_EN     <= 1'b0;
            data_ram_valid <= 1'b0;
        end
        MEM_READ2: begin
            CS_reg         <= 1'b0;
            ADD_REG_EN     <= 1'b1;    // Incrementa RAM_ADDR
            data_ram_valid <= 1'b1;    // DIN è valido
        end
        default: begin
            CS_reg         <= 1'b0;
            ADD_REG_EN     <= 1'b0;
            data_ram_valid <= 1'b0;
        end
    endcase
end
```

**Effetto**: quando `aer_decoder` vuole leggere, va in `MEM_WAIT` e ci resta finché `data_ready_i` (dal reader AXI) non diventa 1. Il resto della FSM principale non cambia: aspetta `data_ram_valid` come prima.

---

## 9. Il Path DRAM: PS DDR4 via S_AXI_HP0

### 9.1 Come Funziona

Quando il `reckon_dram_reader` emette una AXI read a indirizzo `0x8000_xxxx`:

```
reckon_dram_reader
    │ AXI AR: addr=0x8000_0100
    ▼
AXI Crossbar (porta master ext)
    │ Routing: 0x8000_xxxx → porta LLC out
    ▼
LLC (Last Level Cache / SPM)
    │ Se cache miss o bypass → forward
    ▼
LLC output (axi_llc_mst_req)
    │
    ▼
S_AXI_HP0 (porta slave PS)
    │ PS traduce addr → DDR4 fisico
    ▼
PS DDR4 Controller  
    │
    ▼
DDR4 DRAM chip (4 GB)
    │ Legge il dato
    ▼
Risposta risale tutto il path
    │
    ▼
reckon_dram_reader riceve il dato su DIN
```

### 9.2 Address Translation

Il crossbar Cheshire mappa la "DRAM" a `0x8000_0000 – 0xFFFF_FFFF` (dal `LlcOutRegionStart/End` in `DefaultCfg`).

La PS DDR4 è mappata (dal punto di vista PS) a `0x0000_0000 – 0x7FFF_FFFF` (primi 2 GB).

Serve un **address remapping** nel path tra LLC output e S_AXI_HP0:
- Cheshire invia `0x8000_0000 + offset`
- S_AXI_HP0 deve ricevere `0x0000_0000 + offset`
- Quindi: **sottrarre `0x8000_0000`** dall'indirizzo

Questo può essere fatto con:
1. Un piccolo modulo RTL che modifica `axi_llc_mst_req.aw.addr` e `.ar.addr`
2. Oppure dalla configurazione nel Vivado Address Editor (il PS può accettare un range offset)

### 9.3 Diagramma Temporale di una Lettura

```
Ciclo:  1    2    3    4    5    ...   15   16   17   18   19
        ├────┤    ├────┤    ├──────────┤    ├────┤    ├────┤
CS:     ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
Reader: IDLE │SEND_AR│    WAIT_R...............│DONE│
              AR────►│                         │R◄──│
Xbar:         │ route│    LLC→HP→DDR4→HP→LLC   │    │
              │      │    (~10-20 cicli)       │    │
data_rdy:     │      │                         │ ▄▄▄│
aer_dec: MEM1 │ WAIT │ WAIT  WAIT  WAIT  WAIT │MEM2│IDLE
```

Latenza tipica: **15-30 cicli** per lettura singola (a 50 MHz = 0.3-0.6 µs).

---

## 10. Software Cheshire (CVA6)

### 10.1 Flusso di Controllo

```c
#include "dif/uart.h"

// Indirizzi dei registri axi_layer (external slave del crossbar)
// L'indirizzo dipende da AxiExtRegionStart[0] — da configurare
#define RECKON_REG_BASE  0x20000000ULL  // ESEMPIO — va configurato

// Registri output (Cheshire → ReckOn)
#define REG_BATCH_SIZE      (RECKON_REG_BASE + 0*8)
#define REG_N_SAMPLES       (RECKON_REG_BASE + 1*8)
#define REG_DO_EPROP        (RECKON_REG_BASE + 2*8)
#define REG_CTRL_NEW_EPOCH  (RECKON_REG_BASE + 3*8)
#define REG_CTRL_NEW_BATCH  (RECKON_REG_BASE + 4*8)
#define REG_CTRL_TEST       (RECKON_REG_BASE + 5*8)
#define REG_CTRL_STOP       (RECKON_REG_BASE + 6*8)
#define REG_DEBUG           (RECKON_REG_BASE + 7*8)
#define REG_DRAM_ADDR_LO    (RECKON_REG_BASE + 8*8)   // NUOVO
#define REG_DRAM_ADDR_HI    (RECKON_REG_BASE + 9*8)   // NUOVO

// Registri input (ReckOn → Cheshire)
#define REG_INFER_COUNT     (RECKON_REG_BASE + 0x100)  // in_reg[0]
#define REG_EPOCH_DONE      (RECKON_REG_BASE + 0x108)  // in_reg[1]
#define REG_BATCH_DONE      (RECKON_REG_BASE + 0x110)  // in_reg[2]

static inline void reg_write(uint64_t addr, uint32_t val) {
    *(volatile uint32_t*)addr = val;
}
static inline uint32_t reg_read(uint64_t addr) {
    return *(volatile uint32_t*)addr;
}

int main(void) {
    // === 1. Dire a ReckOn DOVE sono i dati nella DRAM ===
    uint64_t dram_data_addr = 0x80000000ULL;  // I 200 MB partono da qui
    reg_write(REG_DRAM_ADDR_LO, (uint32_t)(dram_data_addr & 0xFFFFFFFF));
    reg_write(REG_DRAM_ADDR_HI, (uint32_t)(dram_data_addr >> 32));
    
    // === 2. Configurare ReckOn ===
    reg_write(REG_BATCH_SIZE, 128);    // batch di 128 campioni
    reg_write(REG_N_SAMPLES, 1000);    // 1000 campioni per epoca
    reg_write(REG_DO_EPROP, 0);        // inference only
    
    // === 3. Avviare l'epoca ===
    reg_write(REG_CTRL_NEW_EPOCH, 1);  // NEW_EPOCH pulse
    reg_write(REG_CTRL_NEW_EPOCH, 0);
    
    // === 4. Loop: attendere batch, avviare prossimo ===
    int total_batches = 1000 / 128;  // ~7 batch
    for (int b = 0; b < total_batches; b++) {
        // Attendi BATCH_DONE
        while (!(reg_read(REG_BATCH_DONE) & 1)) {
            asm volatile("nop");
        }
        
        // Leggi risultato inferenza
        uint32_t infer = reg_read(REG_INFER_COUNT);
        
        // Avvia prossimo batch
        if (b < total_batches - 1) {
            reg_write(REG_CTRL_NEW_BATCH, 1);
            reg_write(REG_CTRL_NEW_BATCH, 0);
        }
    }
    
    // === 5. Attendi fine epoca ===
    while (!(reg_read(REG_EPOCH_DONE) & 1)) {
        asm volatile("nop");
    }
    
    return 0;
}
```

### 10.2 Nota Importante

In questa architettura, Cheshire **non muove dati**. Il suo ruolo è:
1. Scrivere l'indirizzo base DRAM nel registro
2. Configurare i parametri di ReckOn
3. Dare il via (NEW_EPOCH)
4. Attendere i risultati

**ReckOn fa tutto il resto**: attraverso `aer_decoder` e `reckon_dram_reader`, legge autonomamente i dati dalla DRAM entry per entry.

---

## 11. Software PS (ARM A53)

La PS deve solo:
1. Caricare i 200 MB di dati AER nella DDR4
2. (Opzionale) Segnalare a Cheshire che i dati sono pronti

```c
// Bare-metal su ARM A53 — carica dati AER in DDR4
#include <stdint.h>

// Area DDR4 visibile dal PL via S_AXI_HP0
// Deve corrispondere a ciò che Cheshire vede come 0x8000_0000
#define DDR_DATA_BASE  0x00000000UL  // O l'offset mappato nella PS

void load_aer_dataset(void) {
    volatile uint32_t* ddr = (volatile uint32_t*)DDR_DATA_BASE;
    
    // Carica dati da SD card, Ethernet, ecc.
    // Formato: 32 bit per entry AER
    // [27:24] code | [23:12] data | [11:0] tick
    
    // Esempio: caricare da un array in memoria
    extern const uint32_t aer_dataset[];
    extern const uint32_t aer_dataset_size;
    
    for (uint32_t i = 0; i < aer_dataset_size; i++) {
        ddr[i] = aer_dataset[i];
    }
    
    // Flush cache per garantire che i dati siano in DDR
    __asm__ volatile("dsb sy");
    __asm__ volatile("dc civac, %0" : : "r"(ddr));
    __asm__ volatile("dsb sy");
}
```

---

## 12. Performance

### 12.1 Lettura Singola (Senza Prefetch)

| Fase | Cicli (@ 50 MHz) |
|------|-------------------|
| aer_decoder CS → reader FSM | 1 |
| AXI AR handshake | 1-2 |
| Crossbar routing | 1-3 |
| LLC lookup | 2-5 |
| S_AXI_HP0 → PS DDR4 | 5-15 |
| DDR4 accesso fisico (CAS latency) | 5-10 |
| Ritorno dati (R channel) | 3-5 |
| **Totale** | **~18-40 cicli** |

A 50 MHz: **0.36 – 0.8 µs per entry**.

Per 200 MB = ~52 milioni di entry a 32 bit ciascuna:
- Best case: 52M × 0.36 µs = **~19 secondi**
- Worst case: 52M × 0.8 µs = **~42 secondi**

### 12.2 Con Prefetch (Burst AXI)

Con burst di 64 entry (256 byte):
- Overhead burst: ~20 cicli setup + 64 × 1 ciclo/dato = ~84 cicli per 64 entry
- **~1.3 cicli/entry** ammortizzati

Per 200 MB con prefetch:
- 52M × 1.3 × 20 ns = **~1.4 secondi** (14× più veloce!)

### 12.3 Confronto

| Modalità | Tempo per 200 MB | Note |
|----------|-------------------|------|
| Singola lettura | ~19-42 s | Semplice ma lento |
| Burst prefetch (len=64) | ~1.4 s | Richiede FIFO interno |
| Burst prefetch (len=256) | ~0.8 s | FIFO più grande, max burst AXI4 |
| Per confronto: BRAM (1 ciclo) | ~1.0 s | Limite teorico impossibile (BRAM = 256KB) |

**Raccomandazione**: implementare sempre il prefetch con burst. Un FIFO da 256 entry × 32 bit = 1 KB di BRAM PL è trascurabile.

---

## 13. Versione con Prefetch — Concetto

```systemverilog
module reckon_dram_reader_prefetch #(
    parameter int unsigned BurstLen = 64,  // Entry per burst
    // ... altri parametri come sopra
)(
    // ... stesse porte
);
    // FIFO interno (BurstLen × 32 bit)
    logic [31:0] fifo [0:BurstLen-1];
    logic [$clog2(BurstLen)-1:0] fifo_wr_ptr, fifo_rd_ptr;
    logic [$clog2(BurstLen):0]   fifo_count;
    
    // FSM:
    // 1. PREFETCH: lancia AXI burst read di BurstLen entry
    //    ar.addr = base_addr + next_bulk_addr
    //    ar.len  = BurstLen - 1
    //    ar.size = 3'b010 (4 byte)
    //
    // 2. FILL: ricevi BurstLen dati R e riempi il FIFO
    //
    // 3. SERVE: quando aer_decoder chiede (cs_i), 
    //    preleva dal FIFO in 1 ciclo (come una BRAM!)
    //
    // 4. Quando FIFO scende sotto soglia (es. 16 entry), 
    //    lancia prossimo burst (pipeline)
    
    // Con questa implementazione, aer_decoder NON va modificato!
    // Il FIFO risponde in 1 ciclo come la BRAM originale.
    // Il burst AXI viene lanciato in background.
endmodule
```

Con il prefetch, `aer_decoder` **non deve cambiare affatto** — il FIFO risponde in 1 ciclo come la BRAM. È la soluzione più pulita ma richiede più logica.

---

## 14. Riepilogo Finale

### Cosa è coerente con la tua richiesta

| Requisito | Questa architettura |
|-----------|---------------------|
| PS espone 200 MB | ✅ PS carica in DDR4 (abilitata) |
| Dati nella DRAM | ✅ DDR4 PS accessibile via S_AXI_HP0 |
| Cheshire fornisce indirizzo AXI | ✅ CVA6 scrive base_addr nel registro |
| ReckOn va a prendere i dati | ✅ `reckon_dram_reader` è AXI master, legge dalla DRAM |
| Tutto via AXI | ✅ AXI crossbar, AXI master del reader, AXI S_AXI_HP0 |

### Cosa NON è coerente dalle guide precedenti

| Proposta precedente | Problema |
|---------------------|----------|
| iDMA copia DDR→BRAM | Cheshire muove i dati, non ReckOn |
| PS DMA scrive in BRAM | PS muove i dati direttamente |
| BRAM come buffer intermedio | ReckOn non va dalla DRAM, legge locale |
| Chunking 256KB | Non necessario se ReckOn legge dalla DRAM direttamente |

### Road map implementazione

| Step | Descrizione | Difficoltà | File |
|------|-------------|------------|------|
| 1 | Creare `reckon_dram_reader.sv` (versione base) | ⭐⭐⭐ | Nuovo file |
| 2 | Modificare `aer_decoder.v` (aggiungere `MEM_WAIT`) | ⭐⭐ | aer_decoder.v |
| 3 | Modificare `reckon_axi_top.v` (sostituire BRAM con reader) | ⭐⭐ | reckon_axi_top.v |
| 4 | Config Cheshire: `AxiExtNumMst = 1` | ⭐ | xilinx_zcu102_reckon_chs_top.sv |
| 5 | Collegare `axi_ext_mst_req_i` al reader | ⭐⭐ | xilinx_zcu102_reckon_chs_top.sv |
| 6 | Aggiungere registri indirizzo in `axi_layer` | ⭐ | xilinx_zcu102_reckon_chs_top.sv |
| 7 | Abilitare PS DDR4 + S_AXI_HP0 nel TCL | ⭐⭐ | chs-bd-zcu102.tcl |
| 8 | Collegare LLC output → S_AXI_HP0 | ⭐⭐⭐ | xilinx_zcu102_reckon_chs_top.sv + TCL |
| 9 | Software CVA6 (configurazione + avvio) | ⭐⭐ | sw/tests/ |
| 10 | Software PS (caricamento dati) | ⭐⭐ | Nuovo progetto ARM |
| 11 | (Opt) Upgrade a prefetch con burst | ⭐⭐⭐ | reckon_dram_reader.sv |

---

## 15. Glossario

| Termine | Significato |
|---------|-------------|
| **AXI Master** | Un IP che **emette** richieste di lettura/scrittura sull'AXI bus |
| **AXI Slave** | Un IP che **risponde** a richieste AXI (es. DRAM controller, registro) |
| **AR channel** | AXI Read Address channel — il master dice "voglio leggere a questo indirizzo" |
| **R channel** | AXI Read Data channel — lo slave risponde con il dato |
| **Burst** | Più beat in una singola transazione AXI (ar.len > 0), molto più efficiente |
| **Prefetch** | Leggere dati in anticipo e metterli in un buffer, prima che servano |
| **FIFO** | First-In-First-Out buffer — usato per il prefetch |
| **S_AXI_HP** | Slave AXI High Performance — porta della PS che dà accesso alla DDR4 |
| **ext master** | Porta di ingresso del crossbar Cheshire per master esterni (PL-side) |
| **axi_layer** | Modulo che converte AXI → registri per controllare ReckOn |
| **aer_decoder** | FSM che legge dati AER dalla memoria e li invia a ReckOn sequenzialmente |
| **reckon_dram_reader** | ★ NUOVO modulo: AXI master che legge dalla DRAM per aer_decoder |
