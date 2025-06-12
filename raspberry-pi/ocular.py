import html
import threading
import firebase_admin
from firebase_admin import credentials, firestore
import picamera2
import time
import PIL.Image
from dotenv import load_dotenv
import google.generativeai as genai
import googlemaps
import requests
import speech_recognition as sr
import requests
import base64
import pygame
import RPi.GPIO as GPIO
import os 
import sys
import smbus2
import math
import serial
import re

from twilio.rest import Client #SMS Service 
import firebase_admin
from firebase_admin import credentials, firestore

load_dotenv() #load environment variables with API keys and JSON file paths
GPIO.setmode(GPIO.BCM) # Set GPIO Mode (numbering)

#Button Setup
CONTROL_BUTTON = 27
EMERGENCY_BUTTON = 17
LONG_PRESS_DURATION = 2       
TRIPLE_PRESS_WINDOW = 1       
press_times = []
long_press_detected = False
GPIO.setup(CONTROL_BUTTON, GPIO.IN, pull_up_down = GPIO.PUD_UP)
GPIO.setup(EMERGENCY_BUTTON, GPIO.IN, pull_up_down=GPIO.PUD_UP)  # if using pin 17

#Motor Setup
MOTOR_PIN = 18  # PWM pin for motor (connected to transistor base)
MAX_DUTY_CYCLE = 20  # Max PWM value (full vibration)
pwm = GPIO.PWM(MOTOR_PIN, 100) 
pwm.start(0)  # (motor off)

#SMS Setup
SMS_ACCOUNT_SID = os.environ.get("SMS_ACCOUNT_SID")
SMS_AUTH_TOKEN = os.environ.get("SMS_AUTH_TOKEN")   
SMS_SERVICE_ID = os.environ.get("SMS_SERVICE_ID")
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
FIREBASE_CRED_FILE_PATH = os.environ.get("FIREBASE_CRED_FILE_PATH")
RPI_DEV_ID = os.environ.get("RPI_DEV_ID")
cred = credentials.Certificate(FIREBASE_CRED_FILE_PATH)
firebase_admin.initialize_app(cred)
db = firestore.client()
doc_ref = db.collection("devices").document(RPI_DEV_ID)
print("Initializing System") 
def read_from_firestore(field):
    doc = doc_ref.get()
    if doc.exists:
       return doc.to_dict()[field]
    else:
        print("No document found.")
lang = read_from_firestore("lang")

#initialize latitude and longitude so incase GPS is not connected to any satellite, it be detected
Latitude = Longitude = 0
        

#API Keys setup
TEXT_TO_SPEECH_KEY = os.environ.get("TEXT_TO_SPEECH_KEY")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
TRANSLATE_API_KEY = os.environ.get("TRANSLATE_API_KEY")
GMAPS_API_KEY = os.environ.get("GMAPS_API_KEY")


#Setup Pi Camera
picam2 = picamera2.Picamera2()


#Audio Setup
pygame.mixer.pre_init(frequency=22050, size=-16, channels=2, buffer=4096)  
pygame.mixer.init()
def PlayAudio(filename, force_play = True):
    pygame.mixer.music.load(filename)
    pygame.mixer.music.play()
    if force_play == True:
            clock = pygame.time.Clock()
            while pygame.mixer.music.get_busy():
                clock.tick(30)

#Compass Setup 
QMC5883L_ADDRESS = 0x0D
QMC5883L_DATA_OUT = 0x00
QMC5883L_CTRL_REG1 = 0x09
QMC5883L_SET_RESET = 0x0B
bus = smbus2.SMBus(1)
bus.write_byte_data(QMC5883L_ADDRESS, QMC5883L_CTRL_REG1, 0x1D)
bus.write_byte_data(QMC5883L_ADDRESS, QMC5883L_SET_RESET, 0x01)


#Announce that device is ready
PlayAudio("assets/booted.mp3", False)
print("System Ready")

