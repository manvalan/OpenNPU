# FPGA-Neural v4 — documentazione completa

Acceleratore MobileFaceNet ("G-esteso") su XC7A100T-CSG324-2 con DDR3 a
32 bit, pilotato da un ESP32-S3. Questo è il documento di riferimento
della v4: cosa fa, come è fatta, come si usa dall'ESP32, come si
ricostruisce e si verifica, cosa è misurato e cosa no.

Tutti i numeri sono **misurati** (simulazione RTL, xsim con MIG reale,
place & route Vivado in contesto) salvo dove è scritto *stima*.

| Documento | Contenuto |
|---|---|
| questo file | riferimento completo |
| [`COME_FUNZIONA_G_ESTESO.md`](COME_FUNZIONA_G_ESTESO.md) | spiegazione dell'architettura e dell'esecuzione della rete |
| [`PINOUT_V4.md`](PINOUT_V4.md) | pin FPGA ed ESP32, bank, connettore BTB 40 pin verso la base |
| [`CONNETTORE_BTB_V4.md`](CONNETTORE_BTB_V4.md) | connettore modulo ↔ base (hanxia HX-BTB 40 pin), mappa, scelta |
| [`buildbook/FPGA-Neural-V4-Buildbook.md`](buildbook/FPGA-Neural-V4-Buildbook.md) | Buildbook: la storia del progetto, poi il riferimento tecnico (ex datasheet rev. 2.0): processore, regole, prestazioni, elettrica, pin, firmware, progettare e creare una rete, esempi |
| [`PROGRESS_LOG.md`](PROGRESS_LOG.md) | registro passo per passo (V4-S*, V4-B*) con test e numeri |
| [`../bitstream/README.md`](../bitstream/README.md) | bitstream pronti, sha256, tag git |
| `pnr/`, `pnr/board/`, `pnr/board/flashcfg/` | report di timing, utilizzo, DRC, IO e potenza (flashcfg: build con la flash sui pin Master SPI) |

---

## 1. Risultato

| | 199,34 MHz (tag `v4-board-199`, ECO `v4-board-199-flashcfg`) | 189,20 MHz (tag `v4-board-189`, ECO `v4-board-189-flashcfg`) |
|---|---|---|
| WNS / WHS | +0,003 / +0,011 ns | +0,033 / +0,028 ns |
| cicli per inferenza (MIG reale) | 460.592 | 460.592 |
| tempo di calcolo | **2,311 ms** | 2,434 ms |
| rispetto a ESP32-S3 (248,8 ms, ESP-DL) | **107,7x** | 102,2x |
| start→done visto dall'ESP32 | 2,342 ms (MIG reale) | non simulato (*stima* ~2,46 ms) |

Un'inferenza = immagine grezza 112×112×3 INT8 → embedding di 128 valori (modello di prova) o 512 (MobileFaceNet ESP-DL reale)
INT8, identico bit per bit al modello C `model/gen_mfn.c`.

Trasferimenti dall'ESP32: immagine (37.632 byte) via Quad-SPI a 80 MHz
in 0,941 ms (38,9 MB/s); embedding + statistiche (9 parole da 16 byte)
via Quad-SPI. Con due buffer immagine (API pipeline, §6.3) l'immagine
successiva viaggia mentre la corrente viene calcolata: il throughput è
limitato dal calcolo, circa 430 inferenze/s a 199 MHz (*stima* da
2,337 ms per run).

Risorse (199 MHz): 49.969 LUT (78,8 %), 60.024 FF (47,3 %), 132,5/135
BRAM (98 %), 224/240 DSP.

## 2. Architettura della scheda

```
               ESP32-S3
   SPI3 (gestione, ≤20 MHz)      SPI2 QIO (dati, 80 MHz)
        │                                │
 ┌──────┼────────────────────────────────┼─────────────────────────────┐
 │ spi_host_bridge_v3_chained      qspi_data_port   (dominio qsclk)     │
 │   registri, WRITE/READ_MEM,         │ FIFO asincrone                 │
 │   flash di configurazione           │                               │
 │        │ host_mem_bridge            │                               │
 │        └──────► arbitro ◄───────────┘                               │
 │                   │  (+ v4_ddr_stream: lettura/scrittura del core)   │
 │            mig_native_adapter ── MIG 7-series ── DDR3 2×x16          │
 │                   │                 ui_clk 155,04 MHz                │
 │        FIFO asincrone (Gray) + toggle di start/done                  │
 │                   │                                                  │
 │   core_clk 199,34 MHz (MMCM da ui_clk, M=9 D=1 O=7)                  │
 │   v4_boot ──► v4_core (descrittori, parametri, fmap, engine, GDConv) │
 └──────────────────────────────────────────────────────────────────────┘
```

