import os
import sys
import pyaudio
from six.moves import queue
from google.cloud import speech
from google.oauth2 import service_account
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
import base64
import wave
import io
import pygame
import RPi.GPIO as GPIO
import smbus2
import math
import serial
from queue import Queue
import re
from pathlib import Path
from mutagen import File as MutagenFile

from twilio.rest import Client #SMS Service
import firebase_admin
from firebase_admin import credentials, firestore

load_dotenv() #load environment variables with API keys and JSON file paths
ASSETS_DIR = Path(__file__).resolve().parent / "assets"
os.environ["SDL_AUDIODRIVER"] = "alsa"
GPIO.setmode(GPIO.BCM) # Set GPIO Mode (numbering)

p = pyaudio.PyAudio()

# Get default input device
try:
    default_device = p.get_default_input_device_info()
    print("🔍 Default input device info:")
    print(f"  Name: {default_device['name']}")
    print(f"  Max input channels: {default_device['maxInputChannels']}")
    print(f"  Default sample rate: {default_device['defaultSampleRate']}")
except Exception as e:
    print("❌ Could not get default input device:", e)
    p.terminate()
    exit()

# Test common sample rates
sample_rates_to_test = [8000, 16000, 22050, 32000, 44100, 48000, 96000]

print("\n🔁 Testing supported sample rates...")
for rate in sample_rates_to_test:
    try:
        stream = p.open(
            format=pyaudio.paInt16,
            channels=1,
            rate=rate,
            input=True,
            frames_per_buffer=1024
        )
        stream.close()
        print(f"✅ Supported: {rate} Hz")
    except Exception as e:
        print(f"❌ Unsupported: {rate} Hz → {e}")

p.terminate()

#Button Setup
CONTROL_BUTTON = 27
EMERGENCY_BUTTON = 17
LONG_PRESS_DURATION = 2       
TRIPLE_PRESS_WINDOW = 1       
press_times = []
long_press_detected = False

GPIO.setup(CONTROL_BUTTON, GPIO.IN, pull_up_down = GPIO.PUD_UP)
GPIO.setup(EMERGENCY_BUTTON, GPIO.IN, pull_up_down=GPIO.PUD_UP)  # if using pin 17

#Load environment variables
SMS_ACCOUNT_SID = os.environ.get("SMS_ACCOUNT_SID")
SMS_AUTH_TOKEN = os.environ.get("SMS_AUTH_TOKEN")   
SMS_SERVICE_ID = os.environ.get("SMS_SERVICE_ID")
FIREBASE_CRED_FILE_PATH = os.environ.get("FIREBASE_CRED_FILE_PATH")
SPEECH_TO_TEXT_CRED_FILE_PATH =  os.environ.get("SPEECH_TO_TEXT_CRED_FILE_PATH")
TEXT_TO_SPEECH_KEY = os.environ.get("TEXT_TO_SPEECH_KEY")
RPI_DEV_ID = os.environ.get("RPI_DEV_ID")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
GMAPS_API_KEY = os.environ.get("GMAPS_API_KEY")
TRANSLATE_API_KEY = os.environ.get("TRANSLATE_API_KEY")

#Setup Pi Camera
picam2 = picamera2.Picamera2()

#Audio setup
VOLUME = 1
def reset_mixer():
    pygame.mixer.quit()
    pygame.mixer.pre_init(frequency=16000, size=-16, channels=2, buffer=4096)
    pygame.mixer.init()
    pygame.mixer.music.set_volume(VOLUME)  

#Function to get the duration of the audio
def get_audio_duration(filename):
    """Get duration of audio file using mutagen."""
    try:
        audio = MutagenFile(filename)
        return audio.info.length
    except Exception as e:
        print(f"❌ Failed to get duration: {e}")
        return 0