# Analyze Mode, Analyze environment with Gemini Vision  
def analyse(extra = False):
    
    #Take Picture
    picam2.start() # Start the camera
    time.sleep(1.3) # Sleep for some time so camera gets enough time to adjust to the lighting
    picam2.capture_file("/tmp/data.jpg")
    picam2.stop() # Stop camera for power saving
    if extra == True:
        PlayAudio("assets/what_are_you_specifically.mp3", True)
        extraprompt = speech_to_text()
    else:
        extraprompt = ""
    PlayAudio("assets/image_captured.mp3")
    print("Image Captured!")
    
    #Load Picture
    image_path_1 = "/tmp/data.jpg" 
    sample_file_1 = PIL.Image.open(image_path_1)
    genai.configure(api_key=GEMINI_API_KEY) 
    model = genai.GenerativeModel(model_name="gemini-1.5-flash") #model can be updated here, if needed
   
    #Image + Basic prompt + Extra Prompt if provided
    prompt = "I am visually impaired. Please provide concise guidance in under 50 words and issue warnings only if there is a safety or critical concern." + extraprompt
    
    #Output Analyze Result
    response = model.generate_content([prompt, sample_file_1])
    print(html.unescape(translate(response.text)))
    print(response.text)
    PlayAudio("assets/generating_audio.mp3", False)
    text_to_speech(html.unescape(translate(response.text)))
    picam2.stop()

# Translate with google translate API
def translate(text = "Hello, how are you?"):
    if lang != "en":
        API_KEY = TRANSLATE_API_KEY
        url = f"https://translation.googleapis.com/language/translate/v2?key={API_KEY}"
        data = {"q": text, "target": lang}
        response = requests.post(url,json=data)
        translated_text = response.json()["data"]["translations"][0]["translatedText"]
        return translated_text
    else:
        return text

# Returns voice input (Microphone) as text
def speech_to_text():
    try:
        r = sr.Recognizer()
        with sr.Microphone() as source:
            PlayAudio("assets/listening.mp3", False)
            print("Say something...")
            audio = r.listen(source)

        text = r.recognize_google(audio)
        PlayAudio("assets/processing.mp3")
        return text
    except:
        PlayAudio("assets/speak_again.mp3")
        return speech_to_text()

# Reads out text with speakers 
def text_to_speech(text, filename="assets/output.wav", lang="en-US", voice="en-US-Chirp3-HD-Achernar"):
   
    api_key = TEXT_TO_SPEECH_KEY
    url = f"https://texttospeech.googleapis.com/v1/text:synthesize?key={api_key}"
    
    headers = {"Content-Type": "application/json"}
    data = {
        "input": {"text": text},
        "voice": {
            "languageCode": lang,
            "name": voice
        },
        "audioConfig": {
            "audioEncoding": "LINEAR16"
        }
    }

    response = requests.post(url, headers=headers, json=data)

    if response.status_code == 200:
        audio_content = response.json()["audioContent"]
        with open(filename, "wb") as f:
            f.write(base64.b64decode(audio_content))
        print(f"Audio saved to {filename}")
        PlayAudio(filename)
    else:
        print("Error:", response.status_code, response.text)



# Read Raw data from compass module
def read_raw_data():
    data = bus.read_i2c_block_data(QMC5883L_ADDRESS, QMC5883L_DATA_OUT, 6)

    x = (data[1] << 8) | data[0]
    y = (data[3] << 8) | data[2]

    # Convert to signed values
    x = x - 65536 if x > 32767 else x
    y = y - 65536 if y > 32767 else y

    return x, y

# Convert the raw data into heading
def calculate_heading(x, y):
    heading = math.atan2(y, x) * (180.0 / math.pi)
    if heading < 0:
        heading += 360
    return heading

# Convert heading into direction 
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

# Data with each direction and the corresponding heading
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

def get_vibration_intensity(angle_difference):
    # Calculate vibration intensity based on misalignment.
    return int((angle_difference / 180) * (MAX_DUTY_CYCLE))


