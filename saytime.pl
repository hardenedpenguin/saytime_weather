#!/usr/bin/perl

# saytime.pl - Announces the time and weather information.
# Copyright 2025, Jory A. Pratt, W5GLE
# Based on original work by D. Crompton, WA3DSP
#
# This script retrieves the current time and optionally the weather,
# then generates a concatenated audio file of the time and weather announcement.
# It can either play the audio, or save the sound file.

use strict;
use warnings;
use File::Spec;
use Getopt::Long;
use Log::Log4perl qw(:easy);
use DateTime;
use DateTime::TimeZone;
use Config::Simple;

use constant {
    TMP_DIR => "/tmp",
    BASE_SOUND_DIR => "/usr/share/asterisk/sounds/en",
    WEATHER_SCRIPT => "/usr/sbin/weather.pl",
    DEFAULT_VERBOSE => 0,
    DEFAULT_DRY_RUN => 0,
    DEFAULT_TEST_MODE => 0,
    DEFAULT_WEATHER_ENABLED => 1,
    DEFAULT_24HOUR => 0,
    DEFAULT_GREETING => 1,
    ASTERISK_BIN => "/usr/sbin/asterisk",
    DEFAULT_PLAY_METHOD => 'localplay',
    PLAY_DELAY => 5,
    VERSION => '2.7.5',
};

my %options = (
    location_id => undef,
    node_number => undef,
    silent => 0,
    use_24hour => DEFAULT_24HOUR,
    verbose => DEFAULT_VERBOSE,
    dry_run => DEFAULT_DRY_RUN,
    test_mode => DEFAULT_TEST_MODE,
    weather_enabled => DEFAULT_WEATHER_ENABLED,
    greeting_enabled => DEFAULT_GREETING,
    custom_sound_dir => undef,
    log_file => undef,
    play_method => 'localplay',
);

GetOptions(
    "location_id|l=s" => \$options{location_id},
    "node_number|n=s" => \$options{node_number},
    "silent|s=i" => \$options{silent},
    "use_24hour|h!" => \$options{use_24hour},
    "verbose|v!" => \$options{verbose},
    "dry-run|d!" => \$options{dry_run},
    "test|t!" => \$options{test_mode},
    "weather|w!" => \$options{weather_enabled},
    "greeting|g!" => \$options{greeting_enabled},
    "sound-dir=s" => \$options{custom_sound_dir},
    "log=s" => \$options{log_file},
    "method|m" => sub { $options{play_method} = 'playback' },
    "help" => sub { show_usage(); exit 0; },
) or show_usage();

$options{play_method} //= 'localplay';

setup_logging();

my %config;
my $config_file = '/etc/asterisk/local/weather.ini';
if (-f $config_file) {
    Config::Simple->import_from($config_file, \%config)
        or die "Cannot load config file $config_file: " . Config::Simple->error();
} else {
    DEBUG("Creating default configuration file: $config_file") if $options{verbose};
    open my $fh, '>', $config_file
        or die "Cannot create config file $config_file: $!";
    print $fh <<'EOT';
; Weather configuration
[weather]
; Process weather condition announcements (YES/NO)
process_condition = YES

; Temperature display mode (F for Fahrenheit, C for Celsius)
Temperature_mode = F

; Cache settings
cache_enabled = YES
cache_duration = 1800
EOT
    close $fh;
    chmod 0644, $config_file
        or die "Cannot set permissions on $config_file: $!";
}

$config{"weather.Temperature_mode"} ||= "F";
$config{"weather.process_condition"} ||= "YES";

validate_options();

my $critical_error_occurred = 0;

# Process weather FIRST so timezone file is created before getting time
# This ensures time matches the weather location timezone
my $weather_sound_files = process_weather($options{location_id});

# Now get time (will use timezone from weather.pl if available)
my $now = get_current_time($options{location_id});

my $time_sound_files = process_time($now, $options{use_24hour});

my $output_file = File::Spec->catfile(TMP_DIR, "current-time.ulaw");
my $final_sound_files = combine_sound_files($time_sound_files, $weather_sound_files);

if ($options{dry_run}) {
    INFO("Dry run mode - would play: $final_sound_files");
    exit 0;
}

if ($final_sound_files) {
    create_output_file($final_sound_files, $output_file);
}

if ($options{silent} == 0) {
    play_announcement($options{node_number}, $output_file);
    cleanup_files($output_file, $options{weather_enabled}, $options{silent});
} elsif ($options{silent} == 1 || $options{silent} == 2) {
    INFO("Saved sound file to $output_file");
    cleanup_files(undef, $options{weather_enabled}, $options{silent});
}

