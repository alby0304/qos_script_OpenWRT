#!/bin/sh
#
# Script di Qualità del Servizio per OpenWrt
# Basato sulle linee guida ufficiali HFSC di Kenjiro Cho (IIJ Lab)
# 
# Versione: 1.0
# Autore: Alberto Bettini
# Data: 2024
#
# Questo script implementa un sistema di QoS usando HFSC (Hierarchical Fair Service Curve)
# seguendo le best practices documentate in ALTQ Tips (https://www.iijlab.net/~kjc/software/TIPS.txt)
#

set -e  # Esci in caso di errore

# ============================================
# SEZIONE 1: VARIABILI DI CONFIGURAZIONE
# ============================================

# File di configurazione esterno (opzionale)
CONFIG_FILE="/root/etc/qos.conf"

# Carica configurazione esterna se esiste
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# --- Configurazione di Rete ---
# Banda totale disponibile (kbit/s)
# Nota: Impostare al 95% della banda reale per evitare bufferbloat
BANDA_UPLOAD=${BANDA_UPLOAD:-1000}     # Upload totale
BANDA_DOWNLOAD=${BANDA_DOWNLOAD:-10000} # Download totale (per ingress shaping)

# Interfacce di rete
IFACE_WAN=${IFACE_WAN:-$(uci get network.wan.ifname 2>/dev/null || echo "eth0")}
IFACE_LAN=${IFACE_LAN:-$(uci get network.lan.ifname 2>/dev/null || echo "br-lan")}

# --- Configurazione Utenti ---
# Indirizzi IP o sottoreti
RETE_PRIORITA_ALTA=${RETE_PRIORITA_ALTA:-"192.168.99.3/32"}
RETE_PRIORITA_MEDIA=${RETE_PRIORITA_MEDIA:-"192.168.99.4/32"}
RETE_PRIORITA_BASSA=${RETE_PRIORITA_BASSA:-"192.168.99.5/32"}

# Allocazione percentuale banda garantita
PCT_ALTA=${PCT_ALTA:-50}      # 50% banda garantita
PCT_MEDIA=${PCT_MEDIA:-25}    # 25% banda garantita
PCT_BASSA=${PCT_BASSA:-12}    # 12% banda garantita
PCT_DEFAULT=${PCT_DEFAULT:-13} # Resto per traffico non classificato

# --- Configurazione Servizi Critici ---
# Traffico interattivo (SSH, DNS, etc.)
BANDA_INTERATTIVO=${BANDA_INTERATTIVO:-$((BANDA_UPLOAD / 10))}  # 10% per traffico interattivo
LATENZA_INTERATTIVO=${LATENZA_INTERATTIVO:-5}                   # 5ms latenza massima

# VoIP/Videoconferenza
BANDA_VOIP=${BANDA_VOIP:-$((BANDA_UPLOAD / 5))}  # 20% per VoIP
LATENZA_VOIP=${LATENZA_VOIP:-10}                  # 10ms latenza massima

# --- Percorsi Comandi ---
TC=${TC:-"/sbin/tc"}
IPT=${IPT:-"/usr/sbin/iptables"}
IP=${IP:-"/sbin/ip"}
MODPROBE=${MODPROBE:-"/sbin/modprobe"}

# --- Opzioni di Debug e Logging ---
DEBUG=${DEBUG:-0}
LOG_FILE=${LOG_FILE:-"/var/log/qos.log"}
VERBOSE=${VERBOSE:-1}

# ============================================
# SEZIONE 2: FUNZIONI DI UTILITÀ
# ============================================

# Inizializza logging
init_logging() {
    if [ "$VERBOSE" -eq 1 ]; then
        exec 2>&1 | tee -a "$LOG_FILE"
        echo "=== QoS Script Avviato: $(date) ===" >> "$LOG_FILE"
    fi
}


# Funzioni di output con colori ANSI
log_info() {
    [ "$VERBOSE" -eq 1 ] && echo -e "[INFO] $*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >> "$LOG_FILE"
}