# Takes in the first instruction from google maps instructions. Extract out the direction (i.e. North, South etc) and align the person with haptics (vibration motor)
def align(instruction1):
    
    print("Reading QMC5883L compass data...\n")
    instruction1 = instruction1.lower()
    for direction, angle in DIRECTION_MAP.items():
            if re.search(rf"\b{direction}\b", instruction1):  # Match whole word
                print(f"Detected direction: {direction.capitalize()} ({angle}°)")
                PlayAudio("assets/compass.mp3")
                while True:
                    x, y = read_raw_data()
                    heading = calculate_heading(x, y)
                    direction = get_compass_direction(heading)

                    angle_difference = abs(angle - heading)             
                                   
                    print(f"Direction: {direction}, Heading: {heading:.2f}°")

                    vibration_intensity = get_vibration_intensity(angle_difference)

                    # Print feedback
                    print(f"Angle: {heading:.2f}° | Direction: {direction} | Target: {angle}° | Misalignment: {angle_difference}° | Vibration: {vibration_intensity}%")

                    # Exit when aligned
                    if angle_difference < 8:  # Consider aligned if within 5 degrees
                        pwm.ChangeDutyCycle(0)  # Stop vibration
                        print("Aligned with target. Exiting.")
                        PlayAudio("assets/compass_exit.mp3")
                        break

                    time.sleep(0.5)


# Get Raw data from GPS Module
def parse_GPGGA(sentence):
    parts = sentence.split(',')
    if len(parts) < 6:
        return None, None

    lat_raw = parts[2]
    lat_dir = parts[3]

    lon_raw = parts[4]
    lon_dir = parts[5]

    if not lat_raw or not lon_raw:
        return None, None

    lat_deg = float(lat_raw[:2])
    lat_min = float(lat_raw[2:])
    lat = lat_deg + (lat_min / 60.0)
    if lat_dir == 'S':
        lat *= -1

    lon_deg = float(lon_raw[:3])
    lon_min = float(lon_raw[3:])
    lon = lon_deg + (lon_min / 60.0)
    if lon_dir == 'W':
        lon *= -1

    return lat, lon

ser = serial.Serial('/dev/serial0', baudrate=9600, timeout=1)

# Returns the coordinates of current location
def get_current_coordinates():
    while True:
        line = ser.readline().decode('ascii', errors='replace')
        if line.startswith('$GPGGA'):
            lat, lon = parse_GPGGA(line)
            if lat and lon:
               # print(lat, lon)
                return lat,lon
            else:
                return 0,0

gmaps = googlemaps.Client(key=GMAPS_API_KEY)

# Returns the coordinates of destination location
def get_destination_coordinates(destination):
    geocode_result = gmaps.geocode(destination)
    if geocode_result:
        location = geocode_result[0]['geometry']['location']
        lat, lng = location['lat'], location['lng']
      
        return f"{lat},{lng}"

# Returns all navigation instructions
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

    return steps 


# Find distance between 2 coordinates
def haversine(coord1, coord2):
    R = 6371  # Earth radius in kilometers
    
    lat1, lon1 = map(math.radians, coord1)  # Convert to radians
    lat2, lon2 = map(math.radians, coord2)
    
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    
    return R * c  # Distance in km

# Navigate Mode, auditory/haptic interface
def navigate():
   
    global Latitude, Longitude
    print("Latitude,", Latitude)
    origin = "%s,%s"%(Latitude, Longitude)
    print("Origin Coords : ", origin)
    vinput = speech_to_text()
    print("Destination : ", vinput)
    destination = get_destination_coordinates(vinput)
    print("Destination Coords : ", destination)
    navigation_steps = get_directions(origin, destination)   
    if navigation_steps != []:
        points = []
        first = False
        
        for i, step in enumerate(navigation_steps):
            instruction = re.sub(r"</?b>|<div.*?>.*?</div>", "", step['instruction'])  # Remove <b> and <div> tags
            instruction = instruction.replace("Rd", "Road")
            instruction = translate(instruction)
            instruction = html.unescape(instruction)
            print(instruction)

            if first == False:
                align(step['instruction'])
            text_to_speech(instruction)
            while True:
                Latitude,Longitude = get_current_coordinates()
                curr = Latitude,Longitude
                print(haversine(curr, step['end_location']))
                if GPIO.input(CONTROL_BUTTON) == GPIO.LOW:
                        print("Navigation Terminated")
                        break
                if haversine(curr, step['end_location']) < 0.0085 :
                        break                                    
            first = True
        text_to_speech("Navigation Ended")      
    else:
        PlayAudio("assets/noroutes.mp3")
        print("No Routes")   



