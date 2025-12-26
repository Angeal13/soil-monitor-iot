import mysql.connector
import serial

class Config:
    # Database Configuration
    DB_CONFIG = {
        'user': "DevOps",
        'password': "DevTeam", 
        'host': "192.168.1.100",
        'port': 3306,
        'database': "soilmonitornig"
    }
    
    # Serial Configuration - Raspberry Pi 3
    SERIAL_PORT = '/dev/ttyUSB0'  # Changed to Raspberry Pi port
    SERIAL_BAUDRATE = 9600
    SERIAL_TIMEOUT = 1
    MODBUS_COMMAND = bytes([0x01, 0x03, 0x00, 0x00, 0x00, 0x07, 0x04, 0x08])
    RESPONSE_LENGTH = 19
    
    # System Behavior
    MEASUREMENT_INTERVAL = 300  # seconds
    OFFLINE_STORAGE = 'offline_data.csv'
    MAX_OFFLINE_RECORDS = 1000

    INTERNET_TEST_URLS = ['http://www.google.com', 'http://www.cloudflare.com']
