#!/usr/bin/perl

# Rewrite script to perl, rebuild all audio files for asl3
# Copyright 2025, Jory A. Pratt, W5GLE
# Based on original work by D. Crompton, WA3DSP
#
# Recent improvements (Oct 9, 2025):
# - CRITICAL: Replaced discontinued AccuWeather RSS with Open-Meteo API
# - Added ZIP code to coordinates conversion using Census Geocoding API
# - Fixed config file creation logic to properly handle multiple paths
# - Removed dead code (unused fetch_weather function)
# - Removed duplicate file cleanup calls for better efficiency
# - Improved binary file reading with chunked I/O for memory efficiency
# - Improved weather condition sound file matching with better debugging
# - Added better error handling and verbose logging throughout
# - Open-Meteo provides free weather data with no API key required
#

use strict;
use warnings;
use open qw(:std :utf8);
use locale;
$ENV{LC_ALL} = "en_US.UTF-8";
use LWP::UserAgent;
use JSON;
use Encode qw(decode);
use Cache::FileCache;
use File::Spec;
use Getopt::Long qw(:config no_ignore_case bundling);

# Define paths at the top of the script
my @CONFIG_PATHS = (
    "/etc/asterisk/local/weather.ini",
    "/etc/asterisk/weather.ini",
    "/usr/local/etc/weather.ini"
);

my @CACHE_PATHS = (
    "/var/cache/weather",
    "/tmp/weather-cache"
);

my @TEMP_PATHS = (
    "/tmp/temperature",
    "/tmp/condition.ulaw",
    "/tmp/timezone"
);

use constant {
    TMP_DIR => "/tmp",
    TEMP_FILE => "/tmp/temperature",
    COND_FILE => "/tmp/condition.ulaw",
    TIMEZONE_FILE => "/tmp/timezone",
    VERSION => '2.7.5',
    WEATHER_SOUND_DIR => "/usr/share/asterisk/sounds/en/wx",
};

# Add options hash near the top (must be before helper functions that reference it)
my %options = (
    verbose => 0,  # Default to non-verbose
    config_file => undef,  # Custom config file path
    default_country => undef,  # Override default_country from config
    temperature_mode => undef,  # Override Temperature_mode from config
    no_cache => 0,  # Disable cache for this run
    no_condition => 0,  # Disable condition announcements for this run
);

# Helper functions must be defined before use
sub ERROR {
    my ($msg) = @_;
    print STDERR "ERROR: $msg\n";
}

sub DEBUG {
    my ($msg) = @_;
    print "$msg\n" if $options{verbose};
}

sub WARN {
    my ($msg) = @_;
    # Only show warnings in verbose mode
    print STDERR "WARNING: $msg\n" if $options{verbose};
}

# Parse command line options first (before processing positional args)
GetOptions(
    'c|config=s'          => \$options{config_file},
    'd|default-country=s' => \$options{default_country},
    't|temperature-mode=s' => \$options{temperature_mode},
    'no-cache'            => \$options{no_cache},
    'no-condition'        => \$options{no_condition},
    'h|help'              => sub { show_usage(); },
    'version'             => sub { print "weather.pl version " . VERSION . "\n"; exit 0; },
) or show_usage();

# Source the allstar variables - try each config path
my %config;
my $config_created = 0;

# If custom config file specified, use only that
my @config_paths_to_try = $options{config_file} ? ($options{config_file}) : @CONFIG_PATHS;

# If custom config specified but doesn't exist, error out
if ($options{config_file} && !-f $options{config_file}) {
    print STDERR "ERROR: Custom config file not found: $options{config_file}\n";
    exit 1;
}

foreach my $config_file (@config_paths_to_try) {
    if (-f $config_file) {
        open my $fh, "<", $config_file or next;
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/^\s+|\s+$//g; # Trim leading/trailing whitespace
            next if $line eq '' || $line =~ /^;/; # Skip empty lines and comments
            next if $line =~ /^\[.*\]$/; # Skip section headers
            if ($line =~ /^([^=]+?)\s*=\s*"([^"]*)"\s*$/) {
                $config{$1} = $2;
            } elsif ($line =~ /^([^=]+?)\s*=\s*([^\"]\S*)\s*$/) {
                $config{$1} = $2;
            }
        }
        close $fh;
        last;  # Stop after first successful config file
    } elsif (!$config_created) {
        # Try to create config file in the first available location
        eval {
            DEBUG("Creating default configuration file: $config_file") if $options{verbose};
            
            # Create parent directory if needed
            my ($vol, $dir, $file) = File::Spec->splitpath($config_file);
            my $parent_dir = File::Spec->catpath($vol, $dir, '');
            if (!-d $parent_dir) {
                require File::Path;
                File::Path::make_path($parent_dir);
            }
            
            open my $fh, '>', $config_file
                or die "Cannot create config file $config_file: $!";
            
            print $fh <<'EOT';
; ============================================================================
; Weather Configuration for saytime-weather
; ============================================================================
; This file controls how weather data is fetched and announced.
; All settings have sensible defaults - no changes required to get started!
; ============================================================================

[weather]

; ============================================================================
; TEMPERATURE SETTINGS
; ============================================================================

; Temperature display mode: F for Fahrenheit, C for Celsius
; Default: F
; Examples: Temperature_mode = F  (for 72°F)
;           Temperature_mode = C  (for 22°C)
Temperature_mode = F

; ============================================================================
; CONDITION ANNOUNCEMENTS
; ============================================================================

; Process and announce weather conditions (cloudy, rain, clear, etc.)
; Set to NO to only announce temperature
; Default: YES
process_condition = YES

; ============================================================================
; LOCATION SETTINGS
; ============================================================================

; Default country for ambiguous postal code lookups
; Helps with 5-digit codes that could be multiple countries
; Use ISO 3166-1 alpha-2 country codes: us, ca, de, fr, uk, etc.
; Leave blank for international search (slower)
; Default: us
; Examples: default_country = us  (prioritize US ZIP codes)
;           default_country = ca  (prioritize Canadian postal codes)
;           default_country =     (search all countries)
default_country = us

; ============================================================================
; WEATHER DATA SOURCE
; ============================================================================

; Weather data provider (currently only openmeteo supported)
; Open-Meteo is free, requires no API key, and provides worldwide coverage
; This option is reserved for future providers
; Default: openmeteo
weather_provider = openmeteo

; ============================================================================
; CACHE SETTINGS
; ============================================================================

; Enable caching to reduce API calls and improve response time
; Recommended: YES (faster repeated lookups, reduces API load)
; Set to NO only for testing or if you need real-time updates
; Default: YES
cache_enabled = YES

; Cache duration in seconds (how long to keep weather data)
; Default: 1800 (30 minutes)
; Examples: cache_duration = 1800   (30 minutes, recommended)
;           cache_duration = 3600   (1 hour)
;           cache_duration = 900    (15 minutes)
;           cache_duration = 300    (5 minutes, for testing)
cache_duration = 1800

; ============================================================================
; USAGE EXAMPLES
; ============================================================================
; 
; Test weather for your location:
;   /usr/sbin/weather.pl YOUR_POSTAL_CODE v
;
; Examples:
;   /usr/sbin/weather.pl 90210 v          (Beverly Hills, CA)
;   /usr/sbin/weather.pl M5H2N2 v         (Toronto, ON)
;   /usr/sbin/weather.pl 10115 v          (Berlin, Germany)
;
; Use with Asterisk:
;   /usr/sbin/saytime.pl -l 90210 -n 1
;
; ============================================================================
EOT
            close $fh;
            
            chmod 0644, $config_file
                or die "Cannot set permissions on $config_file: $!";
            
            $config_created = 1;
            last;  # Stop after creating config file
        };
        if ($@) {
            WARN("Could not create config file $config_file: $@");
            # Continue to try next path
        }
    }
}

