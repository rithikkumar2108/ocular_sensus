import re
import PIL.Image
from picamera2 import Picamera2
from pathlib import Path
import time
import google.generativeai as genai
import RPi.GPIO as GPIO
import serial
from gtts import gTTS
import os
import pygame
import requests
import googlemaps
import speech_recognition as sr
from rapidfuzz import process
import difflib
import math
from qmc5883l import QMC5883L
from twilio.rest import Client
import firebase_admin
from firebase_admin import credentials, firestore
import pynmea2
from dotenv import load_dotenv
import smbus2


enableproximity = False
PROJ_DIR = Path(__file__).parent
load_dotenv()
SMS_ACCOUNT_SID = os.environ.get("SMS_ACCOUNT_SID")
SMS_AUTH_TOKEN = os.environ.get("SMS_AUTH_TOKEN")   
SMS_SERVICE_ID = os.environ.get("SMS_SERVICE_ID")
FIREBASE_CRED_FILE_PATH = os.environ.get("FIREBASE_CRED_FILE_PATH")
RPI_DEV_ID = os.environ.get("RPI_DEV_ID")
GMAPS_API_KEY = os.environ.get("GMAPS_API_KEY")
TRANSLATE_API_KEY = os.environ.get("TRANSLATE_API_KEY")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")

#Initialize Latitude and Longitude
Latitude = Longitude = 0


#Function to send SMS
def sms(number, message):
    account_sid = SMS_ACCOUNT_SID
    auth_token = SMS_AUTH_TOKEN
    client = Client(account_sid, auth_token)
    message = client.messages.create(
      messaging_service_sid=SMS_SERVICE_ID,
      body=message,
      to=number)
    print(message.sid)

#Firebase Setup
cred = credentials.Certificate(FIREBASE_CRED_FILE_PATH)
firebase_admin.initialize_app(cred)
db = firestore.client()
doc_ref = db.collection("devices").document(RPI_DEV_ID)

def read_from_firestore(field):
    doc = doc_ref.get()
    if doc.exists:
       return doc.to_dict()[field]
    else:
        print("No document found.")



def emergency():
    Latitude,Longitude = get_gps_data()
    doc_ref.update({
        "emergency": True,   
        "latitude" : Latitude,
        "longitude": Longitude
    })
    
    contacts =  read_from_firestore("contacts")
    for i in contacts:
        print(i["phone_no"], f"Hi {i['contact_name']}")
        sms(i["phone_no"], f"\nHi {i['contact_name']},\n{read_from_firestore('ownerName')} needs immediate help.\nLocation :  https://maps.google.com/?q={Latitude},{Longitude}")       
picam2 = Picamera2()



lang = read_from_firestore("lang")
print(lang)


# Initialize Google Maps client
gmaps = googlemaps.Client(key=GMAPS_API_KEY)


#Proximity Setup
TRIG = 23  
ECHO = 24  
MOTOR_PIN = 18  # PWM pin for motor (connected to transistor base)

MAX_DISTANCE = 2.5  # Maximum distance (meters)
MIN_DISTANCE = 0.3
MAX_DUTY_CYCLE = 20  # Max PWM value (full vibration)
MIN_DUTY_CYCLE = 0    # No vibration

# Setup GPIO
GPIO.setmode(GPIO.BCM)
GPIO.setup(TRIG, GPIO.OUT)
GPIO.setup(ECHO, GPIO.IN)
GPIO.setup(MOTOR_PIN, GPIO.OUT)

# Set up PWM (50Hz frequency)
pwm = GPIO.PWM(MOTOR_PIN, 50) 
pwm.start(0)  # Start with 0% duty cycle (motor OFF)


QMC5883L_ADDRESS = 0x0D

# Registers
QMC5883L_CTRL_REG1 = 0x09
QMC5883L_SET_RESET = 0x0B
QMC5883L_DATA_OUT = 0x00

# Initialize I2C
bus = smbus2.SMBus(1)

# Initialize QMC5883L
bus.write_byte_data(QMC5883L_ADDRESS, QMC5883L_CTRL_REG1, 0x1D)  # 200Hz, Full Scale, Continuous Mode
bus.write_byte_data(QMC5883L_ADDRESS, QMC5883L_SET_RESET, 0x01)  # Set/Reset Period

def read_raw_data():
    data = bus.read_i2c_block_data(QMC5883L_ADDRESS, QMC5883L_DATA_OUT, 6)

    x = (data[1] << 8) | data[0]
    y = (data[3] << 8) | data[2]
    z = (data[5] << 8) | data[4]

    # Convert to signed values
    x = x - 65536 if x > 32767 else x
    y = y - 65536 if y > 32767 else y
    z = z - 65536 if z > 32767 else z

    return x, y, z