Tre domini di clock, collegati solo da FIFO asincrone con puntatori Gray
e sincronizzatori a toggle (vincolati con `set_max_delay -datapath_only`
nello XDC):

| Clock | Frequenza | Da dove |
|---|---|---|
| `osc_200` | 200 MHz | unico oscillatore LVDS su N5/P5 (dalla rev. 1.3): riferimento IDELAYCTRL e ingresso dell'MMCM ×31/5/4 → 310 MHz al MIG |
| `ui_clk` | 155,0 MHz | MIG (memoria 310 MHz; fino alla rev. 1.2: 155,04 MHz da un oscillatore a 310,078 MHz) |
| `core_clk` | 199,29 MHz | MMCME2_BASE su ui_clk, `CLKOUT0_DIVIDE_F` 7,000 (7,375 → 189,15 MHz); 199,34 MHz fino alla rev. 1.2 |
| `qsclk` | 80 MHz | pin D15, dall'ESP32 |

Schema RTL del top generato da Vivado (design elaborato, 257 celle):
[`img/schema_rtl_v4.svg`](img/schema_rtl_v4.svg) (vettoriale, zoomabile) e
[`img/schema_rtl_v4.png`](img/schema_rtl_v4.png).

### 2.1 Blocchi (hardware/v4/rtl)

| File | Ruolo |
|---|---|
| `v4_board_top.v` | top della scheda: MIG, bridge SPI v3, porta QSPI, arbitro, CDC, MMCM, boot, core |
| `v4_boot.v` | legge l'header dalla DDR3, carica descrittori e immagine nel core, avvia, riscrive risultato e statistiche |
| `v4_ddr_stream.v` | porta DDR3 del core e del boot (burst da 256 bit, pipelined) |
| `qspi_data_port.v` | porta dati Quad-SPI (comandi 0x1A/0x2A, §5.2) |
| `async_fifo.v` | FIFO asincrona con puntatori Gray |
| `v4_core.v` | sequencer a descrittori, memorie parametri, porta host, 40 passate |
| `param_loader.v` | streaming dei parametri dalla DDR3, doppio buffer per passata |
| `dwpw_engine.v` | depthwise 3×3 + pointwise fusi (e modo solo-pointwise) |
| `dw_linebuf_grouped.v`, `depthwise_mac3x3_pipe.v` | line buffer in BRAM e MAC depthwise |
| `pw_array_packed.v` | array pointwise 16×16, 2 MAC INT8 per DSP48E1 |
| `requant_act.v` | requantizzazione (shift potenza di 2) + PReLU, 8 stadi |
| `gdconv_unit.v` | GDConv 7×7 finale |
| `im2col_feeder.v` | im2col del conv1 dall'immagine grezza |
| `fmap_mem.v`, `fmap_feeder.v`, `tile_writer.v` | 3 banchi fmap da 128 KB, lettura, scrittura con residuo |

Riusati da v3 senza modifiche: `spi_host_bridge_v3_chained.v`,
`host_mem_bridge.v`, `mig_native_adapter.v`, `flash_spi_master.v`.

## 3. Memoria DDR3

Indirizzi in parole da 128 bit (W). Il layout è scelto dall'host
tramite l'header; quello usato da `gen_mfn.c` e dai test:

| W | Contenuto |
|---|---|
| 16 | header (2 parole) |
| 64 | tabella descrittori (3 parole per passata, 40 passate) |
| 256 | immagine grezza, 2.352 parole = 37.632 byte, HWC |
| 4096 | immagine dei parametri (~1 MB) |
| 80000 | risultato: 8 parole di embedding + 1 parola di statistiche |

Byte k di una parola = bit [8k+7:8k]. Sull'ESP32 little-endian un buffer
di byte è già nell'ordine giusto.

### 3.1 Header (`v4_boot.v`)

| Parola | Bit | Campo |
|---|---|---|
| w0 | [15:0] | numero di passate (1..64) |
| w0 | [47:16] | W della tabella descrittori |
| w0 | [79:48] | W dell'immagine |
| w0 | [95:80] | parole dell'immagine |
| w0 | [111:96] | indirizzo fmap dove copiare l'immagine |
| w1 | [31:0] | W del risultato |
| w1 | [47:32] | indirizzo fmap del tensore di uscita |
| w1 | [63:48] | parole di uscita |
| w1 | [95:64] | W base dei parametri (sommata a ogni richiesta del loader) |
| w1 | [127:96] | magic `0x344E4E56` ("VNN4") |

