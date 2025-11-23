# Saytime Weather

A comprehensive time and weather announcement system for Asterisk PBX, designed specifically for radio systems, repeater controllers, and amateur radio applications. This system provides automated voice announcements of current time and weather conditions using high-quality synthesized speech.

**Version 2.7.5** - Code cleanup and refactoring release! Improved maintainability, better error handling, and code organization improvements.

## 🚀 Features

- **Time Announcements**: Support for both 12-hour and 24-hour time formats
- **Location-Aware Timezone**: Time automatically matches weather location timezone
- **Worldwide Weather**: Real-time weather from postal codes OR ICAO airport codes globally
- **ICAO Airport Support**: 6000+ airports worldwide (KJFK, EGLL, CYYZ, LFPG, RJAA)
- **No API Keys Required**: Fully functional out of the box - zero configuration!
- **Global Postal Codes**: US ZIP codes, Canadian postal codes, European codes, and more
- **Day/Night Detection**: Intelligent conditions (never says "sunny" at 2 AM)
- **Smart Greetings**: Context-aware greeting messages (morning/afternoon/evening)
- **Flexible Output**: Voice playback or file generation for later use
- **Comprehensive Logging**: Quiet by default, detailed with verbose flag
- **Caching System**: Intelligent caching (30 min default) for fast repeated lookups
- **Free Weather APIs**: Open-Meteo (weather) + Nominatim (geocoding) - both free forever
- **Clean Codebase**: Well-organized, maintainable code with consistent patterns

## 📋 Requirements

- **Asterisk PBX** (tested with versions 16+)
- **Perl 5.20+** with the following modules:
  - `LWP::UserAgent` (HTTP requests)
  - `JSON` (JSON parsing)
  - `DateTime` and `DateTime::TimeZone` (Time handling)
  - `Config::Simple` (Configuration)
  - `Log::Log4perl` (Logging)
  - `Cache::FileCache` (Caching)
- **Internet Connection** for weather API access
- **No API Keys Required** - Works immediately after installation

## 🛠️ Installation

### Option 1: Debian Package (Recommended)

1. **Download the latest release**:
   ```bash
   cd /tmp
   wget https://github.com/w5gle/saytime-weather/releases/download/v2.7.5/saytime-weather_2.7.5_all.deb
   ```

2. **Install the package**:
   ```bash
   sudo apt install ./saytime-weather_2.7.5_all.deb
   ```

   This will automatically:
   - Install all required dependencies
   - Set up the system directories
   - Install sound files
   - Create configuration with sensible defaults

## ⚙️ Configuration

### Weather Configuration

The system works out of the box with sensible defaults. Configuration is **optional** and the config file is auto-created on first run.

Edit `/etc/asterisk/local/weather.ini`:

```ini
[weather]
# Temperature display mode (F for Fahrenheit, C for Celsius)
Temperature_mode = F

# Default country for postal code lookups (ISO 3166-1 alpha-2 code)
# Options: us, ca, de, fr, uk, it, es, etc.
default_country = us

# Process weather condition announcements (YES/NO)
process_condition = YES

# Cache settings for faster repeated lookups
cache_enabled = YES
cache_duration = 1800                   ; 30 minutes in seconds
```

**That's it!** The system works immediately with sensible defaults.

## 📝 Changelog

### What Changed in v2.7.5?

**New in 2.7.5 - Code Cleanup Release:**
- 🧹 **Code Refactoring** - Improved code organization and maintainability
- 🔧 **Better Error Handling** - Simplified error handling patterns throughout
- 🗑️ **Removed Dead Code** - Eliminated unused functions and redundant checks
- 🔒 **Security Improvements** - Replaced shell commands with safer Perl file operations
- 📦 **Function Organization** - Fixed function definition order for better clarity
- ✨ **Code Simplification** - Cleaned up complex conditionals and redundant logic

### What Changed in v2.7.4?