log_success() {
    [ "$VERBOSE" -eq 1 ] && echo -e "[OK] $*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] OK: $*" >> "$LOG_FILE"
}

log_error() {
    echo -e "\033[1;31m[ERRORE]\033[0m $*" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRORE: $*" >> "$LOG_FILE"
}

log_warning() {
    [ "$VERBOSE" -eq 1 ] && echo -e "\033[1;33m[AVVISO]\033[0m $*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AVVISO: $*" >> "$LOG_FILE"
}

log_debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo -e "[DEBUG] $*"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >> "$LOG_FILE"
    fi
}

# Esegui comando con logging
run_cmd() {
    local cmd="$1"
    shift
    log_debug "Esecuzione: $cmd $*"
    if ! $cmd "$@" 2>/dev/null; then
        log_error "Comando fallito: $cmd $*"
        return 1
    fi
    return 0
}

# Verifica prerequisiti
check_prerequisites() {
    log_info "Verifica prerequisiti sistema..."
    
    local missing_tools=""
    
    # Verifica strumenti necessari
    for tool in tc iptables ip; do
        if ! command -v $tool >/dev/null 2>&1; then
            missing_tools="$missing_tools $tool"
        fi
    done
    
    if [ -n "$missing_tools" ]; then
        log_error "Strumenti mancanti: $missing_tools"
        log_info "Installare con: opkg install $missing_tools"
        return 1
    fi
    
    # Verifica e carica moduli kernel
    local modules="sch_hfsc sch_sfq cls_fw xt_mark"
    for mod in $modules; do
        if ! lsmod | grep -q "^$mod "; then
            log_debug "Caricamento modulo: $mod"
            $MODPROBE $mod 2>/dev/null || log_warning "Impossibile caricare modulo $mod"
        fi
    done
    
    # Verifica interfacce
    for iface in $IFACE_WAN $IFACE_LAN; do
        if ! $IP link show "$iface" >/dev/null 2>&1; then
            log_error "Interfaccia $iface non trovata"
            return 1
        fi
    done
    
    log_success "Prerequisiti verificati"
    return 0
}

# Calcola dimensione buffer ottimale (BDP - Bandwidth Delay Product)
calculate_buffer_size() { 
    local bandwidth=$1  # in kbit/s
    local rtt=${2:-50}  # RTT in ms (default 50ms)
    
    # BDP = bandwidth * RTT / 8 (converti in bytes)
    local bdp=$((bandwidth * rtt / 8))
    
    # Buffer = 1.5 * BDP (raccomandato)
    local buffer=$((bdp * 3 / 2))
    
    # Limiti min/max
    [ $buffer -lt 4096 ] && buffer=4096
    [ $buffer -gt 131072 ] && buffer=131072
    
    echo $buffer
}

# ============================================
# SEZIONE 3: GESTIONE CONFIGURAZIONE
# ============================================

# Salva configurazione corrente
save_config() {
    local backup_dir="/etc/qos-backup"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    mkdir -p "$backup_dir"
    
    log_info "Salvataggio configurazione in $backup_dir/qos_$timestamp.tar.gz"
    
    {
        echo "# QoS Configuration Backup - $timestamp"
        echo "# Interfaccia: $IFACE_WAN"
        $TC qdisc show dev $IFACE_WAN
        $TC class show dev $IFACE_WAN
        $TC filter show dev $IFACE_WAN
        $IPT -t mangle -L -n -v
    } | gzip > "$backup_dir/qos_$timestamp.tar.gz"
    
    # Mantieni solo ultimi 10 backup
    ls -t "$backup_dir"/qos_*.tar.gz | tail -n +11 | xargs -r rm
    
    log_success "Configurazione salvata"
}

