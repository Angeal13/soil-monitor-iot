from OnlineLogger import OnlineLogger
from OfflineLogger import OfflineLogger
from SensorReader import SensorReader
from Config import Config
import time
import logging
from urllib.request import urlopen, Request
from urllib.error import URLError
import mysql.connector

class MainController:
    def __init__(self):
        self.sensor = SensorReader()
        self.online = OnlineLogger()
        self.offline = OfflineLogger()
        self._register_sensor_on_connection()

    def _register_sensor_on_connection(self):
        """Register sensor when the system starts up"""
        if self.has_internet():
            sensor_info = self.sensor.get_sensor_info()
            if sensor_info:
                # Try to register the sensor
                if self.online.register_sensor(sensor_info):
                    logging.info(f"Sensor registered successfully: {sensor_info['machine_id']}")
                else:
                    logging.warning(f"Failed to register sensor: {sensor_info['machine_id']}")
        else:
            logging.info("No internet connection - sensor registration deferred")

    def has_internet(self):
        """Check internet connectivity"""
        for url in Config.INTERNET_TEST_URLS:
            try:
                urlopen(Request(url), timeout=3)
                return True
            except URLError:
                continue
        return False

    def is_sensor_assigned(self, machine_id):
        """Check if sensor has been assigned to a farm (has farm_id)"""
        if not self.has_internet():
            # If no internet, assume sensor is assigned to allow offline collection
            # This prevents data loss when internet is temporarily down
            return True
            
        try:
            conn = mysql.connector.connect(**Config.DB_CONFIG)
            cur = conn.cursor()
            
            # Check if sensor has a farm_id assigned
            cur.execute("SELECT farm_id,is_active FROM sensors WHERE machine_id = %s", (machine_id,))
            result = cur.fetchone()
            
            conn.close()
            
            # Sensor is assigned if :
            # 1)farm_id is not None
            # 2)is_active is 1
            return result is not None and result[0] is not None and result[1]==1
            
        except Exception as e:
            logging.error(f"Error checking sensor assignment: {e}")
            # If we can't check, assume unassigned to prevent unwanted data collection
            return False

    def run(self):
        """Main execution loop"""
        try:
            while True:
                # Check if sensor is assigned before reading data
                if not self.is_sensor_assigned(self.sensor.machine_id):
                    logging.info(f"Sensor {self.sensor.machine_id} is not assigned to any farm. Skipping data collection.")
                    time.sleep(Config.MEASUREMENT_INTERVAL)
                    continue

                data = self.sensor.read_data()
                if not data:
                    time.sleep(Config.MEASUREMENT_INTERVAL)
                    continue

                if self.has_internet():
                    if self.online.save(data):
                        # Sync offline data if exists
                        offline_data = self.offline.load_all()
                        if not offline_data.empty:
                            if all(self.online.save(row) for _, row in offline_data.iterrows()):
                                self.offline.clear()
                else:
                    self.offline.save(data)

                time.sleep(Config.MEASUREMENT_INTERVAL)

        except KeyboardInterrupt:
            logging.info("System stopped by user")

if __name__ == "__main__":
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[logging.StreamHandler()]
        )
        controller = MainController()
        controller.run()
