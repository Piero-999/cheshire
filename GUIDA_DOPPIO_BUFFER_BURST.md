# Guida: ReckOn Master con AXI Burst e Doppio Buffer — Senza Modificare aer_decoder

## 0. Coerenza con la Richiesta Originale

> *"Deve essere ReckOn che va a prendere i dati dalla DRAM. Cheshire deve fornire a ReckOn l'indirizzo AXI a cui prendere i dati."*

Questa guida propone un'architettura **doppio buffer (ping-pong)** con **AXI burst read** in cui:

| Requisito | Soddisfatto? | Come |
|-----------|:---:|------|
| ReckOn prende i dati dalla DDR4 | ✅ | Un modulo `reckon_dram_prefetcher`, parte del sottosistema ReckOn, è AXI master e fa burst read dalla DDR4 |
| Cheshire fornisce l'indirizzo | ✅ | CVA6 scrive `base_addr` nei registri `axi_layer` |
| aer_decoder non viene modificato | ✅ | Il doppio buffer mantiene l'interfaccia BRAM a 1 ciclo |
| Supporto 200 MB di dati | ✅ | I dati risiedono in DDR4; il buffer locale è solo una cache di lavoro |
| Burst per efficienza | ✅ | Letture AXI4 con burst INCR (fino a 256 beat = 2 KB per burst) |

---

## 1. Perché il Doppio Buffer e Perché aer_decoder NON Deve Cambiare

### 1.1 Il Contratto di aer_decoder con la Memoria

Da `aer_decoder.v`, la memory FSM è:

```
MEM_IDLE  ──(READ=1)──▶  MEM_READ1  ──(1 ciclo)──▶  MEM_READ2  ──▶  MEM_IDLE
                          CS=1                        data_ram_valid=1
                                                      ADD_REG_EN=1
```

- **Ciclo N**: `CS=1`, la BRAM inizia la lettura
- **Ciclo N+1**: `data_ram_valid=1`, il dato su `DIN` è campionato

Questa FSM **non ha stati di attesa**. Il dato DEVE essere pronto in **esattamente 1 ciclo**. 
Una latenza AXI di 10-50 cicli romperebbe questa FSM.

### 1.2 La Soluzione: BRAM come Cache Locale

Invece di far leggere `aer_decoder` direttamente dalla DDR4 (che richiederebbe di modificare la FSM), manteniamo una **BRAM locale** che risponde in 1 ciclo. Ma questa BRAM viene **riempita in background** dal prefetcher AXI, usando un secondo buffer per fare ping-pong.

Risultato: `aer_decoder` vede **esattamente** la stessa interfaccia di sempre. Zero modifiche.

### 1.3 Il Flusso Batch di aer_decoder

Da `aer_decoder.v`:

```verilog
// RAM_ADDR si resetta a 0 a ogni fine batch (END_B) e fine epoca (END_E)
always @(posedge CLK) begin
    if ((curr_state == IDLE) || (curr_state == END_E) || (curr_state == END_B))
        RAM_ADDR_reg <= {ADDR_WIDTH{1'b0}};
    else if (ADD_REG_EN)
        RAM_ADDR_reg <= RAM_ADDR + 1;
end
```

E la FSM principale:

```verilog
END_B: next_state <= (cnt_sample_epoch == N_SAMPLES_sync) ? END_E : (NEW_BATCH_sync ? READM : END_B);
```

Questo significa:
1. Ogni **batch** legge da `RAM_ADDR = 0` in avanti
2. A fine batch (`END_B`), `RAM_ADDR` torna a 0
3. La FSM **aspetta `NEW_BATCH`** prima di riprendere la lettura
4. Nel design attuale, la PS deve ricaricare la BRAM tra un batch e l'altro

**Questa attesa a `END_B` è perfetta** per il doppio buffer: mentre `aer_decoder` sta processando un batch da un buffer, il prefetcher riempie l'altro buffer. A `END_B`, si scambiano.

---

## 2. Architettura Completa