def calculate_heading(x, y):
    heading = math.atan2(y, x) * (180.0 / math.pi)
    if heading < 0:
        heading += 360
    return heading


def get_compass_direction(heading):
    if (337.5 <= heading or heading < 22.5):
        return "North"
    elif 22.5 <= heading < 67.5:
        return "North-East"
    elif 67.5 <= heading < 112.5:
        return "East"
    elif 112.5 <= heading < 157.5:
        return "South-East"
    elif 157.5 <= heading < 202.5:
        return "South"
    elif 202.5 <= heading < 247.5:
        return "South-West"
    elif 247.5 <= heading < 292.5:
        return "West"
    elif 292.5 <= heading < 337.5:
        return "North-West"



while True:
                x, y, z = read_raw_data()
                heading = calculate_heading(x, y)
                direction = get_compass_direction(heading)
            
            

                # Print feedback
                print(direction, heading)


BUTTON_PIN = 17  

GPIO.setmode(GPIO.BCM)  # Use Broadcom numbering
GPIO.setup(BUTTON_PIN, GPIO.IN, pull_up_down=GPIO.PUD_UP)  # Enable pull-up resistor

pygame.mixer.init()

def PlayAudio(filename):
    pygame.mixer.stop()
    pygame.mixer.music.load(filename)
    pygame.mixer.music.play()
    
PlayAudio(PROJ_DIR / "assets/booted.mp3")
def speechtotext():
    recognizer = sr.Recognizer()
    with sr.Microphone() as source:
        print("Listening for 5 seconds... Speak now!")
        recognizer.adjust_for_ambient_noise(source)
        try:
            audio = recognizer.listen(source, timeout=10 )
            PlayAudio(PROJ_DIR / "assets/processing.mp3")
            print("Processing...")
            destination = recognizer.recognize_google(audio)
            print(f"Destination recognized: {destination}")
            return destination
        except sr.UnknownValueError:
            print("Could not understand the audio.")
            return ""
        except sr.RequestError:
            print("Error with the speech recognition service.")
            return ""
        except sr.exceptions.WaitTimeoutError:
            print("Timeout")
            return ""
def text_to_speech(text,  speed=1.5):
    tts = gTTS(text=text, lang=lang, slow=False)
   
    PlayAudio(PROJ_DIR / "assets/generating_audio.mp3")
    
    tts.save(PROJ_DIR / "assets/output.mp3")

    os.system(f"ffmpeg -i {PROJ_DIR}/assets/output.mp3 -filter:a 'atempo={speed}' -vn {PROJ_DIR}/assets/adjusted_output.mp3 -y")

    # Play the modified audio
    
    PlayAudio(PROJ_DIR / "assets/adjusted_output.mp3")

    while pygame.mixer.music.get_busy():
        pass

def translate(text = "Hello, how are you?"):

    API_KEY = TRANSLATE_API_KEY 


    url = f"https://translation.googleapis.com/language/translate/v2?key={API_KEY}"
    data = {"q": text, "target": lang}

    response = requests.post(url,json=data)
    translated_text = response.json()["data"]["translations"][0]["translatedText"]

    return translated_text




def get_destination_coordinates(destination):
    geocode_result = gmaps.geocode(destination)
    if geocode_result:
        location = geocode_result[0]['geometry']['location']
        lat, lng = location['lat'], location['lng']
      
        return f"{lat},{lng}"





#Analyze with GEMINI

def analyse(extra = False):
    picam2.start()
    time.sleep(2)
    picam2.capture_file("/tmp/data.jpg")
    picam2.stop()
    if extra == True:
        PlayAudio(PROJ_DIR / "assets/what_are_you_specifically.mp3")
        time.sleep(1)
        extraprompt = speechtotext()
    else:
        extraprompt = ""
    PlayAudio(PROJ_DIR / "assets/image_captured.mp3")

    print("Image Captured!")
    image_path_1 = "/tmp/data.jpg" 



    sample_file_1 = PIL.Image.open(image_path_1)
    genai.configure(api_key=GEMINI_API_KEY)

    model = genai.GenerativeModel(model_name="gemini-1.5-flash")

    prompt = "I am blind. Guide me in less than 50 words and warn if anything is concerning." + extraprompt
    
    response = model.generate_content([prompt, sample_file_1])

    print(translate(response.text))
    print(response.text)
    text_to_speech(translate(response.text), speed=1.5)
    
        


gps_port = "/dev/serial0"  
baud_rate = 9600