# Pulisci tutte le configurazioni QoS
clean_all() {
    log_info "Rimozione configurazioni QoS esistenti..."
    
    # Rimuovi qdisc (questo rimuove anche classi e filtri)
    for iface in $IFACE_WAN $IFACE_LAN; do
        $TC qdisc del dev $iface root 2>/dev/null || true
        $TC qdisc del dev $iface ingress 2>/dev/null || true
    done
    
    # Pulisci tabelle iptables mangle
    $IPT -t mangle -F 2>/dev/null || true
    $IPT -t mangle -X QOS_MARK 2>/dev/null || true
    
    log_success "Configurazioni rimosse"
}

# ============================================
# SEZIONE 4: CONFIGURAZIONE HFSC
# ============================================

# Configura qdisc radice HFSC
setup_root_qdisc() {
    local iface=$1
    local bandwidth=$2
    
    log_info "Configurazione qdisc HFSC su $iface (banda: ${bandwidth}kbit)"
    
    # Crea qdisc radice
    # default 999 = traffico non classificato va alla classe 1:999
    run_cmd $TC qdisc add dev $iface root handle 1: hfsc default 999
    
    # Classe radice - rappresenta tutta la banda
    # Nota: HFSC usa 'sc' (service curve) non 'ul' nella classe radice
    run_cmd $TC class add dev $iface parent 1: classid 1:1 hfsc \
        sc rate ${bandwidth}kbit
    
    log_success "Qdisc radice configurata"
}

# Configura classe HFSC con curve ottimizzate
setup_hfsc_class() {
    local iface=$1
    local parent=$2
    local classid=$3
    local bandwidth=$4
    local priority=$5
    local description=$6
    
    log_debug "Creazione classe $classid: $description (${bandwidth}kbit, priorità $priority)"
    
    case $priority in
        "realtime")
            # Classe real-time: garantisce bassa latenza e banda
            # Curva concava: burst iniziale poi stabilizzazione
            local burst=$((bandwidth * 2))  # Burst iniziale doppio
            local latency=10                # 10ms latenza target
            
            run_cmd $TC class add dev $iface parent $parent classid $classid hfsc \
                rt m1 ${burst}kbit d ${latency}ms m2 ${bandwidth}kbit \
                ls rate ${bandwidth}kbit
            ;;
            
        "interactive")
            # Classe interattiva: priorità alta ma non real-time strict
            local burst=$((bandwidth * 150 / 100))  # Burst 150%
            local latency=20                        # 20ms latenza
            
            run_cmd $TC class add dev $iface parent $parent classid $classid hfsc \
                rt m1 ${burst}kbit d ${latency}ms m2 ${bandwidth}kbit \
                ls rate ${bandwidth}kbit
            ;;
            
        "normal")
            # Classe normale: solo link-sharing
            run_cmd $TC class add dev $iface parent $parent classid $classid hfsc \
                ls rate ${bandwidth}kbit
            ;;
            
        "bulk")
            # Classe bulk: può prendere in prestito banda ma con priorità bassa
            run_cmd $TC class add dev $iface parent $parent classid $classid hfsc \
                ls rate ${bandwidth}kbit
            ;;
            
        *)
            log_error "Priorità sconosciuta: $priority"
            return 1
            ;;
    esac
    
    # Aggiungi SFQ (Stochastic Fair Queuing) alla classe foglia per fairness
    #run_cmd $TC qdisc add dev $iface parent $classid handle ${classid##*:}: sfq perturb 10
    
    return 0
}