Parola di statistiche dopo il risultato: [31:0] cicli totali del core,
[63:32] cicli in attesa dei parametri, [64] errore, [127:96] magic.

## 4. Come si svolge un'inferenza

1. Una volta sola: l'ESP32 scrive in DDR3 header, descrittori e
   parametri (il "blob" generato offline).
2. Per ogni immagine: l'ESP32 scrive l'immagine via Quad-SPI.
3. L'ESP32 scrive NETWORK_BASE (= 4 × W dell'header) e dà start
   (CONTROL bit1).
4. `v4_boot` legge l'header, copia descrittori e immagine nel core e
   lo avvia; il core esegue le 40 passate caricando i parametri di ogni
   passata dalla DDR3 durante quella precedente.
5. `v4_boot` riscrive embedding e statistiche in DDR3 e alza done.
6. L'ESP32 vede STATUS bit4 (o l'IRQ `data_ready_n`) e legge il
   risultato via Quad-SPI.

## 5. Interfaccia verso l'ESP32

Pin e collegamenti: [`PINOUT_V4.md`](PINOUT_V4.md).

### 5.1 SPI di gestione (bridge v3, invariato)

SPI mode 0, SCLK fino a circa 20 MHz (il bridge sovracampiona in
ui_clk). Comandi usati dalla v4:

| Byte | Comando | Formato |
|---|---|---|
| 0x30 | scrittura registro | 0x30, reg, 4 byte MSB first |
| 0x31 | lettura registro | 0x31, reg, 4 byte letti |
| 0x01 | WRITE_MEM | 0x01, indirizzo halfword 25 bit (4 byte), n halfword (2 byte), dati |
| 0x02 | READ_MEM | 0x02, indirizzo, n, dati letti |

Registri: `0x01` CONTROL (bit1 start), `0x02` STATUS (bit1 DDR3
calibrata, bit2 errore, bit3 busy, bit4 done sticky), `0x04`
NETWORK_BASE (indirizzo dell'header in parole da 32 bit, multiplo di 4).

**Limite noto del bridge v3**: con SCLK veloce un READ_MEM di più
halfword garantisce solo la prima (scoperto con il MIG reale, V4-B3).
Via SPI di gestione si legge una halfword per transazione; i dati in
blocco passano dalla Quad-SPI.

### 5.2 Porta dati Quad-SPI (nuova in v4)

SPI mode 0, half duplex, comando, indirizzo e dati tutti su 4 linee
(ESP-IDF: `SPI_TRANS_MODE_QIO | SPI_TRANS_MULTILINE_CMD |
SPI_TRANS_MULTILINE_ADDR`), 80 MHz su SPI2 IO_MUX.

| Campo | Contenuto |
|---|---|
| comando (8 bit) | `0x1A` scrittura, `0x2A` lettura |
| indirizzo (48 bit) | [47:16] W iniziale, [15:0] numero di parole da 16 byte |
| dummy | 64 clock, solo in lettura |
| dati | 16 × len byte, nibble alto per primo |

In lettura l'FPGA lancia ogni nibble sul fronte di salita precedente a
quello in cui l'ESP32 lo campiona (un periodo intero di tempo di uscita,
dai flip-flop nei pad): nel driver `input_delay_ns = 0`. QCS_N alto
resetta il front end.

## 6. Firmware ESP32

`firmware/esp32/components/fpga_neural/`: `fpga_neural_v4.h/.c`, sopra
il driver SPI v3 (`fpga_neural.h`, variante `FPGA_NEURAL_VARIANT_CHAINED`).
Il codice è stato solo compilato con stub, non ancora provato su un
ESP32 vero.

### 6.1 Inizializzazione

```c
fpga_neural_handle_t h;          // SPI di gestione (driver v3)
fpga_v4_qspi_handle_t q;
fpga_v4_qspi_config_t qc = {
    .spi_host = SPI2_HOST, .pin_sclk = 12, .pin_cs = 10,
    .pin_io0 = 11, .pin_io1 = 13, .pin_io2 = 14, .pin_io3 = 9,
    .clock_speed_hz = 80 * 1000 * 1000,
};
fpga_v4_qspi_init(&qc, &q);
fpga_v4_load_blob(h, 0, blob, blob_len);     // una volta: header, descrittori, parametri
```

### 6.2 Una inferenza

```c
fpga_v4_layout_t lay = { .hdr_w = 16, .img_w = 256, .result_w = 80000 };
int8_t emb[FPGA_V4_EMBEDDING]; fpga_v4_stats_t st;
fpga_v4_infer_fast(h, q, &lay, image, emb, &st, 100);
```