exit $critical_error_occurred;

sub setup_logging {
    # In non-verbose mode: only show ERROR level with simple format
    # In verbose mode: show everything (DEBUG level) with full format
    my $log_level = $options{verbose} ? $DEBUG : $ERROR;
    my $layout = $options{verbose} ? '%d [%p] %m%n' : '%m%n';
    my %log_params = (
        level  => $log_level,
        layout => $layout
    );
    $log_params{file} = ">>$options{log_file}" if $options{log_file};
    Log::Log4perl->easy_init(\%log_params);
}

sub validate_options {
    if ($options{play_method} !~ /^(localplay|playback)$/) {
        die "Invalid play method: $options{play_method} (must be 'localplay' or 'playback')\n";
    }
    
    show_usage() unless defined $options{node_number} || @ARGV;
    
    $options{node_number} = shift @ARGV if @ARGV && !defined $options{node_number};
    
    die "Node number is required\n" unless defined $options{node_number};
    die "Invalid node number format: $options{node_number}\n" unless $options{node_number} =~ /^\d+$/;
    die "Invalid silent value: $options{silent}\n" if $options{silent} < 0 || $options{silent} > 2;
    
    if ($options{weather_enabled} && !defined $options{location_id}) {
        die "Location ID (postal code) is required when weather is enabled\n";
    }
    
    if ($options{custom_sound_dir}) {
        die "Custom sound directory does not exist: $options{custom_sound_dir}\n" 
            unless -d $options{custom_sound_dir};
    }
}

sub get_current_time {
    my ($location_id) = @_;
    
    # Check if weather.pl saved a timezone file (from Open-Meteo)
    # This makes the time match the weather location
    my $timezone_file = File::Spec->catfile(TMP_DIR, "timezone");
    
    if (defined $location_id && -f $timezone_file) {
        my $timezone;
        eval {
            open my $tz_fh, '<', $timezone_file or die "Cannot open timezone file: $!";
            chomp($timezone = <$tz_fh>);
            close $tz_fh;
        };
        
        if (!$@ && $timezone && $timezone ne '') {
            DEBUG("Using timezone from weather location: $timezone") if $options{verbose};
            my $dt = DateTime->now;
            my $tz_error;
            eval { $dt->set_time_zone($timezone); };
            $tz_error = $@;
            
            if ($tz_error) {
                DEBUG("Invalid timezone '$timezone', falling back to local") if $options{verbose};
            } else {
                DEBUG("Current time in $timezone: " . $dt->hms) if $options{verbose};
                return $dt;  # Return from function, not just eval
            }
        } elsif ($@) {
            DEBUG("Failed to read timezone file: $@") if $options{verbose};
        }
    }
    
    # Fall back to system local time
    DEBUG("Using system local time") if $options{verbose};
    return DateTime->now(time_zone => 'local');
}

# Note: Removed complex timezone and geocoding functions (170+ lines)
# Now using simple system local time - the repeater's timezone is correct for local listeners
# Weather fetching is handled by weather.pl which uses Nominatim + Open-Meteo (no API keys needed)

sub check_sound_file {
    my ($file) = @_;
    unless (-f $file) {
        WARN("Sound file not found: $file");
        WARN("  Expected location: $file");
        WARN("  Check that sound files are installed correctly");
        return 0;
    }
    return 1;
}

sub add_sound_file {
    my ($file, $missing_ref) = @_;
    if (check_sound_file($file)) {
        return "$file ";
    } else {
        $$missing_ref++ if defined $missing_ref;
        # Still return the file path - let create_output_file handle missing files gracefully
        return "$file ";
    }
}