# Configura tutte le classi utente
setup_user_classes() {
    local iface=$1
    local total_bw=$2
    
    log_info "Configurazione classi utente..."
    
    # Calcola banda per ogni classe
    local bw_alta=$((total_bw * PCT_ALTA / 100))
    local bw_media=$((total_bw * PCT_MEDIA / 100))
    local bw_bassa=$((total_bw * PCT_BASSA / 100))
    local bw_default=$((total_bw * PCT_DEFAULT / 100))
    
    # Classe 1:10 - Traffico Interattivo (SSH, DNS, ICMP)
    setup_hfsc_class $iface "1:1" "1:10" $BANDA_INTERATTIVO "realtime" \
        "Traffico Interattivo"
    
    # Classe 1:20 - VoIP/Video
    setup_hfsc_class $iface "1:1" "1:20" $BANDA_VOIP "realtime" \
        "VoIP/Videoconferenza"
    
    # Classe 1:100 - Utente Alta Priorità
    setup_hfsc_class $iface "1:1" "1:100" $bw_alta "interactive" \
        "Utente Alta Priorità"
    
    # Classe 1:200 - Utente Media Priorità
    setup_hfsc_class $iface "1:1" "1:200" $bw_media "normal" \
        "Utente Media Priorità"
    
    # Classe 1:300 - Utente Bassa Priorità
    setup_hfsc_class $iface "1:1" "1:300" $bw_bassa "bulk" \
        "Utente Bassa Priorità"
    
    # Classe 1:999 - Default (non classificato)
    setup_hfsc_class $iface "1:1" "1:999" $bw_default "bulk" \
        "Traffico Default"
    
    log_success "Classi utente configurate"
}

# ============================================
# SEZIONE 5: MARCATURA PACCHETTI
# ============================================

# Configura marcatura con iptables
setup_packet_marking() {
    log_info "Configurazione marcatura pacchetti..."
    
    # Crea catena custom per QoS
    $IPT -t mangle -N QOS_MARK 2>/dev/null || true
    $IPT -t mangle -F QOS_MARK
    
    # Aggancia la catena a POSTROUTING
    $IPT -t mangle -D POSTROUTING -o $IFACE_WAN -j QOS_MARK 2>/dev/null || true
    $IPT -t mangle -A POSTROUTING -o $IFACE_WAN -j QOS_MARK
    
    # --- MARCA 10: Traffico Interattivo ---
    # SSH
    $IPT -t mangle -A QOS_MARK -p tcp --dport 22 -j MARK --set-mark 10
    $IPT -t mangle -A QOS_MARK -p tcp --sport 22 -j MARK --set-mark 10
    
    # DNS
    $IPT -t mangle -A QOS_MARK -p udp --dport 53 -j MARK --set-mark 10
    $IPT -t mangle -A QOS_MARK -p tcp --dport 53 -j MARK --set-mark 10
    
    # ICMP (ping)
    $IPT -t mangle -A QOS_MARK -p icmp -j MARK --set-mark 10
    
    # NTP
    $IPT -t mangle -A QOS_MARK -p udp --dport 123 -j MARK --set-mark 10
    
    # --- MARCA 20: VoIP/Video ---
    # SIP
    $IPT -t mangle -A QOS_MARK -p udp --dport 5060:5061 -j MARK --set-mark 20
    # RTP
    $IPT -t mangle -A QOS_MARK -p udp --dport 10000:20000 -j MARK --set-mark 20
    # Teams/Zoom/WebRTC
    $IPT -t mangle -A QOS_MARK -p udp --dport 3478:3481 -j MARK --set-mark 20
    
    # --- MARCA 100: Utente Alta Priorità ---
    for net in $(echo $RETE_PRIORITA_ALTA | tr ',' ' '); do
        $IPT -t mangle -A QOS_MARK -s $net -j MARK --set-mark 100
        $IPT -t mangle -A QOS_MARK -d $net -j MARK --set-mark 100
    done
    
    # --- MARCA 200: Utente Media Priorità ---
    for net in $(echo $RETE_PRIORITA_MEDIA | tr ',' ' '); do
        $IPT -t mangle -A QOS_MARK -s $net -j MARK --set-mark 200
        $IPT -t mangle -A QOS_MARK -d $net -j MARK --set-mark 200
    done
    
    # --- MARCA 300: Utente Bassa Priorità ---
    for net in $(echo $RETE_PRIORITA_BASSA | tr ',' ' '); do
        $IPT -t mangle -A QOS_MARK -s $net -j MARK --set-mark 300
        $IPT -t mangle -A QOS_MARK -d $net -j MARK --set-mark 300
    done
    
    # Contatori per debug
    if [ "$DEBUG" -eq 1 ]; then
        $IPT -t mangle -A QOS_MARK -j LOG --log-prefix "QOS-MARK: " --log-level debug
    fi
    
    log_success "Marcatura pacchetti configurata"
}

