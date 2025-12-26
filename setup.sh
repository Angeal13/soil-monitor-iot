#!/bin/bash
# setup.sh - IoT Soil Monitor System Setup for Raspberry Pi
# GitHub: https://github.com/Angeal13/soil-monitor-iot

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration - Dynamically determined
CURRENT_USER=$(whoami)
HOME_DIR=$(eval echo ~$CURRENT_USER)
REPO_NAME="soil-monitor-iot"
REPO_URL="https://github.com/Angeal13/${REPO_NAME}.git"
VENV_NAME="soilenv"
VENV_PATH="${HOME_DIR}/${VENV_NAME}"
APP_PATH="${HOME_DIR}/${REPO_NAME}"
SERVICE_NAME="soil-monitor.service"

# Detect Python version
detect_python() {
    print_status "Detecting Python version..."
    
    # Check for python3 command
    if command -v python3 &> /dev/null; then
        PYTHON_VERSION="python3"
        PYTHON_CMD="python3"
        
        # Get full version
        PYTHON_FULL_VERSION=$(python3 --version | awk '{print $2}')
        print_status "Found Python $PYTHON_FULL_VERSION"
        
        # Check if it's Python 3.x
        if [[ ! "$PYTHON_FULL_VERSION" =~ ^3\. ]]; then
            print_error "Python 3.x is required. Found: $PYTHON_FULL_VERSION"
            exit 1
        fi
        
        # Check Python version compatibility
        PYTHON_MAJOR_MINOR=$(echo "$PYTHON_FULL_VERSION" | cut -d. -f1-2)
        
        # Warn about very old Python 3 versions
        if [[ "$(echo "$PYTHON_MAJOR_MINOR < 3.7" | bc -l 2>/dev/null)" -eq 1 ]]; then
            print_warning "Python $PYTHON_FULL_VERSION is quite old. Consider upgrading to Python 3.7+"
        fi
        
    else
        print_error "Python 3 not found!"
        print_error "Please install Python 3: sudo apt install python3"
        exit 1
    fi
}

print_status() {
    echo -e "${GREEN}[*]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_sudo() {
    print_status "Checking sudo privileges..."
    if ! sudo -v; then
        print_error "User $CURRENT_USER needs sudo privileges"
        print_error "Run: sudo usermod -a -G sudo $CURRENT_USER"
        print_error "Then log out and back in"
        exit 1
    fi
    print_status "User $CURRENT_USER has sudo privileges ✓"
}

update_system() {
    print_status "Updating system packages..."
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install -y git python3-pip python3-venv python3-dev
}

setup_serial() {
    print_status "Setting up serial communication..."
    
    # Add current user to dialout group for serial access
    sudo usermod -a -G dialout $CURRENT_USER
    
    # Disable serial console if using GPIO serial
    print_warning "If using GPIO serial (ttyAMA0), disable serial console in raspi-config"
    print_warning "Run 'sudo raspi-config' → Interface Options → Serial Port"
    print_warning "Choose 'No' to login shell, 'Yes' to serial hardware"
    
    # Install serial tools
    sudo apt-get install -y minicom screen
}

