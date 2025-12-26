# Saytime Weather

A time and weather announcement system for Asterisk PBX, designed for radio systems, repeater controllers, and amateur radio applications. Provides automated voice announcements of current time and weather conditions.

**Version 2.7.6** - Code simplification and improved maintainability.

## 🚀 Features

- **Time Announcements**: 12-hour and 24-hour formats with location-aware timezone
- **Worldwide Weather**: Postal codes, ICAO airport codes (6000+ airports), or special locations
- **No API Keys Required**: Works immediately after installation
- **Day/Night Detection**: Intelligent conditions (never says "sunny" at 2 AM)
- **Smart Caching**: 30-minute default cache for fast repeated lookups
- **Free APIs**: Open-Meteo (weather) + Nominatim (geocoding)

## 📋 Requirements

- **Asterisk PBX** (tested with versions 16+)
- **Perl 5.20+** with modules: `LWP::UserAgent`, `JSON`, `DateTime`, `DateTime::TimeZone`, `Config::Simple`, `Log::Log4perl`, `Cache::FileCache`
- **Internet Connection** for weather API access

## 🛠️ Installation

### Debian Package (Recommended)

```bash
cd /tmp
wget https://github.com/hardenedpenguin/saytime_weather/releases/download/v2.7.6/saytime-weather_2.7.6_all.deb
sudo apt install ./saytime-weather_2.7.6_all.deb
```

This automatically installs dependencies, sets up directories, and creates configuration with sensible defaults.

## ⚙️ Configuration

Configuration is **optional** - the system works out of the box. Edit `/etc/asterisk/local/weather.ini` (auto-created on first run):

```ini
[weather]
Temperature_mode = F              # F or C
default_country = us              # ISO country code (us, ca, de, fr, etc.)
process_condition = YES           # YES or NO
cache_enabled = YES               # YES or NO
cache_duration = 1800            # 30 minutes in seconds
```

## 🎯 Usage

### saytime.pl - Time and Weather Announcements

```bash
saytime.pl -l <LOCATION_ID> -n <NODE_NUMBER>
```

**Location ID**: Postal code, ICAO airport code (e.g., `KJFK`, `EGLL`), or special location name.

#### Common Options

