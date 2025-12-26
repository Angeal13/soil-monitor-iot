#!/bin/bash
# setup.sh - IoT Soil Monitor System Setup for Raspberry Pi
# GitHub: https://github.com/Angeal13/soil-monitor-iot

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
USER="pi"
REPO_NAME="soil-monitor-iot"
REPO_URL="https://github.com/Angeal13/${REPO_NAME}.git"
VENV_NAME="soilenv"
VENV_PATH="/home/${USER}/${VENV_NAME}"
APP_PATH="/home/${USER}/${REPO_NAME}"
SERVICE_NAME="soil-monitor.service"
PYTHON_VERSION="python3.9"

print_status() {
    echo -e "${GREEN}[*]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_user() {
    if [[ $(whoami) != "pi" ]]; then
        print_error "This script must be run as user 'pi'"
        print_error "Current user: $(whoami)"
        exit 1
    fi
    print_status "Running as user 'pi' ✓"
}

update_system() {
    print_status "Updating system packages..."
    sudo apt-get update
    sudo apt-get upgrade -y
    sudo apt-get install -y git python3-pip python3-venv python3-dev
}

install_python_version() {
    print_status "Checking Python version..."
    
    # Check if Python 3.9 is available
    if ! command -v python3.9 &> /dev/null; then
        print_warning "Python 3.9 not found, installing..."
        sudo apt-get install -y python3.9 python3.9-venv python3.9-dev
    fi
    
    # Set as default Python 3 version
    sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1
    sudo update-alternatives --set python3 /usr/bin/python3.9
}

setup_serial() {
    print_status "Setting up serial communication..."
    
    # Add user to dialout group for serial access
    sudo usermod -a -G dialout $USER
    
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
    
    # Create new virtual environment with Python 3.9
    $PYTHON_VERSION -m venv "$VENV_PATH"
    
    # Activate and install dependencies
    source "${VENV_PATH}/bin/activate"
    
    print_status "Upgrading pip..."
    pip install --upgrade pip
    
    print_status "Installing Python dependencies..."
    pip install mysql-connector-python==8.0.33
    pip install pyserial==3.5
    pip install pandas==1.5.3
    pip install urllib3==1.26.15
    
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
    if [[ ! -f "Config.py" ]]; then
        print_error "Config.py not found in repository!"
        print_error "Please ensure your repository has the correct files."
        exit 1
    fi
    
    if [[ ! -f "MainController.py" ]]; then
        print_error "MainController.py not found in repository!"
        print_error "Please ensure your repository has the correct files."
        exit 1
    fi
    
    # Set proper permissions
    chmod +x setup.sh 2>/dev/null || true
    find . -name "*.py" -exec chmod +x {} \; 2>/dev/null || true
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
    
    cat > "${APP_PATH}/start_monitor.sh" << 'EOF'
#!/bin/bash
# start_monitor.sh - Start Soil Monitor IoT System

set -e

USER="pi"
VENV_PATH="/home/${USER}/soilenv"
APP_PATH="/home/${USER}/soil-monitor-iot"
LOG_FILE="/home/${USER}/soil_monitor.log"

echo "$(date): Starting Soil Monitor System" >> "$LOG_FILE"

# Activate virtual environment
source "${VENV_PATH}/bin/activate"

# Change to app directory
cd "$APP_PATH"

# Run the main controller
python3 MainController.py 2>&1 | tee -a "$LOG_FILE"

# If we get here, something went wrong
echo "$(date): Soil Monitor stopped unexpectedly" >> "$LOG_FILE"
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
User=pi
WorkingDirectory=/home/pi/soil-monitor-iot
ExecStart=/home/pi/soil-monitor-iot/start_monitor.sh
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=soil-monitor

# Security enhancements
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/home/pi/soil-monitor-iot /home/pi/soilenv
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable the service
    sudo systemctl daemon-reload
    sudo systemctl enable ${SERVICE_NAME}
    
    print_status "Systemd service created and enabled"
}

create_log_rotation() {
    print_status "Setting up log rotation..."
    
    sudo bash -c "cat > /etc/logrotate.d/soil-monitor" << EOF
/home/pi/soil_monitor.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 pi pi
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
    (crontab -l 2>/dev/null | grep -v "cleanup_old_logs"; echo "0 2 * * * find /home/pi -name 'soil_monitor.log.*' -mtime +30 -delete") | crontab -
}

verify_configuration() {
    print_status "Verifying system configuration..."
    
    echo ""
    print_status "=== Configuration Summary ==="
    print_status "Repository: ${APP_PATH}"
    print_status "Virtual Env: ${VENV_PATH}"
    print_status "Service: ${SERVICE_NAME}"
    
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

setup_complete() {
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}           SETUP COMPLETE SUCCESSFULLY!           ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo ""
    
    verify_configuration
    
    echo "Service commands:"
    echo "  Start:    sudo systemctl start soil-monitor"
    echo "  Stop:     sudo systemctl stop soil-monitor"
    echo "  Status:   sudo systemctl status soil-monitor"
    echo "  Logs:     journalctl -u soil-monitor -f"
    echo ""
    echo "Important:"
    echo "1. Verify database settings in: ${APP_PATH}/Config.py"
    echo "2. Check serial port: ls /dev/ttyUSB* or /dev/ttyAMA0"
    echo "3. For GPIO serial: sudo raspi-config → Serial Port"
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
        echo -e "${GREEN}Setup complete! You can reboot later with: sudo reboot${NC}"
    fi
}

# Main execution
main() {
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   IoT Soil Monitor System Setup for Raspberry Pi   ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
    echo ""
    
    # Run all setup steps
    check_user
    update_system
    install_python_version
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