# ============================================
# SEZIONE 6: FILTRI TC
# ============================================

# Configura filtri per classificazione
setup_tc_filters() {
    local iface=$1
    
    log_info "Configurazione filtri TC..."
    
    # Filtri basati su fw mark (priorità più bassa = precedenza maggiore)
    
    # Priorità 1: Traffico interattivo
    run_cmd $TC filter add dev $iface parent 1: protocol ip prio 1 \
        handle 10 fw classid 1:10
    
    # Priorità 2: VoIP/Video
    run_cmd $TC filter add dev $iface parent 1: protocol ip prio 2 \
        handle 20 fw classid 1:20
    
    # Priorità 3: Utente alta priorità
    run_cmd $TC filter add dev $iface parent 1: protocol ip prio 3 \
        handle 100 fw classid 1:100
    
    # Priorità 4: Utente media priorità
    run_cmd $TC filter add dev $iface parent 1: protocol ip prio 4 \
        handle 200 fw classid 1:200
    
    # Priorità 5: Utente bassa priorità
    run_cmd $TC filter add dev $iface parent 1: protocol ip prio 5 \
        handle 300 fw classid 1:300
    
    log_success "Filtri TC configurati"
}

# ============================================
# SEZIONE 7: MONITORAGGIO E STATISTICHE
# ============================================

# Mostra statistiche dettagliate
show_statistics() {
    local iface=${1:-$IFACE_WAN}
    
    echo ""
    echo "============================================"
    echo "   STATISTICHE QOS - $(date)"
    echo "============================================"
    echo ""
    
    echo "--- CONFIGURAZIONE ATTUALE ---"
    echo "Interfaccia: $iface"
    echo "Banda Upload: ${BANDA_UPLOAD}kbit"
    echo "Banda Download: ${BANDA_DOWNLOAD}kbit"
    echo ""
    
    echo "--- CLASSI HFSC ---"
    $TC -s class show dev $iface | while read line; do
        case "$line" in
            *"class hfsc 1:10"*) echo "[INTERATTIVO] $line" ;;
            *"class hfsc 1:20"*) echo "[VOIP]        $line" ;;
            *"class hfsc 1:100"*) echo "[ALTA PRIO]   $line" ;;
            *"class hfsc 1:200"*) echo "[MEDIA PRIO]  $line" ;;
            *"class hfsc 1:300"*) echo "[BASSA PRIO]  $line" ;;
            *"class hfsc 1:999"*) echo "[DEFAULT]     $line" ;;
            *"Sent"*) echo "              $line" ;;
        esac
    done
    echo ""
    
    echo "--- FILTRI ATTIVI ---"
    $TC filter show dev $iface | head -20
    echo ""
    
    echo "--- MARCATURE IPTABLES ---"
    $IPT -t mangle -L QOS_MARK -n -v 2>/dev/null | tail -n +3
    echo ""
}