# Set default values for all configuration options
$config{process_condition} = "YES" unless defined $config{process_condition};
$config{Temperature_mode} = "F" unless defined $config{Temperature_mode};
$config{default_country} = "us" unless defined $config{default_country};  # Default to US
$config{weather_provider} = "openmeteo" unless defined $config{weather_provider};  # Default to Open-Meteo
$config{cache_enabled} = "YES" unless defined $config{cache_enabled};
$config{cache_duration} = "1800" unless defined $config{cache_duration};  # 30 minutes default

# Apply command line overrides (these take precedence over config file)
if (defined $options{default_country}) {
    $config{default_country} = $options{default_country};
}
if (defined $options{temperature_mode}) {
    $config{Temperature_mode} = uc($options{temperature_mode});
}
if ($options{no_cache}) {
    $config{cache_enabled} = "NO";
}
if ($options{no_condition}) {
    $config{process_condition} = "NO";
}

# Initialize cache if enabled
my $cache;
if ($config{cache_enabled} eq "YES") {
    foreach my $cache_path (@CACHE_PATHS) {
        if (-d $cache_path) {
            if (!-w $cache_path) {
                WARN("Cache directory not writable: $cache_path");
                next;
            }
        } elsif (!mkdir $cache_path, 0755) {
            WARN("Failed to create cache directory: $cache_path - $!");
            next;
        }
        $cache = Cache::FileCache->new({
            cache_root => $cache_path,
            default_expires_in => $config{cache_duration},
            auto_purge_interval => 3600,  # 1 hour
            auto_purge_on_set => 1,
        });
        last if defined $cache;
    }
    if (!defined $cache) {
        WARN("Failed to initialize cache - continuing without caching");
        $config{cache_enabled} = "NO";
    } else {
        DEBUG("Cache initialized in: " . $cache->{cache_root}) if $options{verbose};
    }
}

# Ensure location and display_only are defined
my $location = shift @ARGV // '';
my $display_only = shift @ARGV // '';

if (not defined $location || $location eq '') {
    print "\n";
    print "USAGE: $0 <postal code>\n";
    print "\n";
    print "Example: $0 77511     (US ZIP code)\n";
    print "         $0 SW1A1AA   (UK postal code)\n";
    print "         $0 75001     (Paris postal code)\n";
    print "\n";
    print "        Add 'v' as second parameter for display only, no sound files\n";
    print "\n";
    print "Weather Provider: Open-Meteo (free, no API key, worldwide)\n";
    print "Geocoding: Nominatim/OpenStreetMap (free, no API key)\n";
    print "\n";
    print "Edit /etc/asterisk/local/weather.ini to configure:\n";
    print "  - Temperature_mode: C/F (default: F)\n";
    print "  - default_country: us/ca/de/fr/uk (default: us)\n";
    print "  - process_condition: YES/NO (default: YES)\n";
    print "  - cache_enabled: YES/NO (default: YES)\n";
    print "  - cache_duration: Cache duration in seconds (default: 1800)\n";
    print "\n";
    exit 0;
}

my $w_type = undef;
my $current = undef;
my $Temperature = undef;
my $Condition = undef;

# Validate location and environment before processing
validate_options();
validate_environment();

# Clean up old files at start of processing
cleanup_old_files();

# Check cache first if enabled
if ($config{cache_enabled} eq "YES" && defined $cache) {
    my $cached_data = $cache->get($location);
    if ($cached_data) {
        $Temperature = $cached_data->{temperature} // '';
        $Condition = $cached_data->{condition} // '';
        $current = "$Condition: $Temperature";
        $w_type = $cached_data->{type} // '';
        
        # Write timezone file from cache if available
        my $cached_tz = $cached_data->{timezone} // '';
        if ($cached_tz) {
            eval {
                open my $tz_fh, '>', TIMEZONE_FILE or die "Cannot open timezone file: $!";
                print $tz_fh $cached_tz;
                close $tz_fh;
                DEBUG("  Restored timezone from cache: $cached_tz") if $options{verbose};
            };
            WARN("Failed to write timezone file from cache: $@") if $@;
        }
    }
}

