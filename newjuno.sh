#!/bin/bash

#############################################
# Juno Cash Interactive Setup & Manager
# Compatible with Juno Cash v0.9.6+
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
JUNO_VERSION="v0.9.6"
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
    echo "        Compatible with v0.9.6+"
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
    log_info "Starting Juno Cash $JUNO_VERSION installation..."
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
        jq \
        libnuma-dev
    
    log_success "Dependencies installed (including NUMA support)"
    
    # Step 2: Clone repository
    log_info "Step 2/7: Cloning repository..."
    cd /root
    if [ -d "$INSTALL_DIR" ]; then
        log_warning "Removing old installation..."
        rm -rf "$INSTALL_DIR"
    fi
    
    git clone https://github.com/juno-cash/junocash.git
    cd junocash
    
    # Checkout specific version
    git checkout $JUNO_VERSION
    log_success "Repository cloned ($JUNO_VERSION)"
    
    # Step 3: Build
    log_info "Step 3/7: Building Juno Cash..."
    log_warning "This will take 30-120 minutes. Please be patient!"
    echo ""
    
    # Use new build script if available
    if [ -f "./build-linux.sh" ]; then
        log_info "Using optimized build script..."
        chmod +x ./build-linux.sh
        ./build-linux.sh 2>&1 | tee build.log
    else
        ./zcutil/build.sh -j${BUILD_THREADS} 2>&1 | tee build.log
    fi
    
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
# Juno Cash Configuration (v0.9.6+)
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

# NUMA Support (v0.9.5+)
# Automatically uses NUMA if available