# Update live location in app and database
LOCATION_REFRESH_RATE = 6
def update_live_location():
    global Latitude,Longitude
    while True:
        print(f"Updated Live Location at {time.strftime('%H:%M:%S')}")
        Latitude,Longitude = get_current_coordinates()
        if Latitude != 0:
            doc_ref.update({
                    "latitude" : Latitude,
                    "longitude": Longitude
                })
        time.sleep(LOCATION_REFRESH_RATE) # Updates every 6 seconds
thread = threading.Thread(target=update_live_location, daemon=True)
thread.start() # Live Location THREAD


# --------- COMPLETE EMERGENCY SYSTEM ----------

emergency = False
emergency_threshold = 0
emergency_threshold_increment = 100
emergency_threshold_increment_interval = 30 
max_threshold = 2500
update_threshold = True

def emergency_sms(needhelp):
    contacts =  read_from_firestore("contacts")
    if needhelp:
        for i in contacts:
            print(i["phone_no"], f"Hi {i['contact_name']}")
            sms(i["phone_no"], f"\nHi {i['contact_name']},\n{read_from_firestore('ownerName')} requires your immediate assistance, as no support is available in his vicinity (Emergency!)\nLocation :  https://maps.google.com/?q={Latitude},{Longitude}")       
    else:
        for i in contacts:
            sms(i["phone_no"], f"\nHi {i['contact_name']},\n{read_from_firestore('ownerName')} no longer needs assistance")
        
        
def emergency_thread():
    foundhelp = False
    global emergency_threshold, update_threshold
    start_time2 = time.time()
    start_time1 = time.time()


    while True:
        emergency = read_from_firestore('emergency') #actively update emergency status
        current_time = time.time()
        
        if emergency:
            if update_threshold and current_time - start_time1 >= emergency_threshold_increment_interval :  
                start_time1 = current_time          
                emergency_threshold += emergency_threshold_increment
                doc_ref.update({
                    "emergency_threshold": emergency_threshold 
                    })
                if emergency_threshold >= max_threshold:
                    print("Max threshold reached!")
                    can_update_threshold = False
                    emergency_sms(True)
            print("in emergency!!")

            
            if current_time - start_time2 >= 5:  
                print("Gonna check if anyone is coming to help!")
                start_time2 = current_time
                ishelpcoming = read_from_firestore("isHelpComing")
                if ishelpcoming:
                    helper = read_from_firestore("helper")
                    if foundhelp == False and helper != "":
                        #tell who is coming to help
                        text_to_speech(f"Please wait while {helper} is coming to assist you")
                        print("Found Help")
                        foundhelp = True
                else:
                    print("No Help Found")
                    foundhelp = False
                    
                    
                
     
thread = threading.Thread(target=emergency_thread, daemon=True)
thread.start() # Emergency THREAD


# PASSIVE NO MOTION EMERGENCY, if person don't move for more than 30 minutes, enable emergency mode
CHANGE_THRESHOLD = 5      #  in degrees
TIME_WINDOW      = 30 * 60  # 30 minutes (in seconds)
SAMPLE_INTERVAL  = 1       # in seconds