**New in 2.7.4 - Major Feature Release! 🎉**
- ✈️ **ICAO Airport Support** - 6000+ airports worldwide (KJFK, EGLL, CYYZ, LFPG, RJAA, etc.)
- 🎛️ **Command Line Overrides** - Test any country with `weather.pl -d fr 75001` or Celsius with `weather.pl -t C`
- 🌞🌙 **Day/Night Detection** - Never says "sunny" at 2 AM anymore!
- 🗺️ **50+ Special Locations** - DXpedition sites & research stations (HEARD, BOUVET, ALERT, etc.)
- 📝 **Enhanced Config** - Comprehensive documentation in weather.ini template
- 🔧 **METAR Integration** - Aviation-grade weather from NOAA
- 🚀 **Improved API** - Updated to latest Open-Meteo current parameter

### What Changed in v2.7.3?

**New in 2.7.3:**
- 🐛 **CRITICAL FIX: Canadian postal code accuracy** - Ontario postal codes now resolve correctly
- 📍 **Added 50+ detailed FSA mappings** - N7L→Chatham-Kent, N6A→London, N8W→Windsor, etc.
- 🎯 **Improved location accuracy** - 3-character FSA lookup prioritized over generic regions
- 🔧 **Fixed lookup logic** - Canadian postal codes no longer use wrong province center

## 🎯 Usage

### saytime.pl - Time and Weather Announcements

#### Basic Usage

```bash
saytime.pl -l <LOCATION_ID> -n <NODE_NUMBER>
```

**Works with postal codes, ICAO airport codes, or special location names!**

#### Command Line Options (saytime.pl)

| Option | Long Option | Description | Default |
|--------|-------------|-------------|---------|
| `-l` | `--location_id=ID` | Location ID (postal code, ICAO code, or special location) | Required |
| `-n` | `--node_number=NUM` | Node number for announcement | Required |
| `-s` | `--silent=NUM` | Silent mode: 0=voice, 1=save both, 2=save weather only | 0 |
| `-h` | `--use_24hour` | Use 24-hour time format | 12-hour |
| `-m` | `--method` | Enable playback method (changes to `playback` mode) | `localplay` |
| `-v` | `--verbose` | Enable verbose output | Off |
| `-d` | `--dry-run` | Don't play or save files (test mode) | Off |
| `-t` | `--test` | Test sound files before playing | Off |
| `-w` | `--weather` | Enable weather announcements | On |
| `-g` | `--greeting` | Enable greeting messages | On |
| | `--sound-dir=DIR` | Custom sound directory | `/usr/share/asterisk/sounds/en` |
| | `--log=FILE` | Log to specified file | Stdout |
| | `--help` | Show help message | - |

### weather.pl - Standalone Weather Retrieval

#### Basic Usage

```bash
weather.pl <LOCATION_ID> [v]
```

**Location ID can be a postal code, ICAO airport code, or special location name. Add `v` for verbose text-only output.**

#### Command Line Options (weather.pl)

| Option | Long Option | Description | Default |
|--------|-------------|-------------|---------|
| `-c` | `--config=FILE` | Use alternate configuration file | Searches default paths |
| `-d` | `--default-country=CC` | Override default country (us, ca, fr, de, uk, etc.) | From config |
| `-t` | `--temperature-mode=M` | Override temperature mode (F or C) | From config |
| `--no-cache` | | Disable caching for this request | Cache enabled |
| `--no-condition` | | Skip weather condition announcements | Conditions enabled |
| `-h` | `--help` | Show detailed help message | - |
| `--version` | | Show version information | - |

**Note**: The `-d` and `-t` options mean different things in `saytime.pl` vs `weather.pl`:
- In `saytime.pl`: `-d` = dry-run, `-t` = test mode
- In `weather.pl`: `-d` = default-country, `-t` = temperature-mode

### Usage Examples

#### saytime.pl Examples

**US ZIP codes**:
```bash
saytime.pl -l 77511 -n 1     # Houston, TX
saytime.pl -l 10001 -n 1     # New York, NY
saytime.pl -l 90210 -n 1     # Beverly Hills, CA
```

**Canadian postal codes**:
```bash
saytime.pl -l M5H2N2 -n 1    # Toronto, ON
saytime.pl -l V6B1A1 -n 1    # Vancouver, BC
saytime.pl -l N7L3R5 -n 1    # Chatham-Kent, ON
```