# Export directory for wallet backups
exportdir=/root
EOF
    
    log_success "Configuration created with NUMA support"
    
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
    log_success "Wallet created (Unified Address - shielded only)"
    
    # Step 7: Export seed phrase
    log_info "Step 7/7: Exporting seed phrase..."
    
    # Try z_getseedphrase first (v0.9.5+)
    SEED_PHRASE=$(./src/junocash-cli z_getseedphrase 2>&1)
    
    if [[ "$SEED_PHRASE" != *"error"* ]] && [ -n "$SEED_PHRASE" ]; then
        echo "$SEED_PHRASE" > ~/.junocash/seed_phrase.txt
        chmod 600 ~/.junocash/seed_phrase.txt
        log_success "Seed phrase exported (24-word mnemonic)"
    else
        # Fallback to z_exportwallet
        ./src/junocash-cli z_exportwallet "walletbackup" 2>&1
        if [ -f ~/walletbackup ]; then
            cp ~/walletbackup ~/.junocash/seed_phrase.txt
            chmod 600 ~/.junocash/seed_phrase.txt
            log_success "Wallet backup exported"
        fi
    fi
    
    echo ""
    log_success "Installation completed!"
    echo ""
    log_info "Your mining address (Unified Address - shielded only):"
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
    log_info "NUMA support will be auto-detected and used if available"
    
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
        log_info "NUMA optimization active (can double mining speed on supported systems)"
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
        log_info "Your Mining Address (Unified Address - shielded only):"
        echo ""
        ADDRESS=$(cat ~/.junocash/mining_address.txt)
        echo -e "${GREEN}$ADDRESS${NC}"
        echo ""
        log_info "Address saved in: ~/.junocash/mining_address.txt"
        log_warning "Note: UA format in v0.9.6+ only contains shielded receivers"
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
    
    if ! check_daemon; then
        log_error "Daemon is not running!"
        log_info "Starting daemon..."
        cd "$INSTALL_DIR"
        ./src/junocashd -daemon
        sleep 15
    fi
    
    cd "$INSTALL_DIR"
    
    # Try to get seed phrase using z_getseedphrase
    log_info "Attempting to retrieve seed phrase..."
    echo ""
    
    SEED_PHRASE=$(./src/junocash-cli z_getseedphrase 2>&1)
    
    if [[ "$SEED_PHRASE" != *"error"* ]] && [ -n "$SEED_PHRASE" ]; then
        echo -e "${GREEN}=== SEED PHRASE (BIP39 Mnemonic - 24 words) ===${NC}"
        echo "$SEED_PHRASE"
        echo ""
        
        # Save to file
        echo "$SEED_PHRASE" > ~/.junocash/seed_phrase_mnemonic.txt
        chmod 600 ~/.junocash/seed_phrase_mnemonic.txt
        log_success "Seed phrase saved to ~/.junocash/seed_phrase_mnemonic.txt"
        log_info "Use 'z_recoverwallet' to restore from this seed phrase"
        echo ""
    else
        log_warning "z_getseedphrase not available or no HD seed"
        echo ""
    fi
    
    # Show shielded addresses
    echo -e "${CYAN}=== SHIELDED ADDRESSES ===${NC}"
    ADDRESSES=$(./src/junocash-cli z_listaddresses 2>/dev/null)
    echo "$ADDRESSES"
    echo ""
    
    # Check if old seed_phrase.txt exists
    if [ -f ~/.junocash/seed_phrase.txt ]; then
        echo -e "${CYAN}=== BACKUP INFO (from previous export) ===${NC}"
        cat ~/.junocash/seed_phrase.txt
        echo ""
        log_info "Old backup location: ~/.junocash/seed_phrase.txt"
        echo ""
    fi
    
    # Show wallet backup files
    echo -e "${CYAN}=== WALLET BACKUP FILES ===${NC}"
    log_info "Backup files found:"
    ls -lh ~/walletbackup* ~/.junocash/*_keys_*.txt ~/.junocash/seed_phrase*.txt 2>/dev/null | tail -10 || echo "No backup files found"
    echo ""
    
    # Offer to create full wallet export
    echo -e "${YELLOW}Create complete wallet backup now? (y/n): ${NC}"
    read -r CREATE_BACKUP
    
    if [[ "$CREATE_BACKUP" == "y" || "$CREATE_BACKUP" == "Y" ]]; then
        echo ""
        log_info "Creating complete wallet backup..."
        
        BACKUP_NAME="walletbackup_complete_$(date +%Y%m%d_%H%M%S)"
        
        RESULT=$(./src/junocash-cli z_exportwallet "$BACKUP_NAME" 2>&1)
        
        if [[ "$RESULT" != *"error"* ]]; then
            log_success "Complete wallet backup created!"
            echo ""
            log_info "Backup location: ~/$BACKUP_NAME"
            echo ""
            echo "Preview of backup:"
            head -30 ~/"$BACKUP_NAME"
        else
            log_error "Failed to create backup: $RESULT"
        fi
    fi
    
    echo ""
    log_warning "IMPORTANT: Keep all backup files safe and private!"
    log_warning "Anyone with these keys can access your funds!"
    echo ""
    
    read -p "Press Enter to continue..."
}

# Recover wallet from seed phrase
recover_wallet() {
    show_header
    
    log_info "Recover Wallet from Seed Phrase (v0.9.5+)"
    echo ""
    
    if ! check_daemon; then
        log_error "Daemon is not running!"
        log_info "Starting daemon..."
        cd "$INSTALL_DIR"
        ./src/junocashd -daemon
        sleep 15
    fi
    
    cd "$INSTALL_DIR"
    
    log_warning "This will replace your current wallet!"
    log_warning "Make sure you have backed up your current wallet first!"
    echo ""
    echo -n "Continue? (yes/no): "
    read -r CONFIRM
    
    if [[ "$CONFIRM" != "yes" ]]; then
        log_info "Recovery cancelled"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    log_info "Enter your 24-word seed phrase:"
    log_info "(Words should be separated by spaces)"
    echo ""
    echo -n "Seed Phrase: "
    read -r SEED_INPUT
    
    if [ -z "$SEED_INPUT" ]; then
        log_error "No seed phrase provided"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo ""
    log_info "Recovering wallet from seed phrase..."
    log_warning "This may take a few minutes..."
    
    RESULT=$(./src/junocash-cli z_recoverwallet "$SEED_INPUT" 2>&1)
    
    if [[ "$RESULT" == *"error"* ]]; then
        log_error "Failed to recover wallet: $RESULT"
    else
        log_success "Wallet recovered successfully!"
        echo ""
        log_info "Wallet is now scanning blockchain for transactions..."
        log_info "This may take several hours depending on wallet age"
        echo ""
        log_info "Your addresses:"
        ./src/junocash-cli z_listaddresses
        echo ""
        log_info "Current balance (may be incomplete during rescan):"
        ./src/junocash-cli z_gettotalbalance
    fi
    
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
    
    echo -e "${CYAN}=== JUNO CASH VERSION ===${NC}"
    ./src/junocash-cli --version 2>/dev/null | head -1
    echo ""
    
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
    echo "   - NUMA support can double speed on multi-socket systems"
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

# Import Private Key
import_private_key() {
    show_header
    
    log_info "Import Private Key to Wallet"
    echo ""
    
    if ! check_daemon; then
        log_error "Daemon is not running!"
        log_info "Starting daemon..."
        cd "$INSTALL_DIR"
        ./src/junocashd -daemon
        sleep 15
    fi
    
    cd "$INSTALL_DIR"
    
    echo -e "${CYAN}Select Import Type:${NC}"
    echo ""
    echo "1. Shielded Private Key (secret-extended-key-main...)"
    echo "2. Import from Backup File (wallet backup)"
    echo "3. Recover from Seed Phrase (24 words - v0.9.5+)"
    echo "4. Cancel"
    echo ""
    echo -n "Select [1-4]: "
    read -r key_type
    
    case $key_type in
        1)
            # Import Shielded Key
            echo ""
            log_info "Import Shielded Private Key (Sapling/Orchard)"
            echo ""
            echo "Enter your shielded private key:"
            echo "(Format: secret-extended-key-main1q...)"
            echo ""
            echo -n "Private Key: "
            read -r PRIVATE_KEY
            
            if [ -z "$PRIVATE_KEY" ]; then
                log_error "No key provided"
                read -p "Press Enter to continue..."
                return
            fi
            
            log_info "Importing shielded key..."
            RESULT=$(./src/junocash-cli z_importkey "$PRIVATE_KEY" 2>&1)
            
            if [[ "$RESULT" == *"error"* ]]; then
                log_error "Failed to import: $RESULT"
            else
                log_success "Shielded key imported successfully!"
                echo ""
                log_info "Imported addresses:"
                ./src/junocash-cli z_listaddresses
                echo ""
                log_info "Checking balance (may take a moment)..."
                ./src/junocash-cli z_gettotalbalance
            fi
            ;;
            
        2)
            # Import from Backup File
            echo ""
            log_info "Import from Wallet Backup File"
            echo ""
            echo "Available backup files:"
            ls -1 ~/walletbackup* /tmp/wallet_backup* 2>/dev/null | head -10
            echo ""
            echo "Enter backup filename (or full path):"
            echo -n "Filename: "
            read -r BACKUP_FILE
            
            if [ -z "$BACKUP_FILE" ]; then
                log_error "No filename provided"
                read -p "Press Enter to continue..."
                return
            fi
            
            # Try to find the file
            if [ -f "$BACKUP_FILE" ]; then
                BACKUP_PATH="$BACKUP_FILE"
            elif [ -f ~/"$BACKUP_FILE" ]; then
                BACKUP_PATH=~/"$BACKUP_FILE"
            elif [ -f /tmp/"$BACKUP_FILE" ]; then
                BACKUP_PATH=/tmp/"$BACKUP_FILE"
            else
                log_error "File not found: $BACKUP_FILE"
                read -p "Press Enter to continue..."
                return
            fi
            
            log_info "Importing wallet from: $BACKUP_PATH"
            log_warning "This may take a while..."
            
            RESULT=$(./src/junocash-cli z_importwallet "$BACKUP_PATH" 2>&1)
            
            if [[ "$RESULT" == *"error"* ]]; then
                log_error "Failed to import: $RESULT"
            else
                log_success "Wallet imported successfully!"
                echo ""
                log_info "Imported addresses:"
                ./src/junocash-cli z_listaddresses
                echo ""
                log_info "Total balance:"
                ./src/junocash-cli z_gettotalbalance
            fi
            ;;
            
        3)
            # Recover from seed phrase
            recover_wallet
            return
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
    
    echo ""
    read -p "Press Enter to continue..."
}

# Export Private Key
export_private_key() {
    show_header
    
    log_info "Export Private Key from Wallet"
    echo ""
    
    if ! check_daemon; then
        log_error "Daemon is not running!"
        log_info "Starting daemon..."
        cd "$INSTALL_DIR"
        ./src/junocashd -daemon
        sleep 15
    fi
    
    cd "$INSTALL_DIR"
    
    echo -e "${CYAN}Select Export Type:${NC}"
    echo ""
    echo "1. Export Seed Phrase (24 words - v0.9.5+)"
    echo "2. Export Shielded Private Key (for specific address)"
    echo "3. Export All Keys (full wallet backup)"
    echo "4. Export Viewing Key (read-only, safe to share)"
    echo "5. Cancel"
    echo ""
    echo -n "Select [1-5]: "
    read -r export_type
    
 case $export_type in
        1)
            # Export Shielded Key
            echo ""
            log_info "Export Shielded Private Key"
            echo ""
            log_info "Available shielded addresses:"
            ./src/junocash-cli z_listaddresses
            echo ""
            echo "Enter address to export private key:"
            echo -n "Address: "
            read -r ADDRESS
            
            if [ -z "$ADDRESS" ]; then
                log_error "No address provided"
                read -p "Press Enter to continue..."
                return
            fi
            
            log_warning "KEEP THIS PRIVATE KEY SAFE!"
            echo ""
            PRIVATE_KEY=$(./src/junocash-cli z_exportkey "$ADDRESS" 2>&1)
            
            if [[ "$PRIVATE_KEY" == *"error"* ]]; then
                log_error "Failed to export: $PRIVATE_KEY"
            else
                echo -e "${GREEN}Private Key:${NC}"
                echo "$PRIVATE_KEY"
                echo ""
                
                # Save to file
                echo "$PRIVATE_KEY" > ~/.junocash/exported_key_$(date +%Y%m%d_%H%M%S).txt
                log_success "Private key also saved to ~/.junocash/exported_key_*.txt"
            fi
            ;;
            
        2)
            # Export All Keys
            echo ""
            log_info "Export Full Wallet Backup"
            echo ""
            
            BACKUP_NAME="walletbackup_$(date +%Y%m%d_%H%M%S)"
            log_info "Exporting to: ~/$BACKUP_NAME"
            
            RESULT=$(./src/junocash-cli z_exportwallet "$BACKUP_NAME" 2>&1)
            
            if [[ "$RESULT" == *"error"* ]]; then
                log_error "Failed to export: $RESULT"
            else
                log_success "Wallet exported successfully!"
                echo ""
                log_info "Backup file: ~/$BACKUP_NAME"
                echo ""
                echo "File preview:"
                head -20 ~/"$BACKUP_NAME"
                echo ""
                log_warning "KEEP THIS FILE SAFE! It contains ALL your private keys!"
            fi
            ;;
            
        3)
            # Export Viewing Key
            echo ""
            log_info "Export Viewing Key (Read-Only)"
            echo ""
            log_info "Available shielded addresses:"
            ./src/junocash-cli z_listaddresses
            echo ""
            echo "Enter address to export viewing key:"
            echo -n "Address: "
            read -r ADDRESS
            
            if [ -z "$ADDRESS" ]; then
                log_error "No address provided"
                read -p "Press Enter to continue..."
                return
            fi
            
            echo ""
            VIEWING_KEY=$(./src/junocash-cli z_exportviewingkey "$ADDRESS" 2>&1)
            
            if [[ "$VIEWING_KEY" == *"error"* ]]; then
                log_error "Failed to export: $VIEWING_KEY"
            else
                echo -e "${GREEN}Viewing Key:${NC}"
                echo "$VIEWING_KEY"
                echo ""
                
                # Save to file
                echo "$VIEWING_KEY" > ~/.junocash/viewing_key_$(date +%Y%m%d_%H%M%S).txt
                log_success "Viewing key saved to ~/.junocash/viewing_key_*.txt"
                log_info "This key can only VIEW transactions, not spend coins"
            fi
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
    echo -e "${YELLOW}│${NC}  ${CYAN}6${NC}. Import Private Key                ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}7${NC}. Export Private Key                ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}8${NC}. Stop Mining                       ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}9${NC}. Check Mining Status               ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}a${NC}. Change RandomX Mode               ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}x${NC}. Exit (Keep Mining Running)        ${YELLOW}│${NC}"
    echo -e "${YELLOW}│${NC}  ${CYAN}0${NC}. Stop Everything and Exit          ${YELLOW}│${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────┘${NC}"
    echo ""
    echo -n "Select option: "
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
                import_private_key
                ;;
            7)
                export_private_key
                ;;
            8)
                if ! check_installation; then
                    log_error "Please install Juno Cash first (Option 1)"
                    read -p "Press Enter to continue..."
                else
                    stop_mining
                fi
                ;;
            9)
                if ! check_installation; then
                    log_error "Please install Juno Cash first (Option 1)"
                    read -p "Press Enter to continue..."
                else
                    check_status
                fi
                ;;
            a|A)
                if ! check_installation; then
                    log_error "Please install Juno Cash first (Option 1)"
                    read -p "Press Enter to continue..."
                else
                    change_randomx_mode
                fi
                ;;
            x|X)
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
                log_error "Invalid option"
                sleep 2
                ;;
        esac
    done
}

# Run main program
main