# Monitoraggio real-time
monitor_realtime() {
    local iface=${1:-$IFACE_WAN}
    local interval=${2:-2}

    log_info "Monitoraggio in tempo reale (Ctrl+C per uscire)"

    while :; do
        clear
        

        echo "=== MONITOR QOS REAL-TIME - $(date) ==="
        echo
        echo "Classe          Pacchetti   Bytes        Rate         Dropped"
        echo "----------------------------------------------------------------"

        # Estrai e formatta statistiche in modo robusto
        # - legge la riga "class hfsc ..." (classid è il 3° campo, es. 1:10)
        # - legge la riga successiva con "Sent ... (dropped ...)" e "rate ..."
        # - cerca i token per nome per evitare dipendere dalle posizioni
        $TC -s class show dev "$iface" | awk '
            /class[[:space:]]+hfsc/ {
                cid = $3
                name = "UNKNOWN"
                if (cid=="1:10")   name="INTERATTIVO"
                else if (cid=="1:20")  name="VOIP"
                else if (cid=="1:100") name="ALTA_PRIO"
                else if (cid=="1:200") name="MEDIA_PRIO"
                else if (cid=="1:300") name="BASSA_PRIO"
                else if (cid=="1:999") name="DEFAULT"

                # leggi la riga successiva con le stats
                if (getline > 0) {
                    pkt="-"; bytes="-"; dropped="-"; rate="-"
                    # scorri i campi cercando le etichette
                    for (i=1; i<=NF; i++) {
                        if ($i=="Sent") {
                            # Formato tipico: Sent <bytes> bytes <pkts> pkt ...
                            if ((i+1)<=NF) bytes=$(i+1)
                            if ((i+3)<=NF) pkt=$(i+3)
                            gsub(/[,()]/,"",bytes); gsub(/[,()]/,"",pkt)
                        }
                        if ($i=="dropped") {
                            if ((i+1)<=NF) { dropped=$(i+1); gsub(/[,()]/,"",dropped) }
                        }
                        if ($i=="rate") {
                            if ((i+2)<=NF) rate=$(i+1)" "$(i+2)   # es. "100Kbit" "rate"
                        }
                    }
                    printf "%-15s %-10s %-12s %-12s %s\n", name, pkt, bytes, rate, dropped
                }
            }
        '

        echo
        echo "Premi Ctrl+C per terminare"
        sleep "$interval"
    done
}

# Test della configurazione
test_configuration() {
    log_info "Test della configurazione QoS..."
    
    local errors=0
    
    # Test 1: Verifica qdisc
    echo -n "Test qdisc HFSC... "
    if $TC qdisc show dev $IFACE_WAN | grep -q "qdisc hfsc 1:"; then
        echo "OK"
    else
        echo "FALLITO"
        ((errors++))
    fi
    
    # Test 2: Verifica classi
    echo -n "Test classi... "
    local num_classes=$($TC class show dev $IFACE_WAN | grep -c "class hfsc")
    if [ "$num_classes" -ge 6 ]; then
        echo "OK ($num_classes classi)"
    else
        echo "FALLITO (solo $num_classes classi)"
        ((errors++))
    fi
    
    # Test 3: Verifica filtri
    echo -n "Test filtri... "
    local num_filters=$($TC filter show dev $IFACE_WAN | grep -c "handle")
    if [ "$num_filters" -ge 5 ]; then
        echo "OK ($num_filters filtri)"
    else
        echo "FALLITO (solo $num_filters filtri)"
        ((errors++))
    fi
    
    # Test 4: Verifica iptables
    echo -n "Test marcature iptables... "
    if $IPT -t mangle -L QOS_MARK -n 2>/dev/null | grep -q "MARK"; then
        echo "OK"
    else
        echo "FALLITO"
        ((errors++))
    fi
    
    # Test 5: Test ping con marcatura
    echo -n "Test marcatura ICMP... "
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        local icmp_marks=$($IPT -t mangle -L QOS_MARK -n -v | grep "icmp" | awk '{print $1}')
        if [ -n "$icmp_marks" ] && [ "$icmp_marks" != "0" ]; then
            echo "OK ($icmp_marks pacchetti marcati)"
        else
            echo "AVVISO (nessun pacchetto ICMP marcato)"
        fi
    else
        echo "SKIP (no connettività)"
    fi
    
    echo ""
    if [ $errors -eq 0 ]; then
        log_success "Tutti i test superati!"
        return 0
    else
        log_error "$errors test falliti"
        return 1
    fi
}

# ============================================
# SEZIONE 8: FUNZIONI PRINCIPALI
# ============================================