def get_gps_data():
    try:
        # Open serial port
        with serial.Serial(gps_port, baud_rate, timeout=1) as ser:
            while True:
                line = ser.readline().decode("utf-8", errors="ignore")  # Read and decode GPS data
                if line.startswith("$GPGGA") or line.startswith("$GPRMC"):  # GGA or RMC sentence
                    try:
                        msg = pynmea2.parse(line)  # Parse NMEA sentence
                        latitude = msg.latitude
                        longitude = msg.longitude
                        return latitude,longitude
                          # Stop after getting valid coordinates
                    except pynmea2.ParseError:
                        continue
    except serial.SerialException as e:
        print(f"Error: {e}")



import requests


DIRECTION_MAP = {
    "north": 0,
    "north-east": 45,
    "northeast": 45,
    "east": 90,
    "south-east": 135,
    "southeast": 135,
    "south": 180,
    "south-west": 225,
    "southwest": 225,
    "west": 270,
    "north-west": 315,
    "northwest": 315
}

def get_directions(origin, destination):
    url = f"https://maps.googleapis.com/maps/api/directions/json?origin={origin}&destination={destination}&mode=walking&key={GMAPS_API_KEY}"
    response = requests.get(url).json()
    steps = []
    if response["routes"] != []:
        for step in response["routes"][0]["legs"][0]["steps"]:
                start_lat = step["start_location"]["lat"]
                start_lon = step["start_location"]["lng"]
                end_lat = step["end_location"]["lat"]
                end_lon = step["end_location"]["lng"]

                steps.append({
                    "instruction": step["html_instructions"],
                    "start_location": (start_lat, start_lon),
                    "end_location": (end_lat, end_lon)
                })

    return steps  # Returns list of steps

#Function to find distance between 2 coordinates
def haversine(coord1, coord2):
    R = 6371  # Earth radius in kilometers
    
    lat1, lon1 = map(math.radians, coord1)  # Convert to radians
    lat2, lon2 = map(math.radians, coord2)
    
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    
    return R * c  # Distance in km

def navigate():

    Latitude,Longitude = get_gps_data()

    origin = f"{Latitude},{Longitude}"
    vinput ="Shiv Nadar University Chennai" # speechtotext()
    print("Origin Coords : ", origin)
    if vinput != "":
        destination =get_destination_coordinates(vinput)
        print("Destination Coords : ", destination)

        navigation_steps = get_directions(origin, destination)
        if navigation_steps != []:
            points = []
            first = False
            for i, step in enumerate(navigation_steps):
                instruction = re.sub(r"</?b>|<div.*?>.*?</div>", "", step['instruction'])  # Remove <b> and <div> tags
                if first == False:
                    align(step['instruction'])
                text_to_speech(instruction, 1)
                
                while True:
                    Latitude,Longitude = get_gps_data()
                    curr = Latitude,Longitude
                    print(haversine(curr, step['end_location']))
                    if GPIO.input(BUTTON_PIN) == GPIO.LOW:
                        print("Navigation Terminated")
                        break
                    if haversine(curr, step['end_location']) < 0.0085 :
                        break
                        
                first = True
            text_to_speech("Navigation Ended")      
        else:
            PlayAudio(PROJ_DIR / "assets/noroutes.mp3")
            print("No Routes")
            
def get_vibration_intensity(angle_difference):
    """Calculate vibration intensity based on misalignment."""
    return int((angle_difference / 180) * (MAX_DUTY_CYCLE))

def align(sentence):
    global enableproximity
    """Extracts direction from input sentence and calls align(target_heading)."""
    sentence = sentence.lower()
    PlayAudio(PROJ_DIR / "assets/compass.mp3")
    if enableproximity == True:
        isprox = True
    else:
        isprox = False
    enableproximity = False
    # Find direction keyword in the sentence
    for direction, angle in DIRECTION_MAP.items():
        if re.search(rf"\b{direction}\b", sentence):  # Match whole word
            print(f"Detected direction: {direction.capitalize()} ({angle}°)")
            while True:
                x, y, z = read_raw_data()
                heading = calculate_heading(x, y)
                direction = get_compass_direction(heading)
            
                angle_difference = abs(angle - heading)

                vibration_intensity = get_vibration_intensity(angle_difference)

                # Print feedback
                print(f"Angle: {heading:.2f}° | Direction: {direction} | Target: {angle}° | Misalignment: {angle_difference}° | Vibration: {vibration_intensity}%")

                # Exit when aligned
                if angle_difference < 8:  # Consider aligned if within 5 degrees
                    pwm.ChangeDutyCycle(MIN_DUTY_CYCLE)  # Stop vibration
                    print("Aligned with target. Exiting.")
                    if isprox == True:
                        enableproximity = True
                    break

                time.sleep(0.1)    

    



valid_commands = [
    "enable proximity",
    "disable proximity",
    "analyse",
    "custom analyse",
    "navigate",
    "emergency"
]


