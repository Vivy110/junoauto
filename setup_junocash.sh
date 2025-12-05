#!/bin/bash

#############################################
# Juno Cash Interactive Setup & Manager
# Untuk Docker Container atau Fresh Linux
#############################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/root/junocash"
MINING_THREADS=$(nproc)
BUILD_THREADS=$(nproc)
RANDOMX_MODE="fast"  # Options: fast, light, auto

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "Please run as root or use sudo"
        exit 1
    fi
}

# Clear screen and show header
show_header() {
    clear
    echo -e "${CYAN}=============================================="
    echo "     🚀 JUNO CASH MINING MANAGER 🚀"
    echo -e "==============================================${NC}"
    echo ""
}

# Check if Juno Cash is installed
check_installation() {
    if [ -f "$INSTALL_DIR/src/junocashd" ] && [ -f "$INSTALL_DIR/src/junocash-cli" ]; then
        return 0
    else
        return 1
    fi
}

# Check if daemon is running
check_daemon() {
    if [ -f "$INSTALL_DIR/src/junocash-cli" ]; then
        cd "$INSTALL_DIR"
        if ./src/junocash-cli getinfo &>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Install Juno Cash
install_junocash() {
    show_header
    log_info "Starting Juno Cash installation..."
    echo ""
    
    # Check root
    check_root
    
    # Step 1: Update and install dependencies
    log_info "Step 1/7: Installing dependencies..."
    apt-get update -qq
    apt-get upgrade -y -qq
    
    apt-get install -y -qq \
        build-essential \
        pkg-config \
        autoconf \
        automake \
        libtool \
        curl \
        git \
        python3 \
        bison \
        cmake \
        libssl-dev \
        libboost-all-dev \
        libevent-dev \
        libsodium-dev \
        wget \
        ca-certificates \
        jq
    
    log_success "Dependencies installed"
    
    # Step 2: Clone repository
    log_info "Step 2/7: Cloning repository..."
    cd /root
    if [ -d "$INSTALL_DIR" ]; then
        log_warning "Removing old installation..."
        rm -rf "$INSTALL_DIR"
    fi
    
    git clone https://github.com/juno-cash/junocash.git
    cd junocash
    log_success "Repository cloned"
    
    # Step 3: Build
    log_info "Step 3/7: Building Juno Cash..."
    log_warning "This will take 30-120 minutes. Please be patient!"
    echo ""
    
    ./zcutil/build.sh -j${BUILD_THREADS} 2>&1 | tee build.log
    
    if [ ! -f "./src/junocashd" ]; then
        log_error "Build failed! Check build.log"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log_success "Build completed"
    
    # Step 4: Create config
    log_info "Step 4/7: Creating configuration..."
    mkdir -p ~/.junocash
    
    cat > ~/.junocash/junocash.conf << EOF
# Juno Cash Configuration
listen=1
server=1
maxconnections=50
rpcuser=junocash
rpcpassword=$(openssl rand -hex 32)
rpcallowip=127.0.0.1
gen=0
dbcache=512
par=4
debug=0
printtoconsole=0

# RandomX Mining Settings
randomx-mode=$RANDOMX_MODE
randomx-cache-size=2048
EOF
    
    log_success "Configuration created"
    
    # Step 5: Start daemon
    log_info "Step 5/7: Starting daemon..."
    cd "$INSTALL_DIR"
    ./src/junocashd -daemon
    
    log_info "Waiting for daemon to initialize (30 seconds)..."
    sleep 30
    
    # Wait for RPC
    for i in {1..30}; do
        if ./src/junocash-cli getinfo &>/dev/null; then
            break
        fi
        sleep 2
    done
    
    if ! ./src/junocash-cli getinfo &>/dev/null; then
        log_error "Daemon failed to start"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log_success "Daemon started"
    
    # Step 6: Create wallet
    log_info "Step 6/7: Creating wallet..."
    
    ./src/junocash-cli z_getnewaccount > /dev/null 2>&1
    MINING_ADDRESS=$(./src/junocash-cli z_getaddressforaccount 0 2>&1)
    
    if [ -z "$MINING_ADDRESS" ] || [[ "$MINING_ADDRESS" == *"error"* ]]; then
        log_error "Failed to create wallet"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    echo "$MINING_ADDRESS" > ~/.junocash/mining_address.txt
    log_success "Wallet created"
    
    # Step 7: Export seed phrase
    log_info "Step 7/7: Exporting seed phrase..."
    SEED=$(./src/junocash-cli z_exportwallet "/tmp/wallet_backup.txt" 2>&1)
    
    if [ -f "/tmp/wallet_backup.txt" ]; then
        # Extract mnemonic from wallet backup
        grep -A 1 "# Mnemonic" /tmp/wallet_backup.txt | tail -1 > ~/.junocash/seed_phrase.txt 2>/dev/null || \
        ./src/junocash-cli dumpwallet "/tmp/wallet_dump.txt" 2>/dev/null
        
        # If no mnemonic found, save HD seed
        if [ ! -s ~/.junocash/seed_phrase.txt ]; then
            ./src/junocash-cli z_exportviewingkey "$MINING_ADDRESS" > ~/.junocash/viewing_key.txt 2>/dev/null
            echo "Wallet backup saved to /tmp/wallet_backup.txt" > ~/.junocash/seed_phrase.txt
        fi
        
        chmod 600 ~/.junocash/seed_phrase.txt
        log_success "Seed phrase exported"
    fi
    
    echo ""
    log_success "Installation completed!"
    echo ""
    log_info "Your mining address:"
    echo -e "${GREEN}$MINING_ADDRESS${NC}"
    echo ""
    log_warning "IMPORTANT: Backup your seed phrase from ~/.junocash/seed_phrase.txt"
    echo ""
    
    read -p "Press Enter to continue..."
}

# Start mining
start_mining() {
    show_header
    
    if ! check_daemon; then
        log_error "Daemon is not running!"
        log_info "Starting daemon..."
        cd "$INSTALL_DIR"
        ./src/junocashd -daemon
        sleep 15
    fi
    
    cd "$INSTALL_DIR"
    
    # Ask for mining mode
    echo -e "${CYAN}Select RandomX Mining Mode:${NC}"
    echo "1. Fast Mode (Recommended - Uses ~2GB RAM, Better hashrate)"
    echo "2. Light Mode (Uses less RAM ~256MB, Lower hashrate)"
    echo "3. Auto Mode (Let system decide)"
    echo ""
    echo -n "Select mode [1-3] (default: 1): "
    read -r mode_choice
    
    case $mode_choice in
        2)
            SELECTED_MODE="light"
            ;;
        3)
            SELECTED_MODE="auto"
            ;;
        *)
            SELECTED_MODE="fast"
            ;;
    esac
    
    # Update config with selected mode
    sed -i "s/randomx-mode=.*/randomx-mode=$SELECTED_MODE/" ~/.junocash/junocash.conf
    
    log_info "Starting mining with $MINING_THREADS threads in $SELECTED_MODE mode..."
    
    # If mode changed, restart daemon to apply settings
    if [ "$SELECTED_MODE" != "$RANDOMX_MODE" ]; then
        log_info "Restarting daemon to apply new RandomX mode..."
        ./src/junocash-cli stop 2>/dev/null
        sleep 5
        ./src/junocashd -daemon
        sleep 15
    fi
    
    RESULT=$(./src/junocash-cli setgenerate true ${MINING_THREADS} 2>&1)
    
    if [[ "$RESULT" == *"error"* ]]; then
        log_error "Failed to start mining: $RESULT"
    else
        log_success "Mining started successfully in $SELECTED_MODE mode!"
        echo ""
        ./src/junocash-cli getmininginfo
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Check balance
check_balance() {
    show_header
    
    if ! check_daemon; then
        log_error "Daemon is not running!"
        read -p "Press Enter to continue..."
        return
    fi
    
    cd "$INSTALL_DIR"
    
    log_info "Account Balance:"
    echo ""
    
    BALANCE=$(./src/junocash-cli z_getbalanceforaccount 0 2>&1)
    
    if [[ "$BALANCE" == *"error"* ]]; then
        log_error "Failed to get balance: $BALANCE"
    else
        echo -e "${GREEN}$BALANCE${NC}"
    fi
    
    echo ""
    log_info "Recent Transactions:"
    ./src/junocash-cli listtransactions "*" 10 2>/dev/null
    
    echo ""
    read -p "Press Enter to continue..."
}