# Avvia QoS
start_qos() {
    log_info "Avvio configurazione QoS..."
    
    # Salva configurazione attuale (se esiste)
    save_config 2>/dev/null || true
    
    # Pulisci configurazioni esistenti
    clean_all
    
    # Configura HFSC su interfaccia WAN
    setup_root_qdisc $IFACE_WAN $BANDA_UPLOAD
    setup_user_classes $IFACE_WAN $BANDA_UPLOAD
    
    # Configura marcatura e filtri
    setup_packet_marking
    setup_tc_filters $IFACE_WAN
    
    # Test configurazione
    if test_configuration; then
        log_success "QoS avviato con successo"
        
        # Mostra statistiche iniziali
        show_statistics $IFACE_WAN
        
        # Salva PID per gestione servizio
        echo $$ > /var/run/qos.pid
        
        return 0
    else
        log_error "Configurazione QoS non riuscita"
        return 1
    fi
}

# Ferma QoS
stop_qos() {
    log_info "Arresto QoS..."
    
    clean_all
    
    rm -f /var/run/qos.pid
    
    log_success "QoS arrestato"
}

# Ricarica configurazione
reload_qos() {
    log_info "Ricaricamento configurazione QoS..."
    
    stop_qos
    sleep 1
    start_qos
}

# ============================================
# SEZIONE 9: GESTIONE ARGOMENTI
# ============================================

show_usage() {
    cat << EOF
Uso: $0 [COMANDO] [OPZIONI]

COMANDI:
    start           Avvia QoS
    stop            Arresta QoS
    restart         Riavvia QoS
    reload          Ricarica configurazione
    status          Mostra stato e statistiche
    monitor [SEC]   Monitoraggio real-time (default: 2 sec)
    test            Testa configurazione
    save            Salva configurazione attuale
    help            Mostra questo messaggio

OPZIONI:
    -d, --debug     Abilita modalità debug
    -v, --verbose   Output dettagliato
    -q, --quiet     Output minimo
    -c, --config    File configurazione alternativo

ESEMPI:
    $0 start                    # Avvia QoS
    $0 monitor 1                # Monitor ogni secondo
    $0 -d start                 # Avvia con debug
    $0 -c /etc/myqos.conf start # Usa config alternativa

CONFIGURAZIONE:
    Il file di configurazione di default è: $CONFIG_FILE
    
    Variabili principali:
    - BANDA_UPLOAD: Banda upload totale (kbit/s)
    - BANDA_DOWNLOAD: Banda download totale (kbit/s)
    - PCT_ALTA/MEDIA/BASSA: Percentuali allocazione banda

FILE:
    Log: $LOG_FILE
    PID: /var/run/qos.pid
    Backup: /etc/qos-backup/

Per maggiori informazioni: https://github.com/tuouser/qos-openwrt

EOF
}

# ============================================
# SEZIONE 10: MAIN
# ============================================

main() {
    # Parsing opzioni
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--debug)
                DEBUG=1
                VERBOSE=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -q|--quiet)
                VERBOSE=0
                shift
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help|help)
                show_usage
                exit 0
                ;;
            -*)
                log_error "Opzione sconosciuta: $1"
                show_usage
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Comando principale
    COMMAND="${1:-status}"
    shift
    
    # Inizializza logging
    init_logging
    
    # Verifica privilegi root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Questo script richiede privilegi di root"
        exit 1
    fi
    
    # Verifica prerequisiti (per tutti tranne help e status)
    case "$COMMAND" in
        start|restart|reload)
            check_prerequisites || exit 1
            ;;
    esac
    
    # Esegui comando
    case "$COMMAND" in
        start)
            start_qos
            ;;
        stop)
            stop_qos
            ;;
        restart)
            stop_qos
            sleep 2
            start_qos
            ;;
        reload)
            reload_qos
            ;;
        status)
            show_statistics "$@"
            ;;
        monitor)
            monitor_realtime "$IFACE_WAN" "${1:-2}"
            ;;
        test)
            test_configuration
            ;;
        save)
            save_config
            ;;
        *)
            log_error "Comando sconosciuto: $COMMAND"
            show_usage
            exit 1
            ;;
    esac
    
    exit $?
}

# Esecuzione
main "$@"