sub process_time {
    my ($now, $use_24hour) = @_;
    my @files;
    my $sound_dir = $options{custom_sound_dir} || BASE_SOUND_DIR;
    my $missing_files = 0;
    
    if ($options{greeting_enabled}) {
        my $hour = $now->hour;
        my $greeting = $hour < 12 ? "morning" : $hour < 18 ? "afternoon" : "evening";
        push @files, add_sound_file("$sound_dir/rpt/good$greeting.ulaw", \$missing_files);
    }
    
    push @files, add_sound_file("$sound_dir/rpt/thetimeis.ulaw", \$missing_files);
    
    my ($hour, $minute) = ($now->hour, $now->minute);
    
    if ($use_24hour) {
        if ($hour < 10) {
            push @files, add_sound_file("$sound_dir/digits/0.ulaw", \$missing_files);
        }
        push @files, format_number($hour, $sound_dir);
        
        if ($minute == 0) {
            push @files, add_sound_file("$sound_dir/digits/hundred.ulaw", \$missing_files);
            push @files, add_sound_file("$sound_dir/hours.ulaw", \$missing_files);
        } else {
            if ($minute < 10) {
                push @files, add_sound_file("$sound_dir/digits/0.ulaw", \$missing_files);
            }
            push @files, format_number($minute, $sound_dir);
            push @files, add_sound_file("$sound_dir/hours.ulaw", \$missing_files);
        }
    } else {
        my $display_hour = ($hour == 0 || $hour == 12) ? 12 : ($hour > 12 ? $hour - 12 : $hour);
        push @files, add_sound_file("$sound_dir/digits/$display_hour.ulaw", \$missing_files);
        
        if ($minute != 0) {
            if ($minute < 10) {
                push @files, add_sound_file("$sound_dir/digits/0.ulaw", \$missing_files);
            }
            push @files, format_number($minute, $sound_dir);
        }
        push @files, add_sound_file("$sound_dir/digits/" . ($hour < 12 ? "a-m" : "p-m") . ".ulaw", \$missing_files);
    }
    
    if ($missing_files > 0 && !$options{verbose}) {
        WARN("$missing_files sound file(s) missing. Run with -v for details.");
    }
    
    return join("", @files);
}

sub process_weather {
    my ($location_id) = @_;
    return "" unless $options{weather_enabled} && defined $location_id;
    
    DEBUG("Fetching weather for location: $location_id") if $options{verbose};

    my $temp_file_to_clean = File::Spec->catfile(TMP_DIR, "temperature");
    my $weather_condition_file_to_clean = File::Spec->catfile(TMP_DIR, "condition.ulaw");
    unlink $temp_file_to_clean if -e $temp_file_to_clean;
    unlink $weather_condition_file_to_clean if -e $weather_condition_file_to_clean;
    
    # Use system() with list form to prevent command injection
    # Validate location_id contains only safe characters (alphanumeric, spaces, hyphens, underscores)
    if ($location_id =~ /[^a-zA-Z0-9\s\-_]/) {
        ERROR("Invalid location ID format. Only alphanumeric characters, spaces, hyphens, and underscores are allowed.");
        ERROR("  Location: $location_id");
        $critical_error_occurred = 1;
        return "";
    }
    
    my $weather_result_raw = system(WEATHER_SCRIPT, $location_id);
    
    if ($weather_result_raw != 0) {
        my $exit_code = $? >> 8;
        ERROR("Weather script failed:");
        ERROR("  Location: $location_id");
        ERROR("  Script: " . WEATHER_SCRIPT);
        ERROR("  Exit code: $exit_code");
        ERROR("  Hint: Check that weather.pl is installed and location ID is valid");
        $critical_error_occurred = 1;
        return "";
    }
    
    my $temp_file = File::Spec->catfile(TMP_DIR, "temperature");
    my $weather_condition_file = File::Spec->catfile(TMP_DIR, "condition.ulaw");
    my $sound_dir = $options{custom_sound_dir} || BASE_SOUND_DIR;
    
    my $files = "";
    if (-f $temp_file) {
        open my $temp_fh, '<', $temp_file or die "Cannot open temperature file: $!";
        chomp(my $temp = <$temp_fh>);
        close $temp_fh;
        
        # Check for required sound files
        my @required_files = (
            "$sound_dir/silence/1.ulaw",
            "$sound_dir/wx/weather.ulaw",
            "$sound_dir/wx/conditions.ulaw",
            "$weather_condition_file",
            "$sound_dir/wx/temperature.ulaw",
            "$sound_dir/wx/degrees.ulaw"
        );
        
        my $missing_count = 0;
        for my $file (@required_files) {
            next if $file eq $weather_condition_file;  # This is generated, not required to exist beforehand
            unless (-f $file) {
                WARN("Weather sound file not found: $file") if $options{verbose};
                $missing_count++;
            }
        }
        
        if ($missing_count > 0 && $options{verbose}) {
            WARN("$missing_count weather sound file(s) missing. Announcement may be incomplete.");
        }
        
        $files = "$sound_dir/silence/1.ulaw " .
                 "$sound_dir/wx/weather.ulaw " .
                 "$sound_dir/wx/conditions.ulaw $weather_condition_file " .
                 "$sound_dir/wx/temperature.ulaw ";
                 
        if ($temp < 0) {
            my $missing_count_ref = \$missing_count;
            $files .= add_sound_file("$sound_dir/digits/minus.ulaw", $missing_count_ref);
            $temp = abs($temp);
        }
        
        $files .= format_number($temp, $sound_dir);
        $files .= "$sound_dir/wx/degrees.ulaw ";
    } else {
        ERROR("Temperature file not found after running weather script");
        ERROR("  Expected: $temp_file");
        ERROR("  Hint: Check that weather.pl completed successfully");
        Log::Log4perl::get_logger()->warn("Temperature file not found after running weather script: $temp_file");
    }
    
    return $files;
}