```
╔══════════════════════════════════════════════════════════════════════════╗
║                              PS (ARM A53)                                ║
║                                                                          ║
║  1. Carica 200 MB di dati AER nella DDR4 (0x0000_0000 – 0x0C80_0000)    ║
║  2. Comunica a Cheshire: "dati pronti, indirizzo X, Y words per batch"   ║
╚══════════════════════════════╤═══════════════════════════════════════════╝
                               │ (S_AXI_HP0 — letture dalla PL)
                               ▼
╔══════════════════════════════════════════════════════════════════════════╗
║                         AXI Crossbar Cheshire                            ║
║                                                                          ║
║  MASTER (Input) Ports:              SLAVE (Output) Ports:                ║
║   [0] CVA6 core                      [0] Debug                          ║
║   [1] Debug module                   [1] Reg demux                      ║
║   [2] iDMA                           [2] LLC out → S_AXI_HP0 → DDR4    ║
║   [3] ★ reckon_dram_prefetcher ★     [3] SPM cached/uncached            ║
║       (ext master, NUOVO)            [4] DMA config                     ║
║                                      [5] axi_layer (ext slave, registri)║
╚════════════════════════════════════════════════╤═════════════════════════╝
                                                 │
              ┌──────────────────────────────────┘
              ▼
╔══════════════════════════════════════════════════════════════════════════╗
║                      reckon_axi_top (MODIFICATO)                         ║
║                                                                          ║
║  ┌────────────────────────────────────────────────────────────────────┐  ║
║  │                  reckon_dram_prefetcher (NUOVO)                    │  ║
║  │                                                                    │  ║
║  │  Ingressi di configurazione (da axi_layer out_reg):                │  ║
║  │    - base_addr [47:0]  (indirizzo DDR4 di partenza)                │  ║
║  │    - batch_words [15:0] (parole da 32 bit per batch)               │  ║
║  │                                                                    │  ║
║  │  Ingressi di controllo:                                            │  ║
║  │    - start_fill_i  (start prefetch del primo buffer)               │  ║
║  │    - batch_done_i  (BATCH_DONE da aer_decoder)                     │  ║
║  │    - epoch_done_i  (EPOCH_DONE da aer_decoder)                     │  ║
║  │                                                                    │  ║
║  │  Uscite:                                                           │  ║
║  │    - AXI Master Port → crossbar input[3]                          │  ║
║  │    - bram_wr_addr [ADDR_WIDTH-1:0]                                 │  ║
║  │    - bram_wr_data [31:0]                                           │  ║
║  │    - bram_wr_en                                                    │  ║
║  │    - active_buf (0=A, 1=B) → controlla MUX lettura                 │  ║
║  │    - fill_done_o → gate per NEW_BATCH                              │  ║
║  └─────────────────────────┬──────────────────────────────────────────┘  ║
║                            │                                             ║
║       ┌────────────────────┼────────────────────┐                        ║
║       ▼ (write port A)     │      (write port A) ▼                       ║
║  ┌──────────┐              │              ┌──────────┐                   ║
║  │ BRAM "A" │              │              │ BRAM "B" │                   ║
║  │ 2^16 × 32│              │              │ 2^16 × 32│                   ║
║  │          │              │              │          │                   ║
║  │ Port B ──┼──┐           │         ┌────┤── Port B │                   ║
║  └──────────┘  │     ┌─────┴─────┐   │    └──────────┘                   ║
║                ▼     │           │   ▼                                    ║
║            ┌────────────────────────────┐                                ║
║            │    MUX (active_buf)        │                                ║
║            │  0 → BRAM_A.DOUTB         │                                ║
║            │  1 → BRAM_B.DOUTB         │                                ║
║            └───────────┬────────────────┘                                ║
║                        │ DIN [31:0]                                      ║
║                        ▼                                                 ║
║  ┌──────────────────────────────────────────────────────────────┐        ║
║  │                    aer_decoder (INVARIATO!)                   │        ║
║  │                                                               │        ║
║  │  CS ────────────────────▶ (va al BRAM attivo via MUX)        │        ║
║  │  RAM_ADDR ──────────────▶ (va a entrambi i BRAM port B)     │        ║
║  │  DIN ◀────────────────── (dal MUX, 1 ciclo di latenza)      │        ║
║  │                                                               │        ║
║  │  BATCH_DONE ───────────▶ prefetcher (swap + start next fill) │        ║
║  │  EPOCH_DONE ───────────▶ prefetcher (reset ddr4_ptr)         │        ║
║  └──────────────────────────────────────────────────────────────┘        ║
║                        │                                                 ║
║                        ▼                                                 ║
║  ┌──────────────────────────────────────────────────────────────┐        ║
║  │                    reckon SNN (INVARIATO!)                    │        ║
║  └──────────────────────────────────────────────────────────────┘        ║
╚══════════════════════════════════════════════════════════════════════════╝
```

---

## 3. Il Meccanismo Ping-Pong in Dettaglio

### 3.1 Sequenza Temporale

```
Tempo ──────────────────────────────────────────────────────────────────▶

      ┌─ FASE 0: Prefetch Iniziale ──┐
      │                               │
      │  Prefetcher riempie Buffer A  │
      │  (batch 0 da DDR4)            │
      │  aer_decoder fermo in IDLE    │
      │                               │
      │  fill_done → NEW_EPOCH        │
      └───────────────────────────────┘
      
      ┌─ FASE 1: Batch 0 ─────────────────────┐  ┌─ FASE 2: Batch 1 ──────
      │                                         │  │
      │  aer_decoder legge da Buffer A          │  │  aer_decoder legge da B
      │  (CS/RAM_ADDR → BRAM_A port B → DIN)   │  │  (CS/RAM_ADDR → BRAM_B)
      │                                         │  │
      │  Prefetcher riempie Buffer B            │  │  Prefetcher riempie A
      │  (batch 1 da DDR4, via AXI burst)       │  │  (batch 2 da DDR4)
      │                                         │  │
      │  batch_done ─▶ SWAP (active_buf 0→1)   │  │  batch_done ─▶ SWAP
      └─────────────────────────────────────────┘  └──────────────────────

active_buf:  0                                      1                    0
             ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄  ▄▄
```

### 3.2 Regola Critica: fill_done prima del Swap

Rischio: il prefetcher non finisce di riempire il buffer inattivo prima che `BATCH_DONE` arrivi.

**Soluzione**: il segnale `NEW_BATCH` verso `aer_decoder` viene **gatato**:

```verilog
// Nel top-level:
wire new_batch_gated = new_batch_from_cheshire & fill_done;
```

La FSM di `aer_decoder` resta in `END_B` (aspettando `NEW_BATCH`) finché il buffer non è pronto. Nessuna modifica ad `aer_decoder`, solo il cablaggio del segnale `NEW_BATCH` viene ritardato.

### 3.3 Gestione di EPOCH_DONE

A fine epoca (`END_E`), se ci sono altre epoche:
1. Il puntatore DDR4 torna a `base_addr` (si riprocessa lo stesso dataset)
2. Swap buffer
3. Il prefetcher ricomincia a riempire il buffer inattivo
4. `NEW_EPOCH` viene gatato come `NEW_BATCH`:

```verilog
wire new_epoch_gated = new_epoch_from_cheshire & fill_done;
```

---

## 4. Il Nuovo Modulo: `reckon_dram_prefetcher`

### 4.1 Interfaccia