#Function to play the audio
def PlayAudio(filename, force_play=True):
    if not os.path.exists(filename):
        print(f"❌ File not found: {filename}")
        return

    # Get duration
    duration = get_audio_duration(filename)
    if duration == 0:
        print("⚠️ Warning: Couldn't detect duration. Using get_busy fallback.")

    # Init mixer if not already
    reset_mixer()
    pygame.mixer.music.load(filename)
    pygame.mixer.music.play()
    print(f"▶️ Playing: {filename}")

    if force_play:
        if duration > 0:
            time.sleep(duration+ 0.15) 
            

        else:
            # fallback if duration fails
            clock = pygame.time.Clock()
            while pygame.mixer.music.get_busy():
                clock.tick(30)

    print("✅ Done.")

# Audio recording parameters
RATE = 16000
CHUNK = int(RATE / 10)  # 100ms

class MicrophoneStream:
    def __init__(self, rate, chunk):
        self.rate = rate
        self.chunk = chunk
        self._buff = queue.Queue()
        self.closed = True

    def __enter__(self):
        self.audio_interface = pyaudio.PyAudio()
        self.stream = self.audio_interface.open(
            format=pyaudio.paInt16,
            channels=1,
            rate=self.rate,
            input=True,
            frames_per_buffer=self.chunk,
            stream_callback=self._fill_buffer,
        )
        self.closed = False
        return self

    def __exit__(self, type, value, traceback):
        self.stream.stop_stream()
        self.stream.close()
        self.closed = True
        self._buff.put(None)
        self.audio_interface.terminate()

    def _fill_buffer(self, in_data, frame_count, time_info, status_flags):
        self._buff.put(in_data)
        return None, pyaudio.paContinue

    def generator(self):
        while not self.closed:
            chunk = self._buff.get()
            if chunk is None:
                return
            data = [chunk]

            while True:
                try:
                    chunk = self._buff.get(block=False)
                    if chunk is None:
                        return
                    data.append(chunk)
                except queue.Empty:
                    break

            yield b"".join(data)


#Firebase setup

cred = credentials.Certificate(FIREBASE_CRED_FILE_PATH)
firebase_admin.initialize_app(cred)
db = firestore.client()
doc_ref = db.collection("devices").document(RPI_DEV_ID)
helpers_ref = db.collection("devices").document(RPI_DEV_ID).collection("helpers")

print("Initializing System") 
#Funtion to read from firebase
def read_from_firestore(field):
    doc = doc_ref.get()
    if doc.exists:
       return doc.to_dict()[field]
    else:
        print("No document found.")
language_code = read_from_firestore("lang") #For text to speech
navigation_tags = read_from_firestore("navigation_tags")
contacts =  read_from_firestore("contacts")
ownerName = read_from_firestore("ownerName")
lang = language_code[:2] #For translation

#initialize latitude and longitude so incase GPS is not connected to any satellite, it be detected
Latitude = Longitude = 0

#Function to find the voluntary helper
def findhelper():
    docs = helpers_ref.where('isactive', '==', True).limit(1).stream()   
    for doc in docs:
        return doc.to_dict()
    if docs == []:
        return None


print(findhelper()["name"])

#Translation Setup
def translate(text = "Hello, how are you?"):

    API_KEY = TRANSLATE_API_KEY


    url = f"https://translation.googleapis.com/language/translate/v2?key={API_KEY}"
    data = {"q": text, "target": lang}

    response = requests.post(url,json=data)
   
    translated_text = response.json()["data"]["translations"][0]["translatedText"]

    return html.unescape(translated_text)