# Check address
check_address() {
    show_header
    
    if [ -f ~/.junocash/mining_address.txt ]; then
        log_info "Your Mining Address:"
        echo ""
        ADDRESS=$(cat ~/.junocash/mining_address.txt)
        echo -e "${GREEN}$ADDRESS${NC}"
        echo ""
        log_info "Address saved in: ~/.junocash/mining_address.txt"
    else
        log_warning "No saved address found!"
        
        if check_daemon; then
            cd "$INSTALL_DIR"
            log_info "Retrieving address from wallet..."
            ADDRESS=$(./src/junocash-cli z_getaddressforaccount 0 2>&1)
            
            if [[ "$ADDRESS" != *"error"* ]]; then
                echo ""
                echo -e "${GREEN}$ADDRESS${NC}"
                echo "$ADDRESS" > ~/.junocash/mining_address.txt
                echo ""
                log_success "Address saved to ~/.junocash/mining_address.txt"
            else
                log_error "Failed to get address: $ADDRESS"
            fi
        else
            log_error "Daemon is not running!"
        fi
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Check seed phrase
check_seed() {
    show_header
    
    log_warning "SEED PHRASE - KEEP THIS SAFE AND PRIVATE!"
    echo ""
    
    if [ -f ~/.junocash/seed_phrase.txt ]; then
        log_info "Seed Phrase / Backup Info:"
        echo ""
        cat ~/.junocash/seed_phrase.txt
        echo ""
        log_info "Seed phrase location: ~/.junocash/seed_phrase.txt"
    else
        log_warning "No saved seed phrase found!"
        
        if check_daemon; then
            cd "$INSTALL_DIR"
            log_info "Exporting wallet backup..."
            
            ./src/junocash-cli z_exportwallet "/tmp/wallet_backup_$(date +%s).txt" 2>&1
            
            echo ""
            log_info "Wallet backup saved to /tmp/"
            log_info "Backup files:"
            ls -lh /tmp/wallet_backup_* 2>/dev/null || log_warning "No backup files found"
            
            # Try to get viewing key
            if [ -f ~/.junocash/mining_address.txt ]; then
                ADDRESS=$(cat ~/.junocash/mining_address.txt)
                log_info "Exporting viewing key..."
                ./src/junocash-cli z_exportviewingkey "$ADDRESS" 2>/dev/null
            fi
        else
            log_error "Daemon is not running!"
        fi
    fi
    
    echo ""
    log_warning "Always backup these files before deleting the wallet!"
    echo ""
    read -p "Press Enter to continue..."
}

# Stop mining
stop_mining() {
    show_header
    
    if ! check_daemon; then
        log_error "Daemon is not running!"
        read -p "Press Enter to continue..."
        return
    fi
    
    cd "$INSTALL_DIR"
    log_info "Stopping mining..."
    
    RESULT=$(./src/junocash-cli setgenerate false 2>&1)
    
    if [[ "$RESULT" == *"error"* ]]; then
        log_error "Failed to stop mining: $RESULT"
    else
        log_success "Mining stopped successfully!"
        echo ""
        ./src/junocash-cli getmininginfo
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Check mining status
check_status() {
    show_header
    
    if ! check_daemon; then
        log_error "Daemon is not running!"
        read -p "Press Enter to continue..."
        return
    fi
    
    cd "$INSTALL_DIR"
    
    echo -e "${CYAN}=== MINING STATUS ===${NC}"
    ./src/junocash-cli getmininginfo 2>/dev/null
    
    echo ""
    echo -e "${CYAN}=== BLOCKCHAIN INFO ===${NC}"
    ./src/junocash-cli getblockchaininfo 2>/dev/null | grep -E "chain|blocks|headers|difficulty|verificationprogress"
    
    echo ""
    echo -e "${CYAN}=== NETWORK INFO ===${NC}"
    PEERS=$(./src/junocash-cli getconnectioncount 2>/dev/null)
    echo "Connected peers: $PEERS"
    
    echo ""
    echo -e "${CYAN}=== BALANCE ===${NC}"
    ./src/junocash-cli z_getbalanceforaccount 0 2>/dev/null
    
    echo ""
    read -p "Press Enter to continue..."
}

# Stop everything and exit
stop_and_exit() {
    show_header
    
    log_warning "Stopping all Juno Cash processes..."
    
    if check_daemon; then
        cd "$INSTALL_DIR"
        
        log_info "Stopping mining..."
        ./src/junocash-cli setgenerate false 2>/dev/null
        
        sleep 2
        
        log_info "Stopping daemon..."
        ./src/junocash-cli stop 2>/dev/null
        
        log_info "Waiting for daemon to stop..."
        sleep 5
        
        log_success "All processes stopped"
    else
        log_info "Daemon is not running"
    fi
    
    echo ""
    log_success "Goodbye! 👋"
    exit 0
}

# Change RandomX mode
change_randomx_mode() {
    show_header
    
    log_info "Current RandomX Mode Configuration"
    echo ""
    
    if [ -f ~/.junocash/junocash.conf ]; then
        CURRENT_MODE=$(grep "randomx-mode" ~/.junocash/junocash.conf | cut -d'=' -f2)
        echo -e "Current mode: ${GREEN}$CURRENT_MODE${NC}"
    else
        echo "No config file found"
    fi
    
    echo ""
    echo -e "${CYAN}Select New RandomX Mining Mode:${NC}"
    echo ""
    echo "1. ${GREEN}Fast Mode${NC} (Recommended)"
    echo "   - Uses ~2GB RAM"
    echo "   - Best hashrate performance"
    echo "   - Recommended for systems with 4GB+ RAM"
    echo ""
    echo "2. ${YELLOW}Light Mode${NC}"
    echo "   - Uses ~256MB RAM"
    echo "   - Lower hashrate"
    echo "   - Good for low-memory systems"
    echo ""
    echo "3. ${BLUE}Auto Mode${NC}"
    echo "   - System decides based on available RAM"
    echo "   - Balanced approach"
    echo ""
    echo "4. Cancel and return to menu"
    echo ""
    echo -n "Select mode [1-4]: "
    read -r mode_choice
    
    case $mode_choice in
        1)
            NEW_MODE="fast"
            ;;
        2)
            NEW_MODE="light"
            ;;
        3)
            NEW_MODE="auto"
            ;;
        4)
            return
            ;;
        *)
            log_error "Invalid choice"
            read -p "Press Enter to continue..."
            return
            ;;
    esac
    
    log_info "Changing RandomX mode to: $NEW_MODE"
    
    # Update config
    if [ -f ~/.junocash/junocash.conf ]; then
        sed -i "s/randomx-mode=.*/randomx-mode=$NEW_MODE/" ~/.junocash/junocash.conf
        log_success "Config updated"
    else
        log_error "Config file not found"
        read -p "Press Enter to continue..."
        return
    fi
    
    # Ask to restart
    echo ""
    log_warning "Daemon needs to restart to apply changes"
    echo -n "Restart daemon now? (y/n): "
    read -r restart_choice
    
    if [[ "$restart_choice" == "y" || "$restart_choice" == "Y" ]]; then
        if check_daemon; then
            cd "$INSTALL_DIR"
            
            # Check if currently mining
            MINING_STATUS=$(./src/junocash-cli getmininginfo 2>/dev/null | grep "generate" | grep "true")
            
            log_info "Stopping daemon..."
            ./src/junocash-cli stop 2>/dev/null
            sleep 5
            
            log_info "Starting daemon with new mode..."
            ./src/junocashd -daemon
            sleep 15
            
            # Restart mining if it was running
            if [ -n "$MINING_STATUS" ]; then
                log_info "Restarting mining..."
                ./src/junocash-cli setgenerate true ${MINING_THREADS} 2>/dev/null
                sleep 2
            fi
            
            log_success "Daemon restarted with $NEW_MODE mode"
            echo ""
            ./src/junocash-cli getmininginfo 2>/dev/null
        else
            log_info "Daemon is not running. Start it when ready."
        fi
    else
        log_info "Changes will apply on next daemon start"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Main menu