```systemverilog
module reckon_dram_prefetcher #(
    parameter int unsigned AxiAddrWidth  = 48,
    parameter int unsigned AxiDataWidth  = 64,
    parameter int unsigned AxiIdWidth    = 2,    // AxiMstIdWidth
    parameter int unsigned AxiUserWidth  = 2,
    parameter int unsigned RamAddrWidth  = 16,   // 2^16 = 65536 entry
    parameter int unsigned BurstLen      = 256,  // beat per burst (max AXI4 = 256)
    parameter type axi_mst_req_t = logic,
    parameter type axi_mst_rsp_t = logic
)(
    input  logic                        clk_i,
    input  logic                        rst_ni,

    // Configurazione (da axi_layer out_reg, dominio soc_clk)
    input  logic [AxiAddrWidth-1:0]     base_addr_i,      // indirizzo DDR4 di partenza
    input  logic [RamAddrWidth-1:0]     batch_words_i,    // parole 32-bit per batch (0 = usa max)

    // Controllo
    input  logic                        start_i,          // avvia primo prefetch (da Cheshire)
    input  logic                        batch_done_i,     // BATCH_DONE da aer_decoder
    input  logic                        epoch_done_i,     // EPOCH_DONE da aer_decoder

    // Stato
    output logic                        fill_done_o,      // buffer inattivo pronto
    output logic                        active_buf_o,     // 0=A, 1=B (per MUX lettura)

    // BRAM write port (va al buffer INATTIVO)
    output logic [RamAddrWidth-1:0]     bram_wr_addr_o,
    output logic [31:0]                 bram_wr_data_o,
    output logic                        bram_wr_en_o,
    output logic                        bram_wr_sel_o,    // 0=scrivi A, 1=scrivi B

    // AXI Master (verso il crossbar Cheshire)
    output axi_mst_req_t                axi_req_o,
    input  axi_mst_rsp_t                axi_rsp_i
);
```

### 4.2 FSM del Prefetcher

```
                 ┌──────────┐
        rst ────▶│   IDLE   │◀──────────────────────────────────────┐
                 └────┬─────┘                                       │
                      │ start_i=1                                   │
                      ▼                                             │
                 ┌──────────┐                                       │
           ┌────▶│ BURST_AR │  Emette AXI AR con:                  │
           │     │          │    addr = ddr4_ptr                    │
           │     │          │    len  = BurstLen-1                  │
           │     │          │    size = 3'b011 (8 byte/beat)        │
           │     │          │    burst = INCR                       │
           │     └────┬─────┘                                       │
           │          │ ar_ready                                    │
           │          ▼                                             │
           │     ┌──────────┐                                       │
           │     │ BURST_R  │  Riceve R beats:                     │
           │     │          │    Per ogni beat (64 bit):            │
           │     │          │      word_lo = r.data[31:0]  → BRAM  │
           │     │          │      word_hi = r.data[63:32] → BRAM  │
           │     │          │      bram_wr_addr += 2               │
           │     │          │    beat_cnt++                         │
           │     └────┬─────┘                                       │
           │          │ r.last (fine burst)                         │
           │          ▼                                             │
           │     ┌──────────┐                                       │
           │     │  CHECK   │  words_filled >= batch_words?        │
           │     │          │    NO  → ddr4_ptr += BurstLen×8      │
           │     │          │          torna a BURST_AR             │
           │     │          │    SÌ  → vai a WAIT_SWAP             │
           │     └────┬──┬──┘                                       │
           │     NO ──┘  │ SÌ                                      │
           │             ▼                                          │
           │     ┌──────────┐                                       │
           │     │WAIT_SWAP │  fill_done_o = 1                     │
           │     │          │  Aspetta batch_done_i o epoch_done_i │
           │     │          │                                       │
           │     │          │  Su batch_done_i:                     │
           │     │          │    swap active_buf                    │
           │     │          │    ddr4_ptr += 0 (già avanzato)      │
           │     │          │    → BURST_AR (riempi prossimo)      │
           │     │          │                                       │
           │     │          │  Su epoch_done_i:                     │
           │     │          │    swap active_buf                    │
           │     │          │    ddr4_ptr = base_addr               │
           │     │          │    → BURST_AR (ri-prefetch dall'inizio)│
           │     └──┬───┬──┘                                       │
           │        │   │ (stop/idle)                               │
           └────────┘   └──────────────────────────────────────────┘
```

### 4.3 Gestione del Puntatore DDR4

```
Variabili interne:
  ddr4_ptr     [47:0]  — indirizzo corrente nella DDR4
  words_filled [16:0]  — quante parole 32-bit scritte nel buffer corrente
  beat_cnt     [8:0]   — contatore beat all'interno del burst

Inizializzazione:
  ddr4_ptr = base_addr_i
  
Dopo ogni burst completato:
  ddr4_ptr += BurstLen × 8   (8 byte per beat)
  
A fine epoca (epoch_done_i):
  ddr4_ptr = base_addr_i     (ricomincio da capo per la prossima epoca)
```

### 4.4 Scrittura BRAM: 2 Word per Beat

Il bus AXI ha 64 bit di dato. Ogni beat contiene **2 entry AER** da 32 bit:

```
AXI R beat N:  r.data = { word_hi[31:0], word_lo[31:0] }
                         [63:32]         [31:0]

→ Scrivi word_lo in BRAM[bram_wr_addr]     (ciclo N)
→ Scrivi word_hi in BRAM[bram_wr_addr + 1] (ciclo N+1, se serve via FSM pipelining)
```

Per semplificare, ogni R beat richiede **2 cicli di scrittura** sulla BRAM (che ha 1 porta di scrittura da 32 bit). Questo va bene perché il throughput di scrittura è comunque limitato dalla latenza AXI, non dalla BRAM.

**Alternativa più efficiente**: usare una BRAM con `RAM_WIDTH = 64` bit e scrivere una word da 64 bit per ciclo, poi fare la lettura a 32 bit con un piccolo adattatore. Ma aggiunge complessità; per il prototipo, la soluzione a 2 cicli è più sicura.

### 4.5 AXI Master Signals

```systemverilog
// Canale AR (Read Address) — unico canale attivo
always_comb begin
    axi_req_o          = '0;          // default: tutto a zero (AW/W morti)
    axi_req_o.b_ready  = 1'b1;       // sempre pronto ad accettare B (non arriveranno mai)
    
    // AR channel
    axi_req_o.ar.addr  = ddr4_ptr;
    axi_req_o.ar.len   = BurstLen - 1; // N+1 beat
    axi_req_o.ar.size  = 3'b011;       // 8 byte per beat (64 bit)
    axi_req_o.ar.burst = 2'b01;        // INCR
    axi_req_o.ar.id    = '0;
    axi_req_o.ar.lock  = 1'b0;
    axi_req_o.ar.cache = 4'b0010;      // Normal Non-cacheable
    axi_req_o.ar.prot  = 3'b000;
    axi_req_o.ar.qos   = 4'b0000;
    axi_req_o.ar.user  = '0;
    axi_req_o.ar_valid = (state == BURST_AR);
    
    // R channel
    axi_req_o.r_ready  = (state == BURST_R);
end
```