# If no cached data, fetch from API
if (not defined $current or $current eq "") {
    my $lat;
    my $lon;
    
    # Try ICAO/METAR first if it looks like an airport code
    if (is_icao_code($location)) {
        DEBUG("Detected ICAO code, trying METAR...") if $options{verbose};
        my ($metar_temp, $metar_cond) = fetch_metar_weather($location);
        
        if (defined $metar_temp && defined $metar_cond) {
            $Temperature = sprintf("%.0f", $metar_temp);
            $Condition = $metar_cond;
            $current = "$Condition: $Temperature";
            $w_type = "metar";
            
            DEBUG("METAR: $Temperature°F, $Condition") if $options{verbose};
            
            # Cache the METAR data
            if ($config{cache_enabled} eq "YES" && defined $cache) {
                $cache->set($location, {
                    temperature => $Temperature,
                    condition => $Condition,
                    type => $w_type,
                    timezone => ''  # METAR doesn't provide timezone
                });
            }
        } else {
            DEBUG("METAR fetch failed, falling back to postal code lookup") if $options{verbose};
        }
    }
    
    # If METAR didn't work or not an ICAO code, try postal code lookup
    if (not defined $current or $current eq "") {
    # Convert postal code to coordinates using Nominatim
    ($lat, $lon) = postal_to_coordinates($location);
    
    # If we have coordinates, fetch weather from Open-Meteo
    if (defined $lat && defined $lon) {
        my ($temp, $cond, $tz) = fetch_weather_openmeteo($lat, $lon);
        
        if (defined $temp && defined $cond) {
            $Temperature = sprintf("%.0f", $temp);  # Round to nearest degree
            $Condition = $cond;
            $current = "$Condition: $Temperature";
            $w_type = "openmeteo";
            
            DEBUG("Open-Meteo: $Temperature°, $Condition") if $options{verbose};
            
            # Cache the data if enabled (including timezone)
            if ($config{cache_enabled} eq "YES" && defined $cache) {
                $cache->set($location, {
                    temperature => $Temperature,
                    condition => $Condition,
                    type => $w_type,
                    timezone => $tz || ''
                });
            }
        } else {
            WARN("Failed to fetch weather data from Open-Meteo");
        }
    } else {
        WARN("Could not get coordinates for location: $location");
    }
    
    $w_type = "openmeteo" unless $w_type;
    }
}

if (not defined $current or $current eq "") {
    ERROR("No weather report available");
    exit 1;
}

# Convert temperature to Celsius (simple math, no need for eval)
my $CTEMP = sprintf "%.0f", (5/9) * ($Temperature - 32);
print "$Temperature\N{DEGREE SIGN}F, $CTEMP\N{DEGREE SIGN}C / $Condition\n";

# If v given as second parameter just echo text, no sound
if (defined $display_only and $display_only eq "v") {
    exit;
}

# Note: Files already cleaned up earlier in cleanup_old_files()

# Check if Celsius look for reasonably sane temperature
my $tmin;
my $tmax;
if ($config{Temperature_mode} eq "C") {
    $Temperature = $CTEMP;
    $tmin = -60;
    $tmax = 60;
} else {
    $tmin = -100;
    $tmax = 150;
}

# Write temperature file if within valid range
if ($Temperature >= $tmin && $Temperature <= $tmax) {
    if (open my $temp_fh, '>', TEMP_FILE) {
        print $temp_fh $Temperature;
        close $temp_fh;
    } else {
        WARN("Error writing temperature file: $!");
    }
}

# Process weather condition if enabled
if ($config{process_condition} eq "YES" && $Condition) {
    my @conditions = map { lc($_) } split /\s+/, $Condition;
    my @condition_files;
    my $sound_dir = WEATHER_SOUND_DIR;
    
    DEBUG("Processing weather condition: $Condition") if $options{verbose};
    DEBUG("Looking for sound files in: $sound_dir") if $options{verbose};
    
    # First try exact condition match
    for my $cond (@conditions) {
        next unless $cond;  # Skip empty strings
        my $file = "$sound_dir/$cond.ulaw";
        if (-f $file) {
            DEBUG("  Found exact match: $file") if $options{verbose};
            push @condition_files, $file;
        }
    }
    
    # If no exact matches, try to find similar conditions using pattern matching
    if (!@condition_files && -d $sound_dir) {
        opendir(my $dh, $sound_dir) or WARN("Cannot open sound directory: $sound_dir - $!");
        if ($dh) {
            my @available_files = grep { /\.ulaw$/ && -f "$sound_dir/$_" } readdir($dh);
            closedir($dh);
            
            DEBUG("  No exact matches, trying pattern matching") if $options{verbose};
            for my $cond (@conditions) {
                next unless $cond;  # Skip empty strings
                for my $file (@available_files) {
                    if ($file =~ /\Q$cond\E/i) {
                        my $full_path = "$sound_dir/$file";
                        if (!grep { $_ eq $full_path } @condition_files) {  # Avoid duplicates
                            DEBUG("  Found pattern match: $full_path") if $options{verbose};
                            push @condition_files, $full_path;
                        }
                    }
                }
            }
        }
    }
    
    # If still no matches, try to use a default condition
    if (!@condition_files) {
        DEBUG("  No matches found, trying defaults") if $options{verbose};
        my @default_conditions = qw(clear sunny fair);
        for my $default (@default_conditions) {
            my $file = "$sound_dir/$default.ulaw";
            if (-f $file) {
                DEBUG("  Using default condition: $file") if $options{verbose};
                push @condition_files, $file;
                last;
            }
        }
    }
    
    # Write condition sound file if we found any files
    if (@condition_files) {
        eval {
            open my $condition_fh, ">:raw", COND_FILE or die "Cannot open " . COND_FILE . ": $!";
            for my $file (@condition_files) {
                if (-f $file) {
                    open my $in_fh, "<:raw", $file 
                        or die "Cannot open $file: $!";
                    # Read and write in chunks for better memory efficiency
                    my $buffer;
                    while (read($in_fh, $buffer, 8192)) {
                        print $condition_fh $buffer;
                    }
                    close $in_fh;
                }
            }
            close $condition_fh;
        };
        if ($@) {
            ERROR("Failed to write condition file: $@");
            exit 1;
        }
    } else {
        WARN("No weather condition sound files found for: $Condition");
    }
}

# Validate environment (moved earlier in execution flow)
# These checks are now done in validate_options() and at startup