### 6.3 Pipeline (due buffer)

Due layout A/B, ognuno con il suo header, immagine e risultato:
`fpga_v4_stage_image(q, &B, next)` mentre A calcola, poi
`fpga_v4_finish(h, q, &A, ...)` e `fpga_v4_start(h, &B)`.

## 7. Ricostruire e verificare

Strumenti: OSS CAD Suite (Icarus) e Vivado 2026.1 (vedi `CLAUDE.md` per
i percorsi e `LD_LIBRARY_PATH`). Tutto da `hardware/v4`.

| Cosa | Comando | Durata |
|---|---|---|
| modello C + regressione Icarus (unit, core, scheda) | `sim/run_icarus.sh /tmp/v4sim` | ~1 h |
| progetto Vivado della scheda | `vivado -mode batch -source vivado/create_v4_board.tcl -tclargs <proj> <mig_ip_v3> <mfn_dir> <mig_example_sim>` | minuti |
| simulazione con MIG reale + DDR3 Micron | `vivado -mode batch -source vivado/run_board_xsim.tcl -tclargs 40 <proj> <mfn_dir>` | ~3 h |
| sintesi, P&R, bitstream | `vivado -mode batch -source vivado/impl_v4_board.tcl -tclargs <proj> <report_dir> <file.bit>` | 3-12 h (1 thread) |
| P&R del solo core | `constr/pr_core.tcl` | ~2 h |

Per il clock a 189,20 MHz: `CLKOUT0_DIVIDE_F(7.375)` in
`rtl/v4_board_top.v`.

### 7.1 Matrice di verifica

| Livello | Banco | Esito |
|---|---|---|
| unità | tb_requant_act, tb_pw_array_packed, tb_dw_linebuf_*, tb_dwpw_engine, tb_im2col_feeder, tb_async_fifo, tb_v4_ddr_stream, tb_qspi_data_port | tutti passano, con mutazioni che vengono rilevate |
| core, rete intera | tb_v4_core_mfn (37 passate confrontate, 132.704 parole) | 0 errori, 463.971 cicli |
| scheda, Icarus | tb_v4_board_top (immagine via QSPI, start via SPI, embedding) | bit-exact, 460.683 cicli, start→done 2,337 ms |
| scheda, MIG reale | tb_v4_board_xsim (MIG + 2 modelli Micron, calibrazione reale, DDR3 precaricata) | **embedding bit-exact**, 460.592 cicli, start→done 2,342 ms (V4-B9) |
| timing | P&R della scheda intera | 199,34 MHz WNS +0,003 ns; 189,20 MHz WNS +0,033 ns |

### 7.2 Storia del timing della scheda

| Run | Cambiamento | WNS core @199 MHz | QSPI |
|---|---|---|---|
| 1 | prima scheda completa | -0,777 ns | -6,060 ns |
| 2 | QSPI sul fronte di salita dai pad, porta host e reset registrati, flusso del core | -1,485 ns | +1,064 ns |
| 3 | descrittori in LUTRAM (ignorato), limiti di fanout | placement fallito | – |
| 4 | tabella descrittori con un solo indirizzo di lettura registrato | -0,235 ns (+0,033 a 189 MHz) | +1,163 ns |
| 5 | im2col `rows_ready`, lettura descrittore, FIFO DDR→core registrati | **+0,003 ns** | +0,830 ns |

## 8. Limiti e punti aperti

1. **Margine a 199 MHz quasi nullo** (+0,003 ns): il timing è rispettato
   nel caso peggiore del modello Vivado, ma su una scheda nuova conviene
   avere pronta la versione a 189 MHz (tag `v4-board-189`).
2. **Il chip è pieno**: 98 % delle BRAM, 79 % delle LUT. Ogni aggiunta
   costa timing; una nuova funzione probabilmente richiede di togliere
   qualcos'altro.
3. **La Quad-SPI a 80 MHz non è provata su un ESP32 vero**: i vincoli
   assumono 0–2 ns di ritardo tra ESP32 e scheda. Se sulla scheda non
   funziona, prima si abbassa il clock a 40 MHz nel driver.
4. **Bank 0 a 3,3 V** (`CFGBVS = VCCO`): se la scheda usa un'altra
   tensione per il bank 0 va cambiato lo XDC e rigenerato il bitstream.
5. **Firmware solo compilato**, non eseguito su hardware.
6. **Start→done a 189 MHz non simulato**; il tempo di calcolo lo è.
7. La configurazione dalla flash (boot autonomo) è quella di v3, non
   toccata dalla v4: vedi `docs/PHYSICAL_REALIZATION.md` §2.3 e §5.
