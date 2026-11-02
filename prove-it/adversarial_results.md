# Adversarial Challenge Results

- Total Scenarios Tested: 11
- Passed: 11
- Failed: 0

| ID | Scenario | Status | Details |
|---|---|---|---|
| ADV-1 | YouTube Music Video (Rick Astley 4K AV1) | **PASS** | Exit: 0, 4K/AV1 detected: True |
| ADV-2 | YouTube 4K 60fps Profile Trigger | **PASS** | Exit: 0, 4k-video profile: True |
| ADV-3 | YouTube Shorts Vertical Playback | **PASS** | Exit: 0, Demuxed/Played: True |
| ADV-4 | Rapid Seek Forward/Backward Barrage | **PASS** | Exit: 0, Seek recovery confirmed |
| ADV-5 | YouTube Audio-Only Mode (--no-video) | **PASS** | Exit: 0, WASAPI audio active |
| ADV-6.1 | BotGuard & JS Challenge Resolution (Anonymous) | **PASS** | Exit: 0, googlevideo resolved: True |
| ADV-6.2 | BotGuard & Authenticated Cookie Extraction | **PASS** | Exit: 0, googlevideo resolved: True |
| ADV-7.1 | Cookie-Sync Missing cookies.txt Fallback/Header | **PASS** | Header: # Netscape HTTP Cookie File |
| ADV-7.2 | Cookie-Sync 0-byte cookies.txt Graceful Recovery | **PASS** | Header: # Netscape HTTP Cookie File |
| ADV-7.3 | Cookie-Sync Raw String Parsing & Transpilation | **PASS** | Bili mapped: True, YT mapped: True |
| ADV-7.4 | Session Isolation: Bilibili -> YouTube Header Scoping | **PASS** | Exit: 0, YT headers count: 0 |