# Add version to usage
sub show_usage {
    print "weather.pl version " . VERSION . "\n\n";
    print "Usage: $0 [OPTIONS] location_id [v]\n\n";
    print "Arguments:\n";
    print "  location_id    Postal code, ZIP code, or ICAO airport code\n";
    print "                 ICAO examples: KJFK, EGLL, CYYZ, NZSP, LFPG, RJAA\n";
    print "  v              Optional: Display text only (verbose mode), no sound output\n\n";
    print "Options:\n";
    print "  -c, --config FILE        Use alternate configuration file\n";
    print "  -d, --default-country CC Override default country (us, ca, fr, de, uk, etc.)\n";
    print "  -t, --temperature-mode M Override temperature mode (F or C)\n";
    print "  --no-cache               Disable caching for this request\n";
    print "  --no-condition           Skip weather condition announcements\n";
    print "  -h, --help               Show this help message\n";
    print "  --version                Show version information\n\n";
    print "Examples:\n";
    print "  Postal Codes:\n";
    print "    $0 90210                    # Beverly Hills, CA (ZIP)\n";
    print "    $0 M5H2N2 v                 # Toronto, ON (postal code)\n";
    print "    $0 -d fr 75001              # Paris, France\n";
    print "    $0 -d de 10115 v            # Berlin, Germany\n\n";
    print "  ICAO Airport Codes:\n";
    print "    $0 KJFK v                   # JFK Airport, New York\n";
    print "    $0 EGLL                     # Heathrow, London\n";
    print "    $0 CYYZ v                   # Toronto Pearson\n";
    print "    $0 NZSP v                   # South Pole Station\n";
    print "    $0 LFPG                     # Charles de Gaulle, Paris\n";
    print "    $0 RJAA v                   # Narita, Tokyo\n\n";
    print "  With Options:\n";
    print "    $0 -t C KJFK                # JFK in Celsius\n";
    print "    $0 --no-cache EGLL v        # Fresh METAR from Heathrow\n\n";
    print "Default Configuration Files (searched in order):\n";
    print "  /etc/asterisk/local/weather.ini\n";
    print "  /etc/asterisk/weather.ini\n";
    print "  /usr/local/etc/weather.ini\n\n";
    print "Configuration Options:\n";
    print "  - Temperature_mode: F/C (set to C for Celsius, F for Fahrenheit)\n";
    print "  - process_condition: YES/NO (default: YES)\n";
    print "  - default_country: ISO country code for postal lookups (default: us)\n";
    print "  - weather_provider: Weather data source (default: openmeteo)\n";
    print "  - cache_enabled: YES/NO (default: YES)\n";
    print "  - cache_duration: Cache duration in seconds (default: 1800)\n\n";
    print "Note: Command line options override configuration file settings for that run.\n";
    exit 1;
}

# Note: fetch_weather function removed as it was unused dead code
# Weather fetching is done inline in the main code flow
# Note: write_temperature function removed as it was unused

sub cleanup_old_files {
    DEBUG("Cleaning up old weather files:") if $options{verbose};
    
    foreach my $file (TEMP_FILE(), COND_FILE(), TIMEZONE_FILE()) {
        if (-e $file) {
            DEBUG("  Removing: $file") if $options{verbose};
            unlink $file or WARN("Could not remove file: $file - $!");
        }
    }
}

sub validate_options {
    if (!defined $location || $location eq '') {
        ERROR("Postal code not provided");
        show_usage();
    }
}

# Check if input looks like an ICAO airport code
sub is_icao_code {
    my ($code) = @_;
    
    # ICAO codes are 4 letters (e.g., KJFK, EGLL, CYYZ, NZSP)
    return 0 unless $code =~ /^[A-Z]{4}$/i;
    
    # Check if it starts with valid ICAO prefixes
    # K = USA, C = Canada, E = Europe, N = Pacific/Antarctica, R = Asia, etc.
    my $prefix = uc(substr($code, 0, 1));
    return 1 if $prefix =~ /^[ABCDEFGHIJKLMNOPQRSTUVWYZ]$/;
    
    return 0;
}

# Fetch weather from METAR (aviation weather)
sub fetch_metar_weather {
    my ($icao) = @_;
    
    $icao = uc($icao);
    DEBUG("Fetching METAR for $icao") if $options{verbose};
    
    my $ua = LWP::UserAgent->new(timeout => 15);
    $ua->agent('Mozilla/5.0 (compatible; WeatherBot/1.0)');
    
    # Try NOAA Aviation Weather API first
    my $url = "https://aviationweather.gov/api/data/metar?ids=${icao}&format=raw&hours=0&taf=false";
    my $response = $ua->get($url);
    
    my $metar;
    if ($response->is_success) {
        $metar = $response->decoded_content;
        $metar =~ s/^\s+|\s+$//g;  # Trim whitespace
    }
    
    # Fallback to NWS if Aviation Weather failed
    if (!$metar || $metar eq '') {
        DEBUG("  Trying NWS fallback...") if $options{verbose};
        $url = "https://tgftp.nws.noaa.gov/data/observations/metar/stations/${icao}.TXT";
        $response = $ua->get($url);
        if ($response->is_success) {
            my @lines = split /\n/, $response->decoded_content;
            # METAR is usually on the second line
            $metar = $lines[1] if @lines > 1;
            $metar =~ s/^\s+|\s+$//g if $metar;
        }
    }
    
    return unless $metar && $metar ne '';
    
    DEBUG("  METAR: $metar") if $options{verbose};
    
    # Parse temperature and conditions from METAR
    my $temp_f = parse_metar_temperature($metar);
    my $condition = parse_metar_condition($metar);
    
    return ($temp_f, $condition);
}

# Parse temperature from METAR report
sub parse_metar_temperature {
    my ($metar) = @_;
    
    # Temperature format: 25/18 (temp/dewpoint in Celsius)
    # Or with M prefix for negative: M05/M10
    if ($metar =~ /\s(M?\d{2})\/(M?\d{2})\s/) {
        my $temp_c = $1;
        # Convert M prefix to minus sign
        $temp_c =~ s/^M/-/;
        # Remove leading zeros
        $temp_c =~ s/^(-?)0+(\d)/$1$2/;
        # Convert to Fahrenheit
        my $temp_f = ($temp_c * 9/5) + 32;
        return sprintf("%.0f", $temp_f);
    }
    
    return undef;
}