create_virtualenv() {
    print_status "Creating Python virtual environment..."
    
    # Remove old environment if exists
    if [[ -d "$VENV_PATH" ]]; then
        print_warning "Removing existing virtual environment..."
        rm -rf "$VENV_PATH"
    fi
    
    # Create new virtual environment with detected Python version
    $PYTHON_CMD -m venv "$VENV_PATH"
    
    # Activate and install dependencies
    source "${VENV_PATH}/bin/activate"
    
    print_status "Upgrading pip..."
    pip install --upgrade pip
    
    print_status "Installing Python dependencies..."
    
    # Install compatible versions based on Python version
    if [[ "$(echo "$PYTHON_MAJOR_MINOR >= 3.11" | bc -l 2>/dev/null)" -eq 1 ]] || [[ -z "$PYTHON_MAJOR_MINOR" ]]; then
        # For Python 3.11+ or unknown version, use latest compatible versions
        print_status "Python $PYTHON_FULL_VERSION detected, using latest compatible packages"
        pip install mysql-connector-python pyserial pandas urllib3
    elif [[ "$(echo "$PYTHON_MAJOR_MINOR >= 3.8" | bc -l 2>/dev/null)" -eq 1 ]]; then
        # For Python 3.8-3.10, use specific versions that work well
        pip install mysql-connector-python==8.2.0
        pip install pyserial==3.5
        pip install pandas==2.0.3
        pip install urllib3==2.0.7
    else
        # For Python 3.7 or older, use older compatible versions
        pip install mysql-connector-python==8.0.33
        pip install pyserial==3.5
        pip install pandas==1.5.3
        pip install urllib3==1.26.15
    fi
    
    # Verify installations
    print_status "Verifying package installations..."
    pip list | grep -E "mysql-connector|pyserial|pandas|urllib3"
    
    deactivate
    
    print_status "Virtual environment created at: ${VENV_PATH}"
}

clone_repository() {
    print_status "Cloning repository from GitHub..."
    
    if [[ -d "$APP_PATH" ]]; then
        print_warning "Repository already exists, pulling updates..."
        cd "$APP_PATH"
        git pull origin main
    else
        print_status "Cloning from: ${REPO_URL}"
        git clone "$REPO_URL" "$APP_PATH"
        cd "$APP_PATH"
    fi
    
    # Verify required files exist
    REQUIRED_FILES=("Config.py" "MainController.py" "SensorReader.py" "OnlineLogger.py" "OfflineLogger.py")
    for file in "${REQUIRED_FILES[@]}"; do
        if [[ ! -f "$file" ]]; then
            print_error "$file not found in repository!"
            print_error "Please ensure your repository has the correct files."
            exit 1
        fi
    done
    
    # Set proper permissions
    chmod +x setup.sh 2>/dev/null || true
    find . -name "*.py" -exec chmod +x {} \; 2>/dev/null || true
    
    print_status "All required files found ✓"
}

update_serial_port() {
    print_status "Updating serial port configuration for Raspberry Pi..."
    
    CONFIG_FILE="${APP_PATH}/Config.py"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        # Create backup of original config
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup"
        
        print_status "Original config backed up as: ${CONFIG_FILE}.backup"
        
        # Check current serial port setting
        CURRENT_PORT=$(grep "SERIAL_PORT = " "$CONFIG_FILE" | head -1 | cut -d "'" -f 2)
        print_status "Current serial port in Config.py: ${CURRENT_PORT}"
        
        # Update serial port for Raspberry Pi if it's still COM4
        if [[ "$CURRENT_PORT" == "COM4" ]]; then
            sed -i "s/SERIAL_PORT = 'COM4'/SERIAL_PORT = '\/dev\/ttyUSB0'/" "$CONFIG_FILE"
            sed -i "s/# Changed to Raspberry Pi port/# Raspberry Pi with USB-to-RS485 adapter/" "$CONFIG_FILE"
            print_status "Updated serial port from COM4 to /dev/ttyUSB0"
        elif [[ "$CURRENT_PORT" == "/dev/ttyUSB0" ]] || [[ "$CURRENT_PORT" == "/dev/ttyAMA0" ]]; then
            print_status "Serial port already configured for Raspberry Pi: ${CURRENT_PORT}"
        else
            print_warning "Unknown serial port configuration: ${CURRENT_PORT}"
            print_warning "Please verify this matches your Raspberry Pi setup"
        fi
        
        # Display final configuration
        echo ""
        print_status "Final Configuration in Config.py:"
        grep -A 20 "class Config:" "$CONFIG_FILE" | head -25
        echo ""
        
    else
        print_error "Config.py not found after cloning!"
        exit 1
    fi
}