def get_closest_command(user_input):
    """Find the best matching command based on partial input."""
    user_input = user_input.lower().strip()
    if user_input != "":
        if user_input in valid_commands:
            return user_input

        for command in valid_commands:
            if command in user_input:
                return command

        closest_match = difflib.get_close_matches(user_input, valid_commands, n=1, cutoff=0.4)
        if closest_match:
            return closest_match[0]

        # Step 4: No match found
    return "Invalid command"




flag = False

# Compass - STILL - Emergency
CHANGE_THRESHOLD = 2  # Degrees (small changes ignored)

#AUTO EMERGENCY, TIME RELATED VARSs
TIME_LIMIT = 60  # Wait 60 Seconds
CHECK_INTERVAL = 1  # Check every 1 second
previous_heading = None
stable_count = 0  # Counter for stable readings

try:

    last_run = time.time()  # Time var for live tracking


    next_run = time.time() + 0.5  # Time var for ultrasonic sensor

    last_check_time = time.time()  # Tracks last check time for compass module

    while True:
    
        current_time = time.time() #Live Time var for compass module

    # Check heading only if 1 second has passed
        if current_time - last_check_time >= CHECK_INTERVAL:
            last_check_time = current_time  # Update last check time
            
            x, y, z = read_raw_data()
            current_heading = calculate_heading(x, y)

            if previous_heading is not None:
                if abs(current_heading - previous_heading) < CHANGE_THRESHOLD:
                    stable_count += 1
                else:
                    stable_count = 0  # Reset counter if heading changes

                if stable_count >= TIME_LIMIT:
                    
                    emergency()

            previous_heading = current_heading
        
        if GPIO.input(BUTTON_PIN) == GPIO.LOW and flag == False:  # Button pressed
            Flag = True
            print("Button Pressed!")
            time.sleep(0.2)  # Debounce delay
            PlayAudio(PROJ_DIR / "assets/listening.mp3")

            
            command = get_closest_command(speechtotext())
            if command == "enable proximity":
                enableproximity = True
                print("Proximity Enabled")
                PlayAudio(PROJ_DIR / "assets/proximity_enabled.mp3")
                
            elif command == "disable proximity":
                enableproximity = False
                PlayAudio(PROJ_DIR / "assets/proximity_disabled.mp3")

                print("Proximity Disabled")
            
            elif command == "analyse":
                analyse(False)
            elif command == "custom analyse":
                analyse(True)
            elif command == "navigate":
                navigate()
            elif command == "emergency":
                PlayAudio(PROJ_DIR / "assets/emergency.mp3")
                emergency()
                
            else:
                print("Invalid Command")
                PlayAudio(PROJ_DIR / "assets/invalid.mp3")

        
        if time.time() - last_run >= 2:  # every 2 second
                Latitude, Longitude  = get_gps_data()
                doc_ref.update({
                   "latitude": Latitude, 
                   "longitude": Longitude
                })
                
                lang = read_from_firestore("lang")                
                last_run = time.time()  # Update last run time
            
        if time.time() >= next_run and enableproximity:
                    print("Executing command...")
                    GPIO.output(TRIG, True)
                    time.sleep(0.00001)  # 10µs pulse
                    GPIO.output(TRIG, False)
            
                    start_time = time.time()
                    stop_time = time.time()
            
                    while GPIO.input(ECHO) == 0:
                        start_time = time.time()
            
                    while GPIO.input(ECHO) == 1:
                        stop_time = time.time()
            
                        # Calculate distance in cm (time * speed of sound / 2)
                    elapsed_time = stop_time - start_time
                    distance_cm = (elapsed_time * 34300) / 2  # Speed of sound = 343m/s
            
                        # Convert to meters
                    distance = distance_cm / 100
            
                    distance = round(distance, 2)      
                         
                    if distance >= MAX_DISTANCE:
                        duty_cycle = MIN_DUTY_CYCLE  # No vibration
                    elif distance <= (MIN_DISTANCE):  # Small percentage of max distance
                        duty_cycle =  MAX_DUTY_CYCLE  # Max vibration
                    else:
                        normalized = (distance - MIN_DISTANCE) / (MAX_DISTANCE - MIN_DISTANCE)
                        duty_cycle = MAX_DUTY_CYCLE * (1 - normalized)  # Inverted for intensity
                        duty_cycle =  round(duty_cycle, 2)
            
                    pwm.ChangeDutyCycle(duty_cycle)
                        
                    print(f"Distance: {distance}m | Motor PWM: {duty_cycle}%")
                    time.sleep(0.5)
                    next_run = time.time() + 0.5
        flag = False

        
except KeyboardInterrupt:
    print("Measurement stopped by user")
    pwm.stop()
    GPIO.cleanup()