| Option | Description | Default |
|--------|-------------|---------|
| `-l, --location_id=ID` | Location ID (required) | - |
| `-n, --node_number=NUM` | Node number (required) | - |
| `-s, --silent=NUM` | 0=voice, 1=save both, 2=weather only | 0 |
| `-h, --use_24hour` | 24-hour time format | 12-hour |
| `-v, --verbose` | Verbose output | Off |
| `-d, --dry-run` | Test mode (don't play) | Off |
| `-w, --weather` | Enable weather | On |
| `-g, --greeting` | Enable greetings | On |
| `--help` | Show help | - |

### weather.pl - Standalone Weather Retrieval

```bash
weather.pl <LOCATION_ID> [v]
```

Add `v` for text-only output. Options: `-c` (config), `-d` (country), `-t` (temp mode), `--no-cache`, `--no-condition`, `-h` (help), `--version`.

**Note**: `-d` and `-t` mean different things in each script:
- `saytime.pl`: `-d` = dry-run, `-t` = test mode
- `weather.pl`: `-d` = default-country, `-t` = temperature-mode

### Examples

**Postal codes**:
```bash
saytime.pl -l 77511 -n 1          # US ZIP
saytime.pl -l M5H2N2 -n 1         # Canadian postal
saytime.pl -l 75001 -n 1           # European postal
```

**ICAO airport codes**:
```bash
saytime.pl -l KJFK -n 1           # JFK, New York
saytime.pl -l EGLL -n 1           # Heathrow, London
weather.pl CYYZ v                  # Toronto Pearson
```

**Special locations** (50+ remote locations for DXpeditions):
```bash
saytime.pl -l ALERT -n 1          # Alert, Nunavut (northernmost)
weather.pl HEARD v                 # Heard Island (VK0)
weather.pl BOUVET v                # Bouvet Island (3Y0)
```

**Other options**:
```bash
saytime.pl -l 77511 -n 1 -h       # 24-hour format
saytime.pl -l 77511 -n 1 -s 1     # Save to file
weather.pl -t C KJFK v             # Celsius
weather.pl --no-cache EGLL v        # Skip cache
```

## ⏰ Automation

### Crontab

```bash
sudo crontab -e
```

**Every hour (3 AM - 11 PM)**:
```cron
00 03-23 * * * /usr/bin/nice -19 /usr/sbin/saytime.pl -l 77511 -n 1 > /dev/null 2>&1
```

**Every 30 minutes (6 AM - 10 PM)**:
```cron
0,30 06-22 * * * /usr/bin/nice -19 /usr/sbin/saytime.pl -l 77511 -n 1 > /dev/null 2>&1
```

### Asterisk Dialplan

```asterisk
[weather-announcement]
exten => 1234,1,Answer()
exten => 1234,2,Exec(/usr/sbin/saytime.pl -l 77511 -n 1)
exten => 1234,3,Hangup()
```

## 🌍 Location Support

- **Postal Codes**: US ZIP (5-digit), Canadian (A1A 1A1), European (5-digit), UK (SW1A1AA), and more
- **ICAO Airport Codes**: 6000+ airports worldwide (4-letter codes like `KJFK`, `EGLL`, `CYYZ`)
- **Special Locations**: 50+ remote locations including:
  - Antarctica stations (SOUTHPOLE, MCMURDO, VOSTOK, etc.)
  - Arctic locations (ALERT, EUREKA, THULE, etc.)
  - DXpedition islands (HEARD, BOUVET, KERGUELEN, etc.)
  - Pacific islands (MIDWAY, WAKE, EASTER, etc.)

**Timezone Feature**: Time announcements automatically match the weather location's timezone.

## 🔧 Troubleshooting

**"Could not get coordinates"**:
- Verify postal code format and internet connectivity
- Test: `weather.pl 12345 v`

**No sound output**:
- Check Asterisk: `sudo systemctl status asterisk`
- Test: `saytime.pl -l 12345 -n 1 -v -t`

**Weather not updating**:
- Clear cache: `sudo rm -rf /var/cache/weather/*`
- Test API: `curl "https://api.open-meteo.com/v1/forecast?latitude=29.56&longitude=-95.16&current=temperature_2m,weather_code,is_day&temperature_unit=fahrenheit&timezone=auto"`
- Test without cache: `weather.pl --no-cache 12345 v`

**Debug mode**:
```bash
saytime.pl -l 12345 -n 1 -v -d    # Verbose + dry-run
weather.pl 12345 v                 # Verbose text output
```

## 📁 File Structure

```
/usr/sbin/
├── saytime.pl          # Main announcement script
└── weather.pl          # Weather retrieval script

/etc/asterisk/local/
└── weather.ini         # Configuration (auto-created)

/usr/share/asterisk/sounds/en/
└── wx/                 # Weather sound files

/var/cache/weather/    # Cache directory (auto-created)
/tmp/                   # Temporary files
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

```bash
git clone https://github.com/hardenedpenguin/saytime_weather.git
cd saytime_weather
make test
make install
```

## 📄 License

**Copyright 2025, Jory A. Pratt, W5GLE**

Based on original work by D. Crompton, WA3DSP

## 🆘 Support

- **GitHub Issues**: [Report bugs or request features](https://github.com/hardenedpenguin/saytime_weather/issues)
- **Documentation**: Check the [Wiki](https://github.com/hardenedpenguin/saytime_weather/wiki)

## 🙏 Acknowledgments

- Original concept by D. Crompton, WA3DSP
- Open-Meteo for free weather API (https://open-meteo.com)
- OpenStreetMap Nominatim for free geocoding (https://nominatim.org)

---

**Made with ❤️ for the amateur radio community**
