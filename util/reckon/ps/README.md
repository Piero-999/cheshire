# Flow PS-first: la board si porta dietro bitstream e training set

Chiude l'ultimo step di sviluppo pinnato in [`guides/HANDOFF.md`](../../../guides/HANDOFF.md).
La board tiene **bitstream + training set**; la PS configura la PL e scrive i dati; da fuori
arriva solo il JTAG a caricare e far partire il software di Cheshire.

```
  1. accendo la PS            (SD boot; bitstream e dataset sono già a bordo)
  2. PS    --PCAP-->  PL configurata          reckon_load.py     ┐ sulla PS
  3. PS    --HPM0-->  dati in DDR4            reckon_feed        ┘
  4. JTAG  --Olimex-->  ELF su Cheshire + via   run_test.sh       da fuori

 PS Linux (aarch64)                     PL / Cheshire (RISC-V)
 reckon_feed  --mmap /dev/mem-->  DDR4  <--iDMA--  BRAM  -->  ReckOn
      |            0xA000_0000    ===    0x8000_0000              ^
      |                          stessa cella fisica              |
      +--------- mailbox 0xA010_0000 == 0x8010_0000 --------------+
```

Configurare la PL dalla PS invece che da Vivado non è solo comodità:

- **elimina l'hazard di ordine.** Se la PL non è configurata, `maxihpm0_fpd_aclk` (che viene dal
  `clk_wiz` in PL) non gira: la scrittura a `0xA000_0000` non riceve mai risposta e **il core ARM
  si pianta nella store**, senza timeout né segnale. Se è la PS a configurare, quel caso non può
  più presentarsi.
- **niente più VIO reset**: una configurazione PCAP fresca riparte da reset su tutti i domini di
  clock, ReckOn (`clk15`) compreso.
- **il loop quotidiano non usa più Vivado né hw_server** — solo OpenOCD sull'Olimex, che è un TAP
  diverso. Vivado resta per ILA/VIO.

## L'offset: PS = CVA6 + 0x2000_0000