**European postal codes**:
```bash
saytime.pl -l 75001 -n 1     # Paris, France
saytime.pl -l 10115 -n 1     # Berlin, Germany
saytime.pl -l SW1A1AA -n 1   # London, UK
```

**ICAO airport codes**:
```bash
saytime.pl -l KJFK -n 1      # JFK Airport, New York
saytime.pl -l EGLL -n 1      # Heathrow, London
saytime.pl -l CYYZ -n 1      # Toronto Pearson
saytime.pl -l LFPG -n 1      # Charles de Gaulle, Paris
saytime.pl -l RJAA -n 1      # Narita, Tokyo
```

**Special remote locations**:
```bash
saytime.pl -l ALERT -n 1     # Alert, Nunavut (northernmost settlement)
saytime.pl -l HEARD -n 1     # Heard Island (VK0)
saytime.pl -l BOUVET -n 1    # Bouvet Island (3Y0)
```

**24-hour time format**:
```bash
saytime.pl -l 77511 -n 1 -h
```

**Save announcement to file**:
```bash
saytime.pl -l 77511 -n 1 -s 1
```

**Test mode with verbose output**:
```bash
saytime.pl -l 77511 -n 1 -d -v
```

#### weather.pl Examples

**Basic usage**:
```bash
weather.pl 77511             # Generate sound files
weather.pl 77511 v           # Display text only (verbose)
```

**Postal codes**:
```bash
weather.pl 90210 v                    # Beverly Hills, CA (ZIP)
weather.pl M5H2N2 v                   # Toronto, ON (postal code)
weather.pl -d fr 75001 v              # Paris, France (override country)
weather.pl -d de 10115 v              # Berlin, Germany
```

**ICAO airport codes**:
```bash
weather.pl KJFK v                     # JFK Airport, New York
weather.pl EGLL v                     # Heathrow, London
weather.pl CYYZ v                     # Toronto Pearson
weather.pl LFPG v                     # Charles de Gaulle, Paris
weather.pl RJAA v                     # Narita, Tokyo
```

**Special remote locations**:
```bash
weather.pl ALERT v                    # Alert, Nunavut
weather.pl HEARD v                    # Heard Island (VK0)
weather.pl BOUVET v                   # Bouvet Island (3Y0)
weather.pl EASTER v                   # Easter Island
weather.pl MIDWAY v                   # Midway Atoll
```

**With command line overrides**:
```bash
weather.pl -t C KJFK v                # JFK in Celsius
weather.pl --no-cache EGLL v          # Fresh METAR from Heathrow (no cache)
weather.pl -d ca 75001 v              # Try 75001 as Canadian postal code
```

## 📁 File Structure

```
/usr/sbin/
├── saytime.pl          # Main announcement script
└── weather.pl          # Weather retrieval script

/etc/asterisk/local/
└── weather.ini         # Weather configuration file (auto-created on first run)

/usr/share/asterisk/sounds/en/
├── a-m.ulaw            # "AM" for time announcements
├── p-m.ulaw            # "PM" for time announcements
└── wx/                 # Weather sound files directory
    ├── clear.ulaw      # Weather condition sounds
    ├── cloudy.ulaw
    ├── rain.ulaw
    ├── sunny.ulaw
    ├── temperature.ulaw    # Temperature announcements
    ├── degrees.ulaw
    └── ...             # Additional weather sounds (breezy, calm, drizzle, 
                        # foggy, gusty, hail, heavy, light, moderate, mostly,
                        # overcast, partly, showers, sleet, thunderstorms, 
                        # weather, windy)

/var/cache/weather/     # Weather cache directory (created automatically)
/tmp/                   # Temporary files (temperature, condition.ulaw, timezone)
```

**Note**: Configuration files are searched in this order:
1. `/etc/asterisk/local/weather.ini` (primary)
2. `/etc/asterisk/weather.ini` (fallback)
3. `/usr/local/etc/weather.ini` (fallback)

## ⏰ Automation

### Crontab Setup