---

## 5. Modifiche RTL — File per File

### 5.1 `hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv`

#### 5.1.1 Abilitare `AxiExtNumMst = 1`

```diff
  function automatic cheshire_cfg_t gen_cheshire_xilinx_cfg();
    cheshire_cfg_t ret  = DefaultCfg;
    ret.RtcFreq         = 1000000;
    ...
    ret.AxiExtNumSlv    = 1;
+   ret.AxiExtNumMst    = 1;   // reckon_dram_prefetcher come AXI master
    return ret;
  endfunction
```

**Effetto in `cheshire_soc.sv`**: il blocco `gen_ext_axi_mst` (riga ~278) viene attivato:
```systemverilog
if (Cfg.AxiExtNumMst > 0) begin : gen_ext_axi_mst
    assign axi_in_req[AxiIn.num_in-1:AxiIn.ext_base] = axi_ext_mst_req_i;
    assign axi_ext_mst_rsp_o = axi_in_rsp[AxiIn.num_in-1:AxiIn.ext_base];
end
```

Questo aggiunge una **porta input** al crossbar AXI per il master esterno. Il crossbar poi **instraderà** le richieste del prefetcher verso la porta LLC out (per indirizzi `0x8000_0000–0xFFFF_FFFF`), che a sua volta va alla S_AXI_HP0 del PS → DDR4.

#### 5.1.2 Collegare il Prefetcher al SoC

Attualmente:
```systemverilog
.axi_ext_mst_req_i  ( '0 ),
.axi_ext_mst_rsp_o  ( ),
```

Diventa:
```systemverilog
// Segnali AXI master del prefetcher
axi_mst_req_t reckon_prefetch_axi_req;
axi_mst_rsp_t reckon_prefetch_axi_rsp;

// ...nella istanza cheshire_soc:
.axi_ext_mst_req_i  ( reckon_prefetch_axi_req ),
.axi_ext_mst_rsp_o  ( reckon_prefetch_axi_rsp ),
```

#### 5.1.3 Aggiungere Registri per `base_addr` e `batch_words`

Opzione consigliata: **non spostare** i registri esistenti (out_reg[0..7]). Portare `AxiRegsNout` da 8 a 10 in `axi_layer` e aggiungere i nuovi registri in coda:

| Registro | Uso |
|----------|-----|
| out_reg[0] | batch_size *(invariato)* |
| out_reg[1] | n_samples *(invariato)* |
| out_reg[2] | do_eprop *(invariato)* |
| out_reg[3] | reckon_ctrl_i[0] — NEW_EPOCH *(invariato)* |
| out_reg[4] | reckon_ctrl_i[1] — NEW_BATCH *(invariato)* |
| out_reg[5] | reckon_ctrl_i[2] — TEST *(invariato)* |
| out_reg[6] | reckon_ctrl_i[3] — STOP *(invariato)* |
| out_reg[7] | debug *(invariato)* |
| **out_reg[8]** | **DRAM_BASE_ADDR_LO** (32 bit bassi) |
| **out_reg[9]** | **DRAM_BASE_ADDR_HI [15:0] + BATCH_WORDS [31:16]** |

Nel top-level:
```systemverilog
wire [47:0] reckon_dram_base_addr;
wire [15:0] reckon_batch_words;

assign reckon_dram_base_addr = {axi_reg_o[9][15:0], axi_reg_o[8]};
assign reckon_batch_words    = axi_reg_o[9][31:16];
```

> **Nota**: Per lo spazio di indirizzamento Cheshire (`LlcOutRegionStart = 0x8000_0000`, `LlcOutRegionEnd = 0x1_0000_0000`), servono al massimo 33 bit. 48 bit è conservativo.

#### 5.1.4 Gatare NEW_BATCH e NEW_EPOCH

```systemverilog
// Segnali dal prefetcher
logic fill_done, active_buf;
logic batch_done_from_reckon, epoch_done_from_reckon;

// Gate: la FSM di aer_decoder resta in END_B/END_E finché il buffer è pronto
wire new_batch_gated = reckon_ctrl_i[1][0] & fill_done;
wire new_epoch_gated = reckon_ctrl_i[0][0] & fill_done;
```

E poi passare `new_batch_gated` e `new_epoch_gated` al `reckon_axi_top` al posto dei segnali diretti.

#### 5.1.5 Collegare LLC Output a S_AXI_HP0

Attualmente `axi_llc_mst_req` non è collegata (nessun `USE_DDR` definito). Aggiungere:

```systemverilog
`ifdef USE_MPSOC
  // LLC output → S_AXI_HP0 della PS → DDR4
  // Il crossbar mappa 0x8000_0000 alla porta LLC; la LLC forward al suo output
  assign s_axi_hp0_req   = axi_dram_mst_req;
  assign axi_dram_mst_rsp = s_axi_hp0_rsp;
`endif
```

La porta `S_AXI_HP0` va aggiunta all'interfaccia del wrapper MPSoC (vedi sezione 5.5).

### 5.2 `hw/axi_reckon/rtl/reckon_axi_top.v` (MODIFICATO)

Questa è la modifica più impattante su un file esistente. Cambiamenti:

1. **Rimuovere** la BRAM2_we_inst attuale
2. **Rimuovere** i porti BRAM_PORTA (la PS non scrive più nella BRAM)
3. **Aggiungere** due BRAM locali (Buffer A e Buffer B)
4. **Aggiungere** il MUX di lettura
5. **Aggiungere** i porti per il prefetcher

#### Port list modificata:

```diff
  module reckon_axi_top #(
      parameter ADDR_WIDTH = 16
  ) (
      input wire clk_i,
      input wire rst_i,
      ...
-     input wire  [ADDR_WIDTH+1:0] BRAM_PORTA_addr,
-     input wire                   BRAM_PORTA_clk,
-     input wire  [31:0]           BRAM_PORTA_din,
-     input wire                   BRAM_PORTA_en,
-     input wire                   BRAM_PORTA_rst,
-     input wire  [3:0]            BRAM_PORTA_we,
-     output wire [31:0]           BRAM_PORTA_dout,
+     // Prefetcher → BRAM write interface
+     input wire  [ADDR_WIDTH-1:0] pf_bram_wr_addr,
+     input wire  [31:0]           pf_bram_wr_data,
+     input wire                   pf_bram_wr_en,
+     input wire                   pf_bram_wr_sel,   // 0=write A, 1=write B
+     input wire                   active_buf_i,     // 0=read A, 1=read B
      ...
  );
```

#### Logica BRAM e MUX:

```verilog
// ============================================
//  DOPPIO BUFFER (BRAM A + BRAM B) + MUX
// ============================================

wire [31:0] din_buf_a, din_buf_b;

// Selezione CS per lettura (port B) — solo il buffer attivo risponde
wire cs_buf_a = ~active_buf_i & CS;
wire cs_buf_b =  active_buf_i & CS;

// Selezione write enable per scrittura (port A) — solo il buffer inattivo riceve
wire [3:0] we_buf_a = (~pf_bram_wr_sel) ? {4{pf_bram_wr_en}} : 4'b0; 
wire [3:0] we_buf_b = ( pf_bram_wr_sel) ? {4{pf_bram_wr_en}} : 4'b0;

// Buffer A
BRAM2_we_inst #(
    .NB_COL(4), .COL_WIDTH(8), .RAM_WIDTH(32),
    .RAM_DEPTH(2**ADDR_WIDTH), .INIT_FILE("")
) bram_buf_a (
    // Port A: scrittura dal prefetcher
    .ADDRA  (pf_bram_wr_addr),
    .DINA   (pf_bram_wr_data),
    .CLKA   (clk_i),
    .WEA    (we_buf_a),
    .CSA    (pf_bram_wr_en & ~pf_bram_wr_sel),
    .RSTA   (rst_i), .REGENA(),
    .DOUTA  (),  // non usata (write-only da questo lato)
    // Port B: lettura da aer_decoder
    .ADDRB  (RAM_ADDR),
    .DINB   (32'd0),
    .CLKB   (clk_i),
    .WEB    (4'b0),
    .CSB    (cs_buf_a),
    .RSTB   (), .REGENB(),
    .DOUTB  (din_buf_a)
);

// Buffer B
BRAM2_we_inst #(
    .NB_COL(4), .COL_WIDTH(8), .RAM_WIDTH(32),
    .RAM_DEPTH(2**ADDR_WIDTH), .INIT_FILE("")
) bram_buf_b (
    // Port A: scrittura dal prefetcher
    .ADDRA  (pf_bram_wr_addr),
    .DINA   (pf_bram_wr_data),
    .CLKA   (clk_i),
    .WEA    (we_buf_b),
    .CSA    (pf_bram_wr_en & pf_bram_wr_sel),
    .RSTA   (rst_i), .REGENA(),
    .DOUTA  (),
    // Port B: lettura da aer_decoder
    .ADDRB  (RAM_ADDR),
    .DINB   (32'd0),
    .CLKB   (clk_i),
    .WEB    (4'b0),
    .CSB    (cs_buf_b),
    .RSTB   (), .REGENB(),
    .DOUTB  (din_buf_b)
);

// MUX: aer_decoder riceve DIN dal buffer attivo
assign DIN = active_buf_i ? din_buf_b : din_buf_a;
```

**Costo risorse**: 2 × BRAM da 256 KB = **512 KB totale** di Block RAM su FPGA. La ZCU102 (xczu9eg) ha circa 32.1 Mb = 4 MB di BRAM. 512 KB è ~12.5% — accettabile.

### 5.3 `hw/axi_reckon/rtl/reckon_dram_prefetcher.sv` (NUOVO FILE)

Questo file va creato. La FSM è descritta in dettaglio nella Sezione 4. I punti chiave dell'implementazione:

- **Dominio di clock**: tutto su `clk_i` (= `soc_clk` a 50 MHz)
- **AXI burst**: il prefetcher genera burst INCR da `BurstLen` beat sul canale AXI AR/R
- **Scrittura dual-word**: per ogni R beat da 64 bit, scrive 2 parole da 32 bit nella BRAM del buffer inattivo
- **Swap**: su `batch_done_i` o `epoch_done_i`, toggling di `active_buf_o`
- **Reset DDR4 pointer**: su `epoch_done_i` → `ddr4_ptr = base_addr_i`

### 5.4 `hw/axi_reckon/rtl/axi_layer.sv` e `axi_rf.sv` (MODIFICHE MINORI)

Per supportare `AxiRegsNout = 10`:

In `axi_layer.sv`:
```diff
- logic [31:0] out_reg [0:7];
+ logic [31:0] out_reg [0:9];

- for (i = 0; i < 8; i = i + 1) begin : GEN_OUT_REGS
+ for (i = 0; i < 10; i = i + 1) begin : GEN_OUT_REGS
```

In `axi_rf.sv` (il modulo `AXI4_RF_slave_lite_v1_0_S00_AXI`), aggiungere:
```diff
  output wire [31:0] out_reg7,
+ output wire [31:0] out_reg8,
+ output wire [31:0] out_reg9,
```

E nella logica di write del register file, mappare gli indirizzi aggiuntivi.

> **Alternativa senza toccare axi_rf**: si possono riusare registri esistenti con bit-packing. Ma aumentare da 8 a 10 è la soluzione più pulita.

### 5.5 `target/xilinx/scripts/chs-bd-zcu102.tcl` (MODIFICATO)

Abilitare DDR4 e S_AXI_HP0 sulla PS:

```diff
  set_property -dict [list \
-   CONFIG.PSU__DDRC__ENABLE {0} \
+   CONFIG.PSU__DDRC__ENABLE {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__UART0__PERIPHERAL__ENABLE {1} \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
-   CONFIG.PSU__USE__M_AXI_GP2 {0} \
+   CONFIG.PSU__USE__S_AXI_GP2 {1} \
+   CONFIG.PSU__SAXIGP2__DATA_WIDTH {64} \
    CONFIG.PSU__FPGA_PL0_ENABLE {0} \
  ] [get_bd_cells zynq_ultra_ps_e_0]
```

Ed esporre la porta S_AXI_HP0 come interfaccia slave verso il top-level:

```tcl
# Collegamento S_AXI_HP0 alla PL
connect_bd_net [get_bd_pins /clk_wiz_0/clk_50] [get_bd_pins zynq_ultra_ps_e_0/saxihp0_fpd_aclk]
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_HP0
connect_bd_intf_net [get_bd_intf_ports S_AXI_HP0] [get_bd_intf_pins zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
```

---

## 6. Dettaglio AXI Burst — Parametri e Performance

### 6.1 Parametri del Burst

| Parametro | Valore | Note |
|-----------|--------|------|
| `ar.size` | `3'b011` | 8 byte per beat (64 bit, match data bus) |
| `ar.burst` | `2'b01` | INCR (incremento automatico dell'indirizzo) |
| `ar.len` | `255` | 256 beat per burst (max AXI4) |
| `ar.cache` | `4'b0010` | Normal Non-cacheable |
| Byte per burst | 2048 B | 256 beat × 8 B |
| Entry AER per burst | 512 | 2048 B / 4 B |
| Burst per riempire 1 buffer (64K entry) | 128 | 65536 / 512 |

### 6.2 Stima dei Tempi

A 50 MHz, con latenza DDR4 tipica via S_AXI_HP0:

| Metrica | Valore | Calcolo |
|---------|--------|---------|
| Latenza primo beat | ~20 cicli | AR handshake + DDR4 access |
| R beat successivi | ~1 ciclo/beat | Streaming (pipeline DDR4) |
| Tempo per 1 burst (256 beat) | ~280 cicli | 20 + 256 + overhead |
| Tempo per 128 burst (1 buffer) | ~36000 cicli | 128 × 280 |
| Tempo a 50 MHz | **~0.72 ms** | 36000 / 50M |

Un batch tipico di ReckOn richiede decine di millisecondi per il processing. Il prefetch di 0.72 ms è completamente nascosto dal processing del batch precedente (hidden latency).

### 6.3 Confronto con Lettura Singola (No Burst)

| Approccio | Cicli per 64K entry | Tempo @ 50 MHz |
|-----------|---------------------|----------------|
| **AXI Burst (questa guida)** | ~36,000 | **0.72 ms** |
| AXI single-beat (guida precedente) | ~1,300,000 | **26 ms** |
| Fattore miglioramento | **~36×** | |

---

## 7. Address Translation: Cheshire → PS DDR4

### 7.1 Il Problema

Il crossbar Cheshire mappa la DRAM a `0x8000_0000 – 0xFFFF_FFFF` (da `LlcOutRegionStart`).
La PS DDR4 è mappata a `0x0000_0000 – 0x7FFF_FFFF` (vista ARM).

Quando il prefetcher emette `AXI AR addr = 0x8000_0100`:
1. Il crossbar lo instrada alla porta LLC out ✅
2. La LLC lo forwarda a S_AXI_HP0 
3. S_AXI_HP0 riceve `0x8000_0100` — **fuori dal range DDR4 della PS!** ❌

### 7.2 Soluzione: Address Remap nel Vivado Address Editor

Il Vivado Address Editor permette di impostare l'offset dell'address segment S_AXI_HP0:

```tcl
# Nel block design:
set_property offset 0x00000000 [get_bd_addr_segs {S_AXI_HP0/SEG_DDR}]
set_property range 2G [get_bd_addr_segs {S_AXI_HP0/SEG_DDR}]
```

**Oppure**, soluzione RTL esplicita — un piccolo modulo che sottrae `0x8000_0000`:

```systemverilog
// axi_addr_remap: sottrae LlcOutRegionStart dagli indirizzi
assign s_axi_hp0_req        = axi_dram_mst_req;
assign s_axi_hp0_req.ar.addr = axi_dram_mst_req.ar.addr - 48'h8000_0000;
assign s_axi_hp0_req.aw.addr = axi_dram_mst_req.aw.addr - 48'h8000_0000;
assign axi_dram_mst_rsp      = s_axi_hp0_rsp;
```

### 7.3 Indirizzamento dal Punto di Vista Software

| Da dove | Base address | Range | Note |
|---------|-------------|-------|------|
| PS ARM (Linux/baremetal) | `0x0000_0000` | 2 GB | Indirizzo fisico DDR4 |
| Cheshire CVA6 | `0x8000_0000` | 2 GB | Via LLC → S_AXI_HP0 → DDR4 |
| Prefetcher (AXI addr) | `0x8000_0000` | 2 GB | Stesso path del CVA6 |

CVA6 configura `base_addr = 0x8000_0000 + offset_dati`, dove `offset_dati` è l'indirizzo usato dalla PS per scrivere i dati.

---

## 8. Cross-Clock Domain: `soc_clk` (50 MHz) vs `clk15` (15 MHz)

### 8.1 Problema

Nel design attuale:
- `reckon_axi_top` (con `aer_decoder` e `reckon SNN`) opera a `clk15` (15 MHz)
- Il crossbar Cheshire, `axi_layer`, e tutta la logica AXI opera a `soc_clk` (50 MHz)

Il prefetcher opera su `soc_clk` (perché parla AXI con il crossbar), ma scrive nelle BRAM che sono lette da `aer_decoder` su `clk15`.

### 8.2 Soluzione

Le **BRAM dual-clock** (`BRAM2_we_inst`) supportano **nativamente** clock indipendenti sulle porte A e B:

```verilog
BRAM2_we_inst bram_buf_a (
    .CLKA (soc_clk),   // Port A: scrittura dal prefetcher @ 50 MHz
    .CLKB (clk15),     // Port B: lettura da aer_decoder @ 15 MHz
    ...
);
```

Questo è corretto perché:
- Port A (write) e Port B (read) **non accedono mai allo stesso indirizzo contemporaneamente** (garantito dal ping-pong: il buffer attivo è solo letto, l'inattivo è solo scritto)
- La BRAM Xilinx è progettata per cross-clock nativamente

I segnali di controllo (`active_buf`, `fill_done`, `batch_done`) attraversano il confine clock. Servono **sincronizzatori**:

```verilog
// Sincronizzatore batch_done (clk15 → soc_clk)
reg batch_done_sync1, batch_done_sync2;
always @(posedge soc_clk) begin
    batch_done_sync1 <= batch_done_from_reckon;
    batch_done_sync2 <= batch_done_sync1;
end

// Sincronizzatore fill_done (soc_clk → clk15) 
// Questo gate il segnale NEW_BATCH che va ad aer_decoder su clk15
reg fill_done_sync1, fill_done_sync2;
always @(posedge clk15) begin
    fill_done_sync1 <= fill_done;
    fill_done_sync2 <= fill_done_sync1;
end
wire new_batch_gated = new_batch_from_cheshire & fill_done_sync2;
```

---

## 9. Software Cheshire (CVA6)

### 9.1 Flusso di Controllo

```c
#include "dif/uart.h"

// Indirizzi dei registri axi_layer
#define RECKON_REG_BASE     0x20000000ULL   // da configurare in AxiExtRegionStart

#define REG_BATCH_SIZE      (RECKON_REG_BASE + 0x00)
#define REG_N_SAMPLES       (RECKON_REG_BASE + 0x04)
#define REG_DO_EPROP        (RECKON_REG_BASE + 0x08)
#define REG_NEW_EPOCH       (RECKON_REG_BASE + 0x0C)
#define REG_NEW_BATCH       (RECKON_REG_BASE + 0x10)
#define REG_TEST            (RECKON_REG_BASE + 0x14)
#define REG_STOP            (RECKON_REG_BASE + 0x18)
#define REG_DEBUG           (RECKON_REG_BASE + 0x1C)
#define REG_DRAM_ADDR_LO    (RECKON_REG_BASE + 0x20)  // out_reg[8]
#define REG_DRAM_ADDR_HI_BW (RECKON_REG_BASE + 0x24)  // out_reg[9]

// Indirizzi DDR4 (vista Cheshire)
#define DDR4_BASE           0x80000000ULL

void run_reckon_from_dram(uint32_t dram_offset, uint16_t batch_words,
                          uint16_t batch_size, uint16_t n_samples) {
    // 1. Configura indirizzo base DDR4
    *((volatile uint32_t*)REG_DRAM_ADDR_LO) = (uint32_t)(DDR4_BASE + dram_offset);
    *((volatile uint32_t*)REG_DRAM_ADDR_HI_BW) = 
        ((uint32_t)batch_words << 16) | (uint16_t)((DDR4_BASE + dram_offset) >> 32);

    // 2. Configura parametri ReckOn
    *((volatile uint32_t*)REG_BATCH_SIZE) = batch_size;
    *((volatile uint32_t*)REG_N_SAMPLES) = n_samples;
    *((volatile uint32_t*)REG_DO_EPROP)  = 0;  // inference only
    *((volatile uint32_t*)REG_TEST)      = 1;  // test mode

    // 3. Avvia — il prefetcher riempie Buffer A, poi parte aer_decoder
    *((volatile uint32_t*)REG_NEW_EPOCH) = 1;
    
    // 4. Per ogni batch successivo (se serve software handshaking):
    //    Il prefetcher gestisce automaticamente il ping-pong.
    //    NEW_BATCH viene gatato da fill_done.
    for (int b = 1; b < n_samples / batch_size; b++) {
        *((volatile uint32_t*)REG_NEW_BATCH) = 1;
        // Polling BATCH_DONE (in_reg[2])
        while (!(*((volatile uint32_t*)(RECKON_REG_BASE + 0x48))));
        *((volatile uint32_t*)REG_NEW_BATCH) = 0;
    }

    // 5. Leggi risultato
    uint32_t infer_count = *((volatile uint32_t*)(RECKON_REG_BASE + 0x40));
}
```

### 9.2 Alternativa: Prefetcher Autonomo

Per semplificare il software, il prefetcher potrebbe auto-generare `NEW_BATCH` quando il fill è completo, rendendo il loop software non necessario. In questo caso:

```c
// Solo:
*((volatile uint32_t*)REG_NEW_EPOCH) = 1;
// ... aspetta EPOCH_DONE ...
uint32_t result = *((volatile uint32_t*)(RECKON_REG_BASE + 0x40));
```

Il prefetcher genera internamente `NEW_BATCH` = `fill_done & batch_done_latched`, rendendo il flusso completamente autonomo dopo l'avvio.

---

## 10. Riepilogo Completo delle Modifiche

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FILE DA CREARE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. hw/axi_reckon/rtl/reckon_dram_prefetcher.sv
   → Nuovo modulo AXI master con FSM burst e gestione ping-pong
   → ~200-300 righe di RTL

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FILE DA MODIFICARE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

2. hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv
   [a] gen_cheshire_xilinx_cfg(): ret.AxiExtNumMst = 1
   [b] Dichiarare segnali AXI prefetcher
   [c] Collegare .axi_ext_mst_req_i / .axi_ext_mst_rsp_o
   [d] Aggiungere registri out_reg[8] e out_reg[9]
   [e] Gatare NEW_BATCH/NEW_EPOCH con fill_done
   [f] Istanziare reckon_dram_prefetcher
   [g] Collegare LLC output → S_AXI_HP0 (con addr remap)
   [h] Aggiungere sincronizzatori cross-clock
   [i] Aggiornare interfaccia reckon_axi_top (rimuovere BRAM_PORTA)

3. hw/axi_reckon/rtl/reckon_axi_top.v
   [a] Rimuovere porte BRAM_PORTA 
   [b] Aggiungere porte prefetcher (write addr/data/en/sel, active_buf)
   [c] Rimuovere istanza BRAM2_we_inst esistente
   [d] Aggiungere 2× BRAM2_we_inst (Buffer A + Buffer B)
   [e] Aggiungere MUX per DIN

4. hw/axi_reckon/rtl/axi_layer.sv
   [a] out_reg: da [0:7] a [0:9]
   [b] GEN_OUT_REGS: da 8 a 10

5. hw/axi_reckon/rtl/axi_rf.sv
   [a] Aggiungere out_reg8, out_reg9 nelle porte output
   [b] Mappare i registri AXI-Lite aggiuntivi

6. target/xilinx/scripts/chs-bd-zcu102.tcl
   [a] PSU__DDRC__ENABLE → {1}
   [b] Aggiungere PSU__USE__S_AXI_GP2 {1}
   [c] Aggiungere collegamento S_AXI_HP0
   [d] Address editor: mappare S_AXI_HP0 alla DDR4

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FILE NON MODIFICATI:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ hw/axi_reckon/rtl/aer_decoder.v          — INVARIATO
✅ hw/cheshire_soc.sv                       — INVARIATO (generici gestiscono tutto)
✅ hw/cheshire_pkg.sv                       — INVARIATO
✅ hw/axi_reckon/rtl/BRAM_2ports_we.v       — INVARIATO (riusato ×2)
✅ hw/axi_reckon/rtl/reckon (SNN core)      — INVARIATO
```

---

## 11. Verifica di Coerenza

### 11.1 Checklist Architetturale

| # | Domanda | Risposta | Verifica |
|---|---------|----------|----------|
| 1 | ReckOn va a prendere i dati dalla DDR4? | Sì — `reckon_dram_prefetcher` è un AXI master che emette read burst verso la DDR4 | ✅ |
| 2 | Cheshire fornisce solo l'indirizzo? | Sì — CVA6 scrive `base_addr` e `batch_words` nei registri axi_layer | ✅ |
| 3 | aer_decoder è invariato? | Sì — vede la stessa interfaccia BRAM (CS/RAM_ADDR/DIN, 1 ciclo) | ✅ |
| 4 | Il modello è Pull (non Push)? | Sì — il prefetcher inizia la transazione AXI (master), nessun DMA esterno | ✅ |
| 5 | Supporta >256 KB di dati? | Sì — i dati sono in DDR4 (fino a 2 GB), il buffer locale è solo un staging area | ✅ |
| 6 | Usa burst per efficienza? | Sì — burst INCR, fino a 256 beat (2 KB) per transazione | ✅ |
| 7 | Il clock crossing è gestito? | Sì — BRAM dual-clock + sincronizzatori per segnali di controllo | ✅ |
| 8 | Il path AXI è completo? | Sì — prefetcher → crossbar → LLC → S_AXI_HP0 → DDR4 | ✅ |

### 11.2 Potenziali Rischi e Mitigazioni

| Rischio | Probabilità | Mitigazione |
|---------|:-----------:|-------------|
| BRAM insufficiente (512 KB su ZCU102) | Bassa | ZCU102 ha 4 MB BRAM; 512 KB = 12.5% |
| Latenza burst > tempo batch | Molto bassa | Fill: ~0.72 ms; batch processing: >>10 ms |
| Conflitto AXI con CVA6 | Media | Il crossbar arbitra; il prefetcher ha bassa priorità. Se serve: AXI RT |
| Address translation PS errata | Media | Verificare con ILA probe sugli indirizzi S_AXI_HP0 |
| CDC (clock domain crossing) bug | Media | Usare `sync` module del repo (2-FF synchronizer) |

### 11.3 Confronto con la Guida Precedente (GUIDA_DDR4_RECKON_MASTER.md)

| Aspetto | Guida precedente | Questa guida |
|---------|------------------|-------------|
| aer_decoder | **Richiede modifica** (stato MEM_WAIT) | **Invariato** |
| Latenza lettura | 15-50 cicli per entry (stallo FSM) | **1 ciclo** (BRAM locale) |
| Throughput | Una entry alla volta | **Burst 2 KB** (512 entry alla volta) |
| Risorse BRAM | 256 KB (1 buffer) | 512 KB (2 buffer ping-pong) |
| Complessità RTL | Bassa (1 modulo semplice) | Media (1 modulo con FSM burst + ping-pong) |
| Rischio funzionale | Alto (timing aer_decoder rotto) | **Basso** (aer_decoder invariato) |

---

## 12. Roadmap Implementativa (Ordine Consigliato)

### Fase 1: Infrastruttura PS DDR4 (1-2 giorni)

1. Modificare `chs-bd-zcu102.tcl` per abilitare DDR4 e S_AXI_HP0
2. Rigenerare il block design Vivado
3. Verificare con un test PS semplice che scrive/legge DDR4

### Fase 2: AXI Master nel Crossbar (1 giorno)

1. Aggiungere `AxiExtNumMst = 1` nella config
2. Collegare `axi_ext_mst_req_i` / `axi_ext_mst_rsp_o` con un test stub
3. Verificare che il crossbar si sintetizza senza errori

### Fase 3: Prefetcher e Doppio Buffer (3-5 giorni)

1. Creare `reckon_dram_prefetcher.sv`
2. Modificare `reckon_axi_top.v` (doppio BRAM + MUX)
3. Collegare tutto nel top-level
4. Test con dati fissi in DDR4 → verificare che aer_decoder legge correttamente

### Fase 4: Integrazione e Validazione (2-3 giorni)

1. Software CVA6: scrivere test che configura i registri e avvia
2. PS software: caricare dataset AER in DDR4
3. End-to-end: PS carica → Cheshire configura → ReckOn elabora → verifica risultati
4. Debug con ILA probes su: AXI AR/R, BRAM write, MUX, batch_done, fill_done