sub format_number {
    my ($num, $sound_dir) = @_;
    my $files = "";
    my $abs_num = abs($num);

    # Handle zero case
    return "$sound_dir/digits/0.ulaw " if $abs_num == 0;

    # Handle hundreds
    if ($abs_num >= 100) {
        my $hundreds = int($abs_num / 100);
        $files .= "$sound_dir/digits/$hundreds.ulaw ";
        $files .= "$sound_dir/digits/hundred.ulaw ";
        $abs_num %= 100;
        return $files if $abs_num == 0;
    }

    # Handle numbers less than 20 (special cases like 11, 12, etc.)
    if ($abs_num < 20) {
        $files .= "$sound_dir/digits/$abs_num.ulaw ";
    } else {
        # Handle tens and ones
        my $tens = int($abs_num / 10) * 10;
        my $ones = $abs_num % 10;
        $files .= "$sound_dir/digits/$tens.ulaw ";
        $files .= "$sound_dir/digits/$ones.ulaw " if $ones;
    }
    
    return $files;
}

sub combine_sound_files {
    my ($time_files, $weather_files) = @_;
    my $files = "";
    
    if ($options{silent} == 0 || $options{silent} == 1) {
        $files = "$time_files $weather_files";
    } elsif ($options{silent} == 2) {
        $files = $weather_files;
    }
    
    return $files;
}

sub create_output_file {
    my ($input_files, $output_file) = @_;
    
    # Use Perl file operations instead of shell cat to prevent command injection
    eval {
        open my $out_fh, '>', $output_file
            or die "Cannot open output file $output_file: $!";
        binmode($out_fh);  # Binary mode for .ulaw files
        
        # Split input_files string into individual file paths
        my @files = split(/\s+/, $input_files);
        my $files_processed = 0;
        
        for my $file (@files) {
            next unless $file && $file =~ /\.ulaw$/;  # Only process .ulaw files
            
            # Validate file path is safe (no directory traversal)
            if ($file =~ /\.\./ || $file =~ /^[\/]/ && $file !~ /^\/usr\/share\/asterisk\/sounds/ && $file !~ /^\/tmp\//) {
                WARN("Skipping potentially unsafe file path: $file");
                next;
            }
            
            if (-f $file) {
                open my $in_fh, '<', $file
                    or do { WARN("Cannot open input file $file: $!"); next; };
                binmode($in_fh);  # Binary mode for .ulaw files
                
                # Copy file contents in chunks for efficiency
                my $buffer;
                while (read($in_fh, $buffer, 8192)) {
                    print $out_fh $buffer;
                }
                close $in_fh;
                $files_processed++;
            } else {
                WARN("Sound file not found: $file");
                WARN("  Expected location: $file");
                WARN("  Check that sound files are installed in the sound directory");
            }
        }
        
        close $out_fh;
        
        if ($files_processed == 0) {
            die "No valid sound files were processed";
        }
        
        DEBUG("Concatenated $files_processed sound files to $output_file") if $options{verbose};
    };
    
    if ($@) {
        ERROR("Failed to create output file:");
        ERROR("  Output: $output_file");
        ERROR("  Error: $@");
        ERROR("  Hint: Check file permissions and disk space");
        $critical_error_occurred = 1;
    }
}