def text_to_speech(text, filename="output.wav", voice="-Chirp3-HD-Leda"):
    api_key = TEXT_TO_SPEECH_KEY
    url = f"https://texttospeech.googleapis.com/v1/text:synthesize?key={api_key}"
    voice = language_code + voice

    headers = {"Content-Type": "application/json"}
    data = {
        "input": {"text": text},
        "voice": {
            "languageCode": language_code,
            "name": voice
        },
        "audioConfig": {
            "audioEncoding": "LINEAR16",  # raw PCM
            "sampleRateHertz": 16000,
            "volumeGainDb": 3
        }
    }

    response = requests.post(url, headers=headers, json=data)

    if response.status_code == 200:
        raw_audio = base64.b64decode(response.json()["audioContent"])

        output_path = ASSETS_DIR / filename
        # Now wrap that raw LINEAR16 in a proper WAV file
        with wave.open(str(output_path), "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)  # LINEAR16 = 16-bit = 2 bytes
            wav_file.setframerate(16000)
            wav_file.writeframes(raw_audio)

        return output_path
    else:
        print("❌ Error:", response.status_code, response.text)

#Function to update the progress     
def update_progress(task_name, current, total, bar_length=40):
    progress = current / total
    filled = int(bar_length * progress)
    bar = '█' * filled + '-' * (bar_length - filled)
    sys.stdout.write(f"\r[{bar}] {int(progress * 100)}% - {task_name.ljust(30)}")
    sys.stdout.flush()

#Download offline audio
def download_offline_audio():
    # List of (filename, prompt_text)
    audios = [
        ("booted", "System Booted."),
        ("destination_ask", "What is your destination?"),
        ("calibrate_compass", "Please turn around to calibrate compass."),
        ("calibrated_compass", "Compass has been Calibrated."),
        ("compass_enter", "Entering compass mode."),
        ("compass_exit", "Exitting compass mode."),
        ("emergency_on", "Emergency mode activated."),
        ("emergency_off", "Emergency mode deactivated."),
        ("generating_audio", "Generating audio."),
        ("gps_unavailable", "GPS signal unavailable. Searching for satellites."),
        ("image_captured", "Image captured. Beginning to analyze the environment."),
        ("listening", "Listening."),
        ("no_routes_found", "Invalid Destination. Try repeating the destination name."),
        ("restart", "Restart sequence initiated for ocular sensus."),
        ("speak_again", "Couldn't understand. Please speak again."),
        ("invalid_command", "Invalid command."), 
        ("navigation_ended", "navigation ended."), 
        ("cooldown", "Cooldown active, ignoring Triple press."), 
        ("custom_ask", "What would you like to know specifically?")
    ]

    total = len(audios)
    print("Downloading audios for offline usage")
    for i, (filename, prompt) in enumerate(audios, 1):

        output_path = ASSETS_DIR / f"{language_code}_{filename}.wav"
        if output_path.exists():
            # File exists, just use the existing path
            file_path = output_path
        else:

            # File doesn't exist, generate it
            translated = translate(prompt)
            file_path = text_to_speech(translated, output_path)

        # Assign to variable dynamically
        globals()[f"{filename}_audio_path"] = file_path
        update_progress(f"{filename}_audio_path", i, total)

    print("\nAll offline audio files ready and variables set.")



download_offline_audio()
print("System Booted")
PlayAudio(booted_audio_path)

#Speech-to-Text setup

def speech_to_text(audio_path = listening_audio_path):
    s= time.time()
    # Load credentials directly from JSON
    credentials = service_account.Credentials.from_service_account_file(SPEECH_TO_TEXT_CRED_FILE_PATH)
    client = speech.SpeechClient(credentials=credentials)

    config = speech.RecognitionConfig(
        encoding=speech.RecognitionConfig.AudioEncoding.LINEAR16,
        sample_rate_hertz=RATE,
        language_code="en-US",
    )

    streaming_config = speech.StreamingRecognitionConfig(
        config=config,
        interim_results=True,
    )
    print("time taken =", -(s-time.time()))
    try:
        PlayAudio(audio_path, True)
        with MicrophoneStream(RATE, CHUNK) as stream:
            audio_generator = stream.generator()
            requests = (speech.StreamingRecognizeRequest(audio_content=content)
                        for content in audio_generator)
            print("Say something...")
            responses = client.streaming_recognize(streaming_config, requests)

            for response in responses:
                    if not response.results:
                        continue

                    result = response.results[0]
                    if not result.alternatives:
                        continue

                    transcript = result.alternatives[0].transcript
                    print("You said:", transcript)

                    if result.is_final:
                        print("Finally, You said:", transcript)

                        return transcript
    except:

        return speech_to_text(speak_again_audio_path)

#Function to analyse the environment
def analyse(extra = False):
    if extra == True:
        extraprompt = speech_to_text(custom_ask_audio_path)
    else:
        extraprompt = ""
    picam2.capture_file("/tmp/data.jpg")
    stop_camera_async()
    PlayAudio(image_captured_audio_path, False)

    print("Image Captured!")
    
    image_path_1 = "/tmp/data.jpg" 


    sample_file_1 = PIL.Image.open(image_path_1)
    
    genai.configure(api_key=GEMINI_API_KEY)

    model = genai.GenerativeModel(model_name="gemini-1.5-flash")

    prompt = extraprompt + "My Name is" + ownerName + ".You are Ocular Sensus. I am blind and using an AI personal assistant device named Ocular Sensus (You). Provide clear, step-by-step guidance in under 50 words. Always clarify and describe my current location or context so I have an idea of where I am.. Prioritize clarity and accessibility. Warn only if something is harmful or unsafe. Dont ask me questions" 
    
    response = model.generate_content([prompt, sample_file_1])
    response_text= response.text.replace("*","")
    translated_response_text = translate(response_text)
    print(translated_response_text)
    print(response_text)
    PlayAudio(generating_audio_audio_path, False)
    PlayAudio(text_to_speech(translated_response_text))


# Compass setup

QMC5883L_ADDRESS = 0x0D

QMC5883L_DATA_OUT = 0x00
QMC5883L_CTRL_REG1 = 0x09
QMC5883L_SET_RESET = 0x0B

# Initialize I2C bus
bus = smbus2.SMBus(1)

# Initialize QMC5883L: 200Hz output, 2G range, continuous mode
bus.write_byte_data(QMC5883L_ADDRESS, QMC5883L_CTRL_REG1, 0x1D)
bus.write_byte_data(QMC5883L_ADDRESS, QMC5883L_SET_RESET, 0x01)

#caliberating the compass
def calibrate(duration=10 ):
    print("Calibrating... Rotate sensor slowly in all directions.")
    PlayAudio(calibrate_compass_audio_path)
    PlayAudio(ASSETS_DIR/"Countdown.wav", False)
    
    start_time = time.time()


    x_vals, y_vals, z_vals = [], [], []

    while time.time() - start_time < duration:
        data = bus.read_i2c_block_data(QMC5883L_ADDRESS, QMC5883L_DATA_OUT, 6)
        x = data[1] << 8 | data[0]
        y = data[3] << 8 | data[2]
        z = data[5] << 8 | data[4]

        # Convert to signed
        x = x - 65536 if x >= 32768 else x
        y = y - 65536 if y >= 32768 else y
        z = z - 65536 if z >= 32768 else z
        x_vals.append(x)
        y_vals.append(y)
        z_vals.append(z)
        time.sleep(0.05)

    offsets = {
        'x_offset': (max(x_vals) + min(x_vals)) / 2,
        'y_offset': (max(y_vals) + min(y_vals)) / 2,
        'z_offset': (max(z_vals) + min(z_vals)) / 2,
    }

    print("Calibration complete.")
    print("Offsets:", offsets)
    PlayAudio(calibrated_compass_audio_path)
    return offsets

offsets =  {'x_offset': -1763.0, 'y_offset': -391.0, 'z_offset': 1273.0} #calibrate()

#Read raw data from Compass module
def read_raw_data():
    data = bus.read_i2c_block_data(QMC5883L_ADDRESS, QMC5883L_DATA_OUT, 6)

    x = (data[1] << 8) | data[0]
    y = (data[3] << 8) | data[2]
    z = (data[5] << 8) | data[4]

    # Convert to signed values
    x = x - 65536 if x > 32767 else x
    y = y - 65536 if y > 32767 else y
    z = z - 65536 if z > 32767 else z
    x -= offsets['x_offset']
    y -= offsets['y_offset']
    return x, y, z

#Covert the raw data into heading
def calculate_heading(x, y):
    heading = math.atan2(y, x) * (180.0 / math.pi)
    if heading < 0:
        heading += 360
    return heading

#Convert heading into direction
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

def get_compass_intensity(angle_difference):
    # Calculate volume intensity based on misalignment.
    return (angle_difference / 180) * VOLUME
    
# Takes in the first instruction from google maps instructions. Extract out the direction (i.e. North, South etc) and align the person with volume(speaker)
def align(instruction1):
    

    print("Reading QMC5883L compass data...\n")
    instruction1 = instruction1.lower()
    for direction, angle in DIRECTION_MAP.items():
            if re.search(rf"\b{direction}\b", instruction1):  # Match whole word
                print(f"Detected direction: {direction.capitalize()} ({angle}°)")

                PlayAudio(compass_enter_audio_path)
                while True:
                    x, y, z = read_raw_data()
                    heading = calculate_heading(x, y)
                    direction = get_compass_direction(heading)

                    angle_difference = abs(angle - heading)             
                                   

                    compass_intensity = get_compass_intensity(angle_difference)
                    pygame.mixer.music.load(ASSETS_DIR / "tick.mp3")    
                    pygame.mixer.music.set_volume(compass_intensity * VOLUME)
                    pygame.mixer.music.play(loops=-1)
                    # Print feedback
                    msg = f"Misalignment: {angle_difference}° |Angle: {heading:.2f}° | Direction: {direction} | Target: {angle}° |  Intensity: {compass_intensity}%"
                    
                    sys.stdout.write('\r' + msg + ' ' * 10)  # Overwrite previous text
                    sys.stdout.flush()

                    
                    if GPIO.input(CONTROL_BUTTON) == GPIO.LOW:
                        pygame.mixer.music.stop()
                        print("Force Stop")
                        PlayAudio(compass_exit_audio_path)
                        return
            
                    # Exit when aligned
                    if angle_difference < 20:  # Consider aligned if within 20 degrees
                        print("Aligned with target. Exiting.")
                        PlayAudio(compass_exit_audio_path)
                        break

    
gmaps = googlemaps.Client(key=GMAPS_API_KEY)

#Get raw data from GPS module
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

#Returns the coordinates of the current location
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

#Returns the coordinates of the destination
def get_destination_coordinates(destination):
    geocode_result = gmaps.geocode(destination)
    if geocode_result:
        location = geocode_result[0]['geometry']['location']
        lat, lng = location['lat'], location['lng']
      
        return f"{lat},{lng}"

#Returns all navigation instructions
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

# Navigate Mode, auditory interface
navigate_destination = ""
def navigate(secondtime = False):
   
    global Latitude, Longitude, navigate_destination    
    print("Latitude,", Latitude)
    origin = "%s,%s"%(Latitude, Longitude)
    print("Origin Coords : ", origin)
    if secondtime == False:
       vinput = speech_to_text(destination_ask_audio_path)
    else:
        vinput = speech_to_text(no_routes_found_audio_path)
    navigate_destination = vinput.lower()
    if "terminate" in navigate_destination:
        PlayAudio(navigation_ended_audio_path)
        print("Navigation Terminated")
        return

    for i in navigation_tags:
        if i.lower() in navigate_destination:
            navigate_destination = navigation_tags[i]

    print("Destination : ", navigate_destination)
    destination = get_destination_coordinates(navigate_destination)
    print("Destination Coords : ", destination)
    navigation_steps = get_directions(origin, destination)   
    if navigation_steps != []:
        points = []
        first = True
        
        for i, step in enumerate(navigation_steps):
            instruction = re.sub(r"</?b>|<div.*?>.*?</div>", "", step['instruction'])  # Remove <b> and <div> tags
            instruction = instruction.replace("Rd", "Road")
            instruction = translate(instruction)
            
            print(instruction)
            if first == True:
                align(step['instruction'])
                PlayAudio(text_to_speech("To go to "+ navigate_destination + " ," +instruction))
            else:
                PlayAudio(text_to_speech(instruction))
            while True:

                 #eval(input("Coordinates: " )) 
                curr = Latitude,Longitude
              #  print(f"Delta Distance: {haversine(curr, step['end_location'])}") 
                distance = haversine(curr, step['end_location'])
                msg = f"Delta Distance: {distance}"
                sys.stdout.write('\r' + msg + ' ' * 10)  # Overwrite previous text
                sys.stdout.flush()

                if GPIO.input(CONTROL_BUTTON) == GPIO.LOW:
                    print("Button pressed!")  
                    start_camera_async()
                    command = speech_to_text().lower()
                    print("Command", command)
                    if "custom" in command : 
                        print("| Entered Custom Analyse Mode |")
                        analyse(True)
                    elif "analyze" in command or "analyse" in command  :
                        print("| Entered Analyse Mode |")
                        analyse()
                    elif "terminate" in command :
                        print("Navigation Terminated")
                        navigate_destination = ""
                        PlayAudio(navigation_ended_audio_path)
                        stop_camera_async()
                        return
                    else:
                        PlayAudio(invalid_command_audio_path)
                        stop_camera_async()
                if haversine(curr, step['end_location']) < 0.0085 :
                        
                        break                                    
            first = False
        navigate_destination = ""
        PlayAudio(navigation_ended_audio_path)
    else:
        navigate(True)
        print("No Routes")   

# Update live location in app and database
LOCATION_REFRESH_RATE = 5
def update_live_location():
    global Latitude,Longitude
    last_update_time = -LOCATION_REFRESH_RATE #so it gets updated the first time

    while True:
        # Runs every second
        Latitude, Longitude = get_current_coordinates()

        current_time = time.time()

        if Latitude != 0 and (current_time - last_update_time) >= LOCATION_REFRESH_RATE:
            print(f"Updated Live Location at {time.strftime('%H:%M:%S')}")
            doc_ref.update({
                "latitude": Latitude,
                "longitude": Longitude,
                "nav": navigate_destination
            })
            last_update_time = current_time

        time.sleep(0.5)  # Sleep 0.5s for coordinate fetch

# Start the 6-second task in a background thread
thread = threading.Thread(target=update_live_location, daemon=True)
thread.start()


# --------- COMPLETE EMERGENCY SYSTEM ----------

emergency = False #Global Emergency Status, Read Only
force_emergency = False
emergency_threshold = 0 #Global Emergency Threshold Radius, Read Only
emergency_threshold_initial = 1000
emergency_threshold_increment = 100
emergency_threshold_increment_interval = 20 
max_threshold = 2500
update_threshold = True

#Functions to send SMS
def sms(number, message):
    account_sid = SMS_ACCOUNT_SID
    auth_token = SMS_AUTH_TOKEN
    client = Client(account_sid, auth_token)
    message = client.messages.create(
      messaging_service_sid=SMS_SERVICE_ID,
      body=message,
      to=number)
    print(message.sid)

#Function to send Emergency SMS
def emergency_sms(needhelp):
    if needhelp:
        for i in contacts:
            print(i["phone_no"], f"Hi {i['contact_name']}")
            sms(i["phone_no"], f"\nHi {i['contact_name']},\n{ownerName} requires your immediate assistance, as no support is available in his vicinity (Emergency!)\nLocation :  https://maps.google.com/?q={Latitude},{Longitude}")       
    else:
        for i in contacts:
            sms(i["phone_no"], f"\nHi {i['contact_name']},\n{ownerName} no longer needs assistance")
        
#Emergency thread
def emergency_thread():
    foundhelp = False
    global emergency_threshold, update_threshold,force_emergency
    start_time2 = time.time()
    start_time1 = time.time()
    while True:
        if force_emergency == True:
            emergency = True
            force_emergency = False
        else:
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
            print(force_emergency, "in emergency!!")

            
            if current_time - start_time2 >= 5:  
                print("Gonna check if anyone is coming to help!")
                start_time2 = current_time
                ishelpcoming = findhelper()
                if ishelpcoming:
                    update_threshold = False
                    if foundhelp == False :
                        helper = findhelper()["name"]
                        helperloc = findhelper()
                        #tell who is coming to help
                        PlayAudio(text_to_speech(f"Please wait while {helper} is coming to assist you"))
                        print("Found Help")
                        foundhelp = True
                else:
                    update_threshold = True
                    print("No Help Found")
                    foundhelp = False
                    
                    
                
     
thread = threading.Thread(target=emergency_thread, daemon=True)
thread.start()



# ------------- Main Interactions ---------------
#The following code is to setup the interaction of the device with user and the environment


# Emergency Button --> Triple Press - Toggle Emergency; Long Press - Restart System

def check_long_press(): # Restart system on long press
    start = time.time()
    while GPIO.input(EMERGENCY_BUTTON) == GPIO.LOW:
        if time.time() - start >= LONG_PRESS_DURATION:
            print("Long press detected")
            PlayAudio(restart_audio_path)
            GPIO.cleanup()
            python = sys.executable
            os.execv(python, [python] + sys.argv)
            break
        time.sleep(0.01)



cooldown_until = 0
#Emergency button setup
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
                PlayAudio(cooldown_audio_path)
                return

            cooldown_until = now + 30

            emergency = read_from_firestore("emergency")
            if emergency == False:
                
                if Latitude != 0:
                    PlayAudio(emergency_on_audio_path)
                    print("| Enabled Emergency Mode |")
                    doc_ref.update({
                        "timestamp":firestore.SERVER_TIMESTAMP
                    })
                    
                    emergency_threshold = emergency_threshold_initial
                    force_emergency = True
                    update_threshold = True
                    doc_ref.update({
                        "emergency": True,
                        "emergency_threshold" : emergency_threshold_initial
                    })
                else:
                    print("| No GPS Data to enter emergency mode |")
                    cooldown_until = time.time()
                    PlayAudio(gps_unavailable_audio_path)

            else:
                PlayAudio(emergency_off_audio_path)
                print("| Disabled Emergency Mode |")
                doc_ref.update({
                    "emergency": False
                })
                emergency_sms(False)

            press_times = []
            
GPIO.add_event_detect(EMERGENCY_BUTTON, GPIO.BOTH, callback=emergency_button_main, bouncetime=50)

command_queue = Queue()
#Rpi Camera worker
def camera_worker():
    while True:
        command = command_queue.get()
        if command == "start":
            if not picam2.started:
                print("Starting camera...")
                picam2.start()
        elif command == "stop":
            if picam2.started:
                print("Stopping camera...")
                picam2.stop()
                 
threading.Thread(target=camera_worker, daemon=True).start()
def start_camera_async():
    command_queue.put("start")

def stop_camera_async():
    command_queue.put("stop")
# Control Button - Analyze & Navigate Mode
try:
    while True:
        button_state = GPIO.input(CONTROL_BUTTON)
        if button_state == GPIO.LOW:
            print("Button pressed!")
            start_camera_async()
            command = speech_to_text().lower()
            try:       
                if "custom" in command : 
                    print("| Entered Custom Analyse Mode |")
                    analyse(True)
                elif "analyze" in command or "analyse" in command  :
                    print("| Entered Analyse Mode |")
                    analyse()
                elif "navigate" in command :
                    print("Current Latitude :",Latitude)
                    stop_camera_async()
                    if Latitude != 0:
                        print("| Entered Navigate Mode |")
                        navigate()
                    else:
                        print("| No GPS Data to enter navigate mode |")
                        PlayAudio(gps_unavailable_audio_path)
                else:
                    PlayAudio(invalid_command_audio_path)
                    stop_camera_async()
                
                    
            except Exception as e:
                print("Error" + e)
                PlayAudio(invalid_command_audio_path)
                stop_camera_async()
   
#Error handling 
except KeyboardInterrupt:
    print("Exiting program.")
except Exception as e :
    PlayAudio(restart_audio_path)
    print("Error : ", e)
    python = sys.executable
    os.execv(python, [python] + sys.argv)
    
finally:
    #GPIO cleanup
    GPIO.cleanup()