def no_motion_emergency_system():

    x0, y0 = read_raw_data()
    h0 = calculate_heading(x0, y0)
    t0 = time.time()
    last_heading = h0

    while True:
        time.sleep(SAMPLE_INTERVAL)
        x, y = read_raw_data()
        heading = calculate_heading(x, y)
        now = time.time()
        elapsed = now - t0

        if abs(heading - h0) > CHANGE_THRESHOLD:
            h0 = heading
            t0 = now

        last_heading = heading

        # if our window has slid past 30 minutes without >4° movement
        if elapsed >= TIME_WINDOW:
            print("EMERGENCY: heading stuck within ±5° for 30 minutes!")
            if Latitude != 0:
                    PlayAudio("assets/emergency_on.mp3")
                    print("| Enabled Emergency Mode |")
                    emergency_threshold = 0
                    update_threshold = True
                    emergency = True
                    doc_ref.update({
                        "emergency": True
                    })
                else:
                    print("| No GPS Data to enter emergency mode |")
                    PlayAudio("assets/gps_unavailable.mp3")

            break

thread = threading.Thread(target=no_motion_emergency_system, daemon=True) 
thread.start() # Passive Emergency THREAD





# ------------- Main Interactions ---------------


# Emergency Button --> Triple Press - Toggle Emergency; Long Press - Restart System

def check_long_press(): # Restart system on long press
    start = time.time()
    while GPIO.input(EMERGENCY_BUTTON) == GPIO.LOW:
        if time.time() - start >= LONG_PRESS_DURATION:
            print("Long press detected")
            python = sys.executable
            os.execv(python, [python] + sys.argv)
            break
        time.sleep(0.01)

cooldown_until = 0
def emergency_button_main(channel):
    global press_times, emergency_threshold, update_threshold, emergency, cooldown_until

    now = time.time()

    if GPIO.input(EMERGENCY_BUTTON) == GPIO.LOW:
        threading.Thread(target=check_long_press, daemon=True).start()
    else:
        press_times = [t for t in press_times if now - t < TRIPLE_PRESS_WINDOW]  
        press_times.append(now)
        if len(press_times) == 3: # Toggle emergency on triple press 
            print("Triple quick press detected")
            if now < cooldown_until:
                print("| Cooldown active, ignoring Triple press |")
                return

            cooldown_until = now + 30

            emergency = read_from_firestore("emergency")
            if emergency == False:
                if Latitude != 0:
                    PlayAudio("assets/emergency_on.mp3")
                    print("| Enabled Emergency Mode |")
                    emergency_threshold = 0
                    update_threshold = True
                    emergency = True
                    doc_ref.update({
                        "emergency": True
                    })
                else:
                    print("| No GPS Data to enter emergency mode |")
                    PlayAudio("assets/gps_unavailable.mp3")
            else:
                PlayAudio("assets/emergency_off.mp3")
                print("| Disabled Emergency Mode |")
                emergency = False
                doc_ref.update({
                    "emergency": False
                })
                emergency_sms(False)

            press_times = []
            
            
GPIO.add_event_detect(EMERGENCY_BUTTON, GPIO.BOTH, callback=emergency_button_main, bouncetime=50)

# Control Button - Analyze & Navigate Mode
try:
    while True:
        button_state = GPIO.input(CONTROL_BUTTON)
        if button_state == GPIO.LOW:
            print("Button pressed!")
            command = speech_to_text()
            print(command)
            try:       
                if "custom" in command : 
                    print("| Entered Custom Analyse Mode |")
                    analyse(True)
                elif "analyse" in command :
                    print("| Entered Analyse Mode |")
                    analyse()
                elif "navigate" in command :
                    if Latitude != 0:
                        print("| Entered Navigate Mode |")
                        navigate()
                    else:
                        print("| No GPS Data to enter navigate mode |")
                        PlayAudio("assets/gps_unavailable.mp3")
                else:
                    PlayAudio("assets/invalid_command.mp3")
                
                    
            except Exception as e:
                PlayAudio("assets/invalid_command.mp3")
                print("Error" + e)
                time.sleep(0.2)  
            
   
except KeyboardInterrupt:
    print("Exiting program.")
finally:
    pwm.stop()
    GPIO.cleanup()