create_start_script() {
    print_status "Creating start script..."
    
    cat > "${APP_PATH}/start_monitor.sh" << EOF
#!/bin/bash
# start_monitor.sh - Start Soil Monitor IoT System

set -e

USER="${CURRENT_USER}"
HOME_DIR="${HOME_DIR}"
VENV_PATH="\${HOME_DIR}/soilenv"
APP_PATH="\${HOME_DIR}/soil-monitor-iot"
LOG_FILE="\${HOME_DIR}/soil_monitor.log"

echo "\$(date): Starting Soil Monitor System" >> "\$LOG_FILE"

# Activate virtual environment
source "\${VENV_PATH}/bin/activate"

# Change to app directory
cd "\$APP_PATH"

# Run the main controller
python3 MainController.py 2>&1 | tee -a "\$LOG_FILE"

# If we get here, something went wrong
echo "\$(date): Soil Monitor stopped unexpectedly" >> "\$LOG_FILE"
EOF
    
    chmod +x "${APP_PATH}/start_monitor.sh"
    print_status "Start script created: ${APP_PATH}/start_monitor.sh"
}

create_systemd_service() {
    print_status "Creating systemd service for auto-start on boot..."
    
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
    
    sudo bash -c "cat > ${SERVICE_FILE}" << EOF
[Unit]
Description=Soil Monitor IoT System
After=network.target multi-user.target
Wants=network.target

[Service]
Type=simple
User=${CURRENT_USER}
WorkingDirectory=${HOME_DIR}/soil-monitor-iot
ExecStart=${HOME_DIR}/soil-monitor-iot/start_monitor.sh
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=soil-monitor

# Security enhancements
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${HOME_DIR}/soil-monitor-iot ${HOME_DIR}/soilenv
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable the service
    sudo systemctl daemon-reload
    sudo systemctl enable ${SERVICE_NAME}
    
    print_status "Systemd service created and enabled for user: ${CURRENT_USER}"
}

create_log_rotation() {
    print_status "Setting up log rotation..."
    
    sudo bash -c "cat > /etc/logrotate.d/soil-monitor" << EOF
${HOME_DIR}/soil_monitor.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 ${CURRENT_USER} ${CURRENT_USER}
    postrotate
        systemctl kill -s USR1 soil-monitor.service >/dev/null 2>&1 || true
    endscript
}
EOF
}

install_crontab() {
    print_status "Setting up health check cron job..."
    
    # Add health check that restarts service if it's down
    (crontab -l 2>/dev/null | grep -v "soil-monitor"; echo "*/5 * * * * /usr/bin/systemctl is-active --quiet soil-monitor.service || /usr/bin/systemctl restart soil-monitor.service") | crontab -
    
    # Also add a daily log cleanup
    (crontab -l 2>/dev/null | grep -v "cleanup_old_logs"; echo "0 2 * * * find ${HOME_DIR} -name 'soil_monitor.log.*' -mtime +30 -delete") | crontab -
}

verify_configuration() {
    print_status "Verifying system configuration..."
    
    echo ""
    print_status "=== Configuration Summary ==="
    print_status "Current User: ${CURRENT_USER}"
    print_status "Home Directory: ${HOME_DIR}"
    print_status "Repository: ${APP_PATH}"
    print_status "Virtual Env: ${VENV_PATH}"
    print_status "Service: ${SERVICE_NAME}"
    print_status "Python Version: ${PYTHON_FULL_VERSION}"
    
    # Test Python in virtual environment
    source "${VENV_PATH}/bin/activate"
    print_status "Virtual Env Python: $(python3 --version)"
    deactivate
    
    # Show database configuration (without passwords)
    if [[ -f "${APP_PATH}/Config.py" ]]; then
        echo ""
        print_status "Database Configuration:"
        grep -A 5 "DB_CONFIG = " "${APP_PATH}/Config.py" | sed 's/password.*/password: [HIDDEN]/g'
    fi
    
    # Show serial configuration
    echo ""
    print_status "Serial Configuration:"
    grep -A 3 "SERIAL_PORT = " "${APP_PATH}/Config.py"
    
    echo ""
}