# Parse weather condition from METAR report
sub parse_metar_condition {
    my ($metar) = @_;
    
    # Check for weather phenomena codes
    return "Thunderstorm" if $metar =~ /\bTS\b/;  # Thunderstorm
    return "Heavy Rain" if $metar =~ /\+RA\b/;     # Heavy rain
    return "Rain" if $metar =~ /(-|VC)?RA\b/;      # Rain
    return "Light Rain" if $metar =~ /-RA\b/;      # Light rain
    return "Drizzle" if $metar =~ /DZ\b/;          # Drizzle
    return "Snow" if $metar =~ /SN\b/;             # Snow
    return "Sleet" if $metar =~ /PL\b/;            # Ice pellets
    return "Hail" if $metar =~ /GR\b/;             # Hail
    return "Foggy" if $metar =~ /\bFG\b/;          # Fog
    return "Mist" if $metar =~ /BR\b/;             # Mist
    
    # Check sky conditions (last reported condition wins)
    my $sky_condition = "Clear";
    
    # Parse sky coverage (FEW, SCT, BKN, OVC)
    # OVC = Overcast, BKN = Broken, SCT = Scattered, FEW = Few
    if ($metar =~ /\bOVC\d{3}\b/) {
        $sky_condition = "Overcast";
    } elsif ($metar =~ /\bBKN\d{3}\b/) {
        $sky_condition = "Cloudy";
    } elsif ($metar =~ /\bSCT\d{3}\b/) {
        $sky_condition = "Partly Cloudy";
    } elsif ($metar =~ /\bFEW\d{3}\b/) {
        $sky_condition = "Clear";
    } elsif ($metar =~ /\b(CLR|SKC)\b/) {
        $sky_condition = "Clear";
    }
    
    return $sky_condition;
}