Add to your system crontab for automated announcements:

```bash
sudo crontab -e
```

**Example: Announce every hour from 3 AM to 11 PM**:
```cron
00 03-23 * * * /usr/bin/nice -19 /usr/sbin/saytime.pl -l 77511 -n 1 > /dev/null 2>&1
```

**Example: Announce every 30 minutes during daylight hours**:
```cron
0,30 06-22 * * * /usr/bin/nice -19 /usr/sbin/saytime.pl -l 77511 -n 1 > /dev/null 2>&1
```

**Example: Different time zones (announcements match location time)**:
```cron
# Announce for Los Angeles (Pacific Time)
00 * * * * /usr/bin/nice -19 /usr/sbin/saytime.pl -l 90210 -n 1 > /dev/null 2>&1

# Announce for New York (Eastern Time)  
00 * * * * /usr/bin/nice -19 /usr/sbin/saytime.pl -l 10001 -n 2 > /dev/null 2>&1
```

### Asterisk Integration

Add to your Asterisk dialplan (`/etc/asterisk/extensions.conf`):

```asterisk
[weather-announcement]
exten => 1234,1,Answer()
exten => 1234,2,Exec(/usr/sbin/saytime.pl -l 77511 -n 1)
exten => 1234,3,Hangup()
```

**Example: Multiple locations**:
```asterisk
[weather-announcement]
; Local weather
exten => 1234,1,Answer()
exten => 1234,2,Exec(/usr/sbin/saytime.pl -l 77511 -n 1)
exten => 1234,3,Hangup()

; Remote weather (different timezone)
exten => 5678,1,Answer()
exten => 5678,2,Exec(/usr/sbin/saytime.pl -l 90210 -n 1)
exten => 5678,3,Hangup()
```

## 🌍 Location Support

### Supported Postal Code Formats

- **United States**: 5-digit ZIP codes (e.g., `77511`, `10001`, `90210`)
- **Canada**: 6-character postal codes (e.g., `M5H2N2`, `V6B1A1`, `N7L 3R5`)
- **Germany**: 5-digit postal codes (e.g., `10115`, `80331`, `20095`)
- **France**: 5-digit postal codes (e.g., `75001`, `69001`)
- **United Kingdom**: Postal codes (e.g., `SW1A1AA`, `EC1A1BB`)
- **ICAO Codes**: 4-letter airport codes (e.g., `KJFK`, `EGLL`, `CYYZ`, `LFPG`)
- **And many more!** - Works with most international postal codes

### Special Remote Locations (50+)

Support for remote locations without postal codes!

Perfect for DXpeditions, research stations, and extreme locations:

**Antarctica** (13 stations): `SOUTHPOLE`, `MCMURDO`, `PALMER`, `VOSTOK`, `CASEY`, `MAWSON`, `DAVIS`, `SCOTTBASE`, `SYOWA`, `CONCORDIA`, `HALLEY`, `DUMONT`, `SANAE`

**Arctic** (7 locations): `ALERT` (northernmost!), `EUREKA`, `THULE`, `LONGYEARBYEN`, `BARROW`, `RESOLUTE`, `GRISE`

**DXpedition Islands** (10): `HEARD` (VK0), `BOUVET` (3Y0), `KERGUELEN` (FT5), `CROZET` (FT4), `AMSTERDAM` (FT5), `MACQUARIE` (VK0), `ASCENSION` (ZD8), `STHELENA` (ZD7), `TRISTAN` (ZD9), `GOUGH` (ZD9)

**South Atlantic** (3): `FALKLANDS` (VP8), `SOUTHGEORGIA` (VP8), `SOUTHSANDWICH` (VP8)

**Pacific Islands** (8): `MIDWAY` (KH4), `WAKE` (KH9), `JOHNSTON` (KH3), `PALMYRA` (KH5K), `JARVIS` (KH5), `HOWLAND` (KH1), `BAKER` (KH1), `KINGMAN` (KH5K)

**Pacific Polynesia** (5): `EASTER` (CE0Y), `PITCAIRN` (VP6), `GALAPAGOS` (HC8), `MARQUESAS` (FO), `CLIPPERTON` (FO/C)