test_system() {
    print_status "Running system test..."
    
    # Test Python imports
    source "${VENV_PATH}/bin/activate"
    
    TEST_SCRIPT="${HOME_DIR}/test_imports.py"
    cat > "$TEST_SCRIPT" << 'EOF'
#!/usr/bin/env python3
import sys
print(f"Python {sys.version}")

try:
    import mysql.connector
    print("✓ mysql.connector imported successfully")
except ImportError as e:
    print(f"✗ mysql.connector failed: {e}")

try:
    import serial
    print("✓ pyserial imported successfully")
except ImportError as e:
    print(f"✗ pyserial failed: {e}")

try:
    import pandas
    print(f"✓ pandas {pandas.__version__} imported successfully")
except ImportError as e:
    print(f"✗ pandas failed: {e}")

try:
    import urllib3
    print(f"✓ urllib3 {urllib3.__version__} imported successfully")
except ImportError as e:
    print(f"✗ urllib3 failed: {e}")

print("\nAll required packages are installed!")
EOF
    
    python3 "$TEST_SCRIPT"
    rm "$TEST_SCRIPT"
    deactivate
}

setup_complete() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}           SETUP COMPLETE SUCCESSFULLY!           ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo ""
    
    verify_configuration
    
    # Run system test
    test_system
    
    echo ""
    echo "Service commands:"
    echo "  Start:    sudo systemctl start soil-monitor"
    echo "  Stop:     sudo systemctl stop soil-monitor"
    echo "  Status:   sudo systemctl status soil-monitor"
    echo "  Logs:     journalctl -u soil-monitor -f"
    echo ""
    echo "Important notes:"
    echo "1. User ${CURRENT_USER} was added to 'dialout' group for serial access"
    echo "   You may need to log out and back in for this to take effect"
    echo "2. Verify database settings in: ${APP_PATH}/Config.py"
    echo "3. Check serial port: ls /dev/ttyUSB* or /dev/ttyAMA0"
    echo "4. For GPIO serial: sudo raspi-config → Serial Port"
    echo ""
    echo "Paths:"
    echo "  Code:     ${APP_PATH}"
    echo "  Virtual:  ${VENV_PATH}"
    echo "  Logs:     ${HOME_DIR}/soil_monitor.log"
    echo ""
    
    # Ask user if they want to reboot now
    echo -e "${YELLOW}Do you want to reboot now to activate the service? (y/n)${NC}"
    read -t 30 -p "Reboot now? [y/N]: " REBOOT_CHOICE
    
    if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
        echo -e "\n${GREEN}Rebooting in 5 seconds...${NC}"
        echo -e "${YELLOW}Press Ctrl+C to cancel${NC}"
        
        for i in {5..1}; do
            echo -ne "Rebooting in $i seconds...\r"
            sleep 1
        done
        
        echo -e "\n${GREEN}Rebooting now!${NC}"
        sudo reboot
    else
        echo -e "\n${YELLOW}Skipping reboot. To start the service manually:${NC}"
        echo "  sudo systemctl start soil-monitor"
        echo "  sudo systemctl enable soil-monitor"
        echo ""
        echo -e "${YELLOW}Important: Log out and back in for serial permissions to take effect${NC}"
        echo -e "${GREEN}Setup complete! You can reboot later with: sudo reboot${NC}"
    fi
}

# Main execution
main() {
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   IoT Soil Monitor System Setup for Raspberry Pi   ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo ""
    print_status "Detected user: ${CURRENT_USER}"
    print_status "Home directory: ${HOME_DIR}"
    
    # Detect Python version first
    detect_python
    
    echo ""
    
    # Run all setup steps
    check_sudo
    update_system
    setup_serial
    create_virtualenv
    clone_repository
    update_serial_port
    create_start_script
    create_systemd_service
    create_log_rotation
    install_crontab
    setup_complete
}

# Run main function
main "$@"