# Convert postal code to coordinates using Nominatim/OpenStreetMap API (free, no key, worldwide)
sub postal_to_coordinates {
    my ($postal) = @_;
    
    DEBUG("Converting postal code $postal to coordinates...") if $options{verbose};
    
    # Special locations without postal codes (Antarctica, remote areas, DXpedition sites)
    my %special_locations = (
        # ===== ANTARCTICA =====
        'SOUTHPOLE' => [-90.0, 0.0, 'South Pole Station, Antarctica'],
        'MCMURDO'   => [-77.85, 166.67, 'McMurdo Station, Antarctica (US)'],
        'PALMER'    => [-64.77, -64.05, 'Palmer Station, Antarctica (US)'],
        'VOSTOK'    => [-78.46, 106.84, 'Vostok Station, Antarctica (Russia)'],
        'CASEY'     => [-66.28, 110.53, 'Casey Station, Antarctica (Australia)'],
        'MAWSON'    => [-67.60, 62.87, 'Mawson Station, Antarctica (Australia)'],
        'DAVIS'     => [-68.58, 77.97, 'Davis Station, Antarctica (Australia)'],
        'SCOTTBASE' => [-77.85, 166.76, 'Scott Base, Antarctica (New Zealand)'],
        'SYOWA'     => [-69.00, 39.58, 'Syowa Station, Antarctica (Japan)'],
        'CONCORDIA' => [-75.10, 123.33, 'Concordia Station, Antarctica (France/Italy)'],
        'HALLEY'    => [-75.58, -26.66, 'Halley Research Station, Antarctica (UK)'],
        'DUMONT'    => [-66.66, 140.01, 'Dumont d\'Urville Station, Antarctica (France)'],
        'SANAE'     => [-71.67, -2.84, 'SANAE IV Station, Antarctica (South Africa)'],
        
        # ===== ARCTIC =====
        'ALERT'        => [82.50, -62.35, 'Alert, Nunavut (Northernmost Settlement)'],
        'EUREKA'       => [79.99, -85.93, 'Eureka, Nunavut, Canada'],
        'THULE'        => [76.53, -68.70, 'Thule Air Base, Greenland'],
        'LONGYEARBYEN' => [78.22, 15.65, 'Longyearbyen, Svalbard, Norway'],
        'BARROW'       => [71.29, -156.79, 'Utqiagvik (Barrow), Alaska'],
        'RESOLUTE'     => [74.72, -94.83, 'Resolute, Nunavut, Canada'],
        'GRISE'        => [76.42, -82.90, 'Grise Fiord, Nunavut, Canada'],
        
        # ===== REMOTE ISLANDS (DXpedition Sites) =====
        'ASCENSION'    => [-7.95, -14.36, 'Ascension Island (ZD8)'],
        'STHELENA'     => [-15.97, -5.72, 'St. Helena Island (ZD7)'],
        'TRISTAN'      => [-37.11, -12.28, 'Tristan da Cunha (ZD9)'],
        'BOUVET'       => [-54.42, 3.38, 'Bouvet Island (3Y0)'],
        'HEARD'        => [-53.10, 73.51, 'Heard Island (VK0)'],
        'KERGUELEN'    => [-49.35, 70.22, 'Kerguelen Islands (FT5)'],
        'CROZET'       => [-46.43, 51.86, 'Crozet Islands (FT4)'],
        'AMSTERDAM'    => [-37.83, 77.57, 'Amsterdam Island (FT5)'],
        'MACQUARIE'    => [-54.62, 158.86, 'Macquarie Island (VK0)'],
        
        # ===== PACIFIC ISLANDS =====
        'MIDWAY'       => [28.21, -177.38, 'Midway Atoll (KH4)'],
        'WAKE'         => [19.28, 166.65, 'Wake Island (KH9)'],
        'JOHNSTON'     => [16.73, -169.53, 'Johnston Atoll (KH3)'],
        'PALMYRA'      => [5.89, -162.08, 'Palmyra Atoll (KH5K)'],
        'JARVIS'       => [-0.37, -159.99, 'Jarvis Island (KH5)'],
        'HOWLAND'      => [0.81, -176.62, 'Howland Island (KH1)'],
        'BAKER'        => [0.19, -176.48, 'Baker Island (KH1)'],
        'KINGMAN'      => [6.38, -162.42, 'Kingman Reef (KH5K)'],
        
        # ===== INDIAN OCEAN =====
        'DIEGO'        => [-7.26, 72.40, 'Diego Garcia (VQ9)'],
        'CHAGOS'       => [-7.26, 72.40, 'Chagos Archipelago (VQ9)'],
        'COCOS'        => [-12.19, 96.83, 'Cocos (Keeling) Islands (VK9C)'],
        'CHRISTMAS'    => [-10.49, 105.62, 'Christmas Island (VK9X)'],
        
        # ===== SOUTH ATLANTIC =====
        'FALKLANDS'    => [-51.70, -59.52, 'Stanley, Falkland Islands (VP8)'],
        'SOUTHGEORGIA' => [-54.28, -36.51, 'Grytviken, South Georgia (VP8)'],
        'SOUTHSANDWICH'=> [-59.43, -26.35, 'South Sandwich Islands (VP8)'],
        
        # ===== PACIFIC POLYNESIA =====
        'MARQUESAS'    => [-9.00, -140.00, 'Marquesas Islands, French Polynesia (FO)'],
        'EASTER'       => [-27.11, -109.36, 'Easter Island (CE0Y)'],
        'PITCAIRN'     => [-25.07, -130.10, 'Pitcairn Island (VP6)'],
        'CLIPPERTON'   => [10.30, -109.22, 'Clipperton Island (FO/C)'],
        'GALAPAGOS'    => [-0.95, -90.97, 'Galapagos Islands (HC8)'],
        
        # ===== MOUNTAIN OBSERVATORIES =====
        'MAUNA'        => [19.54, -155.58, 'Mauna Loa Observatory, Hawaii'],
        'JUNGFRAUJOCH' => [46.55, 7.98, 'Jungfraujoch Research Station, Switzerland'],
        
        # ===== EXTREME DESERTS =====
        'MCMURDODRY'   => [-77.85, 163.00, 'McMurdo Dry Valleys, Antarctica'],
        'ATACAMA'      => [-24.50, -69.25, 'Atacama Desert, Chile'],
        
        # ===== OTHER NOTABLE REMOTE LOCATIONS =====
        'GOUGH'        => [-40.35, -9.88, 'Gough Island (ZD9)'],
        'MARION'       => [-46.88, 37.86, 'Marion Island (ZS8)'],
        'PRINCE'       => [-46.77, 37.86, 'Prince Edward Island (ZS8)'],
        'CAMPBELL'     => [-52.55, 169.15, 'Campbell Island (ZL9)'],
        'AUCKLAND'     => [-50.73, 166.09, 'Auckland Islands (ZL9)'],
        'KERMADEC'     => [-29.25, -177.92, 'Kermadec Islands (ZL8)'],
        'CHATHAM'      => [-43.95, -176.55, 'Chatham Islands (ZL7)'],
    );
    
    my $postal_uc = uc($postal);
    $postal_uc =~ s/[^A-Z0-9]//g;  # Remove spaces/special chars
    
    if (exists $special_locations{$postal_uc}) {
        my ($lat, $lon, $name) = @{$special_locations{$postal_uc}};
        DEBUG("  Special location: $name") if $options{verbose};
        DEBUG("  Coordinates: $lat, $lon") if $options{verbose};
        return ($lat, $lon);
    }
    
    my $ua = LWP::UserAgent->new(timeout => 10);
    $ua->agent('Mozilla/5.0 (compatible; WeatherBot/1.0; +https://github.com/w5gle/saytime-weather)');
    
    # Comprehensive Canadian FSA to city mapping (Nominatim has poor Canadian postal code coverage)
    # FSA = Forward Sortation Area (first 3 characters of Canadian postal code)
    # Using 3-character FSAs for better accuracy, falling back to single letter
    my %canadian_fsa_cities = (
        # Ontario - Specific FSAs
        'N7L' => 'Chatham-Kent, Ontario',    # Chatham area
        'N7M' => 'Sarnia, Ontario',          # Sarnia
        'N7T' => 'Sarnia, Ontario',          # Sarnia
        'N6A' => 'London, Ontario',          # London
        'N6B' => 'London, Ontario',          # London
        'N6C' => 'London, Ontario',          # London
        'N6E' => 'London, Ontario',          # London
        'N6G' => 'London, Ontario',          # London
        'N6H' => 'London, Ontario',          # London
        'N6J' => 'London, Ontario',          # London
        'N6K' => 'London, Ontario',          # London
        'N8A' => 'Windsor, Ontario',         # Windsor
        'N8H' => 'Windsor, Ontario',         # Windsor
        'N8N' => 'Windsor, Ontario',         # Windsor
        'N8P' => 'Windsor, Ontario',         # Windsor
        'N8R' => 'Windsor, Ontario',         # Windsor
        'N8S' => 'Windsor, Ontario',         # Windsor
        'N8T' => 'Windsor, Ontario',         # Windsor
        'N8V' => 'Windsor, Ontario',         # Windsor
        'N8W' => 'Windsor, Ontario',         # Windsor
        'N8X' => 'Windsor, Ontario',         # Windsor
        'N8Y' => 'Windsor, Ontario',         # Windsor
        'N9A' => 'Windsor, Ontario',         # Windsor
        'N9B' => 'Windsor, Ontario',         # Windsor
        'N9C' => 'Windsor, Ontario',         # Windsor
        'N9E' => 'Windsor, Ontario',         # Windsor
        'N9G' => 'Windsor, Ontario',         # Windsor
        'N9H' => 'Windsor, Ontario',         # Windsor
        'N9J' => 'Windsor, Ontario',         # Windsor
        'N9K' => 'Windsor, Ontario',         # Windsor
        'N9Y' => 'Windsor, Ontario',         # Windsor
        'N1G' => 'Guelph, Ontario',          # Guelph
        'N1H' => 'Guelph, Ontario',          # Guelph
        'N1K' => 'Guelph, Ontario',          # Guelph
        'N1L' => 'Guelph, Ontario',          # Guelph
        'N3C' => 'Cambridge, Ontario',       # Cambridge
        'N3E' => 'Cambridge, Ontario',       # Cambridge
        'N3H' => 'Cambridge, Ontario',       # Cambridge
        'N2C' => 'Kitchener, Ontario',       # Kitchener
        'N2E' => 'Kitchener, Ontario',       # Kitchener
        'N2G' => 'Kitchener, Ontario',       # Kitchener
        'N2H' => 'Kitchener, Ontario',       # Kitchener
        'N2J' => 'Kitchener, Ontario',       # Kitchener
        'N2K' => 'Kitchener, Ontario',       # Kitchener
        'N2L' => 'Kitchener, Ontario',       # Kitchener
        'N2M' => 'Kitchener, Ontario',       # Kitchener
        'N2N' => 'Kitchener, Ontario',       # Kitchener
        'N2P' => 'Kitchener, Ontario',       # Kitchener
        'N2R' => 'Kitchener, Ontario',       # Kitchener
        
        # Single-letter fallbacks for major cities
        'M' => 'Toronto, Ontario',           # Toronto (all M codes)
        'V' => 'Vancouver, British Columbia', # Vancouver (all V codes)
        'H' => 'Montreal, Quebec',           # Montreal (all H codes)  
        'T' => 'Calgary, Alberta',           # Calgary/Edmonton area
        'R' => 'Winnipeg, Manitoba',         # Winnipeg area
        'K' => 'Ottawa, Ontario',            # Ottawa area
        'L' => 'Mississauga, Ontario',       # GTA west (better than generic "Ontario")
        'N' => 'London, Ontario',            # Southwestern Ontario (better default than generic "Ontario")
        'P' => 'Thunder Bay, Ontario',       # Northern Ontario
        'S' => 'Regina, Saskatchewan',       # Saskatchewan
        'E' => 'Moncton, New Brunswick',     # New Brunswick
        'B' => 'Halifax, Nova Scotia',       # Nova Scotia
        'C' => 'Charlottetown, Prince Edward Island', # PEI
        'A' => 'St. Johns, Newfoundland',    # Newfoundland
        'G' => 'Quebec City, Quebec',        # Eastern Quebec
        'J' => 'Gatineau, Quebec',           # Western Quebec
        'X' => 'Whitehorse, Yukon',          # Territories
        'Y' => 'Whitehorse, Yukon',          # Yukon
    );
    
    # Use Nominatim (OpenStreetMap) geocoding service - free, no API key, worldwide
    my $url;
    my $country = '';
    my $canadian_fsa = '';
    
    # Detect postal code format and set country
    if ($postal =~ /^\d{5}$/) {
        # 5 digits: Could be US, Germany, France, or other countries
        # Use configured default_country, fallback to US if not set
        $country = lc($config{default_country}) || 'us';
        if ($country && $country ne '') {
            $url = "https://nominatim.openstreetmap.org/search?postalcode=$postal&country=$country&format=json&limit=1";
            DEBUG("  Using default country: $country") if $options{verbose};
        } else {
            $url = "https://nominatim.openstreetmap.org/search?postalcode=$postal&format=json&limit=1";
        }
    } elsif ($postal =~ /^([A-Z]\d[A-Z])\s?\d[A-Z]\d$/i) {
        # Canadian: A1A 1A1 or A1A1A1
        $country = 'ca';
        $canadian_fsa = uc($1);  # Extract full 3-character FSA (e.g., N7L)
        # Try with space normalized
        my $normalized = uc($postal);
        $normalized =~ s/\s+//g;  # Remove any spaces
        $normalized =~ s/^([A-Z]\d[A-Z])(\d[A-Z]\d)$/$1 $2/;  # Add space in middle
        $url = "https://nominatim.openstreetmap.org/search?postalcode=$normalized&country=$country&format=json&limit=1";
    } else {
        # Other international codes
        $url = "https://nominatim.openstreetmap.org/search?postalcode=$postal&format=json&limit=1";
    }
    
    DEBUG("  Trying URL: $url") if $options{verbose};
    
    my $response = $ua->get($url);
    if ($response->is_success) {
        my $data = eval { decode_json($response->decoded_content) };
        if ($@ || !$data) {
            DEBUG("Failed to parse Nominatim response: $@") if $options{verbose};
            return;
        }
        
        if ($data && ref($data) eq 'ARRAY' && @$data > 0) {
            my $lat = $data->[0]->{lat};
            my $lon = $data->[0]->{lon};
            my $display = $data->[0]->{display_name} || $postal;
            DEBUG("  Found: $display") if $options{verbose};
            DEBUG("  Coordinates: $lat, $lon") if $options{verbose};
            return ($lat, $lon);
        } else {
            DEBUG("  No coordinates found for postal code $postal") if $options{verbose};
            
            # If country-specific search failed for 5-digit code, try international
            if ($country && $postal =~ /^\d{5}$/) {
                DEBUG("  $country search failed, trying international for $postal") if $options{verbose};
                my $intl_url = "https://nominatim.openstreetmap.org/search?postalcode=$postal&format=json&limit=1";
                sleep 1;  # Rate limit
                $response = $ua->get($intl_url);
                if ($response->is_success) {
                    $data = eval { decode_json($response->decoded_content) };
                    if ($data && ref($data) eq 'ARRAY' && @$data > 0) {
                        my $lat = $data->[0]->{lat};
                        my $lon = $data->[0]->{lon};
                        my $display = $data->[0]->{display_name} || $postal;
                        DEBUG("  Found internationally: $display") if $options{verbose};
                        return ($lat, $lon);
                    }
                }
            }
            
            # For Canadian postal codes, Nominatim often lacks detailed data
            # Use FSA-to-city mapping as fallback
            # Try 3-character FSA first (e.g., N7L), then single-letter fallback (e.g., N)
            if ($country eq 'ca' && $canadian_fsa) {
                my $city_name;
                my $lookup_fsa;
                
                # Try 3-character FSA first
                if (exists $canadian_fsa_cities{$canadian_fsa}) {
                    $city_name = $canadian_fsa_cities{$canadian_fsa};
                    $lookup_fsa = $canadian_fsa;
                }
                # Fall back to single-letter FSA
                elsif (length($canadian_fsa) >= 1) {
                    my $single_letter = substr($canadian_fsa, 0, 1);
                    if (exists $canadian_fsa_cities{$single_letter}) {
                        $city_name = $canadian_fsa_cities{$single_letter};
                        $lookup_fsa = $single_letter;
                    }
                }
                
                if ($city_name) {
                    DEBUG("  Trying Canadian city lookup: $city_name (FSA: $lookup_fsa)") if $options{verbose};
                    
                    my $city_url = "https://nominatim.openstreetmap.org/search?q=$city_name&format=json&limit=1";
                    sleep 1;  # Rate limit
                    $response = $ua->get($city_url);
                    if ($response->is_success) {
                        $data = eval { decode_json($response->decoded_content) };
                        if ($data && ref($data) eq 'ARRAY' && @$data > 0) {
                            my $lat = $data->[0]->{lat};
                            my $lon = $data->[0]->{lon};
                            my $display = $data->[0]->{display_name} || $city_name;
                            DEBUG("  Found via city lookup: $display") if $options{verbose};
                            return ($lat, $lon);
                        }
                    }
                }
            }
        }
    } else {
        DEBUG("Nominatim API request failed: " . $response->status_line) if $options{verbose};
    }
    
    # Add a small delay to respect Nominatim usage policy (max 1 request/second)
    sleep 1;
    
    return;
}