**Indian Ocean** (4): `DIEGO` (VQ9), `CHAGOS` (VQ9), `COCOS` (VK9C), `CHRISTMAS` (VK9X)

**Other Notable Locations** (10): `CAMPBELL` (ZL9), `AUCKLAND` (ZL9), `KERMADEC` (ZL8), `CHATHAM` (ZL7), `MARION` (ZS8), `PRINCE` (ZS8), `MAUNA` (Mauna Loa Observatory), `JUNGFRAUJOCH` (Switzerland), `MCMURDODRY` (Antarctica), `ATACAMA` (Chile)

**Examples:**
```bash
weather.pl ALERT v        # Alert, Nunavut (northernmost settlement)
weather.pl HEARD v        # Heard Island (VK0)
weather.pl BOUVET v       # Bouvet Island (3Y0)
weather.pl EASTER v       # Easter Island (CE0Y)
weather.pl MIDWAY v       # Midway Atoll (KH4)
weather.pl SOUTHPOLE v    # South Pole Station, Antarctica
```

### Timezone Feature

Time announcements automatically use the timezone of the weather location!

- Repeater in Houston announcing LA weather? Says LA's time (Pacific), not Houston's (Central)
- Repeater in New York announcing Paris weather? Says Paris's time (CET), not NY's (EST)
- Same location as repeater? Uses local time as expected

**Automatic and free** - no configuration needed!

## 🔧 Troubleshooting

### Common Issues

1. **"Could not get coordinates" errors**:
   - Verify postal code is valid and correctly formatted
   - Check internet connectivity
   - Try with verbose mode: `weather.pl 12345 v`

2. **No sound output**:
   - Verify Asterisk is running: `sudo systemctl status asterisk`
   - Check sound file permissions: `ls -la /usr/share/asterisk/sounds/en/wx/`
   - Test with verbose mode: `saytime.pl -l 12345 -n 1 -v -t`
   - Verify weather.pl works: `weather.pl 12345 v`

3. **Weather data not updating**:
   - Check internet connectivity: `ping api.open-meteo.com`
   - Clear cache: `sudo rm -rf /var/cache/weather/*`
   - Test API directly: `curl "https://api.open-meteo.com/v1/forecast?latitude=29.56&longitude=-95.16&current=temperature_2m,weather_code,is_day&temperature_unit=fahrenheit&timezone=auto"`
   - Test with no cache: `weather.pl --no-cache 12345 v`

### Debug Mode

Run with verbose output for detailed debugging:

**saytime.pl**:
```bash
saytime.pl -l 12345 -n 1 -v -d
```

**weather.pl**:
```bash
weather.pl 12345 v                    # Verbose text output
weather.pl --no-cache 12345 v          # Skip cache, verbose output
```

### Log Files

Check system logs for errors:
```bash
sudo journalctl -u asterisk -f
tail -f /var/log/asterisk/full
```

## 🤝 Contributing

We welcome contributions! Please feel free to:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

### Development Setup

```bash
git clone https://github.com/w5gle/saytime-weather.git
cd saytime-weather
# Make your changes
make test
make install
```

## 📄 License

**Copyright 2025, Jory A. Pratt, W5GLE**

Based on original work by D. Crompton, WA3DSP

This project is licensed under the terms specified in the LICENSE file.

## 🆘 Support

- **GitHub Issues**: [Report bugs or request features](https://github.com/w5gle/saytime-weather/issues)
- **Documentation**: Check the [Wiki](https://github.com/w5gle/saytime-weather/wiki) for detailed guides
- **Community**: Join our [Discussions](https://github.com/w5gle/saytime-weather/discussions)

## 🙏 Acknowledgments

- Original concept and development by D. Crompton, WA3DSP
- Weather API integrations and improvements by the community
- Sound file contributions from various amateur radio operators
- Open-Meteo for providing free weather API (https://open-meteo.com)
- OpenStreetMap Nominatim for free geocoding (https://nominatim.org)

---

**Made with ❤️ for the amateur radio community**
