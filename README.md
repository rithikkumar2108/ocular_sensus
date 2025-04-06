# Ocular Sensus
Ocular Sensus is an AI-enabled wearable device designed to assist visually impaired individuals in navigating their environment with confidence.

## Problem
For visually impaired individuals, everyday life is filled with challenges that most people never have to think about. Finding misplaced objects, moving safely through unfamiliar spaces, and seeking help in emergencies can be daunting without reliable assistance. Traditional methods like canes or verbal guidance often fall short in providing complete independence. In emergencies, the inability to quickly notify others increases vulnerability.

## Solution
Ocular Sensus enhances the lives of visually impaired users by providing feedback and assistance using AI and IoT. It helps users:

    Understand their environment

    Navigate safely and independently

    Get immediate help during emergencies

It is built entirely for auditory and tactile interaction. It’s a holistic, 
AI-powered solution designed for true independence of visually impaired people 
including all the essential features.

### Key Features

    Environmental Analysis  (GEMINI API)
    Uses AI to analyze surroundings and audibly describe what’s nearby.
    Detects objects, people, signs, and hazards. Users can ask questions like:

        “Where is the bottle in front of me?”
        Output: “It’s on the shelf to your right.”

    Navigation (GMAPS API)
    GPS navigation with Google Maps integration.
    Directional guidance is provided via gentle haptic feedback and audio cues to ensure smooth travel.

    Emergency System
    A built-in emergency system sends the user’s location to a secure server in case of emergency (Firebase)

        Local responders are notified immediately.

        If no help is found, relatives are alerted via SMS.

        Auto-activates if the device detects the user has fainted or is immobile for a long time.

    Companion App
    A dedicated mobile app that allows volunteers to respond during emergencies and enables friends or caregivers to configure device settings.

    Proximity
    Real-time lerping of vibration intensity based on the depth/distance of obstacle.


Note :    
requirements.txt file in raspberry-pi folder contains all the necessary packages to be installed in raspberry pi device