# Convert Open-Meteo WMO weather code to text description with day/night awareness
sub weather_code_to_text {
    my ($code, $is_day) = @_;
    $is_day = 1 unless defined $is_day;  # Default to day if not provided
    
    # Handle codes 1-2 with day/night awareness
    # During day: can say "Sunny", at night: say "Clear" (sun isn't up!)
    if ($code == 1) {
        return $is_day ? 'Sunny' : 'Mainly Clear';
    } elsif ($code == 2) {
        return $is_day ? 'Mostly Sunny' : 'Partly Cloudy';
    }
    
    # All other codes don't need day/night distinction
    my %codes = (
        0  => 'Clear',
        3  => 'Overcast',
        45 => 'Foggy',
        48 => 'Foggy',
        51 => 'Light Drizzle',
        53 => 'Drizzle',
        55 => 'Heavy Drizzle',
        56 => 'Light Freezing Drizzle',
        57 => 'Freezing Drizzle',
        61 => 'Light Rain',
        63 => 'Rain',
        65 => 'Heavy Rain',
        66 => 'Light Freezing Rain',
        67 => 'Freezing Rain',
        71 => 'Light Snow',
        73 => 'Snow',
        75 => 'Heavy Snow',
        77 => 'Snow Grains',
        80 => 'Light Showers',
        81 => 'Showers',
        82 => 'Heavy Showers',
        85 => 'Light Snow Showers',
        86 => 'Snow Showers',
        95 => 'Thunderstorm',
        96 => 'Thunderstorm with Light Hail',
        99 => 'Thunderstorm with Hail',
    );
    
    return $codes{$code} || 'Unknown';
}