sub play_announcement {
    my ($node, $asterisk_file) = @_;
    
    $asterisk_file =~ s/\.ulaw$//;
    
    # Validate inputs to prevent command injection
    unless ($node =~ /^\d+$/) {
        ERROR("Invalid node number format: $node");
        $critical_error_occurred = 1;
        return;
    }
    
    unless ($options{play_method} =~ /^(localplay|playback)$/) {
        ERROR("Invalid play method: $options{play_method}");
        $critical_error_occurred = 1;
        return;
    }
    
    # Sanitize asterisk_file path (remove any potentially dangerous characters)
    $asterisk_file =~ s/[^a-zA-Z0-9\/\-_\.]//g;

    if ($options{test_mode}) {
        INFO("Test mode - would execute: rpt $options{play_method} $node $asterisk_file");
        return;
    }
    
    # Use system() with list form for better security
    # Note: Asterisk CLI requires the command as a single string, so we construct it carefully
    my $asterisk_cmd = "rpt $options{play_method} $node $asterisk_file";
    
    DEBUG("Executing: " . ASTERISK_BIN . " -rx \"$asterisk_cmd\"") if $options{verbose};

    # Escape the command string properly for shell
    my $asterisk_result_raw = system(ASTERISK_BIN, "-rx", $asterisk_cmd);
    if ($asterisk_result_raw != 0) {
        my $exit_code = $? >> 8;
        ERROR("Failed to play announcement:");
        ERROR("  Method: $options{play_method}");
        ERROR("  Node: $node");
        ERROR("  File: $asterisk_file");
        ERROR("  Exit code: $exit_code");
        ERROR("  Hint: Verify Asterisk is running and node number is correct");
        $critical_error_occurred = 1;
    }
    sleep PLAY_DELAY;
}

sub cleanup_files {
    my ($file_to_delete, $weather_enabled, $silent) = @_;
    
    DEBUG("Cleaning up temporary files:") if $options{verbose};
    
    if (defined $file_to_delete && $silent == 0) {
        DEBUG("  Removing announcement file: $file_to_delete") if $options{verbose};
        unlink $file_to_delete if -e $file_to_delete;
    }
    
    if ($weather_enabled && ($silent == 1 || $silent == 2 || $silent == 0)) {
        my $temp_file = File::Spec->catfile(TMP_DIR, "temperature");
        my $cond_file = File::Spec->catfile(TMP_DIR, "condition.ulaw");
        my $tz_file = File::Spec->catfile(TMP_DIR, "timezone");
        
        DEBUG("  Removing weather files:") if $options{verbose};
        DEBUG("    - $temp_file") if $options{verbose};
        DEBUG("    - $cond_file") if $options{verbose};
        DEBUG("    - $tz_file") if $options{verbose};
        
        unlink $temp_file if -e $temp_file;
        unlink $cond_file if -e $cond_file;
        unlink $tz_file if -e $tz_file;
    }
}

sub show_usage {
    print "saytime.pl version " . VERSION . "\n\n";
    die "Usage: $0 [options] node_number\n" .
    "Options:\n" .
    "  -l, --location_id=ID    Location ID for weather (default: none)\n" .
    "  -n, --node_number=NUM   Node number for announcement (if not provided as argument)\n" .
    "  -s, --silent=NUM        Silent mode (default: 0)\n" .
    "                          0=voice, 1=save time+weather, 2=save weather only\n" .
    "  -h, --use_24hour        Use 24-hour clock (default: off)\n" .    
    "  -v, --verbose           Enable verbose output (default: off)\n" .
    "  -d, --dry-run           Don't actually play or save files (default: off)\n" .
    "  -t, --test              Log playback command instead of executing (default: off)\n" .
    "  -w, --weather           Enable weather announcements (default: on)\n" .
    "  -g, --greeting          Enable greeting messages (default: on)\n" .
    "  -m                      Enable playback mode (default: localplay)\n" .
    "      --sound-dir=DIR     Use custom sound directory\n" .
    "                          (default: /usr/share/asterisk/sounds/en)\n" .
    "      --log=FILE          Log to specified file (default: none)\n" .
    "      --help              Show this help message and exit\n\n" .
    "Location ID: Any postal code worldwide\n" .
    "  - US: 77511, 10001, 90210\n" .
    "  - International: 75001 (Paris), SW1A1AA (London), etc.\n" .
    "Examples:\n" .
    "  perl saytime.pl -l 77511 -n 546054\n" .
    "  perl saytime.pl -l 77511 546054 -s 1\n" .
    "  perl saytime.pl -l 77511 546054 -h\n\n" .
    "Configuration in /etc/asterisk/local/weather.ini:\n" .
    "  - Temperature_mode: F/C (default: F)\n" .
    "  - process_condition: YES/NO (default: YES)\n\n" .
    "Note: No API keys required! Uses system time and weather.pl for weather.\n";
}