show_menu() {
    show_header
    
    # Check installation status
    if check_installation; then
        INSTALL_STATUS="${GREEN}✓ Installed${NC}"
    else
        INSTALL_STATUS="${RED}✗ Not Installed${NC}"
    fi
    
    # Check daemon status
    if check_daemon; then
        DAEMON_STATUS="${GREEN}✓ Running${NC}"
    else
        DAEMON_STATUS="${RED}✗ Stopped${NC}"
    fi
    
    echo -e "Status: $INSTALL_STATUS | Daemon: $DAEMON_STATUS"
    echo ""
    echo -e "${YELLOW}┌─────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}1${NC}. Install Juno Cash (Full Setup)   ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}2${NC}. Start Mining (Choose RandomX Mode)${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}3${NC}. Check Balance                     ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}4${NC}. Check Mining Address              ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}5${NC}. Check Seed Phrase / Backup        ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}6${NC}. Stop Mining                       ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}7${NC}. Check Mining Status               ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}8${NC}. Change RandomX Mode               ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}9${NC}. Exit (Keep Mining Running)        ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}0${NC}. Stop Everything and Exit          ${YELLOW}│${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────┘${NC}"
    echo ""
    echo -n "Select option [0-9]: "
}

# Main loop
main() {
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                install_junocash
                ;;
            2)
                if ! check_installation; then
                    log_error "Please install Juno Cash first (Option 1)"
                    read -p "Press Enter to continue..."
                else
                    start_mining
                fi
                ;;
            3)
                if ! check_installation; then
                    log_error "Please install Juno Cash first (Option 1)"
                    read -p "Press Enter to continue..."
                else
                    check_balance
                fi
                ;;
            4)
                check_address
                ;;
            5)
                check_seed
                ;;
            6)
                if ! check_installation; then
                    log_error "Please install Juno Cash first (Option 1)"
                    read -p "Press Enter to continue..."
                else
                    stop_mining
                fi
                ;;
            7)
                if ! check_installation; then
                    log_error "Please install Juno Cash first (Option 1)"
                    read -p "Press Enter to continue..."
                else
                    check_status
                fi
                ;;
            8)
                if ! check_installation; then
                    log_error "Please install Juno Cash first (Option 1)"
                    read -p "Press Enter to continue..."
                else
                    change_randomx_mode
                fi
                ;;
            9)
                show_header
                log_success "Exiting without stopping mining..."
                log_info "Mining will continue in the background"
                echo ""
                log_info "To manage mining later, run this script again"
                echo ""
                exit 0
                ;;
            0)
                stop_and_exit
                ;;
            *)
                log_error "Invalid option. Please choose 0-9"
                sleep 2
                ;;
        esac
    done
}

# Run main program
main