# Fetch weather from Open-Meteo API (free, no API key required)
sub fetch_weather_openmeteo {
    my ($lat, $lon) = @_;
    
    DEBUG("Fetching weather from Open-Meteo: lat=$lat, lon=$lon") if $options{verbose};
    
    my $ua = LWP::UserAgent->new(timeout => 15);
    $ua->agent('Mozilla/5.0 (compatible; WeatherBot/1.0)');
    
    # Always request in Fahrenheit, convert to Celsius later if needed
    # Use 'current' parameter to get is_day field for day/night detection
    my $url = "https://api.open-meteo.com/v1/forecast?" .
              "latitude=$lat&longitude=$lon&" .
              "current=temperature_2m,weather_code,is_day&" .
              "temperature_unit=fahrenheit&timezone=auto";
    
    my $response = $ua->get($url);
    if ($response->is_success) {
        my $data = eval { decode_json($response->decoded_content) };
        if ($@ || !$data) {
            DEBUG("Failed to parse Open-Meteo response: $@") if $options{verbose};
            return;
        }
        
        if ($data->{current}) {
            my $temp = $data->{current}->{temperature_2m};
            my $code = $data->{current}->{weather_code};
            my $is_day = $data->{current}->{is_day} // 1;  # Default to day if missing
            my $condition = weather_code_to_text($code, $is_day);
            my $timezone = $data->{timezone} || '';
            
            DEBUG("  Temperature: $temp") if $options{verbose};
            DEBUG("  Weather code: $code ($condition)") if $options{verbose};
            DEBUG("  Day/Night: " . ($is_day ? "Day" : "Night")) if $options{verbose};
            DEBUG("  Timezone: $timezone") if $options{verbose};
            
            # Save timezone to file so saytime.pl can use it
            if ($timezone) {
                eval {
                    open my $tz_fh, '>', TIMEZONE_FILE or die "Cannot open timezone file: $!";
                    print $tz_fh $timezone;
                    close $tz_fh;
                    DEBUG("  Saved timezone to " . TIMEZONE_FILE) if $options{verbose};
                };
                WARN("Failed to write timezone file: $@") if $@;
            }
            
            return ($temp, $condition, $timezone);
        }
    } else {
        DEBUG("Open-Meteo request failed: " . $response->status_line) if $options{verbose};
    }
    return;
}

# Temperature validation function (currently unused but kept for potential future use)
sub validate_temperature {
    my ($temp) = @_;
    my ($tmin, $tmax) = $config{Temperature_mode} eq "C" 
        ? (-60, 60) 
        : (-100, 150);
    
    return ($temp >= $tmin && $temp <= $tmax);
}

# Add signal handlers for cleanup
$SIG{INT} = $SIG{TERM} = sub {
    cleanup_old_files();
    exit 1;
};

# Add configuration validation
sub validate_config {
    if ($config{Temperature_mode} !~ /^[CF]$/) {
        ERROR("Invalid Temperature_mode: $config{Temperature_mode}");
        exit 1;
    }
    if ($config{cache_duration} !~ /^\d+$/) {
        WARN("Invalid cache_duration: $config{cache_duration}, using default");
        $config{cache_duration} = 1800;
    }
}

# Validate environment
sub validate_environment {
    if (!-d TMP_DIR()) {
        ERROR("Temporary directory not found: " . TMP_DIR());
        exit 1;
    }
    if (!-w TMP_DIR()) {
        ERROR("Cannot write to temporary directory: " . TMP_DIR());
        exit 1;
    }
}

# Call validation after loading config
validate_config();
validate_environment();