`M_AXI_HPM0_FPD` ha l'apertura bassa a `0xA000_0000..0xAFFF_FFFF` e la ZynqMP mette
sul bus l'indirizzo fisico così com'è. Cheshire decodifica `0x8000_0000..0x1_0000_0000`
verso la porta DDR4, la DDR4 PL è da 512 MB e il wrapper tronca a `addr[28:0]`
([`dram_wrapper_xilinx.sv:250`](../../../target/xilinx/src/dram_wrapper_xilinx.sv#L250)):
`0xA000_0000` e `0x8000_0000` finiscono sulla stessa cella. Dettaglio completo nel
commento di [`reckon_ps_mbox.h`](../../../sw/include/reckon/reckon_ps_mbox.h).

Non serve nessuna manutenzione di cache in nessuna delle due direzioni: sulla CVA6 non
c'è **niente** di cacheable (`NrCachedRegionRules = 0`, LOGBOOK §8.6) e la PS mappa
l'apertura con `O_SYNC`, cioè Device-nGnRnE.

## I pezzi

| file | dove gira | cosa fa |
|---|---|---|
| [`../gen_ps_dataset.py`](../gen_ps_dataset.py) | dev host | replica `rk_pack_half()` e genera `reckon_dataset.bin`, l'immagine esatta da copiare in DDR4 |
| `reckon_load.py` | PS | configura la PL via `fpga_manager` (PCAP) di default; `--pynq` usa PYNQ, che **funziona** — vedi sotto perché il default resta l'altro |
| `reckon_feed.c` | PS | mmap dell'apertura, scrive il payload, poi la mailbox; attende l'ack |
| [`reckon_ps_mbox.h`](../../../sw/include/reckon/reckon_ps_mbox.h) | entrambi | contratto condiviso: indirizzi, mailbox, checksum, formato del file |
| [`../../../sw/tests/reckon_stream_ps.c`](../../../sw/tests/reckon_stream_ps.c) | CVA6 | come `reckon_stream_idma.c` ma con `reckon_wait_ddr_from_ps()` al posto di `reckon_prepare_ddr()` |
| [`../ps_deploy.sh`](../ps_deploy.sh) | dev host | orchestratore: genera, copia, compila sulla board, esegue |

Il packing **non** è duplicato lato PS di proposito: lo fa una volta sola il generatore
sull'host, partendo dagli stessi header del firmware, così la geometria non può divergere.

## Uso

Dal dev host, un comando per tutto il flow:

```bash
util/reckon/ps_deploy.sh          # genera il dataset, copia tutto sulla board, compila lì
util/reckon/ps_deploy.sh --load   # + la PS configura la PL
util/reckon/ps_deploy.sh --probe  # + verifica che PS 0xA0000000 == CVA6 0x80000000
util/reckon/ps_deploy.sh --run    # + dati in DDR4 + firmware via JTAG   ← il giro completo
```

Il bitstream viene ricopiato solo se sulla board non c'è già quello (confronto md5): dopo la
prima volta la board se lo tiene, come da flow.

Sulla board, a mano:

```bash
sudo ./reckon_load.py cheshire.zcu102.bit    # fpga_manager; --check per solo leggere l'header
sudo ./reckon_feed --probe                   # scrive 0xC0FFEE01 a 0xA0000000 e rilegge
sudo ./reckon_feed --no-wait                 # carica i dati e la mailbox, poi esce
sudo ./reckon_feed                           # carica e attende l'ack dalla CVA6
sudo ./reckon_feed --status                  # rilegge la mailbox e l'ack, non modifica nulla
sudo ./reckon_feed --status --expect-seq N   # ...e fallisce se l'ack non e' per il seq N
./reckon_feed --dry-run                      # valida solo il file, non tocca /dev/mem
sudo ./reckon_feed --verify                  # + rilegge i 512 KiB parola per parola
```

**`--verify` è spento di default**, ed è una scelta deliberata: costa ~85 ms contro gli 8.6 ms
della scrittura che controlla, e il firmware campiona già il payload dalla sua parte. Accendilo
quando un giro non torna, non a ogni giro. Stessa logica sull'altro lato: il firmware verifica
513 parole invece di 131072 (1.18 ms invece di ~240 ms) — `-DRECKON_PS_FULL_CHECKSUM=1` riporta
la scansione esaustiva. Il perché, e cosa si perde, sta in `reckon_ps_mbox.h` e in LOGBOOK §13.5.

## L'ambiente sulla board (misurato, 2026-07-28)

Non è quello che il piano dava per scontato. Vale la pena saperlo prima di perdere tempo.

| | |
|---|---|
| immagine | **PynqLinux 3.0 "Belfast"**, kernel `5.15.19-xilinx-v2022.1` (non PetaLinux 2022.2) |
| PYNQ | 3.0.1, **funzionante** (serve però l'ambiente giusto: vedi sotto) |
| `fpga_manager` | presente (`Xilinx ZynqMP FPGA Manager`), è il percorso di default |
| XRT | **installato** in `/usr/lib` (`libxrt_core.so` ecc.), `XILINX_XRT=/usr` |
| gcc | 11.2.0 a bordo → `reckon_feed` si compila nativamente |
| `sudo` | **chiede la password** (`xilinx` è nel gruppo `sudo`, non NOPASSWD) |
| `devmem` | **non installato** → per leggere la mailbox si usa `reckon_feed --status` |
| accesso | solo SSH: la CP2108 non è collegata, quindi **nessuna console PS** |

**PYNQ funziona — ma sbaglia diagnosi in modo spettacolare se l'ambiente è incompleto.**
Lanciandolo da una shell **non di login** (cioè un banale `ssh host 'comando'`) si ottiene:

```
AttributeError: 'NoneType' object has no attribute 'xclOpen'
RuntimeError: No Devices Found
```

che sembra dire "XRT non è installato". **Non è così.** In PYNQ 3.0 la classe per ZynqMP è
`EmbeddedDevice`, derivata da `XrtDevice`, e il costruttore chiama `xrt.xclOpen()`; ma
`pynq/_3rdparty/xrt.py` carica la libreria **solo** `if "XILINX_XRT" in os.environ`. Quella
variabile la definisce `/etc/profile.d/xrt_setup.sh`, che una shell non interattiva non carica
mai. Le librerie sono lì, in `/usr/lib`. Servono due cose:

- `XILINX_XRT=/usr` nell'ambiente;
- l'interprete del venv, `/usr/local/share/pynq-venv/bin/python3` — quello di sistema non riesce
  proprio a importare `pynq` (manca `pydantic`).

`reckon_load.py --pynq` **si ri-esegue da solo** con entrambe le condizioni, quindi funziona anche
da `ssh host 'comando'`. Verificato: `download()` in **1.78 s**, e il ponte PS→DDR4 resta intatto
(probe + giro completo superati su una PL configurata da PYNQ).

Il default resta `fpga_manager` non perché PYNQ non vada, ma perché non dipende da niente: né
venv, né variabili d'ambiente, né XRT. Sotto il cofano è comunque lo stesso PCAP.

(Nota: `download()` in 3.0 chiama `set_axi_port_width()`, che riscrive i registri AFI dell'FPD dai
metadati del design. Con un `.bit` nudo il parser non ha `ps_name` e la chiamata esce subito —
quindi **non** disturba l'HPM0 a 128 bit da cui dipende questo progetto, come conferma il fatto
che il ponte funziona dopo un download PYNQ. Chi aggiunge un `.hwh` deve ricontrollarlo:
sbagliarlo rompe il ponte in silenzio.)

## Trappole che costano ore

1. **Prima si configura la PL, poi si tocca `0xA000_0000`.** È il motivo per cui il flow mette
   `reckon_load.py` prima di `reckon_feed`: a fabric non configurata la store non riceve risposta
   e **il core ARM si pianta**, senza timeout né segnale. `reckon_feed` fa la prima scrittura in
   un processo figlio con timeout, così invece di una shell congelata ottieni una diagnosi — ma
   il core resta perso fino al reboot: la difesa vera è l'ordine.
2. **Anche dopo la configurazione, la DDR4 deve calibrare.** Il MIG ricalibra a ogni
   riconfigurazione (~centinaia di ms) e finché non ha finito il suo lato AXI non accetta nulla:
   stesso hang. `reckon_load.py --settle` (default 1 s) copre il caso.
3. **Mai `memcpy()` sull'apertura — né in scrittura né in lettura.** `O_SYNC` dà memoria Device:
   gli accessi non allineati o multi-registro (`ldp`/`ldnp`) fanno fault o si comportano male, e
   la `memcpy` della libc è libera di emetterne. `reckon_feed` usa solo accessi a 32 bit allineati.
   Vale anche per Python: **uno slice `m[0:64]` di una `mmap` è una `memcpy`**, e sull'apertura
   restituisce un miscuglio di parole vicine che *sembra* plausibile — alcune corrette, altre no.
   È già costato una diagnosi sbagliata. Per leggere, `reckon_feed --status`.
4. **Boot mode.** La SW6 deve essere su SD: in JTAG boot la PS resta ferma e il PCAP non è
   utilizzabile, quindi non si potrebbe configurare nulla.

5. **Un handover mai consumato resta armato, e il run dopo se lo prende.** Il consume-once del
   firmware evita di rileggere *lo stesso* handover; non evita di raccoglierne uno **residuo**.
   Se un run va in timeout e il feed arriva tardi, quel magic resta in mailbox: il run successivo
   lo consuma subito e streamma dati vecchi **sembrando sanissimo** (`B00B0002`, contatori a
   posto, checksum ok — che torna, perché payload e checksum vengono entrambi dal feed stantio).
   L'unico testimone è il **numero di sequenza**. Difese, tutte già attive:
   `reckon_feed` ritira il magic prima di riscrivere il payload e avverte se ne trovava uno in
   piedi; `--status --expect-seq N` fallisce se l'ack non è per quel seq; `ps_deploy.sh --run` lo
   verifica da sé a fine giro. **Se usi `--no-wait` a mano, controlla l'ack.**

Minore: **niente VIO reset con traffico PS in volo** — `rst_n` resetta anche gli `iw`/`dw_converter`
del ponte, la risposta B si perde e Linux resta appeso. In questo flow il VIO reset non serve
comunque, perché ogni giro riparte da una configurazione fresca.

## Diagnostica

| sintomo | dove guardare |
|---|---|
| `reckon_load.py` dice `state: <qualcosa> != operating` | la PL **non** è configurata: non lasciare che nulla tocchi `0xA000_0000` |
| serve leggere la mailbox dalla PS | `sudo ./reckon_feed --status`. **Non** usare `devmem` (non installato) né uno slice `mmap` di Python: sull'apertura Device quella è una `memcpy` e restituisce parole mescolate |
| `reckon_feed` dice "the aperture did not answer within 5 s" | PL non configurata o MIG ancora in calibrazione (vedi trappole 1 e 2) |
| `scratch3 = B00B00EE` | fallimento **pulito**. Se è morto nello STEP 2, la mailbox non è arrivata o il checksum non torna: la UART dice quale dei due, e la PS riceve `ack = D09E0002` (`rc=2`) con `ACK_SEQ = 0`. **Verificato su HW.** |
| `scratch3 = B00B0012` | è ancora **dentro** lo STEP 2, cioè incastrato lì: `B00B0012` è il marker d'ingresso (`RECKON_STEP_DDR`), non un codice d'errore. Diverso da `B00B00EE`. |
| `reckon_feed` va in timeout con magic ancora `DA7AC0DE` | il firmware non è mai arrivato allo STEP 2 (l'ELF è stato lanciato?) |
| `reckon_feed` va in timeout con magic azzerato | il firmware ha preso i dati ma non ha finito: leggi `stream_status` da JTAG |
| checksum sbagliato lato CVA6 | la PS ha scritto nel posto sbagliato: quasi sempre l'offset `0x2000_0000` |

La mailbox è leggibile anche a mano dalla board:

```bash
sudo devmem 0xA0100000   # magic  (0 = consumato dal firmware)
sudo devmem 0xA0100020   # ack    (D09E0000 | rc)
sudo devmem 0xA0100028   # stream_status a EPOCH_DONE
```

## Limite noto di questo bitstream

Attraverso HPM0 la PS raggiunge **solo** l'apertura DRAM: registri ReckOn (`0x4000_0000`),
BRAM (`0x4800_0000`) e registri Cheshire (`0x0300_0000`) restano fuori portata, perché
l'RTL zero-estende i 40 bit dell'indirizzo e l'apertura alta FPD (`0x04_xxxx_xxxx`) non
becca nessuna regola di decode. Per questo l'esito del run torna alla PS via mailbox
invece che leggendo `stream_status`, e per questo **la CVA6 si avvia sempre da JTAG**.

Dare alla PS la visibilità su ReckOn è una modifica di una riga in
[`xilinx_zcu102_reckon_chs_top.sv`](../../../hw/axi_reckon/rtl/xilinx_zcu102_reckon_chs_top.sv#L619)
(usare `awaddr[31:0]` invece di zero-estendere), ma richiede una **ri-sintesi completa**.

> ⚠️ **Quella riga non toglierebbe però il JTAG dal giro.** Il debug module ha tre interfacce
> separate e il **DMI** (`dmcontrol`/`dmstatus`, cioè `haltreq`/`resumereq`) è cablato solo da
> `i_dbg_dmi_jtag`: **non è mappato in memoria per nessuno**, quindi nessuna apertura della PS può
> arrivarci. Servirebbe un ponte AXI→DMI nuovo in RTL. La via senza modifiche RTL è far ciclare il
> firmware sulla mailbox invece di riavviarlo a ogni epoca — magic, seq e ack ci sono